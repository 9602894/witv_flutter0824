import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'log_service.dart';
import 'epg_parser.dart';
import 'config_service.dart';
import '../models/channel.dart';

class _RgbColor {
  final int r, g, b;
  const _RgbColor(this.r, this.g, this.b);
}

enum LogoSource {
  m3u,
  github,
  epg,
}

extension LogoSourceExt on LogoSource {
  String get displayName {
    switch (this) {
      case LogoSource.m3u: return 'M3U订阅源';
      case LogoSource.github: return 'GitHub台标仓库';
      case LogoSource.epg: return 'EPG文件台标';
    }
  }
  String get description {
    switch (this) {
      case LogoSource.m3u: return '使用 M3U 订阅源中自带的 tvg-logo';
      case LogoSource.github: return '从 sandiJMYG 仓库下载（需配置Token）';
      case LogoSource.epg: return '使用 EPG 文件中提供的台标地址';
    }
  }
}

class LogoService {
  static final LogoService _instance = LogoService._internal();
  factory LogoService() => _instance;
  LogoService._internal();

  // ---------- 内存缓存 ----------
  // channelName -> File?
  final Map<String, File?> _logoResultCache = {};
  // epgId -> File? （同名 epgid 的所有频道共享）
  final Map<String, File?> _epgIdLogoCache = {};

  // ---------- 原有字段 ----------
  Map<String, String>? _nameToEpgId;
  bool _nameMapLoaded = false;
  final Map<String, String> _m3uLogos = {};

  // 并发锁：防止同一个文件被同时下载多次
  final Map<String, Future<File?>> _pendingDownloads = {};

  static const String _baseLogoUrl =
      'https://raw.githubusercontent.com/tytestelle/logo/main/ico/logo/';
  static const int _transparencyTolerance = 30;
  static const String _prefsKeySources = 'logo_sources_enabled';
  static const int _maxConcurrent = 3;

  // ==================== 同步缓存查询 ====================

  /// 同步获取 channelName 缓存
  File? getLogoSync(String channelName) {
    return _logoResultCache[channelName];
  }

  /// 按 epgId 查同步缓存（供UI先用）
  File? getLogoByEpgIdSync(String? epgId) {
    if (epgId == null) return null;
    return _epgIdLogoCache[epgId];
  }

  /// 异步查 epgId（供UI预加载用）
  Future<String?> getEpgIdAsync(String channelName) async {
    return await _getEpgId(channelName);
  }

  // ==================== 配置管理 ====================

