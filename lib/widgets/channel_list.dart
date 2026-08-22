import 'dart:io';
import 'package:flutter/material.dart';
import '../models/channel.dart';
import '../models/epg_program.dart';
import '../services/logo_service.dart';

// ---------- 独立的台标组件（StatefulWidget，避免 FutureBuilder 闪烁） ----------
class _ChannelLogo extends StatefulWidget {
  final String channelName;
  final String? fallbackUrl;
  const _ChannelLogo({required this.channelName, this.fallbackUrl});

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
    final epgId = await service.getEpgIdAsync(widget.channelName);
    final cachedByEpgId = service.getLogoByEpgIdSync(epgId);
    if (cachedByEpgId != null && cachedByEpgId.existsSync()) {
      if (mounted) setState(() => _logoFile = cachedByEpgId);
      return;
    }
    final cached = service.getLogoSync(widget.channelName);
    if (cached != null && cached.existsSync()) {
      if (mounted) setState(() => _logoFile = cached);
      return;
    }
    final file = await service.getLogo(widget.channelName);
    if (mounted && file != null && file.existsSync()) {
      setState(() => _logoFile = file);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_logoFile != null && _logoFile!.existsSync()) {
      return Image.file(
        _logoFile!,
        width: 32,
        height: 32,
        errorBuilder: (_, __, ___) => const Icon(Icons.tv, color: Colors.white54, size: 24),
      );
    }
    if (widget.fallbackUrl != null && widget.fallbackUrl!.isNotEmpty) {
      return Image.network(
        widget.fallbackUrl!,
        width: 32,
        height: 32,
        errorBuilder: (_, __, ___) => const Icon(Icons.tv, color: Colors.white54, size: 24),
      );
    }
    return const Icon(Icons.tv, color: Colors.white54, size: 24);
  }
}

// ---------- ChannelList ----------
class ChannelList extends StatelessWidget {
  final List<Channel> channels;
  final Channel? selectedChannel;
  final ValueChanged<Channel> onSelect;
  final Map<String, List<EpgProgram>> epgMap;
  final bool showChannelNumber;
  final bool showLogo;
  final EpgProgram? currentEpgProgram;
  final EpgProgram? nextEpgProgram;

  const ChannelList({
    Key? key,
    required this.channels,
    required this.selectedChannel,
    required this.onSelect,
    required this.epgMap,
    this.showChannelNumber = false,
    this.showLogo = true,
    this.currentEpgProgram,
    this.nextEpgProgram,
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
          subtitle: isSelected && (currentEpgProgram != null || nextEpgProgram != null)
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (currentEpgProgram != null)
                      Text(
                        '▶ ${currentEpgProgram!.title}',
                        style: const TextStyle(color: Colors.green, fontSize: 12),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    if (nextEpgProgram != null)
                      Text(
                        '▷ ${nextEpgProgram!.title}',
                        style: const TextStyle(color: Colors.white70, fontSize: 11),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                )
              : null,
          selected: isSelected,
          onTap: () => onSelect(channel),
        );
      },
    );
  }
}
