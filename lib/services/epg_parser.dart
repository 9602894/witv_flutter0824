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

/// EPG 服务 - 按需提取版
///
/// 核心设计：
/// 1. 从 assets/epg_data.json 读取 name → epgid 映射（epgid 即 XML 里 channel 的 id）
/// 2. 下载 EPG XML 到临时文件
/// 3. Isolate 里流式扫描 XML，只提取 epg_data.json 中存在的 channel 的节目
/// 4. 结果直接存入内存 Map，不生成任何缓存文件
/// 5. ValueNotifier 通知 UI 刷新
class EpgParser {
  static const String _epgUrlKey = 'epg_url';
  static const String _lastEpgUpdateKey = 'last_epg_update';
  static const String _epgDataJsonAsset = 'assets/epg_data.json';
  static const String _epgTempFile = 'epg_temp.xml';

  // ========== 内存缓存（唯一真相源）==========
  static Map<String, List<EpgProgram>>? _memoryCache;
  static Map<String, String>? _iconCache;
  static Map<String, String>? _nameToEpgidMap;

  // ========== 后台任务锁 ==========
  static bool _isDownloading = false;

  // ========== UI 更新通知 ==========
  static final ValueNotifier<int> epgUpdateCounter = ValueNotifier(0);

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

  // ========== 主入口：启动时调用，零阻塞 ==========
  static Future<void> init() async {
    LogService.write('EPG: ========== init 开始 ==========');
    try {
      // 1. 加载 epg_data.json（name → epgid 映射）
      await _loadEpgNameMap();
      LogService.write('EPG: 名称映射 ${_nameToEpgidMap?.length ?? 0} 条');

      // 2. 后台下载+提取（不 await，不阻塞播放）
      _checkAndUpdateInBackground();

      LogService.write('EPG: ========== init 完成（后台提取中） ==========');
    } catch (e, stack) {
      LogService.writeCrashLog('EPG init 失败: $e', stack);
    }
  }

  // ========== 后台检查更新 ==========
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

      // 检查更新间隔
      final settings = await _loadSettings();
      final lastUpdate = settings[_lastEpgUpdateKey] as int?;
      if (lastUpdate != null) {
        final diff = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(lastUpdate));
        if (diff < const Duration(hours: 6)) {
          LogService.write('EPG: ${diff.inMinutes}分钟前已更新，跳过');
          return;
        }
      }

      // 1. 下载到临时文件
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

      // 2. 准备 neededChannels（epg_data.json 里的 epgid）
      final neededChannels = _nameToEpgidMap?.values.toSet().toList() ?? [];
      LogService.write('EPG: 需要提取 ${neededChannels.length} 个频道');

      // 3. 【关键】Isolate 里只提取 needed channels，不解析全部
      final stopwatch = Stopwatch()..start();
      final result = await Isolate.run(() => _extractNeededChannels(tempPath, neededChannels));
      stopwatch.stop();

      LogService.write(
        'EPG: 提取完成 ${result.programs.length}频道 ${result.count}节目 '
        '耗时 ${stopwatch.elapsedMilliseconds}ms',
      );

      // 4. 主线程只做赋值
      _memoryCache = result.programs;
      _iconCache = result.icons;
      epgUpdateCounter.value++;
      LogService.write('EPG: 内存缓存已更新，UI 收到通知');

      // 5. 更新设置
      settings[_lastEpgUpdateKey] = DateTime.now().millisecondsSinceEpoch;
      await _saveSettings(settings);

      // 6. 清理临时文件
      try { await file.delete(); } catch (_) {}

      LogService.write('EPG: ========== 后台更新完成 ==========');
    } catch (e, stack) {
      LogService.writeCrashLog('EPG 后台更新失败: $e', stack);
    } finally {
      _isDownloading = false;
    }
  }

  static Future<void> forceRefresh() async {
    LogService.write('EPG: 强制刷新');
    final settings = await _loadSettings();
    settings.remove(_lastEpgUpdateKey);
    await _saveSettings(settings);
    _checkAndUpdateInBackground();
  }

  // ========== Isolate 函数：只提取 needed channels ==========
  /// 不用 xml 包，split 分块扫描，只保留 epg_data.json 中存在的 channel
  @pragma('vm:entry-point')
  static _ExtractResult _extractNeededChannels(String filePath, List<String> neededChannels) {
    final needed = Set<String>.from(neededChannels);
    final programMap = <String, List<EpgProgram>>{};
    final icons = <String, String>{};
    var count = 0;

    final xml = File(filePath).readAsStringSync();

    // ---- 提取 channel icon ----
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

      if (!needed.contains(channelId)) continue;

      final iconIdx = block.indexOf('src="');
      if (iconIdx != -1) {
        final iconEnd = block.indexOf('"', iconIdx + 5);
        icons[channelId] = block.substring(iconIdx + 5, iconEnd);
      }
    }

    // ---- 提取 programme（只保留 needed channels）----
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
      final channelId = tag.substring(chIdx + 9, chEnd);

      if (!needed.contains(channelId)) continue;

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

      programMap.putIfAbsent(channelId, () => []).add(EpgProgram(
        title: title,
        description: desc,
        start: start,
        stop: stop,
      ));
      count++;
    }

    // 排序
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

  // ========== 查询接口（纯内存，O(1)）==========
  static Future<List<EpgProgram>> getProgramsByChannelName(String channelName) async {
    if (channelName.isEmpty) return [];
    final epgid = _nameToEpgidMap?[channelName];
    if (epgid == null) return [];
    return _memoryCache?[epgid] ?? [];
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

  static Future<String?> getChannelIconUrl(String channelName) {
    return getChannelIcon(channelName);
  }

  static Future<Map<String, String>> getNameToEpgId() async {
    return _nameToEpgidMap ?? {};
  }

  static Future<String?> getEpgidByChannelName(String channelName) async {
    return _nameToEpgidMap?[channelName];
  }

  // ========== 加载 epg_data.json（name → epgid 映射）==========
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
