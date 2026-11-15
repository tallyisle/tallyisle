import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../domain/model/codes.dart';
import '../domain/rules/cloud_sync_rules.dart';
import '../features/automation/automation_providers.dart'
    show autoBillDraftCountProvider;
import '../features/backup/backup_providers.dart';
import '../features/books/book_switcher_modal.dart';
import '../features/security/app_lock_providers.dart';
import 'adaptive.dart';
import 'providers.dart';

/// Tracks whether a modal [PopupRoute] (dialog, bottom sheet, popup menu) is
/// currently pushed on the router's root navigator so global shortcuts yield.
class DesktopPopupRouteObserver extends NavigatorObserver {
  int _activePopupCount = 0;

  bool get hasActivePopup => _activePopupCount > 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) {
      _activePopupCount++;
    }
    super.didPush(route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute && _activePopupCount > 0) {
      _activePopupCount--;
    }
    super.didPop(route, previousRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute && _activePopupCount > 0) {
      _activePopupCount--;
    }
    super.didRemove(route, previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute is PopupRoute && _activePopupCount > 0) {
      _activePopupCount--;
    }
    if (newRoute is PopupRoute) {
      _activePopupCount++;
    }
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
  }
}

/// Shared entry point for opening "记一笔" using the user's configured default
/// record type (`支出` / `收入` / `转账`).
void openNewRecordEntry(
  BuildContext context,
  WidgetRef ref, {
  GoRouter? routerOverride,
}) {
  final defaultType =
      ref.read(appSettingsProvider).value?.defaultRecordType ??
      RecordType.expense;
  final location = defaultType == RecordType.expense
      ? '/record/new'
      : '/record/new?type=$defaultType';
  if (routerOverride != null) {
    routerOverride.push(location);
  } else {
    context.push(location);
  }
}

/// Global keyboard shortcut dispatcher active only on desktop platforms while
/// the application is unlocked and no modal popup is open.
///
/// Uses [HardwareKeyboard] so shortcuts work immediately upon cold start even
/// before any pointer click inside the window.
class DesktopGlobalShortcuts extends ConsumerStatefulWidget {
  const DesktopGlobalShortcuts({
    super.key,
    required this.router,
    required this.popupObserver,
    required this.child,
  });

  final GoRouter router;
  final DesktopPopupRouteObserver popupObserver;
  final Widget child;

  @override
  ConsumerState<DesktopGlobalShortcuts> createState() =>
      _DesktopGlobalShortcutsState();
}

