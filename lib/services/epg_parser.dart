import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:collection/collection.dart';
import '../models/epg_program.dart';
import 'log_service.dart';
import 'config_service.dart';

/// EPG 服务 - 保留 XML 文件，重启后直接提取到内存
///
/// 1. epg_data.json: name → epgid（epgid = XML <display-name>）
/// 2. 下载 XML → 保留文件 → Isolate 提取 needed channels → 内存
/// 3. 重启后：XML 文件还在 → 直接提取到内存（无需重新下载）
/// 4. 所有时间强制东八区 UTC+8
class EpgParser {
  static const String _epgUrlKey = 'epg_url';
  static const String _lastEpgUpdateKey = 'last_epg_update';
  static const String _epgDataJsonAsset = 'assets/epg_data.json';
  static const String _epgXmlFile = 'epg_data.xml';  // 保留的 XML 文件

  static Map<String, String>? _nameToEpgidMap;
  static Map<String, List<EpgProgram>>? _memoryCache;
  static Map<String, String>? _iconCache;

  static bool _isWorking = false;
  static final ValueNotifier<int> epgUpdateCounter = ValueNotifier(0);

  /// 东八区当前时间（强制 UTC+8，不受设备时区/代理影响）
  static DateTime get beijingNow {
    return DateTime.now().toUtc().add(const Duration(hours: 8));
  }

  static DateTime toBeijing(DateTime dt) {
    return dt.toUtc().add(const Duration(hours: 8));
  }

  /// 格式化为 HH:MM（东八区）
  static String formatBeijingTime(DateTime dt) {
    final bj = toBeijing(dt);
    return '${bj.hour.toString().padLeft(2, '0')}:${bj.minute.toString().padLeft(2, '0')}';
  }

  /// 格式化为 MM-dd HH:mm（东八区）
  static String formatBeijingDateTime(DateTime dt) {
    final bj = toBeijing(dt);
    return '${bj.month.toString().padLeft(2, '0')}-${bj.day.toString().padLeft(2, '0')} '
        '${bj.hour.toString().padLeft(2, '0')}:${bj.minute.toString().padLeft(2, '0')}';
  }

  /// 获取东八区日期（用于按日期分组）
  static DateTime beijingDate(DateTime dt) {
    final bj = toBeijing(dt);
    return DateTime(bj.year, bj.month, bj.day);
  }

  // ========== 主入口 ==========
  static Future<void> init() async {
    LogService.write('EPG: init 开始');
    try {
      // 1. 加载名称映射
      await _loadEpgNameMap();
      LogService.write('EPG: 名称映射 ${_nameToEpgidMap?.length ?? 0} 条');

      // 2. 【关键】检查本地 XML 文件是否存在
      final dir = await getApplicationDocumentsDirectory();
      final xmlFile = File('${dir.path}/$_epgXmlFile');

      if (await xmlFile.exists()) {
        // XML 文件存在，直接提取到内存（重启后走这里）
        LogService.write('EPG: 发现本地 XML，直接提取');
        await _extractFromLocalFile();
      } else {
        // 没有本地文件，后台下载
        LogService.write('EPG: 无本地 XML，后台下载');
        _checkAndUpdateInBackground();
      }

      LogService.write('EPG: init 完成');
    } catch (e, stack) {
      LogService.writeCrashLog('EPG init 失败: $e', stack);
    }
  }

  // ========== 从本地 XML 文件提取（重启后调用）==========
  static Future<void> _extractFromLocalFile() async {
    if (_isWorking) return;
    _isWorking = true;

    try {
      final dir = await getApplicationDocumentsDirectory();
      final xmlPath = '${dir.path}/$_epgXmlFile';
      final needed = _nameToEpgidMap?.values.toSet().toList() ?? [];

      LogService.write('EPG: 开始从本地 XML 提取 ${needed.length} 个频道');
      final stopwatch = Stopwatch()..start();

      final result = await Isolate.run(() => _extractNeededPrograms(xmlPath, needed));
      stopwatch.stop();

      LogService.write(
        'EPG: 提取完成 ${result.programs.length}频道 ${result.count}节目 '
        '耗时 ${stopwatch.elapsedMilliseconds}ms',
      );

      _memoryCache = result.programs;
      _iconCache = result.icons;
      epgUpdateCounter.value++;
      LogService.write('EPG: 内存已更新（从本地文件）');
    } catch (e, stack) {
      LogService.writeCrashLog('EPG 本地提取失败: $e', stack);
      // 本地文件损坏，删除后重新下载
      try {
        final dir = await getApplicationDocumentsDirectory();
        await File('${dir.path}/$_epgXmlFile').delete();
      } catch (_) {}
      _checkAndUpdateInBackground();
    } finally {
      _isWorking = false;
    }
  }

