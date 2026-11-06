import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/db/connection.dart';
import '../data/db/database.dart';
import '../data/ledger/ledger_service.dart';
import '../data/repo/ledger_queries.dart';
import '../domain/rules/asset_overview.dart';
import '../domain/rules/billing_period.dart';
import '../domain/rules/income_expense.dart';

final databaseProvider = FutureProvider<AppDatabase>((ref) async {
  final db = await openAppDatabase();
  ref.onDispose(() => unawaited(db.close()));
  return db;
});

final ledgerServiceProvider = FutureProvider<LedgerService>(
  (ref) async => LedgerService(await ref.watch(databaseProvider.future)),
);

final queriesProvider = FutureProvider<LedgerQueries>(
  (ref) async => LedgerQueries(await ref.watch(databaseProvider.future)),
);

final currentBookIdProvider = StreamProvider<int>((ref) async* {
  final q = await ref.watch(queriesProvider.future);
  yield* q.watchCurrentBookId();
});

final booksProvider = StreamProvider<List<AccountBook>>((ref) async* {
  final q = await ref.watch(queriesProvider.future);
  yield* q.watchBooks();
});

final currentBookProvider = StreamProvider<AccountBook?>((ref) async* {
  final q = await ref.watch(queriesProvider.future);
  final id = await ref.watch(currentBookIdProvider.future);
  yield* q.watchBook(id);
});

final assetsProvider = StreamProvider<List<Asset>>((ref) async* {
  final q = await ref.watch(queriesProvider.future);
  yield* q.watchAssets();
});

final categoriesProvider = StreamProvider.family<List<RecordCategory>, int>((
  ref,
  bookId,
) async* {
  final q = await ref.watch(queriesProvider.future);
  yield* q.watchCategories(bookId);
});

final recordProvider = StreamProvider.family<LedgerRecord?, String>((
  ref,
  id,
) async* {
  final q = await ref.watch(queriesProvider.future);
  yield* q.watchRecord(id);
});

/// The month the home page shows, as an offset from the current period.
final class PeriodOffset extends Notifier<int> {
  @override
  int build() => 0;
  void previous() => state = state - 1;
  void next() => state = state + 1;
  void reset() => state = 0;
}

final periodOffsetProvider = NotifierProvider<PeriodOffset, int>(
  PeriodOffset.new,
);

final currentPeriodProvider = FutureProvider<BillingPeriod>((ref) async {
  final book = await ref.watch(currentBookProvider.future);
  final startDay = book?.startDay ?? 1;
  final offset = ref.watch(periodOffsetProvider);
  final now = BillingPeriod.containing(DateTime.now(), startDay);
  return BillingPeriod.starting(now.year, now.month + offset, startDay);
});

final periodRecordsProvider = StreamProvider<List<LedgerRecord>>((ref) async* {
  final q = await ref.watch(queriesProvider.future);
  final bookId = await ref.watch(currentBookIdProvider.future);
  final period = await ref.watch(currentPeriodProvider.future);
  yield* q.watchRecords(bookId, period.startMs, period.endMs);
});

final periodSummaryProvider = FutureProvider<IncomeExpense>((ref) async {
  final records = await ref.watch(periodRecordsProvider.future);
  return aggregateIncomeExpense(records.map(statEntryOf));
});

final assetBooksProvider = StreamProvider<List<AssetBook>>((ref) async* {
  final q = await ref.watch(queriesProvider.future);
  yield* q.watchAssetBooks();
});

final currenciesProvider = StreamProvider<List<Currency>>((ref) async* {
  final q = await ref.watch(queriesProvider.future);
  yield* q.watchCurrencies();
});

/// Accounts visible in the current book: bound to it, or bound to no book
/// (docs/modules/asset-overview.md R1).
final bookAssetsProvider = FutureProvider<List<Asset>>((ref) async {
  final assets = await ref.watch(assetsProvider.future);
  final links = await ref.watch(assetBooksProvider.future);
  final bookId = await ref.watch(currentBookIdProvider.future);
  final bound = <int, Set<int>>{};
  for (final l in links) {
    bound.putIfAbsent(l.assetId, () => {}).add(l.bookId);
  }
  return [
    for (final a in assets)
      if (bound[a.id] == null || bound[a.id]!.contains(bookId)) a,
  ];
});

final assetOverviewProvider = FutureProvider<AssetOverview>((ref) async {
  final assets = await ref.watch(bookAssetsProvider.future);
  final currencies = await ref.watch(currenciesProvider.future);
  final rates = RateTable({for (final c in currencies) c.code: c.rateToAnchor});
  return computeAssetOverview([
    for (final a in assets)
      OverviewAccount(
        id: a.id,
        type: a.type,
        subType: a.subType,
        balanceMinor: a.balanceMinor,
        isEffectiveAsset: a.isEffectiveAsset,
        status: a.status,
        currency: a.currency,
        creditInfo: a.creditInfo,
      ),
  ], rates);
});
