import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class IjkPlayerWidget extends StatefulWidget {
  final String url;
  final VoidCallback? onError;
  final ValueChanged<double>? onSpeedUpdate;
  final int decoderIndex;

  const IjkPlayerWidget({
    Key? key,
    required this.url,
    this.onError,
    this.onSpeedUpdate,
    this.decoderIndex = 0,
  }) : super(key: key);

  @override
  _IjkPlayerWidgetState createState() => _IjkPlayerWidgetState();
}

class _IjkPlayerWidgetState extends State<IjkPlayerWidget> {
  static const MethodChannel _channel = MethodChannel('com.example.witv/ijkplayer');
  Timer? _speedTimer;

  @override
  void initState() {
    super.initState();
    _startSpeedTimer();
  }

  void _startSpeedTimer() {
    _speedTimer?.cancel();
    _speedTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      try {
        final speed = await _channel.invokeMethod<double>('getSpeed');
        if (speed != null && widget.onSpeedUpdate != null) {
          widget.onSpeedUpdate!(speed);
        }
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _speedTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AndroidView(
      // 修复：viewType 必须与 MainActivity.kt 中注册的名字一致
      viewType: 'ijkplayer_view',
      creationParams: <String, dynamic>{
        'url': widget.url,
        'decoderIndex': widget.decoderIndex,
      },
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: (int id) {
        _channel.setMethodCallHandler((call) async {
          if (call.method == 'onError') {
            widget.onError?.call();
          }
          return null;
        });
      },
    );
  }
}

