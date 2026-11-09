import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../data/repo/credit_queries.dart';
import '../../domain/ledger/asset_json.dart';
import '../../domain/ledger/record_extra.dart';
import '../../domain/ledger/record_relations.dart';
import '../../domain/rules/asset_overview.dart';
import '../../domain/rules/credit_cycle.dart';

/// Mapping helper from [LedgerRecord] to [CreditCardRecord].
CreditCardRecord toCreditCardRecord(LedgerRecord r) {
  return CreditCardRecord(
    id: r.recordId,
    recordTime: r.recordTime,
    type: r.type,
    subType: r.subType,
    moneyMinor: r.moneyMinor,
    assetId: r.assetId,
    fromAssetId: r.fromAssetId,
    toAssetId: r.toAssetId,
    excludeBudget: r.excludeBudget,
    excludeExIn: r.excludeExIn,
    currencySnapshot: RecordExtra.parse(r.extraInfo).currency,
    relations: r.relInfo != null && r.relInfo!.isNotEmpty
        ? RecordRelations.parse(r.relInfo)
        : null,
  );
}

final creditQueriesProvider = FutureProvider<CreditQueries>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return CreditQueries(db);
});

/// Stream of all records touching [cardId] across all books.
final creditCardRecordsProvider =
    StreamProvider.family<List<LedgerRecord>, int>((ref, cardId) async* {
      final q = await ref.watch(creditQueriesProvider.future);
      yield* q.watchCardRecords(cardId);
    });

/// Stream of all credit card assets in the database.
final allCreditCardsProvider = StreamProvider<List<Asset>>((ref) async* {
  final q = await ref.watch(creditQueriesProvider.future);
  yield* q.watchCreditCards();
});

/// Selected statement year for credit account views.
final class CreditSelectedYearNotifier extends Notifier<int> {
  @override
  int build() => DateTime.now().year;
  void setYear(int y) => state = y;
  void previous() => state = state - 1;
  void next() => state = state + 1;
  void reset() => state = DateTime.now().year;
}

final creditSelectedYearProvider =
    NotifierProvider<CreditSelectedYearNotifier, int>(
      CreditSelectedYearNotifier.new,
    );

/// Statements for [card] in the currently selected year.
final creditStatementsProvider =
    FutureProvider.family<List<CreditStatementItem>, Asset>((ref, card) async {
      final info = CreditInfo.parse(card.creditInfo);
      if (!info.configured) return const [];

      final rawRecords = await ref.watch(
        creditCardRecordsProvider(card.id).future,
      );
      final records = rawRecords.map(toCreditCardRecord).toList();
      final selectedYear = ref.watch(creditSelectedYearProvider);

      return calculateCreditStatements(
        creditInfo: info,
        cardBalanceMinor: card.balanceMinor,
        records: records,
        cardId: card.id,
        selectedYear: selectedYear,
        today: DateTime.now(),
      );
    });

/// Pending repayment banner for [card].
final creditPendingBannerProvider =
    FutureProvider.family<CreditPendingBannerInfo?, Asset>((ref, card) async {
      final statements = await ref.watch(creditStatementsProvider(card).future);
      final selectedYear = ref.watch(creditSelectedYearProvider);
      return findPendingRepaymentBanner(
        statementItems: statements,
        selectedYear: selectedYear,
        today: DateTime.now(),
      );
    });

/// Shared limit computation for [card].
final creditSharedLimitProvider =
    FutureProvider.family<SharedLimitResult, Asset>((ref, card) async {
      final cards = await ref.watch(allCreditCardsProvider.future);
      final currencies = await ref.watch(currenciesProvider.future);
      final rateTable = RateTable({
        for (final c in currencies) c.code: c.rateToAnchor,
      });

      final groupCards = [
        for (final c in cards)
          SharedGroupCard(
            id: c.id,
            balanceMinor: c.balanceMinor,
            initMoneyMinor: c.initMoneyMinor,
            status: c.status,
            currency: c.currency,
            creditInfo: CreditInfo.parse(c.creditInfo),
            extraInfo: AssetExtra.parse(c.extraInfo),
          ),
      ];

      final targetGroupCard = SharedGroupCard(
        id: card.id,
        balanceMinor: card.balanceMinor,
        initMoneyMinor: card.initMoneyMinor,
        status: card.status,
        currency: card.currency,
        creditInfo: CreditInfo.parse(card.creditInfo),
        extraInfo: AssetExtra.parse(card.extraInfo),
      );

      return calculateSharedLimit(
        targetCard: targetGroupCard,
        allCards: groupCards,
        nowMs: DateTime.now().millisecondsSinceEpoch,
        rateTable: rateTable,
      );
    });
