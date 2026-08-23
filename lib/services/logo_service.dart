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

  final Map<String, File?> _logoResultCache = {};
  final Map<String, File?> _epgIdLogoCache = {};

  Map<String, String>? _nameToEpgId;
  bool _nameMapLoaded = false;
  final Map<String, String> _m3uLogos = {};

  final Map<String, Future<File?>> _pendingDownloads = {};

  static const String _baseLogoUrl =
      'https://raw.githubusercontent.com/tytestelle/logo/main/ico/logo/';
  static const int _transparencyTolerance = 30;
  static const String _prefsKeySources = 'logo_sources_enabled';
  static const int _maxConcurrent = 3;

  File? getLogoSync(String channelName) => _logoResultCache[channelName];
  File? getLogoByEpgIdSync(String? epgId) => epgId != null ? _epgIdLogoCache[epgId] : null;
  Future<String?> getEpgIdAsync(String channelName) async => _getEpgId(channelName);

  Future<List<LogoSource>> getEnabledSources() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_prefsKeySources);
    if (jsonStr == null || jsonStr.isEmpty) {
      return []; // 默认不选任何来源，由用户设置
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
      return sources;
    } catch (e) {
      return [];
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

  /// 彻底清空所有台标缓存（内存 + 磁盘 + 映射）
  Future<void> clearLogoCache() async {
    try {
      final logoDir = await _getLogoDir();
      if (await logoDir.exists()) {
        await logoDir.delete(recursive: true);
      }
      await logoDir.create(recursive: true);
      _m3uLogos.clear();
      _pendingDownloads.clear();
      _logoResultCache.clear();
      _epgIdLogoCache.clear();
      _nameToEpgId = null;
      _nameMapLoaded = false;
      LogService.write('LogoService: 已清空所有台标缓存');
    } catch (e) {
      LogService.write('LogoService: 清空缓存失败: \$e');
    }
  }

  // ==================== 加载逻辑（只读本地，绝不自动下载） ====================

  /// 获取台标（只读本地 logo 文件夹）
  /// 本地没有则返回 null，不会触发任何网络请求
  Future<File?> getLogo(String channelName, {String? fallbackUrl}) async {
    // 1. 内存缓存
    if (_logoResultCache.containsKey(channelName)) {
      return _logoResultCache[channelName];
    }

    // 2. epgId 缓存映射
    final epgId = await _getEpgId(channelName);
    if (epgId != null && _epgIdLogoCache.containsKey(epgId)) {
      final cached = _epgIdLogoCache[epgId];
      _logoResultCache[channelName] = cached;
      return cached;
    }

    // 3. 只检查本地 logo 文件夹
    final cacheName = epgId != null ? '\$epgId.png' : '\${_sanitizeFileName(channelName)}.png';
    final logoDir = await _getLogoDir();
    final cacheFile = File(p.join(logoDir.path, cacheName));

    if (await cacheFile.exists()) {
      _logoResultCache[channelName] = cacheFile;
      if (epgId != null) _epgIdLogoCache[epgId] = cacheFile;
      return cacheFile;
    }

    // 本地没有，返回 null，绝不自动下载
    return null;
  }

  /// 检查本地是否已有该频道台标
  Future<bool> hasLocalLogo(String channelName) async {
    final file = await getLogo(channelName);
    return file != null && await file.exists();
  }

  // ==================== 显式下载逻辑（用户触发） ====================

  /// 显式下载单个台标（用户设置来源后调用）
  Future<File?> downloadLogo(String channelName, {String? fallbackUrl}) async {
    final epgId = await _getEpgId(channelName);
    final cacheName = epgId != null ? '\$epgId.png' : '\${_sanitizeFileName(channelName)}.png';
    final logoDir = await _getLogoDir();
    final cacheFile = File(p.join(logoDir.path, cacheName));

    if (await cacheFile.exists()) {
      return cacheFile;
    }

    if (_pendingDownloads.containsKey(cacheName)) {
      return await _pendingDownloads[cacheName]!;
    }

    LogService.write('Logo: 开始下载 \$channelName -> \$cacheName');
    final downloadTask = _downloadFromSources(channelName, cacheName, fallbackUrl: fallbackUrl);
    _pendingDownloads[cacheName] = downloadTask;

    try {
      final result = await downloadTask;
      if (result != null) {
        _logoResultCache[channelName] = result;
        if (epgId != null) _epgIdLogoCache[epgId] = result;
      }
      return result;
    } finally {
      _pendingDownloads.remove(cacheName);
    }
  }

  /// 批量下载台标（用户确认来源后执行）
  Future<void> downloadAllLogos(List<Channel> channels) async {
    final sources = await getEnabledSources();
    if (sources.isEmpty) {
      LogService.write('Logo: 未配置台标来源，跳过下载');
      return;
    }

    LogService.write('LogoService: 开始批量下载台标，共 \${channels.length} 个频道');
    const batchSize = _maxConcurrent;
    var successCount = 0;
    var failCount = 0;

    for (var i = 0; i < channels.length; i += batchSize) {
      final batch = channels.skip(i).take(batchSize).toList();
      final results = await Future.wait(
        batch.map((ch) => downloadLogo(ch.name, fallbackUrl: ch.logoUrl)),
        eagerError: false,
      );
      for (final r in results) {
        if (r != null) successCount++;
        else failCount++;
      }
    }
    LogService.write('LogoService: 批量下载完成，成功 \$successCount，失败 \$failCount');
  }

  /// 预加载本地已有台标到内存（不触发网络）
  Future<void> preloadAllLogos(List<Channel> channels) async {
    LogService.write('LogoService: 开始预加载本地台标');
    const batchSize = _maxConcurrent;
    for (var i = 0; i < channels.length; i += batchSize) {
      final batch = channels.skip(i).take(batchSize).toList();
      await Future.wait(
        batch.map((ch) => getLogo(ch.name, fallbackUrl: ch.logoUrl)),
        eagerError: false,
      );
    }
    LogService.write('LogoService: 本地预加载完成');
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
    LogService.write('LogoService: 收到 M3U logo 映射 \${logos.length} 条');
  }

  // ==================== 内部下载实现 ====================

  Future<File?> _downloadFromSources(String channelName, String cacheName, {String? fallbackUrl}) async {
    final logoDir = await _getLogoDir();
    final cacheFile = File(p.join(logoDir.path, cacheName));

    if (await cacheFile.exists()) {
      return cacheFile;
    }

    final sources = await getEnabledSources();
    if (sources.isEmpty) {
      LogService.write('Logo: \$channelName 未配置来源，跳过下载');
      return null;
    }

    // 1. 按用户配置的来源顺序尝试
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
            fileName = '\$epgId.png';
          } else {
            fileName = '\${_sanitizeFileName(channelName)}.png';
          }
          sourceDesc = 'GitHub';
          final token = await ConfigService.getGitHubToken();
          final url = '\$_baseLogoUrl\$fileName';
          final headers = <String, String>{};
          if (token != null && token.isNotEmpty) {
            headers['Authorization'] = 'token \$token';
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
          if (source == LogoSource.github) {
            // GitHub 仓库的台标已经是透明的，直接保存
            await cacheFile.writeAsBytes(imageBytes);
            LogService.write('Logo: \$channelName 从 GitHub 直接保存 \$cacheName');
          } else {
            // M3U/EPG 来源：强制透明化处理（去白底）
            final processed = await _processTransparency(imageBytes, cacheName);
            await cacheFile.writeAsBytes(processed);
            LogService.write('Logo: \$channelName 从 \$sourceDesc 透明化处理后保存 \$cacheName');
          }
          return cacheFile;
        } catch (e) {
          LogService.write('Logo: \$channelName \$sourceDesc 处理失败 - \$e');
        }
      }
    }

    // 2. 配置来源全部失败，用 fallbackUrl 兜底
    if (fallbackUrl != null && fallbackUrl.isNotEmpty) {
      LogService.write('Logo: \$channelName 配置来源失败，尝试 fallbackUrl');
      final imageBytes = await _fetchBytes(fallbackUrl);
      if (imageBytes != null) {
        try {
          // fallback 也做透明化处理
          final processed = await _processTransparency(imageBytes, cacheName);
          await cacheFile.writeAsBytes(processed);
          LogService.write('Logo: \$channelName fallbackUrl 透明化处理后保存 \$cacheName');
          return cacheFile;
        } catch (e) {
          LogService.write('Logo: \$channelName fallbackUrl 处理失败 - \$e');
        }
      }
    }

    LogService.write('Logo: \$channelName 所有来源失败');
    return null;
  }

  Future<Uint8List?> _fetchBytes(String url, {Map<String, String>? headers}) async {
    try {
      final response = await http.get(Uri.parse(url), headers: headers);
      if (response.statusCode == 200) {
        return response.bodyBytes;
      }
    } catch (e) {
      LogService.write('Logo: 下载失败 \$url - \$e');
    }
    return null;
  }

  // ==================== 透明化处理 ====================

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
              decoded.setPixelRgba(x, y, bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3]);
            }
          }
        }
        uiImage.dispose();
      } catch (_) {}
    }

    if (decoded == null) {
      LogService.write('Logo: 无法解码 \$fileName');
      return imageBytes;
    }

    final image = decoded;

    // 提取背景色
    final bgColor = _getBackgroundColor(image);
    LogService.write('Logo: \$fileName 背景色 RGB(\${bgColor.r},\${bgColor.g},\${bgColor.b})');

    // 透明化处理
    final rgba = image.convert(numChannels: 4);
    int transparentCount = 0;

    for (int y = 0; y < rgba.height; y++) {
      for (int x = 0; x < rgba.width; x++) {
        final p = rgba.getPixel(x, y);
        if (p.a.toInt() == 0) continue;

        final dr = p.r.toInt() - bgColor.r;
        final dg = p.g.toInt() - bgColor.g;
        final db = p.b.toInt() - bgColor.b;
        final dist = sqrt((dr * dr + dg * dg + db * db).toDouble());

        if (dist <= _transparencyTolerance) {
          rgba.setPixelRgba(x, y, p.r.toInt(), p.g.toInt(), p.b.toInt(), 0);
          transparentCount++;
        }
      }
    }

    LogService.write('Logo: \$fileName \$transparentCount/\${rgba.width * rgba.height} 像素透明化');
    return Uint8List.fromList(img.encodePng(rgba));
  }

  // ==================== 辅助方法：提取背景色 ====================

  _RgbColor _getBackgroundColor(img.Image image) {
    final w = image.width;
    final h = image.height;
    final hasAlpha = image.numChannels >= 4;

    final samples = <List<int>>[];

    void addSample(int x, int y) {
      final p = image.getPixel(x, y);
      if (hasAlpha && p.a.toInt() == 0) return;
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

    // 统计出现次数最多的颜色
    final counter = <String, int>{};
    for (final color in samples) {
      final key = '\${color[0]},\${color[1]},\${color[2]}';
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

    if (mostCommon.isEmpty) {
      return _RgbColor(0, 0, 0);
    }

    final parts = mostCommon.split(',');
    return _RgbColor(
      int.parse(parts[0]),
      int.parse(parts[1]),
      int.parse(parts[2]),
    );
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
      LogService.write('Logo: 加载 epg_data.json 名称映射...');
      _nameToEpgId = await EpgParser.getNameToEpgId();
      _nameMapLoaded = true;
      LogService.write('Logo: 名称映射加载完成，共 \${_nameToEpgId?.length ?? 0} 条');
    }
    final id = _nameToEpgId?[channelName];
    if (id == null) {
      LogService.write('Logo: 未找到映射: \$channelName');
    }
    return id;
  }
}
