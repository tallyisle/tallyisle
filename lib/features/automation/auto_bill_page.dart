import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/adaptive.dart';
import '../../app/providers.dart';
import '../../core/money.dart';
import '../../data/automation/auto_bill_service.dart' show AutoBillIngestKind;
import '../../data/db/database.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/auto_map_rules.dart';
import '../../domain/rules/smart_bill_nlp_rules.dart';
import '../../domain/rules/url_scheme_rules.dart' show parseUrlMoney;
import '../../platform/auto_bill_bridge.dart';
import '../common/common.dart';
import 'automation_providers.dart';

/// Auto-bookkeeping management page (`F-020`):
/// - Adaptive 3-OS status & guide card (Android dual-channel Notification + Accessibility,
///   iOS Shortcuts AppIntents 3-step guide, HarmonyOS system share & service card guide)
/// - Android prompt style selector (`notification` / `overlay` / `silent`),
///   familiar-merchant auto-confirm gate switch, and home pending-draft banner switch
/// - Pending draft inbox (`KEY_DRAFT`) with batch confirm & rule self-learning
/// - Keyword mapping rule CRUD (`auto_map`) with per-rule `allowAutoConfirm`
class AutoBillPage extends ConsumerStatefulWidget {
  const AutoBillPage({super.key, this.initialDraftId});

  /// Optional draft ID passed from an `edit_draft` notification action.
  final int? initialDraftId;

  @override
  ConsumerState<AutoBillPage> createState() => _AutoBillPageState();
}

