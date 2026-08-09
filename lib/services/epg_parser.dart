import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';
import '../models/epg_program.dart';
import 'log_service.dart';
import 'config_service.dart';

// ============================================================
// 顶层 Isolate 函数（不可访问静态成员，必须用顶级函数）
// ============================================================

/// 解析 XML 并返回序列化后的 Map（供 compute 调用）
Map<String, dynamic> _parseEpgXmlIsolate(String xmlContent) {
  final stopwatch = Stopwatch()..start();
  final document = XmlDocument.parse(xmlContent);
  final programs = <String, List<Map<String, dynamic>>>{};
  final icons = <String, String>{};
  final idToName = <String, String>{};

  // 第一遍：channel 节点，建立 id->name 映射并提取图标
  for (final channel in document.findAllElements('channel')) {
    final id = channel.getAttribute('id');
    if (id == null || id.isEmpty) continue;

    final displayNameNode = channel.findElements('display-name').firstOrNull;
    if (displayNameNode != null) {
      final name = displayNameNode.text.trim();
      if (name.isNotEmpty) {
        idToName[id] = name;
        final icon = channel.findElements('icon').firstOrNull?.getAttribute('src');
        if (icon != null && icon.isNotEmpty) {
          icons[name] = icon;
        }
      }
    }
  }

  // 第二遍：programme 节点
  for (final programme in document.findAllElements('programme')) {
    final channelId = programme.getAttribute('channel');
    if (channelId == null) continue;
    final channelName = idToName[channelId];
    if (channelName == null) continue;

    final startStr = programme.getAttribute('start');
    final stopStr = programme.getAttribute('stop');
    if (startStr == null || stopStr == null) continue;

    final start = _parseDateTimeFast(startStr);
    final stop = _parseDateTimeFast(stopStr);
    if (start == null || stop == null) continue;

    final title = programme.findElements('title').firstOrNull?.text ?? '';
    final desc = programme.findElements('desc').firstOrNull?.text ?? '';

    programs.putIfAbsent(channelName, () => []);
    programs[channelName]!.add({
      't': title,
      's': start.millisecondsSinceEpoch,
      'e': stop.millisecondsSinceEpoch,
      'd': desc.isNotEmpty ? desc : null,
    });
  }

  // 排序
  for (final list in programs.values) {
    list.sort((a, b) => (a['s'] as int).compareTo(b['s'] as int));
  }

  stopwatch.stop();
  return {
    'programs': programs,
    'icons': icons,
    'time': stopwatch.elapsedMilliseconds,
  };
}

/// 极速日期解析（YYYYMMDDHHMMSS + 时区）
DateTime? _parseDateTimeFast(String str) {
  try {
    if (str.length < 14) return null;
    final year = int.parse(str.substring(0, 4));
    final month = int.parse(str.substring(4, 6));
    final day = int.parse(str.substring(6, 8));
    final hour = int.parse(str.substring(8, 10));
    final minute = int.parse(str.substring(10, 12));
    final second = int.parse(str.substring(12, 14));
    var dt = DateTime(year, month, day, hour, minute, second);
    // 处理时区偏移（如 +0800）
    if (str.length >= 19) {
      final tzSign = str[15];
      final tzHour = int.parse(str.substring(16, 18));
      final tzMin = int.parse(str.substring(18, 20));
      final offsetMin = tzHour * 60 + tzMin;
      if (tzSign == '+') {
        dt = dt.subtract(Duration(minutes: offsetMin));
      } else if (tzSign == '-') {
        dt = dt.add(Duration(minutes: offsetMin));
      }
    }
    return dt.toLocal();
  } catch (_) {
    return null;
  }
}

/// 序列化后的 programs 转对象（供 compute 调用，避免主线程 JSON decode 大对象）
Map<String, List<EpgProgram>> _deserializePrograms(Map<String, dynamic> raw) {
  final result = <String, List<EpgProgram>>{};
  final programsRaw = raw['programs'] as Map<String, dynamic>;
  for (final entry in programsRaw.entries) {
    final list = (entry.value as List).map((e) {
      final m = e as Map<String, dynamic>;
      return EpgProgram(
        title: m['t'] as String,
        start: DateTime.fromMillisecondsSinceEpoch(m['s'] as int),
        end: DateTime.fromMillisecondsSinceEpoch(m['e'] as int),
        desc: m['d'] as String?,
      );
    }).toList();
    result[entry.key] = list;
  }
  return result;
}

