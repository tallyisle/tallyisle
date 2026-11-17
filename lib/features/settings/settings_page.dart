import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../app/adaptive.dart';
import '../../core/failure.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/app_settings_rules.dart';
import '../common/desktop_modal_page.dart';
import '../me/me_page.dart' show MeEmbeddedNavigationScope;
import '../receipt/diy_toolbar_settings_page.dart'
    show DefaultAccountPreferenceSection;
import '../security/app_lock_settings_page.dart';
import 'about_help_page.dart';
import 'data_health_page.dart';
import 'settings_providers.dart';
import 'stat_stories_page.dart';

const _uuid = Uuid();

const List<String> _shortcutMonoFallback = <String>[
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

/// System & Home Settings hub page (`F-038`, `P-03`), linking to App Lock
/// (`F-024`), Data Health Check (`ADR-012`), Stat Stories, and Help/About.
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  bool _busy = false;

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _updateSettings(
    AppSettings next, {
    String? successMessage,
  }) async {
    setState(() => _busy = true);
    try {
      final svc = await ref.read(appSettingsServiceProvider.future);
      await svc.saveSettings(commandId: _uuid.v4(), settings: next);
      if (successMessage != null) {
        _toast(successMessage);
      }
    } on Failure catch (f) {
      _toast(f.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openCustomHexDialog(AppSettings current) async {
    final hex = await showDialog<String>(
      context: context,
      builder: (_) => _CustomThemeHexDialog(initialHex: current.themeSeedHex),
    );
    if (hex == null || !mounted) return;
    try {
      final updated = current.copyWith(themeSeedHex: hex);
      await _updateSettings(
        updated,
        successMessage: '主题色已更新为 #${updated.themeSeedHex}',
      );
    } on Failure catch (f) {
      _toast(f.message);
    }
  }

  Future<void> _confirmResetDefaults() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('恢复默认设置'),
        content: const Text('将首页展示开关、默认记账类型与外观主题恢复为初始状态（不会影响账本数据或应用安全锁）。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('setting_confirm_reset_button'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('恢复默认'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final svc = await ref.read(appSettingsServiceProvider.future);
      await svc.resetSettings(commandId: _uuid.v4());
      _toast('已恢复默认设置');
    } on Failure catch (f) {
      _toast(f.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _navigateSibling(
    BuildContext context, {
    required String route,
    required Widget page,
  }) {
    final meScope = MeEmbeddedNavigationScope.maybeOf(context);
    if (meScope != null) {
      meScope.onSelectRoute(route);
      return;
    }
    if (DesktopAdaptive.isDesktop(context)) {
      pushDesktopModalOrMaterialRoute<void>(context, child: page);
      return;
    }
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(appSettingsProvider);
    final theme = Theme.of(context);
    final isDesktop = DesktopAdaptive.isDesktop(context);

    return Scaffold(
      appBar: AppBar(
        scrolledUnderElevation: isDesktop ? 0 : null,
        title: const Text('系统与首页设置'),
      ),
      body: settingsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Center(child: Text('读取设置失败：$err')),
        data: (settings) {
          final isPreset = themeSeedPresets.any(
            (p) => p.hex == settings.themeSeedHex,
          );

          final listView = ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              const _SectionHeader(title: '首页与记账偏好'),
              Card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SwitchListTile(
                      key: const Key('setting_show_balance_change_switch'),
                      title: const Text('首页显示余额调整记录'),
                      subtitle: const Text('在首页收支流水中显示「账户余额变更」调整记录；不计入收支统计'),
                      value: settings.showBalanceChangeRecordOnHome,
                      onChanged: _busy
                          ? null
                          : (val) => _updateSettings(
                              settings.copyWith(
                                showBalanceChangeRecordOnHome: val,
                              ),
                            ),
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      key: const Key('setting_show_asset_banner_switch'),
                      title: const Text('首页展示净资产概览卡片'),
                      subtitle: const Text('在首页顶部展示可见账户净资产与资产负债概览'),
                      value: settings.showHomeAssetSummaryBanner,
                      onChanged: _busy
                          ? null
                          : (val) => _updateSettings(
                              settings.copyWith(
                                showHomeAssetSummaryBanner: val,
                              ),
                            ),
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      key: const Key('setting_show_budget_card_switch'),
                      title: const Text('首页展示本期预算进度'),
                      subtitle: const Text('在首页展示当前账期的总预算剩余与进度'),
                      value: settings.showHomeBudgetCard,
                      onChanged: _busy
                          ? null
                          : (val) => _updateSettings(
                              settings.copyWith(showHomeBudgetCard: val),
                            ),
                    ),
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text('“记一笔”默认类型', style: theme.textTheme.titleSmall),
                          const SizedBox(height: 8),
                          SizedBox(
                            width: double.infinity,
                            child: SegmentedButton<int>(
                              key: const Key(
                                'setting_default_record_type_segmented',
                              ),
                              showSelectedIcon: false,
                              segments: const [
                                ButtonSegment<int>(
                                  value: RecordType.expense,
                                  label: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text(
                                      '支出',
                                      maxLines: 1,
                                      softWrap: false,
                                    ),
                                  ),
                                  icon: Icon(
                                    Icons.remove_circle_outline,
                                    size: 18,
                                  ),
                                ),
                                ButtonSegment<int>(
                                  value: RecordType.income,
                                  label: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text(
                                      '收入',
                                      maxLines: 1,
                                      softWrap: false,
                                    ),
                                  ),
                                  icon: Icon(
                                    Icons.add_circle_outline,
                                    size: 18,
                                  ),
                                ),
                                ButtonSegment<int>(
                                  value: RecordType.transfer,
                                  label: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text(
                                      '转账',
                                      maxLines: 1,
                                      softWrap: false,
                                    ),
                                  ),
                                  icon: Icon(Icons.swap_horiz, size: 18),
                                ),
                              ],
                              selected: <int>{settings.defaultRecordType},
                              onSelectionChanged: _busy
                                  ? null
                                  : (selected) => _updateSettings(
                                      settings.copyWith(
                                        defaultRecordType: selected.first,
                                      ),
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    DefaultAccountPreferenceSection(
                      switchKey: const Key('setting_default_account_switch'),
                      selectorKey: const Key(
                        'setting_default_account_selector',
                      ),
                      externalBusy: _busy,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const _SectionHeader(title: '外观与主题'),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('深浅色模式', style: theme.textTheme.titleSmall),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: SegmentedButton<AppThemeModePreference>(
                          key: const Key('setting_theme_mode_segmented'),
                          showSelectedIcon: false,
                          segments: [
                            for (final mode in AppThemeModePreference.values)
                              ButtonSegment<AppThemeModePreference>(
                                value: mode,
                                label: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    mode.label,
                                    maxLines: 1,
                                    softWrap: false,
                                  ),
                                ),
                              ),
                          ],
                          selected: <AppThemeModePreference>{
                            settings.themeMode,
                          },
                          onSelectionChanged: _busy
                              ? null
                              : (selected) => _updateSettings(
                                  settings.copyWith(themeMode: selected.first),
                                ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text('品牌与主题色板', style: theme.textTheme.titleSmall),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final preset in themeSeedPresets)
                            ChoiceChip(
                              key: Key('theme_preset_${preset.hex}'),
                              avatar: CircleAvatar(
                                backgroundColor: Color(preset.argb32),
                                radius: 8,
                              ),
                              label: Text(preset.name),
                              selected: settings.themeSeedHex == preset.hex,
                              onSelected: _busy
                                  ? null
                                  : (_) => _updateSettings(
                                      settings.copyWith(
                                        themeSeedHex: preset.hex,
                                      ),
                                    ),
                            ),
                          ChoiceChip(
                            key: const Key('theme_custom_hex_chip'),
                            avatar: CircleAvatar(
                              backgroundColor: Color(settings.themeSeedArgb32),
                              radius: 8,
                            ),
                            label: Text('自定义 #${settings.themeSeedHex}'),
                            selected: !isPreset,
                            onSelected: _busy
                                ? null
                                : (_) => _openCustomHexDialog(settings),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const _SectionHeader(title: '安全、数据体检与更多'),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      key: const Key('nav_app_lock_tile'),
                      leading: const Icon(Icons.lock_outline),
                      title: const Text('应用安全锁'),
                      subtitle: const Text('4/6 位加盐数字密码、生物识别与后台超时锁定'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _navigateSibling(
                        context,
                        route: '/security/app-lock',
                        page: const AppLockSettingsPage(),
                      ),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      key: const Key('nav_data_health_tile'),
                      leading: const Icon(Icons.health_and_safety_outlined),
                      title: const Text('数据体检'),
                      subtitle: const Text('全库账户余额对账、借贷本金核验、引用与 JSON 检查及一键校准'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _navigateSibling(
                        context,
                        route: '/settings/data-health',
                        page: const DataHealthPage(),
                      ),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      key: const Key('nav_stat_stories_tile'),
                      leading: const Icon(Icons.auto_stories_outlined),
                      title: const Text('统计故事'),
                      subtitle: const Text('按账期自动汇总收支摘要并编辑留存'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _navigateSibling(
                        context,
                        route: '/stat-stories',
                        page: const StatStoriesPage(),
                      ),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      key: const Key('nav_about_help_tile'),
                      leading: const Icon(Icons.help_outline),
                      title: const Text('帮助与关于帐屿'),
                      subtitle: const Text('本地离线隐私承诺、全免费无门控说明与常见问题'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _navigateSibling(
                        context,
                        route: '/about',
                        page: const AboutHelpPage(),
                      ),
                    ),
                  ],
                ),
              ),
              if (isDesktop) ...[
                const SizedBox(height: 16),
                const _SectionHeader(title: '桌面键盘快捷键'),
                _DesktopShortcutsCard(
                  primaryMod: DesktopAdaptive.primaryModifierLabel(context),
                  altMod: DesktopAdaptive.altModifierLabel(context),
                ),
              ],
              const SizedBox(height: 20),
              Align(
                alignment: Alignment.center,
                child: OutlinedButton.icon(
                  key: const Key('setting_reset_defaults_button'),
                  onPressed: _busy ? null : _confirmResetDefaults,
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('恢复默认设置'),
                ),
              ),
            ],
          );

          if (isDesktop) {
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 800),
                child: listView,
              ),
            );
          }
          return listView;
        },
      ),
    );
  }
}