class _AutoBillPageState extends ConsumerState<AutoBillPage> {
  final CommandIds _commandIds = CommandIds();
  int _nonce = 0;
  StreamSubscription<CapturedPaymentEvent>? _liveSub;
  bool _openedInitialDraft = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pullCapturedEvents();
      _subscribeLiveEvents();
    });
  }

  void _subscribeLiveEvents() {
    final bridge = ref.read(autoBillBridgeProvider);
    _liveSub = bridge.onCapturedEvent.listen((event) async {
      if (!mounted) return;
      try {
        final service = await ref.read(autoBillServiceProvider.future);
        await service.ingestCapturedEvent(event, index: _nonce++);
      } catch (_) {
        // Non-payment capture noise is safely ignored.
      }
    });
  }

  Future<void> _pullCapturedEvents() async {
    try {
      final service = await ref.read(autoBillServiceProvider.future);
      await service.consumeAndExecutePendingPromptActions();
      await service.ingestCapturedEvents();
      await service.syncNativeConfig();
      if (mounted) {
        ref
          ..invalidate(accessibilityStatusProvider)
          ..invalidate(notificationListenerStatusProvider)
          ..invalidate(overlayPermissionStatusProvider);
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    unawaited(_liveSub?.cancel());
    super.dispose();
  }

  Future<void> _openSystemAccessibilitySettings() async {
    try {
      final service = await ref.read(autoBillServiceProvider.future);
      final opened = await service.openAccessibilitySettings();
      if (!mounted) return;
      if (!opened) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('当前平台不支持打开系统无障碍设置')));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
    }
  }

  Future<void> _openSystemNotificationSettings() async {
    try {
      final service = await ref.read(autoBillServiceProvider.future);
      final opened = await service.openNotificationListenerSettings();
      if (!mounted) return;
      if (!opened) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('当前平台不支持打开系统通知使用权设置')));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
    }
  }

  Future<void> _openSystemOverlaySettings() async {
    try {
      final service = await ref.read(autoBillServiceProvider.future);
      final opened = await service.openOverlaySettings();
      if (!mounted) return;
      ref.invalidate(overlayPermissionStatusProvider);
      if (!opened) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('当前平台不支持打开系统悬浮窗设置')));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
    }
  }

  Future<void> _saveSettings(AutoBillSettings next) async {
    try {
      final service = await ref.read(autoBillServiceProvider.future);
      await service.saveSettings(
        commandId: _commandIds.forPayload([
          'save-auto-settings',
          _nonce++,
          next.encode(),
        ]),
        settings: next,
      );
      if (mounted && next.promptMode == AutoBillPromptMode.overlay) {
        ref.invalidate(overlayPermissionStatusProvider);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
    }
  }

  Future<void> _showIosShortcutsGuideDialog() async {
    await showDialog<void>(
      context: context,
      builder: (_) => const _IosShortcutsGuideDialog(),
    );
  }

  Future<void> _showPastePaymentDialog() async {
    final outcome = await showDialog<AutoBillIngestKind>(
      context: context,
      builder: (_) => const _PastePaymentTextDialog(),
    );
    if (outcome != null && mounted) {
      final text = outcome == AutoBillIngestKind.autoConfirmed
          ? '命中熟店规则，已直接入账'
          : '已识别文本并加入待确认草稿箱';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> _quickConfirmDraft(AutoBillDraft draft) async {
    if (draft.id == null) return;
    try {
      final service = await ref.read(autoBillServiceProvider.future);
      final commandId = _commandIds.forPayload([
        'quick-confirm',
        draft.id,
        _nonce++,
      ]);
      await service.confirmDraft(commandId: commandId, draftId: draft.id!);
      final widgetService = await ref.read(
        widgetSnapshotServiceProvider.future,
      );
      await widgetService.syncToPlatform();
      ref.invalidate(widgetSnapshotProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('草稿已确认入账')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
    }
  }

  Future<void> _confirmAllDrafts(List<AutoBillDraft> drafts) async {
    final ids = [
      for (final d in drafts)
        if (d.id != null) d.id!,
    ];
    if (ids.isEmpty) return;
    try {
      final service = await ref.read(autoBillServiceProvider.future);
      final created = await service.confirmDraftsBatch(
        commandId: _commandIds.forPayload([
          'confirm-all-drafts',
          ids,
          _nonce++,
        ]),
        draftIds: ids,
      );
      final widgetService = await ref.read(
        widgetSnapshotServiceProvider.future,
      );
      await widgetService.syncToPlatform();
      ref.invalidate(widgetSnapshotProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已批量确认入账 ${created.length} 笔账单')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
    }
  }

  Future<void> _openEditConfirmDialog(
    AutoBillDraft draft,
    List<RecordCategory> categories,
    List<Asset> assets,
  ) async {
    if (draft.id == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _ConfirmDraftDialog(
        draft: draft,
        categories: categories,
        assets: assets,
      ),
    );
    if (confirmed == true && mounted) {
      final widgetService = await ref.read(
        widgetSnapshotServiceProvider.future,
      );
      await widgetService.syncToPlatform();
      ref.invalidate(widgetSnapshotProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('草稿已确认入账')));
    }
  }

  Future<void> _deleteDraft(AutoBillDraft draft) async {
    if (draft.id == null) return;
    try {
      final service = await ref.read(autoBillServiceProvider.future);
      await service.deleteDraft(
        commandId: _commandIds.forPayload(['del-draft', draft.id, _nonce++]),
        draftId: draft.id!,
      );
      final widgetService = await ref.read(
        widgetSnapshotServiceProvider.future,
      );
      await widgetService.syncToPlatform();
      ref.invalidate(widgetSnapshotProvider);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
    }
  }

  Future<void> _clearAllDrafts() async {
    final ok = await confirm(
      context,
      title: '清空待确认草稿',
      message: '确定删除草稿箱中全部待确认记录吗？已配置的映射规则不会受影响。',
      ok: '清空',
    );
    if (!ok || !mounted) return;
    try {
      final service = await ref.read(autoBillServiceProvider.future);
      await service.clearDrafts(
        commandId: _commandIds.forPayload(['clear-drafts', _nonce++]),
      );
      final widgetService = await ref.read(
        widgetSnapshotServiceProvider.future,
      );
      await widgetService.syncToPlatform();
      ref.invalidate(widgetSnapshotProvider);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
    }
  }

  Future<void> _openRuleDialog({
    AutoMapRule? existing,
    required List<RecordCategory> categories,
    required List<Asset> assets,
    required int currentBookId,
  }) async {
    await showDialog<bool>(
      context: context,
      builder: (_) => _RuleEditorDialog(
        existing: existing,
        categories: categories,
        assets: assets,
        currentBookId: currentBookId,
      ),
    );
  }

  Future<void> _deleteRule(AutoMapRule rule) async {
    final ok = await confirm(
      context,
      title: '删除映射规则',
      message: '确定删除关键词“${rule.key}”的自动映射规则吗？',
      ok: '删除',
    );
    if (!ok || !mounted) return;
    try {
      final service = await ref.read(autoBillServiceProvider.future);
      await service.deleteRule(
        commandId: _commandIds.forPayload(['del-rule', rule.id, _nonce++]),
        id: rule.id,
      );
      unawaited(service.syncNativeConfig());
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
    }
  }

  void _syncNativePickListsBestEffort() {
    ref.read(autoBillServiceProvider.future).then((s) {
      unawaited(s.syncNativeConfig());
    }, onError: (_) {});
  }

  @override
  Widget build(BuildContext context) {
    final statusAsync = ref.watch(accessibilityStatusProvider);
    final notifStatusAsync = ref.watch(notificationListenerStatusProvider);
    final overlayStatusAsync = ref.watch(overlayPermissionStatusProvider);
    final settings =
        ref.watch(autoBillSettingsProvider).value ?? const AutoBillSettings();
    final draftsAsync = ref.watch(autoBillDraftsProvider);
    final rulesAsync = ref.watch(autoMapRulesProvider);
    final bookId = ref.watch(currentBookIdProvider).value ?? 1;
    final categories =
        ref.watch(categoriesProvider(bookId)).value ?? const <RecordCategory>[];
    final assets = ref.watch(assetsProvider).value ?? const <Asset>[];

    ref.listen<AsyncValue<List<RecordCategory>>>(categoriesProvider(bookId), (
      prev,
      next,
    ) {
      if (prev?.hasValue == true && next.hasValue) {
        _syncNativePickListsBestEffort();
      }
    });
    ref.listen<AsyncValue<List<Asset>>>(assetsProvider, (prev, next) {
      if (prev?.hasValue == true && next.hasValue) {
        _syncNativePickListsBestEffort();
      }
    });

    final fundingAssets = assets
        .where(
          (a) => a.type != AssetType.debt && a.status != AssetStatus.settled,
        )
        .toList(growable: false);

    if (!_openedInitialDraft &&
        widget.initialDraftId != null &&
        draftsAsync.hasValue) {
      final target = draftsAsync.value!
          .where((d) => d.id == widget.initialDraftId)
          .firstOrNull;
      if (target != null) {
        _openedInitialDraft = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            unawaited(
              _openEditConfirmDialog(target, categories, fundingAssets),
            );
          }
        });
      }
    }

    final isDesktop = DesktopAdaptive.isDesktop(context);
    final bridgeReason = ref.watch(autoBillBridgeProvider).capability.reason;
    final isOhos =
        DesktopAdaptive.isOhos(context) || bridgeReason.contains('HarmonyOS');
    final platform = Theme.of(context).platform;
    final accStatus =
        statusAsync.value ?? const AccessibilityBridgeStatus.unsupported();
    final notifStatus =
        notifStatusAsync.value ?? const AutoBillPermissionStatus.unsupported();
    final overlayStatus =
        overlayStatusAsync.value ??
        const AutoBillPermissionStatus.unsupported();

    final isIosMobile =
        !isDesktop &&
        !isOhos &&
        platform == TargetPlatform.iOS &&
        !accStatus.supported &&
        !notifStatus.supported;
    final isAndroidCaptureCapable =
        !isDesktop &&
        !isOhos &&
        !isIosMobile &&
        (accStatus.supported ||
            notifStatus.supported ||
            platform == TargetPlatform.android);
    final accessibilitySupported = !isDesktop && accStatus.supported;

    Widget buildTopPlatformHeader() {
      if (isDesktop) {
        return _DesktopAutoBillBanner(onPasteParse: _showPastePaymentDialog);
      }
      if (isIosMobile) {
        return _IosAutoBillCard(
          statusLabel: accStatus.statusLabel,
          onOpenGuide: _showIosShortcutsGuideDialog,
        );
      }
      if (isOhos) {
        return _OhosAutoBillCard(statusLabel: accStatus.statusLabel);
      }
      return _AndroidAutoBillStatusCard(
        accessibilityStatus: accStatus,
        notificationStatus: notifStatus,
        onOpenAccessibilitySettings: _openSystemAccessibilitySettings,
        onOpenNotificationSettings: _openSystemNotificationSettings,
      );
    }

    const tabBar = TabBar(
      tabs: [
        Tab(key: Key('auto_bill_tab_drafts'), text: '待确认草稿'),
        Tab(key: Key('auto_bill_tab_rules'), text: '映射规则'),
      ],
    );
    final bodyColumn = Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: buildTopPlatformHeader(),
        ),
        Expanded(
          child: TabBarView(
            children: [
              _DraftsTabView(
                draftsAsync: draftsAsync,
                accessibilitySupported: accessibilitySupported,
                showAndroidPromptSettings: isAndroidCaptureCapable,
                settings: settings,
                overlayStatus: overlayStatus,
                categories: categories,
                assets: fundingAssets,
                onSaveSettings: _saveSettings,
                onOpenOverlaySettings: _openSystemOverlaySettings,
                onPasteParse: _showPastePaymentDialog,
                onConfirmAll: _confirmAllDrafts,
                onClearAll: _clearAllDrafts,
                onQuickConfirm: _quickConfirmDraft,
                onEditConfirm: (d) =>
                    _openEditConfirmDialog(d, categories, fundingAssets),
                onDelete: _deleteDraft,
              ),
              _RulesTabView(
                rulesAsync: rulesAsync,
                categories: categories,
                assets: fundingAssets,
                onAddRule: () => _openRuleDialog(
                  categories: categories,
                  assets: fundingAssets,
                  currentBookId: bookId,
                ),
                onEditRule: (rule) => _openRuleDialog(
                  existing: rule,
                  categories: categories,
                  assets: fundingAssets,
                  currentBookId: bookId,
                ),
                onDeleteRule: _deleteRule,
              ),
            ],
          ),
        ),
      ],
    );

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        key: const Key('auto_bill_page'),
        appBar: AppBar(
          scrolledUnderElevation: isDesktop ? 0 : null,
          title: const Text('自动记账'),
          actions: [
            IconButton(
              tooltip: '智能识账面板',
              onPressed: () {
                final router = GoRouter.maybeOf(context);
                if (router != null) {
                  context.push('/automation/smart-bill');
                } else {
                  _showPastePaymentDialog();
                }
              },
              icon: const Icon(Icons.auto_awesome_outlined),
            ),
            IconButton(
              key: const Key('auto_bill_refresh_status_button'),
              tooltip: '刷新状态与草稿队列',
              onPressed: _pullCapturedEvents,
              icon: const Icon(Icons.refresh),
            ),
          ],
          bottom: isDesktop
              ? PreferredSize(
                  preferredSize: tabBar.preferredSize,
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 820),
                      child: tabBar,
                    ),
                  ),
                )
              : tabBar,
        ),
        body: isDesktop
            ? Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 820),
                  child: bodyColumn,
                ),
              )
            : bodyColumn,
      ),
    );
  }
}