  // ========== 后台下载 + 提取 ==========
  static void _checkAndUpdateInBackground() async {
    if (_isWorking) return;
    _isWorking = true;

    try {
      final url = await _resolveEpgUrl();
      if (url == null || url.isEmpty) {
        LogService.write('EPG: 无 URL');
        return;
      }

      final settings = await _loadSettings();
      final lastUpdate = settings[_lastEpgUpdateKey] as int?;
      if (lastUpdate != null) {
        final diff = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(lastUpdate));
        if (diff < const Duration(hours: 6)) {
          LogService.write('EPG: ${diff.inMinutes}分钟前已更新，跳过下载');
          // 即使跳过下载，如果内存为空也要重新提取（文件还在）
          if (_memoryCache == null || _memoryCache!.isEmpty) {
            await _extractFromLocalFile();
          }
          return;
        }
      }

      // 下载到文件（保留，不删除）
      final dir = await getApplicationDocumentsDirectory();
      final xmlPath = '${dir.path}/$_epgXmlFile';

      LogService.write('EPG: 开始下载...');
      final request = await HttpClient().getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != 200) {
        LogService.write('EPG: 下载失败 HTTP=${response.statusCode}');
        return;
      }

      final file = File(xmlPath);
      await response.pipe(file.openWrite());
      final size = await file.length();
      LogService.write('EPG: 下载完成 ${(size / 1024 / 1024).toStringAsFixed(1)}MB');

      // 提取 needed channels
      final needed = _nameToEpgidMap?.values.toSet().toList() ?? [];
      LogService.write('EPG: 需要提取 ${needed.length} 个频道');

      final stopwatch = Stopwatch()..start();
      final result = await Isolate.run(() => _extractNeededPrograms(xmlPath, needed));
      stopwatch.stop();

      LogService.write(
        'EPG: 提取完成 ${result.programs.length}频道 ${result.count}节目 '
        '耗时 ${stopwatch.elapsedMilliseconds}ms',
      );

      _memoryCache = result.programs;
      _iconCache = result.icons;
      epgUpdateCounter.value++;
      LogService.write('EPG: 内存已更新');

      // 更新设置
      settings[_lastEpgUpdateKey] = DateTime.now().millisecondsSinceEpoch;
      await _saveSettings(settings);

