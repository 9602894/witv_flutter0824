import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/settings_service.dart';
import '../services/log_service.dart';
import '../services/config_service.dart';
import '../services/epg_parser.dart';
import '../services/logo_service.dart';
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
  final TextEditingController _epgUrlController = TextEditingController();
  bool _isAdding = false;
  bool _isLoadingToken = true;
  bool _isSavingEpg = false;

  // 新增：遥控器全局焦点与选中索引
  int _selectedIndex = 0;
  final FocusNode _focusNode = FocusNode();

  // 原有 FocusNode 保持不变
  late final FocusNode _nameFocus;
  late final FocusNode _urlFocus;
  late final FocusNode _addBtnFocus;
  late final FocusNode _epgUrlFocus;
  late final FocusNode _epgSaveBtnFocus;
  late final FocusNode _tokenFocus;
  late final FocusNode _tokenSaveBtnFocus;
  late final FocusNode _logoSourceFocus;
  late final FocusNode _clearLogoFocus;
  late final FocusNode _decoderFocus;
  late final FocusNode _autoReconnectFocus;
  late final FocusNode _exportLogFocus;
  late final FocusNode _clearLogFocus;

  @override
  void initState() {
    super.initState();
    _loadToken();
    _loadCurrentEpgUrl();

    _nameFocus = _createFieldFocus(_nameController);
    _urlFocus = _createFieldFocus(_urlController);
    _addBtnFocus = _createBtnFocus();
    _epgUrlFocus = _createFieldFocus(_epgUrlController);
    _epgSaveBtnFocus = _createBtnFocus();
    _tokenFocus = _createFieldFocus(_tokenController);
    _tokenSaveBtnFocus = _createBtnFocus();
    _logoSourceFocus = _createBtnFocus();
    _clearLogoFocus = _createBtnFocus();
    _decoderFocus = _createBtnFocus();
    _autoReconnectFocus = _createBtnFocus();
    _exportLogFocus = _createBtnFocus();
    _clearLogFocus = _createBtnFocus();

    // 延迟请求焦点
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  FocusNode _createFieldFocus(TextEditingController controller) {
    return FocusNode(
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
          node.nextFocus();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
          node.previousFocus();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          final offset = controller.selection.baseOffset;
          if (offset == -1 || offset > 0) return KeyEventResult.ignored;
          node.previousFocus();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
          final offset = controller.selection.baseOffset;
          if (offset == -1 || offset < controller.text.length) return KeyEventResult.ignored;
          node.nextFocus();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
    );
  }

  FocusNode _createBtnFocus() {
    return FocusNode(
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
          node.nextFocus();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
          node.previousFocus();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
    );
  }

  Future<void> _loadCurrentEpgUrl() async {
    final url = await EpgParser.getEpgUrl();
    if (mounted) {
      _epgUrlController.text = url ?? '';
    }
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
    _focusNode.dispose();
    _nameController.dispose();
    _urlController.dispose();
    _tokenController.dispose();
    _epgUrlController.dispose();
    _nameFocus.dispose();
    _urlFocus.dispose();
    _addBtnFocus.dispose();
    _epgUrlFocus.dispose();
    _epgSaveBtnFocus.dispose();
    _tokenFocus.dispose();
    _tokenSaveBtnFocus.dispose();
    _logoSourceFocus.dispose();
    _clearLogoFocus.dispose();
    _decoderFocus.dispose();
    _autoReconnectFocus.dispose();
    _exportLogFocus.dispose();
    _clearLogFocus.dispose();
    super.dispose();
  }

  Future<String?> _getCurrentEpgUrl() async {
    return await EpgParser.getEpgUrl();
  }

  Future<void> _saveEpgUrl() async {
    final url = _epgUrlController.text.trim();
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入有效的 EPG URL')),
      );
      return;
    }
    setState(() => _isSavingEpg = true);
    try {
      await EpgParser.saveEpgUrl(url);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('EPG URL 已保存')),
      );
      _epgUrlController.clear();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败: $e')),
      );
    } finally {
      setState(() => _isSavingEpg = false);
    }
  }

  // 新增：全局按键处理
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
      child: FocusTraversalGroup(
        policy: WidgetOrderTraversalPolicy(),
        child: Scaffold(
          appBar: AppBar(
            title: const Text('设置'),
            actions: [
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: () {
                  settings.markNeedsRefresh();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已标记刷新，返回后自动更新')),
                  );
                },
              ),
            ],
          ),
          body: ListView(
            children: [
              Card(
                margin: const EdgeInsets.all(8),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('订阅源管理', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _nameController,
                              focusNode: _nameFocus,
                              textInputAction: TextInputAction.next,
                              decoration: const InputDecoration(
                                labelText: '名称',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _urlController,
                              focusNode: _urlFocus,
                              textInputAction: TextInputAction.next,
                              decoration: const InputDecoration(
                                labelText: 'URL',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Focus(
                            focusNode: _addBtnFocus,
                            child: ElevatedButton(
                              onPressed: _isAdding ? null : _addSubscription,
                              child: _isAdding
                                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                                  : const Text('添加'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
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
                          icon: const Icon(Icons.delete, color: Colors.red),
                          onPressed: () {
                            _confirmDelete(sub);
                          },
                        ),
                      )).toList(),
                      if (settings.subscriptions.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Center(child: Text('暂无订阅源，请添加')),
                        ),
                    ],
                  ),
                ),
              ),

              Card(
                margin: const EdgeInsets.all(8),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('EPG 订阅管理', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _epgUrlController,
                              focusNode: _epgUrlFocus,
                              textInputAction: TextInputAction.next,
                              decoration: const InputDecoration(
                                labelText: 'EPG URL',
                                hintText: '输入 EPG XML 地址',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Focus(
                            focusNode: _epgSaveBtnFocus,
                            child: ElevatedButton(
                              onPressed: _isSavingEpg ? null : _saveEpgUrl,
                              child: _isSavingEpg
                                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                                  : const Text('保存'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      FutureBuilder<String?>(
                        future: _getCurrentEpgUrl(),
                        builder: (context, snapshot) {
                          final url = snapshot.data;
                          if (url != null && url.isNotEmpty) {
                            return Text('当前: $url', style: const TextStyle(fontSize: 12, color: Colors.grey), maxLines: 1, overflow: TextOverflow.ellipsis);
                          }
                          return const SizedBox.shrink();
                        },
                      ),
                    ],
                  ),
                ),
              ),

              Card(
                margin: const EdgeInsets.all(8),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('GitHub 私有仓库令牌', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _tokenController,
                              focusNode: _tokenFocus,
                              textInputAction: TextInputAction.next,
                              obscureText: true,
                              decoration: const InputDecoration(
                                labelText: 'Personal Access Token',
                                hintText: '输入您的 GitHub 令牌',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Focus(
                            focusNode: _tokenSaveBtnFocus,
                            child: ElevatedButton(
                              onPressed: _isLoadingToken ? null : _saveToken,
                              child: _isLoadingToken
                                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                                  : const Text('保存'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      const Text('令牌仅保存在本地，用于访问私有仓库的配置、EPG 和台标资源。',
                        style: TextStyle(fontSize: 12, color: Colors.grey)),
                    ],
                  ),
                ),
              ),

              Card(
                margin: const EdgeInsets.all(8),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('台标来源', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Focus(
                        focusNode: _logoSourceFocus,
                        child: ListTile(
                          leading: const Icon(Icons.image),
                          title: const Text('选择台标来源'),
                          subtitle: const Text('M3U订阅源 / GitHub仓库 / EPG文件'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => LogoSourceSettingDialog.show(context),
                        ),
                      ),
                      Focus(
                        focusNode: _clearLogoFocus,
                        child: ListTile(
                          leading: const Icon(Icons.delete_forever, color: Colors.red),
                          title: const Text('清除台标缓存', style: TextStyle(color: Colors.red)),
                          subtitle: const Text('删除 logo 文件夹中的所有台标'),
                          onTap: () => _confirmClearLogoCache(),
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text('GitHub 来源直接保存；M3U / EPG 来源自动去除白底后保存。',
                        style: TextStyle(fontSize: 12, color: Colors.grey)),
                    ],
                  ),
                ),
              ),

              Card(
                margin: const EdgeInsets.all(8),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('解码器', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Focus(
                        focusNode: _decoderFocus,
                        child: DropdownButton<int>(
                          value: settings.decoderIndex,
                          items: const [
                            DropdownMenuItem(value: 0, child: Text('硬件解码 (画质优先，推荐)')),
                            DropdownMenuItem(value: 1, child: Text('软件解码 (兼容优先)')),
                          ],
                          onChanged: (value) {
                            if (value != null) settings.setDecoderIndex(value);
                          },
                          isExpanded: true,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '当前解码器: ${settings.decoderIndex == 0 ? "硬件（画质更好）" : "软件（兼容性更好）"}',
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        '• 硬解：使用 GPU 解码，画质清晰、CPU 占用低，部分老旧设备可能黑屏。\n'
                        '• 软解：使用 CPU 解码，兼容性最好，但高码率直播可能卡顿。\n'
                        '如果画面模糊/有马赛克，尝试切换解码器。',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
              ),

              Card(
                margin: const EdgeInsets.all(8),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      const Text('断线自动重连', style: TextStyle(fontSize: 18)),
                      const Spacer(),
                      Focus(
                        focusNode: _autoReconnectFocus,
                        child: Switch(
                          value: settings.autoReconnect,
                          onChanged: (value) {
                            settings.setAutoReconnect(value);
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              Card(
                margin: const EdgeInsets.all(8),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('日志', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: Focus(
                              focusNode: _exportLogFocus,
                              child: ElevatedButton.icon(
                                icon: const Icon(Icons.file_download),
                                label: const Text('导出日志'),
                                onPressed: _exportLog,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Focus(
                              focusNode: _clearLogFocus,
                              child: ElevatedButton.icon(
                                icon: const Icon(Icons.delete_forever),
                                label: const Text('清空日志'),
                                onPressed: _clearLogs,
                                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              Card(
                margin: const EdgeInsets.all(8),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('关于', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      const ListTile(
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
        ),
      ),
    );
  }

  Future<void> _addSubscription() async {
    final name = _nameController.text.trim();
    final url = _urlController.text.trim();
    if (name.isEmpty || url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写完整信息')),
      );
      return;
    }
    setState(() => _isAdding = true);
    try {
      final settings = Provider.of<SettingsService>(context, listen: false);
      final exists = settings.subscriptions.any((s) => s.url == url || s.name == name);
      if (exists) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('订阅源已存在')),
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

  Future<void> _saveToken() async {
    final token = _tokenController.text.trim();
    if (token.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入有效令牌')),
      );
      return;
    }
    setState(() => _isLoadingToken = true);
    try {
      await ConfigService.saveGitHubToken(token);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('令牌已保存')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存令牌失败: $e')),
      );
    } finally {
      setState(() => _isLoadingToken = false);
    }
  }

  Future<void> _confirmClearLogoCache() async {
    final confirm = await _showTransparentDialog<bool>(
      context: context,
      title: '确认清除台标缓存',
      content: '将删除 logo 文件夹中的所有台标图片，确认吗？',
      confirmText: '清除',
      confirmColor: Colors.red,
    );
    if (confirm == true) {
      try {
        await LogoService().clearLogoCache();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('台标缓存已清空')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('清除失败: $e')),
          );
        }
      }
    }
  }

  Future<void> _exportLog() async {
    try {
      final file = await LogService.export();
      if (file != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('日志文件: ${file.path}')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('暂无日志文件')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出失败: $e')),
      );
    }
  }

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
            const SnackBar(content: Text('日志已清空')),
          );
        }
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('清空失败: $e')),
        );
      }
    }
  }

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
