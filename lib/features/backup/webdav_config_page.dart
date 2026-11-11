import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/backup/webdav_client.dart';
import '../../domain/rules/tally_backup.dart';
import '../common/common.dart';
import 'backup_providers.dart';

class WebDavConfigPage extends ConsumerStatefulWidget {
  const WebDavConfigPage({super.key, this.initialConfig});

  final WebDavConfig? initialConfig;

  @override
  ConsumerState<WebDavConfigPage> createState() => _WebDavConfigPageState();
}

class _WebDavConfigPageState extends ConsumerState<WebDavConfigPage> {
  static const List<int> _presetKeepCounts = <int>[5, 10, 20, 30, 50];

  late WebDavConfig _baseConfig;
  late final TextEditingController _urlController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  late final TextEditingController _remoteDirController;

  late int _keepCount;
  late bool _autoBackupEnabled;
  ProviderSubscription<AsyncValue<WebDavConfig>>? _configSub;
  bool _userTouched = false;
  bool _obscurePassword = true;
  bool _busy = false;
  String? _testStatusMessage;
  bool _testSucceeded = false;

  @override
  void initState() {
    super.initState();
    final cfg = widget.initialConfig ?? const WebDavConfig.unconfigured();
    _baseConfig = cfg;
    _urlController = TextEditingController(text: cfg.serverUrl);
    _usernameController = TextEditingController(text: cfg.username);
    _passwordController = TextEditingController(text: cfg.password);
    _remoteDirController = TextEditingController(
      text: cfg.remoteDirectory.isEmpty ? '/TallyIsle' : cfg.remoteDirectory,
    );
    _keepCount = cfg.keepCount > 0 ? cfg.keepCount : defaultWebDavKeepCount;
    _autoBackupEnabled = cfg.autoBackupEnabled;
    if (widget.initialConfig == null) {
      _configSub = ref.listenManual<AsyncValue<WebDavConfig>>(
        webDavConfigProvider,
        (_, next) {
          final loaded = next.value;
          if (loaded != null) {
            _applyLoadedConfigIfUntouched(loaded);
          }
        },
      );
      unawaited(_loadStoredConfig());
    }
  }

  void _applyLoadedConfigIfUntouched(WebDavConfig loaded) {
    if (!mounted || _userTouched || _busy) return;
    setState(() {
      _baseConfig = loaded;
      _urlController.text = loaded.serverUrl;
      _usernameController.text = loaded.username;
      _passwordController.text = loaded.password;
      _remoteDirController.text = loaded.remoteDirectory.isEmpty
          ? '/TallyIsle'
          : loaded.remoteDirectory;
      _keepCount = loaded.keepCount > 0
          ? loaded.keepCount
          : defaultWebDavKeepCount;
      _autoBackupEnabled = loaded.autoBackupEnabled;
    });
  }

  Future<void> _loadStoredConfig() async {
    try {
      final service = await ref.read(tallyBackupServiceProvider.future);
      final fresh = await service.getWebDavConfig();
      _applyLoadedConfigIfUntouched(fresh);
      final streamed = await ref.read(webDavConfigProvider.future);
      _applyLoadedConfigIfUntouched(
        fresh.isConfigured || !streamed.isConfigured ? fresh : streamed,
      );
    } catch (_) {
      try {
        final streamed = await ref.read(webDavConfigProvider.future);
        _applyLoadedConfigIfUntouched(streamed);
      } catch (_) {
        // Keep unconfigured defaults if provider fails before user interaction.
      }
    }
  }

  @override
  void dispose() {
    _configSub?.close();
    _urlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _remoteDirController.dispose();
    super.dispose();
  }

  WebDavConfig _buildDraftConfig() {
    final remoteDir = _remoteDirController.text.trim().isEmpty
        ? '/TallyIsle'
        : _remoteDirController.text.trim();
    return _baseConfig.copyWith(
      serverUrl: _urlController.text.trim(),
      username: _usernameController.text.trim(),
      password: _passwordController.text,
      remoteDirectory: remoteDir,
      keepCount: _keepCount,
      autoBackupEnabled: _autoBackupEnabled,
    );
  }

