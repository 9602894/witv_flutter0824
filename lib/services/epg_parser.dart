import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:xml/xml.dart';
import 'package:collection/collection.dart';
import '../models/epg_program.dart';
import 'log_service.dart';
import 'epg_database_service.dart';
import 'config_service.dart';

class EpgParser {
  static const String _epgUrlKey = 'epg_url';
  static const String _lastEpgUpdateKey = 'last_epg_update';
  static const String _epgCacheFileName = 'epg_cache.json';
  static const String _epgDataJsonAsset = 'assets/epg_data.json';

  // ---------- 内存缓存 ----------
  static Map<String, List<EpgProgram>>? _memoryCache;
  static Map<String, String>? _iconCache;
  static DateTime? _cacheTime;
  static final _cacheLock = Object();

  // ---------- epg_data.json 映射 ----------
  static Map<String, String>? _nameToEpgidMap;

  // ---------- 时区：强制东八区 ----------
  static DateTime get beijingNow {
    final now = DateTime.now();
    return now.toUtc().add(const Duration(hours: 8));
  }

  static DateTime toBeijing(DateTime dt) {
    return dt.toUtc().add(const Duration(hours: 8));
  }

  static String formatBeijingTime(DateTime dt) {
    final bj = toBeijing(dt);
    return '${bj.hour.toString().padLeft(2, '0')}:${bj.minute.toString().padLeft(2, '0')}';
  }

  // ============================================================
  // 加载 epg_data.json
  // ============================================================

