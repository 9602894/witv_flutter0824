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

class EpgParser {
  static const String _epgUrlKey = 'epg_url';
  static const String _lastEpgUpdateKey = 'last_epg_update';
  static const String _epgDataJsonAsset = 'assets/epg_data.json';
  static const String _epgXmlFile = 'epg_data.xml';

  static Map<String, String>? _nameToEpgidMap;
  static Map<String, List<EpgProgram>>? _memoryCache;
  static Map<String, String>? _iconCache;
  static Map<String, String>? _allDisplayNameToIcon;
  static Map<String, String>? _allDisplayNameToChannelId;
  static Map<String, String>? _allChannelIdToIcon;

  static bool _isWorking = false;
  static final ValueNotifier<int> epgUpdateCounter = ValueNotifier(0);

  /// [修正] 获取当前UTC时间，用于和EPG节目时间(UTC存储)直接比较
  /// EPG节目时间已通过 _parseXmltvTime 转为UTC存储，因此比较基准也必须是UTC
  static DateTime get beijingNow => DateTime.now().toUtc();

  /// 将UTC时间转为北京时间显示
  static DateTime toBeijing(DateTime dt) {
    return dt.toUtc().add(const Duration(hours: 8));
  }

  static String formatBeijingTime(DateTime dt) {
    final bj = toBeijing(dt);
    return '${bj.hour.toString().padLeft(2, '0')}:${bj.minute.toString().padLeft(2, '0')}';
  }

  static String formatBeijingDateTime(DateTime dt) {
    final bj = toBeijing(dt);
    return '${bj.month.toString().padLeft(2, '0')}-${bj.day.toString().padLeft(2, '0')} ${bj.hour.toString().padLeft(2, '0')}:${bj.minute.toString().padLeft(2, '0')}';
  }

  static DateTime beijingDate(DateTime dt) {
    final bj = toBeijing(dt);
    return DateTime(bj.year, bj.month, bj.day);
  }

  static String beijingWeekday(DateTime dt) {
    final bj = toBeijing(dt);
    final weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return weekdays[bj.weekday - 1];
  }

  static Future<void> init() async {
    LogService.write('EPG: init 开始');
    try {
      await _loadEpgNameMap();
      LogService.write('EPG: 名称映射 ${_nameToEpgidMap?.length ?? 0} 条');

      final dir = await getApplicationDocumentsDirectory();
      final xmlFile = File('${dir.path}/$_epgXmlFile');

      if (await xmlFile.exists()) {
        LogService.write('EPG: 发现本地 XML，直接提取');
        await _extractFromLocalFile();
      } else {
        LogService.write('EPG: 无本地 XML，后台下载');
        _checkAndUpdateInBackground();
      }

      LogService.write('EPG: init 完成');
    } catch (e, stack) {
      LogService.writeCrashLog('EPG init 失败: $e', stack);
    }
  }

