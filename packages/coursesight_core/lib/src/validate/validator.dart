/// 本地校验:对 LLM 的整表提交做 schema 与业务规则校验。
/// 确定性规则不进 LLM;校验产物是"干净的草稿 + 警告",失败信息供重试提示使用。
/// LLM 输出是完全不可信输入:一律安全取值,禁止裸 cast。
library;

import '../model/models.dart';

class ValidationResult {
  final TimetableData timetable;
  final List<ParseWarning> warnings;

  /// 供格式重试的错误描述;非空表示提交物有硬伤(如 courses 缺失)需要 LLM 重交。
  final List<String> errors;

  const ValidationResult({
    required this.timetable,
    this.warnings = const [],
    this.errors = const [],
  });

  bool get ok => errors.isEmpty;
}

/// 默认 12 节作息模板。
const List<SectionTime> defaultSectionTimes = [
  SectionTime(section: 1, startTime: '08:00', endTime: '08:45'),
  SectionTime(section: 2, startTime: '08:55', endTime: '09:40'),
  SectionTime(section: 3, startTime: '10:00', endTime: '10:45'),
  SectionTime(section: 4, startTime: '10:55', endTime: '11:40'),
  SectionTime(section: 5, startTime: '11:50', endTime: '12:35'),
  SectionTime(section: 6, startTime: '14:00', endTime: '14:45'),
  SectionTime(section: 7, startTime: '14:55', endTime: '15:40'),
  SectionTime(section: 8, startTime: '16:00', endTime: '16:45'),
  SectionTime(section: 9, startTime: '16:55', endTime: '17:40'),
  SectionTime(section: 10, startTime: '19:00', endTime: '19:45'),
  SectionTime(section: 11, startTime: '19:55', endTime: '20:40'),
  SectionTime(section: 12, startTime: '20:50', endTime: '21:35'),
];

const _lowConfidence = 0.7;

// ── 安全取值助手:LLM 可能给 "16"(字符串)而不是 16 ──
int? _toInt(dynamic v) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

double? _toDouble(dynamic v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.trim());
  return null;
}

String? _toStr(dynamic v) => v is String ? v.trim() : null;

const List<String> _dayNames = [
  '', '周一', '周二', '周三', '周四', '周五', '周六', '周日',
];

bool _validTime(String s) {
  final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(s);
  if (m == null) return false;
  final h = int.parse(m.group(1)!);
  final min = int.parse(m.group(2)!);
  return h < 24 && min < 60;
}

