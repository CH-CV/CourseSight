/// 解析编排:预处理 → 生成(整表提交)→ 校验 → 审查循环 → 规范化。
/// LLM 经 [LlmClient] 注入;网络/5xx 重试与格式重试分开计数。
library;

import 'dart:async';
import 'dart:convert';

import 'diagnostic/diagnostic.dart';
import 'llm/llm_client.dart';
import 'model/models.dart';
import 'normalize/normalizer.dart';
import 'preprocess/preprocessor.dart';
import 'prompt/prompt_builder.dart';
import 'review/reviewer.dart';
import 'validate/validator.dart' show sanitizeTimetable, validateSubmission;

/// 过程中的可变诊断累加器,结束时转成不可变的 [ParseDiagnostics]。
class _DiagAcc {
  int promptTokens = 0;
  int completionTokens = 0;
  int llmCalls = 0;
  int formatRetries = 0;
  int networkRetries = 0;
  int reviewRounds = 0;
  final List<String> notes = [];

  void note(String msg) => notes.add(msg);
}

class CourseSightParser {
  final LlmClient llm;
  final Preprocessor preprocessor;

  /// 审查轮数上限:发现问题修复后可再审,默认上限 3。
  final int maxReviewRounds;

  /// 网络/服务端错误重试次数(指数退避)。
  final int networkRetries;

  /// 阶段进度回调(在调用方所在的 isolate 同步触发)。
  final void Function(String stage)? onStage;

  /// 生成过程实时回调:到目前为止 AI 已"写出"的课程名列表(流式增量)。
  final void Function(List<String> names)? onRecognized;

  /// 思考型模型的思考进度回调:已累计的思考字符数(节流上报)。
  final void Function(int thoughtChars)? onThought;

  CourseSightParser({
    required this.llm,
    this.preprocessor = const Preprocessor(),
    this.maxReviewRounds = 3,
    this.networkRetries = 2,
    this.onStage,
    this.onRecognized,
    this.onThought,
  });

  Future<ParseResult> parse(ParseInput input) async {
    if (input.sourceType != SourceType.html) {
      // assert 在 release 下会被剥离,必须显式抛出
      throw UnsupportedError(
          'MVP 仅支持 html 输入,收到 ${input.sourceType.name}');
    }
    final diag = _DiagAcc();
    final warnings = <ParseWarning>[];
    final seenUncertain = <String>{}; // (courseIndex, message) 去重

    // 1) 预处理
    onStage?.call('预处理页面');
    final preprocessWatch = Stopwatch()..start();
    final pre = preprocessor.process(input.data);
    diag.note('预处理耗时 ${preprocessWatch.elapsedMilliseconds}ms');

    // 2) 生成:整表提交;端点不支持工具调用时退化 json_object 模式
    final userPrompt = buildGeneratorUserPrompt(
      pre.text,
      input.hints?.schoolName,
      input.hints?.systemName,
    );
    final tool = buildSubmitTimetableTool();

    var useToolPath = true;
    Map<String, dynamic>? raw;
    for (var attempt = 0; attempt < 2 && raw == null; attempt++) {
      onStage?.call(
          attempt == 0 ? 'AI 生成课表' : 'AI 生成课表(重试)');
      final resp = await _call(
        diag,
        LlmRequest(
          systemPrompt: generatorSystemPrompt,
          userPrompt: userPrompt,
          tool: useToolPath ? tool : null,
          jsonMode: !useToolPath,
        ),
        onProgress: onRecognized == null
            ? null
            : (acc) => onRecognized!(extractRecognizedCourseNames(acc)),
      );

      if (resp.hasToolCall) {
        raw = _decodeArguments(resp.toolCallArguments!);
        if (raw == null) diag.note('工具参数不是合法 JSON');
      } else if (resp.textContent != null) {
        // 部分端点忽略 tool_choice 直接给文本:能取出合法结构就用它
        final extracted = extractJsonObject(resp.textContent!);
        if (extracted != null && extracted['courses'] is List) {
          raw = extracted;
        } else if (useToolPath) {
          useToolPath = false;
          diag.note('端点未返回工具调用,退化 json_object 模式');
        }
      } else if (useToolPath) {
        useToolPath = false;
        diag.note('端点响应为空,退化 json_object 模式');
      }
      if (raw == null && attempt == 0 && useToolPath) {
        useToolPath = false;
        diag.note('首次生成失败,退化 json_object 模式重试');
      }
    }
    if (raw == null) {
      throw const LlmException(
          LlmErrorKind.badResponse, '未能从模型获得合法的课表提交');
    }

    // 3) 校验(硬伤带错误反馈重试 1 次)
    var result = validateSubmission(raw,
        expectedCourseNameCount: pre.estimatedCourseNameCount);
    if (!result.ok) {
      diag.formatRetries++;
      onStage?.call('AI 修正格式');
      final resp = await _call(
        diag,
        LlmRequest(
          systemPrompt: generatorSystemPrompt,
          userPrompt: '$userPrompt\n\n'
              '你上次的提交存在以下问题,请修正后重新提交:\n'
              '${result.errors.map((e) => '- $e').join('\n')}',
          tool: useToolPath ? tool : null,
          jsonMode: !useToolPath,
        ),
        onProgress: onRecognized == null
            ? null
            : (acc) => onRecognized!(extractRecognizedCourseNames(acc)),
      );
      final retryRaw = resp.hasToolCall
          ? _decodeArguments(resp.toolCallArguments ?? '')
          : (resp.textContent != null
              ? extractJsonObject(resp.textContent!)
              : null);
      var fixed = false;
      if (retryRaw != null) {
        final retryResult = validateSubmission(retryRaw,
            expectedCourseNameCount: pre.estimatedCourseNameCount);
        if (retryResult.ok || retryResult.timetable.courses.isNotEmpty) {
          result = retryResult;
          fixed = true;
        }
      }
      if (!fixed && !result.ok) {
        throw LlmException(LlmErrorKind.badResponse, result.errors.join(';'));
      }
    }
    warnings.addAll(result.warnings);

    // 4) 审查循环:空白上下文审查者,侧重点按轮轮换。
    // 审查是增强环节而非否决环节:审查调用失败只降级,不丢弃已生成的草稿。
    var draft = result.timetable;
    for (var round = 0; round < maxReviewRounds; round++) {
      ReviewVerdict? verdict;
      try {
        onStage?.call('交叉审查 · 第 ${round + 1} 轮');
        verdict = await _reviewRound(draft, pre.text, round, diag);
      } on LlmException catch (e) {
        // 原因写进警告与诊断:降级不该是黑箱,便于定位端点兼容性问题
        final reason = '${e.kind.name}: ${e.detail}';
        diag.note('第 ${round + 1} 轮审查调用失败($reason),已跳过审查');
        warnings.add(ParseWarning(WarningCode.reviewDegraded,
            '审查环节不可用(原因:$reason),结果未经交叉审核,请人工核对'));
        break;
      }

      if (verdict == null) {
        diag.note('第 ${round + 1} 轮审查输出无法解析,已跳过');
        warnings.add(const ParseWarning(WarningCode.reviewDegraded,
            '审查输出异常,结果未经完整审核,请人工核对'));
        break;
      }

      for (final u in verdict.uncertain) {
        final name = _courseNameAt(draft, u.courseIndex);
        final message = name == null ? u.problem : '「$name」${u.problem}';
        final key = '${u.courseIndex ?? -1}|$message';
        if (seenUncertain.add(key)) {
          warnings.add(ParseWarning(
            WarningCode.reviewUncertain,
            message,
            courseIndex: _indexOf(draft, u.courseIndex),
          ));
        }
      }

      if (verdict.issues.isEmpty) break;

      final (revised, applied) = applyReviewIssues(draft, verdict.issues);
      if (applied == 0) {
        warnings.add(const ParseWarning(WarningCode.reviewDisagreement,
            '审查发现的问题无法自动修复,请人工核对'));
        break;
      }
      // 修复后的草稿做与校验同源的安全钳制(节次上限、周次范围、空名清理)
      draft = sanitizeTimetable(revised);
      if (round == maxReviewRounds - 1) {
        warnings.add(const ParseWarning(WarningCode.reviewDisagreement,
            '审查轮次已达上限,请人工核对最近修改'));
      }
    }

    // 5) 规范化
    final normalized = normalize(draft);
    if (normalized.firstWeekMonday == null) {
      warnings.add(const ParseWarning(
          WarningCode.missingFirstWeek, '缺少第一周日期,无法推算实际日期'));
    }

    return ParseResult(
      timetable: normalized,
      warnings: warnings,
      diagnostics: ParseDiagnostics(
        sourceChars: input.data.length,
        preprocessedChars: pre.text.length,
        promptTokens: diag.promptTokens,
        completionTokens: diag.completionTokens,
        llmCalls: diag.llmCalls,
        formatRetries: diag.formatRetries,
        networkRetries: diag.networkRetries,
        reviewRounds: diag.reviewRounds,
        notes: List.unmodifiable(diag.notes),
      ),
    );
  }

