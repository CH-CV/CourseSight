/// 路由(go_router):五个顶层目的地。
library;

import 'package:go_router/go_router.dart';

import 'ui/course_edit_screen.dart';
import 'ui/home_screen.dart';
import 'ui/import/import_screen.dart';
import 'ui/settings/settings_screen.dart';

final router = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/',
      name: 'home',
      builder: (context, state) => const HomeScreen(),
    ),
    GoRoute(
      path: '/import',
      name: 'import',
      builder: (context, state) => const ImportScreen(),
    ),
    GoRoute(
      path: '/course/edit',
      name: 'courseEdit',
      builder: (context, state) {
        final extra = state.extra as Map<String, dynamic>? ?? {};
        return CourseEditScreen(
          courseId: extra['courseId'] as int?,
          presetDay: extra['day'] as int?,
          presetSection: extra['section'] as int?,
        );
      },
    ),
    GoRoute(
      path: '/settings',
      name: 'settings',
      builder: (context, state) => const SettingsScreen(),
    ),
  ],
);
