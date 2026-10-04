import 'dart:convert';
import 'dart:io';

import 'package:coursesight_core/coursesight_core.dart';
import 'package:test/test.dart';

/// 按脚本顺序回放响应的假 LLM,并记录每次请求供断言。
class FakeLlmClient implements LlmClient {
  final List<LlmResponse> script;
  final List<LlmRequest> requests = [];
  int cursor = 0;

  FakeLlmClient(this.script);

  @override
  Future<LlmResponse> complete(LlmRequest request) async {
    requests.add(request);
    if (cursor >= script.length) {
      throw StateError('脚本耗尽:收到第 ${requests.length} 次调用');
    }
    return script[cursor++];
  }

  @override
  Future<LlmResponse> completeStream(
    LlmRequest request,
    void Function(String accumulated) onProgress, {
    void Function(int thoughtChars)? onThought,
  }) async {
    final resp = await complete(request);
    if (resp.toolCallArguments != null) onProgress(resp.toolCallArguments!);
    if (resp.textContent != null) onProgress(resp.textContent!);
    return resp;
  }
}

LlmResponse toolResponse(Map<String, dynamic> payload) => LlmResponse(
      toolCallName: 'submit_timetable',
      toolCallArguments: jsonEncode(payload),
      promptTokens: 10,
      completionTokens: 5,
    );

LlmResponse textResponse(String text) =>
    LlmResponse(textContent: text, promptTokens: 10, completionTokens: 5);

Map<String, dynamic> goodSubmission() => {
      'totalWeeks': 16,
      'firstWeekMonday': '2026-03-02',
      'timeConfig': [
        {'section': 1, 'startTime': '08:00', 'endTime': '08:45'},
        {'section': 2, 'startTime': '08:55', 'endTime': '09:40'},
      ],
      'courses': [
        {
          'name': '高等数学',
          'teacher': '张三',
          'location': '教1-101',
          'dayOfWeek': 1,
          'startSection': 1,
          'endSection': 2,
          'weeks': [1, 3, 5, 7, 9, 11, 13, 15],
          'confidence': 0.95,
        },
        {
          'name': '大学英语',
          'location': '外语楼302',
          'dayOfWeek': 3,
          'startSection': 1,
          'endSection': 2,
          'weeks': [1, 3, 5, 7, 9, 11, 13, 15],
          'confidence': 0.9,
        },
      ],
    };

