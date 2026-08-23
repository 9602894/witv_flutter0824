import 'package:flutter/material.dart';
import '../models/channel.dart';
import '../models/epg_program.dart';
import '../services/epg_parser.dart';
import '../services/logo_service.dart';

class ScheduleView extends StatefulWidget {
  final List<Channel> channels;
  final Channel? selectedChannel;
  final Map<String, List<EpgProgram>> epgMap; // 废弃
  final ValueChanged<Channel> onSelectChannel;
  final double leftWeight;
  final double rightWeight;
  final ValueChanged<double> onLeftWeightChanged;
  final bool isEditMode;
  final bool showLeft;
  final LogoService logoService;
  final Future<List<EpgProgram>> Function(String)? getChannelPrograms; // 新增
  final String Function(DateTime)? formatTime; // 新增
  final DateTime? beijingNow; // 新增

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
  VoidCallback? _epgListener;   // 新增字段
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _selectedChannel = widget.selectedChannel;
    _loadPrograms();

    // EPG 更新后自动刷新节目单
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
        // 兼容旧方式
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
    // 移除 EPG 更新监听
    if (_epgListener != null) {
      EpgParser.epgUpdateCounter.removeListener(_epgListener!);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = widget.beijingNow ?? EpgParser.beijingNow;

    return Column(
      children: [
        // 频道信息头
        if (_selectedChannel != null)
          Container(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                FutureBuilder<String?>(
                  future: EpgParser.getChannelIcon(_selectedChannel!.name),
                  builder: (_, snapshot) {
                    final icon = snapshot.data;
                    if (icon != null && icon.isNotEmpty) {
                      return Image.network(icon, width: 32, height: 32,
                        errorBuilder: (_, __, ___) => const Icon(Icons.tv, color: Colors.white));
                    }
                    return const Icon(Icons.tv, color: Colors.white);
                  },
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _selectedChannel!.name,
                    style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),

        // 节目列表
        Expanded(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _programs.isEmpty
                  ? const Center(child: Text('暂无节目信息', style: TextStyle(color: Colors.white70)))
                  : ListView.builder(
                      itemCount: _programs.length,
                      itemBuilder: (context, index) {
                        final program = _programs[index];
                        final isCurrent = program.start.isBefore(now) && program.stop.isAfter(now);
                        final isPast = program.stop.isBefore(now);

                        final fmt = widget.formatTime ?? EpgParser.formatBeijingTime;

                        return ListTile(
                          dense: true,
                          leading: Text(
                            '${fmt(program.start)}',
                            style: TextStyle(
                              color: isCurrent ? Colors.green : (isPast ? Colors.white38 : Colors.white),
                              fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                              fontSize: 12,
                            ),
                          ),
                          title: Text(
                            program.title,
                            style: TextStyle(
                              color: isCurrent ? Colors.green : (isPast ? Colors.white38 : Colors.white),
                              fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                              fontSize: 14,
                            ),
                          ),
                          subtitle: program.description.isNotEmpty
                              ? Text(program.description,
                                  style: TextStyle(color: isPast ? Colors.white24 : Colors.white60, fontSize: 11),
                                  maxLines: 2, overflow: TextOverflow.ellipsis)
                              : null,
                          trailing: isCurrent
                              ? Container(
                                  width: 8, height: 8,
                                  decoration: const BoxDecoration(
                                    color: Colors.green,
                                    shape: BoxShape.circle,
                                  ),
                                )
                              : null,
                          onTap: () {
                            if (_selectedChannel != null) {
                              widget.onSelectChannel(_selectedChannel!);
                            }
                          },
                        );
                      },
                    ),
        ),
      ],
    );
  }
}