  /// 统一的 LLM 调用入口:网络/5xx 指数退避重试,token 与调用数记账。
  /// [onProgress] 非空时走流式(SSE);[onThought] 透传思考进度。
  Future<LlmResponse> _call(_DiagAcc diag, LlmRequest request,
      {void Function(String accumulated)? onProgress}) async {
    for (var attempt = 0;; attempt++) {
      try {
        final resp = onProgress == null
            ? await llm.complete(request)
            : await llm.completeStream(request, onProgress,
                onThought: onThought);
        diag.llmCalls++;
        diag.promptTokens += resp.promptTokens;
        diag.completionTokens += resp.completionTokens;
        return resp;
      } on LlmException catch (e) {
        final retryable = e.kind == LlmErrorKind.network ||
            e.kind == LlmErrorKind.providerError;
        if (!retryable || attempt >= networkRetries) rethrow;
        diag.networkRetries++;
        diag.note('网络错误重试(${attempt + 1}/$networkRetries): ${e.kind.name}');
        await Future<void>.delayed(Duration(milliseconds: 500 << attempt));
      }
    }
  }

  Future<ReviewVerdict?> _reviewRound(
      TimetableData draft, String preprocessed, int round, _DiagAcc diag) async {
    final resp = await _call(
      diag,
      LlmRequest(
        systemPrompt: reviewerSystemPrompt(round),
        userPrompt: buildReviewerUserPrompt(
            preprocessed, const JsonEncoder().convert(draft.toJson())),
        temperature: 0.1,
        jsonMode: true,
      ),
      // 与生成同走流式:思考型模型整包返回可能超出响应超时,
      // 流式下只要数据持续流动就不设总时长天花板。
      onProgress: (_) {},
    );
    diag.reviewRounds++;
    if (resp.textContent == null) return null;
    return parseReviewVerdict(resp.textContent!, preprocessed);
  }

  static Map<String, dynamic>? _decodeArguments(String arguments) {
    try {
      final decoded = jsonDecode(arguments);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  static String? _courseNameAt(TimetableData t, int? index) {
    if (index == null || index < 0 || index >= t.courses.length) return null;
    return t.courses[index].name;
  }

  static int? _indexOf(TimetableData t, int? index) =>
      (index == null || index < 0 || index >= t.courses.length) ? null : index;
}
