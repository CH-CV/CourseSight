/// riverpod 状态层(flutter_riverpod 3.x Notifier 风格)。
/// 数据流:DB → 仓库 → Notifier → UI;写入操作统一走本文件的 action 方法,
/// 便于日后在同一处挂小组件刷新与提醒重排。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../data/db.dart';
import '../data/entities.dart';

/// 当前周(页面上用户正在看的周),跨页共享。
class ViewedWeekNotifier extends Notifier<int?> {
  @override
  int? build() => null;

  void set(int? week) => state = week;
}

final viewedWeekProvider =
    NotifierProvider<ViewedWeekNotifier, int?>(ViewedWeekNotifier.new);

// ── 基础设施 ──

final dbProvider = Provider<Db>((ref) => Db());

final timetableRepositoryProvider =
    Provider<TimetableRepository>((ref) => TimetableRepository(ref.watch(dbProvider)));

final settingsRepositoryProvider =
    Provider<SettingsRepository>((ref) => SettingsRepository(ref.watch(dbProvider)));

final secureStorageProvider =
    Provider<FlutterSecureStorage>((ref) => const FlutterSecureStorage());

// ── 设置 ──

/// 全部设置的内存快照(key→value),load 后可用。
class SettingsState {
  final Map<String, String> values;
  final bool loaded;

  const SettingsState({this.values = const {}, this.loaded = false});

  String? get(String key) => values[key];

  bool get reminderEnabled => values['reminder_enabled'] != 'false';
  int get reminderLeadMinutes => int.tryParse(values['reminder_lead_minutes'] ?? '') ?? 15;
  bool get showWeekend => values['show_weekend'] != 'false';

  /// 每周第一列:默认周一;部分学校课表以周日为第一列,由用户在设置里选。
  int get weekStartDay => values['week_start_day'] == '7' ? 7 : 1;
  bool get showNowLine => values['show_now_line'] != 'false';
  String get llmBaseUrl => values['llm_base_url'] ?? '';
  String get llmModel => values['llm_model'] ?? '';
  bool get llmKeyConfigured => values['llm_key_configured'] == 'true';
  int? get currentTimetableId => int.tryParse(values['current_timetable_id'] ?? '');
}

class SettingsNotifier extends Notifier<SettingsState> {
  @override
  SettingsState build() => const SettingsState();

  Future<void> load() async {
    final repo = ref.read(settingsRepositoryProvider);
    final values = await repo.loadAll();
    state = SettingsState(values: values, loaded: true);
  }

  Future<void> set(String key, String value) async {
    await ref.read(settingsRepositoryProvider).set(key, value);
    state = SettingsState(
      values: {...state.values, key: value},
      loaded: true,
    );
  }

  Future<void> remove(String key) async {
    await ref.read(settingsRepositoryProvider).remove(key);
    final values = {...state.values}..remove(key);
    state = SettingsState(values: values, loaded: true);
  }

  Future<void> setApiKey(String? value) async {
    final storage = ref.read(secureStorageProvider);
    if (value == null || value.isEmpty) {
      await storage.delete(key: 'llm_api_key');
      await set('llm_key_configured', 'false');
    } else {
      await storage.write(key: 'llm_api_key', value: value);
      await set('llm_key_configured', 'true');
    }
  }

  Future<String?> readApiKey() =>
      ref.read(secureStorageProvider).read(key: 'llm_api_key');
}

final settingsProvider =
    NotifierProvider<SettingsNotifier, SettingsState>(SettingsNotifier.new);

// ── 课表 ──

class TimetablesNotifier extends Notifier<List<Timetable>> {
  @override
  List<Timetable> build() => [];

  Future<void> load() async {
    final repo = ref.read(timetableRepositoryProvider);
    state = await repo.listTimetables();
  }

  Future<Timetable> create(Timetable t) async {
    final repo = ref.read(timetableRepositoryProvider);
    final created = await repo.createTimetable(t);
    state = [created, ...state];
    return created;
  }

