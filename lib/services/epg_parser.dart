import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:xml/xml.dart';
import 'package:collection/collection.dart';
import '../models/epg_program.dart';
import 'log_service.dart';
import 'epg_database_service.dart';
import 'config_service.dart';

class _EpgParseResult {
  final Map<String, List<EpgProgram>> programs;
  final Map<String, String> icons;
  final Map<String, String> displayNames;
  final int count;
  _EpgParseResult(this.programs, this.icons, this.displayNames, this.count);
}

class EpgParser {
  static const String _epgUrlKey = 'epg_url';
  static const String _lastEpgUpdateKey = 'last_epg_update';
  static const String _epgCacheFileName = 'epg_cache.json';
  static const String _epgDataJsonAsset = 'assets/epg_data.json';

  static Map<String, List<EpgProgram>>? _memoryCache;
  static Map<String, String>? _iconCache;
  static DateTime? _cacheTime;
  static Map<String, String>? _nameToEpgidMap;

  static DateTime get beijingNow {
    return DateTime.now().toUtc().add(const Duration(hours: 8));
  }

  static DateTime toBeijing(DateTime dt) {
    return dt.toUtc().add(const Duration(hours: 8));
  }

  static String formatBeijingTime(DateTime dt) {
    final bj = toBeijing(dt);
    return '${bj.hour.toString().padLeft(2, '0')}:${bj.minute.toString().padLeft(2, '0')}';
  }

  // ========== 主入口：应用启动时调用 ==========

  static Future<void> init() async {
    LogService.write('EPG: ========== init 开始 ==========');
    try {
      await _loadEpgNameMap();
      LogService.write('EPG: 名称映射 ${_nameToEpgidMap?.length ?? 0} 条');

      final url = await _resolveEpgUrl();
      if (url == null || url.isEmpty) {
        LogService.write('EPG: 无可用 URL，跳过');
        return;
      }
      LogService.write('EPG: URL=$url');

      final settings = await _loadSettings();
      final lastUpdate = settings[_lastEpgUpdateKey] as int?;
      if (lastUpdate != null) {
        final lastDate = DateTime.fromMillisecondsSinceEpoch(lastUpdate);
        final diff = DateTime.now().difference(lastDate);
        if (diff < const Duration(hours: 6)) {
          LogService.write('EPG: ${diff.inMinutes}分钟前已更新，跳过下载');
          await _loadCacheFromFile();
          return;
        }
      }

      LogService.write('EPG: 开始下载...');
      final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 60));
      LogService.write('EPG: 下载完成 HTTP=${response.statusCode} size=${response.bodyBytes.length}');

      if (response.statusCode != 200) {
        LogService.write('EPG: 下载失败 HTTP=${response.statusCode}');
        return;
      }

      final xmlString = utf8.decode(response.bodyBytes);
      await _parseAndSave(xmlString);

      settings[_lastEpgUpdateKey] = DateTime.now().millisecondsSinceEpoch;
      await _saveSettings(settings);

