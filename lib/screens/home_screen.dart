import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import '../services/settings_service.dart';
import '../services/config_service.dart';
import '../services/playlist_parser.dart';
import '../services/epg_parser.dart';
import '../services/log_service.dart';
import '../services/logo_service.dart';
import '../services/epg_database_service.dart'; // ✅ 新增
import '../models/channel.dart';
import '../models/epg_program.dart';
import '../models/subscription.dart';
import '../widgets/ijk_player_widget.dart';
import '../widgets/channel_list.dart';
import '../widgets/group_list.dart';
import '../widgets/schedule_view.dart';
import 'settings_screen.dart';

// ============================================================
// HomeScreen —— 酷9方案优化版：播放零阻塞，EPG 秒级全量加载
// ============================================================

class HomeScreen extends StatefulWidget {
  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // ---------- 数据 ----------
  List<Channel> channels = [];
  List<String> groups = [];
  Channel? currentChannel;
  String? currentGroup;
  String? currentSubName;

  // ---------- 窗口状态 ----------
  bool showChannelList = false;
  bool isScheduleMode = false;
  bool _showEpgInfo = false;
  bool isEditMode = false;
  bool _showRightMenu = false;

  // ---------- 宽度控制 ----------
  double subWeight = 0.2;
  double groupWeight = 0.2;
  double channelWeight = 0.6;
  double scheduleGroupWeight = 0.25;
  double scheduleChannelWeight = 0.35;
  double scheduleWeight = 0.4;

  // ---------- 按钮偏移 ----------
  Offset scheduleModeButtonOffset = Offset(714.8865763346365, 7.9911295572917425);
  Offset channelListButtonOffset = Offset(-133.9163004557305, -4.6614786783854925);

  double _scheduleButtonInitTop = 0;
  double _channelButtonInitTop = 0;

  // ---------- EPG（全局缓存，分组切换不复读） ----------
  // ❌ 删除内存缓存字段：Map<String, List<EpgProgram>> epgMap = {};
  // ✅ 新增当前/下个节目字段
  EpgProgram? _currentEpgProgram;
  EpgProgram? _nextEpgProgram;
  bool _isEpgUpdating = false;
  bool _isEpgLoading = false;

  // ---------- 订阅 ----------
  Map<String, List<Channel>>? _fullGroupMap;
  bool _hasSubscriptions = false;
  bool _isUpdatingSubscription = false;
  bool isLoading = true;

  // ---------- 配置 ----------
  late File _layoutConfigFile;
  Timer? _epgUpdateTimer;   // 6小时检查更新
  Timer? _epgInfoTimer;     // 每秒刷新当前节目信息
  final LogoService _logoService = LogoService();

  // ---------- 播放器重连 ----------
  Timer? _retryTimer;
  Channel? _retryChannel;
  Key? _playerKey;
  double currentSpeed = 0;

  // ---------- 遥控器 ----------
  final FocusNode _focusNode = FocusNode();
  int _selectedIndex = -1;
  String _digitBuffer = '';
  Timer? _digitTimer;

  // ============================================================
  // 工具函数（已修改：UTC 时间 + 北京时间显示）
  // ============================================================

  DateTime _getNow() => DateTime.now().toUtc();

  String _formatTime(DateTime time) {
    final beijing = time.add(const Duration(hours: 8));
    return '${beijing.hour.toString().padLeft(2, '0')}:${beijing.minute.toString().padLeft(2, '0')}';
  }

  String _getDate(DateTime time) {
    final beijing = time.add(const Duration(hours: 8));
    return '${beijing.year}-${beijing.month.toString().padLeft(2, '0')}-${beijing.day.toString().padLeft(2, '0')}';
  }

  // ============================================================
  // 生命周期
  // ============================================================

  @override
  void initState() {
    super.initState();
    _initAsync();
  }

  Future<void> _initAsync() async {
    LogService.write('主页初始化');
    await _initLayoutConfigFile();
    await _loadLayoutConfig();
    _initEpgScheduler();
    await _init();
    _startEpgInfoTimer(); // ✅ 启动每秒刷新定时器
  }

  // ========== 布局配置 ==========

