import 'dart:async';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/epg_program.dart';
import 'log_service.dart';

// ============================================================
// EpgDatabaseService —— 数据库版 EPG 存储（支持 display-name 索引）
// ============================================================

class EpgDatabaseService {
  static Database? _db;
  static final _initLock = Object();

  static Future<Database> get database async {
    if (_db != null) return _db!;
    return await _initDatabase();
  }

  static Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'epg_v2.db'); // 升级数据库版本

    return await openDatabase(
      path,
      version: 2,
      onCreate: (db, version) async {
        // 节目表
        await db.execute('''
          CREATE TABLE programs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            channel_id TEXT NOT NULL,
            title TEXT,
            description TEXT,
            start INTEGER NOT NULL,
            stop INTEGER NOT NULL
          )
        ''');

        // 频道信息表（新增：支持 display-name 到 channel id 的映射）
        await db.execute('''
          CREATE TABLE channels (
            channel_id TEXT PRIMARY KEY,
            display_name TEXT,
            icon TEXT
          )
        ''');

        // 索引
        await db.execute('CREATE INDEX idx_programs_channel ON programs(channel_id)');
        await db.execute('CREATE INDEX idx_programs_time ON programs(start, stop)');
        await db.execute('CREATE INDEX idx_channels_display ON channels(display_name)');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('DROP TABLE IF EXISTS programs');
          await db.execute('DROP TABLE IF EXISTS channels');
          await db.execute('DROP INDEX IF EXISTS idx_programs_channel');
          await db.execute('DROP INDEX IF EXISTS idx_programs_time');
          await db.execute('DROP INDEX IF EXISTS idx_channels_display');
          // 重新创建
          await db.execute('''
            CREATE TABLE programs (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              channel_id TEXT NOT NULL,
              title TEXT,
              description TEXT,
              start INTEGER NOT NULL,
              stop INTEGER NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE channels (
              channel_id TEXT PRIMARY KEY,
              display_name TEXT,
              icon TEXT
            )
          ''');
          await db.execute('CREATE INDEX idx_programs_channel ON programs(channel_id)');
          await db.execute('CREATE INDEX idx_programs_time ON programs(start, stop)');
          await db.execute('CREATE INDEX idx_channels_display ON channels(display_name)');
        }
      },
    );
  }

  // ============================================================
  // 批量插入（事务）
  // ============================================================

  static Future<void> insertPrograms(
    Map<String, List<EpgProgram>> programMap,
    Map<String, String> channelIcons,
  ) async {
    final db = await database;
    await db.transaction((txn) async {
      // 清空旧数据
      await txn.delete('programs');
      await txn.delete('channels');

      // 插入频道信息
      for (final entry in channelIcons.entries) {
        await txn.insert('channels', {
          'channel_id': entry.key,
          'icon': entry.value,
          'display_name': null, // 后面更新
        });
      }

      // 插入节目
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
    LogService.write('EPG数据库: 插入 ${programMap.length} 频道');
  }

  /// 更新频道的 display-name（解析 channel 元素时调用）
  static Future<void> updateChannelDisplayName(String channelId, String displayName) async {
    final db = await database;
    await db.insert(
      'channels',
      {'channel_id': channelId, 'display_name': displayName},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 批量更新 display-names
  static Future<void> batchUpdateDisplayNames(Map<String, String> displayNameMap) async {
    final db = await database;
    await db.transaction((txn) async {
      for (final entry in displayNameMap.entries) {
        await txn.insert(
          'channels',
          {'channel_id': entry.key, 'display_name': entry.value},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  // ============================================================
  // 查询接口
  // ============================================================

  /// 通过 display-name 查找 channel id
  static Future<String?> findChannelIdByDisplayName(String displayName) async {
    final db = await database;
    final result = await db.query(
      'channels',
      columns: ['channel_id'],
      where: 'display_name = ?',
      whereArgs: [displayName],
      limit: 1,
    );
    if (result.isNotEmpty) return result.first['channel_id'] as String?;

    // 如果找不到，尝试直接匹配 channel_id（有些 EPG 的 id 就是 epgid）
    final result2 = await db.query(
      'channels',
      columns: ['channel_id'],
      where: 'channel_id = ?',
      whereArgs: [displayName],
      limit: 1,
    );
    if (result2.isNotEmpty) return result2.first['channel_id'] as String?;

    return null;
  }

  /// 通过 channel id 获取节目单
  static Future<List<EpgProgram>> getProgramsByChannelId(String channelId) async {
    final db = await database;
    final result = await db.query(
      'programs',
      where: 'channel_id = ?',
      whereArgs: [channelId],
      orderBy: 'start ASC',
    );
    return result.map((r) => EpgProgram(
      title: r['title'] as String? ?? '',
      description: r['description'] as String? ?? '',
      start: DateTime.fromMillisecondsSinceEpoch(r['start'] as int),
      stop: DateTime.fromMillisecondsSinceEpoch(r['stop'] as int),
    )).toList();
  }

  /// 获取当前节目（东八区时间）
  static Future<EpgProgram?> getCurrentProgram(String channelId, DateTime now) async {
    final db = await database;
    final nowMs = now.millisecondsSinceEpoch;
    final result = await db.query(
      'programs',
      where: 'channel_id = ? AND start <= ? AND stop > ?',
      whereArgs: [channelId, nowMs, nowMs],
      orderBy: 'start DESC',
      limit: 1,
    );
    if (result.isEmpty) return null;
    final r = result.first;
    return EpgProgram(
      title: r['title'] as String? ?? '',
      description: r['description'] as String? ?? '',
      start: DateTime.fromMillisecondsSinceEpoch(r['start'] as int),
      stop: DateTime.fromMillisecondsSinceEpoch(r['stop'] as int),
    );
  }

  /// 获取下一个节目
  static Future<EpgProgram?> getNextProgram(String channelId, DateTime now) async {
    final db = await database;
    final nowMs = now.millisecondsSinceEpoch;
    final result = await db.query(
      'programs',
      where: 'channel_id = ? AND start > ?',
      whereArgs: [channelId, nowMs],
      orderBy: 'start ASC',
      limit: 1,
    );
    if (result.isEmpty) return null;
    final r = result.first;
    return EpgProgram(
      title: r['title'] as String? ?? '',
      description: r['description'] as String? ?? '',
      start: DateTime.fromMillisecondsSinceEpoch(r['start'] as int),
      stop: DateTime.fromMillisecondsSinceEpoch(r['stop'] as int),
    );
  }

  /// 获取频道图标
  static Future<String?> getChannelIcon(String channelId) async {
    final db = await database;
    final result = await db.query(
      'channels',
      columns: ['icon'],
      where: 'channel_id = ?',
      whereArgs: [channelId],
      limit: 1,
    );
    if (result.isEmpty) return null;
    return result.first['icon'] as String?;
  }

  /// 数据库是否为空
  static Future<bool> isEmpty() async {
    final db = await database;
    final result = await db.rawQuery('SELECT COUNT(*) as count FROM programs');
    final count = (result.first['count'] as num?)?.toInt() ?? 0;
    return count == 0;
  }

  /// 清空数据
  static Future<void> clearAll() async {
    final db = await database;
    await db.delete('programs');
    await db.delete('channels');
  }

  /// 关闭数据库
  static Future<void> close() async {
    if (_db != null) {
      await _db!.close();
      _db = null;
    }
  }
}
