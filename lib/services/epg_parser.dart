import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
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

// ============================================================
// EpgParser —— 酷9方案：精准匹配 + 东八区强制 + 秒级解析
// ============================================================

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
  // 加载 epg_data.json（修复：顶层是 Map {"epgs": [...]}）
  // ============================================================

  static Future<void> _loadEpgNameMap() async {
    if (_nameToEpgidMap != null) return;

    try {
      LogService.write('EPG: 开始加载 epg_data.json...');
      final jsonString = await rootBundle.loadString(_epgDataJsonAsset);

      // FIX: 顶层是 Map {"epgs": [...]}，不是 List
      final jsonData = jsonDecode(jsonString) as Map<String, dynamic>;
      final List<dynamic> data = jsonData['epgs'] as List<dynamic>? ?? [];

      _nameToEpgidMap = {};
      for (final item in data) {
        if (item is! Map) continue;
        final epgid = item['epgid'] as String?;
        final namesStr = item['name'] as String?;
        if (epgid == null || namesStr == null) continue;
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
  // XML 解析（避免主线程序列化大字符串，使用文件传递）
  // ============================================================

  static Future<void> _parseAndCache(String xmlString, String sourceUrl) async {
    final stopwatch = Stopwatch()..start();

    // 1. XML 写入临时文件
    final tempDir = await getTemporaryDirectory();
    final xmlFile = File('${tempDir.path}/epg_temp_${DateTime.now().millisecondsSinceEpoch}.xml');
    await xmlFile.writeAsString(xmlString, flush: true);
    LogService.write('EPG: XML已写入临时文件 ${xmlFile.path}，大小=${xmlString.length}');

    // 2. Isolate 解析 XML → 结果文件路径
    final resultPath = await compute(_parseXmlFile, xmlFile.path);
    await xmlFile.delete();
    LogService.write('EPG: Isolate解析完成，结果文件=$resultPath');

    // 3. FIX: 把大 JSON 反序列化也放到 Isolate，返回结构化数据
    final parsed = await compute(_deserializeEpgResult, resultPath);
    await File(resultPath).delete();

    final programMap = parsed.programs;
    final channelIcons = parsed.icons;
    final displayNameMap = parsed.displayNames;

    // 4. FIX: 减小 batch size，每批 yield，使用数据库 batch 插入
    LogService.write('EPG: 开始写入数据库，共 ${programMap.length} 频道');
    await EpgDatabaseService.clearAll();

    // 先批量插入频道信息（含 display-name）
    await EpgDatabaseService.batchUpdateDisplayNames(displayNameMap);
    await EpgDatabaseService.batchUpdateIcons(channelIcons);

    // 再分批插入节目，用 batch
    const batchSize = 500; // 减小批次
    final entries = programMap.entries.toList();
    for (var i = 0; i < entries.length; i += batchSize) {
      final batch = Map<String, List<EpgProgram>>.fromEntries(
        entries.skip(i).take(batchSize),
      );
      await EpgDatabaseService.insertProgramsBatch(batch);
      // FIX: 每批都 yield，保证播放流畅
      if (i + batchSize < entries.length) {
        await Future.delayed(const Duration(milliseconds: 16));
      }
    }

    _memoryCache = programMap;
    _iconCache = channelIcons;
    _cacheTime = DateTime.now();

    stopwatch.stop();
    LogService.write('EPG解析完成: ${programMap.length} 频道, ${parsed.count} 节目, 耗时 ${stopwatch.elapsedMilliseconds}ms');
  }

  // ============================================================
  // Isolate 解析函数
  // ============================================================

  /// 在 Isolate 中解析 XML 文件，结果写入临时 JSON 文件，返回文件路径
  static String _parseXmlFile(String xmlFilePath) {
    final xmlString = File(xmlFilePath).readAsStringSync();
    final document = XmlDocument.parse(xmlString);

    // 1. 解析 channel（FIX: 同时取 display-name）
    final channelIcons = <String, String>{};
    final displayNames = <String, String>{};

    final channels = document.findAllElements('channel');
    for (final channel in channels) {
      final id = channel.getAttribute('id');
      if (id == null) continue;

      final iconElem = channel.getElement('icon');
      if (iconElem != null) {
        final src = iconElem.getAttribute('src');
        if (src != null && src.isNotEmpty) channelIcons[id] = src;
      }

      // FIX: 解析 display-name，优先第一个
      final displayNameElem = channel.getElement('display-name');
      if (displayNameElem != null) {
        final dn = displayNameElem.value?.trim();
        if (dn != null && dn.isNotEmpty) displayNames[id] = dn;
      }
    }

    // 2. 解析 programme
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

      final title = prog.getElement('title')?.value ?? '';
      final desc = prog.getElement('desc')?.value ?? '';

      programJsonMap.putIfAbsent(channelId, () => []).add({
        'title': title,
        'description': desc,
        'start': start.toIso8601String(),
        'stop': stop.toIso8601String(),
      });
    }

    // 3. 排序
    for (final entry in programJsonMap.entries) {
      entry.value.sort((a, b) => DateTime.parse(a['start']!).compareTo(DateTime.parse(b['start']!)));
    }

    // 4. 写入结果文件（FIX: 带上 displayNames）
    final resultFile = File('${Directory.systemTemp.path}/epg_result_${DateTime.now().millisecondsSinceEpoch}.json');
    resultFile.writeAsStringSync(jsonEncode({
      'programs': programJsonMap,
      'icons': channelIcons,
      'displayNames': displayNames,
      'count': programmes.length,
    }));

    return resultFile.path;
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
  // Isolate 反序列化（避免主线程阻塞）
  // ============================================================

  /// FIX: 新增数据类，用于 Isolate 间传递解析结果
  class _EpgParsedResult {
    final Map<String, List<EpgProgram>> programs;
    final Map<String, String> icons;
    final Map<String, String> displayNames;
    final int count;
    _EpgParsedResult(this.programs, this.icons, this.displayNames, this.count);
  }

  /// FIX: 在 Isolate 中反序列化 JSON，避免主线程阻塞
  static _EpgParsedResult _deserializeEpgResult(String resultPath) {
    final resultFile = File(resultPath);
    final jsonData = jsonDecode(resultFile.readAsStringSync());

    final programJsonMap = (jsonData['programs'] as Map<String, dynamic>).map(
      (k, v) => MapEntry(k, (v as List).map((e) => e as Map<String, dynamic>).toList()),
    );
    final channelIcons = (jsonData['icons'] as Map<String, dynamic>).cast<String, String>();
    final displayNames = (jsonData['displayNames'] as Map<String, dynamic>?)?.cast<String, String>() ?? {};

    final programMap = programJsonMap.map((k, v) => MapEntry(
      k,
      v.map((e) => EpgProgram(
        title: e['title'] as String,
        description: e['description'] as String,
        start: DateTime.parse(e['start'] as String),
        stop: DateTime.parse(e['stop'] as String),
      )).toList(),
    ));

    return _EpgParsedResult(
      programMap,
      channelIcons,
      displayNames,
      jsonData['count'] as int? ?? 0,
    );
  }

  // ============================================================
  // 查询接口（三层精准匹配 + 模糊匹配兜底）
  // ============================================================

  static Future<List<EpgProgram>> getProgramsByChannelName(String channelName) async {
    if (channelName.isEmpty) return [];

    // 第一层：精准匹配（name -> epgid -> channel id）
    final epgid = await getEpgidByChannelName(channelName);
    if (epgid != null) {
      final channelId = await EpgDatabaseService.findChannelIdByDisplayName(epgid);
      if (channelId != null) {
        LogService.write('EPG: 精准匹配 $channelName -> $epgid -> $channelId');
        return await EpgDatabaseService.getProgramsByChannelId(channelId);
      }
    }

    // 第二层：模糊匹配（直接用频道名匹配 EPG 里的 display-name）
    final channelId = await EpgDatabaseService.findChannelIdByDisplayName(channelName);
    if (channelId != null) {
      LogService.write('EPG: 模糊匹配 $channelName -> $channelId');
      return await EpgDatabaseService.getProgramsByChannelId(channelId);
    }

    LogService.write('EPG: 未找到频道映射: $channelName');
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

  // ============================================================
  // getChannelIcon（FIX: 同一个 epgid 的台标复用）
  // ============================================================

  static Future<String?> getChannelIcon(String channelName) async {
    final epgid = await getEpgidByChannelName(channelName);
    if (epgid == null) return null;

    // FIX: 先尝试 channel_id 精确匹配（epgid 通常就是 XML 的 channel id）
    var icon = await EpgDatabaseService.getChannelIcon(epgid);
    if (icon != null) return icon;

    // fallback: 尝试 display_name 匹配
    final channelId = await EpgDatabaseService.findChannelIdByDisplayName(epgid);
    if (channelId == null) return null;
    return EpgDatabaseService.getChannelIcon(channelId);
  }

  // ============================================================
  // 新增方法（兼容旧调用 & LogoService）
  // ============================================================

  static Future<String?> getChannelIconUrl(String channelName) async {
    return getChannelIcon(channelName);
  }

  static Future<Map<String, String>> getNameToEpgId() async {
    await _loadEpgNameMap();
    return _nameToEpgidMap ?? {};
  }

  // ============================================================
  // 公共方法：获取/保存 EPG URL
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
