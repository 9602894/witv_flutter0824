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
}

class LogoService {
  static final LogoService _instance = LogoService._internal();
  factory LogoService() => _instance;
  LogoService._internal();

  // channelName -> File?
  final Map<String, File?> _logoResultCache = {};
  // epgId -> File?
  final Map<String, File?> _epgIdLogoCache = {};

  Map<String, String>? _nameToEpgId;
  bool _nameMapLoaded = false;
  final Map<String, String> _m3uLogos = {};

  final Map<String, Future<File?>> _pendingDownloads = {};

  static const String _baseLogoUrl =
      'https://raw.githubusercontent.com/tytestelle/sandiJMYG/main/ico/logo/';
  static const int _transparencyTolerance = 30;
  static const String _prefsKeySources = 'logo_sources_enabled';
  static const int _maxConcurrent = 3;

  // ==================== 公共 API ====================

  File? getLogoSync(String channelName) => _logoResultCache[channelName];
  File? getLogoByEpgIdSync(String? epgId) => epgId != null ? _epgIdLogoCache[epgId] : null;

  Future<String?> getEpgIdAsync(String channelName) async => _getEpgId(channelName);

  Future<List<LogoSource>> getEnabledSources() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_prefsKeySources);
    if (jsonStr == null || jsonStr.isEmpty) {
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
      return sources.isEmpty ? [LogoSource.github] : sources;
    } catch (e) {
      return [LogoSource.github];
    }
  }

  Future<void> setEnabledSources(List<LogoSource> sources) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKeySources, jsonEncode(sources.map((e) => e.name).toList()));
  }

  Future<bool> hasConfiguredSource() async {
    final sources = await getEnabledSources();
    return sources.isNotEmpty;
  }

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
        LogService.write('LogoService: 已清空所有台标缓存');
      }
    } catch (e) {}
  }

  void updateM3uLogos(Map<String, String> logos) {
    _m3uLogos.clear();
    _m3uLogos.addAll(logos);
    LogService.write('LogoService: 收到 M3U logo ${logos.length} 条');
  }

  /// 核心方法：获取台标（所有来源统一处理，统一存 logo 文件夹）
  Future<File?> getLogo(String channelName) async {
    // 1. 内存缓存
    if (_logoResultCache.containsKey(channelName)) {
      return _logoResultCache[channelName];
    }

    final epgId = await _getEpgId(channelName);
    if (epgId != null && _epgIdLogoCache.containsKey(epgId)) {
      final cached = _epgIdLogoCache[epgId];
      _logoResultCache[channelName] = cached;
      return cached;
    }

    // 2. 确定文件名（有 epgId 用 epgid.png，否则用净化后的频道名）
    final fileName = epgId != null ? '$epgId.png' : '${_sanitizeFileName(channelName)}.png';
    final logoDir = await _getLogoDir();
    final cacheFile = File(p.join(logoDir.path, fileName));

    // 3. 本地已存在
    if (await cacheFile.exists()) {
      _logoResultCache[channelName] = cacheFile;
      if (epgId != null) _epgIdLogoCache[epgId] = cacheFile;
      return cacheFile;
    }

    // 4. 正在下载中，等待
    if (_pendingDownloads.containsKey(fileName)) {
      final result = await _pendingDownloads[fileName]!;
      _logoResultCache[channelName] = result;
      if (epgId != null) _epgIdLogoCache[epgId] = result;
      return result;
    }

    // 5. 发起下载+处理
    LogService.write('Logo: $channelName 开始下载处理 -> $fileName');
    final downloadTask = _downloadAndProcess(channelName, fileName, epgId);
    _pendingDownloads[fileName] = downloadTask;

    try {
      final result = await downloadTask;
      _logoResultCache[channelName] = result;
      if (epgId != null) _epgIdLogoCache[epgId] = result;
      return result;
    } finally {
      _pendingDownloads.remove(fileName);
    }
  }

  /// 预加载
  Future<void> preloadAllLogos(List<Channel> channels) async {
    final sources = await getEnabledSources();
    if (sources.isEmpty) return;
    LogService.write('LogoService: 预加载台标，来源: ${sources.map((s) => s.displayName).join(' > ')}');

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

  // ==================== 下载+处理（核心） ====================

  Future<File?> _downloadAndProcess(String channelName, String fileName, String? epgId) async {
    final logoDir = await _getLogoDir();
    final cacheFile = File(p.join(logoDir.path, fileName));

    final sources = await getEnabledSources();
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
          final token = await ConfigService.getGitHubToken();
          final url = '$_baseLogoUrl$fileName';
          final headers = <String, String>{};
          if (token != null && token.isNotEmpty) {
            headers['Authorization'] = 'token $token';
          }
          sourceDesc = 'GitHub';
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
          final processed = await _processTransparency(imageBytes, fileName);
          await cacheFile.writeAsBytes(processed);
          LogService.write('Logo: $channelName 从 $sourceDesc 下载处理成功 -> $fileName');
          return cacheFile;
        } catch (e) {
          LogService.write('Logo: $channelName $sourceDesc 处理失败 - $e');
        }
      }
    }

    LogService.write('Logo: $channelName 所有来源失败');
    return null;
  }

  Future<Uint8List?> _fetchBytes(String url, {Map<String, String>? headers}) async {
    try {
      final response = await http.get(Uri.parse(url), headers: headers);
      if (response.statusCode == 200) return response.bodyBytes;
    } catch (e) {
      LogService.write('Logo: 下载失败 $url - $e');
    }
    return null;
  }

  // ==================== 透明化处理（完全复刻 Python 脚本） ====================

  Future<Uint8List> _processTransparency(Uint8List imageBytes, String fileName) async {
    img.Image? decoded;

    try { decoded = img.decodeImage(imageBytes); } catch (_) {}
    try { decoded ??= img.decodePng(imageBytes); } catch (_) {}
    try { decoded ??= img.decodeJpg(imageBytes); } catch (_) {}
    try { decoded ??= img.decodeWebP(imageBytes); } catch (_) {}
    try { decoded ??= img.decodeGif(imageBytes); } catch (_) {}
    try { decoded ??= img.decodeBmp(imageBytes); } catch (_) {}

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
      } catch (_) {}
    }

    if (decoded == null) {
      LogService.write('Logo: 无法解码 $fileName');
      return imageBytes;
    }

    // 完全复刻 Python 脚本逻辑
    final bgColor = _getBackgroundColor(decoded);
    LogService.write('Logo: $fileName 背景色 RGB(${bgColor.r},${bgColor.g},${bgColor.b})');

    final result = _makeTransparent(decoded, bgColor, _transparencyTolerance);
    return result;
  }

  /// 复刻 Python get_background_color：转 RGB → 边缘采样 → Counter 统计
  _RgbColor _getBackgroundColor(img.Image image) {
    final rgbImage = image.convert(numChannels: 3);
    final w = rgbImage.width;
    final h = rgbImage.height;

    final samples = <img.Pixel>[];

    // 四角
    samples.add(rgbImage.getPixel(0, 0));
    samples.add(rgbImage.getPixel(w - 1, 0));
    samples.add(rgbImage.getPixel(0, h - 1));
    samples.add(rgbImage.getPixel(w - 1, h - 1));

    // 边缘采样
    final stepX = max(1, w ~/ 20);
    final stepY = max(1, h ~/ 20);
    for (int x = 0; x < w; x += stepX) {
      samples.add(rgbImage.getPixel(x, 0));
      samples.add(rgbImage.getPixel(x, h - 1));
    }
    for (int y = 0; y < h; y += stepY) {
      samples.add(rgbImage.getPixel(0, y));
      samples.add(rgbImage.getPixel(w - 1, y));
    }

    // Counter 统计
    final counter = <String, int>{};
    for (final p in samples) {
      final key = '${p.r.toInt()},${p.g.toInt()},${p.b.toInt()}';
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

  /// 复刻 Python make_transparent：转 RGBA → 容差内透明化
  Uint8List _makeTransparent(img.Image image, _RgbColor bgColor, int tolerance) {
    final rgba = image.convert(numChannels: 4);

    for (int y = 0; y < rgba.height; y++) {
      for (int x = 0; x < rgba.width; x++) {
        final pixel = rgba.getPixel(x, y);
        if (pixel.a.toInt() == 0) continue;

        final dr = pixel.r.toInt() - bgColor.r;
        final dg = pixel.g.toInt() - bgColor.g;
        final db = pixel.b.toInt() - bgColor.b;
        final dist = sqrt((dr * dr + dg * dg + db * db).toDouble());

        if (dist <= tolerance) {
          pixel.a = 0;
        }
      }
    }

    return Uint8List.fromList(img.encodePng(rgba));
  }

  // ==================== 工具方法 ====================

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
      _nameToEpgId = await EpgParser.getNameToEpgId();
      _nameMapLoaded = true;
    }
    return _nameToEpgId?[channelName];
  }
}