void main() {
  final html =
      File('test/fixtures/sample_zhengfang_style.html').readAsStringSync();

  test('完整流水线:生成→审查1轮发现问题修复→审查2轮通过', () async {
    final fake = FakeLlmClient([
      toolResponse(goodSubmission()),
      // 审查第 1 轮:指出大学英语的地点错了(证据取自页面原文)
      textResponse(jsonEncode({
        'issues': [
          {
            'course_index': 1,
            'field': 'location',
            'problem': '地点与页面不符',
            'evidence': '外语楼302 单周',
            'suggestion': '外语楼303',
          }
        ],
        'uncertain': [
          {'course_index': 0, 'problem': '教师姓名疑似缩写'}
        ],
      })),
      // 审查第 2 轮:通过
      textResponse(jsonEncode({'issues': [], 'uncertain': []})),
    ]);
    final parser = CourseSightParser(llm: fake, maxReviewRounds: 3);

    final result = await parser.parse(
      ParseInput(
          data: html,
          hints: const ParseHints(schoolName: '青云大学')),
    );

    // 修复已应用
    expect(result.timetable.courses[1].location, '外语楼303');
    expect(result.timetable.courses.first.name, '高等数学');
    expect(result.timetable.courses.first.weekType, WeekType.odd);
    expect(result.timetable.firstWeekMonday, '2026-03-02');

    // uncertain 进 warnings;无分歧
    expect(
        result.warnings.any((w) => w.code == WarningCode.reviewUncertain),
        isTrue);
    expect(
        result.warnings.every((w) => w.code != WarningCode.reviewDisagreement),
        isTrue);

    // 诊断:生成 1 + 审查 2 = 3 次调用
    expect(result.diagnostics.llmCalls, 3);
    expect(result.diagnostics.reviewRounds, 2);

    // 生成请求带了工具定义与强制调用
    expect(fake.requests.first.tool, isNotNull);
    expect(fake.requests.first.forceToolCall, isTrue);
    // 审查请求走 json 模式、不带工具
    expect(fake.requests[1].tool, isNull);
    expect(fake.requests[1].jsonMode, isTrue);
  });

  test('端点忽略工具调用:文本无合法结构时退化 json 模式重试成功', () async {
    final fake = FakeLlmClient([
      // 第 1 次:工具路径,端点回了不含合法结构的文本
      textResponse('我知道了,课表内容已收到。'),
      // 第 2 次(json 模式):给出完整 JSON
      textResponse('```json\n${jsonEncode(goodSubmission())}\n```'),
      // 审查 1 轮通过
      textResponse(jsonEncode({'issues': [], 'uncertain': []})),
    ]);
    final parser = CourseSightParser(llm: fake);

    final result = await parser.parse(ParseInput(data: html));
    expect(result.timetable.courses.length, 2);
    expect(
        result.diagnostics.notes.join('\n'), contains('退化 json_object'));
    expect(fake.requests[0].tool, isNotNull);
    expect(fake.requests[1].tool, isNull);
    expect(fake.requests[1].jsonMode, isTrue);
  });

  test('工具路径下端点直接回含合法结构的文本:直接采用,不退化', () async {
    final fake = FakeLlmClient([
      textResponse('```json\n${jsonEncode(goodSubmission())}\n```'),
      textResponse(jsonEncode({'issues': [], 'uncertain': []})),
    ]);
    final parser = CourseSightParser(llm: fake);
    final result = await parser.parse(ParseInput(data: html));
    expect(result.timetable.courses.length, 2);
    expect(result.diagnostics.llmCalls, 2);
  });

  test('首次提交有硬伤:带错误反馈重试一次', () async {
    final fake = FakeLlmClient([
      // 第 1 次:缺 courses → 校验硬伤
      toolResponse({'totalWeeks': 16}),
      // 重试:正常提交
      toolResponse(goodSubmission()),
      // 审查通过
      textResponse(jsonEncode({'issues': [], 'uncertain': []})),
    ]);
    final parser = CourseSightParser(llm: fake);

    final result = await parser.parse(ParseInput(data: html));
    expect(result.timetable.courses.length, 2);
    expect(result.diagnostics.formatRetries, 1);
    expect(fake.requests[1].userPrompt, contains('你上次的提交存在以下问题'));
  });

  test('伪证 issue(证据不在原文)降级为 uncertain,不静默消失', () async {
    final fake = FakeLlmClient([
      toolResponse(goodSubmission()),
      // evidence 是编造的 → 核验失败 → 降级 uncertain;issues 为空 → 审查通过
      textResponse(jsonEncode({
        'issues': [
          {
            'course_index': 0,
            'field': 'name',
            'problem': '课程名错误',
            'evidence': '这段话页面里根本不存在',
            'suggestion': '伪造的课',
          }
        ],
        'uncertain': [],
      })),
    ]);
    final parser = CourseSightParser(llm: fake);

    final result = await parser.parse(ParseInput(data: html));
    // 课程名未被篡改
    expect(result.timetable.courses.first.name, '高等数学');
    // 分歧没有消失:降级警告必须可见
    expect(
        result.warnings.any((w) =>
            w.code == WarningCode.reviewUncertain &&
            w.message.contains('证据无法核实')),
        isTrue);
  });

  test('审查者坚持错误证据:无法自动修复时记分歧警告', () async {
    final fake = FakeLlmClient([
      toolResponse(goodSubmission()),
      // issue 的 evidence 不在页面里 → 被丢弃 → applied==0(issues 也为空)
      // 为了触发 applied==0 分支,构造 evidence 在页面中存在但 suggestion 无法解析的字段
      textResponse(jsonEncode({
        'issues': [
          {
            'course_index': 0,
            'field': 'totally_unknown_field',
            'problem': '未知字段',
            'evidence': '高等数学',
            'suggestion': '任意',
          }
        ],
        'uncertain': [],
      })),
    ]);
    final parser = CourseSightParser(llm: fake, maxReviewRounds: 3);

    final result = await parser.parse(ParseInput(data: html));
    expect(
        result.warnings.any((w) => w.code == WarningCode.reviewDisagreement),
        isTrue,
        reason: '未知字段应用数=0,应记分歧');
  });

  test('首次提交有硬伤且重试仍失败:抛出并带错误描述', () async {
    final fake = FakeLlmClient([
      toolResponse({'totalWeeks': 16}),
      toolResponse({'totalWeeks': 16}),
    ]);
    final parser = CourseSightParser(llm: fake);
    await expectLater(
      parser.parse(ParseInput(data: html)),
      throwsA(isA<LlmException>()),
    );
    expect(fake.requests[1].userPrompt, contains('你上次的提交存在以下问题'));
  });

  test('8 节以上课表越界截断后仍能通过(集成冒烟)', () async {
    final payload = goodSubmission();
    payload['courses'] = [
      {
        ...goodSubmission()['courses'][0] as Map<String, dynamic>,
        'startSection': 2,
        'endSection': 30,
      },
    ];
    final fake = FakeLlmClient([
      toolResponse(payload),
      textResponse(jsonEncode({'issues': [], 'uncertain': []})),
    ]);
    final parser = CourseSightParser(llm: fake);
    final result = await parser.parse(ParseInput(data: html));
    expect(result.timetable.courses.single.endSection, 2);
  });
}