/// 校验 LLM 提交的原始 JSON(来自 tool call arguments 或 json 模式文本)。
/// [expectedCourseNameCount] 来自预处理器的课程名估计,用于遗漏对照。
ValidationResult validateSubmission(
  Map<String, dynamic> raw, {
  int expectedCourseNameCount = 0,
}) {
  final errors = <String>[];
  final warnings = <ParseWarning>[];

  final rawCourses = raw['courses'];
  if (rawCourses is! List) {
    errors.add('缺少 courses 数组');
    return ValidationResult(
        timetable: const TimetableData(), errors: errors);
  }

  // 总周数一次性钳制,后续统一使用
  var totalWeeks = _toInt(raw['totalWeeks']) ?? 20;
  if (totalWeeks < 1) totalWeeks = 1;
  if (totalWeeks > 60) totalWeeks = 60;

  // 第一教学周开始日:按学校声明原样保留(不一定是周一——有的学校以
  // 周日或注册日起算第一周)。非法才置空。
  String? firstWeek;
  final rawFirstWeek = _toStr(raw['firstWeekMonday']);
  if (rawFirstWeek != null && rawFirstWeek.isNotEmpty) {
    final parsed = _tryParseDate(rawFirstWeek,
        defaultYear: DateTime.now().year);
    if (parsed == null) {
      warnings.add(const ParseWarning(
          WarningCode.invalidEntryDropped, '第一周日期格式非法,已置空'));
    } else {
      firstWeek = _fmt(parsed);
    }
  }

  // 页面第一列星期:非周一(如以周日开头)时提示抽查。
  // 不做自动位移:AI 按表头文字映射时位移反而会把对的改错,
  // 真正的纠偏靠提示词规则 8 与审查轮次,这里只把风险显式暴露给用户。
  final firstDayColumn = _toInt(raw['firstDayColumn']);
  if (firstDayColumn != null &&
      firstDayColumn >= 1 &&
      firstDayColumn <= 7 &&
      firstDayColumn != 1) {
    warnings.add(ParseWarning(
        WarningCode.dayHeaderNonMonday,
        '课表页面以${_dayNames[firstDayColumn]}为第一列,星期列已按表头映射,请抽查周二/周三列是否正确'));
  }

  // 作息表:逐条校验时间合法性
  final timeConfig = <SectionTime>[];
  for (final t in (raw['timeConfig'] as List? ?? [])) {
    if (t is! Map) continue;
    final section = _toInt(t['section']);
    final start = _toStr(t['startTime']);
    final end = _toStr(t['endTime']);
    if (section == null ||
        section < 1 ||
        start == null ||
        end == null ||
        !_validTime(start) ||
        !_validTime(end)) {
      continue;
    }
    timeConfig.add(SectionTime(section: section, startTime: start, endTime: end));
  }
  if (timeConfig.isEmpty) {
    warnings.add(const ParseWarning(
        WarningCode.missingTimeConfig, '页面未提供作息时间,已使用默认 12 节模板'));
  }
  final effectiveTimes =
      timeConfig.isEmpty ? defaultSectionTimes : timeConfig;
  final maxSection =
      effectiveTimes.map((e) => e.section).reduce((a, b) => a > b ? a : b);

  // 逐条构建课程;rawIndex → 合并后实例的映射用于警告下标修正
  final courses = <CourseData>[];
  final mergedIndexOfRaw = <int, int>{};
  final outOfScheduleRaw = <int>[]; // 记录需要截断告警的原始下标
  final weeksOutOfRangeRaw = <int>[];

  for (var i = 0; i < rawCourses.length; i++) {
    final rawCourse = rawCourses[i];
    if (rawCourse is! Map) {
      warnings.add(ParseWarning(WarningCode.invalidEntryDropped,
          '第 ${i + 1} 条不是对象,已丢弃', courseIndex: null));
      continue;
    }
    final name = _toStr(rawCourse['name']) ?? '';
    if (name.isEmpty) {
      warnings.add(ParseWarning(WarningCode.invalidEntryDropped,
          '第 ${i + 1} 条缺少课程名,已丢弃'));
      continue;
    }

    final day = _toInt(rawCourse['dayOfWeek']) ?? 0;
    if (day < 1 || day > 7) {
      warnings.add(ParseWarning(WarningCode.invalidEntryDropped,
          '「$name」星期($day)非法,已丢弃'));
      continue;
    }

    var start = _toInt(rawCourse['startSection']) ?? 0;
    var end = _toInt(rawCourse['endSection']) ?? 0;
    if (start < 1 || end < 1) {
      warnings.add(ParseWarning(
          WarningCode.invalidEntryDropped, '「$name」节次非法,已丢弃'));
      continue;
    }
    if (end < start) {
      final t = start;
      start = end;
      end = t;
    }
    if (end > maxSection) {
      outOfScheduleRaw.add(i);
      end = maxSection;
      if (start > maxSection) start = maxSection;
    }

    final weeksRaw = rawCourse['weeks'];
    var weeks = weeksRaw is List
        ? weeksRaw
            .map(_toInt)
            .whereType<int>()
            .where((w) => w >= 1 && w <= totalWeeks)
            .toList()
        : <int>[];
    if (weeksRaw is List && weeks.length != weeksRaw.length) {
      weeksOutOfRangeRaw.add(i);
    }
    if (weeks.isEmpty) {
      weeks = List.generate(totalWeeks, (idx) => idx + 1);
      warnings.add(ParseWarning(
          WarningCode.weeksDefaulted, '「$name」无有效周次,按全学期处理'));
    }
    weeks = weeks.toSet().toList()..sort();

    var confidence = _toDouble(rawCourse['confidence']) ?? 1.0;
    confidence = confidence.clamp(0.0, 1.0);

    final course = CourseData(
      name: name,
      teacher: _toStr(rawCourse['teacher']),
      location: _toStr(rawCourse['location']),
      dayOfWeek: day,
      startSection: start,
      endSection: end,
      weeks: weeks,
      weekType: _inferWeekType(weeks),
      confidence: confidence,
    );

    // 重名同段合并:同 name+day+节次区间 → 合并周次
    final existing = courses.indexWhere((m) =>
        m.name == course.name &&
        m.dayOfWeek == course.dayOfWeek &&
        m.startSection == course.startSection &&
        m.endSection == course.endSection);
    if (existing >= 0) {
      final m = courses[existing];
      courses[existing] = m.copyWith(
        weeks: (m.weeks + course.weeks).toSet().toList()..sort(),
        confidence: m.confidence < course.confidence
            ? m.confidence
            : course.confidence,
      );
      mergedIndexOfRaw[i] = existing;
    } else {
      courses.add(course);
      mergedIndexOfRaw[i] = courses.length - 1;
    }
  }

  // ── 以下警告均以合并后的下标为准(与最终课表顺序一致)──
  for (final rawIdx in outOfScheduleRaw) {
    final mi = mergedIndexOfRaw[rawIdx];
    if (mi == null) continue;
    warnings.add(ParseWarning(
      WarningCode.outOfSchedule,
      '「${courses[mi].name}」结束节次超出作息表(最大 $maxSection),已截断',
      courseIndex: mi,
    ));
  }
  for (final rawIdx in weeksOutOfRangeRaw) {
    final mi = mergedIndexOfRaw[rawIdx];
    if (mi == null) continue;
    warnings.add(ParseWarning(
        WarningCode.invalidEntryDropped,
        '「${courses[mi].name}」部分周次超出总周数 $totalWeeks,已忽略',
        courseIndex: mi));
  }

  // 时间冲突检测(节次重叠且周次重叠)。
  // 双方均为高置信度(≥0.7)才逐对告警;低置信度条目(模型自报为推断)
  // 参与的重叠大概率是误识别,合并成一条汇总提示,避免垃圾条目刷屏。
  final lowConfOverlap = <String>{};
  for (var i = 0; i < courses.length; i++) {
    for (var j = i + 1; j < courses.length; j++) {
      if (!courses[i].conflictsWith(courses[j])) continue;
      if (courses[i].confidence < 0.7 || courses[j].confidence < 0.7) {
        if (courses[i].confidence < 0.7) lowConfOverlap.add(courses[i].name);
        if (courses[j].confidence < 0.7) lowConfOverlap.add(courses[j].name);
        continue;
      }
      warnings.add(ParseWarning(
        WarningCode.timeConflict,
        '「${courses[i].name}」与「${courses[j].name}」时间重叠',
        courseIndex: i,
      ));
    }
  }
  if (lowConfOverlap.isNotEmpty) {
    final names = [for (final n in lowConfOverlap) '「$n」'].join();
    warnings.add(ParseWarning(
      WarningCode.timeConflict,
      '$names为低置信度条目,与其它课程时间重叠,疑似误识别,'
          '请在预览中核对其时间或取消勾选',
    ));
  }

  // 低置信度标记
  for (var i = 0; i < courses.length; i++) {
    if (courses[i].confidence < _lowConfidence) {
      warnings.add(ParseWarning(
          WarningCode.lowConfidence,
          '「${courses[i].name}」置信度较低(${courses[i].confidence.toStringAsFixed(2)}),请核对',
          courseIndex: i));
    }
  }

  // 课程数量对照(预处理器估出的非空名称格数,≥2 才有意义)
  if (expectedCourseNameCount >= 2 &&
      courses.isNotEmpty &&
      courses.length * 2 <= expectedCourseNameCount) {
    warnings.add(ParseWarning(
        WarningCode.maybeMissingCourses,
        '解析出 ${courses.length} 门课,但页面疑似包含约 $expectedCourseNameCount 条,可能遗漏'));
  }

  if (courses.isEmpty) {
    errors.add('未解析出任何课程');
  }

  return ValidationResult(
    timetable: TimetableData(
      totalWeeks: totalWeeks,
      firstWeekMonday: firstWeek,
      timeConfig: effectiveTimes,
      courses: courses,
    ),
    warnings: warnings,
    errors: errors,
  );
}

