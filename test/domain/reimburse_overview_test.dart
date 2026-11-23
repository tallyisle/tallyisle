import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/domain/ledger/record_extra.dart';
import 'package:tallyisle/domain/ledger/record_relations.dart';
import 'package:tallyisle/domain/rules/asset_overview.dart';
import 'package:tallyisle/domain/rules/currency_rates.dart';
import 'package:tallyisle/domain/rules/reimburse_overview.dart';

void main() {
  // 1 USD = 7.20 CNY
  final rates = RateTable({'CNY': '1', 'USD': rateToAnchorFromPrice('7.20')});

  group('L-04 reimburse_overview refunds & multi-currency', () {
    test('subtracts linked refunds from pending reimbursable amount', () {
      final rel = RecordRelations()
        ..refunds = BillLinks(
          children: [LinkedBill(billId: 'ref-1', amount: BigInt.from(3000))],
        )
        ..reimbursements = BillLinks(
          children: [LinkedBill(billId: 'rec-1', amount: BigInt.from(2000))],
        );

      final overview = computeReimburseOverview([
        ReimburseBillInput(
          recordId: 'b-1',
          bookId: 1,
          moneyMinor: BigInt.from(10000), // ¥100 origin
          recordTime: 1000,
          fromAssetId: 1,
          relInfo: rel.encode(),
        ),
      ], rates: rates);

      // Effective origin = 100 - 30 = 70; reimbursed = 20; remaining = 50
      expect(overview.pendingItems, hasLength(1));
      final item = overview.pendingItems.single;
      expect(item.originMinor, BigInt.from(7000));
      expect(item.reimbursedMinor, BigInt.from(2000));
      expect(item.remainingMinor, BigInt.from(5000));
      expect(overview.pendingTotalMinor, BigInt.from(5000));
      expect(overview.reimbursedTotalMinor, BigInt.from(2000));
      expect(overview.totalOriginMinor, BigInt.from(7000));
    });

    test('fully refunded reimbursable bill is settled with 0 pending', () {
      final rel = RecordRelations()
        ..refunds = BillLinks(
          children: [
            LinkedBill(billId: 'ref-full', amount: BigInt.from(10000)),
          ],
        );

      final overview = computeReimburseOverview([
        ReimburseBillInput(
          recordId: 'b-full-refund',
          bookId: 1,
          moneyMinor: BigInt.from(10000),
          recordTime: 1000,
          fromAssetId: 1,
          relInfo: rel.encode(),
        ),
      ], rates: rates);

      expect(overview.pendingItems, isEmpty);
      expect(overview.settledItems, hasLength(1));
      expect(overview.pendingTotalMinor, BigInt.zero);
    });

    test(
      'resolves currency from funding account (ac) instead of source (sc) and converts totals to base CNY',
      () {
        // Bill 1: entered in USD ($10), booked on CNY card (¥72) -> ac == CNY
        final usdToCnyExtra = RecordExtra()
          ..currency = CurrencySnapshot(
            sourceCode: 'USD',
            sourceGross: BigInt.from(1000),
            assetCode: 'CNY',
            assetNet: BigInt.from(7200),
            baseCode: 'CNY',
            baseAmount: BigInt.from(7200),
          );

        // Bill 2: booked on USD card ($50), partial refund $10 -> effective $40,
        // reimbursed $15 -> remaining $25 ($25 * 7.20 = ¥180.00)
        final usdCardExtra = RecordExtra()
          ..currency = CurrencySnapshot(
            sourceCode: 'USD',
            sourceGross: BigInt.from(5000),
            assetCode: 'USD',
            assetNet: BigInt.from(5000),
            baseCode: 'CNY',
            baseAmount: BigInt.from(36000),
          );
        final usdRel = RecordRelations()
          ..refunds = BillLinks(
            children: [
              LinkedBill(
                billId: 'usd-ref',
                amount: BigInt.from(1000),
                assetCode: 'USD',
                assetAmount: BigInt.from(1000),
                baseCode: 'CNY',
                baseAmount: BigInt.from(7200),
              ),
            ],
          )
          ..reimbursements = BillLinks(
            children: [
              LinkedBill(
                billId: 'usd-rec',
                amount: BigInt.from(1500),
                assetCode: 'USD',
                assetAmount: BigInt.from(1500),
                baseCode: 'CNY',
                baseAmount: BigInt.from(10800),
              ),
            ],
          );

        final overview = computeReimburseOverview([
          ReimburseBillInput(
            recordId: 'b-cny-card',
            bookId: 1,
            moneyMinor: BigInt.from(7200),
            recordTime: 2000,
            fromAssetId: 1,
            extraInfo: usdToCnyExtra.encode(),
            fallbackCurrencyCode: 'CNY',
          ),
          ReimburseBillInput(
            recordId: 'b-usd-card',
            bookId: 1,
            moneyMinor: BigInt.from(5000),
            recordTime: 1000,
            fromAssetId: 2,
            extraInfo: usdCardExtra.encode(),
            relInfo: usdRel.encode(),
            fallbackCurrencyCode: 'USD',
          ),
        ], rates: rates);

        expect(overview.pendingItems, hasLength(2));
        final cnyItem = overview.pendingItems.firstWhere(
          (i) => i.recordId == 'b-cny-card',
        );
        expect(cnyItem.currencyCode, 'CNY');
        expect(cnyItem.originMinor, BigInt.from(7200));
        expect(cnyItem.remainingMinor, BigInt.from(7200));

        final usdItem = overview.pendingItems.firstWhere(
          (i) => i.recordId == 'b-usd-card',
        );
        expect(usdItem.currencyCode, 'USD');
        expect(usdItem.originMinor, BigInt.from(4000)); // $50 - $10 refund
        expect(usdItem.reimbursedMinor, BigInt.from(1500)); // $15
        expect(usdItem.remainingMinor, BigInt.from(2500)); // $25

        // Totals in CNY:
        // pending = ¥72 + ($25 * 7.20 = ¥180) = ¥252.00 (25200)
        // reimbursed = ¥0 + ($15 * 7.20 = ¥108) = ¥108.00 (10800)
        // totalOrigin = ¥72 + ($40 * 7.20 = ¥288) = ¥360.00 (36000)
        expect(overview.pendingTotalMinor, BigInt.from(25200));
        expect(overview.reimbursedTotalMinor, BigInt.from(10800));
        expect(overview.totalOriginMinor, BigInt.from(36000));
      },
    );
  });
}
