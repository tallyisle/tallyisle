import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/assets/asset_detail_page.dart';
import '../features/assets/asset_editor_page.dart';
import '../features/assets/assets_page.dart';
import '../features/attachments/bill_images_page.dart';
import '../features/automation/auto_bill_page.dart';
import '../features/automation/desktop_widgets_page.dart';
import '../features/automation/mcp_settings_page.dart';
import '../features/automation/ocr_bill_page.dart';
import '../features/automation/smart_quick_sheet.dart';
import '../features/automation/url_scheme_page.dart';
import '../features/backup/backup_page.dart';
import '../features/backup/s3_config_page.dart';
import '../features/backup/webdav_config_page.dart';
import '../features/bank_cards/bank_card_editor_page.dart';
import '../features/bank_cards/bank_cards_page.dart';
import '../features/batch_edit/batch_edit_page.dart';
import '../features/books/books_page.dart';
import '../features/budget/budget_page.dart';
import '../features/budget/budget_providers.dart' show budgetOffsetProvider;
import '../features/calendar/calendar_page.dart';
import '../features/categories/categories_page.dart';
import '../features/category_transfer/category_transfer_page.dart';
import '../features/common/desktop_modal_page.dart';
import '../features/csv_transfer/csv_export_page.dart';
import '../features/csv_transfer/csv_import_page.dart';
import '../features/csv_transfer/import_batches_page.dart';
import '../features/currencies/currencies_page.dart';
import '../features/debt/debt_detail_page.dart';
import '../features/debt/debt_editor_page.dart';
import '../features/debt/debt_page.dart';
import '../features/deposit/fixed_deposit_editor_page.dart';
import '../features/deposit/fixed_deposit_page.dart';
import '../features/home/home_page.dart';
import '../features/installment/installment_detail_page.dart';
import '../features/installment/installment_editor_page.dart';
import '../features/installment/installment_page.dart';
import '../features/me/me_page.dart';
import '../features/migration/migration_page.dart';
import '../features/notes/note_editor_page.dart';
import '../features/notes/note_trash_page.dart';
import '../features/notes/notes_page.dart';
import '../features/periodic/periodic_editor_page.dart';
import '../features/periodic/periodic_page.dart';
import '../features/receipt/diy_toolbar_settings_page.dart';
import '../features/records/desktop_record_editor_dialog.dart';
import '../features/records/record_detail_page.dart';
import '../features/records/record_editor_page.dart';
import '../features/reimburse/reimburse_page.dart';
import '../features/reminder/reminder_page.dart';
import '../features/savings/savings_detail_page.dart';
import '../features/savings/savings_editor_page.dart';
import '../features/savings/savings_page.dart';
import '../features/search/search_page.dart';
import '../features/security/app_lock_settings_page.dart';
import '../features/settings/about_help_page.dart';
import '../features/settings/data_health_page.dart';
import '../features/settings/settings_page.dart';
import '../features/settings/stat_stories_page.dart';
import '../features/stats/annual_report_page.dart';
import '../features/stats/asset_trend_page.dart';
import '../features/stats/category_stats_page.dart';
import '../features/stats/stats_page.dart';
import '../features/stats/tag_stats_page.dart';
import '../features/tags/tags_page.dart';
import '../features/templates/template_editor_page.dart';
import '../features/templates/templates_page.dart';
import '../features/wishes/wish_editor_page.dart';
import '../features/wishes/wishes_page.dart';
import 'adaptive.dart';
import 'desktop_shell.dart';
import 'providers.dart';

Page<Object?> _adaptiveFormPage(
  BuildContext context,
  GoRouterState state,
  Widget child,
) => buildDesktopModalOrMaterialPage<Object?>(
  context: context,
  key: state.pageKey,
  name: state.name ?? state.path,
  arguments: <String, String>{
    ...state.pathParameters,
    ...state.uri.queryParameters,
  },
  restorationId: state.pageKey.value,
  child: child,
);