class _DesktopAutoBillBanner extends StatelessWidget {
  const _DesktopAutoBillBanner({required this.onPasteParse});

  final VoidCallback onPasteParse;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      key: const Key('auto_bill_desktop_banner'),
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(Icons.paste_rounded, size: 22, color: scheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '支持直接粘贴口语、银行短信、微信/支付宝通知文本自动解析，也可审核手机端同步过来的待确认草稿。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.tonalIcon(
              key: const Key('auto_bill_desktop_paste_button'),
              onPressed: onPasteParse,
              icon: const Icon(Icons.content_paste_go_rounded, size: 17),
              label: const Text('粘贴识账'),
            ),
          ],
        ),
      ),
    );
  }
}

(Color, Color) _badgeColorsForLabel(ThemeData theme, String label) =>
    switch (label) {
      accessibilityEnabledLabel => (
        theme.colorScheme.primaryContainer,
        theme.colorScheme.onPrimaryContainer,
      ),
      accessibilityDisabledLabel => (
        theme.colorScheme.tertiaryContainer,
        theme.colorScheme.onTertiaryContainer,
      ),
      _ => (
        theme.colorScheme.surfaceContainerHighest,
        theme.colorScheme.onSurfaceVariant,
      ),
    };

class _AndroidAutoBillStatusCard extends StatelessWidget {
  const _AndroidAutoBillStatusCard({
    required this.accessibilityStatus,
    required this.notificationStatus,
    required this.onOpenAccessibilitySettings,
    required this.onOpenNotificationSettings,
  });

  final AccessibilityBridgeStatus accessibilityStatus;
  final AutoBillPermissionStatus notificationStatus;
  final VoidCallback onOpenAccessibilitySettings;
  final VoidCallback onOpenNotificationSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (accBg, accFg) = _badgeColorsForLabel(
      theme,
      accessibilityStatus.statusLabel,
    );
    final (notifBg, notifFg) = _badgeColorsForLabel(
      theme,
      notificationStatus.statusLabel,
    );

