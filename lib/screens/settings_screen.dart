import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/settings_service.dart';
import '../services/log_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  int _selectedIndex = 0;
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
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
    final isBack = key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.goBack ||
                   key == LogicalKeyboardKey.backspace || keyId == 0x100000803 ||
                   keyId == 0x100000008 || label.contains('back');

    if (isUp) {
      setState(() => _selectedIndex = _selectedIndex > 0 ? _selectedIndex - 1 : 0);
    } else if (isDown) {
      setState(() => _selectedIndex = _selectedIndex + 1);
    } else if (isBack) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsService>(context);
    return RawKeyboardListener(
      focusNode: _focusNode,
      onKey: _handleKeyEvent,
      child: Scaffold(
        appBar: AppBar(title: const Text('设置')),
        body: ListView(
          children: [
            _buildSectionTitle('播放设置'),
            _buildSettingItem(
              '默认解码器',
              subtitle: settings.decoderIndex == 0 ? '硬解码' : '软解码',
              trailing: DropdownButton<int>(
                value: settings.decoderIndex,
                dropdownColor: Colors.grey[800],
                items: const [
                  DropdownMenuItem(value: 0, child: Text('硬解码')),
                  DropdownMenuItem(value: 1, child: Text('软解码')),
                ],
                onChanged: (v) => settings.setDecoderIndex(v ?? 0),
              ),
            ),
            _buildSettingItem(
              '断线重连',
              subtitle: settings.autoReconnect ? '开启' : '关闭',
              trailing: Switch(
                value: settings.autoReconnect,
                onChanged: (v) => settings.setAutoReconnect(v),
              ),
            ),
            const Divider(),
            _buildSectionTitle('数据管理'),
            _buildSettingItem(
              '清除缓存',
              onTap: () async {
                final dir = await SettingsService.getCacheDir();
                if (await dir.exists()) {
                  await dir.delete(recursive: true);
                }
                if (mounted) ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('缓存已清除')),
                );
              },
            ),
            _buildSettingItem(
              '导出日志',
              onTap: () async {
                final file = await LogService.export();
                if (mounted) ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(file != null ? '日志已导出' : '导出失败')),
                );
              },
            ),
            const Divider(),
            _buildSectionTitle('关于'),
            _buildSettingItem('版本', subtitle: '1.0.0'),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.bold,
          color: Colors.grey[400],
        ),
      ),
    );
  }

  Widget _buildSettingItem(String title, {String? subtitle, Widget? trailing, VoidCallback? onTap}) {
    return ListTile(
      title: Text(title),
      subtitle: subtitle != null ? Text(subtitle) : null,
      trailing: trailing,
      onTap: onTap,
    );
  }
}
