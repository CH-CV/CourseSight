import 'package:coursesight_core/coursesight_core.dart';
import 'package:test/test.dart';

const page = '第1节 08:00-08:45 高等数学 张三 教1-101 1-16周 单周';

TimetableData draft() => const TimetableData(
      courses: [
        CourseData(
            name: '高等数学',
            location: '错误的教室',
            dayOfWeek: 1,
            startSection: 1,
            endSection: 2,
            weeks: [1, 2, 3, 4]),
      ],
    );

void main() {
  test('evidence 是原文片段的 issue 通过核验', () {
    final text = '{"issues":[{"course_index":0,"field":"location",'
        '"problem":"教室不符","evidence":"张三 教1-101","suggestion":"教1-102"}],"uncertain":[]}';
    final v = parseReviewVerdict(text, page);
    expect(v, isNotNull);
    expect(v!.issues.length, 1);
    expect(v.issues.single.suggestion, '教1-102');
  });

  test('evidence 不在原文中的 issue 降级为 uncertain(防审查者幻觉)', () {
    final text = '{"issues":[{"course_index":0,"field":"location",'
        '"problem":"教室不符","evidence":"这里根本不存在这句话","suggestion":"X"}],"uncertain":[]}';
    final v = parseReviewVerdict(text, page);
    expect(v!.issues, isEmpty, reason: '伪证 issue 不自动应用');
    expect(v.uncertain.single.problem, contains('证据无法核实'));
  });

  test('过短的 evidence(去除空白后 <4 字符)不通过核验', () {
    final text = '{"issues":[{"course_index":0,"field":"location",'
        '"problem":"教室不符","evidence":"周","suggestion":"X"}],"uncertain":[]}';
    final v = parseReviewVerdict(text, page);
    expect(v!.issues, isEmpty);
    expect(v.uncertain, isNotEmpty);
  });

  test('跨单元格引用(带空格)可以命中原文', () {
    final text = '{"issues":[{"course_index":0,"field":"location",'
        '"problem":"教室不符","evidence":"张三 教1-101","suggestion":"教1-102"}],"uncertain":[]}';
    final v = parseReviewVerdict(text, page);
    expect(v!.issues, hasLength(1));
  });

  test('无法自证的疑问进入 uncertain', () {
    final text =
        '{"issues":[],"uncertain":[{"course_index":0,"problem":"周次疑似有误"}]}';
    final v = parseReviewVerdict(text, page);
    expect(v!.issues, isEmpty);
    expect(v.uncertain.single.problem, contains('周次'));
  });

  test('非 JSON 输出返回 null', () {
    expect(parseReviewVerdict('我觉得没问题', page), isNull);
  });

  test('applyReviewIssues 应用合法字段,忽略非法值', () {
    final (revised, applied) = applyReviewIssues(draft(), [
      const ReviewIssue(
          courseIndex: 0,
          field: 'location',
          problem: '',
          evidence: '',
          suggestion: '教1-102'),
      const ReviewIssue(
          courseIndex: 0,
          field: 'weeks',
          problem: '',
          evidence: '',
          suggestion: '1,3,5,7'),
      const ReviewIssue(
          courseIndex: 0,
          field: 'dayOfWeek',
          problem: '',
          evidence: '',
          suggestion: '不是数字'),
      const ReviewIssue(
          courseIndex: 99, field: 'name', problem: '', evidence: '', suggestion: '越界'),
    ]);
    expect(applied, 2);
    expect(revised.courses.single.location, '教1-102');
    expect(revised.courses.single.weeks, [1, 3, 5, 7]);
    expect(revised.courses.single.dayOfWeek, 1);
  });

  test('周次建议支持区间展开,不会拆成端点', () {
    final (revised, applied) = applyReviewIssues(draft(), [
      const ReviewIssue(
          courseIndex: 0,
          field: 'weeks',
          problem: '',
          evidence: '',
          suggestion: '1-16'),
    ]);
    expect(applied, 1);
    // "1-16" 展开为 1..16,而不是错误地解析成 [1, 16]
    expect(revised.courses.single.weeks.length, 16);
    expect(revised.courses.single.weeks.first, 1);
    expect(revised.courses.single.weeks.last, 16);
  });
}
