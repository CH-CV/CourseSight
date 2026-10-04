/// 课表管理:新建 / 切换 / 重命名 / 删除。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/entities.dart';
import '../../logic/reminder_service.dart';
import '../../state/providers.dart';

Future<void> showManageTimetablesDialog(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => const _ManageTimetablesSheet(),
  );
}

class _ManageTimetablesSheet extends ConsumerStatefulWidget {
  const _ManageTimetablesSheet();

  @override
  ConsumerState<_ManageTimetablesSheet> createState() =>
      _ManageTimetablesSheetState();
}

class _ManageTimetablesSheetState extends ConsumerState<_ManageTimetablesSheet> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => ref.read(timetablesProvider.notifier).load());
  }

  @override
  Widget build(BuildContext context) {
    final timetables = ref.watch(timetablesProvider);
    final currentId = ref.watch(currentTimetableIdProvider);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('课表管理', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                FilledButton.tonalIcon(
                  onPressed: () => _create(context),
                  icon: const Icon(Icons.add),
                  label: const Text('新建'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (timetables.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('还没有课表'),
              ),
            for (final t in timetables)
              ListTile(
                leading: Icon(
                  t.id == currentId ? Icons.radio_button_checked : Icons.radio_button_off,
                  color: t.id == currentId
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
                title: Text(t.name),
                subtitle: Text(
                    '${t.totalWeeks} 周'
                    '${t.firstWeekMonday != null ? ' · ${t.firstWeekMonday} 开学' : ''}'),
                onTap: () => _switchTo(t),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                        icon: const Icon(Icons.edit),
                        onPressed: () => _rename(context, t)),
                    IconButton(
                        icon: const Icon(Icons.delete),
                        onPressed: () => _delete(context, t)),
                  ],
                ),
              ),
            const SizedBox(height: 4),
            const Text('数据仅存本机,卸载前请先备份(设置 → 数据)。',
                style: TextStyle(fontSize: 11)),
          ],
        ),
      ),
    );
  }

  Future<void> _switchTo(Timetable t) async {
    if (t.id == null) return;
    await ref.read(settingsProvider.notifier).set('current_timetable_id', '${t.id}');
    await ref.read(coursesProvider.notifier).loadFor(t.id!);
    await ref.read(sectionTimesProvider.notifier).loadFor(t.id!);
    await refreshAfterChange();
    if (mounted) Navigator.pop(context);
  }

  Future<void> _create(BuildContext context) async {
    final controller = TextEditingController(text: '我的课表');
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建课表'),
        content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: '名称')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('创建')),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;
    final created =
        await ref.read(timetablesProvider.notifier).create(Timetable(name: name));
    await _switchTo(created);
  }

  Future<void> _rename(BuildContext context, Timetable t) async {
    final controller = TextEditingController(text: t.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('确定')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await ref
        .read(timetablesProvider.notifier)
        .update(Timetable(id: t.id, name: name, firstWeekMonday: t.firstWeekMonday, totalWeeks: t.totalWeeks));
    controller.dispose();
  }

  Future<void> _delete(BuildContext context, Timetable t) async {
    if (t.id == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除课表'),
        content: Text('确定删除「${t.name}」及其全部课程吗?此操作不可撤销。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(timetablesProvider.notifier).delete(t.id!);
    // 若删的是当前表,切到第一张
    final settings = ref.read(settingsProvider);
    if (settings.currentTimetableId == t.id) {
      final first = ref.read(timetablesProvider).firstOrNull;
      if (first?.id != null) {
        await _switchTo(first!);
      } else {
        await ref.read(settingsProvider.notifier).remove('current_timetable_id');
        ref.read(coursesProvider.notifier).clear();
        ref.read(sectionTimesProvider.notifier).clear();
        await refreshAfterChange();
      }
    } else {
      await refreshAfterChange();
    }
  }
}