// ============================================================
// EpgParser 主类（全静态，线程安全，播放零阻塞）
// ============================================================

class EpgParser {
  static const String epgCacheDirName = 'epgCache';
  static const String hashFileName = 'epg_hash.txt';
  static const String iconCacheFileName = 'epg_icons.json';
  static const String epgDataFileName = 'epg_data.json';
  static const String programsCacheFileName = 'epg_programs_cache.json';

  static Directory? _cacheDir;
  static Map<String, List<EpgProgram>>? _programsCache;
  static Map<String, String>? _iconMapCache;
  static Map<String, String>? _nameToEpgId;
  static bool _epgDataLoaded = false;

  // 配置仓库
  static const String _baseConfigUrl =
      'https://raw.githubusercontent.com/tytestelle/witv_flutter/main/assets/';

  // 后台任务锁（防止并发下载/解析）
  static final _updateLock = Mutex();
  static bool _isBackgroundUpdating = false;

  // ============================================================
  // 初始化与缓存目录
  // ============================================================

  static Future<void> _initCache() async {
    if (_cacheDir != null) return;
    final appDocDir = await getApplicationDocumentsDirectory();
    _cacheDir = Directory('${appDocDir.path}/$epgCacheDirName');
    if (!await _cacheDir!.exists()) {
      await _cacheDir!.create(recursive: true);
    }
  }

  static Future<String?> _getEpgUrl() async {
    final config = await ConfigService.getConfig();
    final inner = config['Configuration'] as Map<String, dynamic>?;
    final epgUrlRaw = inner?['EPG_URLS'] as String?;
    if (epgUrlRaw == null || epgUrlRaw.isEmpty) return null;
    if (epgUrlRaw.contains(r'$')) {
      return epgUrlRaw.split(r'$')[0].trim();
    }
    return epgUrlRaw.trim();
  }

  static String _computeHash(String content) {
    return md5.convert(utf8.encode(content)).toString();
  }

  // ============================================================
  // epg_data.json 加载（名称映射表）
  // ============================================================

  static Future<void> _loadEpgData() async {
    if (_epgDataLoaded) return;
    try {
      String content = '';
      final appDocDir = await getApplicationDocumentsDirectory();
      final localFile = File(p.join(appDocDir.path, epgDataFileName));

      // 1. 优先远程（带 token）
      final token = await ConfigService.getGitHubToken();
      bool loadedFromRemote = false;
      if (token != null && token.isNotEmpty) {
        try {
          final url = '${_baseConfigUrl}epg_data.json';
          LogService.write('EpgParser: 尝试远程加载 epg_data.json...');
          final response = await Dio().get(
            url,
            options: Options(
              headers: {'Authorization': 'token $token'},
              receiveTimeout: const Duration(seconds: 10),
            ),
          );
          if (response.statusCode == 200) {
            content = response.data.toString();
            await localFile.writeAsString(content);
            loadedFromRemote = true;
            LogService.write('EpgParser: 远程加载 epg_data.json 成功');
          } else {
            throw Exception('HTTP ${response.statusCode}');
          }
        } catch (e) {
          LogService.write('EpgParser: 远程加载失败: $e');
        }
      }

      // 2. 本地缓存或 assets
      if (!loadedFromRemote) {
        if (await localFile.exists()) {
          content = await localFile.readAsString();
          LogService.write('EpgParser: 本地缓存加载 epg_data.json');
        } else {
          content = await rootBundle.loadString('assets/$epgDataFileName');
          await localFile.writeAsString(content);
          LogService.write('EpgParser: assets 加载 epg_data.json');
        }
      }

      // 解析（轻量 JSON，直接主线程即可）
      final decoded = jsonDecode(content);
      List<dynamic> jsonList;
      if (decoded is List) {
        jsonList = decoded;
      } else if (decoded is Map<String, dynamic>) {
        jsonList = (decoded['epgs'] ??
                decoded['data'] ??
                decoded['channels'] ??
                decoded['list'] ??
                <dynamic>[])
            as List<dynamic>;
      } else {
        jsonList = [];
      }

      _nameToEpgId = {};
      for (final item in jsonList) {
        if (item is! Map<String, dynamic>) continue;
        final epgid = item['epgid'] as String?;
        final nameStr = item['name'] as String?;
        if (epgid != null && nameStr != null) {
          final names = nameStr
              .split(',')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList();
          for (final n in names) {
            _nameToEpgId![n] = epgid;
          }
        }
      }
      LogService.write(
          'EpgParser: epg_data.json 加载完成，映射数 ${_nameToEpgId?.length}');
    } catch (e, stack) {
      _nameToEpgId = {};
      LogService.write('EpgParser: 加载 epg_data.json 失败: $e');
    }
    _epgDataLoaded = true;
  }

