import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/deposit/fixed_deposit_service.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/fixed_deposit.dart';
import 'package:tallyisle/features/deposit/fixed_deposit_editor_page.dart';
import 'package:tallyisle/features/deposit/fixed_deposit_page.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Widget buildApp(Widget child, AppDatabase db) => ProviderScope(
    retry: (_, _) => null,
    overrides: [databaseProvider.overrideWith((ref) async => db)],
    child: MaterialApp(home: child),
  );

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets(
    'FixedDepositPage: create deposit with auto-calculated interest, header update, and initialAssetId filter',
    (tester) async {
      final nowMs = DateTime(2026, 6, 1, 10, 0).millisecondsSinceEpoch;
      final db = AppDatabase(NativeDatabase.memory(), nowMs: () => nowMs);
      final ledger = LedgerService(db);
      final depService = FixedDepositService(db);

      late int cardA;
      await tester.runAsync(() async {
        cardA = await ledger.createAsset(
          commandId: 'mk-card-a',
          name: '招商银行储蓄卡',
          initial: Money.parse('20000.00'),
        );
        final cardB = await ledger.createAsset(
          commandId: 'mk-card-b',
          name: '建设银行定存卡',
          initial: Money.parse('5000.00'),
        );

        // Pre-create one deposit on cardB to verify initialAssetId filtering
        await depService.createDeposit(
          commandId: 'pre-b',
          draft: FixedDepositDraft(
            targetAssetId: cardB,
            principal: Money.parse('5000.00'),
            annualRate: percentToAnnualRate('2.0'),
            periodUnit: DepositPeriodUnit.year,
            periodCount: 1,
            depositDate: DateTime(2026, 5, 1).millisecondsSinceEpoch,
          ),
        );
      });

      await tester.pumpWidget(
        buildApp(FixedDepositPage(initialAssetId: cardA), db),
      );
      await settle(tester);

      // Filtered to cardA initially -> empty!
      expect(find.byKey(const Key('fixed_deposit_page')), findsOneWidget);
      expect(find.text('暂无定期存款记录'), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('deposit_total_principal')))
            .data,
        '¥0.00',
      );

      // Tap FAB to create a 6-month deposit on cardA: 10000.00 @ 2.4% -> 120.00
      await tester.tap(find.byKey(const Key('add_deposit_fab')));
      await settle(tester);

      expect(
        find.byKey(const Key('fixed_deposit_editor_page')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('deposit_principal_input')),
        '10000.00',
      );
      await tester.enterText(
        find.byKey(const Key('deposit_rate_input')),
        '2.4',
      );
      await tester.enterText(
        find.byKey(const Key('deposit_period_count_input')),
        '6',
      );
      await tester.ensureVisible(find.text('按月'));
      await tester.tap(find.text('按月'));
      await settle(tester);

      // Verify auto-calculated expected income == 120.00 (FD-2)!
      final expectedField = tester.widget<TextField>(
        find.byKey(const Key('deposit_expected_income_input')),
      );
      expect(expectedField.controller!.text, '120.00');

      await tester.ensureVisible(find.byKey(const Key('deposit_remark_input')));
      await tester.enterText(
        find.byKey(const Key('deposit_remark_input')),
        '半年定存',
      );
      await tester.tap(find.byKey(const Key('deposit_save_button')));
      await settle(tester);

      // Back on FixedDepositPage (filtered to cardA): 10000.00 principal, 120.00 pending!
      expect(find.byKey(const Key('fixed_deposit_page')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('deposit_total_principal')))
            .data,
        '¥10000.00',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('deposit_pending_income')))
            .data,
        '¥120.00',
      );
      expect(find.textContaining('半年定存'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets(
    'FixedDepositPage: lazy auto-settlement on entry, settled remark sync, chip navigation & delete',
    (tester) async {
      final nowMs = DateTime(2026, 6, 1, 12, 0).millisecondsSinceEpoch;
      final db = AppDatabase(NativeDatabase.memory(), nowMs: () => nowMs);
      final ledger = LedgerService(db);
      final depService = FixedDepositService(db);

      late int hostId;
      await tester.runAsync(() async {
        hostId = await ledger.createAsset(
          commandId: 'mk-host',
          name: '工商银行定存卡',
          initial: Money.parse('10000.00'),
        );

        // Create a past-due deposit (due 2026-05-01 <= 2026-06-01): 10000 @ 3.0% 1yr -> 300.00
        await depService.createDeposit(
          commandId: 'mk-due-dep',
          draft: FixedDepositDraft(
            targetAssetId: hostId,
            principal: Money.parse('10000.00'),
            annualRate: percentToAnnualRate('3.0'),
            periodUnit: DepositPeriodUnit.year,
            periodCount: 1,
            depositDate: DateTime(2025, 5, 1).millisecondsSinceEpoch,
            remark: '到期测试',
          ),
        );
      });

      // Opening FixedDepositPage lazily settles the due deposit!
      await tester.pumpWidget(buildApp(const FixedDepositPage(), db));
      await settle(tester);

      expect(find.text('已结束'), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('deposit_settled_income')))
            .data,
        '¥300.00',
      );

      // Edit settled deposit remark -> syncs to linked income record (ASYM-FD-03)
      await tester.tap(find.byKey(Key('deposit_edit_${hostId}_0')));
      await settle(tester);
      expect(find.text('编辑定存备注'), findsOneWidget);

      await tester.ensureVisible(find.byKey(const Key('deposit_remark_input')));
      await tester.enterText(
        find.byKey(const Key('deposit_remark_input')),
        '已结清改备注',
      );
      await tester.tap(find.byKey(const Key('deposit_save_button')));
      await settle(tester);

      expect(find.textContaining('已结清改备注'), findsOneWidget);
      late List<LedgerRecord> records;
      await tester.runAsync(() async {
        records = await db.select(db.records).get();
      });
      expect(records.single.remark, '定期存款收益：已结清改备注');

      // Tap settled income chip while record is alive -> opens RecordDetailPage!
      await tester.tap(find.byKey(Key('deposit_income_chip_${hostId}_0')));
      await settle(tester);
      expect(find.text('账单详情'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await settle(tester);

      // Delete income record manually, then tap settled income chip -> shows '账单已不存在'
      await tester.runAsync(() async {
        await ledger.deleteRecord(
          commandId: 'del-inc-bill',
          recordId: records.single.recordId,
        );
      });
      await settle(tester);

      await tester.tap(find.byKey(Key('deposit_income_chip_${hostId}_0')));
      await settle(tester);
      expect(find.text('账单已不存在'), findsOneWidget);

      // Delete the deposit via confirmation dialog -> clean empty state & no double deduction!
      await tester.tap(find.byKey(Key('deposit_delete_${hostId}_0')));
      await settle(tester);
      await tester.tap(find.text('删除'));
      await settle(tester);

      expect(find.text('暂无定期存款记录'), findsOneWidget);
      late Asset finalHost;
      await tester.runAsync(() async {
        finalHost = await (db.select(
          db.assets,
        )..where((t) => t.id.equals(hostId))).getSingle();
      });
      expect(finalHost.balanceMinor, Money.parse('10000.00').storageMinor);

      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets(
    'FixedDepositEditorPage: opens existing USD deposit with cold streams and disabled currency without crash',
    (tester) async {
      final nowMs = DateTime(2026, 6, 1, 10, 0).millisecondsSinceEpoch;
      final db = AppDatabase(NativeDatabase.memory(), nowMs: () => nowMs);
      final ledger = LedgerService(db);
      final depService = FixedDepositService(db);

      late int usdHostId;
      await tester.runAsync(() async {
        await db
            .into(db.currencies)
            .insertOnConflictUpdate(
              CurrenciesCompanion.insert(
                code: 'USD',
                name: '美元',
                symbol: r'$',
                rateToAnchor: '0.13',
                anchorCode: 'CNY',
                enable: const Value(true),
              ),
            );
        usdHostId = await ledger.createAsset(
          commandId: 'mk-usd-host',
          name: '中行外币账户',
          initial: Money.parse('1000.00', currency: 'USD'),
          currency: 'USD',
        );
        await depService.createDeposit(
          commandId: 'mk-usd-dep',
          draft: FixedDepositDraft(
            targetAssetId: usdHostId,
            principal: Money.parse('500.00', currency: 'USD'),
            annualRate: percentToAnnualRate('4.5'),
            periodUnit: DepositPeriodUnit.year,
            periodCount: 1,
            depositDate: DateTime(2026, 5, 1).millisecondsSinceEpoch,
            currency: 'USD',
          ),
        );
        // Disable USD afterwards to verify fallback item prevents DropdownButton crash.
        await (db.update(db.currencies)..where((t) => t.code.equals('USD')))
            .write(const CurrenciesCompanion(enable: Value(false)));
      });

      // Open FixedDepositEditorPage directly (cold streams!).
      await tester.pumpWidget(
        buildApp(
          FixedDepositEditorPage(assetId: usdHostId, depositIndex: 0),
          db,
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      await settle(tester);
      expect(tester.takeException(), isNull);

      final currencyDropdown = tester.widget<DropdownButton<String>>(
        find.byKey(const Key('deposit_currency_dropdown')),
      );
      expect(currencyDropdown.value, 'USD');
      expect(find.text('美元（USD）'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets(
    'Controlled dropdowns: selecting fromAsset=cardB then switching hostAsset=cardB and hiding filtered account do not crash',
    (tester) async {
      final nowMs = DateTime(2026, 6, 1, 10, 0).millisecondsSinceEpoch;
      final db = AppDatabase(NativeDatabase.memory(), nowMs: () => nowMs);
      final ledger = LedgerService(db);

      late int cardA;
      late int cardB;
      await tester.runAsync(() async {
        cardA = await ledger.createAsset(
          commandId: 'mk-a',
          name: '招商银行卡A',
          initial: Money.parse('10000.00'),
        );
        cardB = await ledger.createAsset(
          commandId: 'mk-b',
          name: '建设银行卡B',
          initial: Money.parse('8000.00'),
        );
      });

      await tester.pumpWidget(
        buildApp(FixedDepositPage(initialAssetId: cardA), db),
      );
      await settle(tester);

      await tester.tap(find.byKey(const Key('add_deposit_fab')));
      await settle(tester);

      // 1. Select fromAsset = cardB
      final fromFinder = find.byKey(const Key('deposit_from_asset_dropdown'));
      await tester.ensureVisible(fromFinder);
      await tester.tap(fromFinder);
      await settle(tester);
      await tester.tap(find.text('建设银行卡B（CNY）').last);
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(tester.widget<DropdownButton<int>>(fromFinder).value, cardB);

      // 2. Switch hostAsset to cardB -> fromAsset must cleanly reset to noRef without assertion crash!
      final hostFinder = find.byKey(const Key('deposit_host_asset_dropdown'));
      await tester.ensureVisible(hostFinder);
      await tester.tap(hostFinder);
      await settle(tester);
      await tester.tap(find.text('建设银行卡B（CNY）').last);
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(tester.widget<DropdownButton<int>>(hostFinder).value, cardB);
      expect(tester.widget<DropdownButton<int>>(fromFinder).value, noRef);

      // Pop back to FixedDepositPage(initialAssetId: cardA)
      await tester.tap(find.byType(BackButton));
      await settle(tester);

      // 3. Hide cardA while FixedDepositPage is filtering on cardA -> deposit_asset_filter falls back to noRef cleanly!
      await tester.runAsync(() async {
        await (db.update(db.assets)..where((t) => t.id.equals(cardA))).write(
          const AssetsCompanion(status: Value(AssetStatus.hidden)),
        );
      });
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(
        tester
            .widget<DropdownButton<int>>(
              find.byKey(const Key('deposit_asset_filter')),
            )
            .value,
        noRef,
      );

      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
    },
  );
}
