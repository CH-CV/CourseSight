/// 上课提醒(本地通知)与桌面小组件数据的统一刷新入口。
/// 所有课表数据变更点(import 保存、课程增删改、课表切换/删除、提醒设置变更)
/// 都应调用 [refreshAfterChange],由这里收口通知重排与小组件刷新。
library;

import 'dart:convert';

import 'package:coursesight_core/coursesight_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:home_widget/home_widget.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../data/entities.dart';
import '../state/providers.dart';

const _androidChannelId = 'course_reminders';
const _widgetAndroidName = 'CourseSightTodayWidgetProvider';

/// main() 里注入的应用级容器,供无 ref 的服务层读取状态。
ProviderContainer? appContainer;

/// 数据变更点调用的一行式刷新。
Future<void> refreshAfterChange() async {
  final container = appContainer;
  if (container == null) return;
  await ReminderService.instance.refreshAfterChange(container);
}

class ReminderService {
  ReminderService._();
  static final ReminderService instance = ReminderService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  tz.Location? _location;
  Future<void>? _inFlight; // 串行化刷新,防止 cancelAll 与排程交错

  /// main() 里调用一次;失败静默降级(测试/非移动环境无插件)。
  Future<void> init() async {
    if (_initialized) return;
    try {
      tzdata.initializeTimeZones();
      String tzName = 'Asia/Shanghai';
      try {
        final info = await FlutterTimezone.getLocalTimezone();
        tzName = info.identifier;
      } catch (_) {}
      try {
        _location = tz.getLocation(tzName);
      } catch (_) {
        _location = tz.getLocation('Asia/Shanghai');
      }
      const settings = InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'));
      await _plugin.initialize(settings: settings);
      _initialized = true;
    } catch (_) {
      _initialized = false;
    }
  }

