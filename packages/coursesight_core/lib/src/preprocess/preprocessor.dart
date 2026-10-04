/// HTML 预处理:只做与表格形态无关的减负(去脚本/样式/注释/纯展示属性),
/// 表格(含 rowspan/colspan)与正文原样保留,交给 AI 自己读。
/// 刻意不做任何结构解释:把网格拉平、按列对齐之类的事看似帮 AI,
/// 实则是逐格式适配——一旦猜错结构比不猜更糟。
library;

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

class PreprocessResult {
  final String text;
  final int originalChars;
  final int keptChars;

  /// 从表格单元格里数出来的"疑似课程名"数量(去重后),供 Validator 做遗漏对照。
  final int estimatedCourseNameCount;

  const PreprocessResult({
    required this.text,
    required this.originalChars,
    required this.keptChars,
    required this.estimatedCourseNameCount,
  });

  double get keptRatio =>
      originalChars == 0 ? 0 : keptChars / originalChars;
}

/// 表头词与噪音词:整格命中时不计入课程名估计。
const List<String> _noiseWords = [
  '星期', '周次', '节次', '上午', '下午', '晚上', '早读', '晚自习', '午休',
  '寒假', '暑假', '课程',
];

/// 星期表头(星期一…星期日 / 周一…周日)整格排除。
final _weekdayPattern = RegExp(r'^(星期|礼拜|周)[一二三四五六日天]$');

/// 时间样式:整格命中即排除(作息格)。
final _timePattern = RegExp(r'^\s*\d{1,2}:\d{2}\s*(?:[-–—~]\s*\d{1,2}:\d{2}\s*)?$');

/// 节次表头格:"第1,2节" / "第九节" / "1-2节" 等。
final _sectionHeaderPattern = RegExp(r'^第?\s*\d+(?:\s*[,，、\-–—]\s*\d+)?\s*节$');

/// 纯展示属性:删掉只影响体积,不影响语义;结构属性(colspan/rowspan)不在其列。
/// title 不在其列——个别系统把课程信息放在 title 提示里。
const Set<String> _presentationAttrs = {
  'style', 'class', 'id', 'align', 'valign', 'width', 'height',
  'border', 'cellpadding', 'cellspacing', 'bgcolor', 'background',
  'nowrap', 'hidefocus', 'lang', 'dir',
};

class Preprocessor {
  /// 输出长度上限(字符)。原样保留 HTML 比压扁文本更占字符,但表格的
  /// rowspan/colspan 是判断课程落在哪天/哪节的依据,压扁等于让 AI 盲猜。
  /// 120000 约可容纳整页去噪后的课表页,GLM 级模型 128K 上下文可承载;
  /// 超长仍按保头保尾截断。
  final int maxChars;

  const Preprocessor({this.maxChars = 120000});

  PreprocessResult process(String html) {
    final original = html.length;
    final doc = html_parser.parse(html);

    // 1) 去脚本/样式/模板/注释:对读课表永远无用,且占体积。
    for (final sel in const ['script', 'style', 'noscript', 'template', 'link', 'meta']) {
      for (final e in doc.querySelectorAll(sel)) {
        e.remove();
      }
    }
    _removeComments(doc);

    // 2) 删纯展示属性(style/class/id/align…):只影响体积不影响语义;
    //    colspan/rowspan 等结构属性必须留——课程落在哪天哪节全靠它们。
    for (final el in doc.querySelectorAll('*')) {
      el.attributes.removeWhere(
          (k, v) => _presentationAttrs.contains(k.toString().toLowerCase()));
    }

    // 3) 课程名估计:读单元格文本按词形计数(只读内容,不解释结构),
    //    供 Validator 做遗漏对照。
    final nameCount = _estimateCourseNames(doc);

    // 4) 原样序列化:结构即信息。块级标签后换行只是排版,便于按行读。
    var text = doc.body?.innerHtml ?? doc.documentElement?.innerHtml ?? '';
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    text = text.replaceAllMapped(
        RegExp(r'</(?:tr|table|p|div|li|h[1-6])>|<br\s*/?>'), (m) => '\n');
    text = text.replaceAll(RegExp(r'\n\s*'), '\n').trim();

    // 5) 超长截断(保头保尾,课表通常在主体靠前位置)。
    if (text.length > maxChars) {
      final head = text.substring(0, maxChars * 3 ~/ 4);
      final tail = text.substring(text.length - maxChars ~/ 4);
      text = '$head\n…(中间内容过长被截断)…\n$tail';
    }

    return PreprocessResult(
      text: text,
      originalChars: original,
      keptChars: text.length,
      estimatedCourseNameCount: nameCount,
    );
  }

  static String _clean(String raw) =>
      raw.replaceAll(RegExp(r'\s+'), ' ').trim();

  /// 疑似课程名:非表头/星期/节次/时间格,长度 2-40,含非数字字符。
  static bool _looksLikeCourseName(String text, int cellIndex /* 1-based */) {
    if (text.length < 2 || text.length > 40) return false;
    if (_timePattern.hasMatch(text)) return false;
    if (_weekdayPattern.hasMatch(text)) return false;
    if (_sectionHeaderPattern.hasMatch(text)) return false;
    if (_noiseWords.contains(text)) return false;
    // 纯数字/标点/时间组合不是课程名
    if (RegExp(r'^[\d\s:：\-–—~,，.()()]+$').hasMatch(text)) return false;
    // 表格首列通常是节次表头
    if (cellIndex == 1) return false;
    return true;
  }

  /// 课程名估计:逐格读文本按词形计数(只读内容,不解释表格结构),
  /// 供 Validator 做遗漏对照。
  static int _estimateCourseNames(Document doc) {
    final names = <String>{};
    for (final tr in doc.querySelectorAll('tr')) {
      final cells = tr.querySelectorAll('th, td');
      for (var i = 0; i < cells.length; i++) {
        final text = _clean(cells[i].text);
        if (text.isNotEmpty && _looksLikeCourseName(text, i + 1)) {
          names.add(text);
        }
      }
    }
    return names.length;
  }

  static void _removeComments(Document doc) {
    for (final node in doc.nodes.toList()) {
      _removeCommentsIn(node);
    }
  }

  static void _removeCommentsIn(Node node) {
    for (final child in node.nodes.toList()) {
      if (child is Comment) {
        child.remove();
      } else {
        _removeCommentsIn(child);
      }
    }
  }
}
