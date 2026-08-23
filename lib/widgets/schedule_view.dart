import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../models/channel.dart';
import '../models/epg_program.dart';
import '../services/epg_parser.dart';
import '../services/logo_service.dart';

class ScheduleView extends StatefulWidget {
  final List<Channel> channels;
  final Channel? selectedChannel;
  final Map<String, List<EpgProgram>> epgMap;
  final ValueChanged<Channel> onSelectChannel;
  final double leftWeight;
  final double rightWeight;
  final ValueChanged<double> onLeftWeightChanged;
  final bool isEditMode;
  final bool showLeft;
  final LogoService logoService;
  final Future<List<EpgProgram>> Function(String)? getChannelPrograms;
  final String Function(DateTime)? formatTime;
  final DateTime? beijingNow;

  const ScheduleView({
    Key? key,
    required this.channels,
    required this.selectedChannel,
    required this.epgMap,
    required this.onSelectChannel,
    required this.leftWeight,
    required this.rightWeight,
    required this.onLeftWeightChanged,
    required this.isEditMode,
    required this.showLeft,
    required this.logoService,
    this.getChannelPrograms,
    this.formatTime,
    this.beijingNow,
  }) : super(key: key);

  @override
  _ScheduleViewState createState() => _ScheduleViewState();
}

class _ScheduleViewState extends State<ScheduleView> {
  Channel? _selectedChannel;
  List<EpgProgram> _programs = [];
  VoidCallback? _epgListener;
  VoidCallback? _logoListener;
  bool _isLoading = false;

  // 日期选择
  DateTime? _selectedDate;
  List<DateTime> _availableDates = [];

  // 台标字节
  Uint8List? _logoBytes;

  @override
  void initState() {
    super.initState();
    _selectedChannel = widget.selectedChannel;
    _loadPrograms();
    _loadLogo();

    _epgListener = () {
      if (mounted) _loadPrograms();
    };
    EpgParser.epgUpdateCounter.addListener(_epgListener!);

    _logoListener = () {
      if (mounted) _loadLogo();
    };
    LogoService().logoUpdateNotifier.addListener(_logoListener!);
  }

  @override
  void didUpdateWidget(ScheduleView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedChannel != oldWidget.selectedChannel) {
      _selectedChannel = widget.selectedChannel;
      _loadPrograms();
      _loadLogo();
    }
  }

  // 加载台标（使用 LogoService）
  Future<void> _loadLogo() async {
    if (_selectedChannel == null) {
      if (mounted) setState(() => _logoBytes = null);
      return;
    }
    final file = await widget.logoService.getLogo(_selectedChannel!.name);
    if (file != null && file.existsSync()) {
      final bytes = await file.readAsBytes();
      if (mounted) setState(() => _logoBytes = bytes);
    } else {
      if (mounted) setState(() => _logoBytes = null);
    }
  }

  // 按东八区日期分组加载
  Future<void> _loadPrograms() async {
    if (_selectedChannel == null) return;
    setState(() => _isLoading = true);
    try {
      final allPrograms = await (widget.getChannelPrograms != null
          ? widget.getChannelPrograms!(_selectedChannel!.name)
          : EpgParser.getProgramsByChannelName(_selectedChannel!.name));

      // 按东八区日期分组
      final grouped = <DateTime, List<EpgProgram>>{};
      for (final p in allPrograms) {
        final date = EpgParser.beijingDate(p.start);
        grouped.putIfAbsent(date, () => []).add(p);
      }

      _availableDates = grouped.keys.toList()..sort();
      final today = EpgParser.beijingDate(EpgParser.beijingNow);

      // 默认选中今天，如果没有就选第一天
      if (_selectedDate == null || !_availableDates.contains(_selectedDate)) {
        _selectedDate = _availableDates.contains(today) ? today : (_availableDates.isNotEmpty ? _availableDates.first : null);
      }

      _programs = (_selectedDate != null && grouped.containsKey(_selectedDate)) ? grouped[_selectedDate]! : [];
    } catch (e) {
      _programs = [];
    }
    setState(() => _isLoading = false);
  }

  @override
  void dispose() {
    if (_epgListener != null) {
      EpgParser.epgUpdateCounter.removeListener(_epgListener!);
    }
    if (_logoListener != null) {
      LogoService().logoUpdateNotifier.removeListener(_logoListener!);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        // ---------- 顶部日期横排选择器 ----------
        if (_availableDates.isNotEmpty)
          Container(
            height: 44,
            color: Colors.black.withOpacity(0.3),
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _availableDates.length,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemBuilder: (context, index) {
                final date = _availableDates[index];
                final isSelected = _selectedDate == date;
                final isToday = date == EpgParser.beijingDate(EpgParser.beijingNow);

                return GestureDetector(
                  onTap: () {
                    setState(() {
                      _selectedDate = date;
                    });
                    _loadPrograms();
                  },
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                    decoration: BoxDecoration(
                      color: isSelected ? Colors.yellow : Colors.white.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Center(
                      child: Text(
                        isToday ? '今天' : '${date.month}/${date.day}',
                        style: TextStyle(
                          color: isSelected ? Colors.black : Colors.white,
                          fontSize: 13,
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),

        // ---------- 频道标题（带台标，使用 LogoService） ----------
        if (_selectedChannel != null)
          Container(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                // 台标（使用 LogoService 加载的本地图片）
                if (_logoBytes != null)
                  Container(
                    width: 50,
                    height: 30,
                    color: Colors.transparent,
                    child: Image.memory(
                      _logoBytes!,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => const SizedBox(),
                    ),
                  ),
                const SizedBox(width: 8),
                Text(
                  _selectedChannel!.name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),

        // ---------- 节目列表 ----------
        Expanded(
          child: _programs.isEmpty
              ? const Center(
                  child: Text('暂无节目信息', style: TextStyle(color: Colors.white70)),
                )
              : ListView.builder(
                  itemCount: _programs.length,
                  itemBuilder: (context, index) {
                    final program = _programs[index];
                    final now = EpgParser.beijingNow;
                    final isCurrent = program.start.isBefore(now) && program.stop.isAfter(now);
                    final isPast = program.stop.isBefore(now);

                    return Container(
                      color: isCurrent ? Colors.yellow.withOpacity(0.15) : Colors.transparent,
                      child: ListTile(
                        dense: true,
                        leading: Text(
                          EpgParser.formatBeijingTime(program.start),
                          style: TextStyle(
                            color: isCurrent ? Colors.yellow : (isPast ? Colors.white38 : Colors.white70),
                            fontSize: 13,
                            fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                        title: Text(
                          program.title,
                          style: TextStyle(
                            color: isCurrent ? Colors.yellow : (isPast ? Colors.white38 : Colors.white),
                            fontSize: 14,
                            fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                        // desc 全部显示（不限制行数）
                        subtitle: program.description.isNotEmpty
                            ? Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  program.description,
                                  style: TextStyle(
                                    color: isCurrent ? Colors.yellow.withOpacity(0.7) : Colors.white54,
                                    fontSize: 12,
                                  ),
                                ),
                              )
                            : null,
                        trailing: isCurrent
                            ? Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.yellow,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Text(
                                  '正在播放',
                                  style: TextStyle(
                                    color: Colors.black,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              )
                            : null,
                        onTap: () {
                          if (_selectedChannel != null) {
                            widget.onSelectChannel(_selectedChannel!);
                          }
                        },
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
