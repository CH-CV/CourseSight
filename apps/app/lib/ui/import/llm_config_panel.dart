/// LLM 配置面板:provider 预设 + baseURL/model/key + 测试连接。
/// 导入向导第一步与设置页复用。
library;

import 'package:coursesight_core/coursesight_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';

class LlmPreset {
  final String name;
  final String baseUrl;
  final String model;
  final String hint;

  const LlmPreset(this.name, this.baseUrl, this.model, this.hint);
}

const llmPresets = <LlmPreset>[
  LlmPreset('智谱AI(GLM)', 'https://open.bigmodel.cn/api/paas/v4',
      'glm-5.3-flash', 'open.bigmodel.cn → API keys'),
  LlmPreset('阶跃星辰(StepFun)', 'https://api.stepfun.com/step_plan/v1',
      'step-5-preview', 'platform.stepfun.com → API Keys 管理'),
  LlmPreset('DeepSeek', 'https://api.deepseek.com/v1', 'deepseek-chat',
      'platform.deepseek.com → API keys,价格低'),
  LlmPreset('Kimi(月之暗面)', 'https://api.moonshot.cn/v1', 'kimi-k2',
      'platform.moonshot.cn → API Key 管理'),
  LlmPreset('通义千问(阿里云百炼)',
      'https://dashscope.aliyuncs.com/compatible-mode/v1', 'qwen-plus',
      'bailian.console.aliyun.com → API-KEY'),
  LlmPreset('硅基流动', 'https://api.siliconflow.cn/v1',
      'Qwen/Qwen2.5-7B-Instruct',
      'siliconflow.cn → API 密钥,聚合多家开源模型,注册送额度'),
  LlmPreset('Ollama(本地,无需 key)', 'http://10.0.2.2:11434/v1', 'qwen2.5:7b',
      '电脑上运行 ollama serve;模拟器用 10.0.2.2,真机用电脑局域网 IP'),
  LlmPreset('自定义', '', '', '任何 OpenAI 兼容端点'),
];

/// 测试连接:发一个最小请求,返回 (结果, 描述)。
Future<(bool ok, String message)> testConnection({
  required String baseUrl,
  required String model,
  required String apiKey,
}) async {
  final client = OpenAiCompatibleClient(
    config: OpenAiCompatibleConfig(
      baseUrl: baseUrl,
      model: model,
      apiKey: apiKey,
      sendAuthHeader: apiKey.isNotEmpty,
    ),
    responseTimeout: const Duration(seconds: 30),
  );
  try {
    final resp = await client.complete(const LlmRequest(
      systemPrompt: 'You are a connectivity probe.',
      userPrompt: '回复两个字:正常',
      temperature: 0,
    ));
    final text = (resp.textContent ?? '').trim();
    return (true, text.isEmpty ? '连接正常' : '连接正常:模型回复「$text」');
  } on LlmException catch (e) {
    switch (e.kind) {
      case LlmErrorKind.auth:
        return (false, 'API Key 无效或已过期');
      case LlmErrorKind.modelNotFound:
        return (false, '模型名不存在,请同时检查 baseURL 与 model');
      case LlmErrorKind.rateLimit:
        return (false, '请求过于频繁(额度可能用尽)');
      case LlmErrorKind.network:
        return (false, '网络连接失败,请检查地址与网络');
      default:
        return (false, e.detail);
    }
  }
}

/// 从当前设置构建解析器(读取 secure storage 的 key)。
Future<CourseSightParser> buildParser(WidgetRef ref) async {
  final settings = ref.read(settingsProvider);
  final apiKey = await ref.read(settingsProvider.notifier).readApiKey();
  final client = OpenAiCompatibleClient(
    config: OpenAiCompatibleConfig(
      baseUrl: settings.llmBaseUrl,
      model: settings.llmModel,
      apiKey: apiKey ?? '',
      sendAuthHeader: (apiKey ?? '').isNotEmpty,
    ),
  );
  return CourseSightParser(llm: client);
}

/// LLM 配置表单(设置页与导入向导共用)。
class LlmConfigPanel extends ConsumerStatefulWidget {
  final VoidCallback? onConfigured;

  const LlmConfigPanel({super.key, this.onConfigured});

  @override
  ConsumerState<LlmConfigPanel> createState() => _LlmConfigPanelState();
}

class _LlmConfigPanelState extends ConsumerState<LlmConfigPanel> {
  late final TextEditingController _baseUrl;
  late final TextEditingController _model;
  final _keyController = TextEditingController();
  bool _testing = false;
  String? _testMessage;
  bool? _lastTestOk;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsProvider);
    _baseUrl = TextEditingController(text: settings.llmBaseUrl);
    _model = TextEditingController(text: settings.llmModel);
    // key 不回显,只在配置过时提示已保存
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _model.dispose();
    _keyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          children: [
            for (final preset in llmPresets)
              ActionChip(
                label: Text(preset.name),
                onPressed: () => setState(() {
                  _baseUrl.text = preset.baseUrl;
                  _model.text = preset.model;
                }),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(llmPresets
            .where((p) => p.baseUrl == _baseUrl.text)
            .map((p) => p.hint)
            .firstOrNull ??
            '填入你的 OpenAI 兼容端点信息',
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 12),
        TextField(
          controller: _baseUrl,
          decoration: const InputDecoration(
            labelText: 'Base URL',
            hintText: 'https://…/v1',
            border: OutlineInputBorder(),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _model,
          decoration: const InputDecoration(
            labelText: '模型名',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _keyController,
          obscureText: true,
          decoration: InputDecoration(
            labelText: settings.llmKeyConfigured ? 'API Key(已保存,可更新)' : 'API Key',
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            FilledButton.tonal(
              onPressed: _testing ? null : _saveAndTest,
              child: Text(_testing ? '测试中…' : '保存并测试连接'),
            ),
            const SizedBox(width: 12),
            if (_testMessage != null)
              Expanded(
                child: Text(
                  _testMessage!,
                  style: TextStyle(
                    color: _lastTestOk == true
                        ? Colors.green
                        : Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Future<void> _saveAndTest() async {
    final baseUrl = _baseUrl.text.trim();
    final model = _model.text.trim();
    if (baseUrl.isEmpty || model.isEmpty) {
      setState(() => _testMessage = '请先填写 Base URL 与模型名');
      return;
    }
    setState(() {
      _testing = true;
      _testMessage = null;
    });
    await ref.read(settingsProvider.notifier).set('llm_base_url', baseUrl);
    await ref.read(settingsProvider.notifier).set('llm_model', model);
    if (_keyController.text.trim().isNotEmpty) {
      await ref.read(settingsProvider.notifier).setApiKey(_keyController.text.trim());
    }
    final key = await ref.read(settingsProvider.notifier).readApiKey();

    final (ok, message) = await testConnection(
      baseUrl: baseUrl,
      model: model,
      apiKey: key ?? '',
    );
    if (!mounted) return;
    setState(() {
      _testing = false;
      _lastTestOk = ok;
      _testMessage = message;
    });
    if (ok) {
      // 先让用户看到"连接正常"的确认,再自动进入下一步;
      // 直接跳转会吞掉成功反馈,用户不知道发生了什么
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      if (mounted) widget.onConfigured?.call();
    }
  }
}