  Future<List<LogoSource>> getEnabledSources() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_prefsKeySources);
    if (jsonStr == null || jsonStr.isEmpty) {
      // FIX: 如果没有配置，默认启用 GitHub 来源
      LogService.write('Logo: 未找到配置，使用默认来源 GitHub');
      return [LogoSource.github];
    }
    try {
      final list = jsonDecode(jsonStr) as List<dynamic>;
      final sources = list
          .map((e) => LogoSource.values.firstWhere(
                (s) => s.name == e,
                orElse: () => LogoSource.github,
              ))
          .where((s) => LogoSource.values.contains(s))
          .toList();
      if (sources.isEmpty) {
        LogService.write('Logo: 配置解析为空，使用默认来源 GitHub');
        return [LogoSource.github];
      }
      return sources;
    } catch (e) {
      LogService.write('Logo: 配置解析失败: $e，使用默认来源 GitHub');
      return [LogoSource.github];
    }
  }

  Future<void> setEnabledSources(List<LogoSource> sources) async {
    final prefs = await SharedPreferences.getInstance();
    final list = sources.map((e) => e.name).toList();
    await prefs.setString(_prefsKeySources, jsonEncode(list));
  }

  Future<bool> hasConfiguredSource() async {
    final sources = await getEnabledSources();
    return sources.isNotEmpty;
  }

  // ==================== 公共API ====================

  Future<void> clearNoLogoCache() async {
    try {
      final logoDir = await _getLogoDir();
      if (await logoDir.exists()) {
        await logoDir.delete(recursive: true);
        await logoDir.create();
        _m3uLogos.clear();
        _pendingDownloads.clear();
        _logoResultCache.clear();
        _epgIdLogoCache.clear();
        LogService.write('LogoService: 已手动删除所有台标文件');
      }
    } catch (e) {}
  }

  /// 获取台标（带 epgId 共享缓存）
  Future<File?> getLogo(String channelName) async {
    // 1. channelName 缓存
    if (_logoResultCache.containsKey(channelName)) {
      return _logoResultCache[channelName];
    }

    // 2. epgId 缓存（同名 epgid 的所有频道共享）
    final epgId = await _getEpgId(channelName);
    if (epgId != null && _epgIdLogoCache.containsKey(epgId)) {
      final cached = _epgIdLogoCache[epgId];
      _logoResultCache[channelName] = cached;
      return cached;
    }

    final sources = await getEnabledSources();
    if (sources.isEmpty) {
      LogService.write('Logo: 未配置台标来源，跳过 $channelName');
      return null;
    }

    final cacheName = '${epgId ?? _sanitizeFileName(channelName)}.png';
    final logoDir = await _getLogoDir();
    final cacheFile = File(p.join(logoDir.path, cacheName));

    // 3. 本地文件已存在（所有同名epgid共用）
    if (await cacheFile.exists()) {
      LogService.write('Logo: $channelName 命中本地缓存 $cacheName');
      _logoResultCache[channelName] = cacheFile;
      if (epgId != null) _epgIdLogoCache[epgId] = cacheFile;
      return cacheFile;
    }

    // 4. 正在下载中，排队等待
    if (_pendingDownloads.containsKey(cacheName)) {
      LogService.write('Logo: $channelName 等待 $cacheName 下载完成...');
      final result = await _pendingDownloads[cacheName]!;
      _logoResultCache[channelName] = result;
      if (epgId != null) _epgIdLogoCache[epgId] = result;
      return result;
    }

    // 5. 发起下载
    LogService.write('Logo: $channelName 开始下载 $cacheName');
    final downloadTask = _downloadFromSources(channelName, cacheName, sources);
    _pendingDownloads[cacheName] = downloadTask;

    try {
      final result = await downloadTask;
      _logoResultCache[channelName] = result;
      if (epgId != null) _epgIdLogoCache[epgId] = result;
      if (result != null) {
        LogService.write('Logo: $channelName 下载成功 -> $cacheName');
      } else {
        LogService.write('Logo: $channelName 下载失败');
      }
      return result;
    } finally {
      _pendingDownloads.remove(cacheName);
    }
  }

  /// 获取台标 URL（优先使用 M3U 自带，其次 EPG）
  Future<String?> getLogoUrl(String channelName, String? fallbackUrl) async {
    if (fallbackUrl != null && fallbackUrl.isNotEmpty) {
      return fallbackUrl;
    }
    return await EpgParser.getChannelIcon(channelName);
  }

  void updateM3uLogos(Map<String, String> logos) {
    _m3uLogos.clear();
    _m3uLogos.addAll(logos);
    LogService.write('LogoService: 收到 M3U logo 映射 ${logos.length} 条');
  }

  /// 预加载，限制并发避免影响播放
  Future<void> preloadAllLogos(List<Channel> channels) async {
    final sources = await getEnabledSources();
    if (sources.isEmpty) return;
    LogService.write('LogoService: 开始预加载台标，来源: ${sources.map((s) => s.displayName).join(' > ')}');

    const batchSize = _maxConcurrent;
    for (var i = 0; i < channels.length; i += batchSize) {
      final batch = channels.skip(i).take(batchSize).toList();
      await Future.wait(
        batch.map((ch) => getLogo(ch.name)),
        eagerError: false,
      );
    }
    LogService.write('LogoService: 预加载完成');
  }

  // ==================== 下载逻辑（带锁保护） ====================

  Future<File?> _downloadFromSources(String channelName, String cacheName, List<LogoSource> sources) async {
    final logoDir = await _getLogoDir();
    final cacheFile = File(p.join(logoDir.path, cacheName));

    if (await cacheFile.exists()) {
      return cacheFile;
    }

    for (final source in sources) {
      Uint8List? imageBytes;
      String? sourceDesc;

      switch (source) {
        case LogoSource.m3u:
          final m3uUrl = _m3uLogos[channelName];
          if (m3uUrl != null && m3uUrl.isNotEmpty) {
            sourceDesc = 'M3U';
            imageBytes = await _fetchBytes(m3uUrl);
          }
          break;
        case LogoSource.github:
          String? fileName;
          final epgId = await _getEpgId(channelName);
          if (epgId != null) {
            fileName = '$epgId.png';
          } else {
            fileName = '${_sanitizeFileName(channelName)}.png';
          }
          sourceDesc = 'GitHub';
          final token = await ConfigService.getGitHubToken();
          final url = '$_baseLogoUrl$fileName';
          final headers = <String, String>{};
          if (token != null && token.isNotEmpty) {
            headers['Authorization'] = 'token $token';
          }
          imageBytes = await _fetchBytes(url, headers: headers);
          break;
        case LogoSource.epg:
          final iconUrl = await EpgParser.getChannelIconUrl(channelName);
          if (iconUrl != null && iconUrl.isNotEmpty) {
            sourceDesc = 'EPG';
            imageBytes = await _fetchBytes(iconUrl);
          }
          break;
      }

      if (imageBytes != null) {
        try {
          final processed = await _processTransparency(imageBytes, cacheName);
          await cacheFile.writeAsBytes(processed);
          LogService.write('Logo: $channelName 从 $sourceDesc 下载并保存为 $cacheName');
          return cacheFile;
        } catch (e) {
          LogService.write('Logo: $channelName 保存 $cacheName 失败 - $e');
        }
      }
    }

    LogService.write('Logo: $channelName 所有来源下载失败');
    return null;
  }

  Future<Uint8List?> _fetchBytes(String url, {Map<String, String>? headers}) async {
    try {
      final response = await http.get(Uri.parse(url), headers: headers);
      if (response.statusCode == 200) {
        return response.bodyBytes;
      }
    } catch (e) {
      LogService.write('Logo: 下载失败 $url - $e');
    }
    return null;
  }

  // ==================== 透明化处理核心 ====================

  Future<Uint8List> _processTransparency(Uint8List imageBytes, String fileName) async {
    img.Image? decoded;

    try {
      decoded = img.decodeImage(imageBytes);
    } catch (_) {
      decoded = null;
    }

    if (decoded == null) {
      try {
        final codec = await ui.instantiateImageCodec(imageBytes);
        final frame = await codec.getNextFrame();
        final uiImage = frame.image;
        final byteData = await uiImage.toByteData(format: ui.ImageByteFormat.rawRgba);
        if (byteData != null) {
          final bytes = byteData.buffer.asUint8List();
          decoded = img.Image(width: uiImage.width, height: uiImage.height, numChannels: 4);
          for (int y = 0; y < uiImage.height; y++) {
            for (int x = 0; x < uiImage.width; x++) {
              final i = (y * uiImage.width + x) * 4;
              final pixel = decoded.getPixel(x, y);
              pixel.r = bytes[i];
              pixel.g = bytes[i + 1];
              pixel.b = bytes[i + 2];
              pixel.a = bytes[i + 3];
            }
          }
        }
        uiImage.dispose();
      } catch (_) {
        decoded = null;
      }
    }

    if (decoded == null) {
      try { decoded = img.decodePng(imageBytes); } catch (_) {}
      try { decoded ??= img.decodeJpg(imageBytes); } catch (_) {}
      try { decoded ??= img.decodeWebP(imageBytes); } catch (_) {}
      try { decoded ??= img.decodeGif(imageBytes); } catch (_) {}
      try { decoded ??= img.decodeBmp(imageBytes); } catch (_) {}
    }

    if (decoded == null) {
      return imageBytes;
    }

    final bgColor = _getBackgroundColor(decoded);
    if (bgColor == null) {
      return Uint8List.fromList(img.encodePng(decoded));
    }

    final transparent = _makeTransparent(decoded, bgColor, _transparencyTolerance);
    return transparent;
  }

  _RgbColor? _getBackgroundColor(img.Image image) {
    if (image.hasAlpha) {
      final topLeft = image.getPixel(0, 0);
      if (topLeft.a == 0) return null;
    }

    final w = image.width;
    final h = image.height;
    final counter = <String, int>{};

    void count(img.Pixel p) {
      final key = '${p.r},${p.g},${p.b}';
      counter[key] = (counter[key] ?? 0) + 1;
    }

    count(image.getPixel(0, 0));
    count(image.getPixel(w - 1, 0));
    count(image.getPixel(0, h - 1));
    count(image.getPixel(w - 1, h - 1));

    final stepX = max(1, w ~/ 20);
    final stepY = max(1, h ~/ 20);

    for (int x = 0; x < w; x += stepX) {
      count(image.getPixel(x, 0));
      count(image.getPixel(x, h - 1));
    }
    for (int y = 0; y < h; y += stepY) {
      count(image.getPixel(0, y));
      count(image.getPixel(w - 1, y));
    }

    String mostCommon = '';
    int maxCount = 0;
    counter.forEach((key, count) {
      if (count > maxCount) {
        maxCount = count;
        mostCommon = key;
      }
    });

    if (mostCommon.isEmpty) return null;

    final parts = mostCommon.split(',');
    return _RgbColor(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
  }

  double _colorDistance(img.Pixel c1, _RgbColor c2) {
    final dr = c1.r.toInt() - c2.r;
    final dg = c1.g.toInt() - c2.g;
    final db = c1.b.toInt() - c2.b;
    return sqrt((dr * dr + dg * dg + db * db).toDouble());
  }

  Uint8List _makeTransparent(img.Image image, _RgbColor bgColor, int tolerance) {
    final rgba = image.convert(numChannels: 4);
    for (int y = 0; y < rgba.height; y++) {
      for (int x = 0; x < rgba.width; x++) {
        final pixel = rgba.getPixel(x, y);
        if (pixel.a == 0) continue;
        if (_colorDistance(pixel, bgColor) <= tolerance) {
          pixel.a = 0;
        }
      }
    }
    return Uint8List.fromList(img.encodePng(rgba));
  }

  String _sanitizeFileName(String name) {
    return name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  }

  Future<Directory> _getLogoDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(appDir.path, 'logo'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<String?> _getEpgId(String channelName) async {
    if (!_nameMapLoaded) {
      LogService.write('Logo: 加载 epg_data.json 名称映射...');
      _nameToEpgId = await EpgParser.getNameToEpgId();
      _nameMapLoaded = true;
      LogService.write('Logo: 名称映射加载完成，共 ${_nameToEpgId?.length ?? 0} 条');
    }
    final id = _nameToEpgId?[channelName];
    if (id == null) {
      LogService.write('Logo: 未找到映射: $channelName');
    }
    return id;
  }
}
