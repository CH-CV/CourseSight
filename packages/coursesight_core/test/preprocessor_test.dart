import 'dart:io';

import 'package:coursesight_core/coursesight_core.dart';
import 'package:test/test.dart';

void main() {
  final html = File('test/fixtures/sample_zhengfang_style.html').readAsStringSync();

  test('预处理保留表格与关键正文,剔除脚本样式', () {
    final result = const Preprocessor().process(html);

    expect(result.text.contains('高等数学'), isTrue);
    expect(result.text.contains('教1-101'), isTrue);
    expect(result.text.contains('2026-03-02'), isTrue);
    expect(result.text.contains('alert'), isFalse,
        reason: 'script 内容应被剔除');
    expect(result.text.contains('border-collapse'), isFalse,
        reason: 'style 内容应被剔除');
    expect(result.keptRatio, lessThan(0.9));
  });

  test('疑似课程名计数:6 门课(单双周同名不同段算 7 格),星期/节次/时间格不计', () {
    final result = const Preprocessor().process(html);
    expect(result.estimatedCourseNameCount, inInclusiveRange(6, 8));
    // 关键:不再把星期表头计进来导致遗漏对照虚高
    expect(result.estimatedCourseNameCount, lessThan(10));
  });

  test('超长页面被截断到 maxChars', () {
    final big = '<html><body><table><tr><td>${'课程内容' * 20000}</td></tr></table></body></html>';
    final result = const Preprocessor(maxChars: 8000).process(big);
    expect(result.keptChars, lessThanOrEqualTo(8100));
  });

  test('表格结构原样保留:表头/rowspan/空单元格都不许丢', () {
    // 结构即信息:rowspan/colspan 与空单元格是 AI 判断课程归属哪天/哪节
    // 的唯一依据,压扁成文本会让星期映射失去依据,原样保留交给 AI 自己读。
    const grid = '''
<html><body><table>
<tr><th>节次</th><th>周日</th><th>周一</th><th>周二</th></tr>
<tr><td>1-2节</td><td></td><td></td><td>高等数学</td></tr>
<tr><td>3-4节</td><td></td><td></td><td rowspan="2">线性代数</td></tr>
<tr><td>5-6节</td><td></td><td></td></tr>
</table></body></html>
''';
    final result = const Preprocessor().process(grid);
    expect(result.text.contains('<th>周二</th>'), isTrue,
        reason: '星期表头必须保留,AI 靠它映射 dayOfWeek');
    expect(result.text.contains('rowspan="2"'), isTrue,
        reason: 'rowspan 是跨节次课程的唯一依据');
    expect(RegExp(r'<td></td>').hasMatch(result.text), isTrue,
        reason: '空单元格必须保留,AI 靠它数清第几列');
    expect(result.text.contains('高等数学'), isTrue);
  });
}
