/// LLM 审查循环:空白上下文审查者,纠错必须带原文依据。
library;

import 'dart:convert';

import '../model/models.dart';
import '../prompt/prompt_builder.dart' show extractJsonObject;

/// 审查者输出的一条 issue(有原文依据,可自动修复)。
class ReviewIssue {
  final int courseIndex;
  final String field;
  final String problem;
  final String evidence;
  final String suggestion;

  const ReviewIssue({
    required this.courseIndex,
    required this.field,
    required this.problem,
    required this.evidence,
    required this.suggestion,
  });
}

/// 审查者不确定的疑点(无原文依据,只进预览提示,不自动应用)。
class ReviewUncertain {
  final int? courseIndex;
  final String problem;

  const ReviewUncertain({this.courseIndex, required this.problem});
}

/// 单轮审查的完整裁决。
class ReviewVerdict {
  final List<ReviewIssue> issues;
  final List<ReviewUncertain> uncertain;

  const ReviewVerdict({this.issues = const [], this.uncertain = const []});

  bool get clean => issues.isEmpty && uncertain.isEmpty;

  static const empty = ReviewVerdict();
}

/// 审查者输出完全不可信:整体安全解析,失败返回 null。
/// evidence 核验(忽略空白差异后必须是页面原文的子串,且有效长度 ≥4)
/// 失败的 issue 降级为 uncertain——防审查者幻觉纠错,同时不让分歧消失。
ReviewVerdict? parseReviewVerdict(String text, String preprocessedSource) {
  try {
    final json = extractJsonObject(text);
    if (json == null) return null;

    String squash(String s) => s.replaceAll(RegExp(r'\s+'), '');
    // 表格列分隔符不作为证据边界:审查者引用跨单元格内容(如"教1-101 单周")也应命中
    final haystack =
        squash(preprocessedSource.replaceAll('|', ''));

    int? idx(dynamic v) {
      final i = v is num ? v.toInt() : (v is String ? int.tryParse(v.trim()) : null);
      return i;
    }

    final issues = <ReviewIssue>[];
    final uncertain = <ReviewUncertain>[];
    for (final raw in (json['issues'] as List? ?? [])) {
      if (raw is! Map) continue;
      final evidence = (raw['evidence']?.toString() ?? '').trim();
      final suggestion = (raw['suggestion']?.toString() ?? '').trim();
      final problem = (raw['problem']?.toString() ?? '').trim();
      final courseIndex = idx(raw['course_index']);
      if (evidence.isEmpty || suggestion.isEmpty) {
        uncertain.add(ReviewUncertain(
            courseIndex: courseIndex,
            problem: 'issue 字段不完整${problem.isEmpty ? '' : ':$problem'}'));
        continue;
      }
      if (squash(evidence).length < 4 ||
          !haystack.contains(squash(evidence))) {
        uncertain.add(ReviewUncertain(
            courseIndex: courseIndex,
            problem: '证据无法核实,未采纳「$problem」(建议:$suggestion)'));
        continue;
      }
      issues.add(ReviewIssue(
        courseIndex: courseIndex ?? -1,
        field: (raw['field']?.toString() ?? '').trim(),
        problem: problem,
        evidence: evidence,
        suggestion: suggestion,
      ));
    }

    for (final raw in (json['uncertain'] as List? ?? [])) {
      if (raw is! Map) continue;
      final problem = (raw['problem']?.toString() ?? '').trim();
      if (problem.isEmpty) continue;
      uncertain.add(ReviewUncertain(
        courseIndex: idx(raw['course_index']),
        problem: problem,
      ));
    }

    return ReviewVerdict(issues: issues, uncertain: uncertain);
  } catch (_) {
    return null;
  }
}

/// 把有依据的 issue 应用到课表草稿,返回修订版与被应用的条数。
/// weeks 建议值支持 JSON 数组、单值序列与 "a-b" 区间展开;应用后由调用方
/// 执行 sanitizeTimetable 做同样的安全钳制。
(TimetableData, int) applyReviewIssues(
    TimetableData timetable, List<ReviewIssue> issues) {
  var applied = 0;
  final courses = List<CourseData>.from(timetable.courses);

  for (final issue in issues) {
    final idx = issue.courseIndex;
    if (idx < 0 || idx >= courses.length) continue;
    final c = courses[idx];
    final value = issue.suggestion;
    switch (issue.field.trim().toLowerCase()) {
      case 'name':
        if (value.isNotEmpty) {
          courses[idx] = c.copyWith(name: value);
          applied++;
        }
      case 'teacher':
        courses[idx] = c.copyWith(teacher: value);
        applied++;
      case 'location':
        courses[idx] = c.copyWith(location: value);
        applied++;
      case 'dayofweek' || 'day_of_week' || 'day':
        final d = int.tryParse(value);
        if (d != null && d >= 1 && d <= 7) {
          courses[idx] = c.copyWith(dayOfWeek: d);
          applied++;
        }
      case 'startsection' || 'start_section' || 'start':
        final v = int.tryParse(value);
        if (v != null && v >= 1) {
          courses[idx] = c.copyWith(startSection: v);
          applied++;
        }
      case 'endsection' || 'end_section' || 'end':
        final v = int.tryParse(value);
        if (v != null && v >= 1) {
          courses[idx] = c.copyWith(endSection: v);
          applied++;
        }
      case 'weeks' || 'week':
        final weeks = _parseWeeksSuggestion(value);
        if (weeks.isNotEmpty) {
          courses[idx] = c.copyWith(weeks: weeks);
          applied++;
        }
    }
  }

  if (applied == 0) return (timetable, 0);
  return (timetable.copyWith(courses: courses), applied);
}

/// 周次建议值解析:
/// 1) JSON 数组形式 "[1,3,5]" → 直接取整;
/// 2) "1,3,5" / "1 3 5" 单值序列;
/// 3) "1-16" / "1–16周" 区间展开(含端点),可与单值混用。
List<int> _parseWeeksSuggestion(String value) {
  // 1) JSON 数组
  if (value.startsWith('[')) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is List) {
        return decoded
            .map((e) => e is num ? e.toInt() : int.tryParse('$e'))
            .whereType<int>()
            .toList();
      }
    } catch (_) {}
  }
  final weeks = <int>[];
  // 3) 区间(先展开,避免 "1-16" 被拆成 [1,16])
  final rangePattern = RegExp(r'(\d{1,2})\s*[-–—]\s*(\d{1,2})');
  var rest = value;
  for (final m in rangePattern.allMatches(value).toList().reversed) {
    final a = int.parse(m.group(1)!);
    final b = int.parse(m.group(2)!);
    final lo = a <= b ? a : b;
    final hi = a <= b ? b : a;
    for (var w = lo; w <= hi; w++) {
      weeks.add(w);
    }
    rest = rest.replaceRange(m.start, m.end, ' ');
  }
  // 2) 剩余单值
  for (final m in RegExp(r'\d{1,2}').allMatches(rest)) {
    weeks.add(int.parse(m.group(0)!));
  }
  return weeks.toSet().toList()..sort();
}
