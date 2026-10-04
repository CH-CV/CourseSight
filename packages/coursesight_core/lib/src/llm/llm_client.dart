/// LLM 调用抽象:引擎只依赖本接口,网络实现由外部注入。
library;

/// 错误类别,映射到 App 层的友好文案。
enum LlmErrorKind {
  auth, // 401/403
  modelNotFound, // 404
  rateLimit, // 429
  providerError, // 5xx
  network, // 连接失败/超时
  badResponse, // 响应不是合法的 completions 结构
}

/// LLM 调用异常。[kind] 供上层决定是否重试与提示文案。
class LlmException implements Exception {
  final LlmErrorKind kind;
  final String detail;

  const LlmException(this.kind, this.detail);

  @override
  String toString() => 'LlmException(${kind.name}): $detail';
}

/// 单次 LLM 请求。引擎不关心 provider 差异,只描述"要什么"。
class LlmRequest {
  final String systemPrompt;
  final String userPrompt;
  final double temperature;

  /// 整表提交工具的 JSON 定义(OpenAI tools 格式);非空时走函数调用路径。
  final Map<String, dynamic>? tool;

  /// 强制模型立即调用 [tool] 指定的函数。
  final bool forceToolCall;

  /// 无 tools 时,若为 true 则请求 json_object 模式(退化路径)。
  final bool jsonMode;

  const LlmRequest({
    required this.systemPrompt,
    required this.userPrompt,
    this.temperature = 0.1,
    this.tool,
    this.forceToolCall = true,
    this.jsonMode = false,
  });
}

/// 单次 LLM 响应。[toolCallName]/[toolCallArguments] 与 [textContent] 二选一有值。
class LlmResponse {
  final String? toolCallName;
  final String? toolCallArguments; // JSON 字符串
  final String? textContent;
  final int promptTokens;
  final int completionTokens;

  const LlmResponse({
    this.toolCallName,
    this.toolCallArguments,
    this.textContent,
    this.promptTokens = 0,
    this.completionTokens = 0,
  });

  /// 是否给出了工具调用。
  bool get hasToolCall =>
      toolCallName != null && toolCallArguments != null;
}

/// LLM 客户端接口。App / 测试注入不同实现。
abstract interface class LlmClient {
  Future<LlmResponse> complete(LlmRequest request);

  /// 流式调用:SSE 增量到达时回调 [onProgress](参数为到目前为止累计的
  /// 工具参数/文本),思考型模型输出思考内容时回调 [onThought](参数为
  /// 已累计的思考字符数,节流上报),最终返回与 [complete] 相同语义的
  /// 完整响应。默认实现退化为非流式(不回调进度),供 fake 与简单实现复用。
  Future<LlmResponse> completeStream(
    LlmRequest request,
    void Function(String accumulated) onProgress, {
    void Function(int thoughtChars)? onThought,
  }) {
    return complete(request);
  }
}
