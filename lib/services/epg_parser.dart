import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';
import '../models/epg_program.dart';
import 'log_service.dart';
import 'config_service.dart';
import 'epg_database_service.dart';

// ========== Isolate 纯解析函数（不碰数据库） ==========

Future<Map<String, dynamic>> _parseEpgXmlIsolate(String xmlContent) async {
  final sw = Stopwatch()..start();
  final doc = XmlDocument.parse(xmlContent);
  final programs = <String, List<Map<String, dynamic>>>{};
  final icons = <String, String>{};
  final idToName = <String, String>{};

  for (final channel in doc.findAllElements('channel')) {
    final id = channel.getAttribute('id');
    if (id == null || id.isEmpty) continue;
    final dn = channel.findElements('display-name').firstOrNull;
    if (dn != null) {
      final name = dn.text.trim();
      if (name.isNotEmpty) {
        idToName[id] = name;
        final icon = channel.findElements('icon').firstOrNull?.getAttribute('src');
        if (icon != null && icon.isNotEmpty) icons[name] = icon;
      }
    }
  }

  for (final prog in doc.findAllElements('programme')) {
    final chId = prog.getAttribute('channel');
    if (chId == null) continue;
    final chName = idToName[chId];
    if (chName == null) continue;

    final sStr = prog.getAttribute('start');
    final eStr = prog.getAttribute('stop');
    if (sStr == null || eStr == null) continue;

    final start = _parseDateTimeFast(sStr);
    final end   = _parseDateTimeFast(eStr);
    if (start == null || end == null) continue;

    final title = prog.findElements('title').firstOrNull?.text ?? '';
    final desc  = prog.findElements('desc').firstOrNull?.text ?? '';

    programs.putIfAbsent(chName, () => []);
    programs[chName]!.add({
      't': title,
      's': start.millisecondsSinceEpoch,
      'e': end.millisecondsSinceEpoch,
      'd': desc.isNotEmpty ? desc : null,
    });
  }

  for (final list in programs.values) {
    list.sort((a, b) => (a['s'] as int).compareTo(b['s'] as int));
  }

  sw.stop();
  return {'programs': programs, 'icons': icons, 'time': sw.elapsedMilliseconds};
}

DateTime? _parseDateTimeFast(String str) {
  try {
    if (str.length < 14) return null;
    final y = int.parse(str.substring(0, 4));
    final m = int.parse(str.substring(4, 6));
    final d = int.parse(str.substring(6, 8));
    final h = int.parse(str.substring(8, 10));
    final min = int.parse(str.substring(10, 12));
    final sec = int.parse(str.substring(12, 14));
    var dt = DateTime.utc(y, m, d, h, min, sec);
    if (str.length >= 19) {
      final sign = str[15];
      final tzH = int.parse(str.substring(16, 18));
      final tzM = int.parse(str.substring(18, 20));
      final off = tzH * 60 + tzM;
      dt = sign == '+' ? dt.subtract(Duration(minutes: off))
                       : dt.add(Duration(minutes: off));
    }
    return dt;
  } catch (_) {
    return null;
  }
}

// ========== 主类 ==========

class EpgParser {
  static const String _cacheDirName = 'epgCache';
  static Directory? _cacheDir;
  static bool _initialized = false;

  static final _updateLock = Mutex();
  static bool _isBackgroundUpdating = false;

  static Future<void> _initCache() async {
    if (_cacheDir != null) return;
    final dir = await getApplicationDocumentsDirectory();
    _cacheDir = Directory('${dir.path}/$_cacheDirName');
    if (!await _cacheDir!.exists()) await _cacheDir!.create(recursive: true);
  }

  static Future<void> initialize() async {
    if (_initialized) return;
    await _initCache();
    await EpgDatabaseService.initMappingsFromAssets();
    _initialized = true;
    LogService.write('EpgParser: 初始化完成');
  }

  static Future<String?> _getEpgUrl() async {
    final config = await ConfigService.getConfig();
    final inner = config['Configuration'] as Map<String, dynamic>?;
    final raw = inner?['EPG_URLS'] as String?;
    if (raw == null || raw.isEmpty) return null;
    return raw.contains(r'$') ? raw.split(r'$')[0].trim() : raw.trim();
  }

  static String _computeHash(String content) =>
      md5.convert(utf8.encode(content)).toString();

  // ========== 更新流程 ==========

  static Future<bool> checkForUpdate() async {
    if (_isBackgroundUpdating) return false;
    return _updateLock.protect(() async {
      _isBackgroundUpdating = true;
      try {
        await initialize();
        final url = await _getEpgUrl();
        if (url == null) {
          LogService.write('EPG URL 未配置，跳过更新');
          return false;
        }
        return await _checkHashUpdate(url);
      } finally {
        _isBackgroundUpdating = false;
      }
    });
  }

