import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/settings_service.dart';
import '../services/log_service.dart';
import '../services/config_service.dart';
import '../models/subscription.dart';
import '../widgets/logo_source_dialog.dart';
import 'dart:io';

class SettingsScreen extends StatefulWidget {
  @override
  _SettingsScreenState createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _tokenController = TextEditingController();
  bool _isAdding = false;
  bool _isLoadingToken = true;

  @override
  void initState() {
    super.initState();
    _loadToken();
  }

  Future<void> _loadToken() async {
    final token = await ConfigService.getGitHubToken();
    if (mounted) {
      setState(() {
        _tokenController.text = token ?? '';
        _isLoadingToken = false;
      });
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsService>(context);
    return Scaffold(
      appBar: AppBar(
        title: Text('设置'),
        actions: [
          IconButton(
            icon: Icon(Icons.refresh),
            onPressed: () {
              settings.markNeedsRefresh();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('已标记刷新，返回后自动更新')),
              );
            },
          ),
        ],
      ),
      body: ListView(
        children: [
          // ---------- 订阅源管理 ----------
          Card(
            margin: EdgeInsets.all(8),
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('订阅源管理', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _nameController,
                          decoration: InputDecoration(
                            labelText: '名称',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _urlController,
                          decoration: InputDecoration(
                            labelText: 'URL',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: _isAdding ? null : _addSubscription,
                        child: _isAdding ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : Text('添加'),
                      ),
                    ],
                  ),
                  SizedBox(height: 12),
                  ...settings.subscriptions.map((sub) => ListTile(
                    leading: Checkbox(
                      value: sub.selected,
                      onChanged: (_) {
                        settings.toggleSelected(sub);
                      },
                    ),
                    title: Text(sub.name),
                    subtitle: Text(sub.url, maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: IconButton(
                      icon: Icon(Icons.delete, color: Colors.red),
                      onPressed: () {
                        _confirmDelete(sub);
                      },
                    ),
                  )).toList(),
                  if (settings.subscriptions.isEmpty)
                    Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Center(child: Text('暂无订阅源，请添加')),
                    ),
                ],
              ),
            ),
          ),

