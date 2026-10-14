/// OpenAI 兼容 chat/completions 实现:智谱 / DeepSeek / Kimi / 通义 / 硅基流动 / Ollama 通吃。
/// 重试(网络/5xx)由引擎编排层负责,本类单次调用不重试。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io'
    show
        ConnectionTask,
        HttpClient,
        HttpException,
        InternetAddress,
        InternetAddressType,
        Socket,
        SocketException;

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' as http_io;

import 'llm_client.dart';

/// 连接与鉴权配置。
class OpenAiCompatibleConfig {
  final String baseUrl; // 如 https://api.openai.com/v1
  final String apiKey; // Ollama 等本地端点可为空串
  final String model;

  /// 某些本地端点(如部分 Ollama 网关)不校验鉴权头;默认仍发送。
  final bool sendAuthHeader;

  const OpenAiCompatibleConfig({
    required this.baseUrl,
    required this.model,
    this.apiKey = '',
    this.sendAuthHeader = true,
  });

  /// 拼接 chat/completions 端点,容忍末尾斜杠与缺失 /v1 的情况由用户配置承担。
  Uri get endpoint {
    var base = baseUrl.trim();
    if (base.endsWith('/')) base = base.substring(0, base.length - 1);
    return Uri.parse('$base/chat/completions');
  }
}

class OpenAiCompatibleClient implements LlmClient {
  final OpenAiCompatibleConfig config;
  final Duration connectTimeout;
  final Duration responseTimeout;

  /// 主通道:dart:io 默认拨号(双栈、Happy Eyeballs)。
  final http.Client _primary;

  /// 兜底通道:IPv4 优先的自定义拨号,仅当主通道在连接阶段失败时启用。
  /// 注:经过 connectionFactory 的连接,其 TLS 升级路径与默认拨号存在
  /// 握手特征差异,个别严格 WAF(如火山引擎防护的端点)会以 301 拒绝
  /// 工厂连接而放行默认连接——因此默认连接可用时绝不走工厂。
  final http.Client? _fallback;

  OpenAiCompatibleClient({
    required this.config,
    http.Client? httpclient,
    this.connectTimeout = const Duration(seconds: 10),
    this.responseTimeout = const Duration(seconds: 120),
  })  : _primary = httpclient ??
            http_io.IOClient(HttpClient()
              ..connectionTimeout = connectTimeout),
        _fallback = httpclient == null ? _ipv4FirstClient(connectTimeout) : null;

  /// 统一发送:主通道连接阶段失败(SocketException/超时,典型如模拟器
  /// NAT 无 IPv6 路由)时,重建请求走 IPv4 优先兜底通道重试一次。
  /// 请求体由 [build] 闭包重建——package:http 的 Request 只能消费一次。
  Future<http.StreamedResponse> _send(
      http.Request Function() build) async {
    final overall = responseTimeout + connectTimeout;
    try {
      return await _primary.send(build()).timeout(overall);
    } on SocketException catch (e) {
      return _viaFallback(build, overall, e);
    } on TimeoutException catch (e) {
      return _viaFallback(build, overall, e);
    } on HttpException catch (e) {
      return _viaFallback(build, overall, e);
    }
  }

  Future<http.StreamedResponse> _viaFallback(
      http.Request Function() build, Duration overall, Object cause) async {
    final fb = _fallback;
    if (fb == null) throw cause;
    return await fb.send(build()).timeout(overall);
  }

  /// IPv4 优先拨号:解析地址先试 A 记录,单地址超时即取消换下一个。
  /// 用于默认拨号不可用的环境(如无 IPv6 路由的安卓模拟器)。
  static http.Client _ipv4FirstClient(Duration connectTimeout) {
    final inner = HttpClient()
      ..connectionFactory = (Uri uri, String? proxyHost, int? proxyPort) async {
        final host = proxyHost ?? uri.host;
        final port = proxyPort ?? uri.port;
        final addresses = await InternetAddress.lookup(host);
        final sorted = [...addresses]
          ..sort((a, b) {
            final a4 = a.type == InternetAddressType.IPv4 ? 0 : 1;
            final b4 = b.type == InternetAddressType.IPv4 ? 0 : 1;
            return a4 - b4;
          });
        Object? lastError;
        for (final addr in sorted) {
          try {
            final task = await Socket.startConnect(addr, port);
            return ConnectionTask.fromSocket(
              task.socket.timeout(
                connectTimeout,
                onTimeout: () {
                  task.cancel();
                  throw SocketException('连接超时(${connectTimeout.inSeconds}s)');
                },
              ),
              task.cancel,
            );
          } catch (e) {
            lastError = e;
          }
        }
        throw SocketException('所有地址均连接失败: $lastError');
      };
    return http_io.IOClient(inner);
  }

