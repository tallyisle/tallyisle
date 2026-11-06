import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/db/connection.dart';
import '../data/db/database.dart';
import '../data/ledger/ledger_service.dart';
import '../data/repo/ledger_queries.dart';
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