  static Future<void> _extractFromLocalFile() async {
    if (_isWorking) return;
    _isWorking = true;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final xmlPath = '${dir.path}/$_epgXmlFile';
      // 修改点 1：传完整的别名映射给 isolate
      final nameMap = _nameToEpgidMap ?? {};
      final needed = nameMap.keys.toSet().toList(); // 用 keys（所有别名），不是 values（epgid）
      final result = await Isolate.run(() => _extractNeededPrograms(xmlPath, needed, nameMap));

      stopwatch.stop();

      LogService.write(
        'EPG: 提取完成 ${result.programs.length}频道 ${result.count}节目 '
        '耗时 ${stopwatch.elapsedMilliseconds}ms icon ${result.allDisplayNameToIcon.length}条',
      );

      _memoryCache = result.programs;
      _iconCache = result.icons;
      _allDisplayNameToIcon = result.allDisplayNameToIcon;
      _allDisplayNameToChannelId = result.allDisplayNameToChannelId;
      _allChannelIdToIcon = result.allChannelIdToIcon;
      epgUpdateCounter.value++;
      LogService.write('EPG: 内存已更新（从本地文件）');
    } catch (e, stack) {
      LogService.writeCrashLog('EPG 本地提取失败: $e', stack);
      try {
        final dir = await getApplicationDocumentsDirectory();
        await File('${dir.path}/$_epgXmlFile').delete();
      } catch (_) {}
      _checkAndUpdateInBackground();
    } finally {
      _isWorking = false;
    }
  }

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
          if (_memoryCache == null || _memoryCache!.isEmpty) {
            await _extractFromLocalFile();
          }
          return;
        }
      }

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

      // 修改点 1：传完整的别名映射给 isolate
      final nameMap = _nameToEpgidMap ?? {};
      final needed = nameMap.keys.toSet().toList();
      final stopwatch = Stopwatch()..start();
      final result = await Isolate.run(() => _extractNeededPrograms(xmlPath, needed, nameMap));
      stopwatch.stop();

      LogService.write(
        'EPG: 提取完成 ${result.programs.length}频道 ${result.count}节目 '
        '耗时 ${stopwatch.elapsedMilliseconds}ms icon ${result.allDisplayNameToIcon.length}条',
      );

      _memoryCache = result.programs;
      _iconCache = result.icons;
      _allDisplayNameToIcon = result.allDisplayNameToIcon;
      _allDisplayNameToChannelId = result.allDisplayNameToChannelId;
      _allChannelIdToIcon = result.allChannelIdToIcon;
      epgUpdateCounter.value++;
      LogService.write('EPG: 内存已更新');

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
    final settings = await _loadSettings();
    settings.remove(_lastEpgUpdateKey);
    await _saveSettings(settings);
    _checkAndUpdateInBackground();
  }

  @pragma('vm:entry-point')
  static _ExtractResult _extractNeededPrograms(
    String filePath,
    List<String> neededDisplayNames,
    Map<String, String> nameToEpgIdMap, // 新增参数
  ) {
    final needed = Set<String>.from(neededDisplayNames);
    final displayNameToId = <String, String>{}; // key 为 epgid
    final icons = <String, String>{};
    final allDisplayNameToIcon = <String, String>{};
    final allDisplayNameToChannelId = <String, String>{};
    final allChannelIdToIcon = <String, String>{};

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

      // 修改点 3：遍历所有 display-name
      final displayNames = <String>[];
      var searchStart = tagEnd;
      while (true) {
        final dnOpen = block.indexOf('<display-name', searchStart);
        if (dnOpen == -1) break;
        final dnTagEnd = block.indexOf('>', dnOpen);
        if (dnTagEnd == -1) break;
        final dnClose = block.indexOf('</display-name>', dnTagEnd);
        if (dnClose == -1) break;
        final dn = block.substring(dnTagEnd + 1, dnClose).trim();
        if (dn.isNotEmpty) displayNames.add(dn);
        searchStart = dnClose + 15; // </display-name> 长度
      }

      if (displayNames.isEmpty) continue;

      // 提取 icon（只取第一个出现的 icon）
      String? iconUrl;
      final iconIdx = block.indexOf('src="', tagEnd);
      if (iconIdx != -1) {
        final iconEnd = block.indexOf('"', iconIdx + 5);
        iconUrl = block.substring(iconIdx + 5, iconEnd);
      }

      // 记录所有 display-name 的映射（给 EPG 台标用）
      for (final dn in displayNames) {
        allDisplayNameToChannelId[dn] = channelId;
        if (iconUrl != null) {
          allDisplayNameToIcon[dn] = iconUrl;
          allChannelIdToIcon[channelId] = iconUrl;
        }
      }

      // 检查是否有任何一个 display-name 能匹配到别名
      String? matchedEpgId;
      for (final dn in displayNames) {
        if (needed.contains(dn)) {
          matchedEpgId = nameToEpgIdMap[dn];
          break;
        }
      }
      if (matchedEpgId == null) continue;

      // 用 epgid 作为 key
      displayNameToId[matchedEpgId] = channelId;
      if (iconUrl != null) {
        icons[matchedEpgId] = iconUrl;
      }
    }

    final neededIds = Set<String>.from(displayNameToId.values);
    final programMap = <String, List<EpgProgram>>{}; // key 为 epgid
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

      // 修改点 4：programMap 用 epgid 作为 key
      String? epgId;
      for (final entry in displayNameToId.entries) {
        if (entry.value == progChannelId) {
          epgId = entry.key;
          break;
        }
      }
      if (epgId == null) continue;

      programMap.putIfAbsent(epgId, () => []).add(EpgProgram(
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

    return _ExtractResult(
      programMap,
      icons,
      allDisplayNameToIcon,
      allDisplayNameToChannelId,
      allChannelIdToIcon,
      count,
    );
  }

  static DateTime? _parseXmltvTime(String t) {
    try {
      String s = t.trim();
      final tzMatch = RegExp(r'[+-]\d{4}').firstMatch(s);
      if (tzMatch != null) s = s.substring(0, tzMatch.start).trim();
      if (s.length >= 14) {
        final year = int.parse(s.substring(0, 4));
        final month = int.parse(s.substring(4, 6));
        final day = int.parse(s.substring(6, 8));
        final hour = int.parse(s.substring(8, 10));
        final minute = int.parse(s.substring(10, 12));
        final second = int.parse(s.substring(12, 14));

        final bjTime = DateTime.utc(year, month, day, hour, minute, second);
        return bjTime.subtract(const Duration(hours: 8));
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

  static Future<List<EpgProgram>> getProgramsByChannelName(String channelName) async {
    if (channelName.isEmpty) return [];
    final epgid = _nameToEpgidMap?[channelName];
    if (epgid == null) return [];
    return _memoryCache?[epgid] ?? [];
  }

  static List<EpgProgram> getProgramsSync(String channelName) {
    if (channelName.isEmpty) return [];
    final epgid = _nameToEpgidMap?[channelName];
    if (epgid == null) return [];
    return _memoryCache?[epgid] ?? [];
  }

  static EpgProgram? getCurrentProgramSync(String channelName) {
    final programs = getProgramsSync(channelName);
    if (programs.isEmpty) return null;
    final now = beijingNow;
    return programs.firstWhereOrNull((p) => p.start.isBefore(now) && p.stop.isAfter(now));
  }

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

  static String? getIconUrlByDisplayNameSync(String displayName) {
    return _allDisplayNameToIcon?[displayName];
  }

  static String? getChannelIdByDisplayNameSync(String displayName) {
    return _allDisplayNameToChannelId?[displayName];
  }

  static String? getIconUrlByChannelIdSync(String channelId) {
    return _allChannelIdToIcon?[channelId];
  }

  static bool hasDisplayNameInEpg(String displayName) {
    return _allDisplayNameToChannelId?.containsKey(displayName) ?? false;
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
  final Map<String, String> allDisplayNameToIcon;
  final Map<String, String> allDisplayNameToChannelId;
  final Map<String, String> allChannelIdToIcon;
  final int count;
  _ExtractResult(
    this.programs,
    this.icons,
    this.allDisplayNameToIcon,
    this.allDisplayNameToChannelId,
    this.allChannelIdToIcon,
    this.count,
  );
}
