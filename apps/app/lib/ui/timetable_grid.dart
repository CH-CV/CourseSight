/// 周课表网格:节次行 × 星期列,Stack 定位课程块,支持同格多课与「现在」指示线。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../data/entities.dart';
import '../../state/providers.dart';
import 'theme.dart';

/// 默认作息在 theme.dart 中唯一定义,供网格与本页共用。
export 'theme.dart' show defaultSectionTimes;

class TimetableGrid extends ConsumerStatefulWidget {
  final List<Course> courses;
  final List<SectionTimeRow> sectionTimes;
  final int viewedWeek;
  final bool showWeekend;
  final bool showNowLine;
  final String? firstWeekMonday;
  final int weekStartDay; // 1=周一开头(默认), 7=周日开头

  const TimetableGrid({
    super.key,
    required this.courses,
    required this.sectionTimes,
    required this.viewedWeek,
    required this.showWeekend,
    required this.showNowLine,
    required this.firstWeekMonday,
    this.weekStartDay = 1,
  });

  @override
  ConsumerState<TimetableGrid> createState() => _TimetableGridState();
}

class _TimetableGridState extends ConsumerState<TimetableGrid> {
  static const double _sectionColumnWidth = 44;
  static const double _rowHeight = 56;

  // 作息与列数在每次 build 时从 widget 现算:切换课表/改设置后立即生效
  List<SectionTimeRow> get _sections => widget.sectionTimes.isEmpty
      ? defaultSectionTimes
          .map((e) => SectionTimeRow(
              timetableId: 0, section: e.$1, startTime: e.$2, endTime: e.$3))
          .toList()
      : widget.sectionTimes;

  int get _dayCount => widget.showWeekend ? 7 : 5;

  /// 每列代表的绝对星期(1=周一…7=周日),按「每周开始日」排布。
  List<int> get _columnDays {
    final start = widget.weekStartDay;
    final days = <int>[];
    for (var i = 0; i < _dayCount; i++) {
      var d = start + i;
      if (d > 7) d -= 7;
      days.add(d);
    }
    return days;
  }

  int get maxSection =>
      _sections.isEmpty ? 12 : _sections.map((s) => s.section).reduce((a, b) => a > b ? a : b);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final todayDow = DateTime.now().weekday; // 1-7
    final gridBodyHeight = maxSection * _rowHeight;

