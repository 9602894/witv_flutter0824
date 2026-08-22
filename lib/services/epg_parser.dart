import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
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

/// EPG 服务 - 零阻塞终极版 v3
///
/// 核心设计：
/// 1. 内存优先：所有查询先走 _memoryCache，O(1) 命中，零延迟
/// 2. 启动秒开：init() 先恢复 JSON 缓存到内存，再后台检查更新
/// 3. 三阶 Isolate：解析 XML → JSON String → 对象构建，主线程只做赋值
/// 4. 播放器零感知：EPG 任何操作都不影响视频解码和渲染
/// 5. ValueNotifier 通知：UI 层用 addListener/removeListener，无需 StreamSubscription
class EpgParser {
  static const String _epgUrlKey = 'epg_url';
  static const String _lastEpgUpdateKey = 'last_epg_update';
  static const String _epgCacheFileName = 'epg_cache.json';
  static const String _epgDataJsonAsset = 'assets/epg_data.json';

  // ========== 内存缓存（主查询链路，唯一真相源）==========
  static Map<String, List<EpgProgram>>? _memoryCache;
  static Map<String, String>? _iconCache;
  static Map<String, String>? _nameToEpgidMap;
  static DateTime? _cacheTime;

  // ========== 后台任务锁 ==========
  static bool _isBackgroundSaving = false;
  static bool _isDownloading = false;

  // ========== UI 更新通知（ValueNotifier，无需 import dart:async）==========
  static final ValueNotifier<int> epgUpdateCounter = ValueNotifier(0);

  static void _notifyUpdate() {
    epgUpdateCounter.value++;
  }

  // ========== 时区工具 ==========
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

  // ========== 主入口：启动时调用，必须零阻塞 ==========
  static Future<void> init() async {
    LogService.write('EPG: ========== init 开始 ==========');
    try {
      await _loadEpgNameMap();
      LogService.write('EPG: 名称映射 ${_nameToEpgidMap?.length ?? 0} 条');

      // 【关键】先恢复内存缓存，UI 立刻有 EPG 数据可用
      await _loadCacheFromFile();
      final memCount = _memoryCache?.length ?? 0;
      LogService.write('EPG: 内存缓存恢复 $memCount 频道，UI 可立即查询');

      // 【关键】后台检查更新，不 await，不阻塞播放
      _checkAndUpdateInBackground();

      LogService.write('EPG: ========== init 完成（内存就绪，后台更新中） ==========');
    } catch (e, stack) {
      LogService.writeCrashLog('EPG init 失败: $e', stack);
    }
  }

