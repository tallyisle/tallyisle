import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/backup/s3_client.dart';
import '../../domain/rules/s3_sigv4_rules.dart';
import '../../domain/rules/tally_backup.dart';
import '../common/common.dart';
import 'backup_providers.dart';

class S3ConfigPage extends ConsumerStatefulWidget {
  const S3ConfigPage({super.key, this.initialConfig});

  final S3Config? initialConfig;

  @override
  ConsumerState<S3ConfigPage> createState() => _S3ConfigPageState();
}

class _S3ConfigPageState extends ConsumerState<S3ConfigPage> {
  static const List<int> _presetKeepCounts = <int>[5, 10, 20, 30, 50];

  late S3Config _baseConfig;
  late final TextEditingController _endpointController;
  late final TextEditingController _regionController;
  late final TextEditingController _bucketController;
  late final TextEditingController _accessKeyController;
  late final TextEditingController _secretKeyController;
  late final TextEditingController _prefixController;

  late bool _forcePathStyle;
  late int _keepCount;
  late bool _autoBackupEnabled;
  ProviderSubscription<AsyncValue<S3Config>>? _configSub;
  bool _userTouched = false;
  bool _obscureSecretKey = true;
  bool _busy = false;
  String? _testStatusMessage;
  bool _testSucceeded = false;

  @override
  void initState() {
    super.initState();
    final cfg = widget.initialConfig ?? const S3Config.unconfigured();
    _baseConfig = cfg;
    _endpointController = TextEditingController(text: cfg.endpoint);
    _regionController = TextEditingController(
      text: cfg.region.isEmpty ? defaultS3Region : cfg.region,
    );
    _bucketController = TextEditingController(text: cfg.bucket);
    _accessKeyController = TextEditingController(text: cfg.accessKeyId);
    _secretKeyController = TextEditingController(text: cfg.secretAccessKey);
    _prefixController = TextEditingController(
      text: cfg.remotePrefix.isEmpty ? defaultS3RemotePrefix : cfg.remotePrefix,
    );
    _forcePathStyle = cfg.forcePathStyle;
    _keepCount = cfg.keepCount > 0 ? cfg.keepCount : defaultWebDavKeepCount;
    _autoBackupEnabled = cfg.autoBackupEnabled;

    if (widget.initialConfig == null) {
      _configSub = ref.listenManual<AsyncValue<S3Config>>(s3ConfigProvider, (
        _,
        next,
      ) {
        final loaded = next.value;
        if (loaded != null) {
          _applyLoadedConfigIfUntouched(loaded);
        }
      });
      unawaited(_loadStoredConfig());
    }
  }

  void _applyLoadedConfigIfUntouched(S3Config loaded) {
    if (!mounted || _userTouched || _busy) return;
    setState(() {
      _baseConfig = loaded;
      _endpointController.text = loaded.endpoint;
      _regionController.text = loaded.region.isEmpty
          ? defaultS3Region
          : loaded.region;
      _bucketController.text = loaded.bucket;
      _accessKeyController.text = loaded.accessKeyId;
      _secretKeyController.text = loaded.secretAccessKey;
      _prefixController.text = loaded.remotePrefix.isEmpty
          ? defaultS3RemotePrefix
          : loaded.remotePrefix;
      _forcePathStyle = loaded.forcePathStyle;
      _keepCount = loaded.keepCount > 0
          ? loaded.keepCount
          : defaultWebDavKeepCount;
      _autoBackupEnabled = loaded.autoBackupEnabled;
    });
  }

