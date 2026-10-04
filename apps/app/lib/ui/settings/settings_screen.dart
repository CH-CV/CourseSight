/// 设置页:LLM / 学期 / 作息 / 提醒 / 外观 / 数据 / 关于。
library;

import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/entities.dart';
import '../../logic/reminder_service.dart';
import '../../state/providers.dart';
import '../import/llm_config_panel.dart';

/// 解析已存的开学日(兼容 2026-09-07 / 2026/9/7 / 2026.9.7),非法返回 null。
DateTime? _tryParseDate(String? raw) {
  if (raw == null) return null;
  final m = RegExp(r'^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})$')
      .firstMatch(raw.trim());
  if (m == null) return null;
  final d = DateTime(
      int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
  if (d.isBefore(DateTime(2020)) || d.isAfter(DateTime(2100))) return null;
  return d;
}

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final timetable = ref.watch(currentTimetableProvider);
    final sections = ref.watch(sectionTimesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          _sectionHeader(context, 'AI 服务(BYOK)'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: LlmConfigPanel(),
          ),
          const Divider(height: 32),

          _sectionHeader(context, '学期'),
          ListTile(
            title: const Text('第一教学周开始日'),
            subtitle: Text(timetable?.firstWeekMonday ?? '未设置,无法推算第几周'),
            trailing: const Icon(Icons.calendar_today),
            onTap: () async {
              final current = timetable;
              if (current?.id == null) return;
              final picked = await showDatePicker(
                context: context,
                helpText: '选择第一教学周的起始日(任意星期几)',
                initialDate: _tryParseDate(current!.firstWeekMonday) ??
                    DateTime.now(),
                firstDate: DateTime(2020),
                lastDate: DateTime(2100),
              );
              if (picked == null) return;
              // 学校声明哪天开学就存哪天,不强制对齐到周一
              final updated = Timetable(
                id: current.id,
                name: current.name,
                firstWeekMonday:
                    '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}',
                totalWeeks: current.totalWeeks,
              );
              await ref.read(timetablesProvider.notifier).update(updated);
              await refreshAfterChange();
            },
          ),
          ListTile(
            title: const Text('每周开始于'),
            subtitle: const Text('该校课表周次按周几起算,影响第几周推算'),
            trailing: DropdownButton<int>(
              value: settings.weekStartDay,
              items: const [
                DropdownMenuItem(value: 1, child: Text('周一')),
                DropdownMenuItem(value: 7, child: Text('周日')),
              ],
              onChanged: (v) async {
                if (v == null) return;
                await ref
                    .read(settingsProvider.notifier)
                    .set('week_start_day', '$v');
                await refreshAfterChange();
              },
            ),
          ),
          ListTile(
            title: const Text('学期总周数'),
            subtitle: Text('${timetable?.totalWeeks ?? 20} 周'),
            trailing: SizedBox(
              width: 100,
              child: TextFormField(
                initialValue: '${timetable?.totalWeeks ?? 20}',
                keyboardType: TextInputType.number,
                onFieldSubmitted: (value) async {
                  final weeks = int.tryParse(value);
                  if (weeks == null || weeks < 1 || weeks > 60) return;
                  if (timetable?.id == null) return;
                  final updated = Timetable(
                    id: timetable!.id,
                    name: timetable.name,
                    firstWeekMonday: timetable.firstWeekMonday,
                    totalWeeks: weeks,
                  );
                  await ref
                      .read(timetablesProvider.notifier)
                      .update(updated);
                  await refreshAfterChange();
                },
              ),
            ),
          ),
          const Divider(height: 32),

          _sectionHeader(context, '作息时间'),
          ListTile(
            title: Text('${sections.isEmpty ? 12 : sections.length} 节(点开编辑)'),
            trailing: const Icon(Icons.edit),
            onTap: () => _editSections(context, sections),
          ),
          const Divider(height: 32),

          _sectionHeader(context, '提醒'),
          SwitchListTile(
            title: const Text('上课提醒'),
            subtitle: const Text('本地通知,课前提醒(默认提前 15 分钟)'),
            value: settings.reminderEnabled,
            onChanged: (v) async {
              await ref
                  .read(settingsProvider.notifier)
                  .set('reminder_enabled', '$v');
              if (v) await ReminderService.instance.ensurePermission();
              await refreshAfterChange();
            },
          ),
          ListTile(
            title: const Text('提醒提前量'),
            trailing: DropdownButton<int>(
              value: settings.reminderLeadMinutes,
              items: [
                for (final m in [0, 5, 10, 15, 20, 30])
                  DropdownMenuItem(value: m, child: Text('$m 分钟')),
              ],
              onChanged: (v) async {
                await ref
                    .read(settingsProvider.notifier)
                    .set('reminder_lead_minutes', '$v');
                await refreshAfterChange();
              },
            ),
          ),
          const Divider(height: 32),

          SwitchListTile(
            title: const Text('信任自签名证书'),
            subtitle: const Text('仅在校内教务系统证书报错时开启,风险自担'),
            value: settings.get('trust_self_signed_cert') == 'true',
            onChanged: (v) => ref
                .read(settingsProvider.notifier)
                .set('trust_self_signed_cert', '$v'),
          ),
          const Divider(height: 32),

          _sectionHeader(context, '外观'),
          SwitchListTile(
            title: const Text('显示周末'),
            value: settings.showWeekend,
            onChanged: (v) =>
                ref.read(settingsProvider.notifier).set('show_weekend', '$v'),
          ),
          SwitchListTile(
            title: const Text('显示「现在」指示线'),
            value: settings.showNowLine,
            onChanged: (v) =>
                ref.read(settingsProvider.notifier).set('show_now_line', '$v'),
          ),
          const Divider(height: 32),

          _sectionHeader(context, '数据'),
          ListTile(
            title: const Text('备份导出'),
            subtitle: const Text('课表数据导出为 JSON 文件'),
            trailing: const Icon(Icons.ios_share),
            onTap: () => _exportBackup(),
          ),
          ListTile(
            title: const Text('备份导入'),
            subtitle: const Text('从 JSON 文件恢复'),
            trailing: const Icon(Icons.file_open),
            onTap: () => _importBackup(),
          ),
          const Divider(height: 32),

          _sectionHeader(context, '关于'),
          const ListTile(
            title: Text('课见 CourseSight'),
            subtitle: Text('v0.1.0 · 开源(MIT)'),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Text(title,
            style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.bold,
                fontSize: 13)),
      );

  Future<void> _editSections(
      BuildContext context, List<SectionTimeRow> sections) async {
    final timetable = ref.read(currentTimetableProvider);
    if (timetable?.id == null) return;
    final controller = TextEditingController(
      text: sections
          .map((s) => '${s.section},${s.startTime},${s.endTime}')
          .join('\n'),
    );
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('作息时间(每行:节次,开始,结束)'),
        content: SizedBox(
          width: double.maxFinite,
          child: TextField(
            controller: controller,
            maxLines: 14,
            decoration: const InputDecoration(
              hintText: '1,08:00,08:45\n2,08:55,09:40\n…',
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    final rows = <SectionTimeRow>[];
    for (final line in controller.text.split('\n')) {
      final parts = line.split(',');
      if (parts.length != 3) continue;
      final section = int.tryParse(parts[0].trim());
      if (section == null) continue;
      rows.add(SectionTimeRow(
        timetableId: timetable!.id!,
        section: section,
        startTime: parts[1].trim(),
        endTime: parts[2].trim(),
      ));
    }
    if (rows.isNotEmpty) {
      await ref.read(sectionTimesProvider.notifier).replaceAll(rows);
      await refreshAfterChange();
    }
  }

  Future<void> _exportBackup() async {
    try {
      final repo = ref.read(timetableRepositoryProvider);
      final timetables = await repo.listTimetables();
      final payload = <String, dynamic>{
        'schemaVersion': 1,
        'app': 'CourseSight',
        'exportedAt': DateTime.now().toIso8601String(),
        'timetables': [for (final t in timetables) t.toRow()],
        'courses': [],
        'timeConfig': [],
      };
      for (final t in timetables) {
        if (t.id == null) continue;
        payload['courses'] = [
          ...(payload['courses'] as List),
          for (final c in await repo.listCourses(t.id!)) c.toRow(),
        ];
        payload['timeConfig'] = [
          ...(payload['timeConfig'] as List),
          for (final s in await repo.listSectionTimes(t.id!)) s.toRow(),
        ];
      }
      final text = const JsonEncoder.withIndent('  ').convert(payload);
      final dir = await getTemporaryDirectory();
      final file = File(
          '${dir.path}/coursesight_backup_${DateTime.now().millisecondsSinceEpoch}.json');
      await file.writeAsString(text);
      if (!mounted) return;
      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path)],
        title: 'CourseSight 备份',
      ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导出失败:$e')));
      }
    }
  }

  Future<void> _importBackup() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (files.isEmpty) return;
    final bytes = await files.first.readAsBytes();
    try {
      final data = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (data['schemaVersion'] != 1) {
        throw const FormatException('备份版本不兼容');
      }
      final repo = ref.read(timetableRepositoryProvider);
      final nameToId = await repo.restoreBackup(
        timetables: (data['timetables'] as List? ?? [])
            .whereType<Map<String, dynamic>>()
            .toList(),
        courses: (data['courses'] as List? ?? [])
            .whereType<Map<String, dynamic>>()
            .toList(),
        timeConfig: (data['timeConfig'] as List? ?? [])
            .whereType<Map<String, dynamic>>()
            .toList(),
      );
      await ref.read(timetablesProvider.notifier).load();
      await refreshAfterChange();
      // 恢复后切到备份中课程最多的一张表
      String? bestName;
      var bestCount = -1;
      final counts = <String, int>{};
      for (final cRow in (data['courses'] as List? ?? [])) {
        final name = (data['timetables'] as List)
            .whereType<Map>()
            .where((t) => t['id'] == (cRow as Map)['timetable_id'])
            .map((t) => t['name'] as String?)
            .firstOrNull;
        if (name == null) continue;
        counts[name] = (counts[name] ?? 0) + 1;
        if (counts[name]! > bestCount) {
          bestCount = counts[name]!;
          bestName = name;
        }
      }
      final newId = bestName != null ? nameToId[bestName] : null;
      if (newId != null) {
        await ref
            .read(settingsProvider.notifier)
            .set('current_timetable_id', '$newId');
        await ref.read(coursesProvider.notifier).loadFor(newId);
        await ref.read(sectionTimesProvider.notifier).loadFor(newId);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('已恢复 ${nameToId.length} 张课表,共 $bestCount+ 门课程')));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导入失败:$e')));
      }
    }
  }
}