  Future<void> update(Timetable t) async {
    final repo = ref.read(timetableRepositoryProvider);
    await repo.updateTimetable(t);
    state = [
      for (final item in state)
        if (item.id == t.id) t else item
    ];
  }

  Future<void> delete(int id) async {
    final repo = ref.read(timetableRepositoryProvider);
    await repo.deleteTimetable(id);
    state = state.where((t) => t.id != id).toList();
  }
}

final timetablesProvider =
    NotifierProvider<TimetablesNotifier, List<Timetable>>(
        TimetablesNotifier.new);

/// 当前选中的课表 id(settings 持久化)。
final currentTimetableIdProvider = Provider<int?>((ref) {
  return ref.watch(settingsProvider).currentTimetableId;
});

final currentTimetableProvider = Provider<Timetable?>((ref) {
  final id = ref.watch(currentTimetableIdProvider);
  final list = ref.watch(timetablesProvider);
  if (list.isEmpty) return null;
  if (id != null) {
    final match = list.where((t) => t.id == id).firstOrNull;
    if (match != null) return match;
  }
  // id 未设置或已失效(如恢复备份后)→ 回退第一张
  return list.first;
});

// ── 课程与作息 ──

class CoursesNotifier extends Notifier<List<Course>> {
  int? _timetableId;

  @override
  List<Course> build() => [];

  Future<void> loadFor(int timetableId) async {
    _timetableId = timetableId;
    final repo = ref.read(timetableRepositoryProvider);
    final loaded = await repo.listCourses(timetableId);
    if (_timetableId == timetableId) state = loaded; // stale-guard
  }

  Future<void> add(Course c) async {
    final repo = ref.read(timetableRepositoryProvider);
    final inserted = await repo.insertCourse(c);
    state = [...state, inserted];
  }

  Future<void> update(Course c) async {
    final repo = ref.read(timetableRepositoryProvider);
    await repo.updateCourse(c);
    state = [
      for (final item in state)
        if (item.id == c.id) c else item
    ];
  }

  Future<void> remove(int id) async {
    final repo = ref.read(timetableRepositoryProvider);
    await repo.deleteCourse(id);
    state = state.where((c) => c.id != id).toList();
  }

  /// 无当前课表时清空列表(不触库)。
  void clear() => state = [];

  Future<void> replaceAll(List<Course> courses) async {
    if (_timetableId == null) return;
    final repo = ref.read(timetableRepositoryProvider);
    await repo.replaceCourses(_timetableId!, courses);
    state = courses;
  }
}

final coursesProvider =
    NotifierProvider<CoursesNotifier, List<Course>>(CoursesNotifier.new);

class SectionTimesNotifier extends Notifier<List<SectionTimeRow>> {
  int? _timetableId;

  @override
  List<SectionTimeRow> build() => [];

  Future<void> loadFor(int timetableId) async {
    _timetableId = timetableId;
    final repo = ref.read(timetableRepositoryProvider);
    final loaded = await repo.listSectionTimes(timetableId);
    if (_timetableId == timetableId) state = loaded; // stale-guard
  }

  Future<void> replaceAll(List<SectionTimeRow> rows) async {
    if (_timetableId == null) return;
    final repo = ref.read(timetableRepositoryProvider);
    await repo.replaceSectionTimes(_timetableId!, rows);
    state = rows;
  }

  /// 无当前课表时清空列表(不触库)。
  void clear() => state = [];
}

final sectionTimesProvider =
    NotifierProvider<SectionTimesNotifier, List<SectionTimeRow>>(
        SectionTimesNotifier.new);

// ── 应用启动时的一次性加载 ──

Future<void> bootstrapLoad(ProviderContainer container) async {
  await container.read(settingsProvider.notifier).load();
  await container.read(timetablesProvider.notifier).load();
  final current = container.read(currentTimetableIdProvider) ??
      container.read(timetablesProvider).firstOrNull?.id;
  if (current != null) {
    await container.read(coursesProvider.notifier).loadFor(current);
    await container.read(sectionTimesProvider.notifier).loadFor(current);
  }
}
