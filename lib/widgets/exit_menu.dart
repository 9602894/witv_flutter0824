import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 退出/设置菜单 - 支持遥控器上下选择和OK确认
class ExitMenu extends StatefulWidget {
  final VoidCallback onSettings;
  final VoidCallback onExit;
  final VoidCallback onDismiss;

  const ExitMenu({
    Key? key,
    required this.onSettings,
    required this.onExit,
    required this.onDismiss,
  }) : super(key: key);

  @override
  State<ExitMenu> createState() => _ExitMenuState();
}

class _ExitMenuState extends State<ExitMenu> {
  int _selectedIndex = 0;
  final List<String> _items = ['设置', '退出'];
  final List<IconData> _icons = [Icons.settings, Icons.exit_to_app];
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _handleKey(RawKeyEvent event) {
    if (event is! RawKeyDownEvent) return;
    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.arrowUp) {
      setState(() => _selectedIndex = (_selectedIndex - 1 + _items.length) % _items.length);
    } else if (key == LogicalKeyboardKey.arrowDown) {
      setState(() => _selectedIndex = (_selectedIndex + 1) % _items.length);
    } else if (key == LogicalKeyboardKey.enter ||
               key == LogicalKeyboardKey.select) {
      if (_selectedIndex == 0) {
        widget.onSettings();
      } else {
        widget.onExit();
      }
    } else if (key == LogicalKeyboardKey.escape ||
               key == LogicalKeyboardKey.goBack ||
               key == LogicalKeyboardKey.backspace) {
      widget.onDismiss();
    }
  }

  @override
  Widget build(BuildContext context) {
    return RawKeyboardListener(
      focusNode: _focusNode,
      onKey: _handleKey,
      child: GestureDetector(
        onTap: widget.onDismiss,
        child: Container(
          color: Colors.black.withOpacity(0.7),
          child: Center(
            child: GestureDetector(
              onTap: () {}, // 阻止点击穿透
              child: Container(
                width: 280,
                padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.85),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white.withOpacity(0.2)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      '菜单',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    ...List.generate(_items.length, (index) {
                      final isSelected = index == _selectedIndex;
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? Colors.blue.withOpacity(0.6)
                                : Colors.white.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(8),
                            border: isSelected
                                ? Border.all(color: Colors.blueAccent, width: 2)
                                : Border.all(color: Colors.transparent),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                _icons[index],
                                color: isSelected ? Colors.white : Colors.white70,
                                size: 22,
                              ),
                              const SizedBox(width: 12),
                              Text(
                                _items[index],
                                style: TextStyle(
                                  color: isSelected ? Colors.white : Colors.white70,
                                  fontSize: 16,
                                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
