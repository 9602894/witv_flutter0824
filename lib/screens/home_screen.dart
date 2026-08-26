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

  VoidCallback? _epgListener;
  bool _autoLoaded = false;
  bool _showExitMenu = false;
  int _exitMenuSelectedIndex = 0;
  int _rightMenuSelectedIndex = 0;
  String _digitDisplay = '';
  Timer? _digitHideTimer;

  // ---------- 新增焦点列控制 ----------
  bool _focusOnGroup = false; // true=焦点在分组列，false=焦点在频道列

  DateTime get _beijingNow => EpgParser.beijingNow;
  String _formatTime(DateTime time) => EpgParser.formatBeijingTime(time);
  String _getDate(DateTime time) {
    final bj = EpgParser.toBeijing(time);
    return '${bj.year}-${bj.month.toString().padLeft(2, '0')}-${bj.day.toString().padLeft(2, '0')}';
  }

  @override
  void initState() {
    super.initState();
    _initAsync();

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
    _digitHideTimer?.cancel();
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
    _digitHideTimer?.cancel();

    setState(() {
      currentChannel = ch;
      _selectedIndex = channels.indexOf(ch);
      _updateEpgInfo();
      // 切换频道后，焦点自动回到频道列
      _focusOnGroup = false;
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
    _digitHideTimer?.cancel();

    setState(() {
      currentGroup = groupName;
      channels = groupChannels;
      // 切换分组后，选中第一个频道，并将焦点移到频道列
      if (channels.isNotEmpty) {
        _selectedIndex = 0;
        currentChannel = channels.first;
        _updateEpgInfo();
        _showEpgInfoTemporarily();
        _focusOnGroup = false; // 焦点回到频道列
      } else {
        _selectedIndex = -1;
        currentChannel = null;
      }
    });

    _logoService.preloadAllLogos(channels);
    _tryDownloadLogos();
    if (currentChannel != null) {
      _updateEpgInfo();
      _showEpgInfoTemporarily();
    }
  }

  // ---------- 修改后的按键处理 ----------
  void _handleKeyEvent(RawKeyEvent event) {
    if (event is! RawKeyDownEvent) return;
    final key = event.logicalKey;
    final keyId = key.keyId;
    final label = key.keyLabel.toLowerCase();

    final isUp = key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.numpad8 ||
                 keyId == 0x100000304 || keyId == 0x01000026 || label.contains('up');
    final isDown = key == LogicalKeyboardKey.arrowDown || key == LogicalKeyboardKey.numpad2 ||
                   keyId == 0x100000301 || keyId == 0x01000028 || label.contains('down');
    final isLeft = key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.numpad4 ||
                   keyId == 0x100000302 || keyId == 0x01000025 || label.contains('left');
    final isRight = key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.numpad6 ||
                    keyId == 0x100000303 || keyId == 0x01000027 || label.contains('right');
    final isOk = key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.select ||
                 key == LogicalKeyboardKey.accept || keyId == 0x100000161 ||
                 keyId == 0x10000000d || label.contains('enter') || label.contains('select');
    final isBack = key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.goBack ||
                   key == LogicalKeyboardKey.backspace || keyId == 0x100000803 ||
                   keyId == 0x100000008 || label.contains('back');
    final isMenu = key == LogicalKeyboardKey.contextMenu || keyId == 0x100000805 ||
                   label.contains('menu');

    // ---------- 退出菜单 ----------
    if (_showExitMenu) {
      if (isUp) {
        setState(() => _exitMenuSelectedIndex = (_exitMenuSelectedIndex - 1 + 2) % 2);
      } else if (isDown) {
        setState(() => _exitMenuSelectedIndex = (_exitMenuSelectedIndex + 1) % 2);
      } else if (isOk) {
        if (_exitMenuSelectedIndex == 0) {
          setState(() => _showExitMenu = false);
          Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsScreen()))
              .then((_) => setState(() {}));
        } else {
          exit(0);
        }
      } else if (isBack) {
        setState(() => _showExitMenu = false);
      }
      return;
    }

    // ---------- 数字键 ----------
    final digitKeys = [
      LogicalKeyboardKey.digit0, LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2, LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4, LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.digit6, LogicalKeyboardKey.digit7,
      LogicalKeyboardKey.digit8, LogicalKeyboardKey.digit9,
    ];
    if (digitKeys.contains(key)) {
      _digitTimer?.cancel();
      _digitHideTimer?.cancel();
      _digitBuffer += key.keyLabel;
      setState(() => _digitDisplay = _digitBuffer);
      _digitHideTimer = Timer(const Duration(milliseconds: 2000), () {
        if (mounted) setState(() => _digitDisplay = '');
      });
      _digitTimer = Timer(const Duration(milliseconds: 1500), () {
        _jumpToChannelNumber(_digitBuffer);
        if (mounted) setState(() { _digitBuffer = ''; _digitDisplay = ''; });
      });
      return;
    }

    if (_digitBuffer.isNotEmpty) {
      _digitTimer?.cancel();
      _digitHideTimer?.cancel();
      _jumpToChannelNumber(_digitBuffer);
      if (mounted) setState(() { _digitBuffer = ''; _digitDisplay = ''; });
    }

    // ---------- 右侧菜单 ----------
    if (_showRightMenu) {
      const menuItemsCount = 5;
      if (isUp) {
        setState(() => _rightMenuSelectedIndex = (_rightMenuSelectedIndex - 1 + menuItemsCount) % menuItemsCount);
      } else if (isDown) {
        setState(() => _rightMenuSelectedIndex = (_rightMenuSelectedIndex + 1) % menuItemsCount);
      } else if (isOk) {
        _executeRightMenuAction(_rightMenuSelectedIndex);
      } else if (isBack || isMenu) {
        setState(() => _showRightMenu = false);
      }
      return;
    }

    // ---------- 频道列表模式（含焦点切换） ----------
    if (showChannelList && !isScheduleMode) {
      if (channels.isEmpty) return;

      // 左右键切换焦点列
      if (isLeft) {
        if (!_focusOnGroup) {
          setState(() => _focusOnGroup = true);
        }
        return;
      } else if (isRight) {
        if (_focusOnGroup) {
          setState(() => _focusOnGroup = false);
        }
        return;
      }

      // 上下键根据焦点列执行不同操作
      if (isUp) {
        if (_focusOnGroup) {
          // 焦点在分组列：切换到上一个分组
          if (groups.isNotEmpty) {
            final currentIdx = groups.indexOf(currentGroup!);
            final prevIdx = (currentIdx - 1 + groups.length) % groups.length;
            _switchToGroup(groups[prevIdx]);
          }
        } else {
          // 焦点在频道列：切换到上一个频道，边界跳转分组
          if (_selectedIndex > 0) {
            setState(() => _selectedIndex--);
          } else {
            if (groups.isNotEmpty) {
              final currentIdx = groups.indexOf(currentGroup!);
              final prevIdx = (currentIdx - 1 + groups.length) % groups.length;
              _switchToGroup(groups[prevIdx]);
              // _switchToGroup 内部已将焦点置为频道列，并选中第一个，但我们需要选中最后一个
              if (channels.isNotEmpty) {
                setState(() {
                  _selectedIndex = channels.length - 1;
                  currentChannel = channels.last;
                  _updateEpgInfo();
                  _showEpgInfoTemporarily();
                });
              }
            }
          }
        }
      } else if (isDown) {
        if (_focusOnGroup) {
          // 焦点在分组列：切换到下一个分组
          if (groups.isNotEmpty) {
            final currentIdx = groups.indexOf(currentGroup!);
            final nextIdx = (currentIdx + 1) % groups.length;
            _switchToGroup(groups[nextIdx]);
          }
        } else {
          // 焦点在频道列：切换到下一个频道，边界跳转分组
          if (_selectedIndex < channels.length - 1) {
            setState(() => _selectedIndex++);
          } else {
            if (groups.isNotEmpty) {
              final currentIdx = groups.indexOf(currentGroup!);
              final nextIdx = (currentIdx + 1) % groups.length;
              _switchToGroup(groups[nextIdx]);
              // _switchToGroup 内部已将焦点置为频道列，并选中第一个
              if (channels.isNotEmpty) {
                setState(() {
                  _selectedIndex = 0;
                  currentChannel = channels.first;
                  _updateEpgInfo();
                  _showEpgInfoTemporarily();
                });
              }
            }
          }
        }
      } else if (isOk) {
        // OK键：如果焦点在分组列，则切换到该分组并自动将焦点移到频道列
        if (_focusOnGroup) {
          // 已在分组列，直接切换分组（但当前选中分组已由currentGroup表示）
          // 这里可以不做额外操作，因为切换分组已经由上下键完成；OK键可视为确认选择当前分组，即切换到频道列
          setState(() => _focusOnGroup = false);
          if (channels.isNotEmpty && currentChannel == null) {
            _switchChannel(channels.first);
          }
        } else {
          // 焦点在频道列，则播放选中频道
          if (_selectedIndex >= 0 && _selectedIndex < channels.length) {
            _switchChannel(channels[_selectedIndex]);
          }
        }
      } else if (isBack || isMenu) {
        setState(() => showChannelList = false);
      }
      return;
    }

    // ---------- 节目单模式 ----------
    if (isScheduleMode) {
      if (isBack) {
        setState(() => isScheduleMode = false);
      }
      // 如需在节目单中增加左右键滚动时间，可在此扩展
      return;
    }

    // ---------- 无窗口全屏播放 ----------
    if (isOk || isMenu) {
      setState(() {
        isScheduleMode = false;
        showChannelList = true;
        _showRightMenu = false;
        _showEpgInfo = false;
        _epgInfoHideTimer?.cancel();
        // 显示频道列表时默认焦点在频道列
        _focusOnGroup = false;
      });
    } else if (isBack) {
      setState(() { _showExitMenu = true; _exitMenuSelectedIndex = 0; });
    } else if (isUp) {
      // 切换上一个频道，边界跳转分组
      if (channels.isNotEmpty) {
        if (_selectedIndex > 0) {
          setState(() => _selectedIndex--);
          _switchChannel(channels[_selectedIndex]);
        } else {
          if (groups.isNotEmpty) {
            final currentIdx = groups.indexOf(currentGroup!);
            final prevIdx = (currentIdx - 1 + groups.length) % groups.length;
            _switchToGroup(groups[prevIdx]);
            if (channels.isNotEmpty) {
              setState(() {
                _selectedIndex = channels.length - 1;
                currentChannel = channels.last;
                _updateEpgInfo();
                _showEpgInfoTemporarily();
              });
            }
          }
        }
      }
    } else if (isDown) {
      // 切换下一个频道，边界跳转分组
      if (channels.isNotEmpty) {
        if (_selectedIndex < channels.length - 1) {
          setState(() => _selectedIndex++);
          _switchChannel(channels[_selectedIndex]);
        } else {
          if (groups.isNotEmpty) {
            final currentIdx = groups.indexOf(currentGroup!);
            final nextIdx = (currentIdx + 1) % groups.length;
            _switchToGroup(groups[nextIdx]);
            if (channels.isNotEmpty) {
              setState(() {
                _selectedIndex = 0;
                currentChannel = channels.first;
                _updateEpgInfo();
                _showEpgInfoTemporarily();
              });
            }
          }
        }
      }
    }
    // 左右键在全屏播放时可预留为快进/快退，本修改不实现
  }

  // 其他辅助方法（原样）
  void _executeRightMenuAction(int index) {
    setState(() => _showRightMenu = false);
    switch (index) {
      case 0:
        Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsScreen())).then((_) => setState(() {}));
        break;
      case 1:
        if (isEditMode) { _exitEditMode(); } else { setState(() => isEditMode = true); }
        break;
      case 2: _showAddSubscriptionDialog(); break;
      case 3: _showAddEpgDialog(); break;
      case 4: break;
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
                          currentChannel != null && currentChannel!.number != null
                              ? '${currentChannel!.number}. ${currentChannel!.name}'
                              : (currentChannel?.name ?? ''),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
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
              width: 36,
              alignment: Alignment.center,
              child: Text('${channel.number}', style: TextStyle(color: isSelected ? Colors.yellow : Colors.white70, fontSize: 13, fontWeight: FontWeight.bold)),
            ),
          ChannelLogo(channelName: channel.name, width: 36, height: 24, fit: BoxFit.contain),
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
          if (_showExitMenu) {
            setState(() => _showExitMenu = false);
            return false;
          }
          setState(() { _showExitMenu = true; _exitMenuSelectedIndex = 0; });
          return false;
        },
        child: Scaffold(
          body: Stack(
            children: [
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
                        Expanded(flex: (groupWeight * 100).toInt(), child: _buildGroupListWithFocus()),
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
                                child: _buildChannelListWithFocus(),
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
                        }, 0),
                        _buildMenuItem(Icons.edit, '编辑', () {
                          if (isEditMode) {
                            _exitEditMode();
                          } else {
                            setState(() => isEditMode = true);
                          }
                          setState(() => _showRightMenu = false);
                        }, 1),
                        _buildMenuItem(Icons.list, '列表订阅', () {
                          _showAddSubscriptionDialog();
                          setState(() => _showRightMenu = false);
                        }, 2),
                        _buildMenuItem(Icons.tv, 'EPG订阅', () {
                          _showAddEpgDialog();
                          setState(() => _showRightMenu = false);
                        }, 3),
                        _buildMenuItem(Icons.close, '关闭', () {
                          setState(() => _showRightMenu = false);
                        }, 4),
                      ],
                    ),
                  ),
                ),

              // 退出菜单
              if (_showExitMenu)
                Positioned.fill(
                  child: GestureDetector(
                    onTap: () => setState(() => _showExitMenu = false),
                    child: Container(
                      color: Colors.black.withOpacity(0.7),
                      child: Center(
                        child: GestureDetector(
                          onTap: () {},
                          child: Container(
                            width: 280,
                            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.85),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.white.withOpacity(0.2)),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text('菜单', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                                const SizedBox(height: 16),
                                _buildExitMenuItem('设置', Icons.settings, 0),
                                const SizedBox(height: 8),
                                _buildExitMenuItem('退出', Icons.exit_to_app, 1),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

              // 数字键输入显示
              if (_digitDisplay.isNotEmpty)
                Positioned(
                  top: 60,
                  right: 20,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.7),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _digitDisplay,
                      style: const TextStyle(color: Colors.yellow, fontSize: 24, fontWeight: FontWeight.bold),
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

  // ---------- 新增带焦点指示的分组列表和频道列表 ----------
  Widget _buildGroupListWithFocus() {
    return Container(
      decoration: BoxDecoration(
        border: _focusOnGroup
            ? Border.all(color: Colors.yellow, width: 2)
            : null,
      ),
      child: GroupList(
        groups: groups,
        selectedGroup: currentGroup,
        onSelect: (group) {
          _switchToGroup(group);
          // 切换分组后焦点自动移至频道列
          setState(() => _focusOnGroup = false);
        },
      ),
    );
  }

  Widget _buildChannelListWithFocus() {
    return Container(
      decoration: BoxDecoration(
        border: !_focusOnGroup
            ? Border.all(color: Colors.yellow, width: 2)
            : null,
      ),
      child: ListView.builder(
        itemCount: channels.length,
        itemBuilder: (context, index) => _buildChannelItem(channels[index], index),
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

  Widget _buildExitMenuItem(String label, IconData icon, int index) {
    final isSelected = index == _exitMenuSelectedIndex;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
      decoration: BoxDecoration(
        color: isSelected ? Colors.blue.withOpacity(0.6) : Colors.white.withOpacity(0.08),
        borderRadius: BorderRadius.circular(8),
        border: isSelected ? Border.all(color: Colors.blueAccent, width: 2) : Border.all(color: Colors.transparent),
      ),
      child: Row(
        children: [
          Icon(icon, color: isSelected ? Colors.white : Colors.white70, size: 22),
          const SizedBox(width: 12),
          Text(label, style: TextStyle(color: isSelected ? Colors.white : Colors.white70, fontSize: 16, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
        ],
      ),
    );
  }

  Widget _buildMenuItem(IconData icon, String label, VoidCallback onTap, int index) {
    final isSelected = _showRightMenu && _rightMenuSelectedIndex == index;
    return ListTile(
      leading: Icon(icon, color: isSelected ? Colors.yellow : Colors.white),
      title: Text(label, style: TextStyle(color: isSelected ? Colors.yellow : Colors.white, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
      tileColor: isSelected ? Colors.white.withOpacity(0.15) : Colors.transparent,
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