  Future<void> _loadStoredConfig() async {
    try {
      final service = await ref.read(tallyBackupServiceProvider.future);
      final fresh = await service.getS3Config();
      _applyLoadedConfigIfUntouched(fresh);
      final streamed = await ref.read(s3ConfigProvider.future);
      _applyLoadedConfigIfUntouched(
        fresh.isConfigured || !streamed.isConfigured ? fresh : streamed,
      );
    } catch (_) {
      try {
        final streamed = await ref.read(s3ConfigProvider.future);
        _applyLoadedConfigIfUntouched(streamed);
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _configSub?.close();
    _endpointController.dispose();
    _regionController.dispose();
    _bucketController.dispose();
    _accessKeyController.dispose();
    _secretKeyController.dispose();
    _prefixController.dispose();
    super.dispose();
  }

  S3Config _buildDraftConfig() {
    final regionText = _regionController.text.trim().isEmpty
        ? defaultS3Region
        : _regionController.text.trim();
    final prefixText = _prefixController.text.trim().isEmpty
        ? defaultS3RemotePrefix
        : _prefixController.text.trim();
    return _baseConfig.copyWith(
      endpoint: _endpointController.text.trim(),
      region: regionText,
      bucket: _bucketController.text.trim(),
      accessKeyId: _accessKeyController.text.trim(),
      secretAccessKey: _secretKeyController.text,
      remotePrefix: prefixText,
      forcePathStyle: _forcePathStyle,
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
      await service.testS3Connection(_buildDraftConfig());
      if (!mounted) return;
      setState(() {
        _testSucceeded = true;
        _testStatusMessage = '连接成功，S3 签名认证与对象读写删除验证通过';
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
        const SnackBar(
          content: Text('请填写有效的 Endpoint、Bucket、Access Key ID 与 Secret Key'),
        ),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      final service = await ref.read(tallyBackupServiceProvider.future);
      await service.saveS3Config(draft);
      ref
        ..invalidate(s3ConfigProvider)
        ..invalidate(cloudSyncSettingsProvider)
        ..invalidate(s3BackupsProvider)
        ..invalidate(activeCloudBackupsProvider);
      if (!mounted) return;
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop(true);
      } else {
        setState(() => _baseConfig = draft);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('S3 配置已更新')));
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
      title: '清除 S3 对象存储配置？',
      message: '清除后将停止自动同步与自动云备份，存储桶内已有的数据不会被删除。',
      ok: '清除',
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    try {
      final service = await ref.read(tallyBackupServiceProvider.future);
      await service.clearS3Config();
      ref
        ..invalidate(s3ConfigProvider)
        ..invalidate(cloudSyncSettingsProvider)
        ..invalidate(s3BackupsProvider)
        ..invalidate(activeCloudBackupsProvider);
      if (!mounted) return;
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop(true);
      } else {
        setState(() {
          _baseConfig = S3Config(
            includeAttachments: _baseConfig.includeAttachments,
            keepCount: _keepCount,
            forcePathStyle: _forcePathStyle,
          );
          _endpointController.clear();
          _regionController.text = defaultS3Region;
          _bucketController.clear();
          _accessKeyController.clear();
          _secretKeyController.clear();
          _prefixController.text = defaultS3RemotePrefix;
          _autoBackupEnabled = false;
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('S3 配置已清除')));
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
      key: const Key('s3_config_page'),
      appBar: AppBar(
        title: const Text('S3 对象存储配置'),
        actions: [
          if (_baseConfig.isConfigured)
            TextButton(
              key: const Key('s3_clear_config_button'),
              onPressed: _busy ? null : _handleClear,
              child: const Text('清除配置'),
            ),
        ],
      ),
      body: Column(
        children: [
          if (_busy) const LinearProgressIndicator(key: Key('s3_config_busy')),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '兼容 AWS S3、Cloudflare R2、阿里云 OSS、腾讯云 COS、MinIO 与 Backblaze B2（标准 AWS SigV4 签名）。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('s3_endpoint_input'),
                    controller: _endpointController,
                    enabled: !_busy,
                    keyboardType: TextInputType.url,
                    onChanged: (_) => _userTouched = true,
                    decoration: const InputDecoration(
                      labelText: 'Endpoint 地址',
                      hintText:
                          'https://<account>.r2.cloudflarestorage.com 或 https://s3.us-east-1.amazonaws.com',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: const Key('s3_region_input'),
                          controller: _regionController,
                          enabled: !_busy,
                          onChanged: (_) => _userTouched = true,
                          decoration: const InputDecoration(
                            labelText: 'Region 区域',
                            hintText: 'auto / us-east-1',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          key: const Key('s3_bucket_input'),
                          controller: _bucketController,
                          enabled: !_busy,
                          onChanged: (_) => _userTouched = true,
                          decoration: const InputDecoration(
                            labelText: 'Bucket 桶名称',
                            hintText: 'tallyisle-data',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('s3_access_key_input'),
                    controller: _accessKeyController,
                    enabled: !_busy,
                    onChanged: (_) => _userTouched = true,
                    decoration: const InputDecoration(
                      labelText: 'Access Key ID',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('s3_secret_key_input'),
                    controller: _secretKeyController,
                    enabled: !_busy,
                    obscureText: _obscureSecretKey,
                    onChanged: (_) => _userTouched = true,
                    decoration: InputDecoration(
                      labelText: 'Secret Access Key',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscureSecretKey
                              ? Icons.visibility
                              : Icons.visibility_off,
                        ),
                        onPressed: () => setState(
                          () => _obscureSecretKey = !_obscureSecretKey,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('s3_prefix_input'),
                    controller: _prefixController,
                    enabled: !_busy,
                    onChanged: (_) => _userTouched = true,
                    decoration: const InputDecoration(
                      labelText: '远端对象前缀（Prefix）',
                      hintText: 'TallyIsle',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    key: const Key('s3_path_style_switch'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Path-Style 路径寻址模式'),
                    subtitle: Text(
                      _forcePathStyle
                          ? '默认开启（endpoint/bucket/key），广泛兼容 MinIO、R2 与自建服务'
                          : 'Virtual-Hosted 虚拟主机模式（bucket.endpoint/key），适用于强制子域名的对象存储',
                    ),
                    value: _forcePathStyle,
                    onChanged: _busy
                        ? null
                        : (val) {
                            _userTouched = true;
                            setState(() => _forcePathStyle = val);
                          },
                  ),
                  const SizedBox(height: 8),
                  InputDecorator(
                    decoration: const InputDecoration(
                      labelText: '远端自动保留备份份数',
                      border: OutlineInputBorder(),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<int>(
                        key: const Key('s3_keep_count_dropdown'),
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
                    key: const Key('s3_auto_backup_switch'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('开启自动静默云备份'),
                    subtitle: const Text('距上次备份超过 24 小时且本地产生新账单变动时自动归档上传'),
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
                      key: const Key('s3_test_result_banner'),
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
                          key: const Key('s3_test_connection_button'),
                          onPressed: _busy ? null : _handleTestConnection,
                          icon: const Icon(Icons.wifi_tethering),
                          label: const Text('测试连接'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          key: const Key('s3_save_config_button'),
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
