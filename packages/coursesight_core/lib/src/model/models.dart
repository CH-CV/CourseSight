/// 解析引擎的数据模型。schemaVersion 只增不改:对外 JSON 契约的唯一版本标识。
library;

import '../diagnostic/diagnostic.dart';

/// 课表数据来源类型。MVP 仅启用 html,其余为引擎预留能力。
enum SourceType { html, screenshot, pdf }

/// 可选的解析提示(学校名 / 教务系统名),只影响提示词,不影响流程。
class ParseHints {
  final String? schoolName;
  final String? systemName;

  const ParseHints({this.schoolName, this.systemName});

  Map<String, dynamic> toJson() => {
        if (schoolName != null) 'schoolName': schoolName,
        if (systemName != null) 'systemName': systemName,
      };

  static ParseHints? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    return ParseHints(
      schoolName: json['schoolName'] as String?,
      systemName: json['systemName'] as String?,
    );
  }
}

/// 解析输入。
class ParseInput {
  final SourceType sourceType;
  final String data;
  final ParseHints? hints;

  const ParseInput({
    this.sourceType = SourceType.html,
    required this.data,
    this.hints,
  });
}

/// 周次来源标签:展开后的 [CourseData.weeks] 的原始表述。
enum WeekType { all, odd, even, custom }

/// 单条课程(草稿与成品通用)。
class CourseData {
  final String name;
  final String? teacher;
  final String? location;
  final int dayOfWeek; // 1=周一 … 7=周日
  final int startSection;
  final int endSection;
  final List<int> weeks; // 展开后的具体周次
  final WeekType weekType;
  final double confidence; // 0-1,LLM 自报

  const CourseData({
    required this.name,
    this.teacher,
    this.location,
    required this.dayOfWeek,
    required this.startSection,
    required this.endSection,
    required this.weeks,
    this.weekType = WeekType.all,
    this.confidence = 1.0,
  });

  bool overlapsWeeks(List<int> other) =>
      weeks.any(other.contains);

  bool conflictsWith(CourseData other) =>
      dayOfWeek == other.dayOfWeek &&
      startSection <= other.endSection &&
      other.startSection <= endSection &&
      overlapsWeeks(other.weeks);

  CourseData copyWith({
    String? name,
    String? teacher,
    String? location,
    int? dayOfWeek,
    int? startSection,
    int? endSection,
    List<int>? weeks,
    WeekType? weekType,
    double? confidence,
  }) {
    return CourseData(
      name: name ?? this.name,
      teacher: teacher ?? this.teacher,
      location: location ?? this.location,
      dayOfWeek: dayOfWeek ?? this.dayOfWeek,
      startSection: startSection ?? this.startSection,
      endSection: endSection ?? this.endSection,
      weeks: weeks ?? this.weeks,
      weekType: weekType ?? this.weekType,
      confidence: confidence ?? this.confidence,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        if (teacher != null && teacher!.isNotEmpty) 'teacher': teacher,
        if (location != null && location!.isNotEmpty) 'location': location,
        'dayOfWeek': dayOfWeek,
        'startSection': startSection,
        'endSection': endSection,
        'weeks': weeks,
        'weekType': weekType.name,
        'confidence': confidence,
      };

  static CourseData fromJson(Map<String, dynamic> json) {
    final weeksRaw = json['weeks'];
    final weeks = weeksRaw is List
        ? weeksRaw.map((e) => (e as num).toInt()).toList()
        : <int>[];
    return CourseData(
      name: (json['name'] as String?) ?? '',
      teacher: json['teacher'] as String?,
      location: json['location'] as String?,
      dayOfWeek: (json['dayOfWeek'] as num?)?.toInt() ?? 1,
      startSection: (json['startSection'] as num?)?.toInt() ?? 1,
      endSection: (json['endSection'] as num?)?.toInt() ?? 1,
      weeks: weeks,
      weekType: WeekType.values.firstWhere(
        (e) => e.name == json['weekType'],
        orElse: () => WeekType.all,
      ),
      confidence: (json['confidence'] as num?)?.toDouble() ?? 1.0,
    );
  }
}

/// 单节课的起止时间。
class SectionTime {
  final int section;
  final String startTime; // "HH:mm"
  final String endTime;