  Future<void> _handleTestConnection() async {
    setState(() {
      _busy = true;
      _testStatusMessage = null;
    });
    try {
      final service = await ref.read(tallyBackupServiceProvider.future);
      await service.testWebDavConnection(_buildDraftConfig());
      if (!mounted) return;
      setState(() {
        _testSucceeded = true;
        _testStatusMessage = '连接成功，远端目录读写权限验证通过';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testSucceeded = false;
        _testStatusMessage = safeMessage(e);
      });
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _handleSave() async {
    final draft = _buildDraftConfig();
    if (!draft.isConfigured) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写有效的 http/https 服务器地址、用户名与密码')),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      final service = await ref.read(tallyBackupServiceProvider.future);
      await service.saveWebDavConfig(draft);
      ref
        ..invalidate(webDavConfigProvider)
        ..invalidate(webDavBackupsProvider);
      if (!mounted) return;
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop(true);
      } else {
        setState(() => _baseConfig = draft);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('WebDAV 配置已更新')));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _handleClear() async {
    final confirmed = await confirm(
      context,
      title: '清除 WebDAV 配置？',
      message: '清除后将停止自动云备份，远端已上传的备份文件不会被删除。',
      ok: '清除',
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    try {
      final service = await ref.read(tallyBackupServiceProvider.future);
      await service.clearWebDavConfig();
      ref
        ..invalidate(webDavConfigProvider)
        ..invalidate(webDavBackupsProvider);
      if (!mounted) return;
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop(true);
      } else {
        setState(() {
          _baseConfig = WebDavConfig(
            includeAttachments: _baseConfig.includeAttachments,
            keepCount: _keepCount,
          );
          _urlController.clear();
          _usernameController.clear();
          _passwordController.clear();
          _remoteDirController.text = '/TallyIsle';
          _autoBackupEnabled = false;
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('WebDAV 配置已清除')));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final keepOptions = <int>{..._presetKeepCounts, _keepCount}.toList()
      ..sort();

    return Scaffold(
      key: const Key('webdav_config_page'),
      appBar: AppBar(
        title: const Text('WebDAV 配置'),
        actions: [
          if (_baseConfig.isConfigured)
            TextButton(
              key: const Key('webdav_clear_config_button'),
              onPressed: _busy ? null : _handleClear,
              child: const Text('清除配置'),
            ),
        ],
      ),
      body: Column(
        children: [
          if (_busy)
            const LinearProgressIndicator(key: Key('webdav_config_busy')),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    key: const Key('webdav_url_input'),
                    controller: _urlController,
                    enabled: !_busy,
                    keyboardType: TextInputType.url,
                    onChanged: (_) => _userTouched = true,
                    decoration: const InputDecoration(
                      labelText: '服务器地址',
                      hintText: 'https://dav.jianguoyun.com/dav/',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('webdav_username_input'),
                    controller: _usernameController,
                    enabled: !_busy,
                    onChanged: (_) => _userTouched = true,
                    decoration: const InputDecoration(
                      labelText: '用户名 / 账号',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('webdav_password_input'),
                    controller: _passwordController,
                    enabled: !_busy,
                    obscureText: _obscurePassword,
                    onChanged: (_) => _userTouched = true,
                    decoration: InputDecoration(
                      labelText: '密码 / 应用专用密码',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscurePassword
                              ? Icons.visibility
                              : Icons.visibility_off,
                        ),
                        onPressed: () => setState(
                          () => _obscurePassword = !_obscurePassword,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('webdav_remote_dir_input'),
                    controller: _remoteDirController,
                    enabled: !_busy,
                    onChanged: (_) => _userTouched = true,
                    decoration: const InputDecoration(
                      labelText: '远端存储目录',
                      hintText: '/TallyIsle',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  InputDecorator(
                    decoration: const InputDecoration(
                      labelText: '远端自动保留备份份数',
                      border: OutlineInputBorder(),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<int>(
                        key: const Key('webdav_keep_count_dropdown'),
                        isExpanded: true,
                        isDense: true,
                        value: _keepCount,
                        items: [
                          for (final n in keepOptions)
                            DropdownMenuItem<int>(
                              value: n,
                              child: Text('保留最近 $n 份备份'),
                            ),
                        ],
                        onChanged: _busy
                            ? null
                            : (val) {
                                if (val != null) {
                                  _userTouched = true;
                                  setState(() => _keepCount = val);
                                }
                              },
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    key: const Key('webdav_auto_backup_switch'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('开启自动静默云备份'),
                    subtitle: const Text('距上次备份超过 24 小时且本地产生新账单变动时自动上传'),
                    value: _autoBackupEnabled,
                    onChanged: _busy
                        ? null
                        : (val) {
                            _userTouched = true;
                            setState(() => _autoBackupEnabled = val);
                          },
                  ),
                  if (_testStatusMessage != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      key: const Key('webdav_test_result_banner'),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: _testSucceeded
                            ? Colors.green.withValues(alpha: 0.12)
                            : Theme.of(context).colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _testStatusMessage!,
                        style: TextStyle(
                          color: _testSucceeded
                              ? Colors.green.shade800
                              : Theme.of(context).colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          key: const Key('webdav_test_connection_button'),
                          onPressed: _busy ? null : _handleTestConnection,
                          icon: const Icon(Icons.wifi_tethering),
                          label: const Text('测试连接'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          key: const Key('webdav_save_config_button'),
                          onPressed: _busy ? null : _handleSave,
                          icon: const Icon(Icons.save_outlined),
                          label: const Text('保存配置'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
