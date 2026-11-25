import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/adaptive.dart';
import '../../platform/app_widgets.dart';
import '../../platform/files.dart';
import '../common/common.dart';
import 'automation_providers.dart';

/// Live previews, snapshot refresh, and pin/add guide for Android AppWidgets
/// and HarmonyOS NEXT Form Kit service cards (`F-034`).
class DesktopWidgetsPage extends ConsumerStatefulWidget {
  const DesktopWidgetsPage({super.key});

  @override
  ConsumerState<DesktopWidgetsPage> createState() => _DesktopWidgetsPageState();
}

class _DesktopWidgetsPageState extends ConsumerState<DesktopWidgetsPage> {
  bool _syncing = false;

  Future<void> _syncSnapshot() async {
    setState(() => _syncing = true);
    try {
      final bridge = ref.read(appWidgetBridgeProvider);
      final isOhos =
          DesktopAdaptive.isOhos(context) ||
          bridge.capability.reason.contains('HarmonyOS');
      final isSupported = bridge.capability.state == CapabilityState.available;
      final service = await ref.read(widgetSnapshotServiceProvider.future);
      await service.syncToPlatform();
      ref.invalidate(widgetSnapshotProvider);
      ref.invalidate(activeWidgetCountsProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isSupported
                ? (isOhos ? '已同步最新账本数据到桌面服务卡片' : '已同步最新账本数据到桌面小组件')
                : '已刷新小组件实时预览数据',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _pinWidget(DesktopWidgetKind kind) async {
    final isOhos =
        DesktopAdaptive.isOhos(context) ||
        ref
            .read(appWidgetBridgeProvider)
            .capability
            .reason
            .contains('HarmonyOS');
    try {
      final service = await ref.read(widgetSnapshotServiceProvider.future);
      final pinned = await service.requestPinWidget(kind);
      ref.invalidate(activeWidgetCountsProvider);
      if (!mounted) return;
      if (pinned) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已发起“${kind.title}”添加请求，请在系统弹窗中确认')),
        );
      } else if (isOhos) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请返回桌面双指捏合或长按“帐屿”图标 → 服务卡片，手动添加万能卡片')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('当前桌面环境不支持直接固定，请长按手机桌面空白处手动添加“帐屿”小组件')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final snapshotAsync = ref.watch(widgetSnapshotProvider);
    final countsAsync = ref.watch(activeWidgetCountsProvider);
    final bridge = ref.watch(appWidgetBridgeProvider);
    final capability = bridge.capability;
    final theme = Theme.of(context);
    final isOhos =
        DesktopAdaptive.isOhos(context) ||
        capability.reason.contains('HarmonyOS');

    return Scaffold(
      key: const Key('desktop_widgets_page'),
      appBar: AppBar(
        title: const Text('桌面小组件'),
        actions: [
          IconButton(
            key: const Key('widget_sync_button'),
            tooltip: '刷新组件数据',
            onPressed: _syncing ? null : _syncSnapshot,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: asyncBody(snapshotAsync, (snapshot) {
        final counts = countsAsync.value ?? const <DesktopWidgetKind, int>{};
        final isWidgetSupported = capability.state == CapabilityState.available;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (!isWidgetSupported)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Container(
                  key: const Key('widget_capability_banner'),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline),
                      const SizedBox(width: 10),
                      Expanded(child: Text(capability.reason)),
                    ],
                  ),
                ),
              ),
            _WidgetPreviewSection(
              kind: DesktopWidgetKind.quickAdd,
              activeCount: counts[DesktopWidgetKind.quickAdd] ?? 0,
              description: '1×1 极简图标入口，点击直接拉起“记一笔”页面。',
              onPin: isWidgetSupported
                  ? () => _pinWidget(DesktopWidgetKind.quickAdd)
                  : null,
              preview: const _QuickAddPreviewCard(),
            ),
            const SizedBox(height: 16),
            _WidgetPreviewSection(
              kind: DesktopWidgetKind.monthSummary,
              activeCount: counts[DesktopWidgetKind.monthSummary] ?? 0,
              description: '2×2 卡片实时展示当前账本本期支出、收入与预算剩余（或结余）。',
              onPin: isWidgetSupported
                  ? () => _pinWidget(DesktopWidgetKind.monthSummary)
                  : null,
              preview: _MonthSummaryPreviewCard(snapshot: snapshot),
            ),
            const SizedBox(height: 16),
            _WidgetPreviewSection(
              kind: DesktopWidgetKind.monthBar,
              activeCount: counts[DesktopWidgetKind.monthBar] ?? 0,
              description: '4×1 紧凑横条同时展示本期支出、本期收入、今日支出与快捷记账按钮。',
              onPin: isWidgetSupported
                  ? () => _pinWidget(DesktopWidgetKind.monthBar)
                  : null,
              preview: _MonthBarPreviewCard(snapshot: snapshot),
            ),
            const SizedBox(height: 16),
            _WidgetPreviewSection(
              kind: DesktopWidgetKind.smartQuick,
              activeCount: counts[DesktopWidgetKind.smartQuick] ?? 0,
              description: '4×1 / 2×2 智能速记卡：实时显示当前账本与待确认角标，一键直达记一笔、口语粘贴与选图识账。',
              onPin: isWidgetSupported
                  ? () => _pinWidget(DesktopWidgetKind.smartQuick)
                  : null,
              preview: _SmartQuickPreviewCard(snapshot: snapshot),
            ),
            if (isWidgetSupported) ...[
              const SizedBox(height: 20),
              if (isOhos)
                Card(
                  key: const Key('widget_ohos_guide_card'),
                  margin: EdgeInsets.zero,
                  elevation: 0,
                  surfaceTintColor: Colors.transparent,
                  clipBehavior: Clip.antiAlias,
                  color: _tonalCardColor(theme),
                  shape: _tonalCardShape,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'HarmonyOS 服务卡片添加指引',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          '双指捏合桌面或长按帐屿图标 → 服务卡片，即可添加 4 款原生万能卡片（快捷记账、月度收支概览、月度横条、智能速记）。',
                        ),
                      ],
                    ),
                  ),
                )
              else
                Card(
                  key: const Key('widget_add_guide_card'),
                  margin: EdgeInsets.zero,
                  elevation: 0,
                  surfaceTintColor: Colors.transparent,
                  clipBehavior: Clip.antiAlias,
                  color: _tonalCardColor(theme),
                  shape: _tonalCardShape,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '手动添加小组件指引',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text('1. 返回手机系统桌面，长按空白区域进入桌面编辑模式。'),
                        const SizedBox(height: 4),
                        const Text('2. 点击“小组件 / Widgets”，在列表中找到“帐屿”。'),
                        const SizedBox(height: 4),
                        const Text('3. 选择 1×1、2×2 或 4×1 尺寸并拖拽至桌面即可实时联动。'),
                      ],
                    ),
                  ),
                ),
            ],
          ],
        );
      }),
    );
  }
}

