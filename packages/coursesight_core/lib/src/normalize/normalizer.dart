/// 规范化:作息补全、节次互换修正。**不重排课程顺序**——
/// 警告的 courseIndex 以校验阶段(合并后)的下标为准,排序会让下标错位。
library;

import '../model/models.dart';
import '../validate/validator.dart' show defaultSectionTimes;

/// 输入草稿,输出可直接入库的规范化课表(纯函数)。
TimetableData normalize(TimetableData draft) {
  // 作息表:缺失或不足时用默认模板补齐
  var times = List<SectionTime>.from(draft.timeConfig);
  if (times.isEmpty) times = List.from(defaultSectionTimes);
  times.sort((a, b) => a.section.compareTo(b.section));

  final courses = <CourseData>[];
  for (final c in draft.courses) {
    var fixed = c;
    if (c.endSection < c.startSection) {
      fixed = fixed.copyWith(
          startSection: c.endSection, endSection: c.startSection);
    }
    courses.add(fixed);
  }

  return draft.copyWith(timeConfig: times, courses: courses);
}

/// 计算某日期是学期第几周。
/// [firstWeekStart] 是第一教学周的开始日(由学校决定,不一定是周一);
/// [weekStartDay] 是该校一周的第一天(1=周一,7=周日)。
/// 锚点日对齐到所在周的 [weekStartDay] 起算,该周为第 1 周;
/// [date] 早于第一周返回 0。
int weekOfDate(String firstWeekStart, DateTime date, {int weekStartDay = 1}) {
  final anchor = DateTime.parse(firstWeekStart);
  // 把锚点回退到它所在周的"周首"(可能落在锚点之前几天)
  var offset = anchor.weekday - weekStartDay;
  if (offset < 0) offset += 7;
  final weekStartDate = DateTime(anchor.year, anchor.month, anchor.day)
      .subtract(Duration(days: offset));
  final target = DateTime(date.year, date.month, date.day);
  final diff = target.difference(weekStartDate).inDays;
  if (diff < 0) return 0;
  return diff ~/ 7 + 1;
}

/// 当前周是否在课程的周次列表中。
bool courseInWeek(CourseData course, int week) => course.weeks.contains(week);