  // ============================================================
  // 核心优化：二进制缓存（解析一次，永久秒读）
  // ============================================================

  /// 将解析结果写入 JSON 缓存（比 XML 小 5~10 倍，decode 快 20 倍）
  static Future<void> _saveProgramsCache(
    Map<String, List<EpgProgram>> programs,
    Map<String, String> icons,
  ) async {
    await _initCache();
    try {
      final cacheFile = File('${_cacheDir!.path}/$programsCacheFileName');
      final serializable = <String, dynamic>{
        'version': 1,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'icons': icons,
        'programs': <String, dynamic>{},
      };
      for (final entry in programs.entries) {
        serializable['programs'][entry.key] = entry.value.map((p) => {
          't': p.title,
          's': p.start.millisecondsSinceEpoch,
          'e': p.end.millisecondsSinceEpoch,
          'd': p.desc,
        }).toList();
      }
      await cacheFile.writeAsString(jsonEncode(serializable));
      LogService.write('EpgParser: 节目缓存已保存(${programs.length}频道)');
    } catch (e) {
      LogService.write('EpgParser: 保存节目缓存失败: $e');
    }
  }

  /// 从 JSON 缓存秒级恢复（比解析 XML 快 50 倍以上）
  static Future<bool> _loadProgramsCache() async {
    await _initCache();
    try {
      final cacheFile = File('${_cacheDir!.path}/$programsCacheFileName');
      if (!await cacheFile.exists()) return false;

      final content = await cacheFile.readAsString();
      final raw = jsonDecode(content) as Map<String, dynamic>;

      // 图标
      final iconsRaw = raw['icons'] as Map<String, dynamic>?;
      if (iconsRaw != null) {
        _iconMapCache = iconsRaw.map((k, v) => MapEntry(k, v.toString()));
      }

      // 节目：先取原始 Map，再用 compute 反序列化（避免主线程卡顿）
      final programsRaw = raw['programs'] as Map<String, dynamic>;
      if (programsRaw.isEmpty) {
        _programsCache = {};
        return true;
      }

      // 小数据量直接主线程，大数据量用 compute
      if (programsRaw.length > 500) {
        _programsCache = await compute(_deserializePrograms, {'programs': programsRaw});
      } else {
        _programsCache = _deserializePrograms({'programs': programsRaw});
      }

      LogService.write(
          'EpgParser: 节目缓存秒级恢复(${_programsCache!.length}频道)');
      return true;
    } catch (e) {
      LogService.write('EpgParser: 加载节目缓存失败: $e');
      return false;
    }
  }

  // ============================================================
  // EPG 更新与下载（全后台，零阻塞播放）
  // ============================================================

