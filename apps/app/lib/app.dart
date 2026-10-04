/// 应用根:Material 3 主题(seed 色 indigo,深色跟随系统)与路由。
library;

import 'package:flutter/material.dart';

import 'router.dart';

class CourseSightApp extends StatelessWidget {
  const CourseSightApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF3F51B5); // indigo
    return MaterialApp.router(
      title: '课见',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
            seedColor: seed, brightness: Brightness.dark),
      ),
      themeMode: ThemeMode.system,
      routerConfig: router,
    );
  }
}
