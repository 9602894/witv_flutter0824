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

  // 修改 _load() —— 先走缓存，再尝试 fallback 处理
  Future<void> _load() async {
    final service = LogoService();
    
    // 1. 先尝试从缓存/下载获取处理过的台标
    final file = await service.getLogo(widget.channelName);
    if (mounted && file != null && file.existsSync()) {
      setState(() => _logoFile = file);
      return;
    }
    
    // 2. 如果 getLogo 失败，但有 fallbackUrl，把 fallbackUrl 也下载处理
    if (widget.fallbackUrl != null && widget.fallbackUrl!.isNotEmpty) {
      final processedFile = await service.downloadAndProcess(
        widget.channelName, 
        widget.fallbackUrl!,
      );
      if (mounted && processedFile != null && processedFile.existsSync()) {
        setState(() => _logoFile = processedFile);
        return;
      }
    }
    
    // 3. 都失败，显示默认图标
    if (mounted) setState(() => _logoFile = null);
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
    // 删除这里的 Image.network(fallbackUrl!) 直接显示逻辑
    // fallbackUrl 已经在 _load() 中通过 downloadAndProcess 处理过了
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
