/// 导入向导:①LLM 配置检查 → ②webview 抓取 → ③结果预览确认。
library;


import 'dart:async';

import 'dart:convert';
import 'dart:io';

import 'package:coursesight_core/coursesight_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/entities.dart';
import '../../logic/import_service.dart';
import '../../logic/reminder_service.dart';
import '../../state/providers.dart';
import '../theme.dart';
import 'llm_config_panel.dart';

const _mobileUa =
    'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';
const _uaDesktop =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

class ImportScreen extends ConsumerStatefulWidget {
  const ImportScreen({super.key});

  @override
  ConsumerState<ImportScreen> createState() => _ImportScreenState();
}

enum _Phase { config, webview, preview }

class _ImportScreenState extends ConsumerState<ImportScreen> {
  _Phase _phase = _Phase.config;
  bool _desktopUa = false;
  bool _capturing = false;
  bool _parsing = false;
  String _parsingStage = '';

  InAppWebViewController? _webviewController;
  final _urlController = TextEditingController();
  var _certHintShown = false;

  ParseResult? _parseResult;
  var _checked = <int>{};
  var _recognized = <String>[]; // 流式生成过程中已识别的课程名
  final _expandedGroups = <String>{}; // 预览页展开详情的课程组(按课程名)
  DateTime? _parseStart; // 解析开始时间,overlay 显示已用时
  Timer? _elapsedTimer;

