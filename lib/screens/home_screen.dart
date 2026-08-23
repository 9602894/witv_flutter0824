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
import '../models/channel.dart';
import '../models/epg_program.dart';
import '../models/subscription.dart';
import '../widgets/ijk_player_widget.dart';
import '../widgets/group_list.dart';
import '../widgets/schedule_view.dart';
import 'settings_screen.dart';

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
  bool _showEpgInfo = true;          // 默认显示中下框
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

  // ---------- EPG ----------
  EpgProgram? _currentProgram;
  EpgProgram? _nextProgram;
  bool _isEpgUpdating = false;

  // ---------- 定时器 ----------
  Timer? _epgInfoHideTimer;           // 中下框自动隐藏
  Timer? _epgUpdateTimer;
  Timer? _epgInfoTimer;

  // ---------- 订阅 ----------
  Map<String, List<Channel>>? _fullGroupMap;
  bool _hasSubscriptions = false;
  bool _isUpdatingSubscription = false;
  bool isLoading = true;

  // ---------- 配置 ----------
  late File _layoutConfigFile;
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

  // ---------- 自动加载标记 ----------
  VoidCallback? _epgListener;
  bool _autoLoaded = false;

  // ============================================================
  // 工具函数
  // ============================================================
  DateTime get _beijingNow => EpgParser.beijingNow;
  String _formatTime(DateTime time) => EpgParser.formatBeijingTime(time);
  String _getDate(DateTime time) {
    final bj = EpgParser.toBeijing(time);
    return '${bj.year}-${bj.month.toString().padLeft(2, '0')}-${bj.day.toString().padLeft(2, '0')}';
  }

  // ============================================================
  // 生命周期
  // ============================================================
  @override
  void initState() {
    super.initState();
    _initAsync();

    // EPG 更新监听
    _epgListener = () {
      if (!mounted) return;
      _updateEpgInfo();
      if (isScheduleMode) setState(() {});
    };
    EpgParser.epgUpdateCounter.addListener(_epgListener!);
  }

  Future<void> _initAsync() async {
    LogService.write('主页初始化');
    await _initLayoutConfigFile();
    await _loadLayoutConfig();

    final logoSources = await _logoService.getEnabledSources();
    LogService.write('Logo: 已配置来源 ${logoSources.length} 个: ${logoSources.map((s) => s.name).join(', ')}');
    final hasLogoSource = await _logoService.hasConfiguredSource();
    if (!hasLogoSource) {
      LogService.write('Logo: 首次使用，自动设置默认来源 GitHub');
      await _logoService.setEnabledSources([LogoSource.github]);
    }

    _initEpgScheduler();
    _startEpgInfoTimer();
    _loadEpgInBackground();

    if (mounted) setState(() => isLoading = false);
  }

  void _loadEpgInBackground() {
    EpgParser.init().then((_) async {
      LogService.write('EPG: 后台加载完成');
      if (currentChannel != null && mounted) {
        await _updateEpgInfo();
        // 显示中下框并启动5秒自动隐藏
        _showEpgInfoTemporarily();
      }
    }).catchError((e, stack) {
      LogService.writeCrashLog('EPG后台加载失败: $e', stack);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_autoLoaded && channels.isEmpty) {
      final settings = Provider.of<SettingsService>(context);
      if (settings.subscriptions.isNotEmpty) {
        _autoLoaded = true;
        final selectedSubs = settings.subscriptions.where((s) => s.selected).toList();
        if (selectedSubs.isNotEmpty) {
          _loadSubscriptionData(selectedSubs.first);
        } else {
          _loadSubscriptionData(settings.subscriptions.first);
        }
      }
    }
  }

  // ========== 布局配置 ==========
  Future<void> _initLayoutConfigFile() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _layoutConfigFile = File('${dir.path}/layout_config.json');
      if (!await _layoutConfigFile.exists()) {
        await _saveLayoutConfig();
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
        'channelButtonDy': channelListButtonOffset.dy,
      };
      await _layoutConfigFile.writeAsString(jsonEncode(json));
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
    _epgInfoHideTimer?.cancel();
    if (_epgListener != null) {
      EpgParser.epgUpdateCounter.removeListener(_epgListener!);
    }
    _epgUpdateTimer?.cancel();
    _epgInfoTimer?.cancel();
    _retryTimer?.cancel();
    _digitTimer?.cancel();
    _focusNode.dispose();
    _saveLayoutConfig();
    super.dispose();
  }

  // ========== EPG 调度 ==========
  void _initEpgScheduler() {
    _epgUpdateTimer = Timer.periodic(const Duration(hours: 6), (_) {
      _checkEpgUpdate();
    });
  }

  Future<void> _checkEpgUpdate() async {
    if (_isEpgUpdating) return;
    _isEpgUpdating = true;
    try {
      await EpgParser.init();
      await _updateEpgInfo();
    } catch (e) {
      LogService.write('EPG 更新检查失败: $e');
    } finally {
      _isEpgUpdating = false;
    }
  }

  // ========== EPG 查询 ==========
  Future<EpgProgram?> _getCurrentProgram(String channelName) async {
    return await EpgParser.getCurrentProgram(channelName);
  }

  Future<EpgProgram?> _getNextProgram(String channelName) async {
    return await EpgParser.getNextProgram(channelName);
  }

  Future<List<EpgProgram>> _getChannelPrograms(String channelName) async {
    return await EpgParser.getProgramsByChannelName(channelName);
  }

  Future<void> _updateEpgInfo() async {
    if (currentChannel == null) return;
    final current = await _getCurrentProgram(currentChannel!.name);
    final next = await _getNextProgram(currentChannel!.name);
    if (mounted) {
      setState(() {
        _currentProgram = current;
        _nextProgram = next;
      });
    }
  }

  // ========== 每秒刷新 EPG 信息 ==========
  void _startEpgInfoTimer() {
    _epgInfoTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (currentChannel != null && mounted) {
        _updateEpgInfo();
      }
    });
  }

  // ========== 显示中下框并5秒后自动隐藏 ==========
  void _showEpgInfoTemporarily() {
    _epgInfoHideTimer?.cancel();
    setState(() => _showEpgInfo = true);
    _epgInfoHideTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _showEpgInfo = false);
    });
  }

  // ========== 播放器重连 ==========
  void _scheduleRetry() {
    _retryTimer?.cancel();
    _retryChannel = currentChannel;
    if (_retryChannel == null) return;
    _retryTimer = Timer(const Duration(seconds: 5), () {
      if (currentChannel == _retryChannel && currentChannel != null) {
        setState(() => currentChannel = null);
        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted && _retryChannel != null) {
            setState(() {
              _playerKey = UniqueKey();
              currentChannel = _retryChannel;
            });
          }
        });
      }
      _retryTimer = null;
    });
  }

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryChannel = null;
  }

  // ========== 频道切换（换台） ==========
  void _switchChannel(Channel ch) {
    _cancelRetry();
    _digitBuffer = '';
    _digitTimer?.cancel();

    setState(() {
      currentChannel = ch;
      _selectedIndex = channels.indexOf(ch);
      _updateEpgInfo();
    });

    // 显示中下框，5秒后自动隐藏
    _showEpgInfoTemporarily();

    Provider.of<SettingsService>(context, listen: false).saveLastChannel(ch.name);
  }

  // ========== 分组切换 ==========
  void _switchToGroup(String groupName) {
    if (_fullGroupMap == null || _fullGroupMap!.isEmpty) return;
    final groupChannels = _fullGroupMap![groupName];
    if (groupChannels == null || groupChannels.isEmpty) return;
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

    _logoService.preloadAllLogos(channels);
    if (currentChannel != null) {
      _updateEpgInfo();
      // 切换分组时也显示中下框
      _showEpgInfoTemporarily();
    }
  }

  // ========== 订阅源加载 ==========
  Future<void> _loadSubscriptionData(Subscription sub) async {
    try {
      final url = sub.url;
      final cacheFile = await PlaylistParser.getCacheFile(url, sub.name);

      if (await cacheFile.exists()) {
        try {
          final content = await cacheFile.readAsString();
          final groupMap = PlaylistParser.parseFromString(content);
          if (groupMap.isNotEmpty) {
            _applyGroupMap(groupMap, sub.name);
          }
        } catch (e) {
          LogService.write('缓存解析失败: $e');
        }
      }

      if (!await cacheFile.exists() || channels.isEmpty) {
        final groupMap = await PlaylistParser.parseFromUrl(url);
        if (groupMap.isNotEmpty) {
          await PlaylistParser.saveCache(groupMap, url, sub.name);
          _applyGroupMap(groupMap, sub.name);
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('订阅源加载失败')),
            );
          }
        }
        return;
      }

      if (!_isUpdatingSubscription) {
        _isUpdatingSubscription = true;
        Future.delayed(const Duration(seconds: 2), () async {
          try {
            final newMap = await PlaylistParser.parseFromUrl(url);
            if (newMap.isNotEmpty) {
              final oldCount = _fullGroupMap?.values.expand((l) => l).length ?? 0;
              final newCount = newMap.values.expand((l) => l).length;
              if (oldCount != newCount || newMap.keys.length != groups.length) {
                await PlaylistParser.saveCache(newMap, url, sub.name);
                if (mounted && currentSubName == sub.name) {
                  _applyGroupMap(newMap, sub.name);
                }
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
    }
  }

  // ========== 应用分组映射 ==========
  void _applyGroupMap(Map<String, List<Channel>> groupMap, String subName) {
    if (groupMap.isEmpty) return;

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
                } catch (_) {}
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
            // 加载后显示中下框
            _showEpgInfoTemporarily();
            _updateEpgInfo();
          } else if (currentChannel != null && channels.contains(currentChannel)) {
            _selectedIndex = channels.indexOf(currentChannel!);
          } else {
            _selectedIndex = -1;
          }
        } else {
          for (final g in groups) {
            final chs = groupMap[g];
            if (chs != null && chs.isNotEmpty) {
              currentGroup = g;
              channels = chs;
              break;
            }
          }
        }
      }
      currentSubName = subName;
    });

    if (currentChannel != null) {
      _updateEpgInfo();
    }
  }

  // ========== 遥控器按键 ==========
  void _handleKeyEvent(RawKeyEvent event) {
    if (event is! RawKeyDownEvent) return;
    if (!showChannelList || isEditMode || isScheduleMode) return;

    final key = event.logicalKey;
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
      setState(() => _selectedIndex = _selectedIndex > 0 ? _selectedIndex - 1 : channels.length - 1);
    } else if (key == LogicalKeyboardKey.arrowDown) {
      setState(() => _selectedIndex = _selectedIndex < channels.length - 1 ? _selectedIndex + 1 : 0);
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
    }
  }

  // ============================================================
  // 中下框信息条（背景完全透明）
  // ============================================================
  Widget _buildEpgInfoBar() {
    final current = _currentProgram;
    final next = _nextProgram;
    final logoUrl = currentChannel != null
        ? EpgParser.getChannelIconSync(currentChannel!.name)
        : null;

    return Visibility(
      visible: _showEpgInfo,
      child: GestureDetector(
        onTap: () {
          // 点击中下框不关闭（可留空或添加其他交互）
        },
        child: Container(
          color: Colors.transparent,          // 完全透明背景
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: SafeArea(
            top: false,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 台标（透明背景）
                if (logoUrl != null && logoUrl.isNotEmpty)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Container(
                      width: 70,
                      height: 45,
                      color: Colors.transparent,
                      child: Image.network(
                        logoUrl,
                        width: 70,
                        height: 45,
                        fit: BoxFit.contain,
                        loadingBuilder: (context, child, loadingProgress) {
                          if (loadingProgress == null) return child;
                          return Container(color: Colors.transparent);
                        },
                        errorBuilder: (context, error, stackTrace) {
                          return Container(color: Colors.transparent);
                        },
                      ),
                    ),
                  )
                else
                  const SizedBox(width: 70, height: 45),

                const SizedBox(width: 12),

                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 频道名
                      Text(
                        currentChannel?.name ?? '',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),

                      // 正在播放（东八区时间）
                      if (current != null)
                        Text(
                          '正在播放：${EpgParser.formatBeijingTime(current.start)} - ${EpgParser.formatBeijingTime(current.stop)}  ${current.title}',
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),

                      // desc 全部显示（不限制行数）
                      if (current?.description?.isNotEmpty == true)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            current!.description!,
                            style: const TextStyle(color: Colors.white70, fontSize: 12),
                          ),
                        )
                      else
                        const Padding(
                          padding: EdgeInsets.only(top: 2),
                          child: Text(
                            '暂无描述信息',
                            style: TextStyle(color: Colors.white54, fontSize: 12),
                          ),
                        ),

                      const SizedBox(height: 4),

                      // 下一节目（东八区时间）
                      if (next != null)
                        Text(
                          '下一节目：${EpgParser.formatBeijingTime(next.start)} - ${EpgParser.formatBeijingTime(next.stop)}  ${next.title}',
                          style: const TextStyle(color: Colors.white70, fontSize: 12),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ============================================================
  // 频道列表项（左边台标 + 当前 EPG）
  // ============================================================
  Widget _buildChannelItem(Channel channel, int index) {
    final currentEpg = EpgParser.getCurrentProgramSync(channel.name);
    final logoUrl = EpgParser.getChannelIconSync(channel.name);
    final isSelected = currentChannel?.name == channel.name;

    return ListTile(
      dense: true,
      selected: isSelected,
      selectedTileColor: Colors.white.withOpacity(0.1),
      leading: logoUrl != null && logoUrl.isNotEmpty
          ? Container(
              width: 36,
              height: 24,
              color: Colors.transparent,
              child: Image.network(
                logoUrl,
                width: 36,
                height: 24,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const SizedBox(width: 36, height: 24),
              ),
            )
          : const SizedBox(width: 36, height: 24),
      title: Text(
        channel.name,
        style: TextStyle(
          color: isSelected ? Colors.yellow : Colors.white,
          fontSize: 14,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      subtitle: currentEpg != null
          ? Text(
              '${EpgParser.formatBeijingTime(currentEpg.start)}-${EpgParser.formatBeijingTime(currentEpg.stop)} ${currentEpg.title}',
              style: TextStyle(
                color: isSelected ? Colors.yellow.withOpacity(0.8) : Colors.white70,
                fontSize: 11,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            )
          : Text(
              '暂无节目信息',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
      onTap: () => _switchChannel(channel),
    );
  }

  // ========== 构建 UI ==========
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

    return RawKeyboardListener(
      focusNode: _focusNode,
      onKey: _handleKeyEvent,
      child: WillPopScope(
        onWillPop: () async {
          // 返回键优先关闭中下框
          if (_showEpgInfo) {
            setState(() => _showEpgInfo = false);
            _epgInfoHideTimer?.cancel();
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
                TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
                TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('确定')),
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
                    onError: _scheduleRetry,
                    onSpeedUpdate: (speed) {
                      if (mounted) setState(() => currentSpeed = speed);
                    },
                  ),
                ),

              // ---------- 点击播放器区域弹出中下框 ----------
              if (!_showEpgInfo)
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: () {
                      _showEpgInfoTemporarily();
                    },
                  ),
                ),

              // ---------- 左侧点击区域（切换列表） ----------
              Positioned(
                left: 0, top: 0, bottom: 0, width: 40,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () {
                    setState(() {
                      if (isScheduleMode) {
                        isScheduleMode = false;
                        showChannelList = true;
                      } else {
                        showChannelList = !showChannelList;
                      }
                      if (showChannelList) {
                        _showRightMenu = false;
                        _showEpgInfo = false;  // 列表显示时隐藏中下框
                        _epgInfoHideTimer?.cancel();
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
                  left: 0, top: 0, bottom: 0,
                  width: MediaQuery.of(context).size.width * 0.7,
                  child: Container(
                    color: Colors.transparent,
                    child: Row(
                      children: [
                        Expanded(flex: (subWeight * 100).toInt(), child: _buildSubscriptionList()),
                        _buildDragBar(onDrag: (delta) {
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
                        }, isEditMode: isEditMode),
                        Expanded(flex: (groupWeight * 100).toInt(), child: _buildGroupList()),
                        _buildDragBar(onDrag: (delta) {
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
                        }, isEditMode: isEditMode),
                        Expanded(
                          flex: (channelWeight * 100).toInt(),
                          child: Stack(
                            children: [
                              Positioned.fill(
                                child: ListView.builder(
                                  itemCount: channels.length,
                                  itemBuilder: (context, index) =>
                                      _buildChannelItem(channels[index], index),
                                ),
                              ),
                              Positioned(
                                right: 20 - channelListButtonOffset.dx,
                                top: _channelButtonInitTop + channelListButtonOffset.dy,
                                child: GestureDetector(
                                  onPanUpdate: (details) {
                                    if (!isEditMode) return;
                                    setState(() => channelListButtonOffset += details.delta);
                                  },
                                  onTap: () => setState(() {
                                    isScheduleMode = true;
                                    showChannelList = false;
                                  }),
                                  child: Container(
                                    width: 26, height: 80, color: Colors.transparent,
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
                  left: 0, top: 0, bottom: 0,
                  width: MediaQuery.of(context).size.width * 0.7,
                  child: Stack(
                    children: [
                      Row(
                        children: [
                          Expanded(flex: (scheduleGroupWeight * 100).toInt(), child: _buildGroupList()),
                          _buildDragBar(onDrag: (delta) {
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
                          }, isEditMode: isEditMode),
                          Expanded(
                            flex: (scheduleChannelWeight * 100).toInt(),
                            child: ListView.builder(
                              itemCount: channels.length,
                              itemBuilder: (context, index) =>
                                  _buildChannelItem(channels[index], index),
                            ),
                          ),
                          _buildDragBar(onDrag: (delta) {
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
                          }, isEditMode: isEditMode),
                          Expanded(
                            flex: (scheduleWeight * 100).toInt(),
                            child: ScheduleView(
                              channels: channels,
                              selectedChannel: currentChannel,
                              epgMap: const {},
                              onSelectChannel: _switchChannel,
                              leftWeight: 0.3,
                              rightWeight: 0.7,
                              onLeftWeightChanged: (_) {},
                              isEditMode: isEditMode,
                              showLeft: false,
                              logoService: _logoService,
                              getChannelPrograms: _getChannelPrograms,
                              formatTime: _formatTime,
                              beijingNow: _beijingNow,
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
                            setState(() => scheduleModeButtonOffset += details.delta);
                          },
                          onTap: () => setState(() {
                            isScheduleMode = false;
                            showChannelList = true;
                          }),
                          child: Container(
                            width: 26, height: 80, color: Colors.transparent,
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

              // ---------- 中下框 EPG 信息 ----------
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _buildEpgInfoBar(),
              ),

              // ---------- 右侧菜单 ----------
              if (_showRightMenu)
                Positioned(
                  top: 0, right: 0, bottom: 0,
                  width: MediaQuery.of(context).size.width * 0.12,
                  child: Container(
                    color: Colors.transparent,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _buildMenuItem(Icons.settings, '设置', () {
                          Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsScreen()))
                              .then((_) => setState(() {}));
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
                top: 0, right: 0,
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
                        context, MaterialPageRoute(builder: (_) => SettingsScreen()),
                      ).then((_) => setState(() {})),
                    ),
                    IconButton(
                      icon: const Icon(Icons.menu, color: Colors.white),
                      onPressed: () => setState(() => _showRightMenu = !_showRightMenu),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ========== 辅助构建方法 ==========
  Widget _buildDragBar({required void Function(double) onDrag, required bool isEditMode}) {
    if (!isEditMode) return const SizedBox.shrink();
    return GestureDetector(
      onHorizontalDragUpdate: (details) {
        final width = MediaQuery.of(context).size.width * 0.7;
        onDrag(details.delta.dx / width);
      },
      child: Container(width: 8, color: Colors.white24),
    );
  }

  Widget _buildMenuItem(IconData icon, String label, VoidCallback onTap) {
    return ListTile(
      leading: Icon(icon, color: Colors.white),
      title: Text(label, style: const TextStyle(color: Colors.white)),
      onTap: onTap,
    );
  }

  Widget _buildSubscriptionList() {
    return Consumer<SettingsService>(
      builder: (context, settings, _) {
        final subs = settings.subscriptions;
        _hasSubscriptions = subs.isNotEmpty;
        if (!_hasSubscriptions) {
          return const Center(child: Text('无订阅源', style: TextStyle(color: Colors.white)));
        }
        return ListView.builder(
          itemCount: subs.length,
          itemBuilder: (_, index) {
            final sub = subs[index];
            final isSelected = currentSubName == sub.name;
            return ListTile(
              title: Text(sub.name, style: TextStyle(
                color: isSelected ? Colors.yellow : Colors.white,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              )),
              onTap: () => _loadSubscriptionData(sub),
            );
          },
        );
      },
    );
  }

  Widget _buildGroupList() {
    return GroupList(
      groups: groups,
      selectedGroup: currentGroup,
      onSelect: _switchToGroup,
    );
  }

  // ========== 对话框方法 ==========
  void _showAddSubscriptionDialog() {
    // 原为空实现，保持原样
  }

  void _showAddEpgDialog() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => SettingsScreen()),
    ).then((_) => setState(() {}));
  }
}