class _WidgetPreviewSection extends StatelessWidget {
  const _WidgetPreviewSection({
    required this.kind,
    required this.activeCount,
    required this.description,
    required this.preview,
    required this.onPin,
  });

  final DesktopWidgetKind kind;
  final int activeCount;
  final String description;
  final Widget preview;
  final VoidCallback? onPin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return Card(
      key: Key('widget_section_${kind.wireKey}'),
      margin: EdgeInsets.zero,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      color: _tonalCardColor(theme),
      shape: _tonalCardShape,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${kind.title}（${kind.gridLabel}）',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                if (activeCount > 0) ...[
                  const SizedBox(width: 8),
                  Chip(
                    label: Text('已添加 $activeCount 个'),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Text(description, style: theme.textTheme.bodySmall),
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
              decoration: BoxDecoration(
                color: isDark
                    ? scheme.surfaceContainerHigh.withValues(alpha: 0.65)
                    : scheme.surfaceContainerHighest.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Center(child: preview),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                key: Key('widget_pin_${kind.wireKey}'),
                onPressed: onPin,
                icon: Icon(
                  onPin != null
                      ? Icons.add_to_home_screen
                      : Icons.block_outlined,
                  size: 18,
                ),
                label: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    onPin != null ? '添加到桌面' : '仅支持 Android 与 HarmonyOS 桌面',
                    maxLines: 1,
                    softWrap: false,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WidgetPreviewPalette {
  const _WidgetPreviewPalette._({
    required this.cardColor,
    required this.borderColor,
    required this.shadowColor,
    required this.accentColor,
    required this.primaryTextColor,
    required this.bodyTextColor,
    required this.secondaryTextColor,
    required this.pillBgColor,
  });

  factory _WidgetPreviewPalette.of(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (isDark) {
      return const _WidgetPreviewPalette._(
        cardColor: Color(0xFF242A35),
        borderColor: Color(0xFF374151),
        shadowColor: Color(0x28000000),
        accentColor: Color(0xFF60A5FA),
        primaryTextColor: Color(0xFFF3F4F6),
        bodyTextColor: Color(0xFFD1D5DB),
        secondaryTextColor: Color(0xFF9CA3AF),
        pillBgColor: Color(0xFF1E3A5F),
      );
    }
    return const _WidgetPreviewPalette._(
      cardColor: Color(0xFFFFFFFF),
      borderColor: Color(0xFFE0E6EE),
      shadowColor: Color(0x12000000),
      accentColor: Color(0xFF1F6FEB),
      primaryTextColor: Color(0xFF111827),
      bodyTextColor: Color(0xFF374151),
      secondaryTextColor: Color(0xFF6B7280),
      pillBgColor: Color(0xFFEFF6FF),
    );
  }

  final Color cardColor;
  final Color borderColor;
  final Color shadowColor;
  final Color accentColor;
  final Color primaryTextColor;
  final Color bodyTextColor;
  final Color secondaryTextColor;
  final Color pillBgColor;
}

class _QuickAddPreviewCard extends StatelessWidget {
  const _QuickAddPreviewCard();

  @override
  Widget build(BuildContext context) {
    final palette = _WidgetPreviewPalette.of(context);
    return Container(
      key: const Key('widget_preview_quick_add'),
      width: 84,
      height: 84,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: palette.cardColor,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: palette.borderColor),
        boxShadow: [
          BoxShadow(
            color: palette.shadowColor,
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '+',
              style: TextStyle(
                fontSize: 28,
                height: 1.0,
                fontWeight: FontWeight.bold,
                color: palette.accentColor,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '记一笔',
              maxLines: 1,
              softWrap: false,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: palette.primaryTextColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MonthSummaryPreviewCard extends StatelessWidget {
  const _MonthSummaryPreviewCard({required this.snapshot});

  final WidgetSnapshotPayload snapshot;

  @override
  Widget build(BuildContext context) {
    final palette = _WidgetPreviewPalette.of(context);
    final sym = snapshot.currencySymbol;
    final secondaryText = snapshot.budgetRemainingFormatted != null
        ? '预算剩余 $sym${snapshot.budgetRemainingFormatted}'
        : '结余 $sym${snapshot.balanceFormatted}';

    return Container(
      key: const Key('widget_preview_month_summary'),
      width: 220,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.cardColor,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: palette.borderColor),
        boxShadow: [
          BoxShadow(
            color: palette.shadowColor,
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${snapshot.bookName} · ${snapshot.periodLabel}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: palette.secondaryTextColor,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '+ 记一笔',
                maxLines: 1,
                softWrap: false,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: palette.accentColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '本期支出',
            style: TextStyle(fontSize: 11, color: palette.secondaryTextColor),
          ),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              '$sym${snapshot.expenseFormatted}',
              maxLines: 1,
              softWrap: false,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: palette.primaryTextColor,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '收入 $sym${snapshot.incomeFormatted}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: palette.bodyTextColor),
          ),
          const SizedBox(height: 2),
          Text(
            secondaryText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: palette.bodyTextColor),
          ),
        ],
      ),
    );
  }
}

class _MonthBarPreviewCard extends StatelessWidget {
  const _MonthBarPreviewCard({required this.snapshot});

  final WidgetSnapshotPayload snapshot;

  @override
  Widget build(BuildContext context) {
    final palette = _WidgetPreviewPalette.of(context);
    final sym = snapshot.currencySymbol;
    return Container(
      key: const Key('widget_preview_month_bar'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: palette.cardColor,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: palette.borderColor),
        boxShadow: [
          BoxShadow(
            color: palette.shadowColor,
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: _BarMetric(
              label: '${snapshot.bookName}支出',
              value: '$sym${snapshot.expenseFormatted}',
              palette: palette,
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: _BarMetric(
              label: '本期收入',
              value: '$sym${snapshot.incomeFormatted}',
              palette: palette,
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: _BarMetric(
              label: '今日支出',
              value: '$sym${snapshot.todayExpenseFormatted}',
              palette: palette,
            ),
          ),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 68),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: palette.pillBgColor,
                borderRadius: BorderRadius.circular(12),
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  '+ 记一笔',
                  maxLines: 1,
                  softWrap: false,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: palette.accentColor,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SmartQuickPreviewCard extends StatelessWidget {
  const _SmartQuickPreviewCard({required this.snapshot});

  final WidgetSnapshotPayload snapshot;

  @override
  Widget build(BuildContext context) {
    final palette = _WidgetPreviewPalette.of(context);
    final badgeText = snapshot.pendingDraftCount > 0
        ? '待确认 ${snapshot.pendingDraftCount}'
        : '无待确认';

    return Container(
      key: const Key('widget_preview_smart_quick'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.cardColor,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: palette.borderColor),
        boxShadow: [
          BoxShadow(
            color: palette.shadowColor,
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  snapshot.bookName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: palette.primaryTextColor,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: palette.pillBgColor,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  badgeText,
                  maxLines: 1,
                  softWrap: false,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: palette.accentColor,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _SmartActionPill(label: '+ 记一笔', palette: palette),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _SmartActionPill(label: '口语粘贴', palette: palette),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _SmartActionPill(label: '识图', palette: palette),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SmartActionPill extends StatelessWidget {
  const _SmartActionPill({required this.label, required this.palette});

  final String label;
  final _WidgetPreviewPalette palette;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
    decoration: BoxDecoration(
      color: palette.pillBgColor,
      borderRadius: BorderRadius.circular(12),
    ),
    alignment: Alignment.center,
    child: FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(
        label,
        maxLines: 1,
        softWrap: false,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: palette.accentColor,
        ),
      ),
    ),
  );
}

class _BarMetric extends StatelessWidget {
  const _BarMetric({
    required this.label,
    required this.value,
    required this.palette,
  });

  final String label;
  final String value;
  final _WidgetPreviewPalette palette;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, color: palette.secondaryTextColor),
      ),
      const SizedBox(height: 2),
      Text(
        value,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.bold,
          color: palette.primaryTextColor,
        ),
      ),
    ],
  );
}

final _tonalCardShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.circular(16),
);

Color _tonalCardColor(ThemeData theme) {
  final scheme = theme.colorScheme;
  return theme.brightness == Brightness.dark
      ? scheme.surfaceContainerLow
      : Color.lerp(scheme.surfaceContainerLow, scheme.surfaceContainer, 0.55)!;
}
