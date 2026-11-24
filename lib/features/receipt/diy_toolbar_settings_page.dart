import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  DiyToolbarConfig? _optimisticConfig;

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
    setState(() {
      _busy = true;
      _optimisticConfig = next;
    });
    try {
      final service = await ref.read(billAttachmentServiceProvider.future);
      final seq = _saveSeq++;
      await service.saveDiyToolbarConfig(
        commandId: _ids.forPayload(['ui-diy-toolbar', seq, next.toJson()]),
        config: next,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _optimisticConfig = null);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _optimisticConfig = null;
        });
      }
    }
  }

  static Color _groupColor(ColorScheme scheme, bool isDark) => isDark
      ? scheme.surfaceContainerLow
      : Color.lerp(scheme.surfaceContainerLow, scheme.surfaceContainer, 0.55)!;

  Widget _buildSectionHeader(
    BuildContext context, {
    required String title,
    String? subtitle,
    EdgeInsetsGeometry padding = const EdgeInsets.fromLTRB(20, 4, 20, 8),
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSortableRow(
    BuildContext context, {
    required DiyToolbarConfig config,
    required List<DiyToolbarItem> sortableItems,
    required int index,
    required bool isDesktop,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final item = sortableItems[index];
    final action = item.action;
    final isFirst = index == 0;
    final isLast = index == sortableItems.length - 1;
    const radius = Radius.circular(16);

    final tile = ListTile(
      visualDensity: isDesktop ? null : const VisualDensity(vertical: -1),
      contentPadding: const EdgeInsets.only(left: 16, right: 12),
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
                    key: Key('diy-drag-handle-${action.key}'),
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
      trailing: Switch(
        key: Key('diy-switch-${action.key}'),
        value: item.enabled,
        onChanged: _busy
            ? null
            : (enabled) => _persist(config.setEnabled(action, enabled)),
      ),
    );

    final grouped = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
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

  Widget _buildFixedSwitchesSection(
    BuildContext context, {
    required DiyToolbarConfig config,
    required List<DiyToolbarItem> fixedItems,
    required bool isDesktop,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return Column(
      key: const Key('diy-fixed-switches-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildSectionHeader(
          context,
          title: '记账辅助开关',
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Material(
            key: const Key('diy-fixed-switches-card'),
            color: _groupColor(scheme, isDark),
            borderRadius: BorderRadius.circular(16),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < fixedItems.length; i++) ...[
                  if (i > 0)
                    Divider(
                      height: 1,
                      thickness: 0.5,
                      indent: 56,
                      endIndent: 16,
                      color: scheme.outlineVariant.withValues(
                        alpha: isDark ? 0.28 : 0.35,
                      ),
                    ),
                  ListTile(
                    key: ValueKey('diy-row-${fixedItems[i].action.key}'),
                    visualDensity: isDesktop
                        ? null
                        : const VisualDensity(vertical: -1),
                    contentPadding: const EdgeInsets.only(left: 16, right: 12),
                    leading: Icon(_iconFor(fixedItems[i].action)),
                    title: Text(fixedItems[i].action.label),
                    subtitle: Text(fixedItems[i].action.description),
                    trailing: Switch(
                      key: Key('diy-switch-${fixedItems[i].action.key}'),
                      value: fixedItems[i].enabled,
                      onChanged: _busy
                          ? null
                          : (enabled) => _persist(
                              config.setEnabled(fixedItems[i].action, enabled),
                            ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
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
            onPressed: _busy || !configAsync.hasValue
                ? null
                : () {
                    final current = configAsync.requireValue;
                    final reset = DiyToolbarConfig.defaults()
                        .copyWithStyles(
                          datePickerStyle: current.datePickerStyle,
                          timePickerStyle: current.timePickerStyle,
                        )
                        .copyWithDefaultAccount(
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
      body: asyncBody(configAsync, (rawConfig) {
        final config = _optimisticConfig ?? rawConfig;
        final sortableItems = config.sortableItems;
        final fixedItems = config.fixedSwitchItems;

        final list = ReorderableListView.builder(
          key: const Key('diy-toolbar-list'),
          buildDefaultDragHandles: false,
          padding: const EdgeInsets.only(top: 12, bottom: 24),
          header: _buildSectionHeader(
            context,
            title: '工具栏项目（可拖拽排序）',
            subtitle: '账户与日期时间固定在工具栏最前常驻',
          ),
          footer: _buildFixedSwitchesSection(
            context,
            config: config,
            fixedItems: fixedItems,
            isDesktop: isDesktop,
          ),
          onReorderStart: (_) {
            if (!isDesktop) {
              HapticFeedback.selectionClick();
            }
          },
          proxyDecorator: (child, index, animation) => Material(
            elevation: 6,
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(16),
            child: child,
          ),
          itemCount: sortableItems.length,
          onReorderItem: (oldIndex, newIndex) {
            if (_busy || oldIndex == newIndex) return;
            _persist(config.moveSortableItem(oldIndex, newIndex));
          },
          itemBuilder: (context, index) => _buildSortableRow(
            context,
            config: config,
            sortableItems: sortableItems,
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
