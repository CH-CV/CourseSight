/// 提示词与工具定义。改提示词只改这里。
library;

import 'dart:convert';

/// 「提交课表」工具的 JSON Schema(OpenAI tools 格式的 function 部分)。
Map<String, dynamic> buildSubmitTimetableTool() => {
      'name': 'submit_timetable',
      'description': '提交从课表页面提取的完整数据。读完页面后必须调用恰好一次。',
      'parameters': {
        'type': 'object',
        'required': ['courses'],
        'properties': {
          'totalWeeks': {
            'type': ['integer', 'null'],
            'description': '本学期总周数;页面有说明(如「共20周」)才填,没有则填 null',
          },
          'firstWeekMonday': {
            'type': ['string', 'null'],
            'description': '第一周周一日期 YYYY-MM-DD,页面有则填否则 null',
          },
          'firstDayColumn': {
            'type': ['integer', 'null'],
            'minimum': 1,
            'maximum': 7,
            'description':
                '课表第一列(节次列右侧第一列)是星期几,按表头文字:1=周一…7=周日;读不出填 null',
          },
          'timeConfig': {
            'type': 'array',
            'description': '页面给出的每节起止时间,没有则空数组',
            'items': {
              'type': 'object',
              'properties': {
                'section': {'type': 'integer'},
                'startTime': {'type': 'string'},
                'endTime': {'type': 'string'},
              },
            },
          },
          'courses': {
            'type': 'array',
            'items': {
              'type': 'object',
              'required': ['name', 'dayOfWeek', 'startSection', 'endSection', 'weeks'],
              'properties': {
                'name': {'type': 'string'},
                'teacher': {'type': 'string'},
                'location': {'type': 'string'},
                'dayOfWeek': {
                  'type': 'integer',
                  'minimum': 1,
                  'maximum': 7,
                  'description': '1=周一…7=周日;必须按页面表头文字映射,第一列不一定是周一',
                },
                'startSection': {'type': 'integer', 'minimum': 1},
                'endSection': {'type': 'integer', 'minimum': 1},
                'weeks': {
                  'type': 'array',
                  'items': {'type': 'integer'},
                  'description': '展开后的具体周次,如 [1,3,5,15]',
                },
                'confidence': {'type': 'number', 'minimum': 0, 'maximum': 1},
              },
            },
          },
        },
      },
    };

const String generatorSystemPrompt = '''
你是教务系统课表解析器。从用户提供的课表页面内容中提取全部课程,通过调用 submit_timetable 工具一次性提交。规则:
1. 只提取课表数据,忽略选课按钮、新闻、通知栏等无关内容;空单元格不是课程。
2. 同一门课的不同时段/周次拆成多条记录(如「1-8周」与「10-16周」是两条),不要合并不同时段。
3. 单周=奇数周,双周=偶数周;「1-16周(单)」展开为 [1,3,5,7,9,11,13,15]。weeks 一律填展开后的具体周次。
4. 节次以页面表头编号为准;页面只有时间没有节次号时,按作息表对照推断,并把该条 confidence 降到 0.6 以下。
5. 实践、实习、班会等非常规条目也提取,name 原样保留。
6. 每条自报 confidence(0–1):与页面完全一致 1.0;有推断成分 ≤0.6。
7. 不确定就降低 confidence,严禁编造页面上不存在的内容。
8. 星期必须按课表表头行的文字映射(周一=1,周二=2,…,周六=6,周日=7);表头第一列不一定是周一(部分学校以周日开头),严禁按列的先后顺序默认从周一开始;填 dayOfWeek 前先读表头,并在 firstDayColumn 中报告第一列(节次列右侧第一列)是星期几。
''';

/// 三轮审查的任务行(时间节次 / 周次单双周 / 遗漏多余)。
const List<String> reviewerRoundTasks = [
  '只检查时间维度:每条记录的星期、节次区间是否与页面一致、是否超出作息范围、是否存在同时间段重叠。',
  '只检查周次:单双周展开是否正确、周次区间是否与页面一致、totalWeeks 是否合理。',
  '只查遗漏与多余:逐个核对页面上出现的课程名称,确认每门课都有对应记录、没有凭空多出的课程。',
];

String reviewerSystemPrompt(int round) => '''
你是课表数据审核员。你会看到【课表页面内容】和另一个系统从中提取的【课程 JSON】。找出两者不一致之处。
输出严格 JSON,不要任何其他文字:
{"issues":[{"course_index":0,"field":"字段名","problem":"描述","evidence":"页面原文片段,必须原文复制","suggestion":"修正值"}],"uncertain":[{"course_index":0,"problem":"描述"}]}
硬性规则:每条 issue 的 evidence 必须是页面内容的原文片段(可截断、不可改写);找不到原文依据的疑问一律放进 uncertain,不得放进 issues。
本轮任务:${reviewerRoundTasks[round.clamp(0, reviewerRoundTasks.length - 1)]}
''';

/// 生成者请求的 user prompt。
String buildGeneratorUserPrompt(
    String preprocessed, String? schoolName, String? systemName) {
  final hint = [
    if (schoolName != null && schoolName.isNotEmpty) '学校:$schoolName',
    if (systemName != null && systemName.isNotEmpty) '教务系统:$systemName',
  ].join(',');
  return '${hint.isEmpty ? '' : '($hint)\n'}'
      '【课表页面内容】\n'
      '以下是教务页面的原始 HTML(已去除脚本/样式)。课表通常是 table:'
      '星期表头在 tr/th 里,课程在 td 里,跨节次的课用 rowspan 合并、'
      '跨列的用 colspan 合并——按 HTML 结构自己判断每个单元格归属哪天/哪几节,'
      '页面里的导航、按钮、通知等与课表无关的内容自行忽略。\n'
      '$preprocessed';
}

/// 审查者请求的 user prompt。
String buildReviewerUserPrompt(String preprocessed, String timetableJson) =>
    '【课表页面内容】\n'
    '以下是教务页面的原始 HTML(已去除脚本/样式)。课表通常是 table:'
    '星期表头在 tr/th 里,课程在 td 里,跨节次用 rowspan、跨列用 colspan 合并,'
    '按 HTML 结构核对每个单元格归属;无关内容自行忽略。\n'
    '$preprocessed\n\n【课程 JSON】\n$timetableJson';

/// 从 LLM 文本输出中提取 JSON 对象(容忍代码块包裹与前后杂文)。
Map<String, dynamic>? extractJsonObject(String text) {
  var t = text.trim();
  final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(t);
  if (fence != null) t = fence.group(1)!.trim();
  final start = t.indexOf('{');
  final end = t.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  try {
    return jsonDecode(t.substring(start, end + 1)) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}


/// 从流式累计的工具参数/文本中提取"已出现的课程名"。
/// 用于生成过程中的实时反馈:不要求 JSON 完整,正则捕获已闭合的
/// "name": "..." 键值对即可。返回按出现顺序去重的列表。
List<String> extractRecognizedCourseNames(String accumulated) {
  final names = <String>[];
  final pattern = RegExp(r'"name"\s*:\s*"((?:[^"\\]|\\.)*)"');
  for (final m in pattern.allMatches(accumulated)) {
    final raw = m.group(1)!;
    // 反转义常见转义符
    final name = raw.replaceAll(r'\"', '"').replaceAll(r'\\', r'\');
    if (name.trim().isNotEmpty && !names.contains(name)) {
      names.add(name);
    }
  }
  return names;
}