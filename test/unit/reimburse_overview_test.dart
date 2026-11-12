import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/domain/ledger/record_extra.dart';
import 'package:tallyisle/domain/ledger/record_relations.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/reimburse_overview.dart';

String _encodeOriginLinks(List<(String, int)> items) {
  final rel = RecordRelations()
    ..reimbursements = BillLinks(
      children: [
        for (final (id, minor) in items)
          LinkedBill(billId: id, amount: BigInt.from(minor)),
      ],
    );
  return rel.encode()!;
}

String _encodeChildOrigin(String originId) {
  final rel = RecordRelations()..reimbursements = BillLinks(originId: originId);
  return rel.encode()!;
}

void main() {
  group('computeReimburseOverview pure domain rules', () {
    test('returns empty overview with zero BigInt totals for empty input', () {
      final overview = computeReimburseOverview(const <ReimburseBillInput>[]);
      expect(overview.isEmpty, isTrue);
      expect(overview.pendingItems, isEmpty);
      expect(overview.settledItems, isEmpty);
      expect(overview.pendingTotalMinor, BigInt.zero);
      expect(overview.reimbursedTotalMinor, BigInt.zero);
      expect(overview.totalOriginMinor, BigInt.zero);
    });

    test(
      'computes pending, partial, exact-settled, and over-reimbursed states with exact BigInt math',
      () {
        final inputs = <ReimburseBillInput>[
          ReimburseBillInput(
            recordId: 'b1-unpaid',
            bookId: 1,
            moneyMinor: BigInt.from(12000),
            recordTime: 1000,
            createDate: 10,
            categoryId: 5,
            fromAssetId: 2,
            remark: '出差高铁',
          ),
          ReimburseBillInput(
            recordId: 'b2-partial',
            bookId: 1,
            moneyMinor: BigInt.from(10000),
            recordTime: 2000,
            createDate: 20,
            categoryId: 6,
            fromAssetId: 2,
            remark: '酒店住宿',
            relInfo: _encodeOriginLinks([('rc-1', 3550), ('rc-2', 2450)]),
          ),
          ReimburseBillInput(
            recordId: 'b3-exact',
            bookId: 1,
            moneyMinor: BigInt.from(8523),
            recordTime: 1500,
            createDate: 15,
            categoryId: 7,
            fromAssetId: 3,
            remark: '打印装订',
            relInfo: _encodeOriginLinks([('rc-3', 8523)]),
          ),
          ReimburseBillInput(
            recordId: 'b4-overage',
            bookId: 2,
            moneyMinor: BigInt.from(5000),
            recordTime: 3000,
            createDate: 30,
            categoryId: 8,
            assetId: 4, // legacy asset_id fallback when fromAssetId == noRef
            remark: '补贴包干',
            relInfo: _encodeOriginLinks([('rc-4', 6200)]),
          ),
          // Non-reimbursable bill should be ignored if passed in.
          ReimburseBillInput(
            recordId: 'b-ignored-expense',
            bookId: 1,
            type: RecordType.expense,
            moneyMinor: BigInt.from(99999),
            recordTime: 9999,
          ),
        ];

        final overview = computeReimburseOverview(inputs);

        // Pending items sorted by recordTime DESC: b2-partial (2000), b1-unpaid (1000)
        expect(
          overview.pendingItems.map((e) => e.recordId).toList(),
          equals(['b2-partial', 'b1-unpaid']),
        );
        final partial = overview.pendingItems[0];
        expect(partial.originMinor, BigInt.from(10000));
        expect(partial.reimbursedMinor, BigInt.from(6000));
        expect(partial.remainingMinor, BigInt.from(4000));
        expect(partial.overageMinor, BigInt.zero);
        expect(partial.isSettled, isFalse);
        expect(partial.isPartial, isTrue);
        expect(partial.receiptIds, equals(['rc-1', 'rc-2']));

        final unpaid = overview.pendingItems[1];
        expect(unpaid.originMinor, BigInt.from(12000));
        expect(unpaid.reimbursedMinor, BigInt.zero);
        expect(unpaid.remainingMinor, BigInt.from(12000));
        expect(unpaid.overageMinor, BigInt.zero);
        expect(unpaid.isSettled, isFalse);
        expect(unpaid.isPartial, isFalse);
        expect(unpaid.receiptIds, isEmpty);

        // Settled items sorted by recordTime DESC: b4-overage (3000), b3-exact (1500)
        expect(
          overview.settledItems.map((e) => e.recordId).toList(),
          equals(['b4-overage', 'b3-exact']),
        );
        final overage = overview.settledItems[0];
        expect(overage.fundingAssetId, 4);
        expect(overage.originMinor, BigInt.from(5000));
        expect(overage.reimbursedMinor, BigInt.from(6200));
        expect(overage.remainingMinor, BigInt.zero);
        expect(overage.overageMinor, BigInt.from(1200));
        expect(overage.isSettled, isTrue);
        expect(overage.isPartial, isFalse);

        final exact = overview.settledItems[1];
        expect(exact.originMinor, BigInt.from(8523));
        expect(exact.reimbursedMinor, BigInt.from(8523));
        expect(exact.remainingMinor, BigInt.zero);
        expect(exact.overageMinor, BigInt.zero);
        expect(exact.isSettled, isTrue);
        expect(exact.isPartial, isFalse);

        expect(overview.pendingTotalMinor, BigInt.from(16000));
        expect(overview.reimbursedTotalMinor, BigInt.from(20723));
        expect(overview.totalOriginMinor, BigInt.from(35523));
      },
    );

    test(
      'reconciles live receipts: uses live moneyMinor when present, falls back to link.amount, skips unlinked deleted receipts, and deduplicates reverse links',
      () {
        final bill = ReimburseBillInput(
          recordId: 'bill-a',
          bookId: 1,
          moneyMinor: BigInt.from(20000),
          recordTime: 5000,
          // rc-live has link 4000 but live row has 4500; rc-legacy only exists in link (3000)
          relInfo: _encodeOriginLinks([('rc-live', 4000), ('rc-legacy', 3000)]),
        );

        final liveReceipts = <String, ReimburseReceiptInput>{
          'rc-live': ReimburseReceiptInput(
            recordId: 'rc-live',
            moneyMinor: BigInt.from(4500),
            relInfo: _encodeChildOrigin('bill-a'),
          ),
          // Reverse-linked receipt not yet listed in parent's children:
          'rc-reverse': ReimburseReceiptInput(
            recordId: 'rc-reverse',
            moneyMinor: BigInt.from(2500),
            relInfo: _encodeChildOrigin('bill-a'),
          ),
          // Unrelated / unlinked receipt belonging to another bill:
          'rc-other': ReimburseReceiptInput(
            recordId: 'rc-other',
            moneyMinor: BigInt.from(9900),
            relInfo: _encodeChildOrigin('bill-other'),
          ),
        };

        final overview = computeReimburseOverview([
          bill,
        ], liveReceipts: liveReceipts);

        expect(overview.pendingItems, hasLength(1));
        final item = overview.pendingItems.single;
        // 4500 (live) + 3000 (fallback link) + 2500 (reverse) = 10000
        expect(item.reimbursedMinor, BigInt.from(10000));
        expect(item.remainingMinor, BigInt.from(10000));
        expect(item.receiptIds, equals(['rc-live', 'rc-legacy', 'rc-reverse']));
      },
    );

    test(
      'sorts ties by createDate DESC then recordId DESC and resolves currencyCode & fundingAssetId',
      () {
        final usdExtra =
            (RecordExtra()
                  ..currency = CurrencySnapshot(
                    sourceCode: 'usd',
                    sourceGross: BigInt.from(5000),
                  ))
                .encode();

        final overview = computeReimburseOverview([
          ReimburseBillInput(
            recordId: 'b-older-create',
            bookId: 1,
            moneyMinor: BigInt.from(1000),
            recordTime: 9000,
            createDate: 100,
            fromAssetId: 10,
            assetId: 99,
            extraInfo: usdExtra,
          ),
          ReimburseBillInput(
            recordId: 'b-newer-create',
            bookId: 1,
            moneyMinor: BigInt.from(2000),
            recordTime: 9000,
            createDate: 200,
            fromAssetId: noRef,
            assetId: 12,
            fallbackCurrencyCode: 'hkd',
          ),
          ReimburseBillInput(
            recordId: 'b-corrupt-json',
            bookId: 1,
            moneyMinor: BigInt.from(3000),
            recordTime: 8000,
            relInfo: '{not-valid-json',
            extraInfo: '{not-valid-json',
          ),
        ], baseCurrencyCode: 'CNY');

        expect(
          overview.pendingItems.map((e) => e.recordId).toList(),
          equals(['b-newer-create', 'b-older-create', 'b-corrupt-json']),
        );
        expect(overview.pendingItems[0].fundingAssetId, 12);
        expect(overview.pendingItems[0].currencyCode, 'HKD');
        expect(overview.pendingItems[1].fundingAssetId, 10);
        expect(overview.pendingItems[1].currencyCode, 'USD');
        expect(overview.pendingItems[2].fundingAssetId, noRef);
        expect(overview.pendingItems[2].currencyCode, 'CNY');
      },
    );

    test(
      'computeReimbursePreview classifies partial, full, and overage hints',
      () {
        // Bill of 100.00 already partially reimbursed 30.00 (remaining 70.00):
        final partial = computeReimbursePreview(
          originMinor: BigInt.from(10000),
          alreadyReimbursedMinor: BigInt.from(3000),
          inputMinor: BigInt.from(2500),
        );
        expect(partial.kind, ReimbursePreviewKind.partial);
        expect(partial.afterRemainingMinor, BigInt.from(4500));
        expect(partial.hintText, '报销后剩余待报 ¥45.00');

        final full = computeReimbursePreview(
          originMinor: BigInt.from(10000),
          alreadyReimbursedMinor: BigInt.from(3000),
          inputMinor: BigInt.from(7000),
        );
        expect(full.kind, ReimbursePreviewKind.full);
        expect(full.afterRemainingMinor, BigInt.zero);
        expect(full.hintText, '全额结清');

        final over = computeReimbursePreview(
          originMinor: BigInt.from(10000),
          alreadyReimbursedMinor: BigInt.from(3000),
          inputMinor: BigInt.from(8250),
        );
        expect(over.kind, ReimbursePreviewKind.overage);
        expect(over.overageMinor, BigInt.from(1250));
        expect(over.hintText, '超出垫付 +¥12.50');
      },
    );

    test('domain layer purity: zero flutter, drift, or double usage', () {
      final src = File(
        'lib/domain/rules/reimburse_overview.dart',
      ).readAsStringSync();
      expect(src.contains("package:flutter/"), isFalse);
      expect(src.contains("dart:ui"), isFalse);
      expect(src.contains("package:drift/"), isFalse);
      expect(RegExp(r'\bdouble\b').hasMatch(src), isFalse);
    });
  });
}
