import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../data/repo/savings_queries.dart';
import '../../data/savings/savings_service.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/asset_overview.dart' show normalizeCurrency;
import '../../domain/rules/currency_rates.dart' show baseCurrency;
import '../../domain/rules/savings_plan.dart';

final savingsServiceProvider = FutureProvider<SavingsService>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return SavingsService(db);
});

final savingsQueriesProvider = FutureProvider<SavingsQueries>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return SavingsQueries(db);
});

final activeSavingsPlansProvider = StreamProvider<List<MoneySavePlan>>((
  ref,
) async* {
  final q = await ref.watch(savingsQueriesProvider.future);
  yield* q.watchPlans(status: SavingsPlanStatus.active);
});

final archivedSavingsPlansProvider = StreamProvider<List<MoneySavePlan>>((
  ref,
) async* {
  final q = await ref.watch(savingsQueriesProvider.future);
  yield* q.watchPlans(status: SavingsPlanStatus.archived);
});

final topActiveSavingsPlanProvider = StreamProvider<MoneySavePlan?>((
  ref,
) async* {
  final q = await ref.watch(savingsQueriesProvider.future);
  yield* q.watchTopActivePlan();
});

final savingsPlanProvider = StreamProvider.family<MoneySavePlan?, int>((
  ref,
  planId,
) async* {
  final q = await ref.watch(savingsQueriesProvider.future);
  yield* q.watchPlan(planId);
});

final savingsPlanRecordsProvider =
    StreamProvider.family<List<MoneySavePlanRecord>, int>((ref, planId) async* {
      final q = await ref.watch(savingsQueriesProvider.future);
      yield* q.watchPlanRecords(planId);
    });

final savingsLiveTransfersProvider = StreamProvider.family<Set<String>, int>((
  ref,
  planId,
) async* {
  final q = await ref.watch(savingsQueriesProvider.future);
  yield* q.watchLiveTransferIdsForPlan(planId);
});

final savingsActiveSummaryProvider = FutureProvider<SavingsActiveSummary>((
  ref,
) async {
  final activePlans = await ref.watch(activeSavingsPlansProvider.future);
  final currencies = await ref.watch(currenciesProvider.future);
  final rawRates = <String, String>{
    for (final c in currencies)
      if (c.enable) c.code: c.rateToAnchor,
  };
  return summarizeActiveSavingsPlans(
    plans: [
      for (final p in activePlans)
        SavingsActivePlanInput(
          id: p.id,
          savedMoneyMinor: p.savedMoneyMinor,
          currency: SavingsPlanExtra.parse(p.extraInfo).currency,
        ),
    ],
    rawRates: rawRates,
  );
});

/// Assembled detail view model for `SavingsDetailPage`.
final class SavingsPlanDetailView {
  const SavingsPlanDetailView({
    required this.plan,
    required this.currency,
    required this.currencySymbol,
    required this.fromAsset,
    required this.toAsset,
    required this.book,
    required this.schedule,
    required this.liveTransferIds,
    required this.hasAnyLinkedTransfer,
  });

  final MoneySavePlan plan;
  final String currency;
  final String currencySymbol;
  final Asset? fromAsset;
  final Asset? toAsset;
  final AccountBook? book;
  final MergedSavingsSchedule<MoneySavePlanRecord> schedule;
  final Set<String> liveTransferIds;
  final bool hasAnyLinkedTransfer;
}

String resolveCurrencySymbol(String code, Iterable<Currency> currencies) {
  final normalized = normalizeCurrency(code) ?? baseCurrency;
  for (final c in currencies) {
    if (normalizeCurrency(c.code) == normalized && c.symbol.trim().isNotEmpty) {
      return c.symbol;
    }
  }
  return normalized == 'CNY' ? '¥' : '$normalized ';
}

final savingsDetailViewProvider =
    FutureProvider.family<SavingsPlanDetailView?, int>((ref, planId) async {
      final plan = await ref.watch(savingsPlanProvider(planId).future);
      if (plan == null) return null;

      final records = await ref.watch(
        savingsPlanRecordsProvider(planId).future,
      );
      final liveTransferIds = await ref.watch(
        savingsLiveTransfersProvider(planId).future,
      );
      final assets = await ref.watch(assetsProvider.future);
      final books = await ref.watch(booksProvider.future);
      final currencies = await ref.watch(currenciesProvider.future);

      final assetMap = {for (final a in assets) a.id: a};
      final bookMap = {for (final b in books) b.id: b};

      final curr = SavingsPlanExtra.parse(plan.extraInfo).currency;
      final symbol = resolveCurrencySymbol(curr, currencies);

      final schedule = mergeSavingsSchedule<MoneySavePlanRecord>(
        planType: plan.planType,
        cycleType: plan.cycleType,
        startDateMs: plan.startDate,
        endDateMs: plan.endDate,
        startMoneyMinor: plan.startMoneyMinor,
        incrementalMinor: plan.incrementalMinor,
        records: records,
        recordDateOf: (r) => r.recordDate,
        recordIdOf: (r) => r.id,
        recordMoneyOf: (r) => r.recordMoneyMinor,
      );

      final hasLinked = records.any(
        (r) => r.recordId != null && r.recordId!.isNotEmpty,
      );

      return SavingsPlanDetailView(
        plan: plan,
        currency: curr,
        currencySymbol: symbol,
        fromAsset: plan.fromAssetId == noRef
            ? null
            : assetMap[plan.fromAssetId],
        toAsset: plan.toAssetId == noRef ? null : assetMap[plan.toAssetId],
        book: plan.bookId == noRef ? null : bookMap[plan.bookId],
        schedule: schedule,
        liveTransferIds: liveTransferIds,
        hasAnyLinkedTransfer: hasLinked,
      );
    });