  Future<void> _initLayoutConfigFile() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _layoutConfigFile = File('${dir.path}/layout_config.json');
      LogService.write('配置文件路径: ${_layoutConfigFile.path}');
      if (!await _layoutConfigFile.exists()) {
        await _saveLayoutConfig();
        LogService.write('创建默认配置文件');
      }
    } catch (e, stack) {
      LogService.writeCrashLog(e, stack);
    }
  }

  Future<void> _loadLayoutConfig() async {
    try {
      if (await _layoutConfigFile.exists()) {
        final content = await _layoutConfigFile.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;
        subWeight = json['subWeight']?.toDouble() ?? subWeight;
        groupWeight = json['groupWeight']?.toDouble() ?? groupWeight;
        channelWeight = json['channelWeight']?.toDouble() ?? channelWeight;
        scheduleGroupWeight = json['scheduleGroupWeight']?.toDouble() ?? scheduleGroupWeight;
        scheduleChannelWeight = json['scheduleChannelWeight']?.toDouble() ?? scheduleChannelWeight;
        scheduleWeight = json['scheduleWeight']?.toDouble() ?? scheduleWeight;
        scheduleModeButtonOffset = Offset(
          json['scheduleModeButtonDx']?.toDouble() ?? scheduleModeButtonOffset.dx,
          json['scheduleModeButtonDy']?.toDouble() ?? scheduleModeButtonOffset.dy,
        );
        channelListButtonOffset = Offset(
          json['channelListButtonDx']?.toDouble() ?? channelListButtonOffset.dx,
          json['channelListButtonDy']?.toDouble() ?? channelListButtonOffset.dy,
        );
        LogService.write('布局配置加载成功');
      }
    } catch (e, stack) {
      LogService.writeCrashLog(e, stack);
    }
  }

  Future<void> _saveLayoutConfig() async {
    try {
      final json = {
        'subWeight': subWeight,
        'groupWeight': groupWeight,
        'channelWeight': channelWeight,
        'scheduleGroupWeight': scheduleGroupWeight,
        'scheduleChannelWeight': scheduleChannelWeight,
        'scheduleWeight': scheduleWeight,
        'scheduleModeButtonDx': scheduleModeButtonOffset.dx,
        'scheduleModeButtonDy': scheduleModeButtonOffset.dy,
        'channelListButtonDx': channelListButtonOffset.dx,
        'channelListButtonDy': channelListButtonOffset.dy,
      };
      await _layoutConfigFile.writeAsString(jsonEncode(json));
      LogService.write('布局配置已保存');
    } catch (e, stack) {
      LogService.writeCrashLog(e, stack);
    }
  }

  void _exitEditMode() {
    setState(() => isEditMode = false);
    _saveLayoutConfig();
  }

  @override
  void dispose() {
    _epgUpdateTimer?.cancel();
    _epgInfoTimer?.cancel();
    _retryTimer?.cancel();
    _digitTimer?.cancel();
    _focusNode.dispose();
    _saveLayoutConfig();
    super.dispose();
  }

  // ========== EPG 调度（后台静默，绝不阻塞播放） ==========

  void _initEpgScheduler() {
    _epgUpdateTimer = Timer.periodic(const Duration(hours: 6), (_) {
      _checkEpgUpdate();
    });
  }

  Future<void> _checkEpgUpdate() async {
    if (_isEpgUpdating) return;
    _isEpgUpdating = true;
    try {
      final updated = await EpgParser.checkForUpdate();
      if (updated) {
        LogService.write('EPG 已更新，刷新当前节目信息');
        // ✅ 更新后刷新当前显示的节目信息
        await _updateEpgInfo();
      }
    } catch (e) {
      LogService.write('EPG 更新检查失败: $e');
    } finally {
      _isEpgUpdating = false;
    }
  }

  // ============================================================
  // EPG 加载（核心优化：一次性导入数据库）
  // ============================================================

  /// 从数据库或 JSON 文件加载 EPG 数据（替换原 _loadAllEpg）
  Future<void> _loadAllEpg() async {
    try {
      final isDbEmpty = await EpgDatabaseService.isEmpty();
      if (!isDbEmpty) {
        LogService.write('EPG: 数据库已有数据，跳过加载');
        return;
      }

      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/epg_cache.json');

      if (await file.exists()) {
        final jsonString = await file.readAsString();
        final jsonData = jsonDecode(jsonString);
        final programs = (jsonData['programs'] as Map<String, dynamic>).map(
          (k, v) => MapEntry(k, (v as List).map((e) => EpgProgram.fromJson(e)).toList()),
        );
        final icons = (jsonData['icons'] as Map<String, dynamic>).cast<String, String>();
        await EpgDatabaseService.insertPrograms(programs, icons);
        LogService.write('EPG: JSON 缓存已导入数据库');
      } else {
        // 从 assets 加载（首次启动）
        final epgString = await rootBundle.loadString('assets/epg_data.json');
        final jsonData = jsonDecode(epgString);
        final programs = (jsonData['programs'] as Map<String, dynamic>).map(
          (k, v) => MapEntry(k, (v as List).map((e) => EpgProgram.fromJson(e)).toList()),
        );
        final icons = (jsonData['icons'] as Map<String, dynamic>).cast<String, String>();
        await EpgDatabaseService.insertPrograms(programs, icons);
        LogService.write('EPG: assets 已导入数据库');
      }
    } catch (e) {
      LogService.write('加载EPG失败: $e');
    }
  }

  // ============================================================
  // EPG 查询（数据库版）
  // ============================================================

  Future<EpgProgram?> _getCurrentProgram(String channelName) async {
    final now = _getNow(); // UTC
    final programs = await EpgDatabaseService.getCurrentPrograms(channelName, now);
    return programs.isNotEmpty ? programs.first : null;
  }

  Future<EpgProgram?> _getNextProgram(String channelName) async {
    final now = _getNow(); // UTC
    return await EpgDatabaseService.getNextProgram(channelName, now);
  }

  /// 刷新当前频道的节目信息（异步，更新状态）
  Future<void> _updateEpgInfo() async {
    if (currentChannel == null) return;
    final current = await _getCurrentProgram(currentChannel!.name);
    final next = await _getNextProgram(currentChannel!.name);
    if (mounted) {
      setState(() {
        _currentEpgProgram = current;
        _nextEpgProgram = next;
      });
    }
  }

  // ============================================================
  // 播放器重连
  // ============================================================

  void _scheduleRetry() {
    _retryTimer?.cancel();
    _retryChannel = currentChannel;
    if (_retryChannel == null) return;

    LogService.write('播放器断线，5秒后重连: ${_retryChannel!.name}');
    _retryTimer = Timer(const Duration(seconds: 5), () {
      if (currentChannel == _retryChannel && currentChannel != null) {
        LogService.write('自动重连: ${currentChannel!.name}');
        setState(() => currentChannel = null);
        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted && _retryChannel != null) {
            setState(() {
              _playerKey = UniqueKey();
              currentChannel = _retryChannel;
            });
          }
        });
      } else {
        LogService.write('自动重连已取消（频道已切换）');
      }
      _retryTimer = null;
    });
  }

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryChannel = null;
  }

  // ============================================================
  // 修改后的 _switchChannel —— 直接赋值，不复建 PlatformView，并更新 EPG 信息
  // ============================================================
  void _switchChannel(Channel ch) {
    _cancelRetry();
    _digitBuffer = '';
    _digitTimer?.cancel();
    LogService.write('选择频道: ${ch.name}');
    setState(() {
      currentChannel = ch;
      _showEpgInfo = true;
      _selectedIndex = channels.indexOf(ch);
    });
    Provider.of<SettingsService>(context, listen: false).saveLastChannel(ch.name);
    _updateEpgInfo(); // 异步更新，不阻塞
  }

  // ============================================================
  // 分组切换（❌ 不再调用 _loadAllEpg，EPG 已全局缓存）
  // ============================================================

  void _switchToGroup(String groupName) {
    if (_fullGroupMap == null || _fullGroupMap!.isEmpty) {
      LogService.write('错误：_fullGroupMap 为空');
      return;
    }
    final groupChannels = _fullGroupMap![groupName];
    if (groupChannels == null || groupChannels.isEmpty) {
      LogService.write('分组 $groupName 不存在或为空');
      return;
    }
    _cancelRetry();
    _digitBuffer = '';
    _digitTimer?.cancel();

    setState(() {
      currentGroup = groupName;
      channels = groupChannels;
      if (currentChannel != null && channels.contains(currentChannel)) {
        _selectedIndex = channels.indexOf(currentChannel!);
      } else {
        _selectedIndex = -1;
      }
    });

    // 分组切换不复读 EPG，但可刷新当前分组台标
    _logoService.preloadAllLogos(channels);
    LogService.write('切换到分组: $groupName，频道数: ${channels.length}');
    // 刷新当前频道 EPG 信息（若当前频道存在）
    if (currentChannel != null) {
      _updateEpgInfo();
    }
  }

  // ============================================================
  // 订阅源加载
  // ============================================================

  Future<void> _loadSubscriptionData(Subscription sub) async {
    try {
      LogService.write('加载订阅源数据: ${sub.name}');
      final url = sub.url;
      final cacheFile = await PlaylistParser.getCacheFile(url, sub.name);

      // 1. 先读缓存立即显示（秒开）
      if (await cacheFile.exists()) {
        try {
          final content = await cacheFile.readAsString();
          final groupMap = PlaylistParser.parseFromString(content);
          if (groupMap.isNotEmpty) {
            LogService.write('缓存秒开: ${sub.name}');
            _applyGroupMap(groupMap, sub.name);
          }
        } catch (e) {
          LogService.write('缓存解析失败: $e');
        }
      }

      // 2. 缓存不存在或为空，则从网络加载
      if (!await cacheFile.exists() || channels.isEmpty) {
        LogService.write('网络加载订阅源...');
        final groupMap = await PlaylistParser.parseFromUrl(url);
        if (groupMap.isNotEmpty) {
          await PlaylistParser.saveCache(groupMap, url, sub.name);
          _applyGroupMap(groupMap, sub.name);
          LogService.write('网络加载成功');
        } else {
          LogService.write('网络返回空数据');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('订阅源加载失败，请检查网络')),
            );
          }
        }
        return;
      }

      // 3. 后台静默更新（已有缓存时，2秒后检查更新）
      if (!_isUpdatingSubscription) {
        _isUpdatingSubscription = true;
        LogService.write('后台静默更新订阅源...');
        Future.delayed(const Duration(seconds: 2), () async {
          try {
            final newMap = await PlaylistParser.parseFromUrl(url);
            if (newMap.isNotEmpty) {
              final oldCount = _fullGroupMap?.values.expand((l) => l).length ?? 0;
              final newCount = newMap.values.expand((l) => l).length;
              if (oldCount != newCount || newMap.keys.length != groups.length) {
                LogService.write('后台更新检测到变化，刷新列表');
                await PlaylistParser.saveCache(newMap, url, sub.name);
                if (mounted && currentSubName == sub.name) {
                  _applyGroupMap(newMap, sub.name);
                }
              } else {
                LogService.write('后台更新无变化');
              }
            }
          } catch (e) {
            LogService.write('后台更新失败: $e');
          } finally {
            _isUpdatingSubscription = false;
          }
        });
      }
    } catch (e, stack) {
      LogService.writeCrashLog('加载订阅源异常: $e', stack);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载订阅源失败: $e')),
        );
      }
    }
  }

  // ============================================================
  // 应用分组映射（修复 null 安全，EPG 异步加载不阻塞）
  // ============================================================

  void _applyGroupMap(Map<String, List<Channel>> groupMap, String subName) {
    if (groupMap.isEmpty) {
      LogService.write('错误：解析出的分组为空');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('订阅源解析失败，请检查URL是否正确')),
        );
      }
      return;
    }

    // 提取 m3u 台标
    final m3uLogos = <String, String>{};
    for (final list in groupMap.values) {
      for (final ch in list) {
        if (ch.logoUrl != null && ch.logoUrl!.isNotEmpty) {
          m3uLogos[ch.name] = ch.logoUrl!;
        }
      }
    }
    _logoService.updateM3uLogos(m3uLogos);

    _fullGroupMap = groupMap;

    setState(() {
      groups = groupMap.keys.toList();
      if (groups.isNotEmpty) {
        if (currentGroup == null || !groups.contains(currentGroup)) {
          currentGroup = groups.first;
        }
        final groupChannels = groupMap[currentGroup];
        if (groupChannels != null && groupChannels.isNotEmpty) {
          channels = groupChannels;
          if (currentChannel == null && channels.isNotEmpty) {
            final lastChannel = Provider.of<SettingsService>(context, listen: false).getLastChannel();
            if (lastChannel != null) {
              Channel? found;
              for (final list in groupMap.values) {
                try {
                  found = list.firstWhere((ch) => ch.name == lastChannel);
                  break;
                } catch (_) {
                  // firstWhere 未找到会抛异常，继续下一组
                }
              }
              if (found != null) {
                currentChannel = found;
                _selectedIndex = channels.indexOf(found);
              } else {
                currentChannel = channels.first;
                _selectedIndex = 0;
              }
            } else {
              currentChannel = channels.first;
              _selectedIndex = 0;
            }
            _showEpgInfo = true;
          } else if (currentChannel != null && channels.contains(currentChannel)) {
            _selectedIndex = channels.indexOf(currentChannel!);
          } else {
            _selectedIndex = -1;
          }
        } else {
          // 当前分组为空，找第一个非空分组
          for (final g in groups) {
            final chs = groupMap[g];
            if (chs != null && chs.isNotEmpty) {
              currentGroup = g;
              channels = chs;
              break;
            }
          }
        }
      } else {
        LogService.write('警告：没有分组');
        return;
      }
      currentSubName = subName;
    });

    // ✅ 关键优化：EPG 在后台异步加载，不阻塞分组显示和播放
    _loadAllEpg();
    // 加载完成后刷新当前频道信息
    if (currentChannel != null) {
      _updateEpgInfo();
    }
    LogService.write('分组数据应用完成，分组数: ${groups.length}，频道数: ${channels.length}');
  }

  // ============================================================
  // 遥控器按键处理
  // ============================================================

  void _handleKeyEvent(RawKeyEvent event) {
    if (event is! RawKeyDownEvent) return;
    if (!showChannelList || isEditMode || isScheduleMode) return;

    final key = event.logicalKey;

    // 数字键（0-9）
    final digitKeys = [
      LogicalKeyboardKey.digit0, LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2, LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4, LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.digit6, LogicalKeyboardKey.digit7,
      LogicalKeyboardKey.digit8, LogicalKeyboardKey.digit9,
    ];
    if (digitKeys.contains(key)) {
      _digitTimer?.cancel();
      _digitBuffer += key.keyLabel;
      LogService.write('数字输入: $_digitBuffer');
      _digitTimer = Timer(const Duration(milliseconds: 1500), () {
        _jumpToChannelNumber(_digitBuffer);
        _digitBuffer = '';
      });
      return;
    }

    if (_digitBuffer.isNotEmpty) {
      _digitTimer?.cancel();
      _jumpToChannelNumber(_digitBuffer);
      _digitBuffer = '';
    }

    if (channels.isEmpty) return;

    if (key == LogicalKeyboardKey.arrowUp) {
      setState(() {
        _selectedIndex = _selectedIndex > 0 ? _selectedIndex - 1 : channels.length - 1;
      });
    } else if (key == LogicalKeyboardKey.arrowDown) {
      setState(() {
        _selectedIndex = _selectedIndex < channels.length - 1 ? _selectedIndex + 1 : 0;
      });
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      if (groups.isNotEmpty) {
        final currentIdx = groups.indexOf(currentGroup!);
        final prevIdx = (currentIdx - 1 + groups.length) % groups.length;
        _switchToGroup(groups[prevIdx]);
      }
    } else if (key == LogicalKeyboardKey.arrowRight) {
      if (groups.isNotEmpty) {
        final currentIdx = groups.indexOf(currentGroup!);
        final nextIdx = (currentIdx + 1) % groups.length;
        _switchToGroup(groups[nextIdx]);
      }
    } else if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.select) {
      if (_selectedIndex >= 0 && _selectedIndex < channels.length) {
        _switchChannel(channels[_selectedIndex]);
      }
    }
  }

  void _jumpToChannelNumber(String digits) {
    if (digits.isEmpty) return;
    final targetNumber = int.tryParse(digits);
    if (targetNumber == null) return;

    Channel? found;
    for (final ch in channels) {
      if (ch.number == targetNumber) {
        found = ch;
        break;
      }
    }
    if (found != null) {
      _switchChannel(found);
      LogService.write('数字跳转: ${found.name} (${found.number})');
    } else {
      LogService.write('未找到频道号: $targetNumber');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('未找到频道号 $targetNumber')),
      );
    }
  }

  // ============================================================
  // 构建 UI
  // ============================================================

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    _scheduleButtonInitTop = (screenHeight - 80) / 2;
    _channelButtonInitTop = (screenHeight - 80) / 2;

    if (currentChannel != null && channels.isNotEmpty) {
      final idx = channels.indexOf(currentChannel!);
      if (idx != _selectedIndex && idx >= 0) {
        _selectedIndex = idx;
      }
    }

    // 空 EPG Map（ChannelList 和 ScheduleView 已改为从数据库读取，此处仅作占位）
    const emptyEpgMap = <String, List<EpgProgram>>{};

    return RawKeyboardListener(
      focusNode: _focusNode,
      onKey: _handleKeyEvent,
      child: WillPopScope(
        onWillPop: () async {
          if (_showEpgInfo) {
            setState(() => _showEpgInfo = false);
            return false;
          }
          if (isScheduleMode) {
            setState(() => isScheduleMode = false);
            return false;
          }
          if (showChannelList) {
            setState(() => showChannelList = false);
            return false;
          }
          if (_showRightMenu) {
            setState(() => _showRightMenu = false);
            return false;
          }
          final shouldExit = await showDialog<bool>(
            context: context,
            builder: (_) => AlertDialog(
              title: const Text('提示'),
              content: const Text('确定要退出应用吗？'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('确定'),
                ),
              ],
            ),
          );
          if (shouldExit == true) exit(0);
          return false;
        },
        child: Scaffold(
          body: Stack(
            children: [
              // ---------- 播放器 ----------
              if (currentChannel != null && currentChannel!.url.isNotEmpty)
                Positioned.fill(
                  child: IjkPlayerWidget(
                    key: _playerKey,
                    url: currentChannel!.url,
                    decoderIndex: Provider.of<SettingsService>(context, listen: false).decoderIndex,
                    onError: () {
                      LogService.write('播放器错误回调: ${currentChannel?.name}');
                      _scheduleRetry();
                    },
                    onSpeedUpdate: (speed) {
                      if (mounted) setState(() => currentSpeed = speed);
                    },
                  ),
                ),

              // ---------- 左侧点击区域 ----------
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: 40,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () {
                    LogService.write('左侧点击事件触发');
                    setState(() {
                      if (isScheduleMode) {
                        isScheduleMode = false;
                        showChannelList = true;
                      } else {
                        showChannelList = !showChannelList;
                      }
                      if (showChannelList) {
                        _showRightMenu = false;
                        _showEpgInfo = false;
                        _focusNode.requestFocus();
                      }
                    });
                  },
                  child: Container(color: Colors.transparent),
                ),
              ),

              // ---------- 频道列表模式 ----------
              if (showChannelList && !isScheduleMode)
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: MediaQuery.of(context).size.width * 0.7,
                  child: Container(
                    color: Colors.transparent,
                    child: Row(
                      children: [
                        Expanded(
                          flex: (subWeight * 100).toInt(),
                          child: _buildSubscriptionList(),
                        ),
                        _buildDragBar(
                          onDrag: (delta) {
                            setState(() {
                              double newSub = subWeight + delta;
                              double newGroup = groupWeight - delta;
                              if (newSub < 0.05) newSub = 0.05;
                              if (newGroup < 0.05) newGroup = 0.05;
                              subWeight = newSub;
                              groupWeight = newGroup;
                              channelWeight = 1 - subWeight - groupWeight;
                              if (channelWeight < 0.05) {
                                channelWeight = 0.05;
                                final total = subWeight + groupWeight;
                                subWeight = subWeight / total * 0.95;
                                groupWeight = groupWeight / total * 0.95;
                              }
                            });
                          },
                          isEditMode: isEditMode,
                        ),
                        Expanded(
                          flex: (groupWeight * 100).toInt(),
                          child: _buildGroupList(),
                        ),
                        _buildDragBar(
                          onDrag: (delta) {
                            setState(() {
                              double newGroup = groupWeight + delta;
                              double newChannel = channelWeight - delta;
                              if (newGroup < 0.05) newGroup = 0.05;
                              if (newChannel < 0.05) newChannel = 0.05;
                              groupWeight = newGroup;
                              channelWeight = newChannel;
                              subWeight = 1 - groupWeight - channelWeight;
                              if (subWeight < 0.05) {
                                subWeight = 0.05;
                                final total = groupWeight + channelWeight;
                                groupWeight = groupWeight / total * 0.95;
                                channelWeight = channelWeight / total * 0.95;
                              }
                            });
                          },
                          isEditMode: isEditMode,
                        ),
                        Expanded(
                          flex: (channelWeight * 100).toInt(),
                          child: Stack(
                            children: [
                              Positioned.fill(
                                child: ChannelList(
                                  channels: channels,
                                  selectedChannel: currentChannel,
                                  onSelect: _switchChannel,
                                  epgMap: emptyEpgMap, // 不再使用，改为数据库查询
                                  showChannelNumber: false,
                                  showLogo: true,
                                ),
                              ),
                              Positioned(
                                right: 20 - channelListButtonOffset.dx,
                                top: _channelButtonInitTop + channelListButtonOffset.dy,
                                child: GestureDetector(
                                  onPanUpdate: (details) {
                                    if (!isEditMode) return;
                                    setState(() {
                                      channelListButtonOffset += details.delta;
                                    });
                                  },
                                  onTap: () {
                                    setState(() {
                                      isScheduleMode = true;
                                      showChannelList = false;
                                    });
                                  },
                                  child: Container(
                                    width: 26,
                                    height: 80,
                                    color: Colors.transparent,
                                    child: const Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Text('节', style: TextStyle(color: Colors.white, fontSize: 13)),
                                        Text('目', style: TextStyle(color: Colors.white, fontSize: 13)),
                                        Text('单', style: TextStyle(color: Colors.white, fontSize: 13)),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              // ---------- 节目单模式 ----------
              if (isScheduleMode)
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: MediaQuery.of(context).size.width * 0.7,
                  child: Stack(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            flex: (scheduleGroupWeight * 100).toInt(),
                            child: _buildGroupList(),
                          ),
                          _buildDragBar(
                            onDrag: (delta) {
                              setState(() {
                                double newGroup = scheduleGroupWeight + delta;
                                double newChannel = scheduleChannelWeight - delta;
                                if (newGroup < 0.05) newGroup = 0.05;
                                if (newChannel < 0.05) newChannel = 0.05;
                                scheduleGroupWeight = newGroup;
                                scheduleChannelWeight = newChannel;
                                scheduleWeight = 1 - newGroup - newChannel;
                                if (scheduleWeight < 0.05) {
                                  scheduleWeight = 0.05;
                                  final total = newGroup + newChannel;
                                  scheduleGroupWeight = scheduleGroupWeight / total * 0.95;
                                  scheduleChannelWeight = scheduleChannelWeight / total * 0.95;
                                }
                              });
                            },
                            isEditMode: isEditMode,
                          ),
                          Expanded(
                            flex: (scheduleChannelWeight * 100).toInt(),
                            child: ChannelList(
                              channels: channels,
                              selectedChannel: currentChannel,
                              onSelect: _switchChannel,
                              epgMap: emptyEpgMap, // 不再使用
                              showChannelNumber: false,
                              showLogo: true,
                            ),
                          ),
                          _buildDragBar(
                            onDrag: (delta) {
                              setState(() {
                                double newChannel = scheduleChannelWeight + delta;
                                double newSchedule = scheduleWeight - delta;
                                if (newChannel < 0.05) newChannel = 0.05;
                                if (newSchedule < 0.05) newSchedule = 0.05;
                                scheduleChannelWeight = newChannel;
                                scheduleWeight = newSchedule;
                                scheduleGroupWeight = 1 - newChannel - newSchedule;
                                if (scheduleGroupWeight < 0.05) {
                                  scheduleGroupWeight = 0.05;
                                  final total = newChannel + newSchedule;
                                  scheduleChannelWeight = scheduleChannelWeight / total * 0.95;
                                  scheduleWeight = scheduleWeight / total * 0.95;
                                }
                              });
                            },
                            isEditMode: isEditMode,
                          ),
                          Expanded(
                            flex: (scheduleWeight * 100).toInt(),
                            child: ScheduleView(
                              channels: channels,
                              selectedChannel: currentChannel,
                              epgMap: emptyEpgMap, // 不再使用
                              onSelectChannel: _switchChannel,
                              leftWeight: 0.3,
                              rightWeight: 0.7,
                              onLeftWeightChanged: (_) {},
                              isEditMode: isEditMode,
                              showLeft: false,
                              logoService: _logoService,
                            ),
                          ),
                        ],
                      ),
                      Positioned(
                        left: 8 + scheduleModeButtonOffset.dx,
                        top: _scheduleButtonInitTop + scheduleModeButtonOffset.dy,
                        child: GestureDetector(
                          onPanUpdate: (details) {
                            if (!isEditMode) return;
                            setState(() {
                              scheduleModeButtonOffset += details.delta;
                            });
                          },
                          onTap: () {
                            setState(() {
                              isScheduleMode = false;
                              showChannelList = true;
                            });
                          },
                          child: Container(
                            width: 26,
                            height: 80,
                            color: Colors.transparent,
                            child: const Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text('频', style: TextStyle(color: Colors.white, fontSize: 13)),
                                Text('道', style: TextStyle(color: Colors.white, fontSize: 13)),
                                Text('组', style: TextStyle(color: Colors.white, fontSize: 13)),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

              // ---------- EPG 信息浮窗（使用数据库状态） ----------
              if (_showEpgInfo && currentChannel != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: MediaQuery.of(context).size.height * 0.15,
                  child: Center(
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 500),
                      padding: const EdgeInsets.all(16),
                      decoration: const BoxDecoration(color: Colors.transparent),
                      child: _buildEpgInfoWithLogo(), // 不再传入 channel
                    ),
                  ),
                ),

              // ---------- 右侧菜单 ----------
              if (_showRightMenu)
                Positioned(
                  top: 0,
                  right: 0,
                  bottom: 0,
                  width: MediaQuery.of(context).size.width * 0.12,
                  child: Container(
                    color: Colors.transparent,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _buildMenuItem(Icons.settings, '设置', () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => SettingsScreen()),
                          ).then((_) => setState(() {}));
                          setState(() => _showRightMenu = false);
                        }),
                        _buildMenuItem(Icons.edit, '编辑', () {
                          if (isEditMode) {
                            _exitEditMode();
                          } else {
                            setState(() => isEditMode = true);
                          }
                          setState(() => _showRightMenu = false);
                        }),
                        _buildMenuItem(Icons.list, '列表订阅', () {
                          _showAddSubscriptionDialog();
                          setState(() => _showRightMenu = false);
                        }),
                        _buildMenuItem(Icons.tv, 'EPG订阅', () {
                          _showAddEpgDialog();
                          setState(() => _showRightMenu = false);
                        }),
                        _buildMenuItem(Icons.close, '关闭', () {
                          setState(() => _showRightMenu = false);
                        }),
                      ],
                    ),
                  ),
                ),

              // ---------- 顶部工具栏 ----------
              Positioned(
                top: 0,
                right: 0,
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit, color: Colors.white),
                      onPressed: () {
                        if (isEditMode) {
                          _exitEditMode();
                        } else {
                          setState(() => isEditMode = true);
                        }
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.settings, color: Colors.white),
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => SettingsScreen()),
                      ),
                    ),
                  ],
                ),
              ),

              // ---------- 编辑模式信息 ----------
              if (isEditMode)
                Positioned(
                  top: 50,
                  left: 0,
                  right: 0,
                  child: Container(
                    color: Colors.black54,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (!isScheduleMode) ...[
                          Text('订阅 ${(subWeight*100).toInt()}%', style: const TextStyle(color: Colors.white, fontSize: 12)),
                          const SizedBox(width: 16),
                          Text('分组 ${(groupWeight*100).toInt()}%', style: const TextStyle(color: Colors.white, fontSize: 12)),
                          const SizedBox(width: 16),
                          Text('频道 ${(channelWeight*100).toInt()}%', style: const TextStyle(color: Colors.white, fontSize: 12)),
                        ] else ...[
                          Text('分组 ${(scheduleGroupWeight*100).toInt()}%', style: const TextStyle(color: Colors.white, fontSize: 12)),
                          const SizedBox(width: 16),
                          Text('频道 ${(scheduleChannelWeight*100).toInt()}%', style: const TextStyle(color: Colors.white, fontSize: 12)),
                          const SizedBox(width: 16),
                          Text('节目单 ${(scheduleWeight*100).toInt()}%', style: const TextStyle(color: Colors.white, fontSize: 12)),
                        ],
                        const SizedBox(width: 16),
                        ElevatedButton(
                          onPressed: _exitEditMode,
                          style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2)),
                          child: const Text('退出编辑', style: TextStyle(fontSize: 12)),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ============================================================
  // 辅助构建方法
  // ============================================================

  /// 构建 EPG 信息浮窗（直接使用 _currentEpgProgram 和 _nextEpgProgram）
  Widget _buildEpgInfoWithLogo() {
    if (currentChannel == null) return const SizedBox.shrink();
    final channel = currentChannel!;
    final channelNumber = channel.number != null ? '${channel.number}  ' : '';

    return FutureBuilder<File?>(
      future: _logoService.getLogo(channel.name),
      builder: (context, snapshot) {
        Widget logo = const SizedBox(width: 80, height: 80);
        if (snapshot.connectionState == ConnectionState.waiting) {
          logo = const SizedBox(
            width: 80, height: 80,
            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70),
          );
        } else if (snapshot.hasData && snapshot.data != null) {
          logo = Image.file(
            snapshot.data!,
            width: 80,
            height: 80,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => _defaultLogo(channel.name, size: 80),
          );
        } else {
          logo = _defaultLogo(channel.name, size: 80);
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            logo,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (channelNumber.isNotEmpty)
                        Text(
                          channelNumber,
                          style: const TextStyle(
                            color: Colors.yellow,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            shadows: [Shadow(offset: Offset(1,1), blurRadius: 4, color: Colors.black87)],
                          ),
                        ),
                      Expanded(
                        child: Text(
                          channel.name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            shadows: [Shadow(offset: Offset(1,1), blurRadius: 4, color: Colors.black87)],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _buildEpgProgramInfo(), // 使用当前状态字段
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _defaultLogo(String name, {double size = 80}) {
    final firstChar = name.isNotEmpty ? name[0] : '?';
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(color: Colors.transparent, shape: BoxShape.circle),
      child: Center(
        child: Text(
          firstChar,
          style: TextStyle(color: Colors.white, fontSize: size * 0.5, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  /// 构建当前/下个节目信息（直接使用字段）
  Widget _buildEpgProgramInfo() {
    final current = _currentEpgProgram;
    final next = _nextEpgProgram;
    final children = <Widget>[];
    if (current != null) {
      children.add(_buildEpgItem(current, '当前节目'));
      children.add(const SizedBox(height: 4));
    }
    if (next != null) {
      children.add(_buildEpgItem(next, '下一节目'));
    }
    if (children.isEmpty) {
      return const Text('暂无节目信息', style: TextStyle(color: Colors.white70));
    }
    return Column(children: children);
  }

  Widget _buildEpgItem(EpgProgram prog, String label) {
    final timeStr = '${_formatTime(prog.start)}-${_formatTime(prog.end)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$label: $timeStr ${prog.title}',
          style: const TextStyle(color: Colors.white, fontSize: 14, shadows: [
            Shadow(offset: Offset(1,1), blurRadius: 4, color: Colors.black87)
          ]),
        ),
        if (prog.desc != null && prog.desc!.isNotEmpty)
          Text(
            prog.desc!,
            style: const TextStyle(color: Colors.white70, fontSize: 12, shadows: [
              Shadow(offset: Offset(1,1), blurRadius: 4, color: Colors.black87)
            ]),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
      ],
    );
  }

  Widget _buildSubscriptionList() {
    final settings = Provider.of<SettingsService>(context);
    final subs = settings.subscriptions;
    if (subs.isEmpty) {
      return const Center(
        child: Text('无订阅', style: TextStyle(color: Colors.white70, fontSize: 12)),
      );
    }
    return Container(
      color: Colors.transparent,
      child: ListView.builder(
        itemCount: subs.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return const ListTile(
              leading: Icon(Icons.favorite, color: Colors.yellow, size: 16),
              title: Text(
                '我的收藏',
                style: TextStyle(color: Colors.yellow, fontSize: 14, fontWeight: FontWeight.bold),
              ),
            );
          }
          final sub = subs[index - 1];
          final isSelected = sub.selected;
          return ListTile(
            title: Text(
              sub.name,
              style: TextStyle(color: isSelected ? Colors.yellow : Colors.white, fontSize: 13),
            ),
            onTap: () {
              LogService.write('切换订阅源: ${sub.name}');
              settings.toggleSelected(sub);
              _loadSubscriptionData(sub);
            },
          );
        },
      ),
    );
  }

  Widget _buildGroupList() {
    return Container(
      color: Colors.transparent,
      child: ListView.builder(
        itemCount: groups.length,
        itemBuilder: (context, index) {
          final group = groups[index];
          final isSelected = group == currentGroup;
          final displayName = group.replaceAll(',', '');
          return ListTile(
            title: Text(
              displayName,
              style: TextStyle(color: isSelected ? Colors.yellow : Colors.white, fontSize: 13),
            ),
            onTap: () {
              LogService.write('切换到分组: $group');
              _switchToGroup(group);
            },
          );
        },
      ),
    );
  }

  Widget _buildDragBar({required Function(double delta) onDrag, required bool isEditMode}) {
    return GestureDetector(
      onHorizontalDragUpdate: (details) {
        if (!isEditMode) return;
        final delta = details.delta.dx / MediaQuery.of(context).size.width;
        onDrag(delta);
      },
      child: Container(
        width: isEditMode ? 6 : 2,
        color: isEditMode ? Colors.yellow : Colors.transparent,
      ),
    );
  }

  Widget _buildMenuItem(IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 24),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(color: Colors.white, fontSize: 10)),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // 添加订阅源对话框
  // ============================================================

  void _showAddSubscriptionDialog() {
    final nameCtrl = TextEditingController();
    final urlCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('添加列表订阅'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: '名称')),
            TextField(controller: urlCtrl, decoration: const InputDecoration(labelText: 'URL')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          TextButton(
            onPressed: () {
              final name = nameCtrl.text.trim();
              final url = urlCtrl.text.trim();
              if (name.isNotEmpty && url.isNotEmpty) {
                final settings = Provider.of<SettingsService>(context, listen: false);
                final exists = settings.subscriptions.any((s) => s.url == url || s.name == name);
                if (exists) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('订阅源已存在')),
                  );
                  return;
                }
                settings.addSubscription(Subscription(name: name, url: url, selected: true));
                _loadSubscriptionData(Subscription(name: name, url: url, selected: true));
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('已添加: $name')),
                );
              }
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }

  void _showAddEpgDialog() {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('添加EPG订阅'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(labelText: 'EPG URL (XMLTV)'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          TextButton(
            onPressed: () async {
              final url = ctrl.text.trim();
              if (url.isNotEmpty) {
                final config = await ConfigService.getConfig();
                final inner = config['Configuration'] as Map<String, dynamic>?;
                if (inner != null) {
                  inner['EPG_URLS'] = url;
                  await ConfigService.saveConfig({'Configuration': inner});
                  _checkEpgUpdate();
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('EPG已更新')),
                  );
                }
              }
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // 数据初始化
  // ============================================================

  Future<void> _init() async {
    // 1. 后台预加载 EPG 数据（不阻塞 UI）
    EpgParser.preloadAll().then((_) {
      LogService.write('EPG 预加载完成');
    });

    await _loadSavedSubscriptions();
    final settings = Provider.of<SettingsService>(context, listen: false);
    if (settings.subscriptions.isEmpty) {
      await _addDefaultSubscription();
    }
    final selected = settings.subscriptions.where((s) => s.selected).toList();
    if (selected.isNotEmpty) {
      await _loadSubscriptionData(selected.first);
    } else if (settings.subscriptions.isNotEmpty) {
      settings.toggleSelected(settings.subscriptions.first);
      await _loadSubscriptionData(settings.subscriptions.first);
    }
    _checkSubscriptions();
    setState(() => isLoading = false);

    // 2. 启动 10 秒后检查 EPG 更新（后台静默）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(seconds: 10), () {
        if (mounted) _checkEpgUpdate();
      });
    });

    LogService.write('初始化完成');
  }

  // ============================================================
  // 每秒刷新 EPG 信息定时器
  // ============================================================

  void _startEpgInfoTimer() {
    _epgInfoTimer?.cancel();
    _epgInfoTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (currentChannel != null && _showEpgInfo) {
        _updateEpgInfo();
      }
    });
  }

  Future<void> _loadSavedSubscriptions() async => Future.delayed(Duration.zero);

  Future<void> _addDefaultSubscription() async {
    try {
      LogService.write('尝试从配置添加默认订阅源');
      final config = await ConfigService.getConfig();
      final inner = config['Configuration'] as Map<String, dynamic>?;
      final liveUrl = inner?['LIVE_URLS'] as String?;
      if (liveUrl != null && liveUrl.isNotEmpty) {
        String name = '默认源';
        String url = liveUrl;
        if (liveUrl.contains(r'$')) {
          final parts = liveUrl.split(r'$');
          if (parts.length == 2) {
            url = parts[0].trim();
            name = parts[1].trim();
          }
        }
        final settings = Provider.of<SettingsService>(context, listen: false);
        final exists = settings.subscriptions.any((s) => s.url == url);
        if (!exists) {
          settings.addSubscription(Subscription(name: name, url: url, selected: true));
          LogService.write('自动添加默认订阅源: $name -> $url');
        } else {
          LogService.write('默认订阅源已存在，跳过');
        }
      }
    } catch (e, stack) {
      LogService.writeCrashLog(e, stack);
    }
  }

  void _checkSubscriptions() {
    final settings = Provider.of<SettingsService>(context, listen: false);
    final hasSelected = settings.subscriptions.any((s) => s.selected);
    setState(() {
      _hasSubscriptions = hasSelected || channels.isNotEmpty;
    });
    if (!_hasSubscriptions) {
      _showNoSourceDialog();
    }
  }

  void _showNoSourceDialog() {
    LogService.write('无订阅源，显示提示对话框');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          title: const Text('提示'),
          content: const Text('当前没有可用的订阅源，请先添加订阅源。'),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => SettingsScreen()),
                );
              },
              child: const Text('去设置'),
            ),
            TextButton(
              onPressed: () => exit(0),
              child: const Text('退出'),
            ),
          ],
        ),
      );
    });
  }
}
