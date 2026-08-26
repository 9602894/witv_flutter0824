import 'package:flutter/material.dart';
import 'ijk_player_widget.dart';

class PlayerWidget extends StatefulWidget {
  final String url;
  final int decoderIndex;
  final VoidCallback? onError;
  final ValueChanged<double>? onSpeedUpdate;

  const PlayerWidget({
    Key? key,
    required this.url,
    this.decoderIndex = 0,
    this.onError,
    this.onSpeedUpdate,
  }) : super(key: key);

  @override
  State<PlayerWidget> createState() => _PlayerWidgetState();
}

class _PlayerWidgetState extends State<PlayerWidget> {
  @override
  Widget build(BuildContext context) {
    return IjkPlayerWidget(
      url: widget.url,
      decoderIndex: widget.decoderIndex,
      onError: widget.onError,
      onSpeedUpdate: widget.onSpeedUpdate,
    );
  }
}

