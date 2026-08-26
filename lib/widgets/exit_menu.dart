import 'package:flutter/material.dart';

/// 退出/设置菜单 - 纯展示组件
/// 按键处理由父组件（HomeScreen）统一在 RawKeyboardListener 中处理
class ExitMenu extends StatelessWidget {
  final int selectedIndex;
  final VoidCallback onSettings;
  final VoidCallback onExit;
  final VoidCallback onDismiss;

  const ExitMenu({
    Key? key,
    required this.selectedIndex,
    required this.onSettings,
    required this.onExit,
    required this.onDismiss,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final items = ['设置', '退出'];
    final icons = [Icons.settings, Icons.exit_to_app];

    return GestureDetector(
      onTap: onDismiss,
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
                    final isSelected = index == selectedIndex;
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
    );
  }
}