    return Card(
      key: const Key('auto_bill_status_card'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.notifications_active_outlined, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        '通知栏监听（推荐）',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Container(
                        key: const Key('auto_bill_notif_status_badge'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: notifBg,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          notificationStatus.statusLabel,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: notifFg,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (notificationStatus.supported)
                  TextButton(
                    key: const Key('auto_bill_open_notif_settings_button'),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    onPressed: onOpenNotificationSettings,
                    child: Text(notificationStatus.enabled ? '设置' : '去开启'),
                  ),
              ],
            ),
            const Divider(height: 12),
            Row(
              children: [
                const Icon(Icons.accessibility_new, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        '无障碍支付识别',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Container(
                        key: const Key('auto_bill_status_badge'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: accBg,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          accessibilityStatus.statusLabel,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: accFg,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (accessibilityStatus.supported)
                  TextButton(
                    key: const Key('auto_bill_open_settings_button'),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    onPressed: onOpenAccessibilitySettings,
                    child: Text(accessibilityStatus.enabled ? '设置' : '去开启'),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '双通道本机离线提取支付通知与结果页，15 秒内跨通道自动合并防重，零数据上传。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IosAutoBillCard extends StatelessWidget {
  const _IosAutoBillCard({
    required this.statusLabel,
    required this.onOpenGuide,
  });

  final String statusLabel;
  final VoidCallback onOpenGuide;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      key: const Key('auto_bill_ios_shortcuts_card'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(Icons.bolt_rounded, color: scheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        'iOS 快捷指令一键识账',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Container(
                        key: const Key('auto_bill_status_badge'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          statusLabel,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '轻点背面两下 / 操作按钮 / 收到银行短信自动运行，调用内置“帐屿”动作块一步识账（支持免费自签与巨魔）。',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              key: const Key('auto_bill_ios_guide_button'),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              onPressed: onOpenGuide,
              child: const Text('绑定向导'),
            ),
          ],
        ),
      ),
    );
  }
}

class _IosShortcutsGuideDialog extends StatelessWidget {
  const _IosShortcutsGuideDialog();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      key: const Key('auto_bill_ios_guide_dialog'),
      title: const Text('iOS 快捷指令 3 步绑定向导'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '1. 选择触发方式',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                '打开系统「设置 → 辅助功能 → 触控 → 轻点背面（轻点两下）」，或在苹果「快捷指令 → 自动化」中新建「操作按钮 / 收到银行短信自动运行」。',
              ),
              const SizedBox(height: 12),
              Text(
                '2. 搜索“帐屿”内置动作',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              const Text('在快捷指令动作库搜索“帐屿”，可配合「截屏 → 提取图中文字」将结果传入帐屿动作。'),
              const SizedBox(height: 12),
              Text(
                '3. 选择核对或静默入箱',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                '• 「智能识别账单（打开核对）」：直接拉起帐屿预填面板核对确认；\n'
                '• 「静默记入草稿箱」：后台直接写入待确认草稿（满足熟店规则可自动入账）。',
              ),
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('我知道了'),
        ),
      ],
    );
  }
}

class _OhosAutoBillCard extends StatelessWidget {
  const _OhosAutoBillCard({required this.statusLabel});

  final String statusLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      key: const Key('auto_bill_status_card'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.accessibility_new, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        '后台屏幕抓取',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Container(
                        key: const Key('auto_bill_status_badge'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          statusLabel,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              key: const Key('auto_bill_ohos_guide_strip'),
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: scheme.secondaryContainer.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                'HarmonyOS 快捷识账指引：指关节截屏 → 左下角分享给帐屿一步离线识账 · 长按桌面图标快捷菜单或添加桌面万能卡片。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSecondaryContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AutoBillStrategySettingsCard extends StatelessWidget {
  const _AutoBillStrategySettingsCard({
    required this.showAndroidPromptSettings,
    required this.settings,
    required this.overlayStatus,
    required this.onSaveSettings,
    required this.onOpenOverlaySettings,
  });

  final bool showAndroidPromptSettings;
  final AutoBillSettings settings;
  final AutoBillPermissionStatus overlayStatus;
  final ValueChanged<AutoBillSettings> onSaveSettings;
  final VoidCallback onOpenOverlaySettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final showOverlayWarning =
        showAndroidPromptSettings &&
        settings.promptMode == AutoBillPromptMode.overlay &&
        !overlayStatus.enabled;

    return Card(
      key: const Key('auto_bill_settings_card'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '自动记账策略设置',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            if (showAndroidPromptSettings) ...[
              const SizedBox(height: 8),
              Text(
                '捕获后即时提醒方式',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 6),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<AutoBillPromptMode>(
                  key: const Key('auto_bill_prompt_mode_segment'),
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: AutoBillPromptMode.notification,
                      label: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text('顶部通知', maxLines: 1, softWrap: false),
                      ),
                    ),
                    ButtonSegment(
                      value: AutoBillPromptMode.overlay,
                      label: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text('底部悬浮窗', maxLines: 1, softWrap: false),
                      ),
                    ),
                    ButtonSegment(
                      value: AutoBillPromptMode.silent,
                      label: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text('静默收集', maxLines: 1, softWrap: false),
                      ),
                    ),
                  ],
                  selected: {settings.promptMode},
                  onSelectionChanged: (s) =>
                      onSaveSettings(settings.copyWith(promptMode: s.first)),
                ),
              ),
              if (showOverlayWarning) ...[
                const SizedBox(height: 8),
                Container(
                  key: const Key('auto_bill_overlay_warning'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.tertiaryContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.info_outline,
                        size: 16,
                        color: scheme.onTertiaryContainer,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '尚未开启悬浮窗权限，当前自动回退为顶部通知',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onTertiaryContainer,
                          ),
                        ),
                      ),
                      TextButton(
                        key: const Key(
                          'auto_bill_open_overlay_settings_button',
                        ),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                        onPressed: onOpenOverlaySettings,
                        child: const Text('授权悬浮窗'),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 4),
            ],
            SwitchListTile(
              key: const Key('auto_bill_auto_confirm_switch'),
              contentPadding: EdgeInsets.zero,
              title: const Text('熟店规则自动直接入账'),
              subtitle: const Text('分类 + 账户双齐全且规则允许时免确认入账，通知支持一键撤销'),
              value: settings.autoConfirmMatchedRules,
              onChanged: (v) =>
                  onSaveSettings(settings.copyWith(autoConfirmMatchedRules: v)),
            ),
            SwitchListTile(
              key: const Key('auto_bill_home_banner_switch'),
              contentPadding: EdgeInsets.zero,
              title: const Text('首页显示待确认提醒横条'),
              subtitle: const Text('有待核对账单草稿时在明细列表顶部展示快捷入口'),
              value: settings.showHomeDraftBanner,
              onChanged: (v) =>
                  onSaveSettings(settings.copyWith(showHomeDraftBanner: v)),
            ),
          ],
        ),
      ),
    );
  }
}

