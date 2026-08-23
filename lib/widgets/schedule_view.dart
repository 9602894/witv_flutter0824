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
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _selectedChannel = widget.selectedChannel;
    _loadPrograms();

    _epgListener = () {
      if (mounted) _loadPrograms();
    };
    EpgParser.epgUpdateCounter.addListener(_epgListener!);
  }

  @override
  void didUpdateWidget(ScheduleView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedChannel != oldWidget.selectedChannel) {
      _selectedChannel = widget.selectedChannel;
      _loadPrograms();
    }
  }

  Future<void> _loadPrograms() async {
    if (_selectedChannel == null) return;
    setState(() => _isLoading = true);
    try {
      if (widget.getChannelPrograms != null) {
        final programs = await widget.getChannelPrograms!(_selectedChannel!.name);
        setState(() {
          _programs = programs;
          _isLoading = false;
        });
      } else {
        final programs = await EpgParser.getProgramsByChannelName(_selectedChannel!.name);
        setState(() {
          _programs = programs;
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    if (_epgListener != null) {
      EpgParser.epgUpdateCounter.removeListener(_epgListener!);
    }
    super.dispose();
  }

  // ============================================================
  // 修改 2.1：按日期分组 + 当前高亮 + desc 显示
  // ============================================================
  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_programs.isEmpty) {
      return const Center(
        child: Text('暂无节目信息', style: TextStyle(color: Colors.white70)),
      );
    }

    // 按日期分组（东八区日期）
    final grouped = <DateTime, List<EpgProgram>>{};
    for (final program in _programs) {
      final date = EpgParser.beijingDate(program.start);
      grouped.putIfAbsent(date, () => []).add(program);
    }

    final sortedDates = grouped.keys.toList()..sort();
    final now = EpgParser.beijingNow;

    return ListView.builder(
      itemCount: sortedDates.length,
      itemBuilder: (context, dateIndex) {
        final date = sortedDates[dateIndex];
        final datePrograms = grouped[date]!;
        final dateStr = '${date.month}月${date.day}日';

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 日期标题
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: Colors.white.withOpacity(0.05),
              child: Text(
                dateStr,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            // 该日期的节目列表
            ...datePrograms.map((program) {
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
                  // desc 显示
                  subtitle: program.description.isNotEmpty
                      ? Text(
                          program.description,
                          style: TextStyle(
                            color: isCurrent ? Colors.yellow.withOpacity(0.7) : Colors.white54,
                            fontSize: 12,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
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
            }).toList(),
          ],
        );
      },
    );
  }
}