  /// Android 13+ 通知权限。
  Future<void> ensurePermission() async {
    if (!_initialized) return;
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await android?.requestNotificationsPermission();
    } catch (_) {}
  }

  /// 数据变更后的统一刷新:重排未来 7 天提醒 + 刷新小组件数据。
  /// 串行化:后到的刷新等前一个完成再 cancelAll,避免交错残留过期通知。
  Future<void> refreshAfterChange(ProviderContainer container) async {
    final previous = _inFlight;
    final run = () async {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {}
      }
      final timetable = container.read(currentTimetableProvider);
      final courses = container.read(coursesProvider);
      final sections = container.read(sectionTimesProvider);
      final settings = container.read(settingsProvider);

      await rescheduleReminders(
        timetable: timetable,
        courses: courses,
        sections: sections,
        enabled: settings.reminderEnabled,
        leadMinutes: settings.reminderLeadMinutes,
        weekStartDay: settings.weekStartDay,
      );
      await updateWidgetData(
        timetable: timetable,
        courses: courses,
        sections: sections,
        weekStartDay: settings.weekStartDay,
      );
    }();
    _inFlight = run;
    try {
      await run;
    } finally {
      if (identical(_inFlight, run)) _inFlight = null;
    }
  }

  Future<void> rescheduleReminders({
    required Timetable? timetable,
    required List<Course> courses,
    required List<SectionTimeRow> sections,
    required bool enabled,
    required int leadMinutes,
    int weekStartDay = 1,
  }) async {
    if (!_initialized) return;
    try {
      await _plugin.cancelAll();
      if (!enabled || timetable == null || timetable.firstWeekMonday == null) {
        return;
      }
      final location = _location;
      if (location == null) return;

      final now = tz.TZDateTime.now(location);
      final today = DateTime.now();
      final sectionById = {for (final s in sections) s.section: s};
      var notificationId = 1;

      for (var offset = 0; offset <= 7; offset++) {
        final date = today.add(Duration(days: offset));
        final week = weekOfDate(timetable.firstWeekMonday!, date,
            weekStartDay: weekStartDay);
        if (week < 1 || week > timetable.totalWeeks) continue;

        for (final c in courses) {
          if (c.dayOfWeek != date.weekday || !c.inWeek(week)) continue;
          final section = sectionById[c.startSection];
          if (section == null) continue;
          final startMin = _minutesOfDay(section.startTime);
          if (startMin == null) continue;

          final notify = tz.TZDateTime(
            location,
            date.year,
            date.month,
            date.day,
            startMin ~/ 60,
            startMin % 60,
          ).subtract(Duration(minutes: leadMinutes));
          if (notify.isBefore(now)) continue;
          if (notificationId > 200) return; // 防御性上限

          await _plugin.zonedSchedule(
            id: notificationId++,
            title: '即将上课:${c.name}',
            body: '${section.startTime}-${section.endTime}'
                '${c.location == null || c.location!.isEmpty ? '' : ' @ ${c.location}'}',
            scheduledDate: notify,
            notificationDetails: const NotificationDetails(
              android: AndroidNotificationDetails(
                _androidChannelId,
                '上课提醒',
                channelDescription: '课前本地提醒',
                importance: Importance.high,
                priority: Priority.high,
              ),
            ),
            androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          );
        }
      }
    } catch (_) {
      // 通知失败不影响主流程
    }
  }

  /// 小组件:写入 JSON 并触发 Android 更新。
  /// 周次语义:week==null 且有开学日期 → 学期外(假期,显示空);
  /// 仅缺开学日期时才兜底显示当天全部课程。
  Future<void> updateWidgetData({
    required Timetable? timetable,
    required List<Course> courses,
    required List<SectionTimeRow> sections,
    bool triggerUpdate = true,
    int weekStartDay = 1,
  }) async {
    if (kIsWeb) return;
    try {
      final today = DateTime.now();
      final week = timetable?.currentWeek(today, weekStartDay: weekStartDay);
      final outOfSemester =
          timetable != null && timetable.firstWeekMonday != null && week == null;
      final dow = today.weekday;

      final todays = outOfSemester
          ? <Course>[]
          : courses
              .where((c) =>
                  c.dayOfWeek == dow && (week == null || c.inWeek(week)))
              .toList()
            ..sort((a, b) => a.startSection.compareTo(b.startSection));

      final sectionById = {for (final s in sections) s.section: s};
      String timeOf(int section) =>
          '${sectionById[section]?.startTime ?? ''}-${sectionById[section]?.endTime ?? ''}';

      String? nextName, nextTime, nextLocation;
      final nowMinutes = today.hour * 60 + today.minute;
      for (final c in todays) {
        final s = sectionById[c.startSection];
        if (s == null) continue;
        final startMin = _minutesOfDay(s.startTime);
        if (startMin == null) continue;
        if (startMin >= nowMinutes) {
          nextName = c.name;
          nextTime = s.startTime;
          nextLocation = c.location ?? '';
          break;
        }
      }

      await HomeWidget.saveWidgetData<String>(
        'widget_data',
        jsonEncode({
          'date': '${today.month}/${today.day}',
          'week': week,
          'vacation': outOfSemester,
          'next': {
            'name': nextName,
            'time': nextTime,
            'location': nextLocation,
          },
          'today': [
            for (final c in todays.take(3))
              {
                'name': c.name,
                'time': timeOf(c.startSection),
                'location': c.location ?? '',
              }
          ],
          'total': todays.length,
        }),
      );
      await HomeWidget.updateWidget(
        androidName: _widgetAndroidName,
        qualifiedAndroidName: 'top.coursesight.coursesight_app.$_widgetAndroidName',
      );
      if (triggerUpdate) {
        // 后台回调路径不触发 updateWidget,避免回调递归
      }
    } catch (_) {
      // 小组件失败不影响主流程
    }
  }

  static int? _minutesOfDay(String hhmm) {
    final parts = hhmm.split(':');
    if (parts.length != 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null || h > 23 || m > 59) return null;
    return h * 60 + m;
  }
}
