import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/adaptive.dart';
import '../../data/automation/mcp_server_service.dart';
import '../../data/automation/mcp_tool_dispatcher.dart';
import '../../domain/rules/mcp_rules.dart';
import '../common/common.dart';
import 'automation_providers.dart';

const List<String> _monoFontFallbackChain = <String>[
  'SF Mono',
  'Menlo',
  'Cascadia Mono',
  'Consolas',
  'JetBrains Mono',
  'DejaVu Sans Mono',
  'Liberation Mono',
  'Noto Sans Mono',
  'PingFang SC',
  'Hiragino Sans GB',
  'Microsoft YaHei UI',
  'Microsoft YaHei',
  'Noto Sans CJK SC',
  'Source Han Sans SC',
  'monospace',
  'sans-serif',
];

String _platformMonoFontFamily(BuildContext context) {
  if (!DesktopAdaptive.isDesktop(context)) {
    return 'monospace';
  }
  return switch (Theme.of(context).platform) {
    TargetPlatform.macOS || TargetPlatform.iOS => 'Menlo',
    TargetPlatform.windows => 'Consolas',
    _ => 'DejaVu Sans Mono',
  };
}

/// Embedded Streamable HTTP MCP Server configuration & telemetry page (`F-039`).
class McpSettingsPage extends ConsumerStatefulWidget {
  const McpSettingsPage({super.key});

  @override
  ConsumerState<McpSettingsPage> createState() => _McpSettingsPageState();
}

class _McpSettingsPageState extends ConsumerState<McpSettingsPage> {
  final CommandIds _commandIds = CommandIds();
  int _nonce = 0;
  bool _busy = false;
  bool _revealToken = false;
  String? _error;

  String _nextCommandId(String op, Object? arg) =>
      _commandIds.forPayload(<Object?>['mcp-ui', op, _nonce++, arg]);

