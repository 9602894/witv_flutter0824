import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/logo_service.dart';

class _SourceItem {
  final LogoSource source;
  bool enabled;
  _SourceItem({required this.source, this.enabled = false});
}

class LogoSourceSettingDialog extends StatefulWidget {
  final bool isFirstTime;
  const LogoSourceSettingDialog({super.key, this.isFirstTime = false});

  @override
  State<LogoSourceSettingDialog> createState() => _LogoSourceSettingDialogState();

  static Future<void> show(BuildContext context, {bool isFirstTime = false}) async {
    return showDialog(
      context: context,
      barrierDismissible: !isFirstTime,
      barrierColor: Colors.black.withOpacity(0.6),
      useSafeArea: false,
      builder: (_) => _DialogWrapper(isFirstTime: isFirstTime),
    );
  }
}

class _DialogWrapper extends StatelessWidget {
  final bool isFirstTime;
  const _DialogWrapper({required this.isFirstTime});

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: size.width * 0.5,
          height: size.height * 0.5,
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.75),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withOpacity(0.1)),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: LogoSourceSettingDialog(isFirstTime: isFirstTime),
          ),
        ),
      ),
    );
  }
}

class _LogoSourceSettingDialogState extends State<LogoSourceSettingDialog> {
  final List<_SourceItem> _items = [];
  bool _loading = true;
  int _selectedIndex = 0;
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _loadConfig();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    final enabled = await LogoService().getEnabledSources();
    final allSources = LogoSource.values.toList();
    final ordered = <_SourceItem>[];

    for (final s in enabled) {
      ordered.add(_SourceItem(source: s, enabled: true));
      allSources.remove(s);
    }
    for (final s in allSources) {
      ordered.add(_SourceItem(source: s, enabled: false));
    }

    setState(() {
      _items.addAll(ordered);
      _loading = false;
    });
  }

  void _handleKeyEvent(RawKeyEvent event) {
    if (event is! RawKeyDownEvent) return;
    final key = event.logicalKey;
    final keyId = key.keyId;
    final label = key.keyLabel.toLowerCase();

    final isUp = key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.numpad8 ||
                 keyId == 0x100000304 || keyId == 0x01000026 || label.contains('up');
    final isDown = key == LogicalKeyboardKey.arrowDown || key == LogicalKeyboardKey.numpad2 ||
                   keyId == 0x100000301 || keyId == 0x01000028 || label.contains('down');
    final isOk = key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.select ||
                 key == LogicalKeyboardKey.accept || keyId == 0x100000161 ||
                 keyId == 0x10000000d || label.contains('enter') || label.contains('select');
    final isBack = key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.goBack ||
                   key == LogicalKeyboardKey.backspace || keyId == 0x100000803 ||
                   keyId == 0x100000008 || label.contains('back');

    final itemCount = _items.length + 1;

    if (isUp) {
      setState(() => _selectedIndex = _selectedIndex > 0 ? _selectedIndex - 1 : itemCount - 1);
    } else if (isDown) {
      setState(() => _selectedIndex = _selectedIndex < itemCount - 1 ? _selectedIndex + 1 : 0);
    } else if (isOk) {
      if (_selectedIndex < _items.length) {
        setState(() => _items[_selectedIndex].enabled = !_items[_selectedIndex].enabled);
      } else {
        _save();
      }
    } else if (isBack) {
      if (!widget.isFirstTime) Navigator.of(context).pop();
    }
  }

  Future<void> _save() async {
    final enabled = _items.where((i) => i.enabled).map((i) => i.source).toList();
    if (enabled.isEmpty) {
      _showSnackBar('请至少选择一个台标来源');
      return;
    }
    await LogoService().setEnabledSources(enabled);
    if (mounted) {
      Navigator.of(context).pop();
      _showSnackBar('台标设置已保存（优先级: ${enabled.map((s) => s.displayName).join(' > ')}）');
    }
  }

  void _showSnackBar(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return RawKeyboardListener(
      focusNode: _focusNode,
      onKey: _handleKeyEvent,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              widget.isFirstTime ? '请选择台标来源' : '台标来源设置',
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.isFirstTime)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: Text(
                        '尚未配置台标来源，请选择一种或多种方式获取频道台标。\n可勾选多个来源并调整优先级，程序会按顺序尝试获取。',
                        style: TextStyle(fontSize: 14, color: Colors.grey),
                      ),
                    ),
                  ..._buildSourceList(),
                  const SizedBox(height: 8),
                  const Text(
                    '提示：数字越小优先级越高。获取台标时按 1→2→3 顺序尝试，第一个成功即返回。',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (!widget.isFirstTime)
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消', style: TextStyle(color: Colors.white70)),
                  ),
                _buildSaveButton(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildSourceList() {
    final list = <Widget>[];
    for (int i = 0; i < _items.length; i++) {
      final item = _items[i];
      final realPriority = item.enabled
          ? _items.where((x) => x.enabled).toList().indexOf(item) + 1
          : null;
      final isSelected = i == _selectedIndex;

      list.add(
        InkWell(
          onTap: () => setState(() => item.enabled = !item.enabled),
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: isSelected
                  ? Colors.blue.withOpacity(0.3)
                  : (item.enabled ? Colors.blue.withOpacity(0.15) : Colors.white.withOpacity(0.05)),
              borderRadius: BorderRadius.circular(8),
              border: isSelected
                  ? Border.all(color: Colors.yellow, width: 2)
                  : Border.all(color: Colors.transparent),
            ),
            child: Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: item.enabled ? Colors.blue : Colors.grey[600],
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      item.enabled ? '$realPriority' : '-',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Checkbox(
                  value: item.enabled,
                  onChanged: (v) => setState(() => item.enabled = v ?? false),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.source.displayName,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: item.enabled ? Colors.white : Colors.grey[400],
                        ),
                      ),
                      Text(
                        item.source.description,
                        style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return list;
  }

  Widget _buildSaveButton() {
    final isSelected = _selectedIndex == _items.length;
    return ElevatedButton(
      onPressed: _save,
      style: isSelected ? ElevatedButton.styleFrom(
        backgroundColor: Colors.yellow,
        foregroundColor: Colors.black,
      ) : null,
      child: const Text('保存'),
    );
  }
}
