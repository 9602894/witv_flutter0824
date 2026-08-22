import 'dart:async';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/epg_program.dart';
import 'log_service.dart';

class EpgDatabaseService {
  static Database? _db;
  static const String _tableName = 'epg_programs';
  static const String _metaTable = 'epg_meta';
  static const int _dbVersion = 1;

  static Future<Database> get _database async {
    if (_db != null) return _db!;
    _db = await _initDb();
    return _db!;
  }

  static Future<Database> _initDb() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'epg_data.db');

    return await openDatabase(
      path,
      version: _dbVersion,
      onCreate: (db, version) async {
        await db.execute(
          "CREATE TABLE epg_programs ("
          "id INTEGER PRIMARY KEY AUTOINCREMENT,"
          "channel_name TEXT NOT NULL,"
          "title TEXT NOT NULL,"
          "start_time INTEGER NOT NULL,"
          "end_time INTEGER NOT NULL,"
          "desc TEXT"
          ")",
        );
        await db.execute(
          "CREATE INDEX idx_channel_time ON epg_programs(channel_name, start_time, end_time)",
        );
        await db.execute(
          "CREATE TABLE epg_meta ("
          "key TEXT PRIMARY KEY,"
          "value TEXT"
          ")",
        );
      },
    );
  }

  static Future<void> insertPrograms(
    Map<String, List<EpgProgram>> programs,
    Map<String, String> icons, {
    String? epgHash,
  }) async {
    final db = await _database;
    int totalCount = 0;

    await db.transaction((txn) async {
      await txn.delete(_tableName);
      await txn.delete(_metaTable);

      final batch = txn.batch();
      int count = 0;

      for (final entry in programs.entries) {
        for (final prog in entry.value) {
          batch.insert(_tableName, {
            'channel_name': entry.key,
            'title': prog.title,
            'start_time': prog.start.millisecondsSinceEpoch,
            'end_time': prog.end.millisecondsSinceEpoch,
            'desc': prog.desc,
          });
          count++;
          if (count % 500 == 0) await batch.commit(noResult: true);
        }
      }
      await batch.commit(noResult: true);
      totalCount = count;

      if (epgHash != null) {
        await txn.insert(_metaTable, {'key': 'hash', 'value': epgHash});
      }
      await txn.insert(_metaTable, {
        'key': 'update_time',
        'value': DateTime.now().millisecondsSinceEpoch.toString(),
      });
      await txn.insert(_metaTable, {
        'key': 'channel_count',
        'value': programs.length.toString(),
      });
      await txn.insert(_metaTable, {
        'key': 'program_count',
        'value': count.toString(),
      });
    });

    LogService.write('EpgDatabase: 插入 $totalCount 条节目');
  }

  /// ✅ 查询单个频道当前节目（返回列表）
  static Future<List<EpgProgram>> getCurrentPrograms(
    String channelName,
    DateTime nowUtc,
  ) async {
    final db = await _database;
    final nowMs = nowUtc.millisecondsSinceEpoch;
    final rows = await db.query(
      _tableName,
      where: 'channel_name = ? AND start_time <= ? AND end_time >= ?',
      whereArgs: [channelName, nowMs, nowMs],
      orderBy: 'start_time ASC',
    );
    return rows.map((r) => _rowToProgram(r)).toList();
  }

  /// 查询单个频道当前节目（简化版，返回第一条）
  static Future<EpgProgram?> getCurrentProgram(
    String channelName,
    DateTime nowUtc,
  ) async {
    final programs = await getCurrentPrograms(channelName, nowUtc);
    return programs.isNotEmpty ? programs.first : null;
  }

  static Future<EpgProgram?> getNextProgram(
    String channelName,
    DateTime nowUtc,
  ) async {
    final db = await _database;
    final nowMs = nowUtc.millisecondsSinceEpoch;
    final rows = await db.query(
      _tableName,
      where: 'channel_name = ? AND start_time > ?',
      whereArgs: [channelName, nowMs],
      orderBy: 'start_time ASC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _rowToProgram(rows.first);
  }

  static Future<List<EpgProgram>> getProgramsForChannel(String channelName) async {
    final db = await _database;
    final rows = await db.query(
      _tableName,
      where: 'channel_name = ?',
      whereArgs: [channelName],
      orderBy: 'start_time ASC',
    );
    return rows.map((r) => _rowToProgram(r)).toList();
  }

  static Future<Map<String, EpgProgram?>> getCurrentProgramsForChannels(
    List<String> channelNames,
    DateTime nowUtc,
  ) async {
    if (channelNames.isEmpty) return {};
    final db = await _database;
    final nowMs = nowUtc.millisecondsSinceEpoch;
    final placeholders = List.filled(channelNames.length, '?').join(',');
    final rows = await db.query(
      _tableName,
      where: 'channel_name IN ($placeholders) AND start_time <= ? AND end_time >= ?',
      whereArgs: [...channelNames, nowMs, nowMs],
    );

    final result = <String, EpgProgram?>{for (var n in channelNames) n: null};
    for (final row in rows) {
      result[row['channel_name'] as String] = _rowToProgram(row);
    }
    return result;
  }

  static Future<bool> isEmpty() async {
    final db = await _database;
    final result = await db.rawQuery('SELECT COUNT(*) as count FROM epg_programs');
    return (Sqflite.firstIntValue(result) ?? 0) == 0;
  }

  static EpgProgram _rowToProgram(Map<String, Object?> row) => EpgProgram(
    title: row['title'] as String,
    start: DateTime.fromMillisecondsSinceEpoch(row['start_time'] as int),
    end: DateTime.fromMillisecondsSinceEpoch(row['end_time'] as int),
    desc: row['desc'] as String?,
  );
}