  Map<String, dynamic> _buildBody(LlmRequest request) {
    final body = <String, dynamic>{
      'model': config.model,
      'temperature': request.temperature,
      'messages': [
        {'role': 'system', 'content': request.systemPrompt},
        {'role': 'user', 'content': request.userPrompt},
      ],
    };

    if (request.tool != null) {
      body['tools'] = [
        {'type': 'function', 'function': request.tool}
      ];
      if (request.forceToolCall) {
        body['tool_choice'] = {
          'type': 'function',
          'function': {'name': request.tool!['name']},
        };
      }
    } else if (request.jsonMode) {
      body['response_format'] = {'type': 'json_object'};
    }
    return body;
  }

  @override
  Future<LlmResponse> complete(LlmRequest request) async {
    final body = _buildBody(request);

    http.Request build() {
      final req = http.Request('POST', config.endpoint)
        ..headers['Content-Type'] = 'application/json'
        ..headers['User-Agent'] =
            'CourseSight/0.1 (Android; OpenAI-compatible client)';
      if (config.sendAuthHeader && config.apiKey.isNotEmpty) {
        req.headers['Authorization'] = 'Bearer ${config.apiKey}';
      }
      req.body = jsonEncode(body);
      return req;
    }

    final http.Response resp;
    try {
      final streamed = await _send(build);
      resp = await http.Response.fromStream(streamed);
    } on TimeoutException catch (e) {
      throw LlmException(LlmErrorKind.network, '超时: ${e.message}');
    } catch (e) {
      throw LlmException(LlmErrorKind.network, e.toString());
    }

    switch (resp.statusCode) {
      case 200:
        break;
      case 301:
      case 302:
      case 307:
      case 308:
        // POST 的重定向不可自动跟随(301 会退化为 GET,必被 API 拒绝),
        // 把 Location 与 WAF 线索报给用户排查 Base URL。
        final cookie = resp.headers['set-cookie'];
        throw LlmException(
            LlmErrorKind.badResponse,
            'HTTP ${resp.statusCode}: 服务端要求跳转到 '
            '${resp.headers['location'] ?? '(响应未提供)'}'
            '${cookie != null ? '(并下发 Cookie,疑似 WAF 挑战)' : ''};'
            '请检查 Base URL 的协议与路径是否和服务商文档一致');
      case 401:
      case 403:
        throw LlmException(
            LlmErrorKind.auth, 'HTTP ${resp.statusCode}: ${_snippet(resp.body)}');
      case 404:
        throw LlmException(LlmErrorKind.modelNotFound,
            'HTTP 404: ${_snippet(resp.body)}');
      case 429:
        throw LlmException(LlmErrorKind.rateLimit,
            'HTTP 429: ${_providerMessage(resp.body)}');
      default:
        if (resp.statusCode >= 500) {
          throw LlmException(LlmErrorKind.providerError,
              'HTTP ${resp.statusCode}: ${_snippet(resp.body)}');
        }
        throw LlmException(LlmErrorKind.badResponse,
            'HTTP ${resp.statusCode}: ${_snippet(resp.body)}');
    }

    // 200 但结构畸形(缺 choices/message/类型不对)→ 统一映射 badResponse,
    // 绝不让 TypeError 逃出 LlmException 契约。
    final LlmResponse parsed;
    try {
      parsed = _parseSuccessResponse(utf8.decode(resp.bodyBytes));
    } catch (e) {
      throw LlmException(LlmErrorKind.badResponse, '响应结构异常: $e');
    }
    return parsed;
  }

