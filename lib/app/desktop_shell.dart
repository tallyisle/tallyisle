import 'dart:async';

import 'package:flutter/gestures.dart';
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
import '../features/budget/budget_providers.dart' show budgetOffsetProvider;
import '../features/records/desktop_record_editor_dialog.dart';
import '../features/security/app_lock_providers.dart';
import '../features/stats/annual_report_page.dart'
    show annualReportYearProvider;
import '../features/stats/category_stats_providers.dart'
    show
        CategoryStatsPeriodMode,
        categoryStatsOffsetProvider,
        categoryStatsPeriodModeProvider;
import '../features/stats/tag_stats_providers.dart'
    show TagStatsPeriodMode, tagStatsOffsetProvider, tagStatsPeriodModeProvider;
import 'adaptive.dart';
import 'providers.dart';

/// Resolves the actual topmost matched route location in [router], including
/// imperative routes pushed via `GoRouter.push` (`ImperativeRouteMatch`).
String topmostRouterLocation(GoRouter router) {
  final config = router.routerDelegate.currentConfiguration;
  if (config.matches.isEmpty) {
    return config.uri.path;
  }
  return config.last.matchedLocation;
}

/// Tracks whether a modal [PopupRoute] (dialog, bottom sheet, popup menu) is
/// currently pushed on the router's root navigator or any shell branch
/// navigator so global shortcuts yield cleanly.
class DesktopPopupRouteObserver extends NavigatorObserver {
  final Set<PopupRoute<dynamic>> _activePopups = <PopupRoute<dynamic>>{};

  bool get hasActivePopup => _activePopups.isNotEmpty;

  /// Creates a distinct [NavigatorObserver] instance for a nested shell branch
  /// [Navigator] that reports popup lifecycle events into this root observer.
  NavigatorObserver createChildObserver() => _ChildPopupRouteObserver(this);

  void _trackPush(Route<dynamic> route) {
    if (route is PopupRoute<dynamic>) {
      _activePopups.add(route);
    }
  }

  void _trackRemove(Route<dynamic> route) {
    if (route is PopupRoute<dynamic>) {
      _activePopups.remove(route);
    }
  }