Page<Object?> _adaptiveRecordDetailPage(
  BuildContext context,
  GoRouterState state,
  Widget child,
) {
  final args = <String, String>{
    ...state.pathParameters,
    ...state.uri.queryParameters,
  };
  if (DesktopAdaptive.isExpandedDesktop(context)) {
    return buildDesktopModalOrMaterialPage<Object?>(
      context: context,
      key: state.pageKey,
      name: state.name ?? state.path,
      arguments: args,
      restorationId: state.pageKey.value,
      maxWidth: 560,
      maxHeight: 740,
      child: child,
    );
  }
  return NoTransitionPage<Object?>(
    key: state.pageKey,
    name: state.name ?? state.path,
    arguments: args,
    restorationId: state.pageKey.value,
    child: child,
  );
}

/// Semantic application routes (ADR-015).
GoRouter buildRouter({
  List<NavigatorObserver>? observers,
  DesktopPopupRouteObserver? popupObserver,
}) => GoRouter(
  initialLocation: '/',
  observers: observers,
  routes: [
    StatefulShellRoute.indexedStack(
      builder: (context, state, shell) => _Shell(shell),
      branches: [
        StatefulShellBranch(
          observers: popupObserver == null
              ? null
              : <NavigatorObserver>[popupObserver.createChildObserver()],
          routes: [GoRoute(path: '/', builder: (_, _) => const HomePage())],
        ),
        StatefulShellBranch(
          observers: popupObserver == null
              ? null
              : <NavigatorObserver>[popupObserver.createChildObserver()],
          routes: [
            GoRoute(path: '/stats', builder: (_, _) => const StatsPage()),
          ],
        ),
        StatefulShellBranch(
          observers: popupObserver == null
              ? null
              : <NavigatorObserver>[popupObserver.createChildObserver()],
          routes: [
            GoRoute(path: '/assets', builder: (_, _) => const AssetsPage()),
          ],
        ),
        StatefulShellBranch(
          observers: popupObserver == null
              ? null
              : <NavigatorObserver>[popupObserver.createChildObserver()],
          routes: [GoRoute(path: '/me', builder: (_, _) => const MePage())],
        ),
      ],
    ),
    GoRoute(
      path: '/budget',
      builder: (_, state) => BudgetPage(
        initialOffset: int.tryParse(
          state.uri.queryParameters['initialOffset'] ?? '',
        ),
      ),
    ),
    GoRoute(
      path: '/stats/category',
      builder: (_, _) => const CategoryStatsPage(),
    ),
    GoRoute(
      path: '/stats/category/:id',
      builder: (_, state) => CategoryRouteDrilldownPage(
        categoryId: int.parse(state.pathParameters['id']!),
      ),
    ),
    GoRoute(path: '/stats/tags', builder: (_, _) => const TagRankingsPage()),
    GoRoute(
      path: '/stats/tag/:id',
      builder: (_, state) =>
          TagDetailStatsPage(tagId: state.pathParameters['id']!),
    ),
    GoRoute(
      path: '/stats/trend',
      builder: (_, state) => AssetTrendPage(
        initialAssetId: int.tryParse(
          state.uri.queryParameters['assetId'] ?? '',
        ),
      ),
    ),
    GoRoute(
      path: '/stats/annual',
      builder: (context, state) {
        final q = state.uri.queryParameters;
        return AnnualReportPage(
          initialYear: int.tryParse(q['year'] ?? ''),
          initialBookId: int.tryParse(q['bookId'] ?? ''),
          onRecordTap: (id) => context.push('/record/$id'),
        );
      },
    ),
    GoRoute(
      path: '/record/new',
      pageBuilder: (context, state) {
        final q = state.uri.queryParameters;
        final initialType = int.tryParse(q['type'] ?? '');
        final initialCategory = int.tryParse(q['cat'] ?? q['category'] ?? '');
        final initialTemplateId = int.tryParse(q['templateId'] ?? '');
        final initialAsset = int.tryParse(q['asset'] ?? q['assetId'] ?? '');
        final initialFrom = int.tryParse(q['from'] ?? '');
        final initialTo = int.tryParse(q['to'] ?? '');
        final initialAmount = q['amount'] ?? q['money'];
        final initialRemark = q['remark'] ?? q['note'];
        final initialRecordTimeMs = int.tryParse(q['time'] ?? '');
        final args = <String, String>{...state.pathParameters, ...q};
        if (DesktopAdaptive.useCenteredModalDialog(context)) {
          return DesktopRecordDialogPage<Object?>(
            key: state.pageKey,
            name: state.name ?? state.path,
            arguments: args,
            restorationId: state.pageKey.value,
            initialType: initialType,
            initialCategory: initialCategory,
            initialTemplateId: initialTemplateId,
            initialAssetId: initialAsset,
            initialFrom: initialFrom,
            initialTo: initialTo,
            initialAmount: initialAmount,
            initialRemark: initialRemark,
            initialRecordTimeMs: initialRecordTimeMs,
          );
        }
        return NoTransitionPage<Object?>(
          key: state.pageKey,
          name: state.name ?? state.path,
          arguments: args,
          restorationId: state.pageKey.value,
          child: RecordEditorPage(
            initialType: initialType,
            initialCategory: initialCategory,
            initialTemplateId: initialTemplateId,
            initialAsset: initialAsset,
            initialFrom: initialFrom,
            initialTo: initialTo,
            initialAmount: initialAmount,
            initialRemark: initialRemark,
            initialRecordTimeMs: initialRecordTimeMs,
          ),
        );
      },
    ),
    GoRoute(
      path: '/record/:id',
      pageBuilder: (context, state) => _adaptiveRecordDetailPage(
        context,
        state,
        RecordDetailPage(recordId: state.pathParameters['id']!),
      ),
    ),
    GoRoute(
      path: '/record/:id/edit',
      pageBuilder: (context, state) {
        final recordId = state.pathParameters['id']!;
        final args = <String, String>{
          ...state.pathParameters,
          ...state.uri.queryParameters,
        };
        if (DesktopAdaptive.useCenteredModalDialog(context)) {
          return DesktopRecordDialogPage<Object?>(
            key: state.pageKey,
            name: state.name ?? state.path,
            arguments: args,
            restorationId: state.pageKey.value,
            recordId: recordId,
          );
        }
        return NoTransitionPage<Object?>(
          key: state.pageKey,
          name: state.name ?? state.path,
          arguments: args,
          restorationId: state.pageKey.value,
          child: RecordEditorPage(recordId: recordId),
        );
      },
    ),
    GoRoute(
      path: '/assets/manage',
      pageBuilder: (context, state) => buildDesktopModalOrMaterialPage<Object?>(
        context: context,
        key: state.pageKey,
        name: state.name ?? state.path,
        arguments: <String, String>{
          ...state.pathParameters,
          ...state.uri.queryParameters,
        },
        restorationId: state.pageKey.value,
        maxWidth: 860,
        maxHeight: 740,
        child: const AssetsPage(standaloneManagement: true),
      ),
    ),
    GoRoute(
      path: '/assets/new',
      pageBuilder: (context, state) => _adaptiveFormPage(
        context,
        state,
        AssetEditorPage(
          initialType: int.tryParse(state.uri.queryParameters['type'] ?? ''),
        ),
      ),
    ),
    GoRoute(
      path: '/assets/:id',
      builder: (_, state) =>
          AssetDetailPage(assetId: int.parse(state.pathParameters['id']!)),
    ),
    GoRoute(
      path: '/assets/:id/edit',
      pageBuilder: (context, state) => _adaptiveFormPage(
        context,
        state,
        AssetEditorPage(assetId: int.parse(state.pathParameters['id']!)),
      ),
    ),
    GoRoute(path: '/search', builder: (_, _) => const SearchPage()),
    GoRoute(path: '/calendar', builder: (_, _) => const CalendarPage()),
    GoRoute(path: '/books', builder: (_, _) => const BooksPage()),
    GoRoute(path: '/categories', builder: (_, _) => const CategoriesPage()),
    GoRoute(path: '/tags', builder: (_, _) => const TagsPage()),
    GoRoute(path: '/currencies', builder: (_, _) => const CurrenciesPage()),
    GoRoute(
      path: '/reimburse',
      builder: (context, _) =>
          ReimbursePage(onRecordTap: (id) => context.push('/record/$id')),
    ),
    GoRoute(
      path: '/periodic',
      builder: (context, _) =>
          PeriodicPage(onRecordTap: (id) => context.push('/record/$id')),
    ),
    GoRoute(
      path: '/periodic/new',
      pageBuilder: (context, state) =>
          _adaptiveFormPage(context, state, const PeriodicEditorPage()),
    ),
    GoRoute(
      path: '/periodic/:id/edit',
      pageBuilder: (context, state) => _adaptiveFormPage(
        context,
        state,
        PeriodicEditorPage(periodId: int.parse(state.pathParameters['id']!)),
      ),
    ),
    GoRoute(
      path: '/periodic/:id/history',
      builder: (context, state) => PeriodicHistoryPage(
        periodId: int.parse(state.pathParameters['id']!),
        onRecordTap: (id) => context.push('/record/$id'),
      ),
    ),
    GoRoute(
      path: '/installments',
      builder: (context, _) =>
          InstallmentPage(onRecordTap: (id) => context.push('/record/$id')),
    ),
    GoRoute(
      path: '/installments/new',
      pageBuilder: (context, state) =>
          _adaptiveFormPage(context, state, const InstallmentEditorPage()),
    ),
    GoRoute(
      path: '/installments/:id',
      builder: (context, state) => InstallmentDetailPage(
        installmentId: int.parse(state.pathParameters['id']!),
        onRecordTap: (id) => context.push('/record/$id'),
      ),
    ),
    GoRoute(
      path: '/installments/:id/edit',
      pageBuilder: (context, state) => _adaptiveFormPage(
        context,
        state,
        InstallmentEditorPage(
          installmentId: int.parse(state.pathParameters['id']!),
        ),
      ),
    ),
    GoRoute(path: '/debts', builder: (_, _) => const DebtPage()),
    GoRoute(
      path: '/debts/new',
      pageBuilder: (context, state) => _adaptiveFormPage(
        context,
        state,
        DebtEditorPage(
          initialSubType: int.tryParse(
            state.uri.queryParameters['subType'] ?? '',
          ),
        ),
      ),
    ),
    GoRoute(
      path: '/debts/:id',
      builder: (_, state) =>
          DebtDetailPage(debtId: int.parse(state.pathParameters['id']!)),
    ),
    GoRoute(
      path: '/debts/:id/edit',
      pageBuilder: (context, state) => _adaptiveFormPage(
        context,
        state,
        DebtEditorPage(debtId: int.parse(state.pathParameters['id']!)),
      ),
    ),
    GoRoute(path: '/savings', builder: (_, _) => const SavingsPage()),
    GoRoute(
      path: '/savings/new',
      pageBuilder: (context, state) =>
          _adaptiveFormPage(context, state, const SavingsEditorPage()),
    ),
    GoRoute(
      path: '/savings/:id',
      builder: (_, state) =>
          SavingsDetailPage(planId: int.parse(state.pathParameters['id']!)),
    ),
    GoRoute(
      path: '/savings/:id/edit',
      pageBuilder: (context, state) => _adaptiveFormPage(
        context,
        state,
        SavingsEditorPage(planId: int.parse(state.pathParameters['id']!)),
      ),
    ),
    GoRoute(
      path: '/deposits',
      builder: (context, state) => FixedDepositPage(
        initialAssetId: int.tryParse(
          state.uri.queryParameters['assetId'] ?? '',
        ),
        onRecordTap: (id) => context.push('/record/$id'),
      ),
    ),
    GoRoute(
      path: '/deposits/new',
      pageBuilder: (context, state) => _adaptiveFormPage(
        context,
        state,
        FixedDepositEditorPage(
          initialAssetId: int.tryParse(
            state.uri.queryParameters['assetId'] ?? '',
          ),
        ),
      ),
    ),
    GoRoute(
      path: '/deposits/:assetId/:index/edit',
      pageBuilder: (context, state) => _adaptiveFormPage(
        context,
        state,
        FixedDepositEditorPage(
          assetId: int.parse(state.pathParameters['assetId']!),
          depositIndex: int.parse(state.pathParameters['index']!),
        ),
      ),
    ),
    GoRoute(path: '/reminders', builder: (_, _) => const ReminderPage()),
    GoRoute(path: '/backup', builder: (_, _) => const BackupPage()),
    GoRoute(
      path: '/backup/webdav',
      pageBuilder: (context, state) =>
          _adaptiveFormPage(context, state, const WebDavConfigPage()),
    ),
    GoRoute(
      path: '/backup/s3',
      pageBuilder: (context, state) =>
          _adaptiveFormPage(context, state, const S3ConfigPage()),
    ),
    GoRoute(path: '/import/csv', builder: (_, _) => const CsvImportPage()),
    GoRoute(
      path: '/import/batches',
      builder: (_, _) => const ImportBatchesPage(),
    ),
    GoRoute(
      path: '/import/batches/:id',
      builder: (_, state) => ImportBatchDetailPage(
        batchId: int.parse(state.pathParameters['id']!),
      ),
    ),
    GoRoute(path: '/export/csv', builder: (_, _) => const CsvExportPage()),
    GoRoute(path: '/import/penny', builder: (_, _) => const MigrationPage()),
    GoRoute(path: '/migration', builder: (_, _) => const MigrationPage()),
    GoRoute(path: '/wishes', builder: (_, _) => const WishesPage()),
    GoRoute(
      path: '/wishes/new',
      pageBuilder: (context, state) =>
          _adaptiveFormPage(context, state, const WishEditorPage()),
    ),
    GoRoute(
      path: '/wishes/:id/edit',
      pageBuilder: (context, state) => _adaptiveFormPage(
        context,
        state,
        WishEditorPage(wishId: state.pathParameters['id']),
      ),
    ),
    GoRoute(path: '/notes', builder: (_, _) => const NotesPage()),
    GoRoute(
      path: '/notes/new',
      pageBuilder: (context, state) =>
          _adaptiveFormPage(context, state, const NoteEditorPage()),
    ),
    GoRoute(path: '/notes/trash', builder: (_, _) => const NoteTrashPage()),
    GoRoute(
      path: '/notes/:id/edit',
      pageBuilder: (context, state) => _adaptiveFormPage(
        context,
        state,
        NoteEditorPage(noteId: int.parse(state.pathParameters['id']!)),
      ),
    ),
    GoRoute(path: '/templates', builder: (_, _) => const TemplatesPage()),
    GoRoute(
      path: '/templates/new',
      pageBuilder: (context, state) {
        final q = state.uri.queryParameters;
        return _adaptiveFormPage(
          context,
          state,
          TemplateEditorPage(
            initialBookId: int.tryParse(q['bookId'] ?? ''),
            initialType: int.tryParse(q['type'] ?? ''),
          ),
        );
      },
    ),
    GoRoute(
      path: '/templates/:id/edit',
      pageBuilder: (context, state) => _adaptiveFormPage(
        context,
        state,
        TemplateEditorPage(templateId: int.parse(state.pathParameters['id']!)),
      ),
    ),
    GoRoute(
      path: '/remarks',
      builder: (_, state) => RemarksPage(
        initialCategoryId: int.tryParse(
          state.uri.queryParameters['categoryId'] ?? '',
        ),
      ),
    ),
    GoRoute(path: '/bank-cards', builder: (_, _) => const BankCardsPage()),
    GoRoute(
      path: '/bank-cards/new',
      pageBuilder: (context, state) =>
          _adaptiveFormPage(context, state, const BankCardEditorPage()),
    ),
    GoRoute(
      path: '/bank-cards/:id/edit',
      pageBuilder: (context, state) => _adaptiveFormPage(
        context,
        state,
        BankCardEditorPage(cardId: int.parse(state.pathParameters['id']!)),
      ),
    ),
    GoRoute(
      path: '/categories/transfer',
      builder: (_, state) {
        final q = state.uri.queryParameters;
        return CategoryTransferPage(
          initialBookId: int.tryParse(q['bookId'] ?? ''),
          initialTab: int.tryParse(q['tab'] ?? '') ?? 0,
        );
      },
    ),
    GoRoute(
      path: '/records/batch',
      builder: (_, state) => BatchEditPage(
        initialBookId: int.tryParse(state.uri.queryParameters['bookId'] ?? ''),
      ),
    ),
    GoRoute(path: '/attachments', builder: (_, _) => const BillImagesPage()),
    GoRoute(
      path: '/settings/diy-toolbar',
      builder: (_, _) => const DiyToolbarSettingsPage(),
    ),
    GoRoute(
      path: '/security/app-lock',
      builder: (_, _) => const AppLockSettingsPage(),
    ),
    GoRoute(path: '/settings', builder: (_, _) => const SettingsPage()),
    GoRoute(
      path: '/settings/data-health',
      builder: (_, _) => const DataHealthPage(),
    ),
    GoRoute(path: '/stat-stories', builder: (_, _) => const StatStoriesPage()),
    GoRoute(path: '/about', builder: (_, _) => const AboutHelpPage()),
    GoRoute(
      path: '/automation/url-scheme',
      builder: (_, _) => const UrlSchemePage(),
    ),
    GoRoute(
      path: '/automation/widgets',
      builder: (_, _) => const DesktopWidgetsPage(),
    ),
    GoRoute(
      path: '/automation/auto-bill',
      builder: (_, state) => AutoBillPage(
        initialDraftId: int.tryParse(
          state.uri.queryParameters['draftId'] ?? '',
        ),
      ),
    ),
    GoRoute(
      path: '/automation/smart-bill',
      pageBuilder: (context, state) {
        final q = state.uri.queryParameters;
        final clipRaw = q['clipboard']?.trim().toLowerCase();
        final readClipboard =
            clipRaw == '1' || clipRaw == 'true' || clipRaw == 'yes';
        return _adaptiveFormPage(
          context,
          state,
          SmartQuickBillPage(
            initialText: q['text'],
            readClipboardOnOpen: readClipboard,
            sourceApp: q['app'],
          ),
        );
      },
    ),
    GoRoute(path: '/automation/ocr', builder: (_, _) => const OcrBillPage()),
    GoRoute(
      path: '/automation/mcp',
      builder: (_, _) => const McpSettingsPage(),
    ),
  ],
);

