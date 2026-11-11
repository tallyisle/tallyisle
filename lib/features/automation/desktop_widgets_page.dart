import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../platform/app_widgets.dart';
import '../../platform/files.dart';
import '../common/common.dart';
import 'automation_providers.dart';

/// Live previews, snapshot refresh, and pin/add guide for Android desktop AppWidgets (`F-034`).
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
      final service = await ref.read(widgetSnapshotServiceProvider.future);
      await service.syncToPlatform();
      ref.invalidate(widgetSnapshotProvider);
      ref.invalidate(activeWidgetCountsProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已同步最新账本数据到桌面小组件')));
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
    try {
      final service = await ref.read(widgetSnapshotServiceProvider.future);
      final pinned = await service.requestPinWidget(kind);
      ref.invalidate(activeWidgetCountsProvider);
      if (!mounted) return;
      if (pinned) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已发起“${kind.title}”添加请求，请在系统弹窗中确认')),
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
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (capability.state != CapabilityState.available)
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
              onPin: () => _pinWidget(DesktopWidgetKind.quickAdd),
              preview: const _QuickAddPreviewCard(),
            ),
            const SizedBox(height: 16),
            _WidgetPreviewSection(
              kind: DesktopWidgetKind.monthSummary,
              activeCount: counts[DesktopWidgetKind.monthSummary] ?? 0,
              description: '2×2 卡片实时展示当前账本本期支出、收入与预算剩余（或结余）。',
              onPin: () => _pinWidget(DesktopWidgetKind.monthSummary),
              preview: _MonthSummaryPreviewCard(snapshot: snapshot),
            ),
            const SizedBox(height: 16),
            _WidgetPreviewSection(
              kind: DesktopWidgetKind.monthBar,
              activeCount: counts[DesktopWidgetKind.monthBar] ?? 0,
              description: '4×1 紧凑横条同时展示本期支出、本期收入、今日支出与快捷记账按钮。',
              onPin: () => _pinWidget(DesktopWidgetKind.monthBar),
              preview: _MonthBarPreviewCard(snapshot: snapshot),
            ),
            const SizedBox(height: 20),
            Card(
              key: const Key('widget_add_guide_card'),
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
  final VoidCallback onPin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: Key('widget_section_${kind.wireKey}'),
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
                if (activeCount > 0)
                  Chip(
                    label: Text('已添加 $activeCount 个'),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(description, style: theme.textTheme.bodySmall),
            const SizedBox(height: 14),
            Center(child: preview),
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                key: Key('widget_pin_${kind.wireKey}'),
                onPressed: onPin,
                icon: const Icon(Icons.add_to_home_screen, size: 18),
                label: const Text('添加到桌面'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickAddPreviewCard extends StatelessWidget {
  const _QuickAddPreviewCard();

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('widget_preview_quick_add'),
    width: 84,
    height: 84,
    decoration: BoxDecoration(
      color: const Color(0xFFFFFFFF),
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: const Color(0xFFE0E6EE)),
      boxShadow: const [
        BoxShadow(
          color: Color(0x12000000),
          blurRadius: 8,
          offset: Offset(0, 2),
        ),
      ],
    ),
    child: const Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          '+',
          style: TextStyle(
            fontSize: 28,
            height: 1.0,
            fontWeight: FontWeight.bold,
            color: Color(0xFF1F6FEB),
          ),
        ),
        SizedBox(height: 4),
        Text(
          '记一笔',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Color(0xFF1F2937),
          ),
        ),
      ],
    ),
  );
}

class _MonthSummaryPreviewCard extends StatelessWidget {
  const _MonthSummaryPreviewCard({required this.snapshot});

  final WidgetSnapshotPayload snapshot;

  @override
  Widget build(BuildContext context) {
    final sym = snapshot.currencySymbol;
    final secondaryText = snapshot.budgetRemainingFormatted != null
        ? '预算剩余 $sym${snapshot.budgetRemainingFormatted}'
        : '结余 $sym${snapshot.balanceFormatted}';

    return Container(
      key: const Key('widget_preview_month_summary'),
      width: 220,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFFFF),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE0E6EE)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 8,
            offset: Offset(0, 2),
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
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF6B7280),
                  ),
                ),
              ),
              const Text(
                '+ 记一笔',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1F6FEB),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            '本期支出',
            style: TextStyle(fontSize: 11, color: Color(0xFF6B7280)),
          ),
          Text(
            '$sym${snapshot.expenseFormatted}',
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Color(0xFF111827),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '收入 $sym${snapshot.incomeFormatted}',
            style: const TextStyle(fontSize: 12, color: Color(0xFF374151)),
          ),
          const SizedBox(height: 2),
          Text(
            secondaryText,
            style: const TextStyle(fontSize: 12, color: Color(0xFF374151)),
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
    final sym = snapshot.currencySymbol;
    return Container(
      key: const Key('widget_preview_month_bar'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFFFF),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE0E6EE)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: _BarMetric(
              label: '${snapshot.bookName}支出',
              value: '$sym${snapshot.expenseFormatted}',
            ),
          ),
          Expanded(
            child: _BarMetric(
              label: '本期收入',
              value: '$sym${snapshot.incomeFormatted}',
            ),
          ),
          Expanded(
            child: _BarMetric(
              label: '今日支出',
              value: '$sym${snapshot.todayExpenseFormatted}',
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFEFF6FF),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Text(
              '+ 记一笔',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1F6FEB),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BarMetric extends StatelessWidget {
  const _BarMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280)),
      ),
      const SizedBox(height: 2),
      Text(
        value,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.bold,
          color: Color(0xFF111827),
        ),
      ),
    ],
  );
}
