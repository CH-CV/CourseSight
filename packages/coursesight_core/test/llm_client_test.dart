import 'dart:convert';

import 'package:coursesight_core/coursesight_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

typedef MockHandler = Future<http.Response> Function(http.Request req);

OpenAiCompatibleClient clientWith(MockHandler fn) =>
    OpenAiCompatibleClient(
      config: const OpenAiCompatibleConfig(
        baseUrl: 'https://llm.example.com/v1',
        apiKey: 'sk-test',
        model: 'test-model',
      ),
      httpclient: MockClient(fn),
    );

LlmRequest request() => const LlmRequest(
      systemPrompt: 'sys',
      userPrompt: 'usr',
      tool: {
        'name': 'submit_timetable',
        'parameters': {'type': 'object'}
      },
    );

void main() {
  test('成功解析工具调用响应', () async {
    final client = clientWith((req) async {
      expect(req.url.toString(), 'https://llm.example.com/v1/chat/completions');
      expect(req.headers['Authorization'], 'Bearer sk-test');
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      expect(body['tool_choice'], isNotNull, reason: '应强制调用工具');
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {
                'tool_calls': [
                  {
                    'function': {
                      'name': 'submit_timetable',
                      'arguments': '{"courses":[],"totalWeeks":16}'
                    }
                  }
                ]
              }
            }
          ],
          'usage': {'prompt_tokens': 100, 'completion_tokens': 20},
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final resp = await client.complete(request());
    expect(resp.hasToolCall, isTrue);
    expect(resp.toolCallName, 'submit_timetable');
    expect(resp.promptTokens, 100);
    expect(resp.completionTokens, 20);
  });

  test('json 模式解析文本响应', () async {
    final client = clientWith((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      expect(body['response_format']['type'], 'json_object');
      expect(body['tools'], isNull);
      return http.Response(
        jsonEncode({
          'choices': [
            {'message': {'content': '{"courses":[]}'}
          }],
          'usage': {},
        }),
        200,
      );
    });

    final resp = await client.complete(const LlmRequest(
      systemPrompt: 's',
      userPrompt: 'u',
      jsonMode: true,
    ));
    expect(resp.textContent, '{"courses":[]}');
  });

  test('401 → auth;429 → rateLimit;404 → modelNotFound;500 → providerError',
      () async {
    final cases = {401: LlmErrorKind.auth, 429: LlmErrorKind.rateLimit, 404: LlmErrorKind.modelNotFound, 500: LlmErrorKind.providerError};
    for (final entry in cases.entries) {
      final client = clientWith((req) async =>
          http.Response('{"error":"x"}', entry.key));
      await expectLater(
        client.complete(request()),
        throwsA(isA<LlmException>()
            .having((e) => e.kind, 'kind', entry.value)),
      );
    }
  });

  test('非 JSON 200 响应 → badResponse', () async {
    final client = clientWith((req) async => http.Response('not json', 200));
    await expectLater(
      client.complete(request()),
      throwsA(isA<LlmException>()
          .having((e) => e.kind, 'kind', LlmErrorKind.badResponse)),
    );
  });

  test('200 但结构畸形(choices/message 类型错误)→ badResponse,不逃逸 TypeError',
      () async {
    final malformedBodies = [
      jsonEncode({
        'choices': 'not-a-list',
        'usage': {},
      }),
      jsonEncode({
        'choices': [{'message': 'not-a-map'}],
        'usage': {},
      }),
      jsonEncode({'choices': []}),
      '{"choices":[{"message":{"tool_calls":[123]}}]}',
    ];
    for (final body in malformedBodies) {
      final client =
          clientWith((req) async => http.Response(body, 200));
      await expectLater(
        client.complete(request()),
        throwsA(isA<LlmException>()
            .having((e) => e.kind, 'kind', LlmErrorKind.badResponse)),
        reason: body,
      );
    }
  });

  test('连接失败 → network', () async {
    final client = OpenAiCompatibleClient(
      config: const OpenAiCompatibleConfig(
          baseUrl: 'https://127.0.0.1:1/v1', model: 'm'),
      httpclient: MockClient((req) async => throw Exception('refused')),
    );
    await expectLater(
      client.complete(request()),
      throwsA(isA<LlmException>()
          .having((e) => e.kind, 'kind', LlmErrorKind.network)),
    );
  });
  test('completeStream:SSE 增量拼装工具调用并回调进度', () async {
    const nl = '\n';
    final chunks = <String>[
      'data: {"choices":[{"delta":{"tool_calls":[{"function":{"name":"submit_timetable","arguments":"{\\"totalWeeks\\":"}}]}}]}'
          '$nl$nl',
      'data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"18,\\"courses\\":[{\\"name\\":\\"操作系统\\"}"}}]}}]}'
          '$nl$nl',
      r'data: {"choices":[{"delta":{}}],"usage":{"prompt_tokens":100,"completion_tokens":50}}'
          '$nl$nl',
      'data: [DONE]$nl$nl',
    ];
    final progress = <String>[];
    final mock = MockClient.streaming((request, bodyStream) async {
      return http.StreamedResponse(
        Stream<List<int>>.fromIterable(chunks.map(utf8.encode)),
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });
    final client = OpenAiCompatibleClient(
      config: const OpenAiCompatibleConfig(
          baseUrl: 'https://x.example/v1', model: 'm'),
      httpclient: mock,
    );
    final resp = await client.completeStream(
      const LlmRequest(systemPrompt: 's', userPrompt: 'u'),
      (acc) => progress.add(acc),
    );
    expect(resp.toolCallName, 'submit_timetable');
    expect(resp.toolCallArguments, contains('操作系统'));
    expect(resp.promptTokens, 100);
    expect(resp.completionTokens, 50);
    expect(progress, isNotEmpty);
    expect(progress.last, contains('操作系统'));
  });

  test('completeStream:思考型模型的 reasoning_content 驱动 onThought 节流上报', () async {
    const nl = '\n';
    // 60 字思考(触发一次 ≥40 阈值上报),随后才是工具参数
    final thought = '课表表头第一列是周日,' * 4; // 44 字
    final chunks = <String>[
      'data: {"choices":[{"delta":{"reasoning_content":"$thought"}}]}$nl$nl',
      'data: {"choices":[{"delta":{"reasoning_content":"$thought"}}]}$nl$nl',
      'data: {"choices":[{"delta":{"tool_calls":[{"function":{"name":"submit_timetable","arguments":"{\\"courses\\":[]}"}}]}}]}'
          '$nl$nl',
      'data: [DONE]$nl$nl',
    ];
    final mock = MockClient.streaming((request, bodyStream) async {
      return http.StreamedResponse(
        Stream<List<int>>.fromIterable(chunks.map(utf8.encode)),
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });
    final client = OpenAiCompatibleClient(
      config: const OpenAiCompatibleConfig(
          baseUrl: 'https://x.example/v1', model: 'm'),
      httpclient: mock,
    );
    final thoughts = <int>[];
    final resp = await client.completeStream(
      const LlmRequest(systemPrompt: 's', userPrompt: 'u'),
      (_) {},
      onThought: (n) => thoughts.add(n),
    );
    expect(resp.toolCallName, 'submit_timetable');
    // 88 字思考 → 至少上报两次(≥40、≥80);思考不计入工具参数
    expect(thoughts.length, greaterThanOrEqualTo(2));
    expect(thoughts.last, inInclusiveRange(80, 88));
  });
}
