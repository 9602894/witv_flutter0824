import 'dart:io';
import 'package:flutter/material.dart';
import '../models/channel.dart';
import '../models/epg_program.dart';
import '../services/logo_service.dart';

class _ChannelLogo extends StatefulWidget {
  final String channelName;
  const _ChannelLogo({required this.channelName});

  @override
  State<_ChannelLogo> createState() => _ChannelLogoState();
}

class _ChannelLogoState extends State<_ChannelLogo> {
  File? _logoFile;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_ChannelLogo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channelName != widget.channelName) {
      if (mounted) setState(() => _logoFile = null);
      _load();
    }
  }

  Future<void> _load() async {
    final service = LogoService();
    final file = await service.getLogo(widget.channelName);
    if (mounted && file != null && file.existsSync()) {
      // 清除 Flutter 图片缓存，强制重新解码
      PaintingBinding.instance.imageCache.evict(FileImage(file));
      setState(() => _logoFile = file);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_logoFile != null && _logoFile!.existsSync()) {
      return Image.file(
        _logoFile!,
        key: ValueKey(_logoFile!.path),
        width: 32,
        height: 32,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => const Icon(Icons.tv, color: Colors.white54, size: 24),
      );
    }
    return const Icon(Icons.tv, color: Colors.white54, size: 24);
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
    this.showChannelNumber = false,
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
        return ListTile(
          dense: true,
          leading: showLogo
              ? _ChannelLogo(channelName: channel.name)
              : null,
          title: Text(
            showChannelNumber && channel.number != null
                ? '${channel.number}. ${channel.name}'
                : channel.name,
            style: TextStyle(
              color: isSelected ? Colors.yellow : Colors.white,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              fontSize: 14,
            ),
          ),
          selected: isSelected,
          onTap: () => onSelect(channel),
        );
      },
    );
  }
}
