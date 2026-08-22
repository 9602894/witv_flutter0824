import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/epg_program.dart';
import 'log_service.dart';

class EpgDatabaseService {
  static Database? _db;
  static const String _programsTable = 'epg_programs';
  static const String _mappingsTable = 'epg_mappings';
  static const String _iconsTable   = 'epg_icons';
  static const String _metaTable    = 'epg_meta';
  static const int _dbVersion = 2;

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
        await _createAllTables(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) await _createAllTables(db);
      },
    );
  }

  static Future<void> _createAllTables(Database db) async {
    await db.execute(
      "CREATE TABLE IF NOT EXISTS $_programsTable ("
      "id INTEGER PRIMARY KEY AUTOINCREMENT,"
      "channel_name TEXT NOT NULL,"
      "title TEXT NOT NULL,"
      "start_time INTEGER NOT NULL,"
      "end_time INTEGER NOT NULL,"
      "desc TEXT"
      ")",
    );
    await db.execute(
      "CREATE INDEX IF NOT EXISTS idx_channel_time ON $_programsTable(channel_name, start_time, end_time)",
    );

    await db.execute(
      "CREATE TABLE IF NOT EXISTS $_mappingsTable ("
      "id INTEGER PRIMARY KEY AUTOINCREMENT,"
      "name TEXT NOT NULL,"
      "epgid TEXT NOT NULL,"
      "UNIQUE(name)"
      ")",
    );
    await db.execute(
      "CREATE INDEX IF NOT EXISTS idx_mapping_name ON $_mappingsTable(name)",
    );
    await db.execute(
      "CREATE INDEX IF NOT EXISTS idx_mapping_epgid ON $_mappingsTable(epgid)",
    );

    await db.execute(
      "CREATE TABLE IF NOT EXISTS $_iconsTable ("
      "channel_name TEXT PRIMARY KEY,"
      "icon_url TEXT NOT NULL"
      ")",
    );

    await db.execute(
      "CREATE TABLE IF NOT EXISTS $_metaTable ("
      "key TEXT PRIMARY KEY,"
      "value TEXT"
      ")",
    );
  }

  // ==================== 映射表管理 ====================

  /// 首次启动从 assets 导入，后续启动直接跳过
  static Future<void> initMappingsFromAssets() async {
    final db = await _database;
    final countResult = await db.rawQuery('SELECT COUNT(*) as count FROM $_mappingsTable');
    final count = Sqflite.firstIntValue(countResult) ?? 0;
    if (count > 0) return;

    try {
      final content = await rootBundle.loadString('assets/epg_data.json');
      final decoded = jsonDecode(content);
      final List<dynamic> jsonList = decoded is List
          ? decoded
          : ((decoded as Map)['epgs'] ?? (decoded)['data'] ?? (decoded)['channels'] ?? (decoded)['list'] ?? <dynamic>[]) as List;

      await db.transaction((txn) async {
        final batch = txn.batch();
        int cnt = 0;
        for (final item in jsonList) {
          if (item is! Map) continue;
          final epgid = item['epgid'] as String?;
          final nameStr = item['name'] as String?;
          if (epgid == null || nameStr == null) continue;
          for (final name in nameStr.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty)) {
            batch.insert(_mappingsTable, {'name': name, 'epgid': epgid},
                conflictAlgorithm: ConflictAlgorithm.ignore);
            if (++cnt % 500 == 0) await batch.commit(noResult: true);
          }
        }
        await batch.commit(noResult: true);
      });

      final finalCount = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) as count FROM $_mappingsTable'),
      );
      LogService.write('EpgDatabase: 映射表初始化完成，共 $finalCount 条');
    } catch (e) {
      LogService.write('EpgDatabase: 映射表初始化失败: $e');
    }
  }

  static Future<String?> getEpgIdByName(String channelName) async {
    final db = await _database;
    final rows = await db.query(_mappingsTable,
        columns: ['epgid'], where: 'name = ?', whereArgs: [channelName], limit: 1);
    return rows.isNotEmpty ? rows.first['epgid'] as String : null;
  }

  static Future<Map<String, String?>> getEpgIdsByNames(List<String> names) async {
    if (names.isEmpty) return {};
    final db = await _database;
    final ph = List.filled(names.length, '?').join(',');
    final rows = await db.query(_mappingsTable,
        where: 'name IN ($ph)', whereArgs: names);
    final result = {for (var n in names) n: null as String?};
    for (final row in rows) {
      result[row['name'] as String] = row['epgid'] as String;
    }
    return result;
  }

  // ==================== 节目数据管理 ====================

  static Future<void> insertPrograms(
    Map<String, List<EpgProgram>> programs,
    Map<String, String> icons, {
    String? epgHash,
  }) async {
    final db = await _database;
    await db.transaction((txn) async {
      await txn.delete(_programsTable);
      await txn.delete(_iconsTable);
      await txn.delete(_metaTable);

      var batch = txn.batch();
      int cnt = 0;
      for (final entry in programs.entries) {
        for (final prog in entry.value) {
          batch.insert(_programsTable, {
            'channel_name': entry.key,
            'title': prog.title,
            'start_time': prog.start.millisecondsSinceEpoch,
            'end_time': prog.end.millisecondsSinceEpoch,
            'desc': prog.desc,
          });
          if (++cnt % 500 == 0) {
            await batch.commit(noResult: true);
            batch = txn.batch();
          }
        }
      }
      await batch.commit(noResult: true);

      if (icons.isNotEmpty) {
        var iconBatch = txn.batch();
        int icnt = 0;
        for (final e in icons.entries) {
          iconBatch.insert(_iconsTable, {'channel_name': e.key, 'icon_url': e.value});
          if (++icnt % 500 == 0) {
            await iconBatch.commit(noResult: true);
            iconBatch = txn.batch();
          }
        }
        await iconBatch.commit(noResult: true);
      }

      if (epgHash != null) {
        await txn.insert(_metaTable, {'key': 'hash', 'value': epgHash});
      }
      await txn.insert(_metaTable, {
        'key': 'update_time', 'value': DateTime.now().millisecondsSinceEpoch.toString()
      });
      await txn.insert(_metaTable, {
        'key': 'channel_count', 'value': programs.length.toString()
      });
      await txn.insert(_metaTable, {
        'key': 'program_count', 'value': cnt.toString()
      });
    });
    LogService.write('EpgDatabase: 写入 $cnt 条节目，${icons.length} 个图标');
  }

  /// 核心查询：传入播放列表中的频道名，自动做映射转换
  static Future<List<EpgProgram>> getProgramsForChannel(String channelName) async {
    final epgid = await getEpgIdByName(channelName);
    final target = epgid ?? channelName;

    final db = await _database;
    final rows = await db.query(_programsTable,
        where: 'channel_name = ?', whereArgs: [target], orderBy: 'start_time ASC');
    return rows.map(_rowToProgram).toList();
  }

  static Future<Map<String, List<EpgProgram>>> getProgramsForChannels(List<String> channelNames) async {
    if (channelNames.isEmpty) return {};
    final epgIdMap = await getEpgIdsByNames(channelNames);

    final nameToTarget = <String, String>{};
    final allTargets = <String>{};
    for (final n in channelNames) {
      final t = epgIdMap[n] ?? n;
      nameToTarget[n] = t;
      allTargets.add(t);
    }

    final db = await _database;
    final ph = List.filled(allTargets.length, '?').join(',');
    final rows = await db.query(_programsTable,
        where: 'channel_name IN ($ph)',
        whereArgs: allTargets.toList(),
        orderBy: 'start_time ASC');

    final result = <String, List<EpgProgram>>{for (var n in channelNames) n: []};
    for (final row in rows) {
      final rowName = row['channel_name'] as String;
      for (final e in nameToTarget.entries) {
        if (e.value == rowName) result[e.key]!.add(_rowToProgram(row));
      }
    }
    return result;
  }

  static Future<EpgProgram?> getCurrentProgram(String channelName, DateTime nowUtc) async {
    final progs = await getCurrentPrograms(channelName, nowUtc);
    return progs.isNotEmpty ? progs.first : null;
  }

  static Future<List<EpgProgram>> getCurrentPrograms(String channelName, DateTime nowUtc) async {
    final epgid = await getEpgIdByName(channelName);
    final target = epgid ?? channelName;
    final nowMs = nowUtc.millisecondsSinceEpoch;

    final db = await _database;
    final rows = await db.query(_programsTable,
        where: 'channel_name = ? AND start_time <= ? AND end_time >= ?',
        whereArgs: [target, nowMs, nowMs],
        orderBy: 'start_time ASC');
    return rows.map(_rowToProgram).toList();
  }

  static Future<EpgProgram?> getNextProgram(String channelName, DateTime nowUtc) async {
    final epgid = await getEpgIdByName(channelName);
    final target = epgid ?? channelName;
    final nowMs = nowUtc.millisecondsSinceEpoch;

    final db = await _database;
    final rows = await db.query(_programsTable,
        where: 'channel_name = ? AND start_time > ?',
        whereArgs: [target, nowMs],
        orderBy: 'start_time ASC', limit: 1);
    return rows.isNotEmpty ? _rowToProgram(rows.first) : null;
  }

  static Future<Map<String, EpgProgram?>> getCurrentProgramsForChannels(
      List<String> channelNames, DateTime nowUtc) async {
    if (channelNames.isEmpty) return {};
    final epgIdMap = await getEpgIdsByNames(channelNames);

    final targets = <String, String>{};
    final allTargets = <String>{};
    for (final n in channelNames) {
      final t = epgIdMap[n] ?? n;
      targets[n] = t;
      allTargets.add(t);
    }

    final nowMs = nowUtc.millisecondsSinceEpoch;
    final db = await _database;
    final ph = List.filled(allTargets.length, '?').join(',');
    final rows = await db.query(_programsTable,
        where: 'channel_name IN ($ph) AND start_time <= ? AND end_time >= ?',
        whereArgs: [...allTargets, nowMs, nowMs]);

    final result = <String, EpgProgram?>{for (var n in channelNames) n: null};
    for (final row in rows) {
      final rowName = row['channel_name'] as String;
      for (final e in targets.entries) {
        if (e.value == rowName) {
          result[e.key] = _rowToProgram(row);
          break;
        }
      }
    }
    return result;
  }

  static Future<String?> getChannelIcon(String channelName) async {
    final db = await _database;
    var rows = await db.query(_iconsTable,
        where: 'channel_name = ?', whereArgs: [channelName], limit: 1);
    if (rows.isNotEmpty) return rows.first['icon_url'] as String?;

    final epgid = await getEpgIdByName(channelName);
    if (epgid != null) {
      rows = await db.query(_iconsTable,
          where: 'channel_name = ?', whereArgs: [epgid], limit: 1);
      if (rows.isNotEmpty) return rows.first['icon_url'] as String?;
    }
    return null;
  }

  static Future<bool> isEmpty() async {
    final db = await _database;
    final r = await db.rawQuery('SELECT COUNT(*) as count FROM $_programsTable');
    return (Sqflite.firstIntValue(r) ?? 0) == 0;
  }

  static Future<String?> getCachedHash() async {
    final db = await _database;
    final rows = await db.query(_metaTable, where: 'key = ?', whereArgs: ['hash'], limit: 1);
    return rows.isNotEmpty ? rows.first['value'] as String? : null;
  }

  static Future<void> clearAll() async {
    final db = await _database;
    await db.transaction((txn) async {
      await txn.delete(_programsTable);
      await txn.delete(_iconsTable);
      await txn.delete(_metaTable);
    });
    LogService.write('EpgDatabase: 节目数据已清空');
  }

  static EpgProgram _rowToProgram(Map<String, dynamic> row) => EpgProgram(
    title: row['title'] as String,
    start: DateTime.fromMillisecondsSinceEpoch(row['start_time'] as int),
    end: DateTime.fromMillisecondsSinceEpoch(row['end_time'] as int),
    desc: row['desc'] as String?,
  );
}
