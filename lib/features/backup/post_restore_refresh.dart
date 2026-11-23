import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart'
    show ProviderBase, ProviderListenable, ProviderOrFamily, Refreshable;

import '../../app/providers.dart';
import '../../domain/rules/asset_trend.dart';
import '../attachments/attachment_providers.dart';
import '../automation/automation_providers.dart';
import '../budget/budget_providers.dart';
import '../migration/migration_providers.dart';
import '../receipt/receipt_diy_providers.dart';
import '../reimburse/reimburse_providers.dart';
import '../reminder/reminder_providers.dart';
import '../settings/settings_providers.dart';
import '../stats/annual_report_providers.dart';
import '../stats/asset_trend_providers.dart';
import '../stats/category_stats_providers.dart';
import '../stats/tag_stats_providers.dart';
import '../templates/template_providers.dart';
import 'backup_providers.dart';

/// Unified post-restore & post-sync-pull cache refresh (`S-10`):
/// 1. Clears Flutter's decoded & live image caches so replaced receipt photos
///    with identical filenames reload immediately from disk;
/// 2. Resets period offsets & transient stats/trend ID filters;
/// 3. Invalidates all cached Riverpod providers (books, accounts, categories,
///    budget alerts, data health, DIY toolbar config, stats/trend/reimburse,
///    migration summary, backup lists, and desktop widget previews);
/// 4. Best-effort syncs native platform home-screen widgets.
Future<void> invalidateAllAfterDatabaseReplace(
  WidgetRef ref, {
  bool syncPlatformWidgets = true,
}) => _invalidateAllAfterDatabaseReplaceImpl(
  invalidate: ref.invalidate,
  read: ref.read,
  exists: ref.exists,
  syncPlatformWidgets: syncPlatformWidgets,
);

/// Container-scoped variant of [invalidateAllAfterDatabaseReplace] for headless
/// service/provider tests and non-widget callers.
Future<void> invalidateAllAfterDatabaseReplaceForContainer(
  ProviderContainer container, {
  bool syncPlatformWidgets = true,
}) => _invalidateAllAfterDatabaseReplaceImpl(
  invalidate: container.invalidate,
  read: container.read,
  exists: container.exists,
  syncPlatformWidgets: syncPlatformWidgets,
);

Future<void> _invalidateAllAfterDatabaseReplaceImpl({
  required void Function(ProviderOrFamily provider) invalidate,
  required T Function<T>(ProviderListenable<T> provider) read,
  required bool Function(ProviderBase<Object?> provider) exists,
  required bool syncPlatformWidgets,
}) async {
  try {
    final imageCache = PaintingBinding.instance.imageCache;
    imageCache.clear();
    imageCache.clearLiveImages();
  } catch (_) {
    // Safe when PaintingBinding is not initialized in pure Dart unit tests.
  }

  void safeReset<N>(Refreshable<N> notifierProvider, void Function(N) reset) {
    try {
      reset(read(notifierProvider));
    } catch (_) {}
  }

  safeReset(periodOffsetProvider.notifier, (n) => n.reset());
  safeReset(calendarMonthOffsetProvider.notifier, (n) => n.reset());
  safeReset(budgetOffsetProvider.notifier, (n) => n.reset());
  safeReset(categoryStatsOffsetProvider.notifier, (n) => n.reset());
  safeReset(categoryStatsFilterConfigProvider.notifier, (n) => n.reset());
  safeReset(tagStatsOffsetProvider.notifier, (n) => n.reset());
  safeReset(
    trendFilterProvider.notifier,
    (n) => n.setFilter(const AssetTrendFilter.allEffective()),
  );

  final providersToInvalidate = <ProviderOrFamily>[
    // Backup & sync state
    localBackupsProvider,
    webDavBackupsProvider,
    s3BackupsProvider,
    activeCloudBackupsProvider,
    cloudSyncCursorProvider,
    lastBackupAtMsProvider,
    // Core books, accounts, categories, currencies & tags
    currentBookIdProvider,
    booksProvider,
    currentBookProvider,
    assetsProvider,
    assetProvider,
    assetBooksProvider,
    bookAssetsProvider,
    assetOverviewProvider,
    categoriesProvider,
    allCategoriesProvider,
    activeCategoriesProvider,
    allBookCategoriesMapProvider,
    currenciesProvider,
    rateTableProvider,
    tagsProvider,
    activeTagsProvider,
    recordTagsProvider,
    // Home & calendar records
    currentPeriodProvider,
    periodRecordsProvider,
    periodSummaryProvider,
    calendarRecordsForOffsetProvider,
    calendarRecordsProvider,
    // Attachments & DIY toolbar config
    attachmentBytesProvider,
    recordsWithImagesProvider,
    orphanAttachmentScanProvider,
    diyToolbarConfigProvider,
    // Budget overviews & real-time record editor budget alert hints
    budgetModeProvider,
    budgetPeriodForOffsetProvider,
    budgetPeriodProvider,
    budgetSectionForOffsetProvider,
    budgetSectionProvider,
    budgetsForOffsetProvider,
    currentBudgetsProvider,
    budgetPeriodRecordsForOffsetProvider,
    budgetPeriodRecordsProvider,
    budgetOverviewForOffsetProvider,
    budgetOverviewProvider,
    recordBudgetHintProvider,
    // Data health & settings
    dataHealthReportProvider,
    statStoriesProvider,
    appSettingsProvider,
    // Category / Tag / Trend / Annual stats & Reimburse
    categoryStatsActivePeriodProvider,
    categoryStatsAnalyzeFilterProvider,
    categoryStatsPreviousPeriodProvider,
    categoryStatsRecordsProvider,
    categoryStatsPreviousPeriodRecordsProvider,
    categoryStatsCategoriesProvider,
    categoryStatsResultProvider,
    statsHubCategoryOverviewProvider,
    trendAccountsProvider,
    trendBooksProvider,
    trendBookStartDaysProvider,
    trendRateTableProvider,
    trendRecordsProvider,
    trendModePreferenceProvider,
    assetDistributionProvider,
    assetTrendResultProvider,
    tagStatsCurrentBookIdProvider,
    tagStatsCurrentBookProvider,
    tagStatsAllTagsProvider,
    tagStatsCategoriesProvider,
    tagStatsAssetsProvider,
    tagStatsBaseCurrencyProvider,
    tagRecordCountsProvider,
    tagRankingsViewProvider,
    statsHubTagRankingsProvider,
    tagDetailViewProvider,
    annualAvailableYearsProvider,
    annualReportDataProvider,
    reimburseRawRecordsProvider,
    reimburseAllCategoriesProvider,
    reimburseViewProvider,
    // Templates, remarks, reminders, migration & automation widgets
    templatesQueryProvider,
    templatesByBookProvider,
    remarksForCategoryProvider,
    allRemarksProvider,
    remindersProvider,
    reminderCountProvider,
    migrationLocalSummaryProvider,
    widgetSnapshotProvider,
    activeWidgetCountsProvider,
    autoMapRulesProvider,
    autoBillDraftsProvider,
  ];

  for (final p in providersToInvalidate) {
    try {
      invalidate(p);
    } catch (_) {}
  }

  if (syncPlatformWidgets && exists(databaseProvider)) {
    try {
      final widgetService = await read(widgetSnapshotServiceProvider.future);
      await widgetService.syncToPlatform();
    } catch (_) {
      // Non-blocking widget snapshot sync.
    }
  }
}
