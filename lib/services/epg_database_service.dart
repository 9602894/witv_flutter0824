import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';
import '../models/epg_program.dart';
import 'log_service.dart';

class EpgDatabaseService {
  static Database? _database;
  static final _lock = Completer<void>();

  static Future<Database> get database async {
    if (_database != null) return _database!;
    await _lock.future;
    if (_database != null) return _database!;
    _lock.complete();

    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'epg.db');
    _database = await openDatabase(
      path,
      version: 3,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
    return _database!;
  }

  static Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE channels (
        channel_id TEXT PRIMARY KEY,
        display_name TEXT,
        icon TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE programs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        channel_id TEXT,
        title TEXT,
        description TEXT,
        start INTEGER,
        stop INTEGER
      )
    ''');
    await db.execute('CREATE INDEX idx_programs_channel ON programs(channel_id)');
    await db.execute('CREATE INDEX idx_programs_start ON programs(start)');
    await db.execute('CREATE INDEX idx_programs_stop ON programs(stop)');
    await LogService.write('EPG数据库创建完成');
  }

  static Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('ALTER TABLE channels ADD COLUMN display_name TEXT');
    }
    if (oldVersion < 3) {
      await db.execute('CREATE INDEX idx_programs_start ON programs(start)');
      await db.execute('CREATE INDEX idx_programs_stop ON programs(stop)');
    }
    await LogService.write('EPG数据库升级: $oldVersion -> $newVersion');
  }

  static Future<void> clearAll() async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('programs');
      await txn.delete('channels');
    });
    LogService.write('EPG数据库已清空');
  }

  static Future<bool> isEmpty() async {
    final db = await database;
    final count = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM programs'),
    );
    return count == 0;
  }

  static Future<void> batchUpdateDisplayNames(Map<String, String> displayNames) async {
    if (displayNames.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final entry in displayNames.entries) {
        batch.insert(
          'channels',
          {'channel_id': entry.key, 'display_name': entry.value},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
    LogService.write('EPG: 批量更新 display-name 完成，共 ${displayNames.length} 条');
  }

  static Future<void> batchUpdateIcons(Map<String, String> icons) async {
    if (icons.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final entry in icons.entries) {
        batch.insert(
          'channels',
          {'channel_id': entry.key, 'icon': entry.value},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
    LogService.write('EPG: 批量更新图标完成，共 ${icons.length} 条');
  }

  static Future<void> insertProgramsBatch(
    Map<String, List<EpgProgram>> programMap,
  ) async {
    if (programMap.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final entry in programMap.entries) {
        final channelId = entry.key;
        for (final prog in entry.value) {
          batch.insert('programs', {
            'channel_id': channelId,
            'title': prog.title,
            'description': prog.description,
            'start': prog.start.millisecondsSinceEpoch,
            'stop': prog.stop.millisecondsSinceEpoch,
          });
        }
      }
      await batch.commit(noResult: true);
    });
  }

  static Future<void> insertPrograms(
    Map<String, List<EpgProgram>> programMap,
    Map<String, String> channelIcons,
  ) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('programs');
      await txn.delete('channels');

      for (final entry in channelIcons.entries) {
        await txn.insert('channels', {
          'channel_id': entry.key,
          'icon': entry.value,
          'display_name': null,
        });
      }

      for (final entry in programMap.entries) {
        final channelId = entry.key;
        for (final prog in entry.value) {
          await txn.insert('programs', {
            'channel_id': channelId,
            'title': prog.title,
            'description': prog.description,
            'start': prog.start.millisecondsSinceEpoch,
            'stop': prog.stop.millisecondsSinceEpoch,
          });
        }
      }
    });
    LogService.write('EPG: 插入完成，${programMap.length} 频道, ${channelIcons.length} 图标');
  }

  static Future<String?> findChannelIdByDisplayName(String displayName) async {
    if (displayName.isEmpty) return null;
    final db = await database;
    final result = await db.rawQuery(
      'SELECT channel_id FROM channels WHERE LOWER(display_name) = LOWER(?) LIMIT 1',
      [displayName],
    );
    return result.isNotEmpty ? result.first['channel_id'] as String? : null;
  }

  static Future<List<EpgProgram>> getProgramsByChannelId(String channelId) async {
    if (channelId.isEmpty) return [];
    final db = await database;
    final results = await db.query(
      'programs',
      where: 'channel_id = ?',
      whereArgs: [channelId],
      orderBy: 'start ASC',
    );
    return results.map((row) => EpgProgram(
      title: row['title'] as String? ?? '',
      description: row['description'] as String? ?? '',
      start: DateTime.fromMillisecondsSinceEpoch(row['start'] as int),
      stop: DateTime.fromMillisecondsSinceEpoch(row['stop'] as int),
    )).toList();
  }

  static Future<String?> getChannelIcon(String channelId) async {
    if (channelId.isEmpty) return null;
    final db = await database;
    final result = await db.rawQuery(
      'SELECT icon FROM channels WHERE LOWER(channel_id) = LOWER(?) LIMIT 1',
      [channelId],
    );
    return result.isNotEmpty ? result.first['icon'] as String? : null;
  }

  static Future<int> getProgramCount() async {
    final db = await database;
    final count = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM programs'),
    );
    return count ?? 0;
  }

  static Future<int> getChannelCount() async {
    final db = await database;
    final count = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM channels'),
    );
    return count ?? 0;
  }
}