  static Future<void> _loadEpgNameMap() async {
    if (_nameToEpgidMap != null) return;

    try {
      final jsonString = await rootBundle.loadString(_epgDataJsonAsset);
      final List<dynamic> data = jsonDecode(jsonString);

      _nameToEpgidMap = {};
      for (final item in data) {
        final epgid = item['epgid'] as String;
        final namesStr = item['name'] as String;
        final names = namesStr.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty);
        for (final name in names) {
          _nameToEpgidMap![name] = epgid;
        }
      }
      LogService.write('EPG名称映射加载完成: ${_nameToEpgidMap!.length} 个名称');
    } catch (e, stack) {
      LogService.writeCrashLog('加载epg_data.json失败: $e', stack);
      _nameToEpgidMap = {};
    }
  }

  static Future<String?> getEpgidByChannelName(String channelName) async {
    await _loadEpgNameMap();
    return _nameToEpgidMap?[channelName];
  }

  // ============================================================
  // EPG XML 下载与解析
  // ============================================================

  static Future<bool> checkForUpdate() async {
    try {
      final settings = await _loadSettings();
      final url = settings[_epgUrlKey] as String?;
      if (url == null || url.isEmpty) return false;

      final lastUpdate = settings[_lastEpgUpdateKey] as int?;
      final lastDate = lastUpdate != null
          ? DateTime.fromMillisecondsSinceEpoch(lastUpdate)
          : DateTime(2000);

      if (DateTime.now().difference(lastDate) < const Duration(hours: 6)) {
        return false;
      }

      LogService.write('EPG: 检查更新 $url');
      final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final xmlString = utf8.decode(response.bodyBytes);
        await _parseAndCache(xmlString, url);
        await _saveSettings({
          ...settings,
          _lastEpgUpdateKey: DateTime.now().millisecondsSinceEpoch,
        });
        return true;
      }
    } catch (e) {
      LogService.write('EPG更新检查失败: $e');
    }
    return false;
  }

  // 修改：增强日志，便于排查
  static Future<void> forceRefresh() async {
    try {
      final settings = await _loadSettings();
      final url = settings[_epgUrlKey] as String?;
      LogService.write('EPG forceRefresh: url=$url');
      if (url == null || url.isEmpty) throw Exception('未配置EPG地址');

      LogService.write('EPG forceRefresh: 开始下载...');
      final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 60));
      LogService.write('EPG forceRefresh: HTTP ${response.statusCode}, bodyLength=${response.bodyBytes.length}');

      if (response.statusCode == 200) {
        final xmlString = utf8.decode(response.bodyBytes);
        LogService.write('EPG forceRefresh: 开始解析，xml长度=${xmlString.length}');
        await _parseAndCache(xmlString, url);
        await _saveSettings({
          ...settings,
          _lastEpgUpdateKey: DateTime.now().millisecondsSinceEpoch,
        });
        LogService.write('EPG: 强制刷新成功');
      } else {
        throw Exception('HTTP ${response.statusCode}');
      }
    } catch (e, stack) {
      LogService.write('EPG forceRefresh 异常: $e');
      await LogService.writeCrashLog('EPG强制刷新失败: $e', stack);
      rethrow;
    }
  }

  // ============================================================
  // XML 解析
  // ============================================================

  static Future<void> _parseAndCache(String xmlString, String sourceUrl) async {
    final stopwatch = Stopwatch()..start();

    await EpgDatabaseService.clearAll();

    final document = XmlDocument.parse(xmlString);

    final displayNameToChannelId = <String, String>{};
    final channelIcons = <String, String>{};

    final channels = document.findAllElements('channel');
    for (final channel in channels) {
      final id = channel.getAttribute('id');
      if (id == null) continue;

      final displayNames = channel.findAllElements('display-name');
      for (final dn in displayNames) {
        final name = dn.value?.trim() ?? '';
        if (name.isNotEmpty) {
          displayNameToChannelId[name] = id;
        }
      }

      final iconElem = channel.getElement('icon');
      if (iconElem != null) {
        final src = iconElem.getAttribute('src');
        if (src != null && src.isNotEmpty) {
          channelIcons[id] = src;
        }
      }
    }

    final programMap = <String, List<EpgProgram>>{};
    final programmes = document.findAllElements('programme');

    for (final prog in programmes) {
      final channelId = prog.getAttribute('channel');
      final startStr = prog.getAttribute('start');
      final stopStr = prog.getAttribute('stop');
      if (channelId == null || startStr == null || stopStr == null) continue;

      final start = _parseXmltvTime(startStr);
      final stop = _parseXmltvTime(stopStr);
      if (start == null || stop == null) continue;

      final title = prog.getElement('title')?.value ?? '';
      final desc = prog.getElement('desc')?.value ?? '';

      final program = EpgProgram(
        title: title,
        description: desc,
        start: start,
        stop: stop,
      );

      programMap.putIfAbsent(channelId, () => []).add(program);
    }

    for (final entry in programMap.entries) {
      entry.value.sort((a, b) => a.start.compareTo(b.start));
    }

    await EpgDatabaseService.insertPrograms(programMap, channelIcons);

    _memoryCache = programMap;
    _iconCache = channelIcons;
    _cacheTime = DateTime.now();

    stopwatch.stop();
    LogService.write('EPG解析完成: ${programMap.length} 频道, ${programmes.length} 节目, 耗时 ${stopwatch.elapsedMilliseconds}ms');
  }

  static DateTime? _parseXmltvTime(String t) {
    try {
      String s = t.trim();

      final tzIdx = s.indexOfRegExp(RegExp(r'[+-]\\d{4}'));
      if (tzIdx > 0) {
        s = s.substring(0, tzIdx).trim();
      }

      if (s.length >= 14) {
        final year = int.parse(s.substring(0, 4));
        final month = int.parse(s.substring(4, 6));
        final day = int.parse(s.substring(6, 8));
        final hour = int.parse(s.substring(8, 10));
        final minute = int.parse(s.substring(10, 12));
        final second = int.parse(s.substring(12, 14));
        return DateTime.utc(year, month, day, hour, minute, second);
      }
    } catch (_) {}
    return null;
  }

  // ============================================================
  // 查询接口（三层精准匹配）
  // ============================================================

  static Future<List<EpgProgram>> getProgramsByChannelName(String channelName) async {
    if (channelName.isEmpty) return [];

    final epgid = await getEpgidByChannelName(channelName);
    if (epgid == null) {
      LogService.write('EPG: 未找到频道映射: $channelName');
      return [];
    }

    final channelId = await EpgDatabaseService.findChannelIdByDisplayName(epgid);
    if (channelId == null) {
      LogService.write('EPG: 未找到 channel id: epgid=$epgid');
      return [];
    }

    final programs = await EpgDatabaseService.getProgramsByChannelId(channelId);
    return programs;
  }

  static Future<EpgProgram?> getCurrentProgram(String channelName) async {
    final programs = await getProgramsByChannelName(channelName);
    if (programs.isEmpty) return null;

    final now = beijingNow;
    return programs.firstWhereOrNull((p) => p.start.isBefore(now) && p.stop.isAfter(now));
  }

  static Future<EpgProgram?> getNextProgram(String channelName) async {
    final programs = await getProgramsByChannelName(channelName);
    if (programs.isEmpty) return null;

    final now = beijingNow;
    return programs.firstWhereOrNull((p) => p.start.isAfter(now));
  }

  static Future<String?> getChannelIcon(String channelName) async {
    final epgid = await getEpgidByChannelName(channelName);
    if (epgid == null) return null;
    final channelId = await EpgDatabaseService.findChannelIdByDisplayName(epgid);
    if (channelId == null) return null;
    return EpgDatabaseService.getChannelIcon(channelId);
  }

  // ============================================================
  // 新增公共方法：获取/保存 EPG URL
  // ============================================================

  static Future<String?> getEpgUrl() async {
    final settings = await _loadSettings();
    return settings[_epgUrlKey] as String?;
  }

  static Future<void> saveEpgUrl(String url) async {
    if (url.isEmpty) return;
    final settings = await _loadSettings();
    settings[_epgUrlKey] = url;
    await _saveSettings(settings);
    LogService.write('EPG URL 已更新: $url');
  }

  // ============================================================
  // 缓存管理
  // ============================================================

  static Future<void> warmUpCache() async {
    try {
      final isDbEmpty = await EpgDatabaseService.isEmpty();
      if (isDbEmpty) {
        final dir = await getApplicationDocumentsDirectory();
        final file = File('${dir.path}/$_epgCacheFileName');
        if (await file.exists()) {
          final jsonString = await file.readAsString();
          final jsonData = jsonDecode(jsonString);
          final programs = (jsonData['programs'] as Map<String, dynamic>).map(
            (k, v) => MapEntry(k, (v as List).map((e) => EpgProgram.fromJson(e)).toList()),
          );
          final icons = (jsonData['icons'] as Map<String, dynamic>).cast<String, String>();
          await EpgDatabaseService.insertPrograms(programs, icons);
          LogService.write('EPG: 从 JSON 缓存预热数据库');
        }
      }

      await _loadEpgNameMap();

      LogService.write('EPG: 缓存预热完成');
    } catch (e) {
      LogService.write('EPG缓存预热失败: $e');
    }
  }

  // ---------- 设置持久化 ----------
  static Future<Map<String, dynamic>> _loadSettings() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/epg_settings.json');
      if (await file.exists()) {
        final content = await file.readAsString();
        final settings = jsonDecode(content) as Map<String, dynamic>;
        if (settings[_epgUrlKey] != null) return settings;
      }
    } catch (_) {}

    // 本地没有 EPG 设置时，从 configuration.json 读取默认配置
    try {
      final config = await ConfigService.getConfig();
      final inner = config['Configuration'] as Map<String, dynamic>?;
      final epgUrls = inner?['EPG_URLS'] as String?;
      if (epgUrls != null && epgUrls.isNotEmpty) {
        final parts = epgUrls.split('||');
        for (final part in parts) {
          final trimmed = part.trim();
          if (trimmed.isEmpty) continue;
          final idx = trimmed.lastIndexOf('\$');
          final url = idx > 0 ? trimmed.substring(0, idx).trim() : trimmed;
          if (url.isNotEmpty) {
            return {_epgUrlKey: url};
          }
        }
      }
    } catch (_) {}

    return {};
  }

  static Future<void> _saveSettings(Map<String, dynamic> settings) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/epg_settings.json');
    await file.writeAsString(jsonEncode(settings));
  }
}

// ---------- String 扩展 ----------
extension StringExt on String {
  int indexOfRegExp(RegExp regExp) {
    final match = regExp.firstMatch(this);
    return match?.start ?? -1;
  }
}