      LogService.write('EPG: ========== init 完成 ==========');
    } catch (e, stack) {
      LogService.writeCrashLog('EPG init 失败: $e', stack);
    }
  }

  static Future<void> forceRefresh() async {
    LogService.write('EPG: 强制刷新开始');
    final settings = await _loadSettings();
    settings.remove(_lastEpgUpdateKey);
    await _saveSettings(settings);
    await init();
  }

  // ========== 解析并保存 ==========

  static Future<void> _parseAndSave(String xmlString) async {
    final stopwatch = Stopwatch()..start();

    final tempDir = await getTemporaryDirectory();
    final xmlFile = File('${tempDir.path}/epg_${DateTime.now().millisecondsSinceEpoch}.xml');
    await xmlFile.writeAsString(xmlString, flush: true);
    LogService.write('EPG: XML临时文件已写入 ${xmlFile.path}');

    final resultPath = await compute(_parseXmlFile, xmlFile.path);
    await xmlFile.delete();
    LogService.write('EPG: Isolate解析完成');

    final result = await compute(_deserializeResult, resultPath);
    await File(resultPath).delete();

    await EpgDatabaseService.clearAll();
    LogService.write('EPG: 数据库已清空');

    await EpgDatabaseService.batchUpdateDisplayNames(result.displayNames);
    await EpgDatabaseService.batchUpdateIcons(result.icons);
    LogService.write('EPG: 频道信息写入完成 ${result.displayNames.length} display, ${result.icons.length} icons');

    const batchSize = 500;
    final entries = result.programs.entries.toList();
    for (var i = 0; i < entries.length; i += batchSize) {
      final batch = Map<String, List<EpgProgram>>.fromEntries(
        entries.skip(i).take(batchSize),
      );
      await EpgDatabaseService.insertProgramsBatch(batch);
      if (i + batchSize < entries.length) {
        await Future.delayed(const Duration(milliseconds: 16));
      }
    }
    LogService.write('EPG: 节目写入完成 ${result.count} 条');

    await _saveCacheFile(result.programs, result.icons);
    _memoryCache = result.programs;
    _iconCache = result.icons;
    _cacheTime = DateTime.now();

    stopwatch.stop();
    LogService.write('EPG: 解析完成 ${result.programs.length}频道 ${result.count}节目 ${stopwatch.elapsedMilliseconds}ms');
  }

  // ========== Isolate 函数 ==========

  static String _parseXmlFile(String xmlFilePath) {
    final xmlString = File(xmlFilePath).readAsStringSync();
    final document = XmlDocument.parse(xmlString);

    final channelIcons = <String, String>{};
    final displayNames = <String, String>{};

    for (final channel in document.findAllElements('channel')) {
      final id = channel.getAttribute('id');
      if (id == null) continue;

      final iconElem = channel.getElement('icon');
      if (iconElem != null) {
        final src = iconElem.getAttribute('src');
        if (src != null && src.isNotEmpty) channelIcons[id] = src;
      }

      final dnElem = channel.getElement('display-name');
      if (dnElem != null) {
        final dn = dnElem.value?.trim();
        if (dn != null && dn.isNotEmpty) displayNames[id] = dn;
      }
    }

    final programJsonMap = <String, List<Map<String, dynamic>>>{};
    final programmes = document.findAllElements('programme');

    for (final prog in programmes) {
      final channelId = prog.getAttribute('channel');
      final startStr = prog.getAttribute('start');
      final stopStr = prog.getAttribute('stop');
      if (channelId == null || startStr == null || stopStr == null) continue;

      final start = _parseXmltvTime(startStr);
      final stop = _parseXmltvTime(stopStr);
      if (start == null || stop == null) continue;

      programJsonMap.putIfAbsent(channelId, () => []).add({
        'title': prog.getElement('title')?.value ?? '',
        'description': prog.getElement('desc')?.value ?? '',
        'start': start.toIso8601String(),
        'stop': stop.toIso8601String(),
      });
    }

    for (final entry in programJsonMap.entries) {
      entry.value.sort((a, b) => DateTime.parse(a['start']!).compareTo(DateTime.parse(b['start']!)));
    }

    final resultFile = File('${Directory.systemTemp.path}/epg_result_${DateTime.now().millisecondsSinceEpoch}.json');
    resultFile.writeAsStringSync(jsonEncode({
      'programs': programJsonMap,
      'icons': channelIcons,
      'displayNames': displayNames,
      'count': programmes.length,
    }));

    return resultFile.path;
  }

  static _EpgParseResult _deserializeResult(String resultPath) {
    final jsonData = jsonDecode(File(resultPath).readAsStringSync());

    final programJsonMap = (jsonData['programs'] as Map<String, dynamic>).map(
      (k, v) => MapEntry(k, (v as List).map((e) => e as Map<String, dynamic>).toList()),
    );
    final icons = (jsonData['icons'] as Map<String, dynamic>).cast<String, String>();
    final displayNames = (jsonData['displayNames'] as Map<String, dynamic>?)?.cast<String, String>() ?? {};

    final programs = programJsonMap.map((k, v) => MapEntry(
      k,
      v.map((e) => EpgProgram(
        title: e['title'] as String,
        description: e['description'] as String,
        start: DateTime.parse(e['start'] as String),
        stop: DateTime.parse(e['stop'] as String),
      )).toList(),
    ));

    return _EpgParseResult(programs, icons, displayNames, jsonData['count'] as int? ?? 0);
  }

  static DateTime? _parseXmltvTime(String t) {
    try {
      String s = t.trim();
      final tzIdx = s.indexOfRegExp(RegExp(r'[+-]\d{4}'));
      if (tzIdx > 0) s = s.substring(0, tzIdx).trim();
      if (s.length >= 14) {
        return DateTime.utc(
          int.parse(s.substring(0, 4)),
          int.parse(s.substring(4, 6)),
          int.parse(s.substring(6, 8)),
          int.parse(s.substring(8, 10)),
          int.parse(s.substring(10, 12)),
          int.parse(s.substring(12, 14)),
        );
      }
    } catch (_) {}
    return null;
  }

  // ========== 查询接口 ==========

  static Future<List<EpgProgram>> getProgramsByChannelName(String channelName) async {
    if (channelName.isEmpty) return [];
    final epgid = await getEpgidByChannelName(channelName);
    if (epgid != null) {
      final channelId = await EpgDatabaseService.findChannelIdByDisplayName(epgid);
      if (channelId != null) {
        return await EpgDatabaseService.getProgramsByChannelId(channelId);
      }
      return await EpgDatabaseService.getProgramsByChannelId(epgid);
    }
    return [];
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
    var icon = await EpgDatabaseService.getChannelIcon(epgid);
    if (icon != null) return icon;
    final channelId = await EpgDatabaseService.findChannelIdByDisplayName(epgid);
    if (channelId != null) return await EpgDatabaseService.getChannelIcon(channelId);
    return null;
  }

  static Future<String?> getChannelIconUrl(String channelName) async {
    return getChannelIcon(channelName);
  }

  static Future<Map<String, String>> getNameToEpgId() async {
    await _loadEpgNameMap();
    return _nameToEpgidMap ?? {};
  }

  static Future<String?> getEpgidByChannelName(String channelName) async {
    await _loadEpgNameMap();
    return _nameToEpgidMap?[channelName];
  }

  // ========== 名称映射加载 ==========

  static Future<void> _loadEpgNameMap() async {
    if (_nameToEpgidMap != null) return;
    try {
      final jsonString = await rootBundle.loadString(_epgDataJsonAsset);
      final jsonData = jsonDecode(jsonString) as Map<String, dynamic>;
      final List<dynamic> data = jsonData['epgs'] as List<dynamic>? ?? [];
      _nameToEpgidMap = {};
      for (final item in data) {
        if (item is! Map) continue;
        final epgid = item['epgid'] as String?;
        final namesStr = item['name'] as String?;
        if (epgid == null || namesStr == null) continue;
        for (final name in namesStr.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty)) {
          _nameToEpgidMap![name] = epgid;
        }
      }
      LogService.write('EPG: 名称映射 ${_nameToEpgidMap!.length} 条');
    } catch (e, stack) {
      LogService.writeCrashLog('EPG名称映射加载失败: $e', stack);
      _nameToEpgidMap = {};
    }
  }

  // ========== URL 解析 ==========

  static Future<String?> _resolveEpgUrl() async {
    final settings = await _loadSettings();
    var url = settings[_epgUrlKey] as String?;
    if (url != null && url.isNotEmpty) return url;

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
          final u = idx > 0 ? trimmed.substring(0, idx).trim() : trimmed;
          if (u.isNotEmpty) {
            await saveEpgUrl(u);
            return u;
          }
        }
      }
    } catch (e) {
      LogService.write('EPG: 从配置读取URL失败: $e');
    }
    return null;
  }

  // ========== 缓存文件 ==========

  static Future<void> _saveCacheFile(
    Map<String, List<EpgProgram>> programs,
    Map<String, String> icons,
  ) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_epgCacheFileName');
      await file.writeAsString(jsonEncode({
        'programs': programs.map((k, v) => MapEntry(k, v.map((e) => e.toJson()).toList())),
        'icons': icons,
        'savedAt': DateTime.now().millisecondsSinceEpoch,
      }));
    } catch (e) {
      LogService.write('EPG: 缓存文件保存失败: $e');
    }
  }

  static Future<void> _loadCacheFromFile() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_epgCacheFileName');
      if (!await file.exists()) return;
      final jsonData = jsonDecode(await file.readAsString());
      _memoryCache = (jsonData['programs'] as Map<String, dynamic>).map(
        (k, v) => MapEntry(k, (v as List).map((e) => EpgProgram.fromJson(e)).toList()),
      );
      _iconCache = (jsonData['icons'] as Map<String, dynamic>).cast<String, String>();
      _cacheTime = DateTime.now();
      LogService.write('EPG: 从缓存文件恢复内存');
    } catch (e) {
      LogService.write('EPG: 缓存文件恢复失败: $e');
    }
  }

  // ========== 设置持久化 ==========

  static Future<Map<String, dynamic>> _loadSettings() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/epg_settings.json');
      if (await file.exists()) {
        final content = await file.readAsString();
        return jsonDecode(content) as Map<String, dynamic>;
      }
    } catch (_) {}
    return {};
  }

  static Future<void> _saveSettings(Map<String, dynamic> settings) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/epg_settings.json');
    await file.writeAsString(jsonEncode(settings));
  }

  static Future<void> saveEpgUrl(String url) async {
    if (url.isEmpty) return;
    final settings = await _loadSettings();
    settings[_epgUrlKey] = url;
    await _saveSettings(settings);
  }

  static Future<String?> getEpgUrl() async {
    final settings = await _loadSettings();
    return settings[_epgUrlKey] as String?;
  }

  static Future<bool> checkForUpdate() async {
    await init();
    return true;
  }

  static Future<void> warmUpCache() async {
    await _loadEpgNameMap();
  }
}

extension StringExt on String {
  int indexOfRegExp(RegExp regExp) {
    final match = regExp.firstMatch(this);
    return match?.start ?? -1;
  }
}
