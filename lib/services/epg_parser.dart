import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:collection/collection.dart';
import '../models/epg_program.dart';
import 'log_service.dart';
import 'config_service.dart';

/// EPG 服务 - 纯按需读取版（无内存缓存）
///
/// 设计：
/// 1. epg_data.json 提供 name → epgid（即 XML 中 <display-name>）的映射
/// 2. 下载 EPG XML 到临时文件，仅存储，不解析
/// 3. 查询时直接读取 XML，通过 display-name 找到 channel id，再提取节目
/// 4. 所有查询均在 Isolate 中执行，避免阻塞 UI
class EpgParser {
  static const String _epgUrlKey = 'epg_url';
  static const String _lastEpgUpdateKey = 'last_epg_update';
  static const String _epgDataJsonAsset = 'assets/epg_data.json';
  static const String _epgTempFile = 'epg_temp.xml';

  // ========== 映射（唯一保留的内存数据）==========
  static Map<String, String>? _nameToEpgidMap; // 频道名 → epgid（display-name）

  // ========== 文件路径 ==========
  static String? _epgFilePath;

  // ========== 后台任务锁 ==========
  static bool _isDownloading = false;

  // ========== UI 更新通知（仅用于告知下载完成）==========
  static final ValueNotifier<int> epgUpdateCounter = ValueNotifier(0);