  const SectionTime({
    required this.section,
    required this.startTime,
    required this.endTime,
  });

  Map<String, dynamic> toJson() =>
      {'section': section, 'startTime': startTime, 'endTime': endTime};

  static SectionTime fromJson(Map<String, dynamic> json) => SectionTime(
        section: (json['section'] as num).toInt(),
        startTime: json['startTime'] as String,
        endTime: json['endTime'] as String,
      );
}

/// 结构化课表(引擎的最终产物,也是审查循环中的草稿)。
class TimetableData {
  static const int schemaVersion = 1;

  final String? name;
  final int totalWeeks;
  final String? firstWeekMonday; // "YYYY-MM-DD",可为空
  final List<SectionTime> timeConfig;
  final List<CourseData> courses;

  const TimetableData({
    this.name,
    this.totalWeeks = 20,
    this.firstWeekMonday,
    this.timeConfig = const [],
    this.courses = const [],
  });

  TimetableData copyWith({
    String? name,
    int? totalWeeks,
    String? firstWeekMonday,
    List<SectionTime>? timeConfig,
    List<CourseData>? courses,
  }) {
    return TimetableData(
      name: name ?? this.name,
      totalWeeks: totalWeeks ?? this.totalWeeks,
      firstWeekMonday: firstWeekMonday ?? this.firstWeekMonday,
      timeConfig: timeConfig ?? this.timeConfig,
      courses: courses ?? this.courses,
    );
  }

  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        if (name != null) 'name': name,
        'totalWeeks': totalWeeks,
        if (firstWeekMonday != null) 'firstWeekMonday': firstWeekMonday,
        'timeConfig': timeConfig.map((e) => e.toJson()).toList(),
        'courses': courses.map((e) => e.toJson()).toList(),
      };

  static TimetableData fromJson(Map<String, dynamic> json) {
    final timeConfig = (json['timeConfig'] as List? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(SectionTime.fromJson)
        .toList();
    final courses = (json['courses'] as List? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(CourseData.fromJson)
        .toList();
    return TimetableData(
      name: json['name'] as String?,
      totalWeeks: (json['totalWeeks'] as num?)?.toInt() ?? 20,
      firstWeekMonday: json['firstWeekMonday'] as String?,
      timeConfig: timeConfig,
      courses: courses,
    );
  }
}

/// 警告码:预览页按码决定呈现方式。
enum WarningCode {
  lowConfidence, // 置信度 < 0.7
  timeConflict, // 课程时间重叠
  outOfSchedule, // 节次超出作息表范围
  missingTimeConfig, // 缺失作息表
  maybeMissingCourses, // 课程数量明显少于页面
  invalidEntryDropped, // 非法条目被丢弃
  weeksDefaulted, // 缺周次,按全学期补全(条目保留)
  firstWeekAdjusted, // 已废弃:锚点不再强制对齐周一,保留仅为兼容旧数据
  dayHeaderNonMonday, // 页面第一列非周一,星期列按表头映射,需抽查
  reviewUncertain, // 审查者不确定的疑点
  reviewDegraded, // 审查环节不可用,已跳过
  reviewDisagreement, // 达到审查上限仍有分歧
  missingFirstWeek, // 缺第一周日期,无法推算实际日期
}

/// 非致命警告。
class ParseWarning {
  final WarningCode code;
  final String message;
  final int? courseIndex; // 对应 courses 下标,可为空

  const ParseWarning(this.code, this.message, {this.courseIndex});

  Map<String, dynamic> toJson() => {
        'code': code.name,
        'message': message,
        if (courseIndex != null) 'courseIndex': courseIndex,
      };

  static ParseWarning fromJson(Map<String, dynamic> json) => ParseWarning(
        WarningCode.values.firstWhere((e) => e.name == json['code'],
            orElse: () => WarningCode.reviewUncertain),
        json['message'] as String,
        courseIndex: (json['courseIndex'] as num?)?.toInt(),
      );
}

/// 解析结果:课表草稿 + 警告 + 诊断信息。
class ParseResult {
  final TimetableData timetable;
  final List<ParseWarning> warnings;
  final ParseDiagnostics diagnostics;

  const ParseResult({
    required this.timetable,
    required this.warnings,
    required this.diagnostics,
  });
}
