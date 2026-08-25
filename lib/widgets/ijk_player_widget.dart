import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class IjkPlayerWidget extends StatefulWidget {
  final String url;
  final VoidCallback? onError;
  final ValueChanged<double>? onSpeedUpdate;
  final int decoderIndex; // 0=硬解, 1=软解

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
      viewType: 'com.example.witv/ijkplayer',
      creationParams: <String, dynamic>{
        'url': widget.url,
        'decoderIndex': widget.decoderIndex,
        // 华为悦盒等低端盒子花屏修复参数
        'useTextureView': true,           // 使用 TextureView 替代 SurfaceView，兼容性更好
        'overlayFormat': 'fcc-rv32',      // RGBA32 格式，避免 YUV 转换问题
        'pixelFormat': 'fcc-rv32',        // 像素格式统一
        'framedrop': 1,                   // 允许丢帧保持同步
        'maxFps': 30,                     // 限制最大帧率
        'mediacodecAllVideos': 0,         // 不强制所有视频硬解
        'mediacodecHevc': 0,              // 禁用 HEVC 硬解（很多盒子不支持）
        'mediacodecMpeg2': 0,             // 禁用 MPEG2 硬解
        'mediacodecMpeg4': 0,             // 禁用 MPEG4 硬解
        'videotoolbox': 0,                // 禁用 videotoolbox（iOS 专用，Android 无效但无害）
        'dnsCacheClear': 1,               // 清除 DNS 缓存
        'fflags': 'fastseek',             // 快速 seek
        'reconnect': 1,                   // 自动重连
        'timeout': 30000000,              // 30秒超时（微秒）
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
