import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class IjkPlayerWidget extends StatefulWidget {
  final String url;
  final int decoderIndex;
  final VoidCallback? onError;
  final ValueChanged<double>? onSpeedUpdate;

  const IjkPlayerWidget({
    Key? key,
    required this.url,
    this.decoderIndex = 0,
    this.onError,
    this.onSpeedUpdate,
  }) : super(key: key);

  @override
  State<IjkPlayerWidget> createState() => _IjkPlayerWidgetState();
}

class _IjkPlayerWidgetState extends State<IjkPlayerWidget> {
  static const MethodChannel _channel = MethodChannel('com.example.witv/ijkplayer');
  int _viewId = -1;

  @override
  void initState() {
    super.initState();
    _createPlayer();
  }

  @override
  void didUpdateWidget(IjkPlayerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _setDataSource(widget.url);
    }
    if (oldWidget.decoderIndex != widget.decoderIndex) {
      _setDecoder(widget.decoderIndex);
    }
  }

  @override
  void dispose() {
    _releasePlayer();
    super.dispose();
  }

  Future<void> _createPlayer() async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>('createPlayer');
      if (result != null) {
        _viewId = result['viewId'] as int;
        // 华为悦盒6110M花屏修复：关闭mediacodec-auto-rotate和mediacodec-handle-resolution-change
        await _channel.invokeMethod('setOption', {
          'viewId': _viewId,
          'category': 1,
          'name': 'mediacodec',
          'value': widget.decoderIndex == 0 ? 1 : 0,
        });
        await _channel.invokeMethod('setOption', {
          'viewId': _viewId,
          'category': 1,
          'name': 'mediacodec-auto-rotate',
          'value': 0,  // 华为海思兼容：关闭自动旋转
        });
        await _channel.invokeMethod('setOption', {
          'viewId': _viewId,
          'category': 1,
          'name': 'mediacodec-handle-resolution-change',
          'value': 0,  // 华为海思兼容：关闭分辨率变化处理
        });
        await _channel.invokeMethod('setOption', {
          'viewId': _viewId,
          'category': 1,
          'name': 'opensles',
          'value': 0,
        });
        await _channel.invokeMethod('setOption', {
          'viewId': _viewId,
          'category': 1,
          'name': 'framedrop',
          'value': 5,
        });
        await _channel.invokeMethod('setOption', {
          'viewId': _viewId,
          'category': 1,
          'name': 'packet-buffering',
          'value': 1,
        });
        await _channel.invokeMethod('setOption', {
          'viewId': _viewId,
          'category': 4,
          'name': 'analyzeduration',
          'value': 1,
        });
        await _channel.invokeMethod('setOption', {
          'viewId': _viewId,
          'category': 4,
          'name': 'probesize',
          'value': 1024 * 10,
        });
        await _setDataSource(widget.url);
      }
    } catch (e) {
      widget.onError?.call();
    }
  }

  Future<void> _setDataSource(String url) async {
    if (_viewId < 0) return;
    try {
      await _channel.invokeMethod('setDataSource', {
        'viewId': _viewId,
        'url': url,
      });
    } catch (e) {
      widget.onError?.call();
    }
  }

  Future<void> _setDecoder(int decoderIndex) async {
    if (_viewId < 0) return;
    try {
      await _channel.invokeMethod('setOption', {
        'viewId': _viewId,
        'category': 1,
        'name': 'mediacodec',
        'value': decoderIndex == 0 ? 1 : 0,
      });
    } catch (e) {
      // ignore
    }
  }

  Future<void> _releasePlayer() async {
    if (_viewId < 0) return;
    try {
      await _channel.invokeMethod('releasePlayer', {'viewId': _viewId});
    } catch (e) {
      // ignore
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_viewId < 0) {
      return const Center(child: CircularProgressIndicator());
    }
    return AndroidView(
      viewType: 'com.example.witv/ijkplayer',
      creationParams: {'viewId': _viewId},
      creationParamsCodec: const StandardMessageCodec(),
    );
  }
}
