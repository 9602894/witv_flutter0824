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

/// EPG 服务 - 按需从 XML 文件提取
///
/// 内存中只保留：
/// 1. epg_data.json 的 name → epgid 映射
/// 2. XML 中 display-name → channel-id 映射（几百条）
///
/// 需要节目时，打开 XML 文件，只提取该 channel-id 的节目，不预加载全部。
class EpgParser {
  static const String _epgUrlKey = 'epg_url';
  static const String _lastEpgUpdateKey = 'last_epg_update';
  static const String _epgDataJsonAsset = 'assets/epg_data.json';
  static const String _epgTempFile = 'epg_temp.xml';

  // name → epgid（epgid 即 XML 中 display-name）
  static Map<String, String>? _nameToEpgidMap;
  // display-name → channel-id
  static Map<String, String>? _displayNameToChannelId;
  // channel-id → icon
  static Map<String, String>? _channelIdToIcon;
  // XML 文件路径
  static String? _xmlFilePath;

  // 后台任务锁
  static bool _isDownloading = false;

  // UI 更新通知
  static final ValueNotifier<int> epgUpdateCounter = ValueNotifier(0);

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

  // ========== 主入口 ==========
  static Future<void> init() async {
    LogService.write('EPG: init 开始');
    try {
      await _loadEpgNameMap();
      LogService.write('EPG: 名称映射 ${_nameToEpgidMap?.length ?? 0} 条');
      _checkAndUpdateInBackground();
      LogService.write('EPG: init 完成，后台下载/索引中');
    } catch (e, stack) {
      LogService.writeCrashLog('EPG init 失败: $e', stack);
    }
  }

  // ========== 后台下载 + 建立 channel 索引 ==========
  static void _checkAndUpdateInBackground() async {
    if (_isDownloading) return;
    _isDownloading = true;

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
          LogService.write('EPG: ${diff.inMinutes}分钟前已更新，跳过');
          return;
        }
      }

      // 下载到文件
      final dir = await getApplicationDocumentsDirectory();
      final tempPath = '${dir.path}/$_epgTempFile';

      LogService.write('EPG: 开始下载...');
      final request = await HttpClient().getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != 200) {
        LogService.write('EPG: 下载失败 HTTP=${response.statusCode}');
        return;
      }

      final file = File(tempPath);
      await response.pipe(file.openWrite());
      final size = await file.length();
      LogService.write('EPG: 下载完成 ${(size / 1024 / 1024).toStringAsFixed(1)}MB');

      // Isolate 里扫描 channel 标签，建立 display-name → channel-id 索引
      final needed = _nameToEpgidMap?.values.toSet().toList() ?? [];
      final result = await Isolate.run(() => _buildChannelIndex(tempPath, needed));

      _xmlFilePath = tempPath;
      _displayNameToChannelId = result.displayNameToId;
      _channelIdToIcon = result.idToIcon;

      LogService.write('EPG: channel 索引建立完成 ${_displayNameToChannelId?.length} 条');
      epgUpdateCounter.value++;

      settings[_lastEpgUpdateKey] = DateTime.now().millisecondsSinceEpoch;
      await _saveSettings(settings);
      LogService.write('EPG: 后台完成');
    } catch (e, stack) {
      LogService.writeCrashLog('EPG 后台失败: $e', stack);
    } finally {
      _isDownloading = false;
    }
  }

  static Future<void> forceRefresh() async {
    final settings = await _loadSettings();
    settings.remove(_lastEpgUpdateKey);
    await _saveSettings(settings);
    _checkAndUpdateInBackground();
  }

  // ========== Isolate：扫描 channel 建立索引 ==========
  @pragma('vm:entry-point')
  static _ChannelIndex _buildChannelIndex(String filePath, List<String> neededDisplayNames) {
    final needed = Set<String>.from(neededDisplayNames);
    final displayNameToId = <String, String>{};
    final idToIcon = <String, String>{};

    final xml = File(filePath).readAsStringSync();
    final blocks = xml.split('</channel>');

    for (final block in blocks) {
      final chIdx = block.lastIndexOf('<channel');
      if (chIdx == -1) continue;

      final tagEnd = block.indexOf('>', chIdx);
      if (tagEnd == -1) continue;

      final tag = block.substring(chIdx, tagEnd + 1);
      final idIdx = tag.indexOf('id="');
      if (idIdx == -1) continue;
      final idEnd = tag.indexOf('"', idIdx + 4);
      final channelId = tag.substring(idIdx + 4, idEnd);

      // 提取 display-name
      final dnOpen = block.indexOf('<display-name', tagEnd);
      if (dnOpen == -1) continue;
      final dnTagEnd = block.indexOf('>', dnOpen);
      final dnClose = block.indexOf('</display-name>', dnTagEnd);
      if (dnClose == -1) continue;
      final displayName = block.substring(dnTagEnd + 1, dnClose).trim();

      if (!needed.contains(displayName)) continue;

      displayNameToId[displayName] = channelId;

      // 提取 icon
      final iconIdx = block.indexOf('src="', tagEnd);
      if (iconIdx != -1) {
        final iconEnd = block.indexOf('"', iconIdx + 5);
        idToIcon[channelId] = block.substring(iconIdx + 5, iconEnd);
      }
    }

    return _ChannelIndex(displayNameToId, idToIcon);
  }

  // ========== 按需提取某个 channel 的节目 ==========
  static Future<List<EpgProgram>> _extractProgramsForChannel(String channelId) async {
    final path = _xmlFilePath;
    if (path == null) return [];

    return await Isolate.run(() {
      final xml = File(path).readAsStringSync();
      final programs = <EpgProgram>[];

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

        if (progChannelId != channelId) continue;

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

        programs.add(EpgProgram(
          title: title,
          description: desc,
          start: start,
          stop: stop,
        ));
      }

      programs.sort((a, b) => a.start.compareTo(b.start));
      return programs;
    });
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

  // ========== 查询接口（按需从 XML 提取）==========
  static Future<List<EpgProgram>> getProgramsByChannelName(String channelName) async {
    if (channelName.isEmpty) return [];
    final epgid = _nameToEpgidMap?[channelName];
    if (epgid == null) return [];

    final channelId = _displayNameToChannelId?[epgid];
    if (channelId == null) return [];

    return await _extractProgramsForChannel(channelId);
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
    final channelId = _displayNameToChannelId?[epgid];
    if (channelId == null) return null;
    return _channelIdToIcon?[channelId];
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

class _ChannelIndex {
  final Map<String, String> displayNameToId;
  final Map<String, String> idToIcon;
  _ChannelIndex(this.displayNameToId, this.idToIcon);
}