      LogService.write('EPG: 后台完成');
    } catch (e, stack) {
      LogService.writeCrashLog('EPG 后台失败: $e', stack);
    } finally {
      _isWorking = false;
    }
  }

  static Future<void> forceRefresh() async {
    LogService.write('EPG: 强制刷新');
    final settings = await _loadSettings();
    settings.remove(_lastEpgUpdateKey);
    await _saveSettings(settings);
    _checkAndUpdateInBackground();
  }

  // ========== Isolate：提取 needed channels ==========
  @pragma('vm:entry-point')
  static _ExtractResult _extractNeededPrograms(String filePath, List<String> neededDisplayNames) {
    final needed = Set<String>.from(neededDisplayNames);

    final displayNameToId = <String, String>{};
    final icons = <String, String>{};

    final xml = File(filePath).readAsStringSync();
    final channelBlocks = xml.split('</channel>');

    for (final block in channelBlocks) {
      final chIdx = block.lastIndexOf('<channel');
      if (chIdx == -1) continue;

      final tagEnd = block.indexOf('>', chIdx);
      if (tagEnd == -1) continue;

      final tag = block.substring(chIdx, tagEnd + 1);
      final idIdx = tag.indexOf('id="');
      if (idIdx == -1) continue;
      final idEnd = tag.indexOf('"', idIdx + 4);
      final channelId = tag.substring(idIdx + 4, idEnd);

      final dnOpen = block.indexOf('<display-name', tagEnd);
      if (dnOpen == -1) continue;
      final dnTagEnd = block.indexOf('>', dnOpen);
      final dnClose = block.indexOf('</display-name>', dnTagEnd);
      if (dnClose == -1) continue;
      final displayName = block.substring(dnTagEnd + 1, dnClose).trim();

      if (!needed.contains(displayName)) continue;

      displayNameToId[displayName] = channelId;

      final iconIdx = block.indexOf('src="', tagEnd);
      if (iconIdx != -1) {
        final iconEnd = block.indexOf('"', iconIdx + 5);
        icons[displayName] = block.substring(iconIdx + 5, iconEnd);
      }
    }

    final neededIds = Set<String>.from(displayNameToId.values);
    final programMap = <String, List<EpgProgram>>{};
    var count = 0;

    final blocks = xml.split('</programme>');
    for (final block in blocks) {
      final progIdx = block.lastIndexOf('<programme');
      if (progIdx == -1) continue;

      final tagEnd = block.indexOf('>', progIdx);
      if (tagEnd == -1) continue;

      final tag = block.substring(progIdx, tagEnd + 1);
      final chIdx = tag.indexOf('channel="');
      if (chIdx == -1) continue;
      final chEnd = tag.indexOf('"', chIdx + 9);
      final progChannelId = tag.substring(chIdx + 9, chEnd);

      if (!neededIds.contains(progChannelId)) continue;

      final sIdx = tag.indexOf('start="');
      final eIdx = tag.indexOf('stop="');
      if (sIdx == -1 || eIdx == -1) continue;
      final sEnd = tag.indexOf('"', sIdx + 7);
      final eEnd = tag.indexOf('"', eIdx + 6);

      final start = _parseXmltvTime(tag.substring(sIdx + 7, sEnd));
      final stop = _parseXmltvTime(tag.substring(eIdx + 6, eEnd));
      if (start == null || stop == null) continue;

      final content = block.substring(tagEnd + 1);
      final title = _extractTag(content, 'title');
      final desc = _extractTag(content, 'desc');

      String? displayName;
      for (final entry in displayNameToId.entries) {
        if (entry.value == progChannelId) {
          displayName = entry.key;
          break;
        }
      }
      if (displayName == null) continue;

      programMap.putIfAbsent(displayName, () => []).add(EpgProgram(
        title: title,
        description: desc,
        start: start,
        stop: stop,
      ));
      count++;
    }

    for (final list in programMap.values) {
      list.sort((a, b) => a.start.compareTo(b.start));
    }

    return _ExtractResult(programMap, icons, count);
  }

  static DateTime? _parseXmltvTime(String t) {
    try {
      String s = t.trim();
      final tzMatch = RegExp(r'[+-]\d{4}').firstMatch(s);
      if (tzMatch != null) s = s.substring(0, tzMatch.start).trim();
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

  static String _extractTag(String content, String tagName) {
    final open = '<$tagName';
    final close = '</$tagName>';
    final start = content.indexOf(open);
    if (start == -1) return '';
    final tagEnd = content.indexOf('>', start);
    if (tagEnd == -1) return '';
    final end = content.indexOf(close, tagEnd);
    if (end == -1) return '';
    return content.substring(tagEnd + 1, end).trim();
  }

  // ========== 查询接口 ==========

  static Future<List<EpgProgram>> getProgramsByChannelName(String channelName) async {
    if (channelName.isEmpty) return [];
    final epgid = _nameToEpgidMap?[channelName];
    if (epgid == null) return [];
    return _memoryCache?[epgid] ?? [];
  }

  /// 同步查询（供频道列表 build 方法使用，不阻塞 UI）
  static List<EpgProgram> getProgramsSync(String channelName) {
    if (channelName.isEmpty) return [];
    final epgid = _nameToEpgidMap?[channelName];
    if (epgid == null) return [];
    return _memoryCache?[epgid] ?? [];
  }

  /// 同步获取当前节目（东八区时间）
  static EpgProgram? getCurrentProgramSync(String channelName) {
    final programs = getProgramsSync(channelName);
    if (programs.isEmpty) return null;
    final now = beijingNow;
    return programs.firstWhereOrNull((p) => p.start.isBefore(now) && p.stop.isAfter(now));
  }

  /// 同步获取下一节目（东八区时间）
  static EpgProgram? getNextProgramSync(String channelName) {
    final programs = getProgramsSync(channelName);
    if (programs.isEmpty) return null;
    final now = beijingNow;
    return programs.firstWhereOrNull((p) => p.start.isAfter(now));
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
    final epgid = _nameToEpgidMap?[channelName];
    if (epgid == null) return null;
    return _iconCache?[epgid];
  }

  static String? getChannelIconSync(String channelName) {
    final epgid = _nameToEpgidMap?[channelName];
    if (epgid == null) return null;
    return _iconCache?[epgid];
  }

  static Future<String?> getChannelIconUrl(String channelName) {
    return getChannelIcon(channelName);
  }

  static Future<Map<String, String>> getNameToEpgId() async {
    return _nameToEpgidMap ?? {};
  }

  static Future<String?> getEpgidByChannelName(String channelName) async {
    return _nameToEpgidMap?[channelName];
  }

  static String? getEpgidSync(String channelName) {
    return _nameToEpgidMap?[channelName];
  }

  // ========== 加载 epg_data.json ==========
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
      LogService.writeCrashLog('EPG epg_data.json 加载失败: $e', stack);
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

class _ExtractResult {
  final Map<String, List<EpgProgram>> programs;
  final Map<String, String> icons;
  final int count;
  _ExtractResult(this.programs, this.icons, this.count);
}
