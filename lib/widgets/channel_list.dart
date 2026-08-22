import 'dart:io';  // ⬅️ 新增导入，用于 File 类
import 'package:flutter/material.dart';
import '../models/channel.dart';
import '../models/epg_program.dart';
import '../services/logo_service.dart';

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
      itemCount: channels.length,
      itemBuilder: (context, index) {
        final channel = channels[index];
        final isSelected = channel == selectedChannel;
        return ListTile(
          dense: true,
          leading: showLogo ? _buildLogo(channel) : null,
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

  // 修改：优先使用本地下载的 Logo，降级使用 M3U 自带 URL
  Widget _buildLogo(Channel channel) {
    final logoService = LogoService();
    return FutureBuilder<File?>(
      future: logoService.getLogo(channel.name),
      builder: (context, snapshot) {
        final file = snapshot.data;
        if (file != null && file.existsSync()) {
          return Image.file(
            file,
            width: 32,
            height: 32,
            errorBuilder: (_, __, ___) => const Icon(Icons.tv, color: Colors.white54, size: 24),
          );
        }
        // 本地没有，降级用 M3U 自带的网络 URL
        if (channel.logoUrl != null && channel.logoUrl!.isNotEmpty) {
          return Image.network(
            channel.logoUrl!,
            width: 32,
            height: 32,
            errorBuilder: (_, __, ___) => const Icon(Icons.tv, color: Colors.white54, size: 24),
          );
        }
        return const Icon(Icons.tv, color: Colors.white54, size: 24);
      },
    );
  }
}