  static Future<bool> _checkHashUpdate(String epgUrl) async {
    try {
      final hashUrl = '$epgUrl.hash';
      final resp = await Dio().get(hashUrl,
          options: Options(receiveTimeout: const Duration(seconds: 10),
                           sendTimeout: const Duration(seconds: 5)));
      final remoteHash = resp.data.toString().trim();
      if (remoteHash.isEmpty) return false;

      final localHash = await EpgDatabaseService.getCachedHash();
      if (localHash == remoteHash) {
        LogService.write('EPG 哈希未变化，跳过');
        return false;
      }

      LogService.write('EPG 需要更新，开始下载...');
      final tempFile = File('${_cacheDir!.path}/epg_temp_${DateTime.now().millisecondsSinceEpoch}.xml');
      await Dio().download(epgUrl, tempFile.path,
          options: Options(receiveTimeout: const Duration(seconds: 60),
                           sendTimeout: const Duration(seconds: 10)));

      final xml = await tempFile.readAsString();
      if (xml.trim().isEmpty || !xml.trim().startsWith('<')) {
        await tempFile.delete();
        return false;
      }

      final newHash = _computeHash(xml);
      LogService.write('EPG 下载完成 ${xml.length} bytes，Isolate 解析中...');

      // 1) Isolate 只做 XML 解析
      final result = await compute(_parseEpgXmlIsolate, xml);

      // 2) 主线程反序列化
      final programs = <String, List<EpgProgram>>{};
      for (final e in (result['programs'] as Map<String, dynamic>).entries) {
        programs[e.key] = (e.value as List).map((m) {
          final map = m as Map<String, dynamic>;
          return EpgProgram(
            title: map['t'] as String,
            start: DateTime.fromMillisecondsSinceEpoch(map['s'] as int),
            end: DateTime.fromMillisecondsSinceEpoch(map['e'] as int),
            desc: map['d'] as String?,
          );
        }).toList();
      }
      final icons = (result['icons'] as Map<String, dynamic>)
          .map((k, v) => MapEntry(k, v.toString()));

      // 3) 主线程写入数据库（事务批量插入，性能足够）
      await EpgDatabaseService.insertPrograms(programs, icons, epgHash: newHash);

      // ✅ 微调：清理三天前的旧节目（避免数据膨胀）
      await EpgDatabaseService.cleanOldPrograms(3); // 只保留最近 3 天

      // 4) 保留 XML 备份
      final xmlFile = File('${_cacheDir!.path}/epg_$newHash.xml');
      await tempFile.copy(xmlFile.path);
      await tempFile.delete();
      await _cleanupOldXml(newHash);

      LogService.write('EPG 更新完成: $newHash, ${programs.length} 频道');
      return true;
    } catch (e) {
      LogService.write('EPG 更新失败: $e');
      return false;
    }
  }

  static Future<void> _cleanupOldXml(String keepHash) async {
    try {
      for (final f in await _cacheDir!.list().toList()) {
        if (f is! File) continue;
        final name = p.basename(f.path);
        if (name.startsWith('epg_') && name.endsWith('.xml') && !name.contains(keepHash)) {
          await f.delete();
        }
      }
    } catch (_) {}
  }

  // ========== 对外 API（全部直查数据库） ==========

  static Future<List<EpgProgram>> getProgramsForChannel(String channelName) async {
    await initialize();
    return EpgDatabaseService.getProgramsForChannel(channelName);
  }

  static Future<Map<String, List<EpgProgram>>> getProgramsForChannels(
      List<String> names) async {
    await initialize();
    return EpgDatabaseService.getProgramsForChannels(names);
  }

  static Future<EpgProgram?> getCurrentProgram(String channelName, DateTime nowUtc) async {
    await initialize();
    return EpgDatabaseService.getCurrentProgram(channelName, nowUtc);
  }

  static Future<EpgProgram?> getNextProgram(String channelName, DateTime nowUtc) async {
    await initialize();
    return EpgDatabaseService.getNextProgram(channelName, nowUtc);
  }

  static Future<Map<String, EpgProgram?>> getCurrentProgramsForChannels(
      List<String> names, DateTime nowUtc) async {
    await initialize();
    return EpgDatabaseService.getCurrentProgramsForChannels(names, nowUtc);
  }

  static Future<String?> getChannelIconUrl(String channelName) async {
    await initialize();
    return EpgDatabaseService.getChannelIcon(channelName);
  }

  static Future<void> preloadAll() async => initialize();

  static Future<void> clearCache() async {
    await _initCache();
    if (await _cacheDir!.exists()) {
      await _cacheDir!.delete(recursive: true);
      await _cacheDir!.create();
    }
    await EpgDatabaseService.clearAll();
    _initialized = false;
    LogService.write('EPG 缓存已清空');
  }

  static Future<String?> getCachedHash() async {
    await initialize();
    return EpgDatabaseService.getCachedHash();
  }
}

class Mutex {
  Future<void>? _last;
  Future<T> protect<T>(Future<T> Function() task) async {
    final prev = _last;
    final c = Completer<void>();
    _last = c.future;
    try {
      if (prev != null) await prev;
      return await task();
    } finally {
      c.complete();
    }
  }
}
