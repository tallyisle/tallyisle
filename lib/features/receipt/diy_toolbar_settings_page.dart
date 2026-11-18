import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/adaptive.dart';
import '../attachments/attachment_providers.dart'
    show billAttachmentServiceProvider;
import '../common/common.dart';
import 'receipt_diy_providers.dart';

/// Settings page for customizing the record-editor function toolbar (`F-036`, `/bkp/ARPFDAct`).
class DiyToolbarSettingsPage extends ConsumerStatefulWidget {
  const DiyToolbarSettingsPage({super.key});

  @override
  ConsumerState<DiyToolbarSettingsPage> createState() =>
      _DiyToolbarSettingsPageState();
}

class _DiyToolbarSettingsPageState
    extends ConsumerState<DiyToolbarSettingsPage> {
  final _ids = CommandIds();
  bool _busy = false;
  int _saveSeq = 0;

  static IconData _iconFor(DiyToolbarAction action) => switch (action) {
    DiyToolbarAction.tags => Icons.sell_outlined,
    DiyToolbarAction.images => Icons.photo_camera_back_outlined,
    DiyToolbarAction.discount => Icons.local_offer_outlined,
    DiyToolbarAction.location => Icons.place_outlined,
    DiyToolbarAction.excludeBudget => Icons.pie_chart_outline,
    DiyToolbarAction.excludeExIn => Icons.visibility_off_outlined,
    DiyToolbarAction.currency => Icons.currency_exchange,
    DiyToolbarAction.templates => Icons.bookmarks_outlined,
    DiyToolbarAction.frequentRemarks => Icons.comment_outlined,
    DiyToolbarAction.keypadMultiplyDivide => Icons.calculate_outlined,
    DiyToolbarAction.autoSelectFirstCategory => Icons.category_outlined,
  };

  Future<void> _persist(DiyToolbarConfig next) async {
    setState(() => _busy = true);
    try {
      final service = await ref.read(billAttachmentServiceProvider.future);
      final seq = _saveSeq++;
      await service.saveDiyToolbarConfig(
        commandId: _ids.forPayload(['ui-diy-toolbar', seq, next.toJson()]),
        config: next,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static Color _groupColor(ColorScheme scheme, bool isDark) => isDark
      ? scheme.surfaceContainerLow
      : Color.lerp(scheme.surfaceContainerLow, scheme.surfaceContainer, 0.55)!;

  Widget _sectionHeader(BuildContext context, String title, {String? hint}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 14, 22, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.labelMedium?.copyWith(
              color: scheme.onSurfaceVariant.withValues(
                alpha: isDark ? 0.78 : 0.85,
              ),
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
          if (hint != null) ...[
            const SizedBox(height: 2),
            Text(
              hint,
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 11.5,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.72),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildToolbarRow(
    BuildContext context, {
    required DiyToolbarConfig config,
    required int index,
    required bool isDesktop,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final item = config.items[index];
    final action = item.action;
    final isFirst = index == 0;
    final isLast = index == config.items.length - 1;
    const radius = Radius.circular(16);

    final tile = ListTile(
      visualDensity: isDesktop ? null : const VisualDensity(vertical: -1),
      contentPadding: const EdgeInsets.only(left: 16, right: 8),
      leading: isDesktop
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                MouseRegion(
                  cursor: _busy
                      ? SystemMouseCursors.basic
                      : SystemMouseCursors.grab,
                  child: Icon(
                    Icons.drag_handle_rounded,
                    size: 20,
                    color: scheme.outline,
                  ),
                ),
                const SizedBox(width: 10),
                Icon(_iconFor(action)),
              ],
            )
          : Icon(_iconFor(action)),
      title: Text(action.label),
      subtitle: Text(action.description),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: Key('diy-up-${action.key}'),
            tooltip: '上移',
            visualDensity: VisualDensity.compact,
            style: IconButton.styleFrom(
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            icon: const Icon(Icons.arrow_upward, size: 18),
            onPressed: _busy || isFirst
                ? null
                : () => _persist(config.moveItem(index, index - 1)),
          ),
          IconButton(
            key: Key('diy-down-${action.key}'),
            tooltip: '下移',
            visualDensity: VisualDensity.compact,
            style: IconButton.styleFrom(
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            icon: const Icon(Icons.arrow_downward, size: 18),
            onPressed: _busy || isLast
                ? null
                : () => _persist(config.moveItem(index, index + 1)),
          ),
          Switch(
            key: Key('diy-switch-${action.key}'),
            value: item.enabled,
            onChanged: _busy
                ? null
                : (enabled) => _persist(config.setEnabled(action, enabled)),
          ),
        ],
      ),
    );

    final grouped = Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, isLast ? 16 : 0),
      child: Material(
        color: _groupColor(scheme, isDark),
        borderRadius: BorderRadius.vertical(
          top: isFirst ? radius : Radius.zero,
          bottom: isLast ? radius : Radius.zero,
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!isFirst)
              Divider(
                height: 1,
                thickness: 0.5,
                indent: isDesktop ? 82 : 56,
                endIndent: 16,
                color: scheme.outlineVariant.withValues(
                  alpha: isDark ? 0.28 : 0.35,
                ),
              ),
            tile,
          ],
        ),
      ),
    );

    if (isDesktop) {
      return ReorderableDragStartListener(
        key: ValueKey('diy-row-${action.key}'),
        index: index,
        enabled: !_busy,
        child: grouped,
      );
    }
    return ReorderableDelayedDragStartListener(
      key: ValueKey('diy-row-${action.key}'),
      index: index,
      enabled: !_busy,
      child: grouped,
    );
  }

  @override
  Widget build(BuildContext context) {
    final configAsync = ref.watch(diyToolbarConfigProvider);
    final isDesktop = DesktopAdaptive.isDesktop(context);
    final isDesktopModal =
        isDesktop &&
        ModalRoute.of(context) is PopupRoute &&
        Navigator.of(context).canPop();

    return Scaffold(
      appBar: AppBar(
        leading: isDesktopModal ? const CloseButton() : null,
        title: const Text('记账工具栏自定义'),
        scrolledUnderElevation: 0,
        actions: [
          TextButton(
            key: const Key('diy-toolbar-reset-btn'),
            onPressed: _busy
                ? null
                : () {
                    final current = configAsync.value;
                    final reset = current == null
                        ? DiyToolbarConfig.defaults()
                        : DiyToolbarConfig.defaults().copyWithDefaultAccount(
                            autoSelectDefaultAccount:
                                current.autoSelectDefaultAccount,
                            defaultAccountId: current.defaultAccountId,
                          );
                    _persist(reset);
                  },
            child: const Text('恢复默认'),
          ),
        ],
      ),
      body: asyncBody(configAsync, (config) {
        final list = ReorderableListView.builder(
          key: const Key('diy-toolbar-list'),
          buildDefaultDragHandles: false,
          padding: const EdgeInsets.only(bottom: 12),
          proxyDecorator: (child, index, animation) => Material(
            elevation: 6,
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(16),
            child: child,
          ),
          header: _sectionHeader(
            context,
            '工具栏项目与顺序',
            hint: isDesktop
                ? '拖拽左侧手柄或点击箭头调整顺序，开关控制是否在记一笔弹窗展示'
                : '长按拖拽或点击箭头调整顺序，开关控制是否在记一笔页面展示',
          ),
          itemCount: config.items.length,
          onReorderItem: (oldIndex, newIndex) {
            if (_busy) return;
            _persist(config.moveItem(oldIndex, newIndex));
          },
          itemBuilder: (context, index) => _buildToolbarRow(
            context,
            config: config,
            index: index,
            isDesktop: isDesktop,
          ),
        );
        if (!isDesktop) {
          return list;
        }
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: list,
          ),
        );
      }),
    );
  }
}
