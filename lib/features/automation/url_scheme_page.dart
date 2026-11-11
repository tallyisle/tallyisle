import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/automation/url_scheme_service.dart';
import '../../domain/rules/url_scheme_rules.dart';
import '../common/common.dart';
import 'automation_providers.dart';

/// Documentation, copyable templates, and live in-app URL Scheme tester (`F-033`).
class UrlSchemePage extends ConsumerStatefulWidget {
  const UrlSchemePage({super.key, this.onNavigateRoute});

  /// Optional override for route navigation in tests; defaults to `GoRouter.maybeOf(context)`.
  final void Function(String route)? onNavigateRoute;

  @override
  ConsumerState<UrlSchemePage> createState() => _UrlSchemePageState();
}

class _UrlSchemePageState extends ConsumerState<UrlSchemePage> {
  late final TextEditingController _uriController;
  final CommandIds _commandIds = CommandIds();
  int _nonce = 0;

  bool _executing = false;
  UrlSchemeExecutionResult? _lastResult;
  String? _lastError;

  @override
  void initState() {
    super.initState();
    _uriController = TextEditingController(
      text: urlSchemeTemplates[4].tallyIsleUri,
    );
  }

  @override
  void dispose() {
    _uriController.dispose();
    super.dispose();
  }

  Future<void> _copyText(String text, String label) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已复制$label链接')));
  }

  Future<void> _executeTestUri() async {
    final uriText = _uriController.text.trim();
    setState(() {
      _executing = true;
      _lastError = null;
      _lastResult = null;
    });
    try {
      final service = await ref.read(urlSchemeServiceProvider.future);
      final commandId = _commandIds.forPayload(['url-test', _nonce++, uriText]);
      final result = await service.executeUri(uriText, commandId: commandId);
      if (!mounted) return;
      setState(() => _lastResult = result);

      // Refresh desktop widget snapshot if a record was written.
      if (result.wroteRecord) {
        final widgetService = await ref.read(
          widgetSnapshotServiceProvider.future,
        );
        await widgetService.syncToPlatform();
        ref.invalidate(widgetSnapshotProvider);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _lastError = safeMessage(e));
    } finally {
      if (mounted) setState(() => _executing = false);
    }
  }

  void _openTargetRoute(String route) {
    final callback = widget.onNavigateRoute;
    if (callback != null) {
      callback(route);
      return;
    }
    final router = GoRouter.maybeOf(context);
    if (router != null) {
      if (route.startsWith('/record/new')) {
        router.push(route);
      } else {
        router.go(route);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      key: const Key('url_scheme_page'),
      appBar: AppBar(title: const Text('URL Scheme 外部调用')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.link, color: theme.colorScheme.primary),
                      const SizedBox(width: 8),
                      Text(
                        '双协议兼容支持',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '帐屿同时支持主协议头 tallyisle:// 与兼容协议头 yyjz://，'
                    '可通过快捷指令、桌面自动化脚本或外部应用一键跳转页面或直接静默记账。',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            key: const Key('url_scheme_tester_card'),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '在线调试器',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('url_scheme_test_input'),
                    controller: _uriController,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: '输入或选择待执行的 URL 链接',
                      hintText: 'tallyisle://addbill?type=0&money=18.50',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      FilledButton.icon(
                        key: const Key('url_scheme_execute_button'),
                        onPressed: _executing ? null : _executeTestUri,
                        icon: const Icon(Icons.play_arrow),
                        label: Text(_executing ? '执行中…' : '立即执行'),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton.icon(
                        key: const Key('url_scheme_copy_current_button'),
                        onPressed: () =>
                            _copyText(_uriController.text.trim(), '当前调试'),
                        icon: const Icon(Icons.copy, size: 18),
                        label: const Text('复制链接'),
                      ),
                    ],
                  ),
                  if (_lastError != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      key: const Key('url_scheme_result_error'),
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _lastError!,
                        style: TextStyle(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ],
                  if (_lastResult != null) ...[
                    const SizedBox(height: 12),
                    _ExecutionResultBanner(
                      result: _lastResult!,
                      onOpenRoute: _lastResult!.targetRoute == null
                          ? null
                          : () => _openTargetRoute(_lastResult!.targetRoute!),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            '常用调用模板',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < urlSchemeTemplates.length; i++) ...[
            _TemplateCard(
              index: i,
              template: urlSchemeTemplates[i],
              onFill: (uri) => setState(() {
                _uriController.text = uri;
                _lastError = null;
                _lastResult = null;
              }),
              onCopy: _copyText,
            ),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 12),
          const _ParameterDocsCard(),
        ],
      ),
    );
  }
}

