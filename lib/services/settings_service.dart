import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart' as path_provider;
import '../models/subscription.dart';
import 'dart:convert';
import 'log_service.dart';
import 'config_service.dart';  // 新增导入

class SettingsService extends ChangeNotifier {
  List<Subscription> _subscriptions = [];
  bool _needsRefresh = false;
  int _decoderIndex = 0;
  String? _lastChannel;
  bool _autoReconnect = true; // 默认开启重连

  List<Subscription> get subscriptions => _subscriptions;
  bool get needsRefresh => _needsRefresh;
  int get decoderIndex => _decoderIndex;
  String? get lastChannel => _lastChannel;
  bool get autoReconnect => _autoReconnect;

  SettingsService() {
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final subsJson = prefs.getString('subscriptions');
      if (subsJson != null) {
        final list = jsonDecode(subsJson) as List;
        _subscriptions = list.map((e) => Subscription.fromJson(e)).toList();
      }

      // ===== 新增：首次安装时从 configuration.json 导入预置订阅源 =====
      if (_subscriptions.isEmpty) {
        final config = await ConfigService.getConfig();
        final inner = config['Configuration'] as Map<String, dynamic>?;
        final liveUrls = inner?['LIVE_URLS'] as String?;
        if (liveUrls != null && liveUrls.isNotEmpty) {
          _subscriptions = _parseConfigUrls(liveUrls);
          await saveSubscriptions();
        }
      }
      // =================================================================

      _decoderIndex = prefs.getInt('decoder_index') ?? 0;
      _lastChannel = prefs.getString('last_channel');
      _autoReconnect = prefs.getBool('auto_reconnect') ?? true;
      await LogService.write('SettingsService: 加载订阅源 ${_subscriptions.length} 条，解码器索引 $_decoderIndex，重连: $_autoReconnect');
    } catch (e, stack) {
      await LogService.writeCrashLog(e, stack);
    }
    notifyListeners();
  }

  // 解析 configuration.json 的 URL 格式：地址$名称||地址$名称
  List<Subscription> _parseConfigUrls(String urlsStr) {
    final result = <Subscription>[];
    final parts = urlsStr.split('||');
    for (final part in parts) {
      final trimmed = part.trim();
      if (trimmed.isEmpty) continue;
      final idx = trimmed.lastIndexOf('\$');
      if (idx > 0) {
        final url = trimmed.substring(0, idx).trim();
        final name = trimmed.substring(idx + 1).trim();
        if (url.isNotEmpty && name.isNotEmpty) {
          result.add(Subscription(name: name, url: url, selected: true));
        }
      } else {
        result.add(Subscription(name: '预置源', url: trimmed, selected: true));
      }
    }
    return result;
  }

  Future<void> saveSubscriptions() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = jsonEncode(_subscriptions.map((e) => e.toJson()).toList());
      await prefs.setString('subscriptions', json);
      await LogService.write('SettingsService: 订阅源已保存 ${_subscriptions.length} 条');
    } catch (e) {
      await LogService.write('SettingsService: 保存订阅源失败: $e');
    }
  }

  void addSubscription(Subscription sub) {
    _subscriptions.add(sub);
    saveSubscriptions();
    _needsRefresh = true;
    notifyListeners();
  }

  void removeSubscription(Subscription sub) {
    _subscriptions.remove(sub);
    saveSubscriptions();
    _needsRefresh = true;
    notifyListeners();
  }

  void toggleSelected(Subscription sub) {
    sub.selected = !sub.selected;
    saveSubscriptions();
    _needsRefresh = true;
    notifyListeners();
  }

  void markNeedsRefresh() {
    _needsRefresh = true;
    notifyListeners();
  }

  void clearRefreshFlag() {
    _needsRefresh = false;
  }

  void setDecoderIndex(int index) async {
    _decoderIndex = index;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('decoder_index', index);
    await LogService.write('解码器切换为: $index');
    notifyListeners();
  }

  void saveLastChannel(String channelName) async {
    _lastChannel = channelName;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_channel', channelName);
    await LogService.write('保存上次频道: $channelName');
  }

  String? getLastChannel() => _lastChannel;

  void setAutoReconnect(bool value) async {
    _autoReconnect = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_reconnect', value);
    await LogService.write('断线重连设置为: $value');
    notifyListeners();
  }

  // 获取订阅源缓存目录
  static Future<Directory> getCacheDir() async {
    final appDocDir = await path_provider.getApplicationDocumentsDirectory();
    final cacheDir = Directory('${appDocDir.path}/playlist_cache');
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }
    return cacheDir;
  }
}