class _DesktopShortcutsCard extends StatelessWidget {
  const _DesktopShortcutsCard({required this.primaryMod, required this.altMod});

  final String primaryMod;
  final String altMod;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final monoFamily = switch (theme.platform) {
      TargetPlatform.macOS || TargetPlatform.iOS => 'Menlo',
      TargetPlatform.windows => 'Consolas',
      _ => 'DejaVu Sans Mono',
    };
    final items = <({String label, String keys})>[
      (label: '新建记一笔', keys: '$primaryMod + N'),
      (label: '搜索账单', keys: '$primaryMod + F / K'),
      (label: '切换四大主栏目', keys: '$primaryMod + 1 .. 4'),
      (label: '切换上一账期 / 下一账期', keys: '$altMod + ← / → 或 [ / ]'),
      (label: '回到当前账期', keys: 'T'),
      (label: '关闭弹窗 / 清空搜索返回', keys: 'Esc'),
      (label: '应用安全锁解锁', keys: '数字键 0–9 / Backspace'),
    ];

    return Card(
      key: const Key('desktop_shortcuts_card'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          children: [
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0) const Divider(height: 12, thickness: 0.5),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        items[i].label,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        items[i].keys,
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontFamily: monoFamily,
                          fontFamilyFallback: _shortcutMonoFallback,
                          color: scheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: Text(
        title,
        style: theme.textTheme.labelMedium?.copyWith(
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

class _CustomThemeHexDialog extends StatefulWidget {
  const _CustomThemeHexDialog({required this.initialHex});

  final String initialHex;

  @override
  State<_CustomThemeHexDialog> createState() => _CustomThemeHexDialogState();
}

class _CustomThemeHexDialogState extends State<_CustomThemeHexDialog> {
  late final TextEditingController _hexCtrl;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _hexCtrl = TextEditingController(text: widget.initialHex);
  }

  @override
  void dispose() {
    _hexCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    try {
      final normalized = normalizeThemeSeedHex(_hexCtrl.text);
      Navigator.of(context).pop(normalized);
    } on Failure catch (f) {
      setState(() => _errorText = f.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = DesktopAdaptive.isDesktop(context);
    final field = TextField(
      key: const Key('theme_custom_hex_input'),
      controller: _hexCtrl,
      maxLength: 7,
      decoration: InputDecoration(
        labelText: '6 位十六进制颜色码',
        hintText: '例如 138EAA 或 #2E7D32',
        errorText: _errorText,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 14,
        ),
      ),
      onSubmitted: (_) => _submit(),
    );
    return AlertDialog(
      title: const Text('自定义主题色'),
      content: SingleChildScrollView(
        child: isDesktop
            ? ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 320, maxWidth: 380),
                child: field,
              )
            : field,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('theme_custom_hex_confirm_button'),
          onPressed: _submit,
          child: const Text('应用'),
        ),
      ],
    );
  }
}
