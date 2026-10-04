/// 课程编辑/新建页:全字段表单 + 周次多选 + 颜色选择。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/entities.dart';
import '../logic/reminder_service.dart';
import '../state/providers.dart';
import 'theme.dart';

class CourseEditScreen extends ConsumerStatefulWidget {
  /// 非空 = 编辑已有课程;空 = 新建(可用 presetDay/Section 预填)。
  final int? courseId;
  final int? presetDay;
  final int? presetSection;

  const CourseEditScreen({super.key, this.courseId, this.presetDay, this.presetSection});

  @override
  ConsumerState<CourseEditScreen> createState() => _CourseEditScreenState();
}

class _CourseEditScreenState extends ConsumerState<CourseEditScreen> {
  final _nameController = TextEditingController();
  final _teacherController = TextEditingController();
  final _locationController = TextEditingController();
  final _noteController = TextEditingController();

  int _day = 1;
  int _startSection = 1;
  int _endSection = 2;
  Set<int> _weeks = {};
  int _colorIndex = 0;

  Course? _editing;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  void _init() {
    final timetable = ref.read(currentTimetableProvider);
    final sections = ref.read(sectionTimesProvider);
    final maxSection = sections.isEmpty
        ? 12
        : sections.map((s) => s.section).reduce((a, b) => a > b ? a : b);
    final totalWeeks = timetable?.totalWeeks ?? 20;

    setState(() {
      _weeks = Set<int>.from(List.generate(totalWeeks, (i) => i + 1));
      _day = (widget.presetDay ?? 1).clamp(1, 7);
      _startSection = (widget.presetSection ?? 1).clamp(1, maxSection);
      _endSection = (widget.presetSection ?? 2).clamp(1, maxSection);
      if (_endSection < _startSection) _endSection = _startSection;
    });

    if (widget.courseId != null) {
      final course = ref
          .read(coursesProvider)
          .where((c) => c.id == widget.courseId)
          .firstOrNull;
      if (course != null) {
        _editing = course;
        _nameController.text = course.name;
        _teacherController.text = course.teacher ?? '';
        _locationController.text = course.location ?? '';
        _noteController.text = course.note ?? '';
        setState(() {
          _day = course.dayOfWeek;
          _startSection = course.startSection;
          _endSection = course.endSection;
          _weeks = Set<int>.from(course.weeks);
          _colorIndex = course.colorIndex;
        });
      }
    } else {
      _colorIndex = _guessColor();
    }
    _initialized = true;
  }