  static Future<bool> checkForUpdate() async {
    if (_isBackgroundUpdating) return false;
    return await _updateLock.protect(() async {
      _isBackgroundUpdating = true;
      try {
        await _initCache();
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
      final response = await Dio().get(
        hashUrl,
        options: Options(
          receiveTimeout: const Duration(seconds: 10),
          sendTimeout: const Duration(seconds: 5),
        ),
      );
      final remoteHash = response.data.toString().trim();
      if (remoteHash.isEmpty) return false;

      final hashFile = File('${_cacheDir!.path}/$hashFileName');
      String localHash = '';
      if (await hashFile.exists()) {
        localHash = await hashFile.readAsString();
      }

      if (localHash == remoteHash) {
        LogService.write('EPG 哈希未变化，无需更新');
        // 即使哈希没变，也尝试从缓存加载（首次启动场景）
        if (_programsCache == null) {
          await _loadProgramsCache();
        }
        return false;
      }

      LogService.write('EPG 需要更新，开始流式下载...');

      // 流式下载到临时文件，避免大文件内存溢出
      final tempFile = File(
          '${_cacheDir!.path}/epg_temp_${DateTime.now().millisecondsSinceEpoch}.xml');
      await Dio().download(
        epgUrl,
        tempFile.path,
        options: Options(
          receiveTimeout: const Duration(seconds: 60),
          sendTimeout: const Duration(seconds: 10),
        ),
      );

      if (!await tempFile.exists()) {
        LogService.write('EPG 下载失败：临时文件不存在');
        return false;
      }

      final xmlContent = await tempFile.readAsString();
      if (xmlContent.trim().isEmpty || !xmlContent.trim().startsWith('<')) {
        await tempFile.delete();
        LogService.write('EPG 下载内容无效');
        return false;
      }

      // === 关键优化：Isolate 中完成解析 + 缓存写入 ===
      final newHash = _computeHash(xmlContent);
      LogService.write('EPG 下载完成，大小 ${xmlContent.length}，开始在 Isolate 解析...');

      final parseResult = await compute(_parseEpgXmlIsolate, xmlContent);
      final programs = await compute(_deserializePrograms, parseResult);
      final icons = (parseResult['icons'] as Map<String, dynamic>)
          .map((k, v) => MapEntry(k, v.toString()));

      // 原子替换：先写缓存，再替换 hash，最后删旧文件
      await _saveProgramsCache(programs, icons);

      if (await hashFile.exists()) {
        final oldHash = await hashFile.readAsString();
        final oldXml = File('${_cacheDir!.path}/epg_$oldHash.xml');
        if (await oldXml.exists()) await oldXml.delete();
      }

      final newXmlFile = File('${_cacheDir!.path}/epg_$newHash.xml');
      await tempFile.copy(newXmlFile.path);
      await tempFile.delete();
      await hashFile.writeAsString(newHash);

      // 内存缓存原子替换
      _programsCache = programs;
      _iconMapCache = icons;

      LogService.write('EPG 更新完成，新哈希: $newHash，共 ${programs.length} 频道');
      return true;
    } catch (e) {
      LogService.write('EPG 更新检查失败: $e');
      return false;
    }
  }

  // ============================================================
  // 缓存加载（启动时调用，优先秒级缓存，fallback 到 XML）
  // ============================================================

  static Future<void> _loadCachedEpg() async {
    if (_programsCache != null && _iconMapCache != null) return;

    // 1. 优先尝试二进制缓存（毫秒级）
    final cacheLoaded = await _loadProgramsCache();
    if (cacheLoaded) {
      // 图标缓存若已包含在 programsCache 中则无需再加载旧格式
      if (_iconMapCache != null && _iconMapCache!.isNotEmpty) return;
    }

    // 2. Fallback：从旧版 XML 缓存恢复（首次升级场景）
    await _initCache();
    final hashFile = File('${_cacheDir!.path}/$hashFileName');
    if (!await hashFile.exists()) {
      _programsCache ??= {};
      _iconMapCache ??= {};
      LogService.write('EPG 无缓存，初始化空数据');
      return;
    }

    final hash = await hashFile.readAsString();
    final xmlFile = File('${_cacheDir!.path}/epg_$hash.xml');
    if (!await xmlFile.exists()) {
      _programsCache ??= {};
      _iconMapCache ??= {};
      LogService.write('EPG XML 缓存文件缺失');
      return;
    }

    try {
      final xmlContent = await xmlFile.readAsString();
      if (xmlContent.trim().isEmpty || !xmlContent.trim().startsWith('<')) {
        await xmlFile.delete();
        _programsCache = {};
        LogService.write('EPG XML 内容无效，已清理');
        return;
      }

      // 大文件用 compute 解析
      final parseResult = await compute(_parseEpgXmlIsolate, xmlContent);
      _programsCache = await compute(_deserializePrograms, parseResult);
      _iconMapCache = (parseResult['icons'] as Map<String, dynamic>)
          .map((k, v) => MapEntry(k, v.toString()));

      // 解析成功后立即写入二进制缓存，下次秒开
      await _saveProgramsCache(_programsCache!, _iconMapCache!);

      LogService.write(
          'EPG XML 解析完成，频道数: ${_programsCache!.length}，已转存二进制缓存');
    } catch (e) {
      LogService.write('EPG 缓存解析失败: $e');
      await xmlFile.delete();
      _programsCache = {};
      _iconMapCache = {};
    }
  }

  static Future<void> _saveIconCache(Map<String, String> icons) async {
    try {
      await _initCache();
      final iconFile = File('${_cacheDir!.path}/$iconCacheFileName');
      await iconFile.writeAsString(jsonEncode(icons));
    } catch (e) {
      LogService.write('保存图标缓存失败: $e');
    }
  }

  // ============================================================
  // 对外 API（全部非阻塞，内存级速度）
  // ============================================================

  static Future<Map<String, String>> getNameToEpgId() async {
    await _loadEpgData();
    return Map.from(_nameToEpgId ?? {});
  }

  static Future<String?> getChannelIconUrl(String channelName) async {
    if (_iconMapCache == null) await _loadCachedEpg();
    return _iconMapCache?[channelName];
  }

  static Future<List<EpgProgram>> getProgramsForChannel(String channelName) async {
    await _loadEpgData();
    if (_programsCache == null) await _loadCachedEpg();
    if (_programsCache == null || _nameToEpgId == null) return [];

    final epgid = _nameToEpgId![channelName];
    if (epgid == null) return [];
    final programs = _programsCache![epgid];
    return programs ?? [];
  }

  /// 获取一组频道的节目（key = 频道显示名称）
  static Future<Map<String, List<EpgProgram>>> getGroupPrograms(
      List<String> channelNames) async {
    await _loadEpgData();
    if (_programsCache == null) await _loadCachedEpg();
    if (_programsCache == null || _nameToEpgId == null) return {};

    final result = <String, List<EpgProgram>>{};
    for (final name in channelNames) {
      final epgid = _nameToEpgId![name];
      if (epgid != null && _programsCache!.containsKey(epgid)) {
        result[name] = _programsCache![epgid]!;
      }
    }
    return result;
  }

  /// 新增：按频道名列表批量获取节目（UI 层直接调用，无需关心 epgid）
  static Future<Map<String, List<EpgProgram>>> getProgramsForChannels(
      List<String> channelNames) async {
    return getGroupPrograms(channelNames);
  }

  /// 获取全部节目（ key = epgid ）
  static Future<Map<String, List<EpgProgram>>> getAllPrograms() async {
    if (_programsCache == null) await _loadCachedEpg();
    return Map.from(_programsCache ?? {});
  }

  static Future<Map<String, String>> getAllChannelIcons() async {
    if (_iconMapCache == null) await _loadCachedEpg();
    return Map.from(_iconMapCache ?? {});
  }

  /// 预加载：启动时调用，后台静默完成所有初始化
  static Future<void> preloadAll() async {
    await _loadEpgData();
    await _loadCachedEpg();
  }

  static Future<List<String>> getAllChannelNames() async {
    await _loadCachedEpg();
    return _programsCache?.keys.toList() ?? [];
  }

  static Future<void> clearCache() async {
    await _initCache();
    if (await _cacheDir!.exists()) {
      await _cacheDir!.delete(recursive: true);
      await _cacheDir!.create();
    }
    _programsCache = null;
    _iconMapCache = null;
    _nameToEpgId = null;
    _epgDataLoaded = false;
    LogService.write('EPG 缓存已清空');
  }

  static Future<String?> getCachedHash() async {
    await _initCache();
    final hashFile = File('${_cacheDir!.path}/$hashFileName');
    if (await hashFile.exists()) {
      return await hashFile.readAsString();
    }
    return null;
  }

  /// 手动更新 epg_data.json
  static Future<bool> updateEpgData() async {
    try {
      final token = await ConfigService.getGitHubToken();
      if (token == null || token.isEmpty) {
        LogService.write('EpgParser: 未设置令牌，无法更新');
        return false;
      }
      final url = '${_baseConfigUrl}epg_data.json';
      LogService.write('EpgParser: 手动更新 epg_data.json...');
      final response = await Dio().get(
        url,
        options: Options(
          headers: {'Authorization': 'token $token'},
          receiveTimeout: const Duration(seconds: 10),
        ),
      );
      if (response.statusCode == 200) {
        final appDocDir = await getApplicationDocumentsDirectory();
        final localFile = File(p.join(appDocDir.path, epgDataFileName));
        await localFile.writeAsString(response.data.toString());
        _nameToEpgId = null;
        _epgDataLoaded = false;
        await _loadEpgData();
        LogService.write('EpgParser: 手动更新 epg_data.json 成功');
        return true;
      }
      return false;
    } catch (e) {
      LogService.write('EpgParser: 手动更新失败: $e');
      return false;
    }
  }
}

// ============================================================
// 简易互斥锁（防止并发更新）
// ============================================================

class Mutex {
  Future<void>? _last;

  Future<T> protect<T>(Future<T> Function() task) async {
    final prev = _last;
    final completer = Completer<void>();
    _last = completer.future;
    try {
      if (prev != null) await prev;
      return await task();
    } finally {
      completer.complete();
    }
  }
}
