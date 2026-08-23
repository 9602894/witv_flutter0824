import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/painting.dart';
import '../models/channel.dart';
import '../models/epg_program.dart';
import '../services/logo_service.dart';

class _ChannelLogo extends StatefulWidget {
  final String channelName;
  final String? fallbackUrl;
  const _ChannelLogo({required this.channelName, this.fallbackUrl});

  @override
  State<_ChannelLogo> createState() => _ChannelLogoState();
}

class _ChannelLogoState extends State<_ChannelLogo> {
  Uint8List? _logoBytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_ChannelLogo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channelName != widget.channelName) {
      if (mounted) setState(() => _logoBytes = null);
      _load();
    }
  }

  Future<void> _load() async {
    final service = LogoService();
    final file = await service.getLogo(
      widget.channelName,
      fallbackUrl: widget.fallbackUrl,
    );
    if (mounted && file != null && file.existsSync()) {
      final bytes = await file.readAsBytes();
      setState(() => _logoBytes = bytes);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_logoBytes != null && _logoBytes!.isNotEmpty) {
      return Image.memory(
        _logoBytes!,
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
              ? _ChannelLogo(
                  channelName: channel.name,
                  fallbackUrl: channel.logoUrl,
                )
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
