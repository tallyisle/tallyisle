import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../data/debt/debt_service.dart';
import '../../data/repo/debt_queries.dart';
import '../../domain/ledger/record_extra.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/debt_rules.dart';

final debtServiceProvider = FutureProvider<DebtService>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return DebtService(db);
});

final debtQueriesProvider = FutureProvider<DebtQueries>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return DebtQueries(db);
});

/// `false` = current book (`CE-DM-06`), `true` = all books.
final class DebtAllBooksScopeNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;
  void setAllBooks(bool allBooks) => state = allBooks;
}

final debtAllBooksScopeProvider =
    NotifierProvider<DebtAllBooksScopeNotifier, bool>(
      DebtAllBooksScopeNotifier.new,
    );

/// Active tab on `DebtPage`: `AssetStatus.active` (`0`) or
/// `AssetStatus.settled` (`2`).
final class DebtStatusTabNotifier extends Notifier<int> {
  @override
  int build() => AssetStatus.active;

  void select(int status) => state = status;
}

final debtStatusTabProvider = NotifierProvider<DebtStatusTabNotifier, int>(
  DebtStatusTabNotifier.new,
);

/// Debts visible under the active book scope (`CE-DM-06`).
final scopedDebtsProvider = StreamProvider<List<Asset>>((ref) async* {
  final q = await ref.watch(debtQueriesProvider.future);
  final allBooks = ref.watch(debtAllBooksScopeProvider);
  if (allBooks) {
    yield* q.watchDebts();
  } else {
    final bookId = await ref.watch(currentBookIdProvider.future);
    yield* q.watchDebts(bookId: bookId);
  }
});

final debtFundingAccountsProvider = StreamProvider<List<Asset>>((ref) async* {
  final q = await ref.watch(debtQueriesProvider.future);
  yield* q.watchFundingAccounts();
});

final debtAssetStreamProvider = StreamProvider.family<Asset?, int>((
  ref,
  debtId,
) async* {
  final q = await ref.watch(debtQueriesProvider.future);
  yield* q.watchDebt(debtId);
});

final debtBoundBookIdsProvider = StreamProvider.family<List<int>, int>((
  ref,
  debtId,
) async* {
  final q = await ref.watch(debtQueriesProvider.future);
  yield* q.watchDebtBookIds(debtId);
});

final debtRecordsStreamProvider =
    StreamProvider.family<List<LedgerRecord>, int>((ref, debtId) async* {
      final q = await ref.watch(debtQueriesProvider.future);
      yield* q.watchDebtRecords(debtId);
    });

/// Presentation row for one debt card on `DebtPage`.
final class DebtListItem {
  const DebtListItem({
    required this.debt,
    required this.loanInfo,
    required this.countedInNetWorth,
    required this.totalPrincipalMinor,
    required this.repaidPrincipalMinor,
    required this.remainingPrincipalMinor,
    required this.progressPermille,
    required this.progressLabel,
  });

  final Asset debt;
  final LoanInfo loanInfo;
  final bool countedInNetWorth;
  final BigInt totalPrincipalMinor;
  final BigInt repaidPrincipalMinor;
  final BigInt remainingPrincipalMinor;
  final int progressPermille;
  final String progressLabel;
}

/// Aggregated view state for `DebtPage`.
final class DebtListView {
  const DebtListView({
    required this.summary,
    required this.activeItems,
    required this.settledItems,
  });

  final DebtOverviewSummary summary;
  final List<DebtListItem> activeItems;
  final List<DebtListItem> settledItems;
}

final debtListViewProvider = FutureProvider<DebtListView>((ref) async {
  final debts = await ref.watch(scopedDebtsProvider.future);
  final rates = await ref.watch(rateTableProvider.future);

  final summary = computeDebtOverview([
    for (final d in debts)
      DebtSummaryInput(
        subType: d.subType,
        status: d.status,
        balanceMinor: d.balanceMinor,
        isEffectiveAsset: d.isEffectiveAsset,
        currency: d.currency,
      ),
  ], rates);

  final active = <DebtListItem>[];
  final settled = <DebtListItem>[];

  for (final d in debts) {
    final metrics = computeDebtDetailMetrics(
      status: d.status,
      balanceMinor: d.balanceMinor,
      isEffectiveAsset: d.isEffectiveAsset,
      loanInfoJson: d.loanInfo,
      currency: d.currency,
      records: const [],
      rates: rates,
    );
    final item = DebtListItem(
      debt: d,
      loanInfo: metrics.loanInfo,
      countedInNetWorth: metrics.countedInNetWorth,
      totalPrincipalMinor: metrics.totalPrincipalMinor,
      repaidPrincipalMinor: metrics.repaidPrincipalMinor,
      remainingPrincipalMinor: metrics.remainingPrincipalMinor,
      progressPermille: metrics.progressPermille,
      progressLabel: metrics.progressLabel,
    );
    if (d.status == AssetStatus.settled) {
      settled.add(item);
    } else if (d.status == AssetStatus.active) {
      active.add(item);
    }
  }

  return DebtListView(
    summary: summary,
    activeItems: active,
    settledItems: settled,
  );
});

/// Aggregated view state for `DebtDetailPage`.
final class DebtDetailView {
  const DebtDetailView({
    required this.debt,
    required this.metrics,
    required this.records,
    required this.boundBookIds,
    required this.accountNames,
    required this.bookNames,
  });

  final Asset debt;
  final DebtDetailMetrics metrics;
  final List<LedgerRecord> records;
  final List<int> boundBookIds;
  final Map<int, String> accountNames;
  final Map<int, String> bookNames;
}

final debtDetailViewProvider = FutureProvider.family<DebtDetailView?, int>((
  ref,
  debtId,
) async {
  final debt = await ref.watch(debtAssetStreamProvider(debtId).future);
  if (debt == null) return null;

  final records = await ref.watch(debtRecordsStreamProvider(debtId).future);
  final boundBookIds = await ref.watch(debtBoundBookIdsProvider(debtId).future);
  final allAssets = await ref.watch(assetsProvider.future);
  final allBooks = await ref.watch(booksProvider.future);
  final rates = await ref.watch(rateTableProvider.future);

  final entries = [
    for (final r in records)
      DebtRecordEntry(
        recordId: r.recordId,
        type: r.type,
        subType: r.subType,
        moneyMinor: r.moneyMinor,
        recordTime: r.recordTime,
        currency: RecordExtra.parse(r.extraInfo).currency,
      ),
  ];

  final metrics = computeDebtDetailMetrics(
    status: debt.status,
    balanceMinor: debt.balanceMinor,
    isEffectiveAsset: debt.isEffectiveAsset,
    loanInfoJson: debt.loanInfo,
    currency: debt.currency,
    records: entries,
    rates: rates,
  );

  return DebtDetailView(
    debt: debt,
    metrics: metrics,
    records: records,
    boundBookIds: boundBookIds,
    accountNames: {for (final a in allAssets) a.id: a.name},
    bookNames: {for (final b in allBooks) b.id: b.name},
  );
});
