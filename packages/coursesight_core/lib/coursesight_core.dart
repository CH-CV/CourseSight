/// CourseSight 解析引擎——从教务系统课表页面提取结构化课程数据的纯 Dart 包。
///
/// 核心入口是 [CourseSightParser.parse]:输入页面 HTML,输出结构化课表草稿。
/// 引擎不含任何 Flutter / 数据库依赖,LLM 调用通过 [LlmClient] 接口注入。
library;

export 'src/model/models.dart';
export 'src/llm/llm_client.dart';
export 'src/llm/openai_compatible_client.dart';
export 'src/preprocess/preprocessor.dart';
export 'src/prompt/prompt_builder.dart';
export 'src/validate/validator.dart';
export 'src/review/reviewer.dart';
export 'src/normalize/normalizer.dart';
export 'src/parser.dart';
export 'src/diagnostic/diagnostic.dart';