class _Shell extends ConsumerWidget {
  const _Shell(this.shell);
  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(
      appSettingsProvider.select(
        (asyncVal) => asyncVal.value?.defaultRecordType,
      ),
    );
    if (DesktopAdaptive.useSideNavigation(context)) {
      return DesktopNavigationScaffold(shell: shell);
    }

    final scheme = Theme.of(context).colorScheme;
    final selectedIndex = shell.currentIndex;

    void goBranch(int index) {
      if (index == 1) {
        ref.read(budgetOffsetProvider.notifier).reset();
      }
      shell.goBranch(index, initialLocation: index == selectedIndex);
    }

    return Scaffold(
      body: shell,
      bottomNavigationBar: Material(
        color: scheme.brightness == Brightness.dark
            ? scheme.surfaceContainer
            : scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        child: SafeArea(
          top: false,
          child: SizedBox(
            key: const Key('shell-bottom-bar'),
            height: 64,
            child: Row(
              children: [
                _ShellNavSlot(
                  slotKey: const Key('nav-slot-home'),
                  icon: Icons.receipt_long_outlined,
                  selectedIcon: Icons.receipt_long,
                  label: '明细',
                  selected: selectedIndex == 0,
                  onTap: () => goBranch(0),
                ),
                _ShellNavSlot(
                  slotKey: const Key('nav-slot-stats'),
                  icon: Icons.pie_chart_outline,
                  selectedIcon: Icons.pie_chart,
                  label: '统计',
                  selected: selectedIndex == 1,
                  onTap: () => goBranch(1),
                ),
                Expanded(
                  child: Center(
                    child: _ShellAddRecordButton(
                      onTap: () => openNewRecordEntry(context, ref),
                    ),
                  ),
                ),
                _ShellNavSlot(
                  slotKey: const Key('nav-slot-assets'),
                  icon: Icons.account_balance_wallet_outlined,
                  selectedIcon: Icons.account_balance_wallet,
                  label: '资产',
                  selected: selectedIndex == 2,
                  onTap: () => goBranch(2),
                ),
                _ShellNavSlot(
                  slotKey: const Key('nav-slot-more'),
                  icon: Icons.grid_view_outlined,
                  selectedIcon: Icons.grid_view_rounded,
                  label: '更多',
                  selected: selectedIndex == 3,
                  onTap: () => goBranch(3),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ShellAddRecordButton extends StatefulWidget {
  const _ShellAddRecordButton({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_ShellAddRecordButton> createState() => _ShellAddRecordButtonState();
}

class _ShellAddRecordButtonState extends State<_ShellAddRecordButton> {
  bool _pressed = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fillColor = Color.lerp(
      scheme.primary,
      scheme.onPrimary,
      _pressed ? 0.14 : (_hovered ? 0.06 : 0.0),
    )!;
    return Tooltip(
      message: '记一笔',
      child: Semantics(
        button: true,
        label: '记一笔',
        child: AnimatedScale(
          scale: _pressed ? 0.92 : 1.0,
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOutCubic,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: fillColor,
              borderRadius: BorderRadius.circular(14),
            ),
            child: InkWell(
              key: const Key('add-record'),
              borderRadius: BorderRadius.circular(14),
              splashFactory: NoSplash.splashFactory,
              overlayColor: const WidgetStatePropertyAll<Color>(
                Colors.transparent,
              ),
              splashColor: Colors.transparent,
              highlightColor: Colors.transparent,
              hoverColor: Colors.transparent,
              focusColor: Colors.transparent,
              onHighlightChanged: (value) {
                if (_pressed != value) setState(() => _pressed = value);
              },
              onHover: (value) {
                if (_hovered != value) setState(() => _hovered = value);
              },
              onTap: widget.onTap,
              child: SizedBox(
                width: 46,
                height: 40,
                child: Icon(
                  Icons.add_rounded,
                  color: scheme.onPrimary,
                  size: 28,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ShellNavSlot extends StatefulWidget {
  const _ShellNavSlot({
    required this.slotKey,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final Key slotKey;
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_ShellNavSlot> createState() => _ShellNavSlotState();
}

class _ShellNavSlotState extends State<_ShellNavSlot> {
  bool _pressed = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    final activeForeground = isDark
        ? scheme.onPrimaryContainer
        : scheme.primary;
    final Color pillColor;
    if (widget.selected) {
      pillColor = isDark
          ? Color.lerp(
              scheme.surfaceContainerHigh,
              scheme.primaryContainer,
              _pressed ? 0.72 : 0.56,
            )!
          : Color.lerp(
              scheme.surfaceContainerLowest,
              scheme.primaryContainer,
              _pressed ? 0.84 : 0.70,
            )!;
    } else if (_pressed) {
      pillColor = scheme.primary.withValues(alpha: isDark ? 0.16 : 0.10);
    } else if (_hovered) {
      pillColor = scheme.onSurface.withValues(alpha: 0.06);
    } else {
      pillColor = Colors.transparent;
    }
    final foregroundColor = widget.selected
        ? activeForeground
        : (_pressed ? scheme.onSurface : scheme.onSurfaceVariant);

    return Expanded(
      child: Semantics(
        selected: widget.selected,
        button: true,
        child: InkWell(
          key: widget.slotKey,
          splashFactory: NoSplash.splashFactory,
          overlayColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          hoverColor: Colors.transparent,
          focusColor: Colors.transparent,
          onHighlightChanged: (value) {
            if (_pressed != value) setState(() => _pressed = value);
          },
          onHover: (value) {
            if (_hovered != value) setState(() => _hovered = value);
          },
          onTap: widget.onTap,
          child: SizedBox.expand(
            child: AnimatedScale(
              scale: _pressed ? 0.92 : 1.0,
              duration: const Duration(milliseconds: 110),
              curve: Curves.easeOutCubic,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    curve: Curves.easeOutCubic,
                    width: 52,
                    height: 28,
                    decoration: BoxDecoration(
                      color: pillColor,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      widget.selected ? widget.selectedIcon : widget.icon,
                      size: 22,
                      color: foregroundColor,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 12,
                      height: 1.1,
                      fontWeight: widget.selected
                          ? FontWeight.w600
                          : FontWeight.w500,
                      color: foregroundColor,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
