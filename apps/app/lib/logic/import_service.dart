/// 导入服务:跑解析流水线、构造脱敏诊断包。
library;

import 'dart:convert';

import 'package:coursesight_core/coursesight_core.dart';

class ImportOutcome {
  final ParseResult result;
  final String url;
  final String diagnosticJson; // 失败/低分时给用户导出

  const ImportOutcome({
    required this.result,
    required this.url,
    required this.diagnosticJson,
  });
}

/// 构造脱敏诊断包:不含 apiKey、不含账密(账密根本不经过本应用)。
String buildDiagnosticJson({
  required String url,
  required String preprocessedHtml,
  required ParseDiagnostics diagnostics,
  required List<ParseWarning> warnings,
  required String model,
  required String baseUrl,
  String? errorDetail,
}) {
  return const JsonEncoder.withIndent('  ').convert({
    'app': 'CourseSight',
    'schemaVersion': TimetableData.schemaVersion,
    'time': DateTime.now().toIso8601String(),
    'url': url,
    'model': model,
    'baseUrl': baseUrl,
    'diagnostics': {
      'sourceChars': diagnostics.sourceChars,
      'preprocessedChars': diagnostics.preprocessedChars,
      'promptTokens': diagnostics.promptTokens,
      'completionTokens': diagnostics.completionTokens,
      'llmCalls': diagnostics.llmCalls,
      'formatRetries': diagnostics.formatRetries,
      'networkRetries': diagnostics.networkRetries,
      'reviewRounds': diagnostics.reviewRounds,
      'notes': diagnostics.notes,
    },
    'warnings': [for (final w in warnings) w.toJson()],
    'preprocessedHtml': preprocessedHtml,
    'error': ?errorDetail,
  });
}

/// 友好错误文案。
String friendlyLlmError(LlmException e) {
  switch (e.kind) {
    case LlmErrorKind.auth:
      return 'API Key 无效或已过期,请在设置中检查';
    case LlmErrorKind.modelNotFound:
      return '模型名不存在,请检查设置(也确认 baseURL 是否正确)';
    case LlmErrorKind.rateLimit:
      return '请求过于频繁,请稍后再试';
    case LlmErrorKind.providerError:
      return '服务商暂时出错,请稍后再试';
    case LlmErrorKind.network:
      return '网络连接失败,请检查网络与 Base URL';
    case LlmErrorKind.badResponse:
      return e.detail.contains('未解析出任何课程')
          ? '没有解析出课程:试试「电脑版」页面开关,或导出诊断包反馈'
          : '模型返回异常,可重试或导出诊断包反馈';
  }
}