  @override
  void dispose() {
    _elapsedTimer?.cancel();
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _phase == _Phase.config,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (_phase == _Phase.preview) {
          setState(() => _phase = _Phase.webview);
          return;
        }
        // webview 阶段:先消费 webview 自身历史(SSO 登录多跳转),
        // 没有历史则回到向导第 1 步
        final controller = _webviewController;
        if (controller != null && await controller.canGoBack()) {
          await controller.goBack();
          return;
        }
        if (context.mounted) setState(() => _phase = _Phase.config);
      },
      child: Scaffold(
        appBar: AppBar(
          leading: BackButton(
            onPressed: () async {
              if (_phase == _Phase.preview) {
                setState(() => _phase = _Phase.webview);
                return;
              }
              final controller = _webviewController;
              if (_phase == _Phase.webview &&
                  controller != null &&
                  await controller.canGoBack()) {
                await controller.goBack();
                return;
              }
              if (context.mounted) {
                _phase == _Phase.webview
                    ? setState(() => _phase = _Phase.config)
                    : context.pop();
              }
            },
          ),
          title: Text(switch (_phase) {
            _Phase.config => '导入 · 1/3 AI 配置',
            _Phase.webview => '导入 · 2/3 打开教务页面',
            _Phase.preview => '导入 · 3/3 确认课表',
          }),
        ),
        body: switch (_phase) {
          _Phase.config => _buildConfig(),
          _Phase.webview => _buildWebview(),
          _Phase.preview => _buildPreview(),
        },
      ),
    );
  }

  // ── 第 1 步:配置检查 ──

  Widget _buildConfig() {
    final settings = ref.watch(settingsProvider);
    final configured =
        settings.llmBaseUrl.isNotEmpty && settings.llmModel.isNotEmpty;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Icon(
                  configured ? Icons.check_circle : Icons.info,
                  color: configured ? Colors.green : Colors.orange,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(configured
                      ? 'AI 已配置(${settings.llmModel})。'
                      : '第一次使用需要配置一个 AI 服务(自带 Key)。'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        LlmConfigPanel(
          onConfigured: () {
            if (mounted) setState(() => _phase = _Phase.webview);
          },
        ),
        const SizedBox(height: 16),
        if (configured)
          FilledButton.icon(
            onPressed: () => setState(() => _phase = _Phase.webview),
            icon: const Icon(Icons.arrow_forward),
            label: const Text('下一步:打开教务页面'),
          ),
      ],
    );
  }

  // ── 第 2 步:webview ──

  Widget _buildWebview() {
    return Column(
      children: [
        // 地址栏 + UA 切换
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              IconButton(
                tooltip: '后退',
                icon: const Icon(Icons.chevron_left),
                onPressed: () => _webviewController?.goBack(),
              ),
              IconButton(
                tooltip: '前进',
                icon: const Icon(Icons.chevron_right),
                onPressed: () => _webviewController?.goForward(),
              ),
              Expanded(
                child: TextField(
                  controller: _urlController,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.go,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '输入教务网址,如 jwxt.edu.cn',
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24)),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                  onSubmitted: _navigateTo,
                ),
              ),
              IconButton(
                tooltip: '刷新',
                icon: const Icon(Icons.refresh),
                onPressed: _reload,
              ),
              FilterChip(
                label: const Text('电脑版'),
                selected: _desktopUa,
                onSelected: (v) {
                  setState(() => _desktopUa = v);
                  _webviewController?.setSettings(
                    settings: InAppWebViewSettings(
                        userAgent: v ? _uaDesktop : _mobileUa),
                  );
                  _reload();
                },
              ),
            ],
          ),
        ),
        const Material(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '请在页面中登录你的学校账号——账密只提交给学校系统,本应用不接触、不存储。',
                style: TextStyle(fontSize: 11),
              ),
            ),
          ),
        ),
        Expanded(
          child: GestureDetector(
            onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
            child: Stack(
              children: [
              InAppWebView(
                initialSettings: InAppWebViewSettings(
                  userAgent: _desktopUa ? _uaDesktop : _mobileUa,
                  javaScriptEnabled: true,
                ),
                onWebViewCreated: (controller) {
                  _webviewController = controller;
                  // 部分安卓 webview 实现下,空 webview 的首个 loadUrl 会被吞;
                  // 创建后立即加载当前地址栏内容(无内容则加载空白页占位)
                  final raw = _urlController.text.trim();
                  _navigateTo(raw.isEmpty ? 'about:blank' : raw);
                },
                onLoadStart: (controller, url) {
                  _urlController.text = url.toString();
                },
                onLoadStop: (controller, url) {
                  _urlController.text = url.toString();
                },
                onReceivedError: (controller, request, error) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text('页面加载失败。'
                        'https 站点请在地址栏补全 https:// 前缀;'
                        '校内 http 站点确认已联网。'),
                    duration: const Duration(seconds: 4),
                  ));
                },
                onReceivedServerTrustAuthRequest: (controller, challenge) async {
                  // 教务内网自签名证书:默认拒绝;信任开关在设置
                  final trust = ref
                          .read(settingsProvider)
                          .get('trust_self_signed_cert') ==
                      'true';
                  if (trust) {
                    return ServerTrustAuthResponse(
                        action: ServerTrustAuthResponseAction.PROCEED);
                  }
                  if (mounted && !_certHintShown) {
                    _certHintShown = true;
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('证书不受信任,页面被拦截。'
                          '若是校内教务系统,可在设置中开启「信任自签名证书」。'),
                      duration: Duration(seconds: 4),
                    ));
                  }
                  return ServerTrustAuthResponse(
                      action: ServerTrustAuthResponseAction.CANCEL);
                },
              ),
              if (_capturing || _parsing)
                Positioned.fill(
                  child: ColoredBox(
                    color: Colors.black38,
                    child: Center(
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const CircularProgressIndicator(),
                              const SizedBox(height: 12),
                              Text(_parsing ? _parsingStage : '正在抓取页面…'),
                              if (_parsing && _parseStart != null) ...[
                                const SizedBox(height: 4),
                                Text(
                                    '已用时 ${DateTime.now().difference(_parseStart!).inSeconds} 秒',
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant)),
                              ],
                              if (_recognized.isNotEmpty) ...[
                                const SizedBox(height: 10),
                                Text('已识别 ${_recognized.length} 门',
                                    style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.bold)),
                                const SizedBox(height: 6),
                                ConstrainedBox(
                                  constraints: const BoxConstraints(
                                      maxHeight: 180, maxWidth: 280),
                                  child: SingleChildScrollView(
                                    child: Wrap(
                                      spacing: 6,
                                      runSpacing: 4,
                                      children: [
                                        for (final n in _recognized)
                                          Chip(
                                            label: Text(n,
                                                style: const TextStyle(
                                                    fontSize: 11)),
                                            visualDensity:
                                                VisualDensity.compact,
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _capturing || _parsing ? null : _captureAndParse,
                icon: const Icon(Icons.download),
                label: const Text('抓取此页并解析课表'),
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _navigateTo(String raw) {
    var url = raw.trim();
    if (url.isEmpty) return;
    // 收起键盘并让地址栏失焦——否则键盘遮住 webview,用户以为没反应
    FocusManager.instance.primaryFocus?.unfocus();
    if (url == 'about:blank') {
      _webviewController?.loadUrl(
          urlRequest: URLRequest(url: WebUri('about:blank')));
      return;
    }
    // 教务系统多数为 http,未写 scheme 时默认 http;https 站点请补全前缀
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'http://$url';
    }
    _webviewController?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  void _reload() {
    _webviewController?.reload();
  }

  Future<void> _captureAndParse() async {
    final controller = _webviewController;
    if (controller == null) return;
    setState(() {
      _capturing = true;
      _parsingStage = '';
      _recognized = [];
    });

    // 1) 抓取 HTML(顶层文档 + 同域 iframe 的 body 内容)
    // 多数教务系统(金智/正方等)把课表渲染在框架页的内嵌 iframe 里,
    // 仅取 outerHTML 拿不到 iframe 内容。
    // 不递归、总量封顶、全程防御:任何一步异常都退回纯 outerHTML,
    // 且外层有 25s 超时兜底——绝不允许无限"正在抓取"。
    String? html;
    try {
      // 安卓 WebView 的 evaluateJavascript 对超大返回值会静默失败返回 null,
      // 框架页 + iframe 拼接后可达数百 KB。因此分两步:
      // ① JS 在页面内完成拼接并存入 window.__csHtml,只返回长度;
      // ② Dart 按块取回(每块 100K),彻底绕开大返回值问题。
      const chunkSize = 100000;
      // evaluateJavascript 在 webview 刚恢复/页面切换瞬间可能返回 null。
      // 探测就绪状态并重试,每次探测结果都记录,便于定位。
      final probeLog = <String>[];
      int? totalLen;
      for (var attempt = 0; attempt < 5; attempt++) {
        final ready = await controller
            .evaluateJavascript(source: 'document.readyState')
            .timeout(const Duration(seconds: 5));
        probeLog.add('readyState=$ready');
        if ('$ready' == 'complete') {
          final lenResult = await controller
              .evaluateJavascript(source: r'''
(function(){
  try{
    var NL = String.fromCharCode(10);
    var parts = [document.documentElement.outerHTML];
    var frames = document.querySelectorAll('iframe, frame');
    for (var i = 0; i < frames.length; i++) {
      try {
        var d = frames[i].contentDocument;
        if (d && d.body) {
          parts.push(NL + '==IFRAME(' + (frames[i].src || '') + ')==' + NL
            + d.body.innerHTML + NL + '==END IFRAME==' + NL);
        }
      } catch (e) { }
    }
    var s = parts.join('');
    if (s.length > 1500000) s = s.substring(0, 1500000);
    window.__csHtml = s;
    return s.length;
  } catch (e) {
    window.__csHtml = document.documentElement.outerHTML;
    return window.__csHtml.length;
  }
})()''')
              .timeout(const Duration(seconds: 25));
          probeLog.add('len=$lenResult');
          final parsed = lenResult is int
              ? lenResult
              : int.tryParse('$lenResult');
          if (parsed != null && parsed > 0) {
            totalLen = parsed;
            break;
          }
        }
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      await _writeDebugFile('capture_debug.json', {
        'time': DateTime.now().toIso8601String(),
        'probes': probeLog,
        'url': _urlController.text.trim(),
      });
      if (totalLen == null) {
        _fail('抓取失败:JS 通道未就绪($probeLog),请稍候重试');
        return;
      }
      final buffer = StringBuffer();
      for (var offset = 0; offset < totalLen; offset += chunkSize) {
        final chunk = await controller.evaluateJavascript(
            source: 'window.__csHtml.substr($offset, $chunkSize)');
        if (chunk == null) {
          _fail('抓取失败:分块读取中断(已取 ${buffer.length}/$totalLen 字符),请重试');
          return;
        }
        buffer.write(chunk.toString());
      }
      html = buffer.toString();
    } on TimeoutException {
      _fail('抓取页面超时:页面可能仍在加载,请稍候重试');
      return;
    } catch (e) {
      _fail('抓取页面失败:$e');
      return;
    }
    if (html.length < 500) {
      _fail('页面可能未加载完(实际抓到 ${html.length} 字符),请稍候重试');
      return;
    }
    final pageHtml = html;
    setState(() {
      _capturing = false;
      _parsing = true;
      _parsingStage = '解析中…';
      _parseStart = DateTime.now();
    });
    // 秒表:即便厂商不流式(整包返回),用户也能看到请求确实在走
    _elapsedTimer?.cancel();
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _parsing) setState(() {});
    });

    // 2) 解析(核心流水线)——LLM 调用是纯网络 IO,在主 isolate 执行;
    //    进度回调实时更新界面(遮罩显示阶段与已识别课程)。
    final settings = ref.read(settingsProvider);
    final apiKey = await ref.read(settingsProvider.notifier).readApiKey();

    try {
      final client = OpenAiCompatibleClient(
        config: OpenAiCompatibleConfig(
          baseUrl: settings.llmBaseUrl,
          model: settings.llmModel,
          apiKey: apiKey ?? '',
          sendAuthHeader: (apiKey ?? '').isNotEmpty,
        ),
        responseTimeout: const Duration(seconds: 240),
      );
      final parser = CourseSightParser(
        llm: client,
        onRecognized: (names) {
          if (mounted && names.isNotEmpty) {
            setState(() {
              _recognized = List.unmodifiable(names);
              if (_parsingStage.startsWith('AI 思考中')) {
                _parsingStage = '解析中…';
              }
            });
          }
        },
        onThought: (chars) {
          if (mounted && _recognized.isEmpty) {
            setState(() => _parsingStage = 'AI 思考中(已思考 $chars 字)…');
          }
        },
        onStage: (stage) {
          if (mounted) {
            setState(() => _parsingStage = '$stage…');
          }
        },
      );
      final result = await parser.parse(
        ParseInput(data: pageHtml, hints: const ParseHints()),
      );
      await _writeDebugFile('last_result.json', {
        'time': DateTime.now().toIso8601String(),
        'courses': result.timetable.courses.length,
        'reviewRounds': result.diagnostics.reviewRounds,
        'llmCalls': result.diagnostics.llmCalls,
        'warnings': [for (final w in result.warnings) w.message],
      });
      setState(() {
        _parsing = false;
        _elapsedTimer?.cancel();
        _parseResult = result;
        _checked = {
          for (var i = 0; i < result.timetable.courses.length; i++) i
        };
        _phase = _Phase.preview;
      });
    } on LlmException catch (e) {
      _fail(friendlyLlmError(e),
          diagnosticHtml: pageHtml, errorDetail: '${e.kind.name}: ${e.detail}');
    } catch (e, st) {
      debugPrint('CS_PARSE_FAIL: $e');
      debugPrint('CS_PARSE_STACK: ${st.toString().split(';').take(10).join(' | ')}');
      _fail('解析失败,请重试或导出诊断包反馈',
          diagnosticHtml: pageHtml, errorDetail: e.toString());
    }
  }

  Future<void> _fail(String message,
      {String? diagnosticHtml, String? errorDetail}) async {
    _elapsedTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _capturing = false;
      _parsing = false;
    });
    final settings = ref.read(settingsProvider);
    final diagnosticJson = buildDiagnosticJson(
      url: _urlController.text.trim().isEmpty
          ? (diagnosticHtml != null ? '(当前页)' : '')
          : _urlController.text.trim(),
      preprocessedHtml: diagnosticHtml ?? '',
      diagnostics: const ParseDiagnostics(),
      warnings: const [],
      model: settings.llmModel,
      baseUrl: settings.llmBaseUrl,
      errorDetail: errorDetail,
    );
    await _writeDebugFile('last_error.json', {
      'time': DateTime.now().toIso8601String(),
      'message': message,
      'error': errorDetail,
      'url': _urlController.text.trim(),
      'capturedChars': diagnosticHtml?.length ?? 0,
    });
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('解析遇到问题'),
        content: Text(message),
        actions: [
          if (diagnosticHtml != null)
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                SharePlus.instance.share(ShareParams(
                  text: diagnosticJson,
                  title: 'CourseSight 诊断包',
                ));
              },
              child: const Text('导出诊断包'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('好的'),
          ),
        ],
      ),
    );
  }

  // ── 第 3 步:预览确认 ──

  Widget _buildPreview() {
    final result = _parseResult!;
    final courses = result.timetable.courses;
    final scheme = Theme.of(context).colorScheme;

    // 按课程名分组(保持首次出现顺序):一条记录=一个时段,一门课=一组
    final groups = <String, List<int>>{};
    for (var i = 0; i < courses.length; i++) {
      (groups[courses[i].name] ??= []).add(i);
    }
    final groupEntries = groups.entries.toList();

    return Column(
      children: [
        // 诊断信息 + 警告摘要
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '共解析出 ${courses.length} 条时段 · ${groupEntries.length} 门课程'
              '${result.diagnostics.reviewRounds > 0 ? ' · 审查 ${result.diagnostics.reviewRounds} 轮' : ''}'
              ' · 消耗 ~${result.diagnostics.promptTokens + result.diagnostics.completionTokens} tokens',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
        for (final w in result.warnings.take(6))
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '⚠ ${w.message}',
                style: TextStyle(
                    fontSize: 12,
                    color: w.code == WarningCode.reviewUncertain ||
                            w.code == WarningCode.reviewDisagreement
                        ? scheme.error
                        : Colors.orange),
              ),
            ),
          ),
        Expanded(
          child: ListView.builder(
            itemCount: groupEntries.length,
            itemBuilder: (context, gi) {
              final name = groupEntries[gi].key;
              final idxs = groupEntries[gi].value;
              final allChecked = idxs.every(_checked.contains);
              final expanded = _expandedGroups.contains(name);
              final lowConfidence =
                  idxs.any((i) => courses[i].confidence < 0.7);
              final slotsText = [
                for (final i in idxs)
                  '${weekDayNames[courses[i].dayOfWeek - 1]} '
                      '${courses[i].startSection}-${courses[i].endSection}节',
              ].join(' · ');
              return Column(
                children: [
                  CheckboxListTile(
                    value: allChecked,
                    onChanged: (v) => setState(() {
                      v == true
                          ? _checked.addAll(idxs)
                          : _checked.removeAll(idxs);
                    }),
                    secondary: GestureDetector(
                      onTap: () => setState(() {
                        expanded
                            ? _expandedGroups.remove(name)
                            : _expandedGroups.add(name);
                      }),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                              width: 12,
                              height: 28,
                              color: courseColor(
                                  courses[idxs.first].dayOfWeek + idxs.first)),
                          Icon(expanded ? Icons.expand_less : Icons.expand_more,
                              size: 18),
                        ],
                      ),
                    ),
                    title: Text(
                      name,
                      style: lowConfidence
                          ? TextStyle(color: scheme.error)
                          : null,
                    ),
                    subtitle: Text(
                      '${idxs.length} 个时段 · $slotsText',
                    ),
                  ),
                  if (expanded)
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final i in idxs)
                            _previewRecordDetail(courses, i, result.warnings),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => setState(() => _phase = _Phase.webview),
                    child: const Text('重新抓取'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _checked.isEmpty ? null : _saveCourses,
                    icon: const Icon(Icons.check),
                    label: Text('保存选中 ${_checked.length} 条时段'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 预览分组展开后的单条时段明细:独立勾选 + 全部字段 + 该时段的警告。
  Widget _previewRecordDetail(
      List<CourseData> courses, int i, List<ParseWarning> warnings) {
    final c = courses[i];
    final scheme = Theme.of(context).colorScheme;
    final relatedWarnings = [
      for (final w in warnings)
        if (w.courseIndex == i) w.message,
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 32,
                height: 32,
                child: Checkbox(
                  value: _checked.contains(i),
                  onChanged: (v) => setState(() {
                    v == true ? _checked.add(i) : _checked.remove(i);
                  }),
                  visualDensity: VisualDensity.compact,
                ),
              ),
              Expanded(
                child: Text(
                  '${weekDayNames[c.dayOfWeek - 1]} 第${c.startSection}-${c.endSection}节'
                  ' · ${c.location ?? '无地点'}'
                  '${c.confidence < 0.7 ? ' · ⚠ 低置信度' : ''}',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _previewDetailRow('教师', c.teacher ?? '(未识别)'),
                _previewDetailRow(
                    '周次',
                    c.weeks.length >= 24
                        ? '全学期(${c.weeks.length} 周)'
                        : '第 ${_weeksSummary(c.weeks)} 周'),
                _previewDetailRow('置信度', c.confidence.toStringAsFixed(2)),
                if (relatedWarnings.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '⚠ ${relatedWarnings.join('\n⚠ ')}',
                      style: TextStyle(fontSize: 12, color: scheme.error),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _previewDetailRow(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 52,
              child: Text(label,
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFF888888))),
            ),
            Expanded(
                child: Text(value,
                    style: const TextStyle(fontSize: 13))),
          ],
        ),
      );

  /// 周次摘要:连续段折叠为 a-b。
  String _weeksSummary(List<int> weeks) {
    if (weeks.isEmpty) return '-';
    final buf = StringBuffer();
    var start = weeks.first;
    var prev = weeks.first;
    for (final w in weeks.skip(1)) {
      if (w != prev + 1) {
        buf.write(start == prev ? '$start,' : '$start-$prev,');
        start = w;
      }
      prev = w;
    }
    buf.write(start == prev ? '$start' : '$start-$prev');
    return buf.toString();
  }

  Future<void> _saveCourses() async {
    final result = _parseResult!;
    final messenger = ScaffoldMessenger.of(context);

    // 建新课表(一学期一张;重复导入会生成新表,可在课表管理中删除旧表)
    final name = result.timetable.name ??
        '导入课表 ${DateTime.now().month}/${DateTime.now().day}';
    final timetableRepo = ref.read(timetableRepositoryProvider);

    try {
      final created = await timetableRepo.saveImportedTimetable(
        timetable: Timetable(
          name: name,
          firstWeekMonday: result.timetable.firstWeekMonday,
          totalWeeks: result.timetable.totalWeeks,
        ),
        sections: [
          for (final s in result.timetable.timeConfig)
            SectionTimeRow(
              timetableId: 0, // 事务内会被替换为真实 id
              section: s.section,
              startTime: s.startTime,
              endTime: s.endTime,
            ),
        ],
        courses: [
          for (var i = 0; i < result.timetable.courses.length; i++)
            if (_checked.contains(i))
              Course.fromCore(0, result.timetable.courses[i],
                  result.timetable.courses[i].name.hashCode.abs()),
        ],
      );

      // 切换为当前课表并刷新状态(先落数据,再切当前)
      await ref
          .read(settingsProvider.notifier)
          .set('current_timetable_id', '${created.id}');
      await ref.read(timetablesProvider.notifier).load();
      await ref.read(coursesProvider.notifier).loadFor(created.id!);
      await ref.read(sectionTimesProvider.notifier).loadFor(created.id!);
      await refreshAfterChange();

      messenger.showSnackBar(SnackBar(
          content: Text('已导入 ${_checked.length} 条课程到「$name」')));
      if (mounted) context.go('/');
    } catch (e) {
      messenger.showSnackBar(
          SnackBar(content: Text('保存失败,已回滚:$e')));
    }
  }
}



/// 调试通道:把最近一次解析的结局写入应用文档目录,可用 adb pull 读取
/// (release 下 logcat 不可靠,Flutter 文字也不进系统无障碍树,文本文件是唯一
/// 可靠通道)。仅写入应用私有目录,无对外传输。
Future<void> _writeDebugFile(String name, Map<String, dynamic> data) async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}/$name');
    await f.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
  } catch (_) {}
}