          // ---------- GitHub 令牌设置 ----------
          Card(
            margin: EdgeInsets.all(8),
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('GitHub 私有仓库令牌', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _tokenController,
                          obscureText: true,
                          decoration: InputDecoration(
                            labelText: 'Personal Access Token',
                            hintText: '输入您的 GitHub 令牌',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: _isLoadingToken ? null : _saveToken,
                        child: _isLoadingToken ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : Text('保存'),
                      ),
                    ],
                  ),
                  SizedBox(height: 4),
                  Text('令牌仅保存在本地，用于访问私有仓库的配置、EPG 和台标资源。',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                ],
              ),
            ),
          ),

          // ---------- 台标来源设置 ----------
          Card(
            margin: EdgeInsets.all(8),
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('台标来源', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  SizedBox(height: 8),
                  ListTile(
                    leading: Icon(Icons.image),
                    title: Text('选择台标来源'),
                    subtitle: Text('M3U订阅源 / GitHub仓库 / EPG文件'),
                    trailing: Icon(Icons.chevron_right),
                    onTap: () => LogoSourceSettingDialog.show(context),
                  ),
                  SizedBox(height: 4),
                  Text('所有台标下载后都会自动进行背景透明化处理。',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                ],
              ),
            ),
          ),

          // ---------- 解码器选择（已更新详细说明） ----------
          Card(
            margin: EdgeInsets.all(8),
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('解码器', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  DropdownButton<int>(
                    value: settings.decoderIndex,
                    items: [
                      DropdownMenuItem(value: 0, child: Text('硬件解码 (画质优先，推荐)')),
                      DropdownMenuItem(value: 1, child: Text('软件解码 (兼容优先)')),
                    ],
                    onChanged: (value) {
                      if (value != null) settings.setDecoderIndex(value);
                    },
                    isExpanded: true,
                  ),
                  SizedBox(height: 8),
                  Text(
                    '当前解码器: ${settings.decoderIndex == 0 ? "硬件（画质更好）" : "软件（兼容性更好）"}',
                  ),
                  SizedBox(height: 4),
                  Text(
                    '• 硬解：使用 GPU 解码，画质清晰、CPU 占用低，部分老旧设备可能黑屏。\n'
                    '• 软解：使用 CPU 解码，兼容性最好，但高码率直播可能卡顿。\n'
                    '如果画面模糊/有马赛克，尝试切换解码器。',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            ),
          ),

          // ---------- 自动重连 ----------
          Card(
            margin: EdgeInsets.all(8),
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Row(
                children: [
                  Text('断线自动重连', style: TextStyle(fontSize: 18)),
                  Spacer(),
                  Switch(
                    value: settings.autoReconnect,
                    onChanged: (value) {
                      settings.setAutoReconnect(value);
                    },
                  ),
                ],
              ),
            ),
          ),

          // ---------- 日志操作 ----------
          Card(
            margin: EdgeInsets.all(8),
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('日志', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          icon: Icon(Icons.file_download),
                          label: Text('导出日志'),
                          onPressed: _exportLog,
                        ),
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: ElevatedButton.icon(
                          icon: Icon(Icons.delete_forever),
                          label: Text('清空日志'),
                          onPressed: _clearLogs,
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // ---------- 关于 ----------
          Card(
            margin: EdgeInsets.all(8),
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('关于', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  SizedBox(height: 8),
                  ListTile(
                    leading: Icon(Icons.info),
                    title: Text('Witv 播放器'),
                    subtitle: Text('版本 1.0.0\n基于 Flutter 构建'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------- 添加订阅源 ----------
  Future<void> _addSubscription() async {
    final name = _nameController.text.trim();
    final url = _urlController.text.trim();
    if (name.isEmpty || url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('请填写完整信息')),
      );
      return;
    }
    setState(() => _isAdding = true);
    try {
      final settings = Provider.of<SettingsService>(context, listen: false);
      final exists = settings.subscriptions.any((s) => s.url == url || s.name == name);
      if (exists) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('订阅源已存在')),
        );
        return;
      }
      settings.addSubscription(Subscription(name: name, url: url, selected: true));
      _nameController.clear();
      _urlController.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已添加订阅: $name')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('添加失败: $e')),
      );
    } finally {
      setState(() => _isAdding = false);
    }
  }

  // ---------- 删除确认（透明弹窗） ----------
  Future<void> _confirmDelete(Subscription sub) async {
    final confirm = await _showTransparentDialog<bool>(
      context: context,
      title: '确认删除',
      content: '确定要删除订阅 "${sub.name}" 吗？',
      confirmText: '删除',
      confirmColor: Colors.red,
    );
    if (confirm == true) {
      final settings = Provider.of<SettingsService>(context, listen: false);
      settings.removeSubscription(sub);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已删除: ${sub.name}')),
      );
    }
  }

  // ---------- 保存 GitHub 令牌 ----------
  Future<void> _saveToken() async {
    final token = _tokenController.text.trim();
    if (token.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('请输入有效令牌')),
      );
      return;
    }
    setState(() => _isLoadingToken = true);
    try {
      await ConfigService.saveGitHubToken(token);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('令牌已保存')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存令牌失败: $e')),
      );
    } finally {
      setState(() => _isLoadingToken = false);
    }
  }

  // ---------- 导出日志 ----------
  Future<void> _exportLog() async {
    try {
      final file = await LogService.export();
      if (file != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('日志文件: ${file.path}')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('暂无日志文件')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出失败: $e')),
      );
    }
  }

  // ---------- 清空日志确认（透明弹窗） ----------
  Future<void> _clearLogs() async {
    final confirm = await _showTransparentDialog<bool>(
      context: context,
      title: '确认清空',
      content: '将删除所有日志文件，确认吗？',
      confirmText: '清空',
      confirmColor: Colors.red,
    );
    if (confirm == true) {
      try {
        final dir = await LogService.getLogDir();
        if (await dir.exists()) {
          await dir.delete(recursive: true);
          await dir.create(recursive: true);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('日志已清空')),
          );
        }
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('清空失败: $e')),
        );
      }
    }
  }

  // ---------- 统一透明弹窗（非全屏、半透明背景） ----------
  Future<T?> _showTransparentDialog<T>({
    required BuildContext context,
    required String title,
    required String content,
    String cancelText = '取消',
    required String confirmText,
    Color? confirmColor,
  }) async {
    final size = MediaQuery.of(context).size;
    return showDialog<T>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.6),
      useSafeArea: false,
      builder: (_) => Center(
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: size.width * 0.5,
            height: size.height * 0.3,
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.75),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withOpacity(0.1)),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      content,
                      style: TextStyle(fontSize: 14, color: Colors.grey[300]),
                    ),
                    const Spacer(),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: Text(cancelText, style: const TextStyle(color: Colors.white70)),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: () => Navigator.pop(context, true),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: confirmColor,
                          ),
                          child: Text(confirmText),
                        ),
                      ],
                    ),
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
