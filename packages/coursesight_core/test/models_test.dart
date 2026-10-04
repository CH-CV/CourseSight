import 'package:coursesight_core/coursesight_core.dart';
import 'package:test/test.dart';

void main() {
  test('TimetableData JSON 往返保真', () {
    final original = TimetableData(
      name: '2025-2026 第二学期',
      totalWeeks: 16,
      firstWeekMonday: '2026-03-02',
      timeConfig: const [
        SectionTime(section: 1, startTime: '08:00', endTime: '08:45'),
        SectionTime(section: 2, startTime: '08:55', endTime: '09:40'),
      ],
      courses: const [
        CourseData(
          name: '高等数学',
          teacher: '张三',
          location: '教1-101',
          dayOfWeek: 1,
          startSection: 1,
          endSection: 2,
          weeks: [1, 3, 5, 7, 9, 11, 13, 15],
          weekType: WeekType.odd,
          confidence: 0.95,
        ),
      ],
    );

    final restored = TimetableData.fromJson(original.toJson());
    expect(TimetableData.schemaVersion, 1);
    expect(restored.name, original.name);
    expect(restored.totalWeeks, 16);
    expect(restored.firstWeekMonday, '2026-03-02');
    expect(restored.timeConfig.length, 2);
    expect(restored.courses.single.name, '高等数学');
    expect(restored.courses.single.weeks, original.courses.single.weeks);
    expect(restored.courses.single.weekType, WeekType.odd);
    expect(restored.courses.single.confidence, 0.95);
  });

  test('ParseWarning JSON 往返', () {
    const w = ParseWarning(WarningCode.lowConfidence, '请核对', courseIndex: 3);
    final restored = ParseWarning.fromJson(w.toJson());
    expect(restored.code, WarningCode.lowConfidence);
    expect(restored.courseIndex, 3);
  });

  test('conflictsWith:同天节次重叠且周次重叠才冲突', () {
    const a = CourseData(
        name: 'A',
        dayOfWeek: 1,
        startSection: 1,
        endSection: 2,
        weeks: [1, 2, 3]);
    const bSame = CourseData(
        name: 'B',
        dayOfWeek: 1,
        startSection: 2,
        endSection: 3,
        weeks: [2]);
    const bDiffWeek = CourseData(
        name: 'C',
        dayOfWeek: 1,
        startSection: 2,
        endSection: 3,
        weeks: [4]);
    const bDiffDay = CourseData(
        name: 'D',
        dayOfWeek: 2,
        startSection: 2,
        endSection: 3,
        weeks: [1, 2, 3]);
    expect(a.conflictsWith(bSame), isTrue);
    expect(a.conflictsWith(bDiffWeek), isFalse);
    expect(a.conflictsWith(bDiffDay), isFalse);
  });

  test('weekOfDate 周次推算(周一为周首)', () {
    expect(weekOfDate('2026-03-02', DateTime(2026, 3, 2)), 1);
    expect(weekOfDate('2026-03-02', DateTime(2026, 3, 8)), 1);
    expect(weekOfDate('2026-03-02', DateTime(2026, 3, 9)), 2);
    expect(weekOfDate('2026-03-02', DateTime(2026, 3, 1)), 0);
  });

  test('weekOfDate 非周一锚点与周日周首', () {
    // 学校声明第一教学周从 2026-03-04(周三)开始,周首=周一
    // → 周首回退到 03-02,该周为第 1 周
    expect(weekOfDate('2026-03-04', DateTime(2026, 3, 2)), 1);
    expect(weekOfDate('2026-03-04', DateTime(2026, 3, 4)), 1);
    expect(weekOfDate('2026-03-04', DateTime(2026, 3, 8)), 1);
    expect(weekOfDate('2026-03-04', DateTime(2026, 3, 9)), 2);

    // 周日为周首的学校:锚点 2026-03-01(周日)
    // 2/28(周六)属于上一周 → 0;3/1~3/7 是第 1 周
    expect(weekOfDate('2026-03-01', DateTime(2026, 3, 1), weekStartDay: 7), 1);
    expect(weekOfDate('2026-03-01', DateTime(2026, 3, 7), weekStartDay: 7), 1);
    expect(weekOfDate('2026-03-01', DateTime(2026, 3, 8), weekStartDay: 7), 2);
    expect(weekOfDate('2026-03-01', DateTime(2026, 2, 28), weekStartDay: 7), 0);

    // 周日周首但锚点落在周三(如 3-4 开学):回退到 3-1(周日)
    expect(weekOfDate('2026-03-04', DateTime(2026, 3, 1), weekStartDay: 7), 1);
    expect(weekOfDate('2026-03-04', DateTime(2026, 3, 8), weekStartDay: 7), 2);
  });
}