class _DraftsTabView extends StatelessWidget {
  const _DraftsTabView({
    required this.draftsAsync,
    required this.accessibilitySupported,
    required this.showAndroidPromptSettings,
    required this.settings,
    required this.overlayStatus,
    required this.categories,
    required this.assets,
    required this.onSaveSettings,
    required this.onOpenOverlaySettings,
    required this.onPasteParse,
    required this.onConfirmAll,
    required this.onClearAll,
    required this.onQuickConfirm,
    required this.onEditConfirm,
    required this.onDelete,
  });

  final AsyncValue<List<AutoBillDraft>> draftsAsync;
  final bool accessibilitySupported;
  final bool showAndroidPromptSettings;
  final AutoBillSettings settings;
  final AutoBillPermissionStatus overlayStatus;
  final List<RecordCategory> categories;
  final List<Asset> assets;
  final ValueChanged<AutoBillSettings> onSaveSettings;
  final VoidCallback onOpenOverlaySettings;
  final VoidCallback onPasteParse;
  final ValueChanged<List<AutoBillDraft>> onConfirmAll;
  final VoidCallback onClearAll;
  final ValueChanged<AutoBillDraft> onQuickConfirm;
  final ValueChanged<AutoBillDraft> onEditConfirm;
  final ValueChanged<AutoBillDraft> onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return asyncBody(draftsAsync, (drafts) {
      final catMap = {for (final c in categories) c.id: c.name};
      final assetMap = {for (final a in assets) a.id: a.name};

      final isDesktop = DesktopAdaptive.isDesktop(context);
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _AutoBillStrategySettingsCard(
            showAndroidPromptSettings: showAndroidPromptSettings,
            settings: settings,
            overlayStatus: overlayStatus,
            onSaveSettings: onSaveSettings,
            onOpenOverlaySettings: onOpenOverlaySettings,
          ),
          const SizedBox(height: 12),
          if (!isDesktop)
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: const Key('auto_bill_paste_parse_button'),
                onPressed: onPasteParse,
                icon: const Icon(Icons.content_paste_go, size: 18),
                label: const FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text('粘贴支付或口语文本识别', maxLines: 1, softWrap: false),
                ),
              ),
            ),
          if (drafts.isNotEmpty) ...[
            if (!isDesktop) const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 6,
              children: [
                Text(
                  '待处理（${drafts.length}）',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FilledButton.tonal(
                      key: const Key('auto_bill_confirm_all_drafts_button'),
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                      ),
                      onPressed: () => onConfirmAll(drafts),
                      child: const FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text('批量确认全部', maxLines: 1, softWrap: false),
                      ),
                    ),
                    const SizedBox(width: 4),
                    TextButton(
                      key: const Key('auto_bill_clear_drafts_button'),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      onPressed: onClearAll,
                      child: const Text('清空草稿'),
                    ),
                  ],
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          if (drafts.isEmpty)
            Padding(
              key: const Key('auto_bill_drafts_empty'),
              padding: const EdgeInsets.symmetric(vertical: 36),
              child: Center(
                child: Text(
                  accessibilitySupported
                      ? '暂无待确认草稿\n开启通知监听/无障碍识别或粘贴微信/支付宝/银行短信即可生成草稿'
                      : '暂无待确认草稿\n粘贴微信/支付宝通知、银行短信或口语短句即可生成草稿',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ),
            )
          else
            for (final draft in drafts) ...[
              Card(
                key: Key('auto_bill_draft_${draft.id}'),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Chip(
                                  label: Text(draft.displayApp),
                                  visualDensity: VisualDensity.compact,
                                ),
                                Text(
                                  RecordType.names[draft.recordType] ?? '支出',
                                  style: theme.textTheme.labelMedium,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '¥${draft.money.decimal}',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      if (draft.primaryRemark.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          draft.primaryRemark,
                          style: theme.textTheme.bodyMedium,
                        ),
                      ],
                      const SizedBox(height: 4),
                      Text(
                        [
                          formatDateTime(
                            DateTime.fromMillisecondsSinceEpoch(
                              draft.recordTimeMs,
                            ),
                          ),
                          if (draft.categoryId != null &&
                              catMap[draft.categoryId] != null)
                            '分类：${catMap[draft.categoryId]}'
                          else if (draft.categoryHint != null)
                            '识别分类：${draft.categoryHint}',
                          if (draft.assetId != null &&
                              assetMap[draft.assetId] != null)
                            '账户：${assetMap[draft.assetId]}'
                          else if (draft.accountHint1 != null)
                            '识别账户：${draft.accountHint1}',
                        ].join(' · '),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: Wrap(
                          alignment: WrapAlignment.end,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 4,
                          runSpacing: 4,
                          children: [
                            TextButton(
                              key: Key('auto_bill_delete_draft_${draft.id}'),
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                              ),
                              onPressed: () => onDelete(draft),
                              child: const Text('忽略'),
                            ),
                            TextButton(
                              key: Key('auto_bill_edit_confirm_${draft.id}'),
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                              ),
                              onPressed: () => onEditConfirm(draft),
                              child: const Text('编辑入账'),
                            ),
                            FilledButton.tonal(
                              key: Key('auto_bill_quick_confirm_${draft.id}'),
                              style: FilledButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                ),
                              ),
                              onPressed: () => onQuickConfirm(draft),
                              child: const Text('确认入账'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
        ],
      );
    });
  }
}

class _RulesTabView extends StatelessWidget {
  const _RulesTabView({
    required this.rulesAsync,
    required this.categories,
    required this.assets,
    required this.onAddRule,
    required this.onEditRule,
    required this.onDeleteRule,
  });

