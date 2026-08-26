import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 退出/设置菜单 - 自己管理焦点和按键，不依赖父组件
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
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    // 构建完成后立即抢占焦点，确保遥控器方向键路由到这里
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = ['设置', '退出'];
    final icons = [Icons.settings, Icons.exit_to_app];

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      canRequestFocus: true,
      descendantsAreFocusable: false, // 子组件不可聚焦，防止焦点逃逸
      onKeyEvent: (node, event) {
        // 只处理按下事件
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }

        final key = event.logicalKey;
        final keyId = key.keyId;
        final label = key.keyLabel.toLowerCase();

        // 超宽松按键匹配
        final isUp = key == LogicalKeyboardKey.arrowUp ||
                     key == LogicalKeyboardKey.numpad8 ||
                     keyId == 0x100000304 || keyId == 0x01000026 ||
                     keyId == 0x01000097 ||
                     label.contains('up') || label.contains('dpad_up');

        final isDown = key == LogicalKeyboardKey.arrowDown ||
                       key == LogicalKeyboardKey.numpad2 ||
                       keyId == 0x100000301 || keyId == 0x01000028 ||
                       keyId == 0x01000098 ||
                       label.contains('down') || label.contains('dpad_down');

        final isOk = key == LogicalKeyboardKey.enter ||
                     key == LogicalKeyboardKey.select ||
                     key == LogicalKeyboardKey.accept ||
                     key == LogicalKeyboardKey.numpadEnter ||
                     keyId == 0x100000161 || keyId == 0x10000000d ||
                     keyId == 0x0100000d || keyId == 0x0100001c ||
                     keyId == 0x0100001d || keyId == 0x0100001e ||
                     label.contains('enter') || label.contains('select') ||
                     label.contains('dpad_center');

        final isBack = key == LogicalKeyboardKey.escape ||
                       key == LogicalKeyboardKey.goBack ||
                       key == LogicalKeyboardKey.backspace ||
                       keyId == 0x100000803 || keyId == 0x100000008 ||
                       keyId == 0x0100000e || keyId == 0x0100001b ||
                       keyId == 0x0100006f || keyId == 0x0100006e ||
                       label.contains('back') || label.contains('escape') ||
                       label.contains('return');

        if (isUp) {
          setState(() => _selectedIndex = (_selectedIndex - 1 + items.length) % items.length);
          return KeyEventResult.handled;
        } else if (isDown) {
          setState(() => _selectedIndex = (_selectedIndex + 1) % items.length);
          return KeyEventResult.handled;
        } else if (isOk) {
          if (_selectedIndex == 0) widget.onSettings();
          else widget.onExit();
          return KeyEventResult.handled;
        } else if (isBack) {
          widget.onDismiss();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
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
                    ...List.generate(items.length, (index) {
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
                                icons[index],
                                color: isSelected ? Colors.white : Colors.white70,
                                size: 22,
                              ),
                              const SizedBox(width: 12),
                              Text(
                                items[index],
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
