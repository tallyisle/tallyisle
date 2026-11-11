import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/data/tools/bank_card_service.dart';
import 'package:tallyisle/data/tools/template_remark_service.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/template_card_rules.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  var seq = 0;
  String nextCmd() => 'tc-cmd-${++seq}';

  AppDatabase openTestDb() {
    final db = AppDatabase(NativeDatabase.memory(), nowMs: () => 1762800000000);
    addTearDown(db.close);
    return db;
  }

  Future<(int expenseCatId, int incomeCatId)> loadSeededCategoryIds(
    AppDatabase db,
  ) async {
    final cats = await db.select(db.recordCategories).get();
    final exp = cats.firstWhere((c) => c.type == RecordType.expense).id;
    final inc = cats.firstWhere((c) => c.type == RecordType.income).id;
    return (exp, inc);
  }

  group('TemplateRemarkService — RecordTemplates (F-016)', () {
    test(
      'allocates non-autoIncrement PK via COALESCE(MAX(id), 0) + 1 and preserves unknown exi keys',
      () async {
        final db = openTestDb();
        final svc = TemplateRemarkService(db);
        final (expCatId, _) = await loadSeededCategoryIds(db);

        final firstId = await svc.saveTemplate(
          commandId: nextCmd(),
          draft: TemplateDraft(
            type: RecordType.expense,
            money: Money.parse('15.50'),
            bookId: 1,
            name: '早餐豆浆',
            categoryId: expCatId,
            remark: '小区早餐铺',
          ),
        );
        expect(firstId, 1);

        // Simulate an imported row at id = 7 with custom unknown exi key
        await db
            .into(db.recordTemplates)
            .insert(
              RecordTemplatesCompanion.insert(
                id: const Value(7),
                type: RecordType.expense,
                moneyMinor: BigInt.from(3000),
                recordCatId: Value(expCatId),
                bookId: 1,
                createDate: 1762800000000,
                exi: const Value('{"custom_origin":"penny_v86"}'),
              ),
            );

        final afterMaxId = await svc.saveTemplate(
          commandId: nextCmd(),
          draft: TemplateDraft(
            type: RecordType.expense,
            money: Money.parse('8.00'),
            bookId: 1,
            categoryId: expCatId,
          ),
        );
        expect(afterMaxId, 8);

        // Edit imported template 7 and verify unknown exi key survives
        await svc.saveTemplate(
          commandId: nextCmd(),
          templateId: 7,
          draft: TemplateDraft(
            type: RecordType.expense,
            money: Money.parse('32.00'),
            bookId: 1,
            name: '午餐简餐',
            categoryId: expCatId,
          ),
        );
        final updated7 = await svc.getTemplate(7);
        final parsedExi = TemplateExtra.parse(updated7!.exi);
        expect(parsedExi.name, '午餐简餐');
        expect(parsedExi.raw['custom_origin'], 'penny_v86');
      },
    );

    test(
      'applyTemplateInstant books all 6 supported types accurately through LedgerService with exact balance deltas and ADR-009 idempotency',
      () async {
        final db = openTestDb();
        final ledger = LedgerService(db);
        final svc = TemplateRemarkService(db);
        final (expCatId, incCatId) = await loadSeededCategoryIds(db);

        final bankAssetId = await ledger.createAsset(
          commandId: nextCmd(),
          name: '招商储蓄卡',
          initial: Money.parse('1000.00'),
        );
        final walletAssetId = await ledger.createAsset(
          commandId: nextCmd(),
          name: '零钱通',
          initial: Money.parse('200.00'),
        );

        await db
            .into(db.tags)
            .insert(TagsCompanion.insert(tagId: 'tag_commute', name: '通勤'));

        // 1. Expense (0) with valid + stale tag
        final expTplId = await svc.saveTemplate(
          commandId: nextCmd(),
          draft: TemplateDraft(
            type: RecordType.expense,
            money: Money.parse('18.50'),
            bookId: 1,
            categoryId: expCatId,
            assetId: bankAssetId,
            remark: '地铁通勤',
            autoSave: true,
            excludeBudget: true,
            tagIds: const <String>['tag_commute', 'ghost_deleted_tag'],
          ),
        );
        final applyExpCmd = nextCmd();
        final expRecordId = await svc.applyTemplateInstant(
          commandId: applyExpCmd,
          templateId: expTplId,
          recordTimeMs: 1762810000000,
        );
        // Retry with same commandId is strictly idempotent (no double deduction)
        final expRetryId = await svc.applyTemplateInstant(
          commandId: applyExpCmd,
          templateId: expTplId,
          recordTimeMs: 1762810000000,
        );
        expect(expRetryId, expRecordId);
        // Same commandId with different timestamp throws conflict
        await expectLater(
          svc.applyTemplateInstant(
            commandId: applyExpCmd,
            templateId: expTplId,
            recordTimeMs: 1762899999000,
          ),
          throwsA(
            isA<Failure>().having((f) => f.code, 'code', FailureCode.conflict),
          ),
        );

        var bankAsset = await (db.select(
          db.assets,
        )..where((a) => a.id.equals(bankAssetId))).getSingle();
        // 1000.00 - 18.50 = 981.50 (98150 minor)
        expect(bankAsset.balanceMinor, BigInt.from(98150));

        // Only live tag written to tag_record (zero orphan tag_records)
        final tagLinks = await (db.select(
          db.tagRecords,
        )..where((tr) => tr.recordId.equals(expRecordId))).get();
        expect(tagLinks.map((e) => e.tagId).toList(), <String>['tag_commute']);

        // 2. Income (1)
        final incTplId = await svc.saveTemplate(
          commandId: nextCmd(),
          draft: TemplateDraft(
            type: RecordType.income,
            money: Money.parse('100.00'),
            bookId: 1,
            categoryId: incCatId,
            assetId: walletAssetId,
            autoSave: true,
          ),
        );
        await svc.applyTemplateInstant(
          commandId: nextCmd(),
          templateId: incTplId,
        );
        var walletAsset = await (db.select(
          db.assets,
        )..where((a) => a.id.equals(walletAssetId))).getSingle();
        // 200.00 + 100.00 = 300.00 (30000 minor)
        expect(walletAsset.balanceMinor, BigInt.from(30000));

        // 3. Transfer (2) with fee = 2.50 paid by outgoing account
        final transferTplId = await svc.saveTemplate(
          commandId: nextCmd(),
          draft: TemplateDraft(
            type: RecordType.transfer,
            money: Money.parse('500.00'),
            fee: Money.parse('2.50'),
            feeFromTarget: false,
            bookId: 1,
            assetId: bankAssetId,
            assetId2: walletAssetId,
            remark: '转入零钱',
            autoSave: true,
          ),
        );
        await svc.applyTemplateInstant(
          commandId: nextCmd(),
          templateId: transferTplId,
        );
        bankAsset = await (db.select(
          db.assets,
        )..where((a) => a.id.equals(bankAssetId))).getSingle();
        walletAsset = await (db.select(
          db.assets,
        )..where((a) => a.id.equals(walletAssetId))).getSingle();
        // Bank: 981.50 - 500.00 - 2.50 = 479.00 (47900 minor)
        // Wallet: 300.00 + 500.00 = 800.00 (80000 minor)
        expect(bankAsset.balanceMinor, BigInt.from(47900));
        expect(walletAsset.balanceMinor, BigInt.from(80000));

        // 4. Reimbursable (3): maps template.assetId -> record.fromAssetId
        final reimbTplId = await svc.saveTemplate(
          commandId: nextCmd(),
          draft: TemplateDraft(
            type: RecordType.reimbursable,
            money: Money.parse('128.50'),
            bookId: 1,
            categoryId: expCatId,
            assetId: walletAssetId,
            remark: '垫付办公品',
            autoSave: true,
          ),
        );
        final reimbRecordId = await svc.applyTemplateInstant(
          commandId: nextCmd(),
          templateId: reimbTplId,
        );
        final reimbRecord = await (db.select(
          db.records,
        )..where((r) => r.recordId.equals(reimbRecordId))).getSingle();
        expect(reimbRecord.type, RecordType.reimbursable);
        expect(reimbRecord.assetId, noRef);
        expect(reimbRecord.fromAssetId, walletAssetId);
        walletAsset = await (db.select(
          db.assets,
        )..where((a) => a.id.equals(walletAssetId))).getSingle();
        // Wallet: 800.00 - 128.50 = 671.50 (67150 minor)
        expect(walletAsset.balanceMinor, BigInt.from(67150));

        // 5 & 6. AdvanceIncome (9) & AdvanceExpense (16): pending memos do not alter balance
        final advIncTplId = await svc.saveTemplate(
          commandId: nextCmd(),
          draft: TemplateDraft(
            type: RecordType.advanceIncome,
            money: Money.parse('60.00'),
            bookId: 1,
            categoryId: incCatId,
            assetId: walletAssetId,
            autoSave: true,
          ),
        );
        final advExpTplId = await svc.saveTemplate(
          commandId: nextCmd(),
          draft: TemplateDraft(
            type: RecordType.advanceExpense,
            money: Money.parse('40.00'),
            bookId: 1,
            categoryId: expCatId,
            assetId: walletAssetId,
            autoSave: true,
          ),
        );
        await svc.applyTemplateInstant(
          commandId: nextCmd(),
          templateId: advIncTplId,
        );
        await svc.applyTemplateInstant(
          commandId: nextCmd(),
          templateId: advExpTplId,
        );
        walletAsset = await (db.select(
          db.assets,
        )..where((a) => a.id.equals(walletAssetId))).getSingle();
        expect(walletAsset.balanceMinor, BigInt.from(67150));
      },
    );

    test(
      'rejects applyTemplateInstant cleanly when linked account is deleted or settled, while buildTemplatePrefill falls back safely',
      () async {
        final db = openTestDb();
        final ledger = LedgerService(db);
        final svc = TemplateRemarkService(db);
        final (expCatId, _) = await loadSeededCategoryIds(db);

        final tempAssetId = await ledger.createAsset(
          commandId: nextCmd(),
          name: '临时现金袋',
          initial: Money.parse('50.00'),
        );
        final tplId = await svc.saveTemplate(
          commandId: nextCmd(),
          draft: TemplateDraft(
            type: RecordType.expense,
            money: Money.parse('12.00'),
            bookId: 1,
            categoryId: expCatId,
            assetId: tempAssetId,
            autoSave: true,
          ),
        );

        // Delete the unreferenced account
        await ledger.deleteAsset(commandId: nextCmd(), assetId: tempAssetId);

        await expectLater(
          svc.applyTemplateInstant(commandId: nextCmd(), templateId: tplId),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.validation,
            ),
          ),
        );

        final prefill = await svc.buildTemplatePrefill(tplId);
        expect(prefill.assetId, noRef);
        expect(prefill.categoryId, expCatId);
        expect(prefill.warnings, isNotEmpty);
      },
    );
  });

  group('TemplateRemarkService — Remarks (F-016 R4)', () {
    test(
      'watchRemarksForCategory orders by usedTimes DESC, id DESC for catId or -1, and recordRemarkUsage is idempotent',
      () async {
        final db = openTestDb();
        final svc = TemplateRemarkService(db);
        final cats = await db.select(db.recordCategories).get();
        final catA = cats[0].id;
        final catB = cats[1].id;

        // Blank usage is a no-op
        expect(
          await svc.recordRemarkUsage(
            commandId: nextCmd(),
            recordCatId: catA,
            content: '   ',
          ),
          noRef,
        );

        final r1 = await svc.recordRemarkUsage(
          commandId: nextCmd(),
          recordCatId: catA,
          content: '早餐包子',
        );
        // Increment r1 to usedTimes = 2 (and verify retry idempotency!)
        final usageCmd = nextCmd();
        await svc.recordRemarkUsage(
          commandId: usageCmd,
          recordCatId: catA,
          content: '  早餐包子  ',
        );
        await svc.recordRemarkUsage(
          commandId: usageCmd,
          recordCatId: catA,
          content: '  早餐包子  ',
        );

        // Global remark (-1) with usedTimes = 2 (higher id than r1)
        final globalId = await svc.createRemark(
          commandId: nextCmd(),
          content: '公司团建',
          recordCatId: noRef,
          usedTimes: 2,
        );
        // Other category remark with usedTimes = 99 (excluded from catA)
        await svc.createRemark(
          commandId: nextCmd(),
          content: '猫粮采购',
          recordCatId: catB,
          usedTimes: 99,
        );

        final forCatA = await svc.watchRemarksForCategory(catA).first;
        expect(forCatA.map((r) => r.id).toList(), <int>[globalId, r1]);
        expect(forCatA.map((r) => r.usedTimes).toList(), <int>[2, 2]);

        // Duplicate remark in same category rejected
        await expectLater(
          svc.createRemark(
            commandId: nextCmd(),
            content: '早餐包子',
            recordCatId: catA,
          ),
          throwsA(isA<Failure>()),
        );

        // Update and delete
        await svc.updateRemark(
          commandId: nextCmd(),
          id: r1,
          content: '早餐豆浆油条',
          recordCatId: catA,
          usedTimes: 5,
        );
        final afterUpdate = await svc.getRemarksForCategory(catA);
        expect(afterUpdate.first.content, '早餐豆浆油条');
        expect(afterUpdate.first.usedTimes, 5);

        await svc.deleteRemark(commandId: nextCmd(), id: r1);
        final afterDelete = await svc.getRemarksForCategory(catA);
        expect(afterDelete.map((r) => r.id).toList(), <int>[globalId]);
      },
    );
  });

  group('BankCardService (F-023)', () {
    test(
      'normalizes digits, accepts non-Luhn numbers, filters by cardType, validates linked Asset, and enforces ADR-009 idempotency',
      () async {
        final db = openTestDb();
        final ledger = LedgerService(db);
        final svc = BankCardService(db);

        final linkedAssetId = await ledger.createAsset(
          commandId: nextCmd(),
          name: '招行工资户',
          initial: Money.parse('5000.00'),
        );

        final createCmd = nextCmd();
        final debitId = await svc.saveBankCard(
          commandId: createCmd,
          draft: BankCardDraft(
            cardType: BankCardType.debit,
            cardName: '招商银行储蓄卡',
            cardNo: '6225-8801 1234 5678',
            cardOwner: '李四',
            remark: '高新园支行',
            cardColor: '#1565c0',
            cardAssetId: linkedAssetId,
          ),
        );
        // Retry with same commandId returns identical ID without duplicating
        expect(
          await svc.saveBankCard(
            commandId: createCmd,
            draft: BankCardDraft(
              cardType: BankCardType.debit,
              cardName: '招商银行储蓄卡',
              cardNo: '6225-8801 1234 5678',
              cardOwner: '李四',
              remark: '高新园支行',
              cardColor: '#1565c0',
              cardAssetId: linkedAssetId,
            ),
          ),
          debitId,
        );

        // Non-Luhn credit card number saves cleanly
        final creditId = await svc.saveBankCard(
          commandId: nextCmd(),
          draft: const BankCardDraft(
            cardType: BankCardType.credit,
            cardName: '广发信用卡',
            cardNo: '6222 0000 0000 1235',
          ),
        );

        final savedDebit = await svc.getBankCard(debitId);
        expect(savedDebit!.cardNo, '6225880112345678');
        expect(savedDebit.cardColor, '#1565C0');
        expect(savedDebit.cardAssetId, linkedAssetId);

        expect(
          (await svc.getBankCards(
            cardType: BankCardType.debit,
          )).map((c) => c.id).toList(),
          <int>[debitId],
        );
        expect(
          (await svc.getBankCards(
            cardType: BankCardType.credit,
          )).map((c) => c.id).toList(),
          <int>[creditId],
        );
        expect(await svc.getBankCards(), hasLength(2));

        // Rejects non-existent linked asset
        await expectLater(
          svc.saveBankCard(
            commandId: nextCmd(),
            draft: const BankCardDraft(
              cardType: BankCardType.debit,
              cardName: '测试卡',
              cardNo: '6222021234567890',
              cardAssetId: 99999,
            ),
          ),
          throwsA(isA<Failure>()),
        );

        // Deleting bank card leaves linked asset intact
        await svc.deleteBankCard(commandId: nextCmd(), cardId: debitId);
        expect(await svc.getBankCard(debitId), isNull);
        final stillAliveAsset = await (db.select(
          db.assets,
        )..where((a) => a.id.equals(linkedAssetId))).getSingleOrNull();
        expect(stillAliveAsset, isNotNull);
      },
    );
  });
}
