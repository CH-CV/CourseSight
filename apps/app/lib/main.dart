import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:home_widget/home_widget.dart';

import 'app.dart';
import 'logic/reminder_service.dart';
import 'state/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final container = ProviderContainer();
  appContainer = container;

  await ReminderService.instance.init();
  try {
    await HomeWidget.registerInteractivityCallback(widgetBackgroundCallback);
  } catch (_) {}
  await bootstrapLoad(container);
  // 启动即排未来一周提醒 + 刷新小组件
  unawaited(ReminderService.instance
      .refreshAfterChange(container)
      .then((_) => ReminderService.instance.ensurePermission()));

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const CourseSightApp(),
    ),
  );
}

/// home_widget 后台回调:系统周期性刷新(30 分钟)时由后台 isolate 执行,
/// 重算并写入最新的小组件数据。注意:这里只 saveWidgetData、不触发
/// updateWidget,避免回调递归;系统会按 updatePeriodMillis 自行重绘。
@pragma('vm:entry-point')
Future<void> widgetBackgroundCallback(Uri? uri) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isAndroid) {
    // 后台 isolate 需要显式注册插件
    // (home_widget/sqflite/shared_preferences 均为 medthod-channel 插件,
    //  Flutter 引擎在后台 isolate 自动注册 GeneratedPluginRegistrant)
  }
  final container = ProviderContainer();
  try {
    await container.read(settingsProvider.notifier).load();
    await container.read(timetablesProvider.notifier).load();
    final id = container.read(currentTimetableIdProvider) ??
        container.read(timetablesProvider).firstOrNull?.id;
    if (id != null) {
      await container.read(coursesProvider.notifier).loadFor(id);
      await container.read(sectionTimesProvider.notifier).loadFor(id);
    }
    await ReminderService.instance.updateWidgetData(
      timetable: container.read(currentTimetableProvider),
      courses: container.read(coursesProvider),
      sections: container.read(sectionTimesProvider),
      triggerUpdate: false,
    );
  } catch (_) {
    // 后台刷新失败静默,保留上次数据
  } finally {
    container.dispose();
  }
}
