import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/adaptive.dart';
import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/asset_overview.dart' show normalizeCurrency;
import '../../domain/rules/currency_rates.dart' show baseCurrency;
import '../attachments/attachment_providers.dart'
    show billAttachmentServiceProvider;
import '../common/catalog_icons.dart';
import '../common/common.dart';
import 'receipt_diy_providers.dart';

/// Reusable synchronized preference section for toggling `autoSelectDefaultAccount`
/// and choosing `defaultAccountId` (`ti_preference` key `'record_diy_toolbar'`).
class DefaultAccountPreferenceSection extends ConsumerStatefulWidget {
  const DefaultAccountPreferenceSection({
    super.key,
    required this.switchKey,
    required this.selectorKey,
    this.externalBusy = false,
    this.compact = false,
  });

  final Key switchKey;
  final Key selectorKey;
  final bool externalBusy;
  final bool compact;

  @override
  ConsumerState<DefaultAccountPreferenceSection> createState() =>
      _DefaultAccountPreferenceSectionState();
}

class _DefaultAccountPreferenceSectionState
    extends ConsumerState<DefaultAccountPreferenceSection> {
  final _ids = CommandIds();
  bool _saving = false;
  int _saveSeq = 0;

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<DiyToolbarConfig?> _persistDefaultAccount({
    bool? autoSelectDefaultAccount,
    int? defaultAccountId,
  }) async {
    setState(() => _saving = true);
    try {
      final service = await ref.read(billAttachmentServiceProvider.future);
      final latest = await service.getDiyToolbarConfig();
      final next = latest.copyWithDefaultAccount(
        autoSelectDefaultAccount: autoSelectDefaultAccount,
        defaultAccountId: defaultAccountId,
      );
      final seq = _saveSeq++;
      return await service.saveDiyToolbarConfig(
        commandId: _ids.forPayload([
          'ui-default-account',
          seq,
          next.autoSelectDefaultAccount,
          next.defaultAccountId,
        ]),
        config: next,
      );
    } catch (e) {
      _showSnack(safeMessage(e));
      return null;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<List<Asset>> _resolveSelectableAssets() async {
    final fromProvider = ref.read(assetsProvider).value;
    final List<Asset> allAssets;
    if (fromProvider != null) {
      allAssets = fromProvider;
    } else {
      final service = await ref.read(billAttachmentServiceProvider.future);
      allAssets = await service.db.select(service.db.assets).get();
    }
    return allAssets
        .where(
          (a) => a.status == AssetStatus.active && a.type != AssetType.debt,
        )
        .toList();
  }

  Future<void> _onToggleChanged(bool enabled) async {
    final saved = await _persistDefaultAccount(
      autoSelectDefaultAccount: enabled,
    );
    if (saved == null || !enabled || !mounted) return;
    try {
      final selectable = await _resolveSelectableAssets();
      if (!mounted || selectable.isEmpty) return;
      final hasValidAccount =
          saved.defaultAccountId != noRef &&
          selectable.any((a) => a.id == saved.defaultAccountId);
      if (!hasValidAccount) {
        await _openAccountSelector(
          selectableAssets: selectable,
          currentId: noRef,
        );
      }
    } catch (_) {
      // Non-blocking immediate picker convenience after persisting toggle ON.
    }
  }

  Future<void> _openAccountSelector({
    required List<Asset> selectableAssets,
    required int currentId,
  }) async {
    if (!mounted) return;
    final isDesktop = DesktopAdaptive.isDesktop(context);
    final int? chosen;
    if (isDesktop) {
      chosen = await showDialog<int>(
        context: context,
        builder: (dialogCtx) {
          final cs = Theme.of(dialogCtx).colorScheme;
          return Dialog(
            key: const Key('default-account-picker-dialog'),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420, maxHeight: 520),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 10, 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '选择默认账户',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(dialogCtx).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                        CloseButton(
                          onPressed: () => Navigator.of(dialogCtx).pop(),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      children: [
                        ListTile(
                          key: const Key('default-account-option-none'),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          leading: Container(
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              color: cs.surfaceContainerHighest,
                              shape: BoxShape.circle,
                            ),
                            alignment: Alignment.center,
                            child: Icon(
                              Icons.remove_circle_outline_rounded,
                              size: 18,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                          title: const Text('暂不指定'),
                          trailing: currentId == noRef
                              ? Icon(Icons.check_rounded, color: cs.primary)
                              : null,
                          onTap: () => Navigator.of(dialogCtx).pop(noRef),
                        ),
                        for (final a in selectableAssets)
                          ListTile(
                            key: Key('default-account-option-${a.id}'),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                            leading: AssetIconAvatar(
                              iconKey: a.icon,
                              colorHex: a.color,
                              name: a.name,
                              assetType: a.type,
                              subType: a.subType,
                              size: 34,
                              selected: currentId == a.id,
                            ),
                            title: Text(
                              a.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${normalizeCurrency(a.currency) ?? baseCurrency} · ${formatMinor(a.balanceMinor)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12),
                            ),
                            trailing: currentId == a.id
                                ? Icon(Icons.check_rounded, color: cs.primary)
                                : null,
                            onTap: () => Navigator.of(dialogCtx).pop(a.id),
                          ),
                        if (selectableAssets.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(
                              '暂无可用资金或信用账户，请先前往资产页新建账户。',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 12.5,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    } else {
      chosen = await showModalBottomSheet<int>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        useSafeArea: true,
        sheetAnimationStyle: AnimationStyle.noAnimation,
        builder: (sheetCtx) {
          final cs = Theme.of(sheetCtx).colorScheme;
          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(sheetCtx).height * 0.65,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '选择默认账户',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(sheetCtx).textTheme.titleMedium,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        ListTile(
                          key: const Key('default-account-option-none'),
                          leading: Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: cs.surfaceContainerHighest,
                              shape: BoxShape.circle,
                            ),
                            alignment: Alignment.center,
                            child: Icon(
                              Icons.remove_circle_outline_rounded,
                              size: 18,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                          title: const Text('暂不指定'),
                          trailing: currentId == noRef
                              ? Icon(Icons.check_rounded, color: cs.primary)
                              : null,
                          onTap: () => Navigator.of(sheetCtx).pop(noRef),
                        ),
                        for (final a in selectableAssets)
                          ListTile(
                            key: Key('default-account-option-${a.id}'),
                            leading: AssetIconAvatar(
                              iconKey: a.icon,
                              colorHex: a.color,
                              name: a.name,
                              assetType: a.type,
                              subType: a.subType,
                              size: 36,
                              selected: currentId == a.id,
                            ),
                            title: Text(
                              a.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${normalizeCurrency(a.currency) ?? baseCurrency} · ${formatMinor(a.balanceMinor)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12),
                            ),
                            trailing: currentId == a.id
                                ? Icon(Icons.check_rounded, color: cs.primary)
                                : null,
                            onTap: () => Navigator.of(sheetCtx).pop(a.id),
                          ),
                        if (selectableAssets.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(
                              '暂无可用资金或信用账户，请先前往资产页新建账户。',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 12.5,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    }

    if (chosen == null || !mounted) return;
    await _persistDefaultAccount(
      autoSelectDefaultAccount: true,
      defaultAccountId: chosen,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Guard standalone layout tests that mount SettingsPage without overriding
    // databaseProvider so NativeDatabase.createInBackground is never cold-started.
    if (!ref.exists(databaseProvider) &&
        !ref.exists(diyToolbarConfigProvider)) {
      return SwitchListTile(
        key: widget.switchKey,
        dense: widget.compact,
        visualDensity: widget.compact ? VisualDensity.compact : null,
        contentPadding: widget.compact
            ? const EdgeInsets.symmetric(horizontal: 12)
            : null,
        title: const Text('默认选择指定账户'),
        subtitle: const Text('新建账单时自动填入常用资金或信用账户（编辑旧单或模板已指定账户时不覆盖）'),
        value: false,
        onChanged: null,
      );
    }

    final configAsync = ref.watch(diyToolbarConfigProvider);
    final config = configAsync.value ?? DiyToolbarConfig.defaults();
    final canWatchAssets =
        ref.exists(databaseProvider) || ref.exists(assetsProvider);
    final assetsAsync = canWatchAssets
        ? ref.watch(assetsProvider)
        : const AsyncValue<List<Asset>>.data(<Asset>[]);
    final allAssets = assetsAsync.value ?? const <Asset>[];
    final selectableAssets = allAssets
        .where(
          (a) => a.status == AssetStatus.active && a.type != AssetType.debt,
        )
        .toList();
    final disabled = _saving || widget.externalBusy;
    final cs = Theme.of(context).colorScheme;

    Widget buildSelectorTile() {
      final Widget leading;
      final Widget title;
      Widget? subtitle;
      var effectiveCurrentSelection = noRef;

      if (config.defaultAccountId == noRef) {
        leading = Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Icon(
            Icons.account_balance_wallet_outlined,
            size: 18,
            color: cs.onSurfaceVariant,
          ),
        );
        title = const Text('未指定默认账户（点击选择）');
      } else if (assetsAsync.isLoading && !assetsAsync.hasValue) {
        leading = Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Icon(
            Icons.account_balance_wallet_outlined,
            size: 18,
            color: cs.onSurfaceVariant,
          ),
        );
        title = const Text('正在读取默认账户…');
      } else {
        final matched = allAssets
            .where((a) => a.id == config.defaultAccountId)
            .firstOrNull;
        final isValid =
            matched != null &&
            matched.status == AssetStatus.active &&
            matched.type != AssetType.debt;
        if (isValid) {
          effectiveCurrentSelection = matched.id;
          leading = AssetIconAvatar(
            iconKey: matched.icon,
            colorHex: matched.color,
            name: matched.name,
            assetType: matched.type,
            subType: matched.subType,
            size: 36,
          );
          title = Text(
            matched.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );
          subtitle = Text(
            '${normalizeCurrency(matched.currency) ?? baseCurrency} · ${formatMinor(matched.balanceMinor)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );
        } else {
          leading = Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: cs.errorContainer,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.warning_amber_rounded,
              size: 19,
              color: cs.onErrorContainer,
            ),
          );
          title = Text(
            matched != null ? '${matched.name}（不可用）' : '默认账户不可用',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );
          subtitle = Text(
            '原默认账户已隐藏、结清或删除，当前自动回退为不选账户，点击重新指定',
            style: TextStyle(color: cs.error),
          );
        }
      }

      return ListTile(
        key: widget.selectorKey,
        dense: widget.compact,
        visualDensity: widget.compact ? VisualDensity.compact : null,
        contentPadding: widget.compact
            ? const EdgeInsets.symmetric(horizontal: 12)
            : null,
        enabled: !disabled,
        leading: leading,
        title: title,
        subtitle: subtitle,
        trailing: const Icon(Icons.chevron_right),
        onTap: disabled
            ? null
            : () async {
                final latestSelectable = selectableAssets.isNotEmpty
                    ? selectableAssets
                    : await _resolveSelectableAssets();
                if (!mounted) return;
                await _openAccountSelector(
                  selectableAssets: latestSelectable,
                  currentId: effectiveCurrentSelection,
                );
              },
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          key: widget.switchKey,
          dense: widget.compact,
          visualDensity: widget.compact ? VisualDensity.compact : null,
          contentPadding: widget.compact
              ? const EdgeInsets.symmetric(horizontal: 12)
              : null,
          title: const Text('默认选择指定账户'),
          subtitle: const Text('新建账单时自动填入常用资金或信用账户（编辑旧单或模板已指定账户时不覆盖）'),
          value: config.autoSelectDefaultAccount,
          onChanged: disabled ? null : _onToggleChanged,
        ),
        if (config.autoSelectDefaultAccount) ...[
          const Divider(height: 1),
          buildSelectorTile(),
        ],
      ],
    );
  }
}

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
  bool _previewExpanded = false;
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

  Widget _groupCard(BuildContext context, {Key? key, required Widget child}) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Material(
        key: key,
        color: _groupColor(
          theme.colorScheme,
          theme.brightness == Brightness.dark,
        ),
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: child,
      ),
    );
  }

  Widget _buildPreviewCard(BuildContext context, DiyToolbarConfig config) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final visible = config.visibleActions;
    void toggle() => setState(() => _previewExpanded = !_previewExpanded);
    return _groupCard(
      context,
      key: const Key('diy-toolbar-preview'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: toggle,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
              child: Row(
                children: [
                  Icon(
                    Icons.view_week_outlined,
                    size: 20,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '已启用 ${visible.length}/${config.items.length} 项',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  TextButton.icon(
                    key: const Key('diy-toolbar-preview-toggle'),
                    onPressed: toggle,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      minimumSize: const Size(0, 36),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    icon: Icon(
                      _previewExpanded
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      size: 18,
                    ),
                    label: Text(_previewExpanded ? '收起' : '展开'),
                  ),
                ],
              ),
            ),
          ),
          if (_previewExpanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: visible.isEmpty
                  ? Text(
                      '已隐藏全部工具栏按钮',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    )
                  : Wrap(
                      key: const Key('diy-toolbar-preview-chips'),
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        for (final a in visible)
                          Chip(
                            avatar: Icon(_iconFor(a), size: 16),
                            label: Text(a.label),
                            visualDensity: VisualDensity.compact,
                            side: BorderSide.none,
                            backgroundColor: scheme.surface,
                          ),
                      ],
                    ),
            ),
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
                : () => _persist(DiyToolbarConfig.defaults()),
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
          header: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _sectionHeader(context, '工具栏预览'),
              _buildPreviewCard(context, config),
              _sectionHeader(context, '默认账户'),
              _groupCard(
                context,
                child: DefaultAccountPreferenceSection(
                  switchKey: const Key('diy-default-account-switch'),
                  selectorKey: const Key('diy-default-account-selector'),
                  externalBusy: _busy,
                  compact: !isDesktop,
                ),
              ),
              _sectionHeader(
                context,
                '工具栏项目与顺序',
                hint: isDesktop
                    ? '拖拽左侧手柄或点击箭头调整顺序，开关控制是否在记一笔弹窗展示'
                    : '长按拖拽或点击箭头调整顺序，开关控制是否在记一笔页面展示',
              ),
            ],
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
