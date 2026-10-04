/// 周课表主页:周次切换 + 课表网格 + 菜单(导入/课表管理/设置)。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../state/providers.dart';
import 'timetable_grid.dart';
import 'widgets/manage_timetables_dialog.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final timetable = ref.watch(currentTimetableProvider);
    final courses = ref.watch(coursesProvider);
    final sections = ref.watch(sectionTimesProvider);
    final settings = ref.watch(settingsProvider);

    // 有效周数:无课表时给 1,便于空态渲染
    final totalWeeks = timetable?.totalWeeks ?? 1;
    final currentWeek =
        timetable?.currentWeek(DateTime.now(), weekStartDay: settings.weekStartDay);
    final viewed = ref.watch(viewedWeekProvider) ?? currentWeek ?? 1;

    ref.listen(currentTimetableIdProvider, (prev, next) {
      // 切换课表后刷新周视图到"今天"
      ref.read(viewedWeekProvider.notifier).set(null);
    });

    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          onTap: () => showManageTimetablesDialog(context),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  timetable?.name ?? '课见',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const Icon(Icons.keyboard_arrow_down, size: 20),
            ],
          ),
        ),
        actions: [
          IconButton(
            tooltip: '导入课表',
            icon: const Icon(Icons.add),
            onPressed: () => context.push('/import'),
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              switch (value) {
                case 'import':
                  context.push('/import');
                case 'manage':
                  showManageTimetablesDialog(context);
                case 'settings':
                  context.push('/settings');
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'import', child: Text('导入课表')),
              PopupMenuItem(value: 'manage', child: Text('课表管理')),
              PopupMenuItem(value: 'settings', child: Text('设置')),
            ],
          ),
        ],
      ),
      body: timetable == null
          ? _EmptyState(onImport: () => context.push('/import'))
          : Column(
              children: [
                _WeekSwitcher(
                  totalWeeks: totalWeeks,
                  currentWeek: currentWeek,
                  viewedWeek: viewed.clamp(1, totalWeeks),
                  onChanged: (w) =>
                      ref.read(viewedWeekProvider.notifier).set(w),
                ),
                Expanded(
                  child: courses.isEmpty
                      ? _NoCoursesHint(onImport: () => context.push('/import'))
                      : TimetableGrid(
                          courses: courses,
                          sectionTimes: sections,
                          viewedWeek: viewed.clamp(1, totalWeeks),
                          showWeekend: settings.showWeekend,
                          showNowLine: settings.showNowLine,
                          firstWeekMonday: timetable.firstWeekMonday,
                          weekStartDay: settings.weekStartDay,
                        ),
                ),
              ],
            ),
      floatingActionButton: timetable == null
          ? null
          : FloatingActionButton(
              onPressed: () => context.push('/course/edit'),
              child: const Icon(Icons.edit_calendar),
            ),
    );
  }
}

class _WeekSwitcher extends StatelessWidget {
  final int totalWeeks;
  final int? currentWeek;
  final int viewedWeek;
  final ValueChanged<int> onChanged;

  const _WeekSwitcher({
    required this.totalWeeks,
    required this.currentWeek,
    required this.viewedWeek,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isCurrentWeek = currentWeek == viewedWeek;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: viewedWeek > 1 ? () => onChanged(viewedWeek - 1) : null,
          ),
          GestureDetector(
            onTap: () => _pickWeek(context),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                    color: isCurrentWeek ? scheme.primary : scheme.outline),
              ),
              child: Text(
                '第 $viewedWeek 周 / 共 $totalWeeks 周',
                style: TextStyle(
                  fontSize: 13,
                  color: isCurrentWeek ? scheme.primary : null,
                  fontWeight:
                      isCurrentWeek ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed:
                viewedWeek < totalWeeks ? () => onChanged(viewedWeek + 1) : null,
          ),
          if (!isCurrentWeek && currentWeek != null)
            TextButton(
              onPressed: () => onChanged(currentWeek!),
              child: const Text('回到本周'),
            ),
        ],
      ),
    );
  }

  Future<void> _pickWeek(BuildContext context) async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var w = 1; w <= totalWeeks; w++)
                OutlinedButton(
                  onPressed: () => Navigator.pop(context, w),
                  child: Text('$w'),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked != null) onChanged(picked);
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onImport;
  const _EmptyState({required this.onImport});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.calendar_month, size: 72, color: scheme.primary),
            const SizedBox(height: 16),
            Text('课见 · 看得见的课表',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text(
              '用 AI 读懂任意学校的教务课表,\n开源。',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onImport,
              icon: const Icon(Icons.cloud_download),
              label: const Text('从教务系统导入'),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoCoursesHint extends StatelessWidget {
  final VoidCallback onImport;
  const _NoCoursesHint({required this.onImport});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('这学期还是空的'),
          const SizedBox(height: 8),
          FilledButton.tonal(
            onPressed: onImport,
            child: const Text('导入课表'),
          ),
        ],
      ),
    );
  }
}

/// 供小组件与提醒使用的日期格式化入口。
String formatDate(DateTime d) => DateFormat('yyyy-MM-dd').format(d);