  void _trackReplace(Route<dynamic>? newRoute, Route<dynamic>? oldRoute) {
    if (oldRoute is PopupRoute<dynamic>) {
      _activePopups.remove(oldRoute);
    }
    if (newRoute is PopupRoute<dynamic>) {
      _activePopups.add(newRoute);
    }
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _trackPush(route);
    super.didPush(route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _trackRemove(route);
    super.didPop(route, previousRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _trackRemove(route);
    super.didRemove(route, previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _trackReplace(newRoute, oldRoute);
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
  }
}

final class _ChildPopupRouteObserver extends NavigatorObserver {
  _ChildPopupRouteObserver(this._parent);

  final DesktopPopupRouteObserver _parent;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _parent._trackPush(route);
    super.didPush(route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _parent._trackRemove(route);
    super.didPop(route, previousRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _parent._trackRemove(route);
    super.didRemove(route, previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _parent._trackReplace(newRoute, oldRoute);
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
  }
}

/// Shared horizontal swipe/fling + desktop trackpad two-finger horizontal
/// scroll detector for period-based pages (`HomePage`, `BudgetPage`,
/// `CategoryStatsPage`, `TagRankingsPage`, `TagDetailStatsPage`).
class PeriodSwipeRegion extends StatefulWidget {
  const PeriodSwipeRegion({
    super.key,
    required this.child,
    required this.onPrevious,
    required this.onNext,
    this.enabled = true,
  });

  final Widget child;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final bool enabled;

  @override
  State<PeriodSwipeRegion> createState() => _PeriodSwipeRegionState();
}

class _PeriodSwipeRegionState extends State<PeriodSwipeRegion> {
  static const Duration _trackpadCooldown = Duration(milliseconds: 320);

  int? _activePointer;
  Offset? _pointerStart;
  Offset _pointerDelta = Offset.zero;
  double _horizDragDx = 0.0;
  Timer? _cooldownTimer;
  bool _inCooldown = false;

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    super.dispose();
  }

  void _startCooldown() {
    _inCooldown = true;
    _cooldownTimer?.cancel();
    _cooldownTimer = Timer(_trackpadCooldown, () {
      _inCooldown = false;
    });
  }

  void _handlePointerDown(PointerDownEvent event) {
    _activePointer = event.pointer;
    _pointerStart = event.position;
    _pointerDelta = Offset.zero;
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (event.pointer == _activePointer && _pointerStart != null) {
      _pointerDelta = event.position - _pointerStart!;
    }
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (!widget.enabled || _inCooldown) return;
    if (event is PointerScrollEvent) {
      final dx = event.scrollDelta.dx;
      final dy = event.scrollDelta.dy;
      if (dx.abs() >= 18.0 && dx.abs() > dy.abs() * 1.3) {
        _startCooldown();
        if (dx > 0) {
          widget.onNext();
        } else {
          widget.onPrevious();
        }
      }
    }
  }

  void _handlePanZoomUpdate(PointerPanZoomUpdateEvent event) {
    if (!widget.enabled || _inCooldown) return;
    final dx = event.localPan.dx;
    final dy = event.localPan.dy;
    if (dx.abs() > 48.0 && dx.abs() > dy.abs() * 1.4) {
      _startCooldown();
      if (dx > 0) {
        widget.onPrevious();
      } else {
        widget.onNext();
      }
    }
  }

  void _handleHorizontalDragEnd(DragEndDetails details) {
    final dx = _pointerStart != null ? _pointerDelta.dx : _horizDragDx;
    final dy = _pointerStart != null ? _pointerDelta.dy : 0.0;
    _pointerStart = null;
    _activePointer = null;
    _horizDragDx = 0.0;

    final vx = details.primaryVelocity ?? 0.0;
    final passedDistance = dx.abs() > 48.0 && dx.abs() > dy.abs() * 1.4;
    final passedVelocity =
        vx.abs() > 320.0 && (dy.abs() == 0.0 || dx.abs() > dy.abs() * 1.1);
    if (!passedDistance && !passedVelocity) return;

    final dirSign = passedDistance ? dx : vx;
    if (dirSign > 0) {
      widget.onPrevious();
    } else if (dirSign < 0) {
      widget.onNext();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) {
      return widget.child;
    }
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _handlePointerDown,
      onPointerMove: _handlePointerMove,
      onPointerSignal: _handlePointerSignal,
      onPointerPanZoomUpdate: _handlePanZoomUpdate,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: (_) {
          _horizDragDx = 0.0;
        },
        onHorizontalDragUpdate: (details) {
          _horizDragDx += details.primaryDelta ?? 0.0;
        },
        onHorizontalDragEnd: _handleHorizontalDragEnd,
        child: widget.child,
      ),
    );
  }
}

/// Shared entry point for opening "记一笔" using the user's configured default
/// record type (`支出` / `收入` / `转账`).
///
/// On desktop (`DesktopAdaptive.isDesktop(context)`), opens the centered
/// borderless `600px` modal dialog directly via [showDesktopRecordEditorDialog].
void openNewRecordEntry(
  BuildContext context,
  WidgetRef ref, {
  GoRouter? routerOverride,
}) {
  final defaultType =
      ref.read(appSettingsProvider).value?.defaultRecordType ??
      RecordType.expense;
  if (DesktopAdaptive.isDesktop(context)) {
    final dialogContext = Navigator.maybeOf(context) != null
        ? context
        : routerOverride?.routerDelegate.navigatorKey.currentContext;
    if (dialogContext != null) {
      unawaited(
        showDesktopRecordEditorDialog(dialogContext, initialType: defaultType),
      );
      return;
    }
  }
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

    final currentPath = topmostRouterLocation(widget.router);
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
          if (targetBranchRoute == '/stats') {
            ref.read(budgetOffsetProvider.notifier).reset();
          }
          if (currentPath != targetBranchRoute) {
            widget.router.go(targetBranchRoute);
          }
          return true;
        }
      }
    }

    // Period switching across `/`, `/calendar`, `/budget`, `/stats/category`,
    // `/stats/tags` (`/stats/tag/...`), and `/stats/annual`:
    // - Alt/⌥ + ArrowLeft / ArrowRight
    // - `[` / `]` / `T` when no text input field is focused
    if (!_isTextInputFocused()) {
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
        return _dispatchPeriodShortcut(currentPath, step: -1);
      }
      if ((altOnly && key == LogicalKeyboardKey.arrowRight) ||
          (bareKey && key == LogicalKeyboardKey.bracketRight)) {
        return _dispatchPeriodShortcut(currentPath, step: 1);
      }
      if (bareKey && key == LogicalKeyboardKey.keyT) {
        return _dispatchPeriodShortcut(currentPath, step: 0);
      }
    }

    return false;
  }

  bool _dispatchPeriodShortcut(String currentPath, {required int step}) {
    if (currentPath == '/') {
      final n = ref.read(periodOffsetProvider.notifier);
      if (step < 0) {
        n.previous();
      } else if (step > 0) {
        n.next();
      } else {
        n.reset();
      }
      return true;
    }
    if (currentPath == '/calendar') {
      final n = ref.read(calendarMonthOffsetProvider.notifier);
      if (step < 0) {
        n.previous();
      } else if (step > 0) {
        n.next();
      } else {
        n.reset();
      }
      return true;
    }
    if (currentPath == '/budget') {
      final n = ref.read(budgetOffsetProvider.notifier);
      if (step < 0) {
        n.previous();
      } else if (step > 0) {
        n.next();
      } else {
        n.reset();
      }
      return true;
    }
    if (currentPath == '/stats/category') {
      if (ref.read(categoryStatsPeriodModeProvider) ==
          CategoryStatsPeriodMode.custom) {
        return false;
      }
      final n = ref.read(categoryStatsOffsetProvider.notifier);
      if (step < 0) {
        n.previous();
      } else if (step > 0) {
        n.next();
      } else {
        n.reset();
      }
      return true;
    }
    if (currentPath == '/stats/tags' || currentPath.startsWith('/stats/tag/')) {
      if (ref.read(tagStatsPeriodModeProvider) == TagStatsPeriodMode.all) {
        return false;
      }
      final n = ref.read(tagStatsOffsetProvider.notifier);
      if (step < 0) {
        n.previous();
      } else if (step > 0) {
        n.next();
      } else {
        n.reset();
      }
      return true;
    }
    if (currentPath == '/stats/annual') {
      final n = ref.read(annualReportYearProvider.notifier);
      if (step < 0) {
        n.previous();
      } else if (step > 0) {
        n.next();
      } else {
        n.reset();
      }
      return true;
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
    if (index == 1) {
      ref.read(budgetOffsetProvider.notifier).reset();
    }
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
    final fallbackBrand =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'zh'
        ? '帐屿'
        : 'TallyIsle';
    final bookName =
        ref.watch(currentBookProvider).value?.name ?? fallbackBrand;
    final draftCount = ref.watch(autoBillDraftCountProvider);
    final syncSettings = ref.watch(cloudSyncSettingsProvider).value;
    final rawSyncCursor = ref.watch(cloudSyncCursorProvider).value;
    final davConfig = ref.watch(webDavConfigProvider).value;
    final s3Config = ref.watch(s3ConfigProvider).value;
    final activeBackend = syncSettings?.backend ?? CloudBackendType.none;
    final targetFingerprint = switch (activeBackend) {
      CloudBackendType.webdav =>
        davConfig != null && davConfig.isConfigured
            ? davConfig.targetFingerprint
            : null,
      CloudBackendType.s3 =>
        s3Config != null && s3Config.isConfigured
            ? s3Config.targetFingerprint
            : null,
      CloudBackendType.none => null,
    };
    final LocalSyncCursor? syncCursor =
        activeBackend == CloudBackendType.none ||
            targetFingerprint == null ||
            targetFingerprint.isEmpty
        ? null
        : rawSyncCursor?.scopedToTarget(targetFingerprint);
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
                        onOpenBackup: () => context.go('/me?section=%2Fbackup'),
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
        const SizedBox(height: 8),
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
                          color: syncSummary.hasConflict
                              ? scheme.error
                              : (syncSummary.isCloudActive
                                    ? scheme.primary
                                    : scheme.onSurfaceVariant),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            syncSummary.shortLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: syncSummary.hasConflict
                                  ? scheme.error
                                  : scheme.onSurfaceVariant,
                              fontWeight: syncSummary.hasConflict
                                  ? FontWeight.w600
                                  : FontWeight.w500,
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
        const SizedBox(height: 8),
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
                  color: syncSummary.hasConflict
                      ? scheme.error
                      : (syncSummary.isCloudActive
                            ? scheme.primary
                            : scheme.onSurfaceVariant),
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

({
  bool isCloudActive,
  bool hasConflict,
  IconData icon,
  String shortLabel,
  String tooltip,
})
_describeSyncStatus(CloudSyncSettings? settings, LocalSyncCursor? cursor) {
  final backend = settings?.backend ?? CloudBackendType.none;
  if (backend == CloudBackendType.none) {
    return (
      isCloudActive: false,
      hasConflict: false,
      icon: Icons.cloud_off_outlined,
      shortLabel: '本地离线 · 备份同步',
      tooltip: '纯本地离线存储（点击配置本地自动备份或 WebDAV / S3 云同步）',
    );
  }

  final conflictFile = cursor?.lastConflictFileName?.trim();
  if (conflictFile != null && conflictFile.isNotEmpty) {
    return (
      isCloudActive: true,
      hasConflict: true,
      icon: Icons.sync_problem_rounded,
      shortLabel: '检测到同步冲突 · 待处理',
      tooltip:
          '${backend.displayLabel} 检测到同步冲突 · 待处理（已归档保护 $conflictFile，点击处理）',
    );
  }

  final lastMs = cursor?.lastSyncedAtMs;
  if (cursor == null || cursor.isNeverSynced || lastMs == null || lastMs <= 0) {
    return (
      isCloudActive: true,
      hasConflict: false,
      icon: Icons.cloud_sync_outlined,
      shortLabel: '${backend.displayLabel} · 待同步',
      tooltip: '已启用 ${backend.displayLabel} 云同步（点击查看同步与备份详情）',
    );
  }

  final dt = DateTime.fromMillisecondsSinceEpoch(lastMs);
  String pad2(int v) => v.toString().padLeft(2, '0');
  final stamp =
      '${pad2(dt.month)}-${pad2(dt.day)} ${pad2(dt.hour)}:${pad2(dt.minute)}';
  final rev = cursor.lastSyncedRevision;
  return (
    isCloudActive: true,
    hasConflict: false,
    icon: Icons.cloud_done_outlined,
    shortLabel: '${backend.displayLabel} · $stamp',
    tooltip: '${backend.displayLabel} 已同步 r$rev · $stamp（点击管理）',
  );
}