  int _guessColor() {
    final name = _nameController.text.trim();
    return name.isEmpty ? 0 : name.hashCode.abs();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _teacherController.dispose();
    _locationController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final timetable = ref.watch(currentTimetableProvider);
    final sections = ref.watch(sectionTimesProvider);
    final maxSection = sections.isEmpty
        ? 12
        : sections.map((s) => s.section).reduce((a, b) => a > b ? a : b);

    if (!_initialized) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    return Scaffold(
      appBar: AppBar(
        title: Text(_editing == null ? '新建课程' : '编辑课程'),
        actions: [
          IconButton(icon: const Icon(Icons.check), onPressed: _save),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
                labelText: '课程名 *', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _teacherController,
                  decoration: const InputDecoration(
                      labelText: '教师', border: OutlineInputBorder()),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _locationController,
                  decoration: const InputDecoration(
                      labelText: '地点', border: OutlineInputBorder()),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // 星期
          Wrap(
            spacing: 8,
            children: [
              for (var d = 1; d <= 7; d++)
                ChoiceChip(
                  label: Text(weekDayNames[d - 1]),
                  selected: _day == d,
                  onSelected: (_) => setState(() => _day = d),
                ),
            ],
          ),
          const SizedBox(height: 16),
          // 节次
          Row(
            children: [
              Expanded(
                child: InputDecorator(
                  decoration: const InputDecoration(
                      labelText: '开始节次', border: OutlineInputBorder()),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<int>(
                      value: _startSection.clamp(1, maxSection),
                      isDense: true,
                      isExpanded: true,
                      items: [
                        for (var s = 1; s <= maxSection; s++)
                          DropdownMenuItem(value: s, child: Text('第 $s 节'))
                      ],
                      onChanged: (v) => setState(() {
                        _startSection = v ?? 1;
                        if (_endSection < _startSection) _endSection = _startSection;
                      }),
                    ),
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Text('—'),
              ),
              Expanded(
                child: InputDecorator(
                  decoration: const InputDecoration(
                      labelText: '结束节次', border: OutlineInputBorder()),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<int>(
                      value: _endSection.clamp(1, maxSection),
                      isDense: true,
                      isExpanded: true,
                      items: [
                        for (var s = 1; s <= maxSection; s++)
                          DropdownMenuItem(value: s, child: Text('第 $s 节'))
                      ],
                      onChanged: (v) => setState(() {
                        _endSection = v ?? 1;
                        if (_endSection < _startSection) _endSection = _startSection;
                      }),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // 周次快捷 + 明细
          Row(
            children: [
              Text('上课周次', style: Theme.of(context).textTheme.titleSmall),
              const Spacer(),
              TextButton(
                  onPressed: () => setState(() => _weeks = Set<int>.from(
                      List.generate(timetable?.totalWeeks ?? 20, (i) => i + 1))),
                  child: const Text('全部')),
              TextButton(
                  onPressed: () => setState(() => _weeks = {
                        for (var w = 1; w <= (timetable?.totalWeeks ?? 20); w++)
                          if (w.isOdd) w
                      }),
                  child: const Text('单周')),
              TextButton(
                  onPressed: () => setState(() => _weeks = {
                        for (var w = 1; w <= (timetable?.totalWeeks ?? 20); w++)
                          if (w.isEven) w
                      }),
                  child: const Text('双周')),
            ],
          ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var w = 1; w <= (timetable?.totalWeeks ?? 20); w++)
                FilterChip(
                  label: Text('$w'),
                  selected: _weeks.contains(w),
                  onSelected: (selected) => setState(() {
                    selected ? _weeks.add(w) : _weeks.remove(w);
                  }),
                ),
            ],
          ),
          const SizedBox(height: 16),
          // 颜色
          Text('颜色', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (var i = 0; i < coursePalette.length; i++)
                GestureDetector(
                  onTap: () => setState(() => _colorIndex = i),
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: courseColor(i),
                      shape: BoxShape.circle,
                      border: _colorIndex == i
                          ? Border.all(
                              color: Theme.of(context).colorScheme.primary,
                              width: 3)
                          : null,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _noteController,
            decoration: const InputDecoration(
                labelText: '备注', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 24),
          if (_editing != null)
            OutlinedButton.icon(
              onPressed: _delete,
              icon: const Icon(Icons.delete),
              label: const Text('删除这门课'),
            ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('课程名不能为空')));
      return;
    }
    if (_weeks.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请至少选择一个上课周')));
      return;
    }
    var timetable = ref.read(currentTimetableProvider);
    final coursesNotifier = ref.read(coursesProvider.notifier);

    // 没有课表时先创建一张
    if (timetable == null) {
      timetable = await ref.read(timetablesProvider.notifier).create(
          Timetable(name: '我的课表'));
      await ref
          .read(settingsProvider.notifier)
          .set('current_timetable_id', '${timetable.id}');
      await ref.read(timetablesProvider.notifier).load();
    }

    if (_editing != null && _editing!.id != null) {
      final updated = Course(
        id: _editing!.id,
        timetableId: _editing!.timetableId,
        name: name,
        teacher: _teacherController.text.trim(),
        location: _locationController.text.trim(),
        dayOfWeek: _day,
        startSection: _startSection,
        endSection: _endSection,
        weeks: _weeks.toList()..sort(),
        weekType: _inferType(_weeks, timetable.totalWeeks),
        colorIndex: _colorIndex,
        note: _noteController.text.trim(),
      );
      await coursesNotifier.update(updated);
    } else {
      await coursesNotifier.add(Course(
        timetableId: timetable.id!,
        name: name,
        teacher: _teacherController.text.trim(),
        location: _locationController.text.trim(),
        dayOfWeek: _day,
        startSection: _startSection,
        endSection: _endSection,
        weeks: _weeks.toList()..sort(),
        weekType: _inferType(_weeks, timetable.totalWeeks),
        colorIndex: _colorIndex,
        note: _noteController.text.trim(),
      ));
    }

    await refreshAfterChange();
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已保存「$name」')));
      context.pop();
    }
  }

  Future<void> _delete() async {
    if (_editing?.id == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除课程'),
        content: Text('确定删除「${_editing!.name}」吗?此操作不可撤销。'),
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
    await ref.read(coursesProvider.notifier).remove(_editing!.id!);
    await refreshAfterChange();
    if (mounted) context.pop();
  }

  static String _inferType(Set<int> weeks, int totalWeeks) {
    final list = weeks.toList()..sort();
    if (list.isEmpty) return 'all';
    if (list.length == totalWeeks && list.first == 1 && list.last == totalWeeks) {
      return 'all';
    }
    if (list.every((w) => w.isOdd)) return 'odd';
    if (list.every((w) => w.isEven)) return 'even';
    return 'custom';
  }
}
