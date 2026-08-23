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

double _colorDistanceInt(int r1, int g1, int b1, int r2, int g2, int b2) {
  final dr = r1 - r2;
  final dg = g1 - g2;
  final db = b1 - b2;
  return sqrt((dr * dr + dg * dg + db * db).toDouble());
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
  
  // 补回 description，供 logo_source_dialog.dart 使用
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
  final Map<String, File?> _logoResultCache = {};
  final Map<String, File?> _epgIdLogoCache = {};

  // ---------- 原有字段 ----------
  Map<String, String>? _nameToEpgId;
  bool _nameMapLoaded = false;
  final Map<String, String> _m3uLogos = {};

  // 并发锁
  final Map<String, Future<File?>> _pendingDownloads = {};

  static const String _baseLogoUrl =
      'https://raw.githubusercontent.com/tytestelle/logo/main/ico/logo/';
  static const int _transparencyTolerance = 30;
  static const String _prefsKeySources = 'logo_sources_enabled';
  static const int _maxConcurrent = 3;

  // ==================== 同步缓存查询 ====================

  File? getLogoSync(String channelName) {
    return _logoResultCache[channelName];
  }

  File? getLogoByEpgIdSync(String? epgId) {
    if (epgId == null) return null;
    return _epgIdLogoCache[epgId];
  }

  Future<String?> getEpgIdAsync(String channelName) async {
    return await _getEpgId(channelName);
  }

  // ==================== 配置管理 ====================

  Future<List<LogoSource>> getEnabledSources() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_prefsKeySources);
    if (jsonStr == null || jsonStr.isEmpty) {
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

  /// 下载指定 URL 的图片并做透明化处理（用于 fallbackUrl）
  Future<File?> downloadAndProcess(String channelName, String url) async {
    try {
      final logoDir = await _getLogoDir();
      final safeName = '${_sanitizeFileName(channelName)}_fallback_v2.png';
      final localFile = File(p.join(logoDir.path, safeName));

      if (await localFile.exists()) {
        return localFile;
      }

      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final processed = await _processTransparency(response.bodyBytes, safeName);
        await localFile.writeAsBytes(processed);
        LogService.write('Logo: fallback 下载并处理成功 $channelName');
        return localFile;
      }
    } catch (e) {
      LogService.write('Logo: fallback 处理失败 $channelName - $e');
    }
    return null;
  }

  // ==================== 新增：获取台标（含 fallbackUrl 处理） ====================

  /// 获取台标（含 fallbackUrl 处理，所有图片强制本地处理）
  Future<File?> getLogoWithFallback(String channelName, String? fallbackUrl) async {
    // 先走正常流程（GitHub / M3U / EPG）
    var file = await getLogo(channelName);
    if (file != null) return file;

    // 正常流程失败，用 fallbackUrl 下载并处理
    if (fallbackUrl != null && fallbackUrl.isNotEmpty) {
      file = await _processFallbackUrl(channelName, fallbackUrl);
      if (file != null) {
        _logoResultCache[channelName] = file;
        return file;
      }
    }

    return null;
  }

  // ==================== 新增：处理 fallbackUrl ====================

  Future<File?> _processFallbackUrl(String channelName, String url) async {
    try {
      final logoDir = await _getLogoDir();
      final safeName = 'fb_${_sanitizeFileName(channelName)}_v3.png';
      final localFile = File(p.join(logoDir.path, safeName));

      if (await localFile.exists()) {
        return localFile;
      }

      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final processed = await _processTransparency(response.bodyBytes, safeName);
        await localFile.writeAsBytes(processed);
        LogService.write('Logo: fallback 处理成功 $channelName');
        return localFile;
      }
    } catch (e) {
      LogService.write('Logo: fallback 处理失败 $channelName - $e');
    }
    return null;
  }

  // ==================== 核心透明化处理（完全复刻 Python 脚本） ====================

  Future<Uint8List> _processTransparency(Uint8List imageBytes, String fileName) async {
    img.Image? decoded;

    // 按格式尝试解码
    try { decoded = img.decodeImage(imageBytes); } catch (_) {}
    try { decoded ??= img.decodePng(imageBytes); } catch (_) {}
    try { decoded ??= img.decodeJpg(imageBytes); } catch (_) {}
    try { decoded ??= img.decodeWebP(imageBytes); } catch (_) {}
    try { decoded ??= img.decodeGif(imageBytes); } catch (_) {}
    try { decoded ??= img.decodeBmp(imageBytes); } catch (_) {}

    // Flutter ui 兜底解码
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
      LogService.write('Logo: 无法解码 $fileName，返回原始数据');
      return imageBytes;
    }

    // 强制转 RGBA
    final rgba = decoded.convert(numChannels: 4);

    // 检测背景色
    final bgColor = _getBackgroundColor(rgba);
    LogService.write('Logo: $fileName 背景色 RGB(${bgColor.r},${bgColor.g},${bgColor.b})');

    // 强制透明化
    _forceTransparent(rgba, bgColor);
    return Uint8List.fromList(img.encodePng(rgba));
  }

  // 复刻 Python 的 get_background_color，但增强处理
  _RgbColor _getBackgroundColor(img.Image image) {
    final w = image.width;
    final h = image.height;

    final samples = <List<int>>[];

    void addSample(int x, int y) {
      final p = image.getPixel(x, y);
      if (p.a.toInt() == 0) return; // 忽略已透明像素
      samples.add([p.r.toInt(), p.g.toInt(), p.b.toInt()]);
    }

    // 四角
    addSample(0, 0);
    addSample(w - 1, 0);
    addSample(0, h - 1);
    addSample(w - 1, h - 1);

    // 边缘采样
    final stepX = max(1, w ~/ 20);
    final stepY = max(1, h ~/ 20);
    for (int x = 0; x < w; x += stepX) {
      addSample(x, 0);
      addSample(x, h - 1);
    }
    for (int y = 0; y < h; y += stepY) {
      addSample(0, y);
      addSample(w - 1, y);
    }

    // 边缘采不到（贴边台标），扩展到全图
    if (samples.length < 10) {
      final fullStepX = max(1, w ~/ 10);
      final fullStepY = max(1, h ~/ 10);
      for (int y = 0; y < h; y += fullStepY) {
        for (int x = 0; x < w; x += fullStepX) {
          final p = image.getPixel(x, y);
          if (p.a.toInt() == 0) continue;
          samples.add([p.r.toInt(), p.g.toInt(), p.b.toInt()]);
        }
      }
    }

    // 极端情况：全图透明，返回白色（处理完也是全透明，无害）
    if (samples.isEmpty) {
      return _RgbColor(255, 255, 255);
    }

    // 统计最常见颜色
    final counter = <String, int>{};
    for (final color in samples) {
      final key = '${color[0]},${color[1]},${color[2]}';
      counter[key] = (counter[key] ?? 0) + 1;
    }

    String mostCommon = '';
    int maxCount = 0;
    counter.forEach((key, count) {
      if (count > maxCount) {
        maxCount = count;
        mostCommon = key;
      }
    });

    final parts = mostCommon.split(',');
    return _RgbColor(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
  }

  // 复刻 Python 的 make_transparent，改为直接修改图像
  void _forceTransparent(img.Image image, _RgbColor bgColor) {
    final w = image.width;
    final h = image.height;
    int total = 0;
    int transparent = 0;

    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final p = image.getPixel(x, y);
        if (p.a.toInt() == 0) continue;

        total++;
        final r = p.r.toInt();
        final g = p.g.toInt();
        final b = p.b.toInt();

        // 条件1：在背景色容差内
        final dr = r - bgColor.r;
        final dg = g - bgColor.g;
        final db = b - bgColor.b;
        final dist = sqrt((dr * dr + dg * dg + db * db).toDouble());
        final inTolerance = dist <= _transparencyTolerance;

        // 条件2：无条件兜底 - 只要够白就透明（#F0F0F0 及以上）
        final isNearWhite = r >= 240 && g >= 240 && b >= 240;

        if (inTolerance || isNearWhite) {
          p.a = 0;
          transparent++;
        }
      }
    }

    LogService.write('Logo: 共 $total 个非透明像素，$transparent 个被设为透明');
  }

  // ==================== 原有 getLogo 方法（已修改缓存版本） ====================

  Future<File?> getLogo(String channelName) async {
    // 1. channelName 缓存
    if (_logoResultCache.containsKey(channelName)) {
      return _logoResultCache[channelName];
    }

    // 2. epgId 缓存
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

    // ① 改 cacheName 加版本号 v3
    final cacheName = '${epgId ?? _sanitizeFileName(channelName)}_v3.png';
    final logoDir = await _getLogoDir();
    final cacheFile = File(p.join(logoDir.path, cacheName));

    // 3. 本地文件已存在
    if (await cacheFile.exists()) {
      LogService.write('Logo: $channelName 命中本地缓存 $cacheName');
      _logoResultCache[channelName] = cacheFile;
      if (epgId != null) _epgIdLogoCache[epgId] = cacheFile;
      return cacheFile;
    }

    // 4. 正在下载中
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

  // ==================== 下载逻辑 ====================

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