  // ========== 后台检查更新（完全异步，与播放无关）==========
  static void _checkAndUpdateInBackground() async {
    if (_isDownloading) return;
    _isDownloading = true;

    try {
      final url = await _resolveEpgUrl();
      if (url == null || url.isEmpty) {
        LogService.write('EPG: 无可用 URL，跳过下载');
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
          return;
        }
      }

      LogService.write('EPG: 开始后台下载...');
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

      LogService.write('EPG: ========== 后台更新完成 ==========');
    } catch (e, stack) {
      LogService.writeCrashLog('EPG 后台更新失败: $e', stack);
    } finally {
      _isDownloading = false;
    }
  }

  static Future<void> forceRefresh() async {
    LogService.write('EPG: 强制刷新开始');
    final settings = await _loadSettings();
    settings.remove(_lastEpgUpdateKey);
    await _saveSettings(settings);
    _checkAndUpdateInBackground();
  }

  // ========== 解析并保存（三阶 Isolate，主线程零阻塞）==========
  static Future<void> _parseAndSave(String xmlString) async {
    final stopwatch = Stopwatch()..start();

    // 【第一阶段】Isolate 里解析 XML + 序列化成 JSON String
    // 避免主线程反序列化大量自定义对象
    final jsonString = await Isolate.run(() => _parseXmlToJsonString(xmlString));
    LogService.write('EPG: Isolate XML解析+JSON序列化完成');

    // 【第二阶段】Isolate 里 jsonDecode + 构建 EpgProgram 对象
    // 主线程只做最终赋值，零阻塞
    final result = await Isolate.run(() => _buildFromJsonString(jsonString));
    LogService.write('EPG: Isolate 对象构建完成 ${result.programs.length}频道 ${result.count}节目');

    // 【第三阶段】主线程只做内存赋值（O(1)）
    _memoryCache = result.programs;
    _iconCache = result.icons;
    _cacheTime = DateTime.now();
    _notifyUpdate();
    LogService.write('EPG: 内存缓存已热更新');

    // 后台持久化（不阻塞）
    _saveCacheFile(result.programs, result.icons).catchError((e) {
      LogService.write('EPG: 缓存文件保存失败: $e');
    });
    _saveToDatabaseInBackground(result).catchError((e) {
      LogService.write('EPG: 数据库后台写入失败: $e');
    });

    stopwatch.stop();
    LogService.write('EPG: 总耗时 ${stopwatch.elapsedMilliseconds}ms（播放器无感知）');
  }

  // ========== Isolate 函数 1：解析 XML → JSON String ==========
  @pragma('vm:entry-point')
  static String _parseXmlToJsonString(String xmlString) {
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

    final programMap = <String, List<Map<String, dynamic>>>{};
    final programmes = document.findAllElements('programme');
    var count = 0;

    for (final prog in programmes) {
      final channelId = prog.getAttribute('channel');
      final startStr = prog.getAttribute('start');
      final stopStr = prog.getAttribute('stop');
      if (channelId == null || startStr == null || stopStr == null) continue;

      final start = _parseXmltvTime(startStr);
      final stop = _parseXmltvTime(stopStr);
      if (start == null || stop == null) continue;

      programMap.putIfAbsent(channelId, () => []).add({
        't': prog.getElement('title')?.value ?? '',
        'd': prog.getElement('desc')?.value ?? '',
        's': start.millisecondsSinceEpoch,
        'e': stop.millisecondsSinceEpoch,
      });
      count++;
    }

    // 排序
    for (final list in programMap.values) {
      list.sort((a, b) => (a['s'] as int).compareTo(b['s'] as int));
    }

    return jsonEncode({
      'programs': programMap,
      'icons': channelIcons,
      'displayNames': displayNames,
      'count': count,
    });
  }

  // ========== Isolate 函数 2：JSON String → EpgProgram 对象 ==========
  @pragma('vm:entry-point')
  static _EpgParseResult _buildFromJsonString(String jsonString) {
    final decoded = jsonDecode(jsonString) as Map<String, dynamic>;

    final rawPrograms = decoded['programs'] as Map<String, dynamic>;
    final programs = <String, List<EpgProgram>>{};
    var count = 0;

    for (final entry in rawPrograms.entries) {
      final list = (entry.value as List).map((m) {
        final map = m as Map<String, dynamic>;
        return EpgProgram(
          title: map['t'] as String? ?? '',
          description: map['d'] as String? ?? '',
          start: DateTime.fromMillisecondsSinceEpoch(map['s'] as int),
          stop: DateTime.fromMillisecondsSinceEpoch(map['e'] as int),
        );
      }).toList();
      programs[entry.key] = list;
      count += list.length;
    }

    final icons = (decoded['icons'] as Map<String, dynamic>).cast<String, String>();
    final displayNames = (decoded['displayNames'] as Map<String, dynamic>).cast<String, String>();

    return _EpgParseResult(programs, icons, displayNames, count);
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

  // ========== 查询接口（内存优先，O(1)）==========

  static Future<List<EpgProgram>> getProgramsByChannelName(String channelName) async {
    if (channelName.isEmpty) return [];

    final epgid = await getEpgidByChannelName(channelName);
    if (epgid == null) return [];

    // 1. 优先内存缓存（主链路，零延迟，不阻塞）
    final memCache = _memoryCache;
    if (memCache != null && memCache.containsKey(epgid)) {
      return memCache[epgid]!;
    }

    // 2. 内存 miss，查数据库兜底
    final channelId = await EpgDatabaseService.findChannelIdByDisplayName(epgid);
    if (channelId != null) {
      return await EpgDatabaseService.getProgramsByChannelId(channelId);
    }
    return await EpgDatabaseService.getProgramsByChannelId(epgid);
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

    final memIcons = _iconCache;
    if (memIcons != null && memIcons.containsKey(epgid)) {
      return memIcons[epgid];
    }

    var icon = await EpgDatabaseService.getChannelIcon(epgid);
    if (icon != null) return icon;

    final channelId = await EpgDatabaseService.findChannelIdByDisplayName(epgid);
    if (channelId != null) return await EpgDatabaseService.getChannelIcon(channelId);
    return null;
  }

  static Future<String?> getChannelIconUrl(String channelName) {
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

  // ========== JSON 缓存文件 ==========
  static Future<void> _saveCacheFile(
    Map<String, List<EpgProgram>> programs,
    Map<String, String> icons,
  ) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_epgCacheFileName');

      final jsonString = await Isolate.run(() => jsonEncode({
        'programs': programs.map((k, v) => MapEntry(k, v.map((e) => e.toJson()).toList())),
        'icons': icons,
        'savedAt': DateTime.now().millisecondsSinceEpoch,
      }));

      await file.writeAsString(jsonString);
      LogService.write('EPG: JSON缓存文件已保存');
    } catch (e) {
      LogService.write('EPG: 缓存文件保存失败: $e');
    }
  }

  static Future<void> _loadCacheFromFile() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_epgCacheFileName');
      if (!await file.exists()) return;

      final content = await file.readAsString();
      final result = await Isolate.run(() {
        final jsonData = jsonDecode(content) as Map<String, dynamic>;
        final rawPrograms = jsonData['programs'] as Map<String, dynamic>;
        final programs = <String, List<EpgProgram>>{};
        for (final entry in rawPrograms.entries) {
          programs[entry.key] = (entry.value as List).map((e) => EpgProgram.fromJson(e)).toList();
        }
        final icons = (jsonData['icons'] as Map<String, dynamic>).cast<String, String>();
        return _EpgParseResult(programs, icons, {}, 0);
      });

      _memoryCache = result.programs;
      _iconCache = result.icons;
      _cacheTime = DateTime.now();
      LogService.write('EPG: 从缓存文件恢复内存 ${_memoryCache?.length ?? 0} 频道');
    } catch (e) {
      LogService.write('EPG: 缓存文件恢复失败: $e');
      _memoryCache = null;
      _iconCache = null;
    }
  }

  // ========== 后台写入 SQLite（仅作持久化备份）==========
  static Future<void> _saveToDatabaseInBackground(_EpgParseResult result) async {
    if (_isBackgroundSaving) {
      LogService.write('EPG: 已有后台写入任务，跳过');
      return;
    }
    _isBackgroundSaving = true;

    try {
      final dbStopwatch = Stopwatch()..start();

      await EpgDatabaseService.clearAll();
      await EpgDatabaseService.batchUpdateChannels(result.displayNames, result.icons);

      const batchSize = 5000;
      final entries = result.programs.entries.toList();
      for (var i = 0; i < entries.length; i += batchSize) {
        final batch = Map<String, List<EpgProgram>>.fromEntries(
          entries.skip(i).take(batchSize),
        );
        await EpgDatabaseService.insertProgramsBatch(batch);
        await Future.delayed(const Duration(milliseconds: 100));
      }

      dbStopwatch.stop();
      LogService.write('EPG: 数据库后台写入完成，耗时 ${dbStopwatch.elapsedMilliseconds}ms');
    } catch (e, stack) {
      LogService.writeCrashLog('EPG数据库后台写入失败: $e', stack);
    } finally {
      _isBackgroundSaving = false;
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
    _checkAndUpdateInBackground();
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