class _ExecutionResultBanner extends StatelessWidget {
  const _ExecutionResultBanner({required this.result, this.onOpenRoute});

  final UrlSchemeExecutionResult result;
  final VoidCallback? onOpenRoute;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const Key('url_scheme_result_success'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            result.wroteRecord
                ? '已成功写入账单（ID: ${result.createdRecordId}）'
                : '解析成功：目标路由 ${result.targetRoute ?? '内部动作'}',
            style: TextStyle(
              color: theme.colorScheme.onSecondaryContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (result.resolvedBookId != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '生效账本 ID：${result.resolvedBookId}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSecondaryContainer,
                ),
              ),
            ),
          if (onOpenRoute != null) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              key: const Key('url_scheme_open_route_button'),
              onPressed: onOpenRoute,
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('前往目标页面'),
            ),
          ],
        ],
      ),
    );
  }
}

class _TemplateCard extends StatelessWidget {
  const _TemplateCard({
    required this.index,
    required this.template,
    required this.onFill,
    required this.onCopy,
  });

  final int index;
  final UrlSchemeTemplate template;
  final ValueChanged<String> onFill;
  final Future<void> Function(String text, String label) onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: Key('url_template_card_$index'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              template.title,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(template.description, style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            SelectableText(
              template.tallyIsleUri,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                ActionChip(
                  key: Key('url_template_fill_$index'),
                  avatar: const Icon(Icons.bolt_outlined, size: 16),
                  label: const Text('填入调试'),
                  onPressed: () => onFill(template.tallyIsleUri),
                ),
                ActionChip(
                  key: Key('url_template_copy_primary_$index'),
                  avatar: const Icon(Icons.copy, size: 16),
                  label: const Text('复制 tallyisle://'),
                  onPressed: () => onCopy(template.tallyIsleUri, '主协议'),
                ),
                ActionChip(
                  key: Key('url_template_copy_legacy_$index'),
                  avatar: const Icon(Icons.history, size: 16),
                  label: const Text('复制 yyjz://'),
                  onPressed: () => onCopy(template.legacyUri, '兼容协议'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ParameterDocsCard extends StatelessWidget {
  const _ParameterDocsCard();

  static const _params = <(String, String)>[
    ('type', '账单类型：0 支出（默认）、1 收入、2 转账、3 报销、9 预收、16 预支'),
    ('money', '金额（元，最多两位小数，如 25.50；使用整数分精确计算）'),
    ('discount', '优惠金额（元，可选，仅支出/收入有效，不大于 money）'),
    ('fee', '转账手续费（元，可选，type=2 时生成关联手续费记录）'),
    ('book', '账本名称或数字 ID（省略时写入当前默认账本）'),
    ('category', '分类名称、“父分类>子分类”路径或数字 ID'),
    ('asset1', '账户 / 转出账户名称或数字 ID'),
    ('asset2', '转入账户名称或数字 ID（type=2 转账必填）'),
    ('remark', '备注文本（可选，最长 2000 字）'),
    ('datetime', '时间（支持毫秒时间戳、YYYY-MM-DD HH:mm:ss 或 YYYYMMDDHHmmss）'),
    ('tags', '标签名称或 ID 列表（多个标签以英文或中文逗号分隔）'),
    ('exbudget / exstat', '传 1 或 true 时标记不计入预算 / 不计入收支统计'),
    ('showsheet', '传 1 或 true 时改为拉起记账编辑页确认，不直接静默入账'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: const Key('url_scheme_docs_card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'addbill / newbill 参数说明',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            for (final (name, desc) in _params)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 112,
                      child: Text(
                        name,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(desc, style: theme.textTheme.bodySmall),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
