import 'package:coursesight_core/coursesight_core.dart';
import 'package:test/test.dart';

Map<String, dynamic> rawSubmission({
  List<Map<String, dynamic>>? courses,
  int? totalWeeks = 16,
  String? firstWeekMonday = '2026-03-02',
  int? firstDayColumn = 1,
  List<Map<String, dynamic>>? timeConfig,
}) {
  return {
    'totalWeeks': totalWeeks,
    'firstWeekMonday': firstWeekMonday,
    'firstDayColumn': firstDayColumn,
    'timeConfig': timeConfig ??
        [
          {'section': 1, 'startTime': '08:00', 'endTime': '08:45'},
          {'section': 2, 'startTime': '08:55', 'endTime': '09:40'},
        ],
    'courses': courses ??
        [
          {
            'name': '高等数学',
            'teacher': '张三',
            'location': '教1-101',
            'dayOfWeek': 1,
            'startSection': 1,
            'endSection': 2,
            'weeks': [1, 3, 5],
            'confidence': 1.0,
          },
        ],
  };
}

void main() {
  test('合法提交通过校验并推断周次类型', () {
    final r = validateSubmission(rawSubmission());
    expect(r.ok, isTrue);
    expect(r.timetable.courses.single.name, '高等数学');
    expect(r.timetable.courses.single.weekType, WeekType.odd);
    expect(r.timetable.firstWeekMonday, '2026-03-02');
  });

  test('缺 courses 数组 → 硬伤重试', () {
    final r = validateSubmission({'totalWeeks': 16});
    expect(r.ok, isFalse);
    expect(r.errors.single, contains('courses'));
  });

  test('空课程列表 → 硬伤', () {
    final r = validateSubmission(rawSubmission(courses: []));
    expect(r.ok, isFalse);
  });

  test('非法星期被丢弃并记警告', () {
    final r = validateSubmission(rawSubmission(courses: [
      {'name': '坏课', 'dayOfWeek': 9, 'startSection': 1, 'endSection': 1, 'weeks': [1]},
      {'name': '好课', 'dayOfWeek': 2, 'startSection': 1, 'endSection': 1, 'weeks': [1]},
    ]));
    expect(r.ok, isTrue);
    expect(r.timetable.courses.length, 1);
    expect(r.timetable.courses.single.name, '好课');
    expect(
        r.warnings.any((w) => w.code == WarningCode.invalidEntryDropped),
        isTrue);
  });

  test('结束节次超出作息上限被截断', () {
    final r = validateSubmission(rawSubmission(courses: [
      {'name': '超长课', 'dayOfWeek': 3, 'startSection': 2, 'endSection': 99, 'weeks': [1]},
    ]));
    expect(r.timetable.courses.single.endSection, 2); // maxSection=2
    expect(
        r.warnings.any((w) => w.code == WarningCode.outOfSchedule), isTrue);
  });

  test('重名同段课程合并周次', () {
    final r = validateSubmission(rawSubmission(courses: [
      {'name': '高数', 'dayOfWeek': 1, 'startSection': 1, 'endSection': 2, 'weeks': [1, 3]},
      {'name': '高数', 'dayOfWeek': 1, 'startSection': 1, 'endSection': 2, 'weeks': [5, 7]},
    ]));
    expect(r.timetable.courses.length, 1);
    expect(r.timetable.courses.single.weeks, [1, 3, 5, 7]);
  });

  test('同时间同周次冲突告警', () {
    final r = validateSubmission(rawSubmission(courses: [
      {'name': 'A', 'dayOfWeek': 1, 'startSection': 1, 'endSection': 2, 'weeks': [1, 2]},
      {'name': 'B', 'dayOfWeek': 1, 'startSection': 2, 'endSection': 3, 'weeks': [2]},
    ]));
    expect(r.warnings.any((w) => w.code == WarningCode.timeConflict), isTrue);
  });

  test('低置信度标记', () {
    final r = validateSubmission(rawSubmission(courses: [
      {
        'name': '猜的课',
        'dayOfWeek': 4,
        'startSection': 1,
        'endSection': 1,
        'weeks': [1],
        'confidence': 0.4
      },
    ]));
    expect(r.warnings.any((w) => w.code == WarningCode.lowConfidence), isTrue);
  });

  test('缺周次按全学期处理并记 weeksDefaulted 警告', () {
    final r = validateSubmission(rawSubmission(courses: [
      {'name': '无周次课', 'dayOfWeek': 5, 'startSection': 1, 'endSection': 1},
    ]));
    expect(r.timetable.courses.single.weeks.length, 16);
    expect(r.warnings.any((w) => w.code == WarningCode.weeksDefaulted),
        isTrue);
  });

  test('第一周日期不是周一 → 按学校声明原样保留', () {
    // 各校第一教学周开始日不一定是周一(周日/注册日起算),不再强制调整
    final r = validateSubmission(rawSubmission(firstWeekMonday: '2026-03-04'));
    expect(r.timetable.firstWeekMonday, '2026-03-04');
    expect(
        r.warnings.every((w) => w.code != WarningCode.firstWeekAdjusted),
        isTrue);
  });

  test('第一周日期非法 → 置空(警告与行为一致)', () {
    final r = validateSubmission(rawSubmission(firstWeekMonday: '2026-13-45'));
    expect(r.timetable.firstWeekMonday, isNull);
    expect(
        r.warnings.any((w) => w.code == WarningCode.invalidEntryDropped),
        isTrue);
  });

  test('页面第一列为周日 → 记 dayHeaderNonMonday 警告但不改数据', () {
    final r = validateSubmission(rawSubmission(firstDayColumn: 7));
    expect(r.ok, isTrue);
    // 警告用于提示抽查;课程数据按 AI 提交原样保留,不做自动位移
    expect(r.timetable.courses.single.dayOfWeek, 1);
    expect(
        r.warnings.any((w) => w.code == WarningCode.dayHeaderNonMonday), isTrue);
  });

  test('第一列为周一 / 缺失 / 非法值 → 不出 dayHeaderNonMonday 警告', () {
    for (final v in [1, null, 0, 8, -1]) {
      final r = validateSubmission(rawSubmission(firstDayColumn: v));
      expect(
          r.warnings.any((w) => w.code == WarningCode.dayHeaderNonMonday),
          isFalse,
          reason: 'firstDayColumn=$v 不应触发星期表头警告');
    }
  });

  test('低置信度条目参与的冲突合并为一条汇总,不逐对刷屏', () {
    final r = validateSubmission(rawSubmission(courses: [
      {
        'name': '正常课',
        'dayOfWeek': 1,
        'startSection': 1,
        'endSection': 2,
        'weeks': [1, 2],
        'confidence': 1.0,
      },
      {
        'name': '模式识别课程设计',
        'dayOfWeek': 1,
        'startSection': 1,
        'endSection': 2,
        'weeks': [1, 2],
        'confidence': 0.2,
      },
      {
        'name': '嵌入式系统B课程设计',
        'dayOfWeek': 1,
        'startSection': 2,
        'endSection': 3,
        'weeks': [1, 2],
        'confidence': 0.2,
      },
    ]));
    // 低置信度参与的两组重叠 → 不逐对告警,只出一条带名单的汇总
    final agg = r.warnings
        .where((w) => w.code == WarningCode.timeConflict)
        .toList();
    expect(agg.length, 1);
    expect(agg.single.message, contains('模式识别课程设计'));
    expect(agg.single.message, contains('嵌入式系统B课程设计'));
    expect(agg.single.message, contains('疑似误识别'));
  });

  test('totalWeeks 异常值被钳制', () {
    final r = validateSubmission(rawSubmission(
        totalWeeks: -5,
        courses: [
          {
            'name': 'A',
            'dayOfWeek': 1,
            'startSection': 1,
            'endSection': 1,
            'weeks': [1]
          }
        ]));
    expect(r.timetable.totalWeeks, 1);
    final r2 = validateSubmission(rawSubmission(totalWeeks: 999));
    expect(r2.timetable.totalWeeks, 60);
  });

  test('超出总周数的周次被过滤并告警', () {
    final r = validateSubmission(rawSubmission(courses: [
      {
        'name': '跨界课',
        'dayOfWeek': 1,
        'startSection': 1,
        'endSection': 1,
        'weeks': [1, 2, 99]
      },
    ]));
    expect(r.timetable.courses.single.weeks, [1, 2]);
    expect(
        r.warnings.any((w) => w.code == WarningCode.invalidEntryDropped),
        isTrue);
  });

  test('课程数量对照触发遗漏警告', () {
    final r = validateSubmission(rawSubmission(),
        expectedCourseNameCount: 10); // 只解析出 1 门,估 10 条
    expect(
        r.warnings.any((w) => w.code == WarningCode.maybeMissingCourses),
        isTrue);
  });

  test('缺作息表使用默认模板', () {
    final r = validateSubmission(rawSubmission(timeConfig: []));
    expect(r.timetable.timeConfig.length, defaultSectionTimes.length);
    expect(
        r.warnings.any((w) => w.code == WarningCode.missingTimeConfig),
        isTrue);
  });
  test('开学日期宽容格式:年月日/点分/斜杠/无年份', () {
    // 2026-03-02 是周一
    for (final fmt in ['2026-03-02', '2026.3.2', '2026/3/2', '2026年3月2日']) {
      final r = validateSubmission(rawSubmission(firstWeekMonday: fmt));
      expect(r.timetable.firstWeekMonday, '2026-03-02', reason: fmt);
    }
    // 无年份:补当前年,2026-03-02 恰为周一
    final r2 = validateSubmission(rawSubmission(firstWeekMonday: '3月2日'));
    expect(r2.timetable.firstWeekMonday, '2026-03-02');
    // 非周一:原样保留
    final r3 = validateSubmission(rawSubmission(firstWeekMonday: '2026年3月4日'));
    expect(r3.timetable.firstWeekMonday, '2026-03-04');
    // 非法仍拒绝
    final r4 = validateSubmission(rawSubmission(firstWeekMonday: '2026年13月45日'));
    expect(r4.timetable.firstWeekMonday, isNull);
  });
}