    return SingleChildScrollView(
      child: SizedBox(
        width: double.infinity,
        child: Column(
          children: [
            // ── 星期表头 ──
            Row(
              children: [
                const SizedBox(width: _sectionColumnWidth),
                for (final d in _columnDays)
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      decoration: BoxDecoration(
                        color: _isToday(d, todayDow)
                            ? scheme.primaryContainer
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        children: [
                          Text(weekDayNames[d - 1],
                              style: const TextStyle(
                                  fontSize: 12, fontWeight: FontWeight.bold)),
                          Text(_dateLabel(d), style: const TextStyle(fontSize: 10)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            // ── 网格主体 ──
            SizedBox(
              height: gridBodyHeight.toDouble(),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 节次列
                  SizedBox(
                    width: _sectionColumnWidth,
                    child: Column(
                      children: [
                        for (final s in _sections)
                          SizedBox(
                            height: _rowHeight,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text('${s.section}',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold, fontSize: 13)),
                                Text(s.startTime,
                                    style: TextStyle(
                                        fontSize: 9,
                                        color: scheme.onSurfaceVariant)),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  // 每天一列(按「每周开始日」排布)
                  for (final d in _columnDays)
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          return Container(
                            decoration: BoxDecoration(
                              border: Border(
                                left: BorderSide(
                                    color: scheme.outlineVariant, width: 0.5),
                              ),
                            ),
                            child: Stack(
                              children: [
                                // 节次横线
                                for (var i = 1; i < maxSection; i++)
                                  Positioned(
                                    top: i * _rowHeight - 0.5,
                                    left: 0,
                                    right: 0,
                                    child: Container(
                                      height: 0.5,
                                      color: scheme.outlineVariant,
                                    ),
                                  ),
                                // 今日高亮底色
                                if (_isToday(d, todayDow))
                                  Positioned.fill(
                                    child: ColoredBox(
                                        color: scheme.primaryContainer
                                            .withValues(alpha: 0.25)),
                                  ),
                                // 「现在」指示线
                                if (widget.showNowLine &&
                                    _isToday(d, todayDow) &&
                                    _nowLineTop() != null)
                                  Positioned(
                                    top: _nowLineTop()!,
                                    left: 0,
                                    right: 0,
                                    child: Container(
                                      height: 2,
                                      color: scheme.error,
                                    ),
                                  ),
                                // 课程块下的空白点击层(不拦截课程块:块在其上)
                                Positioned.fill(
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.translucent,
                                    onTapUp: (details) =>
                                        _onEmptyTap(context, d, details.localPosition.dy),
                                  ),
                                ),
                                // 课程块
                                ..._courseBlocks(context, d, constraints.maxWidth),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool _isToday(int day, int todayDow) =>
      day == todayDow &&
      widget.viewedWeek == _currentWeekOfTimetable();

  int? _currentWeekOfTimetable() {
    final t = ref.read(currentTimetableProvider);
    return t?.currentWeek(DateTime.now(),
        weekStartDay: widget.weekStartDay);
  }

  String _dateLabel(int day) {
    final anchor = widget.firstWeekMonday;
    if (anchor == null) return '';
    try {
      final first = DateTime.parse(anchor);
      // 锚点回退到所在周的周首,再按「列的绝对星期与周首的偏移」定位
      var back = first.weekday - widget.weekStartDay;
      if (back < 0) back += 7;
      final weekStart =
          DateTime(first.year, first.month, first.day).subtract(Duration(days: back));
      var colOffset = day - widget.weekStartDay;
      if (colOffset < 0) colOffset += 7;
      final date = weekStart
          .add(Duration(days: (widget.viewedWeek - 1) * 7 + colOffset));
      return DateFormat('M/d').format(date);
    } catch (_) {
      return '';
    }
  }

  double? _nowLineTop() {
    final now = DateTime.now();
    final minutes = now.hour * 60 + now.minute;
    for (final s in _sections) {
      final startParts = s.startTime.split(':');
      final endParts = s.endTime.split(':');
      if (startParts.length != 2 || endParts.length != 2) continue;
      final sh = int.tryParse(startParts[0]);
      final sm = int.tryParse(startParts[1]);
      final eh = int.tryParse(endParts[0]);
      final em = int.tryParse(endParts[1]);
      if (sh == null || sm == null || eh == null || em == null) continue;
      final startMin = sh * 60 + sm;
      final endMin = eh * 60 + em;
      if (endMin <= startMin) continue;
      if (minutes >= startMin && minutes <= endMin) {
        final sectionIdx = _sections.indexOf(s);
        final fraction = (minutes - startMin) / (endMin - startMin);
        return (sectionIdx + fraction) * _rowHeight;
      }
    }
    return null;
  }

  /// 生成某天的课程块;节次重叠的课水平切分(列分配:区间图着色的贪心版)。
  List<Widget> _courseBlocks(BuildContext context, int day, double colWidth) {
    final inWeek = widget.courses
        .where((c) => c.dayOfWeek == day && c.inWeek(widget.viewedWeek))
        .toList()
      ..sort((a, b) => a.startSection.compareTo(b.startSection));

    final widgets = <Widget>[];
    if (inWeek.isEmpty) return widgets;

    // 每列记录已占节次;冲突则另起一列
    final occupied = <List<List<int>>>[]; // 每列:若干 [start,end] 区间
    final colOf = <int>[];
    for (final c in inWeek) {
      var col = 0;
      while (true) {
        if (col >= occupied.length) {
          occupied.add([]);
          break;
        }
        final clash = occupied[col]
            .any((e) => c.startSection <= e[1] && e[0] <= c.endSection);
        if (!clash) break;
        col++;
      }
      occupied[col].add([c.startSection, c.endSection]);
      colOf.add(col);
    }
    final totalColumns = occupied.length;
    final w = colWidth / totalColumns;

    for (var i = 0; i < inWeek.length; i++) {
      final c = inWeek[i];
      widgets.add(Positioned(
        top: (c.startSection - 1) * _rowHeight + 1.5,
        left: colOf[i] * w + 1,
        width: w - 2,
        height: (c.endSection - c.startSection + 1) * _rowHeight - 3,
        child: _CourseBlock(
          course: c,
          onTap: () => _showDetail(context, c),
          onLongPress: () => _editCourse(context, c),
        ),
      ));
    }
    return widgets;
  }

  /// 点击空白格:预填星期与节次新建课程。
  void _onEmptyTap(BuildContext context, int day, double localY) {
    final section = (localY / _rowHeight).floor() + 1;
    if (section < 1 || section > maxSection) return;
    context.push('/course/edit', extra: {'day': day, 'section': section});
  }

  void _showDetail(BuildContext context, Course c) {
    final t = ref.read(currentTimetableProvider);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(c.name, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              _detailRow(Icons.person, c.teacher ?? '—'),
              _detailRow(Icons.place, c.location ?? '—'),
              _detailRow(Icons.schedule,
                  '周${weekDayNames[c.dayOfWeek - 1].substring(1)} 第${c.startSection}-${c.endSection}节'),
              _detailRow(Icons.event_repeat, _weeksLabel(c)),
              if (t?.firstWeekMonday != null &&
                  t!.currentWeek(DateTime.now(),
                          weekStartDay: widget.weekStartDay) !=
                      null)
                _detailRow(Icons.today,
                    '第 ${t.currentWeek(DateTime.now(), weekStartDay: widget.weekStartDay)} 周 · ${weekDayNames[c.dayOfWeek - 1]}'),
              const SizedBox(height: 12),
              Row(
                children: [
                  FilledButton.tonalIcon(
                    onPressed: () {
                      Navigator.pop(context);
                      _editCourse(context, c);
                    },
                    icon: const Icon(Icons.edit),
                    label: const Text('编辑'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonalIcon(
                    onPressed: () {
                      Navigator.pop(context);
                      _deleteCourse(context, c);
                    },
                    icon: const Icon(Icons.delete),
                    label: const Text('删除'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _weeksLabel(Course c) {
    switch (c.weekType) {
      case 'odd':
        return '单周(${c.weeks.length}周)';
      case 'even':
        return '双周(${c.weeks.length}周)';
      case 'all':
        return '全学期';
      default:
        return '${c.weeks.first}-${c.weeks.last}周(共${c.weeks.length}周)';
    }
  }

  Widget _detailRow(IconData icon, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Icon(icon, size: 16),
            const SizedBox(width: 8),
            Expanded(child: Text(text)),
          ],
        ),
      );

  void _editCourse(BuildContext context, Course c) {
    context.push('/course/edit', extra: {'courseId': c.id});
  }

  void _deleteCourse(BuildContext context, Course c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除课程'),
        content: Text('确定删除「${c.name}」吗?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok == true && c.id != null) {
      await ref.read(coursesProvider.notifier).remove(c.id!);
    }
  }
}

class _CourseBlock extends StatelessWidget {
  final Course course;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _CourseBlock({
    required this.course,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final color = courseColor(course.colorIndex);
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                course.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87),
              ),
              if (course.location != null)
                Text(
                  course.location!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10, color: Colors.black54),
                ),
              const Spacer(),
              Text(
                _weekTag(course.weekType),
                style: const TextStyle(fontSize: 9, color: Colors.black54),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _weekTag(String weekType) {
    switch (weekType) {
      case 'odd':
        return '(单)';
      case 'even':
        return '(双)';
      default:
        return '';
    }
  }
}