  LlmResponse _parseSuccessResponse(String bodyText) {
    final data = jsonDecode(bodyText) as Map<String, dynamic>;
    final choices = data['choices'] as List?;
    if (choices == null || choices.isEmpty) {
      throw const FormatException('缺少 choices');
    }
    final first = choices.first;
    if (first is! Map) {
      throw const FormatException('choices[0] 不是对象');
    }
    final message = first['message'];
    if (message is! Map) {
      throw const FormatException('缺少 message');
    }

    final usage = data['usage'] as Map? ?? const {};
    final promptTokens = (usage['prompt_tokens'] as num?)?.toInt() ?? 0;
    final completionTokens = (usage['completion_tokens'] as num?)?.toInt() ?? 0;

    final toolCalls = message['tool_calls'] as List?;
    if (toolCalls != null && toolCalls.isNotEmpty) {
      final call = toolCalls.first;
      if (call is! Map) {
        throw const FormatException('tool_calls[0] 不是对象');
      }
      final function = call['function'];
      if (function is! Map) {
        throw const FormatException('function 不是对象');
      }
      return LlmResponse(
        toolCallName: function['name'] as String?,
        toolCallArguments: function['arguments'] as String?,
        promptTokens: promptTokens,
        completionTokens: completionTokens,
      );
    }

    return LlmResponse(
      textContent: message['content'] as String?,
      promptTokens: promptTokens,
      completionTokens: completionTokens,
    );
  }