class _DesktopGlobalShortcutsState
    extends ConsumerState<DesktopGlobalShortcuts> {
  bool _isDesktop = false;
  bool _isMacOS = false;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleHardwareKey);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _isDesktop = DesktopAdaptive.isDesktop(context);
    _isMacOS = DesktopAdaptive.isMacOS(context);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleHardwareKey);
    super.dispose();
  }

  static bool _isTextInputFocused() {
    final focusCtx = FocusManager.instance.primaryFocus?.context;
    if (focusCtx == null) return false;
    if (focusCtx.widget is EditableText) return true;
    return focusCtx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  static bool _isEditorRoute(String path) {
    if (path == '/record/new') return true;
    if (path.endsWith('/new') || path.endsWith('/edit')) return true;
    return false;
  }

  bool _handleHardwareKey(KeyEvent event) {
    if (!mounted || !_isDesktop) {
      return false;
    }
    if (event is! KeyDownEvent) {
      return false;
    }
    if (widget.popupObserver.hasActivePopup) {
      return false;
    }

    // Yield completely while AppLockGate is resolving cold-start or locked.
    final lockConfigAsync = ref.read(appLockConfigProvider);
    final lockSession = ref.read(appLockSessionProvider);
    final isResolvingInitial =
        !lockSession.initializedColdStart && lockConfigAsync.isLoading;
    final lockConfig = lockConfigAsync.value;
    if (isResolvingInitial ||
        ((lockConfig?.isConfigured ?? false) && lockSession.isLocked)) {
      return false;
    }

    final hw = HardwareKeyboard.instance;
    final primaryMod = _isMacOS
        ? (hw.isMetaPressed || hw.isControlPressed)
        : (hw.isControlPressed && !hw.isMetaPressed);
    final noExtraMod = !hw.isAltPressed && !hw.isShiftPressed;

    final currentPath =
        widget.router.routerDelegate.currentConfiguration.uri.path;
    final key = event.logicalKey;

    if (primaryMod && noExtraMod) {
      // Ctrl/⌘ + N -> New Record
      if (key == LogicalKeyboardKey.keyN) {
        if (_isEditorRoute(currentPath)) {
          return false;
        }
        openNewRecordEntry(context, ref, routerOverride: widget.router);
        return true;
      }

      // Ctrl/⌘ + F or Ctrl/⌘ + K -> Global Search
      if (key == LogicalKeyboardKey.keyF || key == LogicalKeyboardKey.keyK) {
        if (currentPath == '/search' || _isEditorRoute(currentPath)) {
          return false;
        }
        widget.router.push('/search');
        return true;
      }

      // Ctrl/⌘ + 1..4 -> Switch Main Navigation Branches
      if (!_isEditorRoute(currentPath)) {
        final targetBranchRoute = switch (key) {
          LogicalKeyboardKey.digit1 || LogicalKeyboardKey.numpad1 => '/',
          LogicalKeyboardKey.digit2 || LogicalKeyboardKey.numpad2 => '/stats',
          LogicalKeyboardKey.digit3 || LogicalKeyboardKey.numpad3 => '/assets',
          LogicalKeyboardKey.digit4 || LogicalKeyboardKey.numpad4 => '/me',
          _ => null,
        };
        if (targetBranchRoute != null) {
          if (currentPath != targetBranchRoute) {
            widget.router.go(targetBranchRoute);
          }
          return true;
        }
      }
    }

    // Period switching on Home (`/`):
    // - Alt/⌥ + ArrowLeft / ArrowRight
    // - `[` / `]` / `T` when no text input field is focused
    if (currentPath == '/' && !_isTextInputFocused()) {
      final altOnly =
          hw.isAltPressed &&
          !hw.isControlPressed &&
          !hw.isMetaPressed &&
          !hw.isShiftPressed;
      final bareKey =
          !hw.isAltPressed &&
          !hw.isControlPressed &&
          !hw.isMetaPressed &&
          !hw.isShiftPressed;

      if ((altOnly && key == LogicalKeyboardKey.arrowLeft) ||
          (bareKey && key == LogicalKeyboardKey.bracketLeft)) {
        ref.read(periodOffsetProvider.notifier).previous();
        return true;
      }
      if ((altOnly && key == LogicalKeyboardKey.arrowRight) ||
          (bareKey && key == LogicalKeyboardKey.bracketRight)) {
        ref.read(periodOffsetProvider.notifier).next();
        return true;
      }
      if (bareKey && key == LogicalKeyboardKey.keyT) {
        ref.read(periodOffsetProvider.notifier).reset();
        return true;
      }
    }

    return false;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Adaptive desktop shell scaffold (`>= 720px`) rendering either:
/// - `208px` expanded left sidebar (`>= 1080px`)
/// - `76px` compact left navigation rail (`720px .. 1079px`)
class DesktopNavigationScaffold extends ConsumerStatefulWidget {
  const DesktopNavigationScaffold({super.key, required this.shell});

  final StatefulNavigationShell shell;

  @override
  ConsumerState<DesktopNavigationScaffold> createState() =>
      _DesktopNavigationScaffoldState();
}

class _DesktopNavigationScaffoldState
    extends ConsumerState<DesktopNavigationScaffold> {
  bool _switchingBook = false;

  Future<void> _handleSwitchBook() async {
    if (_switchingBook) return;
    _switchingBook = true;
    try {
      await showBookSwitcher(context, ref);
    } finally {
      _switchingBook = false;
    }
  }

  void _goBranch(int index) {
    widget.shell.goBranch(
      index,
      initialLocation: index == widget.shell.currentIndex,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isExpanded = DesktopAdaptive.isExpandedDesktop(context);
    final selectedIndex = widget.shell.currentIndex;
    final bookName = ref.watch(currentBookProvider).value?.name ?? '帐屿';
    final draftCount = ref.watch(autoBillDraftCountProvider);
    final syncSettings = ref.watch(cloudSyncSettingsProvider).value;
    final syncCursor = ref.watch(cloudSyncCursorProvider).value;
    final modLabel = DesktopAdaptive.primaryModifierLabel(context);

    return Scaffold(
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            key: isExpanded
                ? const Key('desktop-sidebar')
                : const Key('desktop-nav-rail'),
            color: scheme.surfaceContainerLow,
            child: SafeArea(
              right: false,
              child: SizedBox(
                width: isExpanded ? 208 : 76,
                child: isExpanded
                    ? _ExpandedDesktopSidebar(
                        bookName: bookName,
                        selectedIndex: selectedIndex,
                        draftCount: draftCount,
                        modLabel: modLabel,
                        syncSettings: syncSettings,
                        syncCursor: syncCursor,
                        onSwitchBook: _handleSwitchBook,
                        onAddRecord: () => openNewRecordEntry(context, ref),
                        onSelectBranch: _goBranch,
                        onOpenSearch: () => context.push('/search'),
                        onOpenCalendar: () => context.push('/calendar'),
                        onOpenBackup: () => context.push('/backup'),
                      )
                    : _CompactDesktopRail(
                        bookName: bookName,
                        selectedIndex: selectedIndex,
                        draftCount: draftCount,
                        modLabel: modLabel,
                        syncSettings: syncSettings,
                        syncCursor: syncCursor,
                        onSwitchBook: _handleSwitchBook,
                        onAddRecord: () => openNewRecordEntry(context, ref),
                        onSelectBranch: _goBranch,
                        onOpenSearch: () => context.push('/search'),
                        onOpenCalendar: () => context.push('/calendar'),
                        onOpenBackup: () => context.push('/backup'),
                      ),
              ),
            ),
          ),
          VerticalDivider(
            width: 1,
            thickness: 1,
            color: scheme.outlineVariant.withValues(alpha: 0.45),
          ),
          Expanded(child: widget.shell),
        ],
      ),
    );
  }
}

