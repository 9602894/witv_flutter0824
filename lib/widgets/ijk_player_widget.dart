import 'dart:async';
import 'package:flutter/material.dart';
import 'package:ijkplayer_flutter_sdk/ijkplayer_flutter_sdk.dart';

class IjkPlayerWidget extends StatefulWidget {
  final String url;
  final VoidCallback? onError;
  final Function(double speed)? onSpeedUpdate;

  const IjkPlayerWidget({
    Key? key,
    required this.url,
    this.onError,
    this.onSpeedUpdate,
  }) : super(key: key);

  @override
  _IjkPlayerWidgetState createState() => _IjkPlayerWidgetState();
}

class _IjkPlayerWidgetState extends State<IjkPlayerWidget> {
  late FlutterIjkPlayer _player;
  bool _isLoading = true;
  bool _hasError = false;
  Timer? _speedTimer;

  @override
  void initState() {
    super.initState();
    try {
      _player = FlutterIjkPlayer();
      // 硬件解码 + 华为海思兼容修复
      _player.setOption(1, "mediacodec", 1);
      _player.setOption(1, "mediacodec-auto-rotate", 0);           // 关闭自动旋转
      _player.setOption(1, "mediacodec-handle-resolution-change", 0); // 关闭分辨率变化处理
      _player.setOption(1, "opensles", 0);                         // 使用AudioTrack而非OpenSL ES
      _player.setOption(1, "videotoolbox", 1);
      _player.setDataSource(widget.url, autoPlay: true);

      // 状态监听
      _player.addListener(() {
        final state = _player.value.state;
        if (state == 2 && !_hasError) {
          setState(() => _isLoading = false);
        } else if (state == 6) {
          setState(() {
            _isLoading = false;
            _hasError = true;
          });
          widget.onError?.call();
        }
      });

      // 模拟速度更新（每秒一次）
      _speedTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }
        final speed = 0.5 + (DateTime.now().millisecond % 10) / 2.0;
        widget.onSpeedUpdate?.call(speed);
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
        _hasError = true;
      });
      widget.onError?.call();
    }
  }

  @override
  void dispose() {
    _speedTimer?.cancel();
    _player.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_hasError) {
      return const Center(
        child: Text('播放器初始化失败', style: TextStyle(color: Colors.white)),
      );
    }
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(color: Colors.white));
    }
    return FlutterIjkView(player: _player, color: Colors.black);
  }
}
