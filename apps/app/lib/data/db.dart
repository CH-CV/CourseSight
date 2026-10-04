/// sqflite 数据层:建表、迁移、仓库。
library;

export 'package:sqflite/sqflite.dart'
    show ConflictAlgorithm, databaseFactory;

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'entities.dart';

class Db {
  Database? _db;

  Future<Database> open() async {
    if (_db != null) return _db!;
    final dir = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dir, 'coursesight.db'),
      version: 1,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE timetables(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            first_week_monday TEXT,
            total_weeks INTEGER NOT NULL DEFAULT 20,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )''');
        await db.execute('''
          CREATE TABLE courses(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timetable_id INTEGER NOT NULL,
            name TEXT NOT NULL,
            teacher TEXT,
            location TEXT,
            day_of_week INTEGER NOT NULL,
            start_section INTEGER NOT NULL,
            end_section INTEGER NOT NULL,
            weeks TEXT NOT NULL,
            week_type TEXT NOT NULL DEFAULT 'all',
            color_index INTEGER NOT NULL DEFAULT 0,
            note TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )''');
        await db.execute(
            'CREATE INDEX idx_courses_timetable ON courses(timetable_id)');
        await db.execute('''
          CREATE TABLE time_configs(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timetable_id INTEGER NOT NULL,
            section INTEGER NOT NULL,
            start_time TEXT NOT NULL,
            end_time TEXT NOT NULL
          )''');
        await db.execute(
            'CREATE INDEX idx_time_configs_timetable ON time_configs(timetable_id)');
        await db.execute(
            'CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT NOT NULL)');
      },
    );
    return _db!;
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}

/// 课表与课程的读写。
class TimetableRepository {
  final Db db;
  TimetableRepository(this.db);

  Future<List<Timetable>> listTimetables() async {
    final d = await db.open();
    final rows = await d.query('timetables', orderBy: 'updated_at DESC');
    return rows.map(Timetable.fromRow).toList();
  }

  Future<Timetable> createTimetable(Timetable t) async {
    final d = await db.open();
    final now = DateTime.now().toIso8601String();
    final row = t.toRow();
    final id = await d.insert('timetables', {...row, 'created_at': now});
    return Timetable(
      id: id,
      name: t.name,
      firstWeekMonday: t.firstWeekMonday,
      totalWeeks: t.totalWeeks,
    );
  }

  /// 事务化保存一次导入:建表 → 作息 → 课程,任何一步失败整体回滚。
  Future<Timetable> saveImportedTimetable({
    required Timetable timetable,
    required List<SectionTimeRow> sections,
    required List<Course> courses,
  }) async {
    final d = await db.open();
    final now = DateTime.now().toIso8601String();
    late final int id;
    await d.transaction((txn) async {
      id = await txn.insert('timetables',
          {...timetable.toRow(), 'created_at': now, 'updated_at': now});
      for (final s in sections) {
        await txn.insert('time_configs',
            {...s.toRow(), 'timetable_id': id});
      }
      for (final c in courses) {
        await txn.insert('courses', {
          ...c.toRow(),
          'timetable_id': id,
          'created_at': now,
        });
      }
    });
    return Timetable(
      id: id,
      name: timetable.name,
      firstWeekMonday: timetable.firstWeekMonday,
      totalWeeks: timetable.totalWeeks,
    );
  }

  /// 事务化恢复备份:timetables/courses/timeConfig 均为导出格式行;
  /// 忽略备份中的 id,由自增重新分配。[nameToId] 返回 旧课表名→新 id。
  Future<Map<String, int>> restoreBackup({
    required List<Map<String, dynamic>> timetables,
    required List<Map<String, dynamic>> courses,
    required List<Map<String, dynamic>> timeConfig,
  }) async {
    final d = await db.open();
    final now = DateTime.now().toIso8601String();
    final nameToId = <String, int>{};
    final legacyIdToNew = <int, int>{};
    await d.transaction((txn) async {
      for (final row in timetables) {
        final newId = await txn.insert('timetables', {
          'name': row['name'] as String? ?? '恢复的课表',
          'first_week_monday': row['first_week_monday'] as String?,
          'total_weeks': (row['total_weeks'] as int?) ?? 20,
          'created_at': now,
          'updated_at': now,
        });
        final legacyId = row['id'] as int?;
        if (legacyId != null) legacyIdToNew[legacyId] = newId;
        nameToId[row['name'] as String? ?? ''] = newId;
      }
      for (final row in courses) {
        final legacyTid = row['timetable_id'] as int?;
        final newTid = legacyIdToNew[legacyTid];
        if (newTid == null) continue; // 找不到归属课表的孤儿行,跳过
        await txn.insert('courses', {
          'timetable_id': newTid,
          'name': row['name'] as String? ?? '',
          'teacher': row['teacher'] as String?,
          'location': row['location'] as String?,
          'day_of_week': (row['day_of_week'] as int?) ?? 1,
          'start_section': (row['start_section'] as int?) ?? 1,
          'end_section': (row['end_section'] as int?) ?? 1,
          'weeks': row['weeks'] as String? ?? '[]',
          'week_type': row['week_type'] as String? ?? 'all',
          'color_index': (row['color_index'] as int?) ?? 0,
          'note': row['note'] as String?,
          'created_at': now,
          'updated_at': now,
        });
      }
      for (final row in timeConfig) {
        final legacyTid = row['timetable_id'] as int?;
        final newTid = legacyIdToNew[legacyTid];
        if (newTid == null) continue;
        await txn.insert('time_configs', {
          'timetable_id': newTid,
          'section': (row['section'] as int?) ?? 1,
          'start_time': row['start_time'] as String? ?? '08:00',
          'end_time': row['end_time'] as String? ?? '08:45',
        });
      }
    });
    return nameToId;
  }

  Future<void> updateTimetable(Timetable t) async {
    if (t.id == null) throw ArgumentError('updateTimetable 需要非空 id');
    final d = await db.open();
    await d
        .update('timetables', t.toRow(), where: 'id = ?', whereArgs: [t.id]);
  }

  /// 删除课表及其课程与作息(sqflite 默认不级联,手动删)。
  Future<void> deleteTimetable(int id) async {
    final d = await db.open();
    await d.transaction((txn) async {
      await txn.delete('courses',
          where: 'timetable_id = ?', whereArgs: [id]);
      await txn.delete('time_configs',
          where: 'timetable_id = ?', whereArgs: [id]);
      await txn.delete('timetables', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<List<Course>> listCourses(int timetableId) async {
    final d = await db.open();
    final rows = await d.query('courses',
        where: 'timetable_id = ?',
        whereArgs: [timetableId],
        orderBy: 'day_of_week, start_section');
    return rows.map(Course.fromRow).toList();
  }

  Future<Course> insertCourse(Course c) async {
    final d = await db.open();
    final now = DateTime.now().toIso8601String();
    final id = await d
        .insert('courses', {...c.toRow(), 'created_at': now});
    return Course.fromRow(
        {...c.toRow(), 'created_at': now, 'id': id});
  }

  Future<void> updateCourse(Course c) async {
    if (c.id == null) throw ArgumentError('updateCourse 需要非空 id');
    final d = await db.open();
    await d.update('courses', c.toRow(),
        where: 'id = ?', whereArgs: [c.id]);
  }

  Future<void> deleteCourse(int id) async {
    final d = await db.open();
    await d.delete('courses', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> replaceCourses(int timetableId, List<Course> courses) async {
    final d = await db.open();
    final now = DateTime.now().toIso8601String();
    await d.transaction((txn) async {
      await txn.delete('courses',
          where: 'timetable_id = ?', whereArgs: [timetableId]);
      for (final c in courses) {
        await txn.insert(
            'courses', {...c.toRow(), 'created_at': now});
      }
      await txn.update(
          'timetables', {'updated_at': now},
          where: 'id = ?', whereArgs: [timetableId]);
    });
  }

  Future<List<SectionTimeRow>> listSectionTimes(int timetableId) async {
    final d = await db.open();
    final rows = await d.query('time_configs',
        where: 'timetable_id = ?',
        whereArgs: [timetableId],
        orderBy: 'section');
    return rows.map(SectionTimeRow.fromRow).toList();
  }

  Future<void> replaceSectionTimes(
      int timetableId, List<SectionTimeRow> rows) async {
    final d = await db.open();
    await d.transaction((txn) async {
      await txn.delete('time_configs',
          where: 'timetable_id = ?', whereArgs: [timetableId]);
      for (final r in rows) {
        await txn.insert('time_configs', r.toRow());
      }
    });
  }
}

/// 设置 KV(settings 表;apiKey 除外——它只进 secure storage)。
class SettingsRepository {
  final Db db;
  SettingsRepository(this.db);

  Future<Map<String, String>> loadAll() async {
    final d = await db.open();
    final rows = await d.query('settings');
    return {
      for (final r in rows) r['key'] as String: r['value'] as String,
    };
  }

  Future<void> set(String key, String value) async {
    final d = await db.open();
    await d.insert('settings', {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> remove(String key) async {
    final d = await db.open();
    await d.delete('settings', where: 'key = ?', whereArgs: [key]);
  }
}

Future<String> getDatabasesPath() => databaseFactory.getDatabasesPath();