class _ExpandedDesktopSidebar extends StatelessWidget {
  const _ExpandedDesktopSidebar({
    required this.bookName,
    required this.selectedIndex,
    required this.draftCount,
    required this.modLabel,
    required this.syncSettings,
    required this.syncCursor,
    required this.onSwitchBook,
    required this.onAddRecord,
    required this.onSelectBranch,
    required this.onOpenSearch,
    required this.onOpenCalendar,
    required this.onOpenBackup,
  });

  final String bookName;
  final int selectedIndex;
  final int draftCount;
  final String modLabel;
  final CloudSyncSettings? syncSettings;
  final LocalSyncCursor? syncCursor;
  final VoidCallback onSwitchBook;
  final VoidCallback onAddRecord;
  final ValueChanged<int> onSelectBranch;
  final VoidCallback onOpenSearch;
  final VoidCallback onOpenCalendar;
  final VoidCallback onOpenBackup;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final syncSummary = _describeSyncStatus(syncSettings, syncCursor);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Material(
                color: scheme.surfaceContainer,
                borderRadius: BorderRadius.circular(12),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  key: const Key('desktop-book-switcher'),
                  onTap: onSwitchBook,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: scheme.primaryContainer,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          alignment: Alignment.center,
                          child: Icon(
                            Icons.book_rounded,
                            size: 16,
                            color: scheme.onPrimaryContainer,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '当前账本',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  fontSize: 10.5,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                              Text(
                                bookName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(
                          Icons.unfold_more_rounded,
                          size: 18,
                          color: scheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Tooltip(
                message: '记一笔 ($modLabel+N)',
                child: FilledButton(
                  key: const Key('add-record'),
                  onPressed: onAddRecord,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(42),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.add_rounded, size: 20),
                      const SizedBox(width: 6),
                      const Expanded(
                        child: Text(
                          '记一笔',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.onPrimary.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '$modLabel+N',
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontSize: 10.5,
                            color: scheme.onPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SidebarNavTile(
                  slotKey: const Key('nav-slot-home'),
                  icon: Icons.receipt_long_outlined,
                  selectedIcon: Icons.receipt_long,
                  label: '明细',
                  shortcutHint: '$modLabel+1',
                  selected: selectedIndex == 0,
                  onTap: () => onSelectBranch(0),
                ),
                const SizedBox(height: 4),
                _SidebarNavTile(
                  slotKey: const Key('nav-slot-stats'),
                  icon: Icons.pie_chart_outline,
                  selectedIcon: Icons.pie_chart,
                  label: '统计',
                  shortcutHint: '$modLabel+2',
                  selected: selectedIndex == 1,
                  onTap: () => onSelectBranch(1),
                ),
                const SizedBox(height: 4),
                _SidebarNavTile(
                  slotKey: const Key('nav-slot-assets'),
                  icon: Icons.account_balance_wallet_outlined,
                  selectedIcon: Icons.account_balance_wallet,
                  label: '资产',
                  shortcutHint: '$modLabel+3',
                  selected: selectedIndex == 2,
                  onTap: () => onSelectBranch(2),
                ),
                const SizedBox(height: 4),
                _SidebarNavTile(
                  slotKey: const Key('nav-slot-more'),
                  icon: Icons.grid_view_outlined,
                  selectedIcon: Icons.grid_view_rounded,
                  label: '更多',
                  shortcutHint: '$modLabel+4',
                  badgeCount: draftCount,
                  selected: selectedIndex == 3,
                  onTap: () => onSelectBranch(3),
                ),
              ],
            ),
          ),
        ),
        Divider(
          height: 1,
          thickness: 0.6,
          indent: 12,
          endIndent: 12,
          color: scheme.outlineVariant.withValues(alpha: 0.45),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: _SidebarUtilityButton(
                      buttonKey: const Key('desktop-nav-search'),
                      icon: Icons.search_rounded,
                      label: '搜索',
                      tooltip: '搜索账单 ($modLabel+F)',
                      onTap: onOpenSearch,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _SidebarUtilityButton(
                      buttonKey: const Key('desktop-nav-calendar'),
                      icon: Icons.calendar_month_outlined,
                      label: '日历',
                      tooltip: '账单日历',
                      onTap: onOpenCalendar,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Tooltip(
                message: syncSummary.tooltip,
                child: InkWell(
                  key: const Key('desktop-nav-sync-status'),
                  borderRadius: BorderRadius.circular(10),
                  onTap: onOpenBackup,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 7,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          syncSummary.icon,
                          size: 16,
                          color: syncSummary.isCloudActive
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            syncSummary.shortLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        Icon(
                          Icons.chevron_right_rounded,
                          size: 15,
                          color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CompactDesktopRail extends StatelessWidget {
  const _CompactDesktopRail({
    required this.bookName,
    required this.selectedIndex,
    required this.draftCount,
    required this.modLabel,
    required this.syncSettings,
    required this.syncCursor,
    required this.onSwitchBook,
    required this.onAddRecord,
    required this.onSelectBranch,
    required this.onOpenSearch,
    required this.onOpenCalendar,
    required this.onOpenBackup,
  });

  final String bookName;
  final int selectedIndex;
  final int draftCount;
  final String modLabel;
  final CloudSyncSettings? syncSettings;
  final LocalSyncCursor? syncCursor;
  final VoidCallback onSwitchBook;
  final VoidCallback onAddRecord;
  final ValueChanged<int> onSelectBranch;
  final VoidCallback onOpenSearch;
  final VoidCallback onOpenCalendar;
  final VoidCallback onOpenBackup;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final syncSummary = _describeSyncStatus(syncSettings, syncCursor);

    return Column(
      children: [
        const SizedBox(height: 10),
        Tooltip(
          message: '切换账本：$bookName',
          child: IconButton.filledTonal(
            key: const Key('desktop-book-switcher'),
            onPressed: onSwitchBook,
            icon: const Icon(Icons.book_outlined, size: 20),
          ),
        ),
        const SizedBox(height: 8),
        Tooltip(
          message: '记一笔 ($modLabel+N)',
          child: Material(
            color: scheme.primary,
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: const Key('add-record'),
              onTap: onAddRecord,
              child: SizedBox(
                width: 46,
                height: 42,
                child: Icon(
                  Icons.add_rounded,
                  color: scheme.onPrimary,
                  size: 26,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: [
                _RailSlot(
                  slotKey: const Key('nav-slot-home'),
                  icon: Icons.receipt_long_outlined,
                  selectedIcon: Icons.receipt_long,
                  label: '明细',
                  selected: selectedIndex == 0,
                  onTap: () => onSelectBranch(0),
                ),
                const SizedBox(height: 6),
                _RailSlot(
                  slotKey: const Key('nav-slot-stats'),
                  icon: Icons.pie_chart_outline,
                  selectedIcon: Icons.pie_chart,
                  label: '统计',
                  selected: selectedIndex == 1,
                  onTap: () => onSelectBranch(1),
                ),
                const SizedBox(height: 6),
                _RailSlot(
                  slotKey: const Key('nav-slot-assets'),
                  icon: Icons.account_balance_wallet_outlined,
                  selectedIcon: Icons.account_balance_wallet,
                  label: '资产',
                  selected: selectedIndex == 2,
                  onTap: () => onSelectBranch(2),
                ),
                const SizedBox(height: 6),
                _RailSlot(
                  slotKey: const Key('nav-slot-more'),
                  icon: Icons.grid_view_outlined,
                  selectedIcon: Icons.grid_view_rounded,
                  label: '更多',
                  badgeCount: draftCount,
                  selected: selectedIndex == 3,
                  onTap: () => onSelectBranch(3),
                ),
              ],
            ),
          ),
        ),
        Divider(
          height: 1,
          thickness: 0.6,
          indent: 12,
          endIndent: 12,
          color: scheme.outlineVariant.withValues(alpha: 0.45),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                key: const Key('desktop-nav-search'),
                visualDensity: VisualDensity.compact,
                tooltip: '搜索账单 ($modLabel+F)',
                onPressed: onOpenSearch,
                icon: const Icon(Icons.search_rounded, size: 20),
              ),
              IconButton(
                key: const Key('desktop-nav-calendar'),
                visualDensity: VisualDensity.compact,
                tooltip: '账单日历',
                onPressed: onOpenCalendar,
                icon: const Icon(Icons.calendar_month_outlined, size: 20),
              ),
              IconButton(
                key: const Key('desktop-nav-sync-status'),
                visualDensity: VisualDensity.compact,
                tooltip: syncSummary.tooltip,
                onPressed: onOpenBackup,
                icon: Icon(
                  syncSummary.icon,
                  size: 19,
                  color: syncSummary.isCloudActive
                      ? scheme.primary
                      : scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SidebarNavTile extends StatelessWidget {
  const _SidebarNavTile({
    required this.slotKey,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.shortcutHint,
    required this.selected,
    required this.onTap,
    this.badgeCount = 0,
  });

  final Key slotKey;
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final String shortcutHint;
  final bool selected;
  final VoidCallback onTap;
  final int badgeCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    Widget leadingIcon = Icon(
      selected ? selectedIcon : icon,
      size: 20,
      color: selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant,
    );
    if (badgeCount > 0) {
      leadingIcon = Badge(label: Text('$badgeCount'), child: leadingIcon);
    }

    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? scheme.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: slotKey,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                leadingIcon,
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: selected
                          ? scheme.onSecondaryContainer
                          : scheme.onSurface,
                    ),
                  ),
                ),
                Text(
                  shortcutHint,
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontSize: 10.5,
                    color:
                        (selected
                                ? scheme.onSecondaryContainer
                                : scheme.onSurfaceVariant)
                            .withValues(alpha: 0.65),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SidebarUtilityButton extends StatelessWidget {
  const _SidebarUtilityButton({
    required this.buttonKey,
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onTap,
  });

  final Key buttonKey;
  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Tooltip(
      message: tooltip,
      child: Material(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: buttonKey,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 16, color: scheme.onSurfaceVariant),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RailSlot extends StatelessWidget {
  const _RailSlot({
    required this.slotKey,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.badgeCount = 0,
  });

  final Key slotKey;
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int badgeCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    Widget iconWidget = Icon(
      selected ? selectedIcon : icon,
      size: 21,
      color: selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant,
    );
    if (badgeCount > 0) {
      iconWidget = Badge(label: Text('$badgeCount'), child: iconWidget);
    }

    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        key: slotKey,
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 48,
                height: 28,
                decoration: BoxDecoration(
                  color: selected
                      ? scheme.secondaryContainer
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(14),
                ),
                alignment: Alignment.center,
                child: iconWidget,
              ),
              const SizedBox(height: 3),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: 11.5,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

({bool isCloudActive, IconData icon, String shortLabel, String tooltip})
_describeSyncStatus(CloudSyncSettings? settings, LocalSyncCursor? cursor) {
  final backend = settings?.backend ?? CloudBackendType.none;
  if (backend == CloudBackendType.none) {
    return (
      isCloudActive: false,
      icon: Icons.cloud_off_outlined,
      shortLabel: '本地离线 · 备份同步',
      tooltip: '纯本地离线存储（点击配置本地自动备份或 WebDAV / S3 云同步）',
    );
  }

  final lastMs = cursor?.lastSyncedAtMs;
  if (lastMs == null || lastMs <= 0) {
    return (
      isCloudActive: true,
      icon: Icons.cloud_sync_outlined,
      shortLabel: '${backend.displayLabel} · 待同步',
      tooltip: '已启用 ${backend.displayLabel} 云同步（点击查看同步与备份详情）',
    );
  }

  final dt = DateTime.fromMillisecondsSinceEpoch(lastMs);
  String pad2(int v) => v.toString().padLeft(2, '0');
  final stamp =
      '${pad2(dt.month)}-${pad2(dt.day)} ${pad2(dt.hour)}:${pad2(dt.minute)}';
  return (
    isCloudActive: true,
    icon: Icons.cloud_done_outlined,
    shortLabel: '${backend.displayLabel} · $stamp',
    tooltip: '${backend.displayLabel} 最近同步于 $stamp（点击管理）',
  );
}
