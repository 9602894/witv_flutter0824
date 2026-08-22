import 'dart:async';
import 'dart:convert';
import 'dart:io';
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
  static const int _dbVersion = 3; // 升到 v3，加 date 字段

  static Future<Database> get _database async {
    if (_db != null) return _db!;
    _db = await _initDb();
    return _db!;
  }

  static Future<Database> _initDb() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'epg_data.db');

    // ========== 核心优化：新用户直接复制预构建数据库 ==========
    final file = File(path);
    if (!await file.exists()) {
      await _copyPrebuiltDb(path);
    }

    return await openDatabase(
      path,
      version: _dbVersion,
      onCreate: (db, version) async {
        // 如果复制成功，这里不会执行；如果复制失败，创建空表兜底
        await _createAllTables(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          // v1->v2: 加映射表索引（老用户兼容）
          await db.execute('CREATE INDEX IF NOT EXISTS idx_mapping_epgid ON $_mappingsTable(epgid)');
        }
        if (oldVersion < 3) {
          // v2->v3: 节目表加 date 字段和索引
          await db.execute('ALTER TABLE $_programsTable ADD COLUMN date TEXT');
          await db.execute('CREATE INDEX IF NOT EXISTS idx_programs_date ON $_programsTable(date)');
        }
      },
    );
  }

  /// 从 assets 复制预构建数据库，零解析时间
  static Future<void> _copyPrebuiltDb(String path) async {
    try {
      final data = await rootBundle.load('assets/epg_init.db');
      final bytes = data.buffer.asUint8List();
      await File(path).writeAsBytes(bytes, flush: true);
      LogService.write('EpgDatabase: 预构建数据库复制完成');
    } catch (e) {
      LogService.write('EpgDatabase: 未找到预构建数据库，将创建空库: $e');
    }
  }

  static Future<void> _createAllTables(Database db) async {
    await db.execute(
      "CREATE TABLE IF NOT EXISTS $_programsTable ("
      "id INTEGER PRIMARY KEY AUTOINCREMENT,"
      "channel_name TEXT NOT NULL,"
      "title TEXT NOT NULL,"
      "start_time INTEGER NOT NULL,"
      "end_time INTEGER NOT NULL,"
      "desc TEXT,"
      "date TEXT NOT NULL"
      ")",
    );
    await db.execute("CREATE INDEX IF NOT EXISTS idx_programs_channel_time ON $_programsTable(channel_name, start_time, end_time)");
    await db.execute("CREATE INDEX IF NOT EXISTS idx_programs_date ON $_programsTable(date)");

    await db.execute(
      "CREATE TABLE IF NOT EXISTS $_mappingsTable ("
      "name TEXT PRIMARY KEY COLLATE NOCASE,"  // NOCASE: 大小写不敏感
      "epgid TEXT NOT NULL"
      ")",
    );
    await db.execute("CREATE INDEX IF NOT EXISTS idx_mapping_epgid ON $_mappingsTable(epgid)");

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

  // ==================== 映射表（只读，预置） ====================

  /// Fallback：如果未使用预构建 db，首次从 JSON 导入（保留旧逻辑兼容）
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
            if (++cnt % 1000 == 0) {
              await batch.commit(noResult: true);
              // batch 提交后需要重新创建，否则后续 insert 不生效
            }
          }
        }
        await batch.commit(noResult: true);
      });

      LogService.write('EpgDatabase: 映射表 Fallback 导入完成');
    } catch (e) {
      LogService.write('EpgDatabase: 映射表 Fallback 导入失败: $e');
    }
  }

  // ==================== 核心查询优化（JOIN 一次往返） ====================

  /// 查单个频道当前节目（自动映射，大小写不敏感）
  static Future<EpgProgram?> getCurrentProgram(String channelName, DateTime nowUtc) async {
    final db = await _database;
    final nowMs = nowUtc.millisecondsSinceEpoch;
    final rows = await db.rawQuery('''
      SELECT p.title, p.start_time, p.end_time, p.desc
      FROM $_programsTable p
      INNER JOIN $_mappingsTable m ON p.channel_name = m.epgid
      WHERE m.name = ? COLLATE NOCASE
        AND p.start_time <= ?
        AND p.end_time >= ?
      ORDER BY p.start_time ASC
      LIMIT 1
    ''', [channelName, nowMs, nowMs]);
    return rows.isNotEmpty ? _rowToProgram(rows.first) : null;
  }

  /// 查单个频道当天全部节目
  static Future<List<EpgProgram>> getProgramsForChannel(String channelName) async {
    final db = await _database;
    final rows = await db.rawQuery('''
      SELECT p.title, p.start_time, p.end_time, p.desc
      FROM $_programsTable p
      INNER JOIN $_mappingsTable m ON p.channel_name = m.epgid
      WHERE m.name = ? COLLATE NOCASE
      ORDER BY p.start_time ASC
    ''', [channelName]);
    return rows.map(_rowToProgram).toList();
  }

  /// 查多个频道当前节目（批量，一次 SQL 往返）
  static Future<Map<String, EpgProgram?>> getCurrentProgramsForChannels(
      List<String> channelNames, DateTime nowUtc) async {
    if (channelNames.isEmpty) return {};
    final db = await _database;
    final nowMs = nowUtc.millisecondsSinceEpoch;
    final ph = List.filled(channelNames.length, '?').join(',');

    final rows = await db.rawQuery('''
      SELECT p.title, p.start_time, p.end_time, p.desc, m.name as query_name
      FROM $_programsTable p
      INNER JOIN $_mappingsTable m ON p.channel_name = m.epgid
      WHERE m.name IN ($ph) COLLATE NOCASE
        AND p.start_time <= ?
        AND p.end_time >= ?
      ORDER BY p.start_time ASC
    ''', [...channelNames, nowMs, nowMs]);

    // 结果映射回原始传入名称（大小写兼容）
    final result = <String, EpgProgram?>{for (var n in channelNames) n: null};
    for (final row in rows) {
      final qName = (row['query_name'] as String).toLowerCase();
      for (final orig in channelNames) {
        if (orig.toLowerCase() == qName && result[orig] == null) {
          result[orig] = _rowToProgram(row);
          break;
        }
      }
    }
    return result;
  }

  /// 查多个频道全天节目（批量）
  static Future<Map<String, List<EpgProgram>>> getProgramsForChannels(List<String> channelNames) async {
    if (channelNames.isEmpty) return {};
    final db = await _database;
    final ph = List.filled(channelNames.length, '?').join(',');

    final rows = await db.rawQuery('''
      SELECT p.title, p.start_time, p.end_time, p.desc, m.name as query_name
      FROM $_programsTable p
      INNER JOIN $_mappingsTable m ON p.channel_name = m.epgid
      WHERE m.name IN ($ph) COLLATE NOCASE
      ORDER BY p.start_time ASC
    ''', channelNames);

    final result = <String, List<EpgProgram>>{for (var n in channelNames) n: []};
    for (final row in rows) {
      final qName = (row['query_name'] as String).toLowerCase();
      for (final orig in channelNames) {
        if (orig.toLowerCase() == qName) {
          result[orig]!.add(_rowToProgram(row));
          break;
        }
      }
    }
    return result;
  }

  static Future<EpgProgram?> getNextProgram(String channelName, DateTime nowUtc) async {
    final db = await _database;
    final nowMs = nowUtc.millisecondsSinceEpoch;
    final rows = await db.rawQuery('''
      SELECT p.title, p.start_time, p.end_time, p.desc
      FROM $_programsTable p
      INNER JOIN $_mappingsTable m ON p.channel_name = m.epgid
      WHERE m.name = ? COLLATE NOCASE
        AND p.start_time > ?
      ORDER BY p.start_time ASC
      LIMIT 1
    ''', [channelName, nowMs]);
    return rows.isNotEmpty ? _rowToProgram(rows.first) : null;
  }

  static Future<String?> getChannelIcon(String channelName) async {
    final db = await _database;
    // 先按原始名查
    var rows = await db.query(_iconsTable,
        where: 'channel_name = ? COLLATE NOCASE', whereArgs: [channelName], limit: 1);
    if (rows.isNotEmpty) return rows.first['icon_url'] as String?;

    // 再按映射后的 epgid 查
    final epgidRows = await db.query(_mappingsTable,
        columns: ['epgid'], where: 'name = ? COLLATE NOCASE', whereArgs: [channelName], limit: 1);
    if (epgidRows.isNotEmpty) {
      final epgid = epgidRows.first['epgid'] as String;
      rows = await db.query(_iconsTable,
          where: 'channel_name = ? COLLATE NOCASE', whereArgs: [epgid], limit: 1);
      if (rows.isNotEmpty) return rows.first['icon_url'] as String?;
    }
    return null;
  }

  /// 获取全部 name -> epgid 映射（供 LogoService 使用）
  static Future<Map<String, String>> getAllMappings() async {
    final db = await _database;
    final rows = await db.query(_mappingsTable, columns: ['name', 'epgid']);
    return {for (var r in rows) r['name'] as String: r['epgid'] as String};
  }

  // ==================== 写入与清理 ====================

  static Future<void> insertPrograms(
    Map<String, List<EpgProgram>> programs,
    Map<String, String> icons, {
    String? epgHash,
  }) async {
    final db = await _database;
    int totalPrograms = 0; // ✅ 用于外部日志

    await db.transaction((txn) async {
      // 只清节目和图标，不清映射表（映射表是预置的）
      await txn.delete(_programsTable);
      await txn.delete(_iconsTable);
      await txn.delete(_metaTable);

      var batch = txn.batch();
      int cnt = 0;
      for (final entry in programs.entries) {
        for (final prog in entry.value) {
          final dateStr =
              '${prog.start.year}${prog.start.month.toString().padLeft(2, '0')}${prog.start.day.toString().padLeft(2, '0')}';
          batch.insert(_programsTable, {
            'channel_name': entry.key,
            'title': prog.title,
            'start_time': prog.start.millisecondsSinceEpoch,
            'end_time': prog.end.millisecondsSinceEpoch,
            'desc': prog.desc,
            'date': dateStr,
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
        'key': 'update_time',
        'value': DateTime.now().millisecondsSinceEpoch.toString()
      });
      await txn.insert(_metaTable, {
        'key': 'channel_count',
        'value': programs.length.toString()
      });
      await txn.insert(_metaTable, {
        'key': 'program_count',
        'value': cnt.toString()
      });

      totalPrograms = cnt; // 传递计数
    });

    LogService.write('EpgDatabase: 写入 $totalPrograms 条节目，${icons.length} 个图标');
  }

  /// 清理 N 天前的节目（防止数据库无限膨胀）
  static Future<void> cleanOldPrograms(int keepDays) async {
    final db = await _database;
    final cutoff = DateTime.now().subtract(Duration(days: keepDays));
    final dateStr = '${cutoff.year}${cutoff.month.toString().padLeft(2, '0')}${cutoff.day.toString().padLeft(2, '0')}';
    final deleted = await db.delete(
      _programsTable,
      where: 'date < ?',
      whereArgs: [dateStr],
    );
    if (deleted > 0) {
      LogService.write('EpgDatabase: 清理 $deleted 条过期节目（<$dateStr）');
    }
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
      // 注意：映射表不删，它是预置的
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
