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
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _epgUrlController = TextEditingController();
  String _currentEpgUrl = '';

  @override
  void initState() {
    super.initState();
    _loadToken();
    _loadCurrentEpgUrl();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _nameController.dispose();
    _urlController.dispose();
    _epgUrlController.dispose();
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

  Future<void> _loadToken() async {
    final token = await SettingsService.getToken();
    if (mounted) setState(() {});
  }

  Future<void> _loadCurrentEpgUrl() async {
    final url = await SettingsService.getCurrentEpgUrl();
    if (mounted) setState(() => _currentEpgUrl = url);
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
              '播放速度',
              subtitle: '${settings.playSpeed}x',
              trailing: DropdownButton<double>(
                value: settings.playSpeed,
                dropdownColor: Colors.grey[800],
                items: const [
                  DropdownMenuItem(value: 0.5, child: Text('0.5x')),
                  DropdownMenuItem(value: 1.0, child: Text('1.0x')),
                  DropdownMenuItem(value: 1.25, child: Text('1.25x')),
                  DropdownMenuItem(value: 1.5, child: Text('1.5x')),
                  DropdownMenuItem(value: 2.0, child: Text('2.0x')),
                ],
                onChanged: (v) => settings.setPlaySpeed(v ?? 1.0),
              ),
            ),
            _buildSettingItem(
              '自动播放',
              subtitle: settings.autoPlay ? '开启' : '关闭',
              trailing: Switch(
                value: settings.autoPlay,
                onChanged: (v) => settings.setAutoPlay(v),
              ),
            ),
            const Divider(),
            _buildSectionTitle('数据管理'),
            _buildSettingItem(
              '清除缓存',
              onTap: () async {
                await SettingsService.clearCache();
                if (mounted) ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('缓存已清除')),
                );
              },
            ),
            _buildSettingItem(
              '导出日志',
              onTap: () async {
                final path = await LogService.exportLogs();
                if (mounted) ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('日志已导出: $path')),
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
