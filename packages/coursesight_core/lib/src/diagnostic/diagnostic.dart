/// LLM 调用诊断信息(计入 ParseResult.diagnostics)。
class ParseDiagnostics {
  final int sourceChars; // 原始输入字符数
  final int preprocessedChars; // 预处理后字符数
  final int promptTokens;
  final int completionTokens;
  final int llmCalls; // LLM 总调用次数(生成+审查)
  final int formatRetries; // 格式校验失败重试次数
  final int networkRetries; // 网络重试次数
  final int reviewRounds; // 审查轮数
  final List<String> notes; // 过程备注(退化路径、异常等)

  const ParseDiagnostics({
    this.sourceChars = 0,
    this.preprocessedChars = 0,
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.llmCalls = 0,
    this.formatRetries = 0,
    this.networkRetries = 0,
    this.reviewRounds = 0,
    this.notes = const [],
  });

  ParseDiagnostics copyWith({
    int? sourceChars,
    int? preprocessedChars,
    int? promptTokens,
    int? completionTokens,
    int? llmCalls,
    int? formatRetries,
    int? networkRetries,
    int? reviewRounds,
    List<String>? notes,
  }) {
    return ParseDiagnostics(
      sourceChars: sourceChars ?? this.sourceChars,
      preprocessedChars: preprocessedChars ?? this.preprocessedChars,
      promptTokens: promptTokens ?? this.promptTokens,
      completionTokens: completionTokens ?? this.completionTokens,
      llmCalls: llmCalls ?? this.llmCalls,
      formatRetries: formatRetries ?? this.formatRetries,
      networkRetries: networkRetries ?? this.networkRetries,
      reviewRounds: reviewRounds ?? this.reviewRounds,
      notes: notes ?? this.notes,
    );
  }
}