  final AsyncValue<List<AutoMapRule>> rulesAsync;
  final List<RecordCategory> categories;
  final List<Asset> assets;
  final VoidCallback onAddRule;
  final ValueChanged<AutoMapRule> onEditRule;
  final ValueChanged<AutoMapRule> onDeleteRule;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return asyncBody(rulesAsync, (rules) {
      final catMap = {for (final c in categories) c.id: c.name};
      final assetMap = {for (final a in assets) a.id: a.name};

      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const Key('auto_bill_add_rule_button'),
              onPressed: onAddRule,
              icon: const Icon(Icons.add, size: 18),
              label: const FittedBox(
                fit: BoxFit.scaleDown,
                child: Text('新增映射规则', maxLines: 1, softWrap: false),
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (rules.isEmpty)
            Padding(
              key: const Key('auto_bill_rules_empty'),
              padding: const EdgeInsets.symmetric(vertical: 48),
              child: Center(
                child: Text(
                  '暂无自动映射规则\n添加商户或卡号关键词后，识别草稿将自动匹配账户与分类',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.outline,
                  ),
                ),
              ),
            )
          else
            for (final rule in rules) ...[
              Builder(
                builder: (context) {
                  final hasBothTargets =
                      rule.info.mapCategoryId != null &&
                      rule.info.mapAssetId != null;
                  final autoReady =
                      rule.info.allowAutoConfirm && hasBothTargets;
                  final badgeLabel = !rule.info.allowAutoConfirm
                      ? '仅预填草稿（已禁自动入账）'
                      : (hasBothTargets ? '具备熟店自动入账资格' : '仅预填草稿（需补齐分类+账户）');
                  final badgeBg = autoReady
                      ? scheme.primaryContainer
                      : scheme.surfaceContainerHighest;
                  final badgeFg = autoReady
                      ? scheme.onPrimaryContainer
                      : scheme.onSurfaceVariant;

                  return Card(
                    key: Key('auto_bill_rule_${rule.id}'),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 4,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    Text(
                                      rule.key,
                                      style: theme.textTheme.titleSmall
                                          ?.copyWith(
                                            fontWeight: FontWeight.bold,
                                          ),
                                    ),
                                    Container(
                                      key: Key(
                                        'auto_bill_rule_auto_badge_${rule.id}',
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: badgeBg,
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Text(
                                        badgeLabel,
                                        style: theme.textTheme.labelSmall
                                            ?.copyWith(
                                              color: badgeFg,
                                              fontWeight: FontWeight.w600,
                                            ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  [
                                    if (rule.info.recordType != null)
                                      '类型：${RecordType.names[rule.info.recordType] ?? '支出'}',
                                    if (rule.info.mapCategoryId != null)
                                      '分类：${catMap[rule.info.mapCategoryId] ?? '#${rule.info.mapCategoryId}'}',
                                    if (rule.info.mapAssetId != null)
                                      '账户：${assetMap[rule.info.mapAssetId] ?? '#${rule.info.mapAssetId}'}',
                                    if (rule.info.remark != null)
                                      '备注：${rule.info.remark}',
                                  ].join(' · '),
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                key: Key('auto_bill_edit_rule_${rule.id}'),
                                visualDensity: VisualDensity.compact,
                                tooltip: '编辑规则',
                                onPressed: () => onEditRule(rule),
                                icon: const Icon(Icons.edit_outlined),
                              ),
                              IconButton(
                                key: Key('auto_bill_delete_rule_${rule.id}'),
                                visualDensity: VisualDensity.compact,
                                tooltip: '删除规则',
                                onPressed: () => onDeleteRule(rule),
                                icon: const Icon(Icons.delete_outline),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 8),
            ],
        ],
      );
    });
  }
}

class _PastePaymentTextDialog extends ConsumerStatefulWidget {
  const _PastePaymentTextDialog();

  @override
  ConsumerState<_PastePaymentTextDialog> createState() =>
      _PastePaymentTextDialogState();
}

class _PastePaymentTextDialogState
    extends ConsumerState<_PastePaymentTextDialog> {
  final TextEditingController _textController = TextEditingController();
  final CommandIds _commandIds = CommandIds();
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<void> _fillFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      setState(() => _error = '剪贴板中暂无文本内容');
      return;
    }
    setState(() {
      _textController.text = text;
      _error = null;
    });
  }

  Future<void> _submit() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final service = await ref.read(autoBillServiceProvider.future);
      final text = _textController.text;
      final outcome = await service.ingestPaymentTextWithOutcome(
        commandId: _commandIds.forPayload(['paste-ingest', text]),
        rawText: text,
        dispatchPrompt: false,
      );
      if (!mounted) return;
      Navigator.pop(context, outcome.kind);
    } catch (e) {
      if (mounted) setState(() => _error = safeMessage(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Row(
      children: [
        const Expanded(child: Text('粘贴支付或口语文本识别')),
        TextButton.icon(
          style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
          onPressed: _saving ? null : _fillFromClipboard,
          icon: const Icon(Icons.content_paste_rounded, size: 16),
          label: const Text('读取剪贴板'),
        ),
      ],
    ),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const Key('auto_bill_paste_input'),
              controller: _textController,
              maxLines: 5,
              decoration: const InputDecoration(
                hintText:
                    '例如：【招商银行】您账户8888于11月11日12:30消费人民币36.50元，商户：瑞幸咖啡\n或：早饭买煎饼微信花了9块5',
                border: OutlineInputBorder(),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const Key('auto_bill_paste_submit'),
        onPressed: _saving ? null : _submit,
        child: const Text('解析并加入草稿'),
      ),
    ],
  );
}

class _ConfirmDraftDialog extends ConsumerStatefulWidget {
  const _ConfirmDraftDialog({
    required this.draft,
    required this.categories,
    required this.assets,
  });

  final AutoBillDraft draft;
  final List<RecordCategory> categories;
  final List<Asset> assets;