/// 审查修复后对草稿做同样的安全钳制(防止审查者把越界值重新带回来)。
/// 返回净化后的课表;被丢弃的条目数供调用方告警。
TimetableData sanitizeTimetable(TimetableData t) {
  if (t.courses.isEmpty) return t;
  final maxSection = t.timeConfig.isEmpty
      ? defaultSectionTimes.length
      : t.timeConfig.map((e) => e.section).reduce((a, b) => a > b ? a : b);
  final kept = <CourseData>[];
  for (final c in t.courses) {
    if (c.name.trim().isEmpty) continue;
    var start = c.startSection < 1 ? 1 : c.startSection;
    var end = c.endSection > maxSection ? maxSection : c.endSection;
    if (end < start) end = start;
    final weeks = c.weeks
        .where((w) => w >= 1 && w <= t.totalWeeks)
        .toList()
      ..sort();
    kept.add(c.copyWith(
      name: c.name.trim(),
      startSection: start,
      endSection: end,
      weeks: weeks.isEmpty ? List.generate(t.totalWeeks, (i) => i + 1) : weeks,
    ));
  }
  return t.copyWith(courses: kept);
}

String _fmt(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// 宽容日期解析:支持 2026-03-02 / 2026.3.2 / 2026/3/2 / 2026年3月2日,
/// 以及无年份的 3月2日 / 03-02(年份由调用方补,此处 [defaultYear])。
/// 月/日越界返回 null(不信 tryParse 的进位行为)。
DateTime? _tryParseDate(String input, {int? defaultYear}) {
  var s = input.trim();
  // 去中文单位与点/斜杠分隔,统一为 -
  s = s
      .replaceAll('年', '-')
      .replaceAll('月', '-')
      .replaceAll('日', '')
      .replaceAll('.', '-')
      .replaceAll('/', '-');
  s = s.trim();
  final m = RegExp(r'^(?:(\d{4})-)?(\d{1,2})-(\d{1,2})$').firstMatch(s);
  if (m == null) return null;
  final year = int.tryParse(m.group(1) ?? '') ?? defaultYear;
  if (year == null) return null;
  final y = year;
  final mo = int.parse(m.group(2)!);
  final d = int.parse(m.group(3)!);
  if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
  final normalized = DateTime(y, mo, d);
  if (normalized.year != y || normalized.month != mo || normalized.day != d) {
    return null;
  }
  return normalized;
}

WeekType _inferWeekType(List<int> weeks) {
  if (weeks.isEmpty) return WeekType.all;
  final allOdd = weeks.every((w) => w.isOdd);
  final allEven = weeks.every((w) => w.isEven);
  final contiguous = weeks.last - weeks.first == weeks.length - 1;
  if (contiguous && weeks.first == 1 && weeks.last == weeks.length) {
    return WeekType.all;
  }
  if (allOdd) return WeekType.odd;
  if (allEven) return WeekType.even;
  return WeekType.custom;
}
