import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../domain/model/codes.dart';
import '../features/assets/asset_detail_page.dart';
import '../features/assets/asset_editor_page.dart';
import '../features/assets/assets_page.dart';
import '../features/attachments/bill_images_page.dart';
import '../features/automation/auto_bill_page.dart';
import '../features/automation/desktop_widgets_page.dart';
import '../features/automation/ocr_bill_page.dart';
import '../features/automation/url_scheme_page.dart';
import '../features/backup/backup_page.dart';
import '../features/backup/s3_config_page.dart';
import '../features/backup/webdav_config_page.dart';
import '../features/bank_cards/bank_card_editor_page.dart';
import '../features/bank_cards/bank_cards_page.dart';
import '../features/batch_edit/batch_edit_page.dart';
import '../features/books/books_page.dart';
import '../features/budget/budget_page.dart';
import '../features/calendar/calendar_page.dart';
import '../features/categories/categories_page.dart';
import '../features/category_transfer/category_transfer_page.dart';
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
import 'providers.dart';

/// Semantic routes (ADR-015). Mapping to the original app's 73 routes is kept
/// in docs/reference/ as modules are implemented.
GoRouter buildRouter() => GoRouter(
  initialLocation: '/',
  routes: [
    StatefulShellRoute.indexedStack(
      builder: (context, state, shell) => _Shell(shell),
      branches: [
        StatefulShellBranch(
          routes: [GoRoute(path: '/', builder: (_, _) => const HomePage())],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(path: '/stats', builder: (_, _) => const StatsPage()),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(path: '/assets', builder: (_, _) => const AssetsPage()),
          ],
        ),
        StatefulShellBranch(
          routes: [GoRoute(path: '/me', builder: (_, _) => const MePage())],
        ),
      ],
    ),
    GoRoute(path: '/budget', builder: (_, _) => const BudgetPage()),
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
      builder: (_, state) {
        final q = state.uri.queryParameters;
        return RecordEditorPage(
          initialType: int.tryParse(q['type'] ?? ''),
          initialCategory: int.tryParse(q['cat'] ?? q['category'] ?? ''),
          initialTemplateId: int.tryParse(q['templateId'] ?? ''),
          initialAsset: int.tryParse(q['asset'] ?? ''),
          initialFrom: int.tryParse(q['from'] ?? ''),
          initialTo: int.tryParse(q['to'] ?? ''),
          initialAmount: q['amount'] ?? q['money'],
          initialRemark: q['remark'] ?? q['note'],
        );
      },
    ),
    GoRoute(
      path: '/record/:id',
      builder: (_, state) =>
          RecordDetailPage(recordId: state.pathParameters['id']!),
    ),
    GoRoute(
      path: '/record/:id/edit',
      builder: (_, state) =>
          RecordEditorPage(recordId: state.pathParameters['id']!),
    ),
    GoRoute(
      path: '/assets/new',
      builder: (_, state) => AssetEditorPage(
        initialType: int.tryParse(state.uri.queryParameters['type'] ?? ''),
      ),
    ),
    GoRoute(
      path: '/assets/:id',
      builder: (_, state) =>
          AssetDetailPage(assetId: int.parse(state.pathParameters['id']!)),
    ),
    GoRoute(
      path: '/assets/:id/edit',
      builder: (_, state) =>
          AssetEditorPage(assetId: int.parse(state.pathParameters['id']!)),
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
      builder: (_, _) => const PeriodicEditorPage(),
    ),
    GoRoute(
      path: '/periodic/:id/edit',
      builder: (_, state) =>
          PeriodicEditorPage(periodId: int.parse(state.pathParameters['id']!)),
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
      builder: (_, _) => const InstallmentEditorPage(),
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
      builder: (_, state) => InstallmentEditorPage(
        installmentId: int.parse(state.pathParameters['id']!),
      ),
    ),
    GoRoute(path: '/debts', builder: (_, _) => const DebtPage()),
    GoRoute(
      path: '/debts/new',
      builder: (_, state) => DebtEditorPage(
        initialSubType: int.tryParse(
          state.uri.queryParameters['subType'] ?? '',
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
      builder: (_, state) =>
          DebtEditorPage(debtId: int.parse(state.pathParameters['id']!)),
    ),
    GoRoute(path: '/savings', builder: (_, _) => const SavingsPage()),
    GoRoute(path: '/savings/new', builder: (_, _) => const SavingsEditorPage()),
    GoRoute(
      path: '/savings/:id',
      builder: (_, state) =>
          SavingsDetailPage(planId: int.parse(state.pathParameters['id']!)),
    ),
    GoRoute(
      path: '/savings/:id/edit',
      builder: (_, state) =>
          SavingsEditorPage(planId: int.parse(state.pathParameters['id']!)),
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
      builder: (_, state) => FixedDepositEditorPage(
        initialAssetId: int.tryParse(
          state.uri.queryParameters['assetId'] ?? '',
        ),
      ),
    ),
    GoRoute(
      path: '/deposits/:assetId/:index/edit',
      builder: (_, state) => FixedDepositEditorPage(
        assetId: int.parse(state.pathParameters['assetId']!),
        depositIndex: int.parse(state.pathParameters['index']!),
      ),
    ),
    GoRoute(path: '/reminders', builder: (_, _) => const ReminderPage()),
    GoRoute(path: '/backup', builder: (_, _) => const BackupPage()),
    GoRoute(
      path: '/backup/webdav',
      builder: (_, _) => const WebDavConfigPage(),
    ),
    GoRoute(path: '/backup/s3', builder: (_, _) => const S3ConfigPage()),
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
    GoRoute(path: '/wishes/new', builder: (_, _) => const WishEditorPage()),
    GoRoute(
      path: '/wishes/:id/edit',
      builder: (_, state) => WishEditorPage(wishId: state.pathParameters['id']),
    ),
    GoRoute(path: '/notes', builder: (_, _) => const NotesPage()),
    GoRoute(path: '/notes/new', builder: (_, _) => const NoteEditorPage()),
    GoRoute(path: '/notes/trash', builder: (_, _) => const NoteTrashPage()),
    GoRoute(
      path: '/notes/:id/edit',
      builder: (_, state) =>
          NoteEditorPage(noteId: int.parse(state.pathParameters['id']!)),
    ),
    GoRoute(path: '/templates', builder: (_, _) => const TemplatesPage()),
    GoRoute(
      path: '/templates/new',
      builder: (_, state) {
        final q = state.uri.queryParameters;
        return TemplateEditorPage(
          initialBookId: int.tryParse(q['bookId'] ?? ''),
          initialType: int.tryParse(q['type'] ?? ''),
        );
      },
    ),
    GoRoute(
      path: '/templates/:id/edit',
      builder: (_, state) => TemplateEditorPage(
        templateId: int.parse(state.pathParameters['id']!),
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
      builder: (_, _) => const BankCardEditorPage(),
    ),
    GoRoute(
      path: '/bank-cards/:id/edit',
      builder: (_, state) =>
          BankCardEditorPage(cardId: int.parse(state.pathParameters['id']!)),
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
      builder: (_, _) => const AutoBillPage(),
    ),
    GoRoute(path: '/automation/ocr', builder: (_, _) => const OcrBillPage()),
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
    final scheme = Theme.of(context).colorScheme;
    final selectedIndex = shell.currentIndex;

    void goBranch(int index) {
      shell.goBranch(index, initialLocation: index == selectedIndex);
    }

    return Scaffold(
      body: shell,
      bottomNavigationBar: Material(
        color: scheme.surfaceContainer,
        surfaceTintColor: scheme.surfaceTint,
        elevation: 3,
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
                    child: Tooltip(
                      message: '记一笔',
                      child: Semantics(
                        button: true,
                        label: '记一笔',
                        child: Material(
                          color: scheme.primary,
                          borderRadius: BorderRadius.circular(14),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            key: const Key('add-record'),
                            onTap: () {
                              final defaultType =
                                  ref
                                      .read(appSettingsProvider)
                                      .value
                                      ?.defaultRecordType ??
                                  RecordType.expense;
                              context.push(
                                defaultType == RecordType.expense
                                    ? '/record/new'
                                    : '/record/new?type=$defaultType',
                              );
                            },
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

class _ShellNavSlot extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Expanded(
      child: Semantics(
        selected: selected,
        button: true,
        child: InkWell(
          key: slotKey,
          onTap: onTap,
          child: SizedBox.expand(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: 52,
                  height: 28,
                  decoration: BoxDecoration(
                    color: selected
                        ? scheme.secondaryContainer
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    selected ? selectedIcon : icon,
                    size: 22,
                    color: selected
                        ? scheme.onSecondaryContainer
                        : scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontSize: 12,
                    height: 1.1,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: selected
                        ? scheme.onSurface
                        : scheme.onSurfaceVariant,
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