  @override
  ConsumerState<_ConfirmDraftDialog> createState() =>
      _ConfirmDraftDialogState();
}

class _ConfirmDraftDialogState extends ConsumerState<_ConfirmDraftDialog> {
  late final TextEditingController _amountController;
  late final TextEditingController _remarkController;
  late final TextEditingController _ruleKeywordController;
  final CommandIds _commandIds = CommandIds();

  late int _recordType;
  int? _categoryId;
  int? _assetId;
  int? _toAssetId;
  late bool _learnRule;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _recordType = widget.draft.recordType;
    _categoryId = widget.draft.categoryId;
    _assetId = widget.draft.assetId;
    _toAssetId = widget.draft.toAssetId;
    final initialRemark = widget.draft.primaryRemark.trim();
    _amountController = TextEditingController(text: widget.draft.money.decimal);
    _remarkController = TextEditingController(text: initialRemark);
    _ruleKeywordController = TextEditingController(text: initialRemark);
    _learnRule = initialRemark.isNotEmpty && isAutoMapRuleKey(initialRemark);
  }

  @override
  void dispose() {
    _amountController.dispose();
    _remarkController.dispose();
    _ruleKeywordController.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final Money money = parseUrlMoney(
        _amountController.text,
        fieldLabel: '入账金额',
      );
      final service = await ref.read(autoBillServiceProvider.future);
      final keyword = _ruleKeywordController.text.trim();
      final payload = [
        'confirm-dialog',
        widget.draft.id,
        _recordType,
        money.toJson(),
        _categoryId,
        _assetId,
        _toAssetId,
        _remarkController.text.trim(),
        _learnRule,
        keyword,
      ];
      await service.confirmDraft(
        commandId: _commandIds.forPayload(payload),
        draftId: widget.draft.id!,
        recordType: _recordType,
        money: money,
        categoryId: _categoryId,
        assetId: _assetId ?? noRef,
        toAssetId: _toAssetId,
        remark: _remarkController.text.trim(),
        learnRule: _learnRule,
        ruleKeyword: keyword.isEmpty ? null : keyword,
      );
      if (_learnRule) {
        unawaited(service.syncNativeConfig());
      }
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = safeMessage(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final wantCatType = _recordType == RecordType.income
        ? RecordType.income
        : RecordType.expense;
    final dirCategories = widget.categories
        .where((c) => !c.isHide && c.type == wantCatType)
        .toList(growable: false);
    final validCatId = dirCategories.any((c) => c.id == _categoryId)
        ? _categoryId
        : dirCategories.firstOrNull?.id;
    final validAssetId = widget.assets.any((a) => a.id == _assetId)
        ? _assetId
        : null;
    final validToAssetId = widget.assets.any((a) => a.id == _toAssetId)
        ? _toAssetId
        : null;
    final keywordPreview = _ruleKeywordController.text.trim();

    return AlertDialog(
      title: const Text('核对并确认入账'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<int>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    padding: WidgetStatePropertyAll(
                      EdgeInsets.symmetric(horizontal: 8),
                    ),
                  ),
                  segments: const [
                    ButtonSegment(
                      value: RecordType.expense,
                      label: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text('支出', maxLines: 1, softWrap: false),
                      ),
                    ),
                    ButtonSegment(
                      value: RecordType.income,
                      label: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text('收入', maxLines: 1, softWrap: false),
                      ),
                    ),
                    ButtonSegment(
                      value: RecordType.transfer,
                      label: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text('转账', maxLines: 1, softWrap: false),
                      ),
                    ),
                  ],
                  selected: {_recordType},
                  onSelectionChanged: (s) =>
                      setState(() => _recordType = s.first),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('confirm_draft_amount_input'),
                controller: _amountController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: '金额（元）',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_recordType != RecordType.transfer) ...[
                const SizedBox(height: 12),
                InputDecorator(
                  decoration: const InputDecoration(
                    labelText: '分类',
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 14,
                    ),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<int>(
                      isExpanded: true,
                      isDense: true,
                      style: Theme.of(context).textTheme.bodyLarge,
                      value: validCatId,
                      items: [
                        for (final c in dirCategories)
                          DropdownMenuItem(value: c.id, child: Text(c.name)),
                      ],
                      onChanged: (v) => setState(() => _categoryId = v),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              InputDecorator(
                decoration: InputDecoration(
                  labelText: _recordType == RecordType.transfer
                      ? '转出账户'
                      : '资金账户',
                  border: const OutlineInputBorder(),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 14,
                  ),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<int?>(
                    isExpanded: true,
                    isDense: true,
                    style: Theme.of(context).textTheme.bodyLarge,
                    value: validAssetId,
                    items: [
                      if (_recordType != RecordType.transfer)
                        const DropdownMenuItem<int?>(
                          value: null,
                          child: Text('不选择账户'),
                        ),
                      for (final a in widget.assets)
                        DropdownMenuItem<int?>(
                          value: a.id,
                          child: Text(a.name),
                        ),
                    ],
                    onChanged: (v) => setState(() => _assetId = v),
                  ),
                ),
              ),
              if (_recordType == RecordType.transfer) ...[
                const SizedBox(height: 12),
                InputDecorator(
                  decoration: const InputDecoration(
                    labelText: '转入账户',
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 14,
                    ),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<int?>(
                      isExpanded: true,
                      isDense: true,
                      style: Theme.of(context).textTheme.bodyLarge,
                      value: validToAssetId,
                      items: [
                        for (final a in widget.assets)
                          DropdownMenuItem<int?>(
                            value: a.id,
                            child: Text(a.name),
                          ),
                      ],
                      onChanged: (v) => setState(() => _toAssetId = v),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                key: const Key('confirm_draft_remark_input'),
                controller: _remarkController,
                decoration: const InputDecoration(
                  labelText: '备注',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                key: const Key('confirm_draft_learn_rule_checkbox'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _learnRule,
                onChanged: (v) => setState(() => _learnRule = v ?? false),
                title: Text(
                  keywordPreview.isNotEmpty
                      ? '记住「$keywordPreview」下次自动匹配'
                      : '同时记住为关键词映射规则',
                ),
              ),
              if (_learnRule) ...[
                const SizedBox(height: 6),
                TextField(
                  key: const Key('confirm_draft_rule_keyword_input'),
                  controller: _ruleKeywordController,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: '匹配关键词',
                    hintText: '例如：瑞幸咖啡',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('confirm_draft_submit_button'),
          onPressed: _saving ? null : _confirm,
          child: const Text('确认入账'),
        ),
      ],
    );
  }
}

class _RuleEditorDialog extends ConsumerStatefulWidget {
  const _RuleEditorDialog({
    this.existing,
    required this.categories,
    required this.assets,
    required this.currentBookId,
  });

  final AutoMapRule? existing;
  final List<RecordCategory> categories;
  final List<Asset> assets;
  final int currentBookId;

  @override
  ConsumerState<_RuleEditorDialog> createState() => _RuleEditorDialogState();
}

class _RuleEditorDialogState extends ConsumerState<_RuleEditorDialog> {
  late final TextEditingController _keyController;
  late final TextEditingController _remarkController;
  final CommandIds _commandIds = CommandIds();

  int? _recordType;
  int? _categoryId;
  int? _assetId;
  bool _allowAutoConfirm = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _keyController = TextEditingController(text: existing?.key ?? '');
    _remarkController = TextEditingController(
      text: existing?.info.remark ?? '',
    );
    _recordType = existing?.info.recordType ?? RecordType.expense;
    _categoryId = existing?.info.mapCategoryId;
    _assetId = existing?.info.mapAssetId;
    _allowAutoConfirm = existing?.info.allowAutoConfirm ?? true;
  }

  @override
  void dispose() {
    _keyController.dispose();
    _remarkController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final info = AutoMapInfo(
        raw: widget.existing?.info.raw,
        recordType: _recordType,
        mapCategoryId: _categoryId,
        mapAssetId: _assetId,
        bookId: widget.currentBookId,
        allowAutoConfirm: _allowAutoConfirm,
        remark: _remarkController.text.trim().isEmpty
            ? null
            : _remarkController.text.trim(),
      );
      final service = await ref.read(autoBillServiceProvider.future);
      final keyText = _keyController.text;
      await service.saveRule(
        commandId: _commandIds.forPayload([
          'save-rule',
          widget.existing?.id,
          keyText,
          info.encode(),
        ]),
        id: widget.existing?.id,
        key: keyText,
        info: info,
      );
      unawaited(service.syncNativeConfig());
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = safeMessage(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final wantCatType = _recordType == RecordType.income
        ? RecordType.income
        : RecordType.expense;
    final visibleCats = widget.categories
        .where((c) => !c.isHide && c.type == wantCatType)
        .toList(growable: false);
    final validCatId = visibleCats.any((c) => c.id == _categoryId)
        ? _categoryId
        : null;
    final validAssetId = widget.assets.any((a) => a.id == _assetId)
        ? _assetId
        : null;

    return AlertDialog(
      key: const Key('auto_bill_rule_dialog'),
      title: Text(widget.existing == null ? '新增映射规则' : '编辑映射规则'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const Key('auto_bill_rule_key_input'),
                controller: _keyController,
                decoration: const InputDecoration(
                  labelText: '匹配关键词（商户名 / 卡号后四位 / 渠道）',
                  hintText: '例如：瑞幸咖啡 或 8888',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<int>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    padding: WidgetStatePropertyAll(
                      EdgeInsets.symmetric(horizontal: 8),
                    ),
                  ),
                  segments: const [
                    ButtonSegment(
                      value: RecordType.expense,
                      label: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text('支出', maxLines: 1, softWrap: false),
                      ),
                    ),
                    ButtonSegment(
                      value: RecordType.income,
                      label: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text('收入', maxLines: 1, softWrap: false),
                      ),
                    ),
                  ],
                  selected: {_recordType ?? RecordType.expense},
                  onSelectionChanged: (s) =>
                      setState(() => _recordType = s.first),
                ),
              ),
              const SizedBox(height: 12),
              InputDecorator(
                decoration: const InputDecoration(
                  labelText: '映射分类',
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 14,
                  ),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<int?>(
                    key: const Key('auto_bill_rule_category_dropdown'),
                    isExpanded: true,
                    isDense: true,
                    style: Theme.of(context).textTheme.bodyLarge,
                    value: validCatId,
                    items: [
                      const DropdownMenuItem<int?>(
                        value: null,
                        child: Text('不指定分类'),
                      ),
                      for (final c in visibleCats)
                        DropdownMenuItem<int?>(
                          value: c.id,
                          child: Text(c.name),
                        ),
                    ],
                    onChanged: (v) => setState(() => _categoryId = v),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              InputDecorator(
                decoration: const InputDecoration(
                  labelText: '映射资金账户',
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 14,
                  ),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<int?>(
                    key: const Key('auto_bill_rule_asset_dropdown'),
                    isExpanded: true,
                    isDense: true,
                    style: Theme.of(context).textTheme.bodyLarge,
                    value: validAssetId,
                    items: [
                      const DropdownMenuItem<int?>(
                        value: null,
                        child: Text('不指定账户'),
                      ),
                      for (final a in widget.assets)
                        DropdownMenuItem<int?>(
                          value: a.id,
                          child: Text(a.name),
                        ),
                    ],
                    onChanged: (v) => setState(() => _assetId = v),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('auto_bill_rule_remark_input'),
                controller: _remarkController,
                decoration: const InputDecoration(
                  labelText: '默认备注（可选）',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 6),
              SwitchListTile(
                key: const Key('auto_rule_allow_auto_confirm_switch'),
                contentPadding: EdgeInsets.zero,
                title: const Text('允许熟店自动入账'),
                subtitle: const Text('开启全局自动入账且同时指定分类与账户时直接入账'),
                value: _allowAutoConfirm,
                onChanged: (v) => setState(() => _allowAutoConfirm = v),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('auto_bill_rule_save_button'),
          onPressed: _saving ? null : _save,
          child: const Text('保存规则'),
        ),
      ],
    );
  }
}
