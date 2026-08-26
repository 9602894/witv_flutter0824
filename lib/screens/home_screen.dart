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
import '../widgets/channel_list.dart';
import '../widgets/logo_source_dialog.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Channel> channels = [];
  List<String> groups = [];
  Channel? currentChannel;
  String? currentGroup;
  String? currentSubName;

  bool showChannelList = false;
  bool isScheduleMode = false;
  bool _showEpgInfo = true;
  bool isEditMode = false;
  bool _showRightMenu = false;
  bool _showExitDialog = false;

  double subWeight = 0.2;
  double groupWeight = 0.2;
  double channelWeight = 0.6;
  double scheduleGroupWeight = 0.25;
  double scheduleChannelWeight = 0.35;
  double scheduleWeight = 0.4;

  Offset scheduleModeButtonOffset = Offset(714.8865763346365, 7.9911295572917425);
  Offset channelListButtonOffset = Offset(-133.9163004557305, -4.6614786783854925);

  double _scheduleButtonInitTop = 0;
  double _channelButtonInitTop = 0;

  EpgProgram? _currentProgram;
  EpgProgram? _nextProgram;
  bool _isEpgUpdating = false;

  Timer? _epgInfoHideTimer;
  Timer? _epgUpdateTimer;
  Timer? _epgInfoTimer;

  Map<String, List<Channel>>? _fullGroupMap;
  bool _hasSubscriptions = false;
  bool _isUpdatingSubscription = false;
  bool isLoading = true;

  late File _layoutConfigFile;
  final LogoService _logoService = LogoService();

  Timer? _retryTimer;
  Channel? _retryChannel;
  Key? _playerKey;
  double currentSpeed = 0;

  final FocusNode _focusNode = FocusNode();
  int _selectedIndex = -1;
  String _digitBuffer = '';
  Timer? _digitTimer;

  String _channelNumberInput = '';
  Timer? _channelNumberTimer;

  // 退出对话框焦点
  int _exitDialogSelectedIndex = 0;

  VoidCallback? _epgListener;
  bool _autoLoaded = false;

  // 修改 A：添加焦点守护定时器
  Timer? _focusCheckTimer;

  DateTime get _beijingNow => EpgParser.beijingNow;
  String _formatTime(DateTime time) => EpgParser.formatBeijingTime(time);

  @override
  void initState() {
    super.initState();
    _initAsync();

    // 修复：启动后立即获取焦点，确保遥控器按键生效
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _focusNode.requestFocus();
        LogService.write('主页: 已请求焦点');
      }
    });

    // 修改 A：每 500ms 检查一次焦点，被 PlatformView 抢走就抢回来
    _focusCheckTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted && !_focusNode.hasFocus && !_showExitDialog) {
        _focusNode.requestFocus();
      }
    });

    _epgListener = () {
      if (!mounted) return;
      _updateEpgInfo();
      if (isScheduleMode) setState(() {});
      _tryDownloadLogos();
    };
    EpgParser.epgUpdateCounter.addListener(_epgListener!);
  }

  Future<void> _initAsync() async {
    LogService.write('主页初始化');
    await _initLayoutConfigFile();
    await _loadLayoutConfig();

    final hasLogoSource = await _logoService.hasConfiguredSource();
    if (!hasLogoSource && mounted) {
      LogService.write('Logo: 首次使用，引导用户设置台标来源');
      await LogoSourceSettingDialog.show(context, isFirstTime: true);
    }

    _tryDownloadLogos();
    _initEpgScheduler();
    _startEpgInfoTimer();
    _loadEpgInBackground();

    if (mounted) setState(() => isLoading = false);

    // 修复：主动加载订阅源，解决 didChangeDependencies 时序竞争导致订阅源永不加载的问题
    _autoLoadSubscription();
  }

  /// 修复：延迟等待 SettingsService 加载完成后自动加载订阅源
  Future<void> _autoLoadSubscription() async {
    // 最多等待 3 秒，让 SettingsService 完成初始化
    for (var i = 0; i < 30; i++) {
      await Future.delayed(const Duration(milliseconds: 100));
      if (!mounted) return;

      final settings = Provider.of<SettingsService>(context, listen: false);
      if (settings.subscriptions.isNotEmpty) {
        if (!_autoLoaded && channels.isEmpty) {
          _autoLoaded = true;
          final selectedSubs = settings.subscriptions.where((s) => s.selected).toList();
          if (selectedSubs.isNotEmpty) {
            await _loadSubscriptionData(selectedSubs.first);
          } else {
            await _loadSubscriptionData(settings.subscriptions.first);
          }
        }
        return;
      }
    }
    LogService.write('自动加载订阅源: 超时，未找到订阅源');
  }

  void _tryDownloadLogos() {
    if (channels.isEmpty) return;
    _logoService.hasConfiguredSource().then((hasSource) {
      if (hasSource && mounted) {
        _logoService.downloadAllLogos(channels);
      }
    });
  }

  void _loadEpgInBackground() {
    EpgParser.init().then((_) async {
      LogService.write('EPG: 后台加载完成');
      if (currentChannel != null && mounted) {
        await _updateEpgInfo();
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

  // 修改 B：dispose 中取消定时器
  @override
  void dispose() {
    _focusCheckTimer?.cancel();
    _epgInfoHideTimer?.cancel();
    if (_epgListener != null) {
      EpgParser.epgUpdateCounter.removeListener(_epgListener!);
    }
    _epgUpdateTimer?.cancel();
    _epgInfoTimer?.cancel();
    _retryTimer?.cancel();
    _digitTimer?.cancel();
    _channelNumberTimer?.cancel();
    _focusNode.dispose();
    _saveLayoutConfig();
    super.dispose();
  }

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

  void _startEpgInfoTimer() {
    _epgInfoTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (currentChannel != null && mounted) {
        _updateEpgInfo();
      }
    });
  }

  void _showEpgInfoTemporarily() {
    _epgInfoHideTimer?.cancel();
    setState(() => _showEpgInfo = true);
    _epgInfoHideTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _showEpgInfo = false);
    });
  }

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

  void _switchChannel(Channel ch) {
    _cancelRetry();
    _digitBuffer = '';
    _digitTimer?.cancel();
    _channelNumberTimer?.cancel();
    _channelNumberInput = '';

    setState(() {
      currentChannel = ch;
      _selectedIndex = channels.indexOf(ch);
      _updateEpgInfo();
    });

    _showEpgInfoTemporarily();
    Provider.of<SettingsService>(context, listen: false).saveLastChannel(ch.name);
  }

  void _switchToGroup(String groupName) {
    if (_fullGroupMap == null || _fullGroupMap!.isEmpty) return;
    final groupChannels = _fullGroupMap![groupName];
    if (groupChannels == null || groupChannels.isEmpty) return;
    _cancelRetry();
    _digitBuffer = '';
    _digitTimer?.cancel();
    _channelNumberTimer?.cancel();
    _channelNumberInput = '';

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
    _tryDownloadLogos();
    if (currentChannel != null) {
      _updateEpgInfo();
      _showEpgInfoTemporarily();
    }
  }

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
    _tryDownloadLogos();
  }

  void _handleKeyEvent(RawKeyEvent event) {
    if (event is! RawKeyDownEvent) return;
    final key = event.logicalKey;

    // 退出对话框显示时，由对话框独占处理按键
    if (_showExitDialog) {
      _handleExitDialogKey(event);
      return;
    }

    if (key == LogicalKeyboardKey.contextMenu) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsScreen()))
          .then((_) => setState(() {}));
      return;
    }

    if (key == LogicalKeyboardKey.goBack || key == LogicalKeyboardKey.escape) {
      if (_showExitDialog) {
        setState(() => _showExitDialog = false);
        return;
      }
    }

    final digitKeys = [
      LogicalKeyboardKey.digit0, LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2, LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4, LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.digit6, LogicalKeyboardKey.digit7,
      LogicalKeyboardKey.digit8, LogicalKeyboardKey.digit9,
    ];
    if (digitKeys.contains(key)) {
      _channelNumberTimer?.cancel();
      setState(() => _channelNumberInput += key.keyLabel);
      _channelNumberTimer = Timer(const Duration(milliseconds: 1500), () {
        _jumpToChannelNumber(_channelNumberInput);
        setState(() => _channelNumberInput = '');
      });
      return;
    }

    if (_channelNumberInput.isNotEmpty) {
      _channelNumberTimer?.cancel();
      _jumpToChannelNumber(_channelNumberInput);
      setState(() => _channelNumberInput = '');
    }

    if (channels.isEmpty) {
      // 修复：没有频道时按 OK 键进入设置，引导用户添加订阅源
      if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.select) {
        Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsScreen()))
            .then((_) => setState(() {}));
      }
      return;
    }
    if (isEditMode) return;

    if (showChannelList && !isScheduleMode) {
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
    } else {
      if (key == LogicalKeyboardKey.arrowUp) {
        final currentIdx = currentChannel != null ? channels.indexOf(currentChannel!) : -1;
        final newIdx = currentIdx > 0 ? currentIdx - 1 : channels.length - 1;
        if (newIdx >= 0 && newIdx < channels.length) {
          _switchChannel(channels[newIdx]);
        }
      } else if (key == LogicalKeyboardKey.arrowDown) {
        final currentIdx = currentChannel != null ? channels.indexOf(currentChannel!) : -1;
        final newIdx = currentIdx < channels.length - 1 ? currentIdx + 1 : 0;
        if (newIdx >= 0 && newIdx < channels.length) {
          _switchChannel(channels[newIdx]);
        }
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
        setState(() {
          showChannelList = true;
          _showRightMenu = false;
          _showEpgInfo = false;
          _epgInfoHideTimer?.cancel();
          _focusNode.requestFocus();
        });
      }
    }
  }

  void _jumpToChannelNumber(String digits) {
    if (digits.isEmpty) return;
    final targetNumber = int.tryParse(digits);
    if (targetNumber == null) return;

    Channel? found;
    String? foundGroup;

    if (_fullGroupMap != null) {
      for (final entry in _fullGroupMap!.entries) {
        for (final ch in entry.value) {
          if (ch.number == targetNumber) {
            found = ch;
            foundGroup = entry.key;
            break;
          }
        }
        if (found != null) break;
      }
    }

    if (found == null) {
      for (final ch in channels) {
        if (ch.number == targetNumber) {
          found = ch;
          break;
        }
      }
    }

    if (found != null) {
      if (foundGroup != null && foundGroup != currentGroup) {
        _switchToGroup(foundGroup);
      }
      _switchChannel(found);
    }
  }

  Widget _buildTag(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
        ),
      ),
    );
  }

  Widget _buildEpgInfoBar() {
    final current = _currentProgram;
    final next = _nextProgram;

    String? timeRemaining;
    if (current != null) {
      final now = EpgParser.beijingNow;
      final diff = current.stop.difference(now);
      if (diff.inMinutes > 0) {
        timeRemaining = '距结束：${diff.inMinutes}分钟';
      }
    }

    final List<String> tags = [];
    if (currentSpeed > 0) {
      tags.add('${currentSpeed.toStringAsFixed(2)}MB/s');
    }
    tags.add('线路1/1');

    return Visibility(
      visible: _showEpgInfo,
      child: Container(
        margin: EdgeInsets.symmetric(
          horizontal: MediaQuery.of(context).size.width * 0.15,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: const BoxDecoration(
          color: Colors.transparent,
        ),
        child: SafeArea(
          top: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (currentChannel != null)
                    ChannelLogo(
                      channelName: currentChannel!.name,
                      width: 80,
                      height: 50,
                      fit: BoxFit.contain,
                    )
                  else
                    const SizedBox(width: 80, height: 50),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          currentChannel?.name ?? '',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (currentChannel?.number != null)
                          Text(
                            '频道号: ${currentChannel!.number}',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: tags.map((t) => _buildTag(t)).toList(),
                      ),
                      if (timeRemaining != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            timeRemaining,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (current != null)
                Text(
                  '正在播放：${EpgParser.formatBeijingTime(current.start)} - ${EpgParser.formatBeijingTime(current.stop)}  ${current.title}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                  ),
                ),
              if (current?.description?.isNotEmpty == true)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    current!.description!,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                    ),
                  ),
                )
              else
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text(
                    '暂无描述信息',
                    style: TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                ),
              const SizedBox(height: 4),
              if (next != null)
                Text(
                  '下一节目：${EpgParser.formatBeijingTime(next.start)} - ${EpgParser.formatBeijingTime(next.stop)}  ${next.title}',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildChannelItem(Channel channel, int index) {
    final currentEpg = EpgParser.getCurrentProgramSync(channel.name);
    final isSelected = currentChannel?.name == channel.name;

    return ListTile(
      dense: true,
      selected: isSelected,
      selectedTileColor: Colors.white.withOpacity(0.1),
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (channel.number != null)
            Container(
              width: 40,
              alignment: Alignment.center,
              child: Text(
                '${channel.number}',
                style: TextStyle(
                  color: isSelected ? Colors.yellow : Colors.white70,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ChannelLogo(
            channelName: channel.name,
            width: 36,
            height: 24,
            fit: BoxFit.contain,
          ),
        ],
      ),
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

  void _handleExitDialogKey(RawKeyEvent event) {
    if (event is! RawKeyDownEvent) return;
    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowRight) {
      setState(() {
        if (key == LogicalKeyboardKey.arrowLeft) {
          _exitDialogSelectedIndex = _exitDialogSelectedIndex > 0 ? _exitDialogSelectedIndex - 1 : 2;
        } else {
          _exitDialogSelectedIndex = _exitDialogSelectedIndex < 2 ? _exitDialogSelectedIndex + 1 : 0;
        }
      });
    } else if (key == LogicalKeyboardKey.arrowUp) {
      setState(() => _exitDialogSelectedIndex = 0);
    } else if (key == LogicalKeyboardKey.arrowDown) {
      setState(() => _exitDialogSelectedIndex = 2);
    } else if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.select) {
      _executeExitDialogAction();
    } else if (key == LogicalKeyboardKey.goBack || key == LogicalKeyboardKey.escape) {
      setState(() => _showExitDialog = false);
    }
  }

  void _executeExitDialogAction() {
    switch (_exitDialogSelectedIndex) {
      case 0:
        setState(() => _showExitDialog = false);
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => SettingsScreen()),
        ).then((_) => setState(() {}));
        break;
      case 1:
        exit(0);
        break;
      case 2:
        setState(() => _showExitDialog = false);
        break;
    }
  }

  Widget _buildExitDialog() {
    if (!_showExitDialog) return const SizedBox.shrink();

    return GestureDetector(
      onTap: () => setState(() => _showExitDialog = false),
      child: Container(
        color: Colors.black.withOpacity(0.5),
        child: Center(
          child: GestureDetector(
            onTap: () {},
            child: Container(
              width: 320,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.9),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withOpacity(0.2)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.5),
                    blurRadius: 20,
                    spreadRadius: 5,
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.live_tv,
                    color: Colors.white70,
                    size: 48,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Witv 播放器',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '您想要做什么？',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 28),
                  Row(
                    children: [
                      Expanded(
                        child: _buildExitDialogButton(
                          index: 0,
                          icon: Icons.settings,
                          label: '设置',
                          activeColor: Colors.blue,
                          onTap: () {
                            _exitDialogSelectedIndex = 0;
                            _executeExitDialogAction();
                          },
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: _buildExitDialogButton(
                          index: 1,
                          icon: Icons.power_settings_new,
                          label: '退出',
                          activeColor: Colors.red,
                          onTap: () {
                            _exitDialogSelectedIndex = 1;
                            _executeExitDialogAction();
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _buildExitDialogCancelButton(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildExitDialogButton({
    required int index,
    required IconData icon,
    required String label,
    required Color activeColor,
    required VoidCallback onTap,
  }) {
    final isSelected = _exitDialogSelectedIndex == index;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      decoration: BoxDecoration(
        color: isSelected ? activeColor.withOpacity(0.3) : Colors.grey[800],
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isSelected ? activeColor : Colors.transparent,
          width: 2,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 16),
            alignment: Alignment.center,
            child: Column(
              children: [
                Icon(
                  icon,
                  color: isSelected ? activeColor : Colors.white70,
                  size: 28,
                ),
                const SizedBox(height: 6),
                Text(
                  label,
                  style: TextStyle(
                    color: isSelected ? activeColor : Colors.white,
                    fontSize: 15,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildExitDialogCancelButton() {
    final isSelected = _exitDialogSelectedIndex == 2;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => setState(() => _showExitDialog = false),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 24),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isSelected ? Colors.white54 : Colors.transparent,
              width: 1,
            ),
          ),
          child: Text(
            '取消',
            style: TextStyle(
              color: isSelected ? Colors.white : Colors.white54,
              fontSize: 14,
            ),
          ),
        ),
      ),
    );
  }

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

    // 修改 C：build 方法去掉 autofocus
    return RawKeyboardListener(
      focusNode: _focusNode,
      onKey: _handleKeyEvent,
      // autofocus: true,  // 已删除
      child: WillPopScope(
        onWillPop: () async {
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
          if (_showExitDialog) {
            setState(() => _showExitDialog = false);
            return false;
          }
          setState(() => _showExitDialog = true);
          return false;
        },
        child: Scaffold(
          body: Stack(
            children: [
              if (channels.isEmpty && !isLoading)
                Positioned.fill(
                  child: Container(
                    color: Colors.black87,
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.tv_off, color: Colors.white54, size: 64),
                          const SizedBox(height: 16),
                          const Text(
                            '暂无频道数据',
                            style: TextStyle(color: Colors.white, fontSize: 20),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            '请按【OK键】或点击屏幕进入设置添加直播源',
                            style: TextStyle(color: Colors.white70, fontSize: 14),
                          ),
                          const SizedBox(height: 24),
                          ElevatedButton.icon(
                            icon: const Icon(Icons.settings),
                            label: const Text('进入设置'),
                            onPressed: () {
                              Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsScreen()))
                                  .then((_) => setState(() {}));
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

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

              if (!_showEpgInfo)
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: () {
                      _showEpgInfoTemporarily();
                    },
                  ),
                ),

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
                        _showEpgInfo = false;
                        _epgInfoHideTimer?.cancel();
                        _focusNode.requestFocus();
                      }
                    });
                  },
                  child: Container(color: Colors.transparent),
                ),
              ),

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

              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _buildEpgInfoBar(),
              ),

              if (_channelNumberInput.isNotEmpty)
                Positioned(
                  top: MediaQuery.of(context).size.height * 0.25,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.75),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white.withOpacity(0.2)),
                      ),
                      child: Text(
                        _channelNumberInput,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 56,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 4,
                        ),
                      ),
                    ),
                  ),
                ),

              _buildExitDialog(),

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

  void _showAddSubscriptionDialog() {}

  void _showAddEpgDialog() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => SettingsScreen()),
    ).then((_) => setState(() {}));
  }
}