  /// 从服务商错误响应中提取人类可读的 message(智谱/OpenAI 风格),
  /// 提取不到则退回原始片段。
  static String _providerMessage(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is Map && error['message'] is String) {
          final msg = error['message'] as String;
          return msg.length > 200 ? msg.substring(0, 200) : msg;
        }
        if (decoded['message'] is String) {
          final msg = decoded['message'] as String;
          return msg.length > 200 ? msg.substring(0, 200) : msg;
        }
      }
    } catch (_) {}
    return _snippet(body);
  }

  @override
  Future<LlmResponse> completeStream(
    LlmRequest request,
    void Function(String accumulated) onProgress, {
    void Function(int thoughtChars)? onThought,
  }) async {
    final body = _buildBody(request)..['stream'] = true;

    http.Request build() {
      final req = http.Request('POST', config.endpoint)
        ..headers['Content-Type'] = 'application/json'
        ..headers['User-Agent'] =
            'CourseSight/0.1 (Android; OpenAI-compatible client)';
      if (config.sendAuthHeader && config.apiKey.isNotEmpty) {
        req.headers['Authorization'] = 'Bearer ${config.apiKey}';
      }
      req.body = jsonEncode(body);
      return req;
    }

    final http.StreamedResponse resp;
    try {
      resp = await _send(build);
    } on TimeoutException catch (e) {
      throw LlmException(LlmErrorKind.network, '超时: ${e.message}');
    } catch (e) {
      throw LlmException(LlmErrorKind.network, e.toString());
    }

    if (resp.statusCode != 200) {
      final text = await resp.stream.bytesToString();
      // 3xx:POST 的重定向不可自动跟随(301 会退化为 GET,必被 API 拒绝)。
      // 把 Location 报给用户——重定向目标是排查 Base URL 的关键线索。
      if (resp.statusCode >= 300 && resp.statusCode < 400) {
        final location = resp.headers['location'] ?? '(响应未提供)';
        throw LlmException(LlmErrorKind.badResponse,
            'HTTP ${resp.statusCode}: 服务端要求跳转到 $location;请检查 Base URL 的协议与路径是否和服务商文档一致(如 https:// 是否写对)');
      }
      switch (resp.statusCode) {
        case 401:
        case 403:
          throw LlmException(
              LlmErrorKind.auth, 'HTTP ${resp.statusCode}: ${_snippet(text)}');
        case 404:
          throw LlmException(
              LlmErrorKind.modelNotFound, 'HTTP 404: ${_snippet(text)}');
        case 429:
          throw LlmException(
              LlmErrorKind.rateLimit, 'HTTP 429: ${_providerMessage(text)}');
        default:
          if (resp.statusCode >= 500) {
            throw LlmException(LlmErrorKind.providerError,
                'HTTP ${resp.statusCode}: ${_snippet(text)}');
          }
          throw LlmException(LlmErrorKind.badResponse,
              'HTTP ${resp.statusCode}: ${_snippet(text)}');
      }
    }

    // SSE 解析:按行拼 data: {...};累计 tool arguments / content 片段
    final toolNameBuf = StringBuffer();
    final toolArgsBuf = StringBuffer();
    final contentBuf = StringBuffer();
    final reasoningBuf = StringBuffer();
    var lastThoughtReport = 0;
    var promptTokens = 0;
    var completionTokens = 0;
    var gotAnyChunk = false;

    Future<void> consumeLine(String line) async {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith(':')) return;
      if (!trimmed.startsWith('data:')) return;
      final payload = trimmed.substring(5).trim();
      if (payload == '[DONE]') return;
      final Map<String, dynamic> chunk;
      try {
        chunk = jsonDecode(payload) as Map<String, dynamic>;
      } catch (_) {
        return; // 忽略无法解析的块
      }
      gotAnyChunk = true;
      final usage = chunk['usage'] as Map?;
      if (usage != null) {
        promptTokens = (usage['prompt_tokens'] as num?)?.toInt() ?? promptTokens;
        completionTokens =
            (usage['completion_tokens'] as num?)?.toInt() ?? completionTokens;
      }
      final choices = chunk['choices'] as List?;
      if (choices == null || choices.isEmpty) return;
      final choice = choices.first;
      if (choice is! Map) return;
      final delta = choice['delta'] as Map?;
      if (delta == null) return;
      final toolCalls = delta['tool_calls'] as List?;
      if (toolCalls != null) {
        for (final tc in toolCalls) {
          if (tc is! Map) continue;
          final function = tc['function'] as Map?;
          if (function == null) continue;
          final name = function['name'] as String?;
          if (name != null && name.isNotEmpty) {
            if (toolNameBuf.isEmpty) toolNameBuf.write(name);
          }
          final args = function['arguments'] as String?;
          if (args != null && args.isNotEmpty) {
            toolArgsBuf.write(args);
            onProgress(toolArgsBuf.toString());
          }
        }
      }
      final content = delta['content'] as String?;
      if (content != null && content.isNotEmpty) {
        contentBuf.write(content);
        onProgress(contentBuf.toString());
      }
      // 思考型模型:思考内容先于工具参数流出,节流上报字数以驱动 UI。
      final thought =
          (delta['reasoning_content'] ?? delta['reasoning']) as String?;
      if (thought != null && thought.isNotEmpty) {
        reasoningBuf.write(thought);
        if (reasoningBuf.length - lastThoughtReport >= 40) {
          lastThoughtReport = reasoningBuf.length;
          onThought?.call(reasoningBuf.length);
        }
      }
    }

    try {
      // 90 秒无任何数据视为死流;总时长受 send 的 timeout 保护
      final lines = resp.stream
          .timeout(const Duration(seconds: 90))
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      await for (final line in lines) {
        await consumeLine(line);
      }
    } on TimeoutException {
      throw const LlmException(LlmErrorKind.network, '流式响应中断(90s 无数据)');
    } catch (e) {
      if (!gotAnyChunk) {
        throw LlmException(LlmErrorKind.network, e.toString());
      }
      // 已收到部分数据但连接中断:返回已累计内容,交给上层校验判断
    }

    if (!gotAnyChunk) {
      throw const LlmException(LlmErrorKind.badResponse, '流式响应无有效数据');
    }
    return LlmResponse(
      toolCallName: toolNameBuf.isEmpty ? null : toolNameBuf.toString(),
      toolCallArguments: toolArgsBuf.isEmpty ? null : toolArgsBuf.toString(),
      textContent: contentBuf.isEmpty ? null : contentBuf.toString(),
      promptTokens: promptTokens,
      completionTokens: completionTokens,
    );
  }

  static String _snippet(String body) =>
      body.length > 300 ? '${body.substring(0, 300)}…' : body;
}
