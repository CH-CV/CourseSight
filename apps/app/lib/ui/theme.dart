/// 课表配色(12 色 Material 浅色调,深浅主题下都用深色文字)。
library;

import 'package:flutter/material.dart';

const List<Color> coursePalette = [
  Color(0xFF90CAF9), // 蓝
  Color(0xFFA5D6A7), // 绿
  Color(0xFFFFAB91), // 橙
  Color(0xFFCE93D8), // 紫
  Color(0xFFFFF59D), // 黄
  Color(0xFF80CBC4), // 青
  Color(0xFFF48FB1), // 粉
  Color(0xFFB39DDB), // 深紫
  Color(0xFFFFCC80), // 暖橙
  Color(0xFFBCAAA4), // 棕灰
  Color(0xFF81D4FA), // 浅蓝
  Color(0xFFC5E1A5), // 黄绿
];

Color courseColor(int index) =>
    coursePalette[index % coursePalette.length];

const weekDayNames = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

/// 12 节默认作息,与 core 的模板一致;新建课表时写入 DB。
const List<(int, String, String)> defaultSectionTimes = [
  (1, '08:00', '08:45'),
  (2, '08:55', '09:40'),
  (3, '10:00', '10:45'),
  (4, '10:55', '11:40'),
  (5, '11:50', '12:35'),
  (6, '14:00', '14:45'),
  (7, '14:55', '15:40'),
  (8, '16:00', '16:45'),
  (9, '16:55', '17:40'),
  (10, '19:00', '19:45'),
  (11, '19:55', '20:40'),
  (12, '20:50', '21:35'),
];