  // ========== 时区工具（保持不变）==========
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
    LogService.write('EPG: ========== init 开始 ==========');
    try {
      await _loadEpgNameMap();
      LogService.write('EPG: 名称映射 ${_nameToEpgidMap?.length ?? 0} 条');
      _checkAndUpdateInBackground();
      LogService.write('EPG: ========== init 完成 ==========');
    } catch (e, stack) {
      LogService.writeCrashLog('EPG init 失败: $e', stack);
    }
  }

  // ========== 后台下载（仅下载，不解析）==========
  static void _checkAndUpdateInBackground() async {
    if (_isDownloading) return;
    _isDownloading = true;

    try {
      final url = await _resolveEpgUrl();
      if (url == null || url.isEmpty) {
        LogService.write('EPG: 无可用 URL');
        return;
      }
      LogService.write('EPG: URL=$url');

      final settings = await _loadSettings();
      final lastUpdate = settings[_lastEpgUpdateKey] as int?;
      if (lastUpdate != null) {
        final diff = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(lastUpdate));
        if (diff < const Duration(hours: 6)) {
          LogService.write('EPG: ${diff.inMinutes}分钟前已更新，跳过');
          return;
        }
      }

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

      // 保存文件路径
      _epgFilePath = tempPath;

      // 更新设置
      settings[_lastEpgUpdateKey] = DateTime.now().millisecondsSinceEpoch;
      await _saveSettings(settings);

      // 通知 UI
      epgUpdateCounter.value++;

      LogService.write('EPG: ========== 后台下载完成 ==========');
    } catch (e, stack) {
      LogService.writeCrashLog('EPG 后台下载失败: $e', stack);
    } finally {
      _isDownloading = false;
    }
  }

  // ========== 强制刷新 ==========
  static Future<void> forceRefresh() async {
    LogService.write('EPG: 强制刷新');
    final settings = await _loadSettings();
    settings.remove(_lastEpgUpdateKey);
    await _saveSettings(settings);
    _checkAndUpdateInBackground();
  }

  // ========== 查询接口（直接读 XML，Isolate 执行）==========
  static Future<List<EpgProgram>> getProgramsByChannelName(String channelName) async {
    if (channelName.isEmpty) return [];
    final epgid = _nameToEpgidMap?[channelName];
    if (epgid == null) return [];
    final filePath = _epgFilePath;
    if (filePath == null || !(await File(filePath).exists())) {
      LogService.write('EPG: XML 文件不存在，返回空');
      return [];
    }
    try {
      // 在 Isolate 中解析
      final result = await Isolate.run(() => _extractProgramsForEpgid(filePath, epgid));
      return result ?? [];
    } catch (e, stack) {
      LogService.writeCrashLog('EPG 查询失败: $e', stack);
      return [];
    }
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
    final filePath = _epgFilePath;
    if (filePath == null || !(await File(filePath).exists())) return null;
    try {
      return await Isolate.run(() => _extractIconForEpgid(filePath, epgid));
    } catch (e) {
      LogService.write('EPG 获取图标失败: $e');
      return null;
    }
  }

  static Future<String?> getChannelIconUrl(String channelName) => getChannelIcon(channelName);

  static Future<Map<String, String>> getNameToEpgId() async {
    return _nameToEpgidMap ?? {};
  }

  static Future<String?> getEpgidByChannelName(String channelName) async {
    return _nameToEpgidMap?[channelName];
  }

  // ========== Isolate 解析函数 ==========
  /// 提取指定 epgid（display-name）的节目列表
  @pragma('vm:entry-point')
  static List<EpgProgram>? _extractProgramsForEpgid(String filePath, String epgid) {
    try {
      final xml = File(filePath).readAsStringSync();

      // 1. 查找 channel id
      final channelId = _findChannelIdForDisplayName(xml, epgid);
      if (channelId == null) return null;

      // 2. 提取该 channel 的所有 programme
      final programs = <EpgProgram>[];
      final blocks = xml.split('</programme>');
      for (final block in blocks) {
        final progIdx = block.lastIndexOf('<programme');
        if (progIdx == -1) continue;
        final tagEnd = block.indexOf('>', progIdx);
        if (tagEnd == -1) continue;

        final tag = block.substring(progIdx, tagEnd + 1);

        // 检查 channel 属性
        final chIdx = tag.indexOf('channel="');
        if (chIdx == -1) continue;
        final chEnd = tag.indexOf('"', chIdx + 9);
        final ch = tag.substring(chIdx + 9, chEnd);
        if (ch != channelId) continue;

        // 解析 start / stop
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
    } catch (e) {
      return null;
    }
  }

  /// 提取指定 epgid 的频道图标 URL
  @pragma('vm:entry-point')
  static String? _extractIconForEpgid(String filePath, String epgid) {
    try {
      final xml = File(filePath).readAsStringSync();
      // 查找 display-name 匹配的 channel
      final channelBlock = _findChannelBlockForDisplayName(xml, epgid);
      if (channelBlock == null) return null;

      // 从 channel 块中提取 icon src
      final iconIdx = channelBlock.indexOf('src="');
      if (iconIdx == -1) return null;
      final iconEnd = channelBlock.indexOf('"', iconIdx + 5);
      return channelBlock.substring(iconIdx + 5, iconEnd);
    } catch (e) {
      return null;
    }
  }

  // ========== 辅助解析函数 ==========
  static String? _findChannelIdForDisplayName(String xml, String displayName) {
    final blocks = xml.split('</channel>');
    for (final block in blocks) {
      final chIdx = block.lastIndexOf('<channel');
      if (chIdx == -1) continue;
      final tagEnd = block.indexOf('>', chIdx);
      if (tagEnd == -1) continue;

      // 检查 display-name
      final dnStart = block.indexOf('<display-name>');
      if (dnStart == -1) continue;
      final dnEnd = block.indexOf('</display-name>', dnStart);
      if (dnEnd == -1) continue;
      final dn = block.substring(dnStart + 14, dnEnd).trim();
      if (dn != displayName) continue;

      // 提取 id
      final idIdx = block.indexOf('id="', chIdx);
      if (idIdx == -1) continue;
      final idEnd = block.indexOf('"', idIdx + 4);
      return block.substring(idIdx + 4, idEnd);
    }
    return null;
  }

  static String? _findChannelBlockForDisplayName(String xml, String displayName) {
    final blocks = xml.split('</channel>');
    for (final block in blocks) {
      final chIdx = block.lastIndexOf('<channel');
      if (chIdx == -1) continue;
      final dnStart = block.indexOf('<display-name>');
      if (dnStart == -1) continue;
      final dnEnd = block.indexOf('</display-name>', dnStart);
      if (dnEnd == -1) continue;
      final dn = block.substring(dnStart + 14, dnEnd).trim();
      if (dn == displayName) {
        return block;
      }
    }
    return null;
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
      LogService.write('EPG: epg_data.json 加载完成 ${_nameToEpgidMap!.length} 条映射');
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

  // 已不再需要预热缓存，保留空实现以防外部调用
  static Future<void> warmUpCache() async {
    await _loadEpgNameMap();
  }
}