  Future<void> _copyText(String text, String label) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text('已复制$label')));
  }

  Future<void> _runMutation(
    Future<void> Function(McpServerService service) action,
  ) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final service = await ref.read(mcpServerServiceProvider.future);
      await action(service);
    } catch (e) {
      if (mounted) {
        setState(() => _error = safeMessage(e));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _openPortDialog(McpServerConfig config) async {
    final nextPort = await showDialog<int>(
      context: context,
      builder: (_) => _McpPortEditDialog(initialPort: config.port),
    );
    if (nextPort == null || nextPort == config.port || !mounted) return;
    await _runMutation(
      (svc) =>
          svc.setPort(nextPort, commandId: _nextCommandId('port', nextPort)),
    );
  }

  Future<void> _confirmRegenerateToken() async {
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            key: const Key('mcp_token_regenerate_dialog'),
            title: const Text('重置 Bearer 访问令牌？'),
            content: const Text('重置后原令牌立即失效，已配置的 AI 客户端需更新为新令牌后才能继续连接。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              FilledButton(
                key: const Key('mcp_token_regenerate_confirm_button'),
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('确认重置'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    await _runMutation(
      (svc) => svc.regenerateAuthToken(
        commandId: _nextCommandId(
          'regen-token',
          DateTime.now().microsecondsSinceEpoch,
        ),
      ),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(const SnackBar(content: Text('已生成新的 MCP 访问令牌')));
  }

  @override
  Widget build(BuildContext context) {
    final configAsync = ref.watch(mcpServerConfigProvider);
    final statusAsync = ref.watch(mcpRuntimeStatusProvider);
    final isDesktop = DesktopAdaptive.isDesktop(context);

    final body = asyncBody(configAsync, (config) {
      final status =
          statusAsync.value ??
          McpRuntimeStatus(boundHost: config.bindAddress, port: config.port);
      final effectivePort = status.isRunning ? status.port : config.port;
      final loopbackUrl = 'http://127.0.0.1:$effectivePort/mcp';
      final preferredEndpointUrl = (config.bindLan && status.lanIps.isNotEmpty)
          ? 'http://${status.lanIps.first}:$effectivePort/mcp'
          : loopbackUrl;
      final clientConfigJson = buildMcpClientConfigJson(
        endpointUrl: preferredEndpointUrl,
        bearerToken: config.effectiveRequireAuth ? config.authToken : null,
      );

      final theme = Theme.of(context);
      final scheme = theme.colorScheme;
      final monoStyle = theme.textTheme.bodySmall?.copyWith(
        fontFamily: _platformMonoFontFamily(context),
        fontFamilyFallback: _monoFontFallbackChain,
      );

      final listView = ListView(
        key: const Key('mcp_settings_list'),
        padding: const EdgeInsets.all(16),
        children: [
          _McpStatusCard(
            config: config,
            status: status,
            loopbackUrl: loopbackUrl,
            effectivePort: effectivePort,
            monoStyle: monoStyle,
            onCopyUrl: (url) => _copyText(url, ' MCP 接口地址'),
          ),
          if (_error != null || status.lastError != null) ...[
            const SizedBox(height: 12),
            Container(
              key: const Key('mcp_error_banner'),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.errorContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                _error ?? status.lastError!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onErrorContainer,
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          _TonalCard(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    key: const Key('mcp_enable_switch'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('启用本机 MCP 服务'),
                    subtitle: const Text(
                      '基于标准 Streamable HTTP (JSON-RPC 2.0) 开放离线账务上下文与工具调用',
                    ),
                    value: config.enabled,
                    onChanged: (_busy || !status.isPlatformSupported)
                        ? null
                        : (v) => _runMutation(
                            (svc) => svc.setEnabled(
                              v,
                              commandId: _nextCommandId('enable', v),
                            ),
                          ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '智能体权限档位',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<McpPermissionTier>(
                      key: const Key('mcp_permission_tier_segmented'),
                      showSelectedIcon: false,
                      segments: [
                        for (final tier in McpPermissionTier.values)
                          ButtonSegment<McpPermissionTier>(
                            value: tier,
                            label: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                tier.label,
                                maxLines: 1,
                                softWrap: false,
                              ),
                            ),
                          ),
                      ],
                      selected: <McpPermissionTier>{config.permissionTier},
                      onSelectionChanged: _busy
                          ? null
                          : (selection) {
                              final next = selection.first;
                              if (next == config.permissionTier) return;
                              _runMutation(
                                (svc) => svc.setPermissionTier(
                                  next,
                                  commandId: _nextCommandId(
                                    'tier',
                                    next.wireName,
                                  ),
                                ),
                              );
                            },
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color:
                          config.permissionTier == McpPermissionTier.fullAccess
                          ? scheme.tertiaryContainer
                          : scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      config.permissionTier.description,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color:
                            config.permissionTier ==
                                McpPermissionTier.fullAccess
                            ? scheme.onTertiaryContainer
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          _TonalCard(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '网络与安全鉴权',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  SwitchListTile(
                    key: const Key('mcp_bind_lan_switch'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('允许局域网设备接入 (0.0.0.0)'),
                    subtitle: Text(
                      config.bindLan
                          ? '已监听全部网卡（0.0.0.0），同一 Wi-Fi / 局域网电脑智能体可远程连接'
                          : '仅监听本机回环（127.0.0.1），外部网络无法访问',
                    ),
                    value: config.bindLan,
                    onChanged: _busy
                        ? null
                        : (v) => _runMutation(
                            (svc) => svc.setBindLan(
                              v,
                              commandId: _nextCommandId('lan', v),
                            ),
                          ),
                  ),
                  ListTile(
                    key: const Key('mcp_port_tile'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('监听端口'),
                    subtitle: Text('当前端口：${config.port}（范围 1024–65535）'),
                    trailing: const Icon(Icons.edit_outlined, size: 20),
                    onTap: _busy ? null : () => _openPortDialog(config),
                  ),
                  SwitchListTile(
                    key: const Key('mcp_require_auth_switch'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('启用 Bearer 令牌鉴权'),
                    subtitle: Text(
                      config.bindLan
                          ? '开启局域网接入时强制锁定启用 Bearer 令牌鉴权'
                          : '校验请求头 Authorization: Bearer <token> 或 X-MCP-Token',
                    ),
                    value: config.effectiveRequireAuth,
                    onChanged: (_busy || config.bindLan)
                        ? null
                        : (v) => _runMutation(
                            (svc) => svc.setRequireAuth(
                              v,
                              commandId: _nextCommandId('auth', v),
                            ),
                          ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Bearer 访问令牌（256-bit CSPRNG）',
                          style: theme.textTheme.labelMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          key: const Key('mcp_token_value_text'),
                          _revealToken
                              ? config.authToken
                              : maskMcpToken(config.authToken),
                          style: monoStyle,
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            TallySoftButton.icon(
                              key: const Key('mcp_token_visibility_button'),
                              compact: true,
                              onPressed: () =>
                                  setState(() => _revealToken = !_revealToken),
                              icon: Icon(
                                _revealToken
                                    ? Icons.visibility_off_outlined
                                    : Icons.visibility_outlined,
                                size: 16,
                              ),
                              label: Text(_revealToken ? '隐藏令牌' : '显示令牌'),
                            ),
                            TallySoftButton.icon(
                              key: const Key('mcp_token_copy_button'),
                              compact: true,
                              onPressed: () =>
                                  _copyText(config.authToken, ' Bearer 令牌'),
                              icon: const Icon(Icons.copy_outlined, size: 16),
                              label: const Text('复制令牌'),
                            ),
                            TextButton.icon(
                              key: const Key('mcp_token_regenerate_button'),
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                              ),
                              onPressed: _busy ? null : _confirmRegenerateToken,
                              icon: const Icon(Icons.refresh, size: 16),
                              label: const Text('重置令牌'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          _TonalCard(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'AI 客户端接入配置',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    isDesktop
                        ? '适用于 Claude Code、Cursor、Cherry Studio、Cline 等支持 Streamable HTTP 的 MCP 客户端。'
                        : (DesktopAdaptive.isOhos(context)
                              ? '适用于 Claude Code、Cursor、Cherry Studio、Cline 等支持 Streamable HTTP 的 MCP 客户端。在 HarmonyOS 设备运行时请保持帐屿处于前台，电脑端远程连接请开启局域网接入 (0.0.0.0)。'
                              : '适用于 Claude Code、Cursor、Cherry Studio、Cline 等支持 Streamable HTTP 的 MCP 客户端。移动设备运行时请保持帐屿处于前台，电脑端远程连接请开启局域网接入 (0.0.0.0)。'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _revealToken
                          ? clientConfigJson
                          : buildMcpClientConfigJson(
                              endpointUrl: preferredEndpointUrl,
                              bearerToken: config.effectiveRequireAuth
                                  ? maskMcpToken(config.authToken)
                                  : null,
                            ),
                      style: monoStyle,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: TallySoftButton.icon(
                      key: const Key('mcp_copy_client_config_button'),
                      onPressed: () =>
                          _copyText(clientConfigJson, ' MCP 客户端配置 JSON'),
                      icon: const Icon(
                        Icons.integration_instructions_outlined,
                        size: 18,
                      ),
                      label: const FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          '一键复制客户端配置 JSON',
                          maxLines: 1,
                          softWrap: false,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          _McpToolsSummaryCard(permissionTier: config.permissionTier),
        ],
      );

      if (!isDesktop) return listView;
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: listView,
        ),
      );
    });

    return Scaffold(
      key: const Key('mcp_settings_page'),
      appBar: AppBar(
        scrolledUnderElevation: isDesktop ? 0 : null,
        title: const Text('MCP 服务'),
      ),
      body: body,
    );
  }
}

class _McpStatusCard extends StatelessWidget {
  const _McpStatusCard({
    required this.config,
    required this.status,
    required this.loopbackUrl,
    required this.effectivePort,
    required this.monoStyle,
    required this.onCopyUrl,
  });

  final McpServerConfig config;
  final McpRuntimeStatus status;
  final String loopbackUrl;
  final int effectivePort;
  final TextStyle? monoStyle;
  final ValueChanged<String> onCopyUrl;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final running = status.isRunning;
    final badgeText = !status.isPlatformSupported
        ? '当前平台不支持'
        : (running ? '运行中' : '已停止');

    final endpoints = <String>[
      loopbackUrl,
      if (config.bindLan)
        for (final ip in status.lanIps) 'http://$ip:$effectivePort/mcp',
    ];

    return _TonalCard(
      key: const Key('mcp_status_card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  running ? Icons.hub : Icons.portable_wifi_off_outlined,
                  color: running ? scheme.primary : scheme.outline,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        'Streamable HTTP 端点',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Container(
                        key: const Key('mcp_status_badge'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: running
                              ? scheme.primaryContainer
                              : scheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          badgeText,
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: running
                                ? scheme.onPrimaryContainer
                                : scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            for (final url in endpoints) ...[
              Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        url,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: monoStyle,
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: '复制接口地址',
                      onPressed: () => onCopyUrl(url),
                      icon: const Icon(Icons.copy_outlined, size: 18),
                    ),
                  ],
                ),
              ),
            ],
            if (config.bindLan && status.lanIps.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '当前未检测到活动局域网 IPv4 地址，连接 Wi-Fi 或以太网后即可通过局域网 IP 访问。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                Text(
                  '监听范围：${config.bindAddress}:$effectivePort',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  '累计调用：${status.requestCount} 次',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                if (status.lastRequestAtMs != null)
                  Text(
                    '最近请求：${formatDateTime(DateTime.fromMillisecondsSinceEpoch(status.lastRequestAtMs!))}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _McpToolsSummaryCard extends StatelessWidget {
  const _McpToolsSummaryCard({required this.permissionTier});

  final McpPermissionTier permissionTier;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final permittedCount = mcpToolsForPermissionTier(permissionTier).length;

    Widget buildGroup(String title, McpToolTier tier, List<McpToolSpec> tools) {
      final enabled = permissionTier.allows(tier);
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  '$title (${tools.length})',
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: enabled
                        ? scheme.secondaryContainer
                        : scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    enabled ? '已开放' : '当前档位已拦截',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: enabled
                          ? scheme.onSecondaryContainer
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final tool in tools)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: enabled
                          ? scheme.surfaceContainerHighest
                          : scheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      tool.name,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: enabled
                            ? scheme.onSurface
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      );
    }

    final readTools = mcpToolCatalog
        .where((t) => t.tier == McpToolTier.read)
        .toList(growable: false);
    final appendTools = mcpToolCatalog
        .where((t) => t.tier == McpToolTier.append)
        .toList(growable: false);
    final fullTools = mcpToolCatalog
        .where((t) => t.tier == McpToolTier.full)
        .toList(growable: false);

    return _TonalCard(
      key: const Key('mcp_tools_summary_card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '可用工具与资源目录（已开放 $permittedCount / ${mcpToolCatalog.length} 项）',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '只读资源：tallyisle://overview · tallyisle://books · tallyisle://assets',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            buildGroup('只读查询工具', McpToolTier.read, readTools),
            buildGroup('新增与草稿工具', McpToolTier.append, appendTools),
            buildGroup('修改与删除工具', McpToolTier.full, fullTools),
          ],
        ),
      ),
    );
  }
}

class _McpPortEditDialog extends StatefulWidget {
  const _McpPortEditDialog({required this.initialPort});

  final int initialPort;

  @override
  State<_McpPortEditDialog> createState() => _McpPortEditDialogState();
}

class _McpPortEditDialogState extends State<_McpPortEditDialog> {
  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: '${widget.initialPort}');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    try {
      final port = parseAndValidateMcpPort(_controller.text);
      Navigator.pop(context, port);
    } catch (e) {
      setState(() => _error = safeMessage(e));
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const Key('mcp_port_dialog'),
    title: const Text('设置 MCP 监听端口'),
    content: SizedBox(
      width: 360,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const Key('mcp_port_input'),
            controller: _controller,
            keyboardType: TextInputType.number,
            autofocus: true,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: '端口号 (1024–65535)',
              hintText: '$defaultMcpPort',
              errorText: _error,
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const Key('mcp_port_save_button'),
        onPressed: _submit,
        child: const Text('保存'),
      ),
    ],
  );
}

/// 无边框柔和色调卡片（16dp 圆角）。
class _TonalCard extends StatelessWidget {
  const _TonalCard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      color: isDark
          ? scheme.surfaceContainerLow
          : Color.lerp(
              scheme.surfaceContainerLow,
              scheme.surfaceContainer,
              0.55,
            )!,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: child,
    );
  }
}
