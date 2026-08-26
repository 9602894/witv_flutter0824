import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../models/channel.dart';
import '../models/epg_program.dart';
import '../services/logo_service.dart';

class ChannelLogo extends StatefulWidget {
  final String channelName;
  final double width;
  final double height;
  final BoxFit fit;
  final Color? backgroundColor;

  const ChannelLogo({
    Key? key,
    required this.channelName,
    this.width = 32,
    this.height = 32,
    this.fit = BoxFit.contain,
    this.backgroundColor,
  }) : super(key: key);

  @override
  State<ChannelLogo> createState() => _ChannelLogoState();
}

class _ChannelLogoState extends State<ChannelLogo> {
  Uint8List? _logoBytes;
  VoidCallback? _logoListener;

  @override
  void initState() {
    super.initState();
    _load();
    _logoListener = () { if (mounted) _load(); };
    LogoService().logoUpdateNotifier.addListener(_logoListener!);
  }

  @override
  void didUpdateWidget(ChannelLogo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channelName != widget.channelName) {
      if (mounted) setState(() => _logoBytes = null);
      _load();
    }
  }

  @override
  void dispose() {
    if (_logoListener != null) {
      LogoService().logoUpdateNotifier.removeListener(_logoListener!);
    }
    super.dispose();
  }

  Future<void> _load() async {
    final service = LogoService();
    final file = await service.getLogo(widget.channelName);
    if (mounted && file != null && file.existsSync()) {
      final bytes = await file.readAsBytes();
      setState(() => _logoBytes = bytes);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_logoBytes != null && _logoBytes!.isNotEmpty) {
      return Container(
        width: widget.width,
        height: widget.height,
        color: widget.backgroundColor ?? Colors.transparent,
        child: Image.memory(
          _logoBytes!,
          width: widget.width,
          height: widget.height,
          fit: widget.fit,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => _buildPlaceholder(),
        ),
      );
    }
    return _buildPlaceholder();
  }

  Widget _buildPlaceholder() {
    return SizedBox(width: widget.width, height: widget.height);
  }
}

class ChannelList extends StatelessWidget {
  final List<Channel> channels;
  final Channel? selectedChannel;
  final ValueChanged<Channel> onSelect;
  final Map<String, List<EpgProgram>> epgMap;
  final bool showChannelNumber;
  final bool showLogo;

  const ChannelList({
    Key? key,
    required this.channels,
    required this.selectedChannel,
    required this.onSelect,
    required this.epgMap,
    this.showChannelNumber = true,
    this.showLogo = true,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      key: ValueKey('cl_${channels.hashCode}'),
      itemCount: channels.length,
      itemBuilder: (context, index) {
        final channel = channels[index];
        final isSelected = channel == selectedChannel;
        return InkWell(
          onTap: () => onSelect(channel),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: isSelected ? Colors.white.withOpacity(0.1) : Colors.transparent,
              border: Border(
                left: BorderSide(
                  color: isSelected ? Colors.yellow : Colors.transparent,
                  width: 3,
                ),
              ),
            ),
            child: Row(
              children: [
                if (showChannelNumber && channel.number != null)
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
                if (showLogo)
                  ChannelLogo(
                    channelName: channel.name,
                    width: 32,
                    height: 32,
                  ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    showChannelNumber && channel.number != null
                        ? '${channel.number}. ${channel.name}'
                        : channel.name,
                    style: TextStyle(
                      color: isSelected ? Colors.yellow : Colors.white,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                      fontSize: 14,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
