/// 应用层数据实体:与数据库行一一对应;与 coursesight_core 的模型互转。
library;

import 'dart:convert';

import 'package:coursesight_core/coursesight_core.dart';

/// 一张课表(多学期多记录)。
class Timetable {
  final int? id;
  String name;
  String? firstWeekMonday; // YYYY-MM-DD,第一教学周开始日(任意星期几)

  /// 页面声明的学期总周数;null = 页面未说明(不设人为上限,
  /// 课排到第几周就显示到第几周)。DB 里以 0 表示未声明。
  int? totalWeeks;

  Timetable({
    this.id,
    required this.name,
    this.firstWeekMonday,
    this.totalWeeks,
  });

  Map<String, dynamic> toRow() => {
        if (id != null) 'id': id,
        'name': name,
        'first_week_monday': firstWeekMonday,
        'total_weeks': totalWeeks ?? 0,
        'updated_at': DateTime.now().toIso8601String(),
      };

  static Timetable fromRow(Map<String, dynamic> row) => Timetable(
        id: row['id'] as int,
        name: row['name'] as String,
        firstWeekMonday: row['first_week_monday'] as String?,
        totalWeeks: () {
          final tw = row['total_weeks'] as int?;
          return (tw == null || tw <= 0) ? null : tw;
        }(),
      );

  /// 当前是第几周(以本地今天计);开学日缺失或早于开学返回 null。
  /// [weekStartDay] 是该校一周的第一天(1=周一,7=周日),
  /// 锚点(第一教学周开始日)不一定是周首,由学校决定。
  /// 不设学期末上限:声明周数之外照常推算,由无课空白表达假期。
  int? currentWeek(DateTime today, {int weekStartDay = 1}) {
    if (firstWeekMonday == null) return null;
    final w = weekOfDate(firstWeekMonday!, today, weekStartDay: weekStartDay);
    if (w < 1) return null;
    return w;
  }
}

/// 一条课程。
class Course {
  final int? id;
  final int timetableId;
  String name;
  String? teacher;
  String? location;
  int dayOfWeek; // 1-7
  int startSection;
  int endSection;
  List<int> weeks;
  String weekType; // all | odd | even | custom
  int colorIndex;
  String? note;

  Course({
    this.id,
    required this.timetableId,
    required this.name,
    this.teacher,
    this.location,
    required this.dayOfWeek,
    required this.startSection,
    required this.endSection,
    required this.weeks,
    this.weekType = 'all',
    this.colorIndex = 0,
    this.note,
  });

  bool inWeek(int week) => weeks.contains(week);

  Map<String, dynamic> toRow() => {
        if (id != null) 'id': id,
        'timetable_id': timetableId,
        'name': name,
        'teacher': teacher,
        'location': location,
        'day_of_week': dayOfWeek,
        'start_section': startSection,
        'end_section': endSection,
        'weeks': jsonEncode(weeks),
        'week_type': weekType,
        'color_index': colorIndex,
        'note': note,
        'updated_at': DateTime.now().toIso8601String(),
      };

  static Course fromRow(Map<String, dynamic> row) => Course(
        id: row['id'] as int,
        timetableId: row['timetable_id'] as int,
        name: row['name'] as String,
        teacher: row['teacher'] as String?,
        location: row['location'] as String?,
        dayOfWeek: row['day_of_week'] as int,
        startSection: row['start_section'] as int,
        endSection: row['end_section'] as int,
        weeks:
            (jsonDecode(row['weeks'] as String) as List).cast<int>().toList(),
        weekType: (row['week_type'] as String?) ?? 'all',
        colorIndex: (row['color_index'] as int?) ?? 0,
        note: row['note'] as String?,
      );

  /// 从引擎的 CourseData 构造(导入入库用)。
  static Course fromCore(
          int timetableId, CourseData data, int colorIndex) =>
      Course(
        timetableId: timetableId,
        name: data.name,
        teacher: data.teacher,
        location: data.location,
        dayOfWeek: data.dayOfWeek,
        startSection: data.startSection,
        endSection: data.endSection,
        weeks: data.weeks,
        weekType: data.weekType.name,
        colorIndex: colorIndex,
      );
}

/// 单节作息。
class SectionTimeRow {
  final int? id;
  final int timetableId;
  final int section;
  final String startTime;
  final String endTime;

  const SectionTimeRow({
    this.id,
    required this.timetableId,
    required this.section,
    required this.startTime,
    required this.endTime,
  });

  SectionTime toCore() =>
      SectionTime(section: section, startTime: startTime, endTime: endTime);

  Map<String, dynamic> toRow() => {
        if (id != null) 'id': id,
        'timetable_id': timetableId,
        'section': section,
        'start_time': startTime,
        'end_time': endTime,
      };

  static SectionTimeRow fromRow(Map<String, dynamic> row) => SectionTimeRow(
        id: row['id'] as int,
        timetableId: row['timetable_id'] as int,
        section: row['section'] as int,
        startTime: row['start_time'] as String,
        endTime: row['end_time'] as String,
      );
}
