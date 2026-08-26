import 'package:flutter/material.dart';
import '../models/channel.dart';
import '../models/epg_program.dart';
import 'channel_logo.dart';

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
    this.showChannelNumber = true,   // 改为 true
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
              ? ChannelLogo(
                  channelName: channel.name,
                  width: 32,
                  height: 32,
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
