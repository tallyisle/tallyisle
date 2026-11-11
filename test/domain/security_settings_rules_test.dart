import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/domain/ledger/record_extra.dart';
import 'package:tallyisle/domain/ledger/record_relations.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/app_lock_rules.dart';
import 'package:tallyisle/domain/rules/app_settings_rules.dart';
import 'package:tallyisle/domain/rules/asset_overview.dart';
import 'package:tallyisle/domain/rules/data_health_rules.dart';
import 'package:tallyisle/domain/rules/debt_rules.dart';
import 'package:tallyisle/domain/rules/income_expense.dart';

void main() {
  group('App Lock domain rules (F-024)', () {
    test(
      'validates 4/6-digit numeric PINs and allowed lock timeouts',
      () async {
        expect(() => validatePinFormat('1234'), returnsNormally);
        expect(() => validatePinFormat('009876'), returnsNormally);
        expect(
          () => validatePinFormat('1234', expectedLength: 4),
          returnsNormally,
        );
        expect(() => validatePinFormat('12345'), throwsA(isA<Failure>()));
        expect(() => validatePinFormat('12a4'), throwsA(isA<Failure>()));
        expect(
          () => validatePinFormat('1234', expectedLength: 6),
          throwsA(isA<Failure>()),
        );
        expect(
          () => validatePinFormat('1234', expectedLength: 5),
          throwsA(isA<Failure>()),
        );

        for (final sec in <int>[0, 30, 60, 300]) {
          expect(() => validateLockTimeoutSeconds(sec), returnsNormally);
        }
        expect(() => validateLockTimeoutSeconds(15), throwsA(isA<Failure>()));
        expect(() => validateLockTimeoutSeconds(-1), throwsA(isA<Failure>()));
      },
    );

    test(
      'PBKDF2-HMAC-SHA256 (>=10,000 rounds) is deterministic per salt, unique across salts, and never stores plaintext PIN (SEC-LK-01)',
      () {
        final saltA = Uint8List.fromList(List<int>.generate(16, (i) => i + 1));
        final saltB = Uint8List.fromList(List<int>.generate(16, (i) => i + 21));

        final hashA1 = derivePinHashBytes(
          pin: '2580',
          saltBytes: saltA,
          iterations: 10000,
        );
        final hashA2 = derivePinHashBytes(
          pin: '2580',
          saltBytes: saltA,
          iterations: 10000,
        );
        final hashB = derivePinHashBytes(
          pin: '2580',
          saltBytes: saltB,
          iterations: 10000,
        );

        expect(hashA1.length, 32);
        expect(constantTimeEquals(hashA1, hashA2), isTrue);
        expect(constantTimeEquals(hashA1, hashB), isFalse);
        expect(
          constantTimeHexEquals(bytesToHex(hashA1), bytesToHex(hashA2)),
          isTrue,
        );
        expect(
          constantTimeHexEquals(bytesToHex(hashA1), bytesToHex(hashB)),
          isFalse,
        );
        expect(constantTimeHexEquals('abcd', 'abc'), isFalse);

        expect(
          () => derivePinHashBytes(
            pin: '2580',
            saltBytes: saltA,
            iterations: 9999,
          ),
          throwsA(isA<Failure>()),
        );
        expect(
          () => derivePinHashBytes(
            pin: '2580',
            saltBytes: Uint8List(15),
            iterations: 10000,
          ),
          throwsA(isA<Failure>()),
        );

        final cfg = createConfiguredAppLock(
          pin: '842691',
          nowMs: 1700000000000,
          saltBytes: saltA,
          biometricEnabled: true,
          timeoutSeconds: 60,
        );
        final encoded = cfg.encode();
        expect(encoded.contains('842691'), isFalse);
        expect(AppLockConfig.parse(encoded), cfg);

        expect(
          () => AppLockConfig.parse('{"enabled":true,"pin":"1234"}'),
          throwsA(isA<Failure>()),
        );
      },
    );

    test(
      'enforces 5-failure 30-second cooldown lockout and blocks even valid PIN during cooldown (SEC-LK-02)',
      () {
        final salt = Uint8List.fromList(List<int>.generate(16, (i) => 7 + i));
        var cfg = createConfiguredAppLock(
          pin: '1357',
          nowMs: 1000,
          saltBytes: salt,
        );

        for (var attempt = 1; attempt <= 4; attempt++) {
          final res = evaluatePinAttempt(
            config: cfg,
            candidatePin: '0000',
            nowMs: 1000 + attempt * 100,
          );
          expect(res.matched, isFalse);
          expect(res.lockedOut, isFalse);
          expect(res.remainingAttemptsBeforeCooldown, 5 - attempt);
          cfg = res.updatedConfig;
        }

        final fifth = evaluatePinAttempt(
          config: cfg,
          candidatePin: '9999',
          nowMs: 2000,
        );
        expect(fifth.matched, isFalse);
        expect(fifth.lockedOut, isTrue);
        expect(fifth.remainingCooldownSeconds, 30);
        expect(fifth.updatedConfig.cooldownUntilMs, 32000);
        cfg = fifth.updatedConfig;

        final duringCooldown = evaluatePinAttempt(
          config: cfg,
          candidatePin: '1357',
          nowMs: 15000,
        );
        expect(duringCooldown.matched, isFalse);
        expect(duringCooldown.lockedOut, isTrue);
        expect(duringCooldown.remainingCooldownSeconds, 17);

        final unlocked = evaluatePinAttempt(
          config: cfg,
          candidatePin: '1357',
          nowMs: 32000,
        );
        expect(unlocked.matched, isTrue);
        expect(unlocked.lockedOut, isFalse);
        expect(unlocked.updatedConfig.failedAttempts, 0);
        expect(unlocked.updatedConfig.cooldownUntilMs, 0);
      },
    );

    test(
      'shouldLockAfterBackground respects 0/30/60/300s thresholds and fails closed on clock rollback (SEC-LK-03)',
      () {
        final salt = Uint8List.fromList(List<int>.filled(16, 42));
        final cfg60 = createConfiguredAppLock(
          pin: '2468',
          nowMs: 10000,
          saltBytes: salt,
          timeoutSeconds: 60,
        );

        expect(
          shouldLockAfterBackground(
            config: AppLockConfig.disabled,
            backgroundedAtMs: 1000,
            nowMs: 999999,
            isInitialColdStart: true,
          ),
          isFalse,
        );
        expect(
          shouldLockAfterBackground(
            config: cfg60,
            backgroundedAtMs: null,
            nowMs: 10000,
            isInitialColdStart: true,
          ),
          isTrue,
        );
        expect(
          shouldLockAfterBackground(
            config: cfg60,
            backgroundedAtMs: 10000,
            nowMs: 69999,
          ),
          isFalse,
        );
        expect(
          shouldLockAfterBackground(
            config: cfg60,
            backgroundedAtMs: 10000,
            nowMs: 70000,
          ),
          isTrue,
        );
        expect(
          shouldLockAfterBackground(
            config: cfg60,
            backgroundedAtMs: 50000,
            nowMs: 49000,
          ),
          isTrue,
        );
      },
    );
  });

  group('ADR-012 Data Health Check domain rules', () {
    const books = <HealthBookRow>[HealthBookRow(id: 1, name: '日常账本')];
    const categories = <HealthCategoryRow>[
      HealthCategoryRow(id: 10, name: '餐饮', accountBookId: 1),
      HealthCategoryRow(id: 11, name: '工资', accountBookId: 1),
    ];
    const tags = <HealthTagRow>[HealthTagRow(tagId: 'tag-1', name: '出差')];

    test(
      'detects ordinary & debt drift while NEVER adding credit card init_money into credit card balance (DR-CD-01)',
      () {
        final assets = <HealthAssetRow>[
          // 1. Ordinary cash account: init 100.00 - expense 25.50 - lent 500 + collected 500 = 74.50, cached 99.00 (DRIFT!)
          HealthAssetRow(
            id: 1,
            name: '现金钱包',
            type: AssetType.normal,
            balanceMinor: BigInt.from(9900),
            initMoneyMinor: BigInt.from(10000),
            currency: 'CNY',
          ),
          // 2. Debt lend-out account: lent 500.00, collected 500.00 -> expected 0 & settled(2), cached 200.00 & active(0) (DRIFT!)
          HealthAssetRow(
            id: 2,
            name: '借给小王',
            type: AssetType.debt,
            subType: AssetType.debtLend,
            status: AssetStatus.active,
            balanceMinor: BigInt.from(20000),
            initMoneyMinor: BigInt.zero,
            currency: 'CNY',
          ),
          // 3. Credit card (type=6): credit limit initMoneyMinor = 20,000.00 (2000000 minor),
          //    1 expense of 350.00 -> balanceMinor = -35000. Healthy! Must NEVER add 2000000!
          HealthAssetRow(
            id: 3,
            name: '招行信用卡',
            type: AssetType.credit,
            balanceMinor: BigInt.from(-35000),
            initMoneyMinor: BigInt.from(2000000),
            currency: 'CNY',
            creditInfo: '{"bill_day":15,"repayment_day":5}',
          ),
          // 4. Credit card with initial debt at creation: limit 50,000.00, initial debt -1,200.00, no bills -> info only!
          HealthAssetRow(
            id: 4,
            name: '交行信用卡',
            type: AssetType.credit,
            balanceMinor: BigInt.from(-120000),
            initMoneyMinor: BigInt.from(5000000),
            currency: 'CNY',
            creditInfo: '{"bill_day":10,"repayment_day":28}',
          ),
        ];

        final records = <HealthRecordRow>[
          HealthRecordRow(
            recordId: 'r-exp-1',
            type: RecordType.expense,
            moneyMinor: BigInt.from(2550),
            recordTime: 1700000100000,
            recordCatId: 10,
            assetId: 1,
            accountBookId: 1,
          ),
          HealthRecordRow(
            recordId: 'r-lend-1',
            type: RecordType.lendOut,
            moneyMinor: BigInt.from(50000),
            recordTime: 1700000200000,
            fromAssetId: 1,
            toAssetId: 2,
            accountBookId: 1,
          ),
          HealthRecordRow(
            recordId: 'r-collect-1',
            type: RecordType.collect,
            moneyMinor: BigInt.from(50000),
            recordTime: 1700000300000,
            fromAssetId: 2,
            toAssetId: 1,
            accountBookId: 1,
          ),
          HealthRecordRow(
            recordId: 'r-cc-exp-1',
            type: RecordType.expense,
            moneyMinor: BigInt.from(35000),
            recordTime: 1700000400000,
            recordCatId: 10,
            assetId: 3,
            accountBookId: 1,
          ),
        ];

        final report = evaluateDataHealth(
          assets: assets,
          records: records,
          books: books,
          categories: categories,
          tags: tags,
          tagRecords: const [
            HealthTagRecordRow(tagId: 'tag-1', recordId: 'r-exp-1'),
            HealthTagRecordRow(tagId: 'tag-1', recordId: 'missing-rec'),
          ],
          nowMs: 1700009999000,
        );

        expect(report.ordinaryRepairs.length, 1);
        expect(report.ordinaryRepairs.single.assetId, 1);
        expect(
          report.ordinaryRepairs.single.expectedBalanceMinor,
          BigInt.from(7450),
        );

        expect(report.debtRepairs.length, 1);
        expect(report.debtRepairs.single.assetId, 2);
        expect(report.debtRepairs.single.expectedBalanceMinor, BigInt.zero);
        expect(report.debtRepairs.single.expectedStatus, AssetStatus.settled);

        expect(report.orphanTagRepairs.length, 1);
        expect(report.orphanTagRepairs.single.recordId, 'missing-rec');

        expect(
          report.ordinaryRepairs.any((p) => p.assetId == 3 || p.assetId == 4),
          isFalse,
        );
        expect(
          report.issues.any(
            (i) => i.assetId == 3 && i.severity != DataHealthSeverity.info,
          ),
          isFalse,
        );
        final card4Issues = report.issues.where((i) => i.assetId == 4).toList();
        expect(card4Issues.length, 1);
        expect(
          card4Issues.single.kind,
          DataHealthIssueKind.creditInitialOffsetInfo,
        );
        expect(card4Issues.single.severity, DataHealthSeverity.info);
        expect(card4Issues.single.repairable, isFalse);

        // Verify manually settled v2 debt (sv=2, s=true, status=settled, balance=0) is respected and NOT reopened,
        // whereas a corrupted settled v2 debt with manualSettled=false IS detected and repaired!
        final manualSettledReport = evaluateDataHealth(
          assets: <HealthAssetRow>[
            HealthAssetRow(
              id: 20,
              name: '已免除尾款借出',
              type: AssetType.debt,
              subType: AssetType.debtLend,
              status: AssetStatus.settled,
              balanceMinor: BigInt.zero,
              initMoneyMinor: BigInt.zero,
              currency: 'CNY',
              loanInfo: LoanInfo(
                schemaVersion: 2,
                manualSettled: true,
                totalDebtMoneyMinor: BigInt.from(50000),
              ).encode(),
            ),
            HealthAssetRow(
              id: 21,
              name: '未手动结清却被误标结清借出',
              type: AssetType.debt,
              subType: AssetType.debtLend,
              status: AssetStatus.settled,
              balanceMinor: BigInt.zero,
              initMoneyMinor: BigInt.zero,
              currency: 'CNY',
              loanInfo: LoanInfo(
                schemaVersion: 2,
                manualSettled: false,
                totalDebtMoneyMinor: BigInt.from(50000),
              ).encode(),
            ),
          ],
          records: <HealthRecordRow>[
            HealthRecordRow(
              recordId: 'r-ms-lend',
              type: RecordType.lendOut,
              moneyMinor: BigInt.from(50000),
              recordTime: 1700000100000,
              toAssetId: 20,
              accountBookId: 1,
            ),
            HealthRecordRow(
              recordId: 'r-accidental-settled-lend',
              type: RecordType.lendOut,
              moneyMinor: BigInt.from(50000),
              recordTime: 1700000100000,
              toAssetId: 21,
              accountBookId: 1,
            ),
          ],
          books: books,
          categories: categories,
          tags: tags,
          tagRecords: const [],
          nowMs: 1700009999000,
        );
        expect(manualSettledReport.debtRepairs.length, 1);
        expect(manualSettledReport.debtRepairs.single.assetId, 21);
        expect(
          manualSettledReport.debtRepairs.single.expectedBalanceMinor,
          BigInt.from(50000),
        );
        expect(
          manualSettledReport.debtRepairs.single.expectedStatus,
          AssetStatus.active,
        );
      },
    );

    test(
      'flags negative credit card limit, invalid credit_info cycle days, broken rel_info, missing refs, malformed JSON, and skips auto-repair on tainted accounts',
      () {
        final brokenRel =
            (RecordRelations()
                  ..refunds = const BillLinks(originId: 'non-existent-origin'))
                .encode();

        final report = evaluateDataHealth(
          assets: <HealthAssetRow>[
            HealthAssetRow(
              id: 1,
              name: '问题普通账户',
              type: AssetType.normal,
              balanceMinor: BigInt.from(5000),
              initMoneyMinor: BigInt.zero,
              currency: 'CNY',
            ),
            HealthAssetRow(
              id: 6,
              name: '异常信用卡',
              type: AssetType.credit,
              balanceMinor: BigInt.zero,
              initMoneyMinor: BigInt.from(-500),
              currency: 'CNY',
              creditInfo: '{"bill_day":99,"repayment_day":0}',
            ),
          ],
          records: <HealthRecordRow>[
            HealthRecordRow(
              recordId: 'r-bad-json',
              type: RecordType.expense,
              moneyMinor: BigInt.from(1000),
              recordTime: 1700000100000,
              recordCatId: 999,
              assetId: 1,
              accountBookId: 999,
              extraInfo: '{not-valid-json',
              relInfo: brokenRel,
            ),
          ],
          books: books,
          categories: categories,
          tags: tags,
          tagRecords: const [],
          auxJsonRows: const [
            HealthAuxJsonRow(
              table: 'budget',
              rowKey: 'id=1',
              column: 'extra_info',
              rawJson: '[1,2,3]',
            ),
          ],
          nowMs: 1700000500000,
        );

        final kinds = report.issues.map((i) => i.kind).toSet();
        expect(kinds, contains(DataHealthIssueKind.creditNegativeLimit));
        expect(kinds, contains(DataHealthIssueKind.missingBookRef));
        expect(kinds, contains(DataHealthIssueKind.missingCategoryRef));
        expect(kinds, contains(DataHealthIssueKind.brokenRelationLink));
        expect(kinds, contains(DataHealthIssueKind.malformedJson));
        expect(
          report.issues.any(
            (i) =>
                i.assetId == 6 && i.kind == DataHealthIssueKind.malformedJson,
          ),
          isTrue,
        );
        // Asset 1 is tainted by r-bad-json, so ordinaryRepairs must NOT overwrite its balance
        expect(report.ordinaryRepairs, isEmpty);
      },
    );

    test(
      'reconciles cross-currency transfers using extra_info CurrencySnapshot without false drift',
      () {
        final fxExtra =
            (RecordExtra()
                  ..currency = CurrencySnapshot(
                    sourceCode: 'USD',
                    sourceGross: BigInt.from(10000),
                    assetCode: 'CNY',
                    assetNet: BigInt.from(72000),
                  ))
                .encode();

        final rates = RateTable(const {'CNY': '1', 'USD': '7.2'});
        final report = evaluateDataHealth(
          assets: <HealthAssetRow>[
            HealthAssetRow(
              id: 1,
              name: '美元账户',
              type: AssetType.normal,
              balanceMinor: BigInt.zero,
              initMoneyMinor: BigInt.from(10000),
              currency: 'USD',
            ),
            HealthAssetRow(
              id: 2,
              name: '人民币储蓄',
              type: 1, // savings/deposit account
              balanceMinor: BigInt.from(72000),
              initMoneyMinor: BigInt.zero,
              currency: 'CNY',
            ),
          ],
          records: <HealthRecordRow>[
            HealthRecordRow(
              recordId: 'r-fx-1',
              type: RecordType.transfer,
              moneyMinor: BigInt.from(10000),
              recordTime: 1700000100000,
              fromAssetId: 1,
              toAssetId: 2,
              accountBookId: 1,
              extraInfo: fxExtra,
            ),
          ],
          books: books,
          categories: categories,
          tags: tags,
          tagRecords: const [],
          rates: rates,
          nowMs: 1700000200000,
        );

        expect(report.isHealthy, isTrue);
        expect(report.ordinaryRepairs, isEmpty);
      },
    );
  });

  group('AppSettings & StatStory domain rules (F-038)', () {
    test(
      'normalizes theme hex, validates record types, and round-trips JSON',
      () {
        expect(normalizeThemeSeedHex('#138eaa'), '138EAA');
        expect(normalizeThemeSeedHex(' 2e7d32 '), '2E7D32');
        expect(() => normalizeThemeSeedHex('ZZZZZZ'), throwsA(isA<Failure>()));
        expect(() => normalizeThemeSeedHex('123'), throwsA(isA<Failure>()));

        expect(
          () => const AppSettings(
            defaultRecordType: RecordType.balanceAdjust,
          ).validated(),
          throwsA(isA<Failure>()),
        );

        const custom = AppSettings(
          showBalanceChangeRecordOnHome: true,
          showHomeAssetSummaryBanner: false,
          showHomeBudgetCard: false,
          defaultRecordType: RecordType.transfer,
          themeMode: AppThemeModePreference.dark,
          themeSeedHex: '2E7D32',
        );
        expect(AppSettings.parse(custom.encode()), custom);
        expect(AppSettings.parse(null), AppSettings.defaults);
        expect(() => AppSettings.parse('{broken'), throwsA(isA<Failure>()));
      },
    );

    test(
      'validates StatStoryDraft and formats exact BigInt/Money narratives',
      () {
        final draft = const StatStoryDraft(
          story: '  本月结余稳步提升  ',
          bookId: 1,
          sdate: 1000,
          edate: 2000,
          dsection: '  2026年11月 ',
        ).validated();
        expect(draft.story, '本月结余稳步提升');
        expect(draft.dsection, '2026年11月');

        expect(
          () => const StatStoryDraft(
            story: '   ',
            bookId: 1,
            sdate: 1000,
            edate: 2000,
          ).validated(),
          throwsA(isA<Failure>()),
        );
        expect(
          () => const StatStoryDraft(
            story: '有效内容',
            bookId: 1,
            sdate: 3000,
            edate: 2000,
          ).validated(),
          throwsA(isA<Failure>()),
        );

        final emptyNarrative = buildStatStoryNarrative(
          periodLabel: '2026年11月',
          bookLabel: '日常账本',
          recordCount: 0,
          summary: IncomeExpense.zero,
        );
        expect(emptyNarrative, contains('暂无收支流水'));

        final richNarrative = buildStatStoryNarrative(
          periodLabel: '2026年11月',
          bookLabel: '日常账本',
          recordCount: 3,
          summary: IncomeExpense(
            income: BigInt.from(1200000),
            expense: BigInt.from(34567),
            incomeCount: 1,
            expenseCount: 2,
          ),
          topExpenseCategoryName: '餐饮',
          topExpenseCategoryMinor: BigInt.from(21050),
        );
        expect(richNarrative, contains('总收入 12000.00 元'));
        expect(richNarrative, contains('总支出 345.67 元'));
        expect(richNarrative, contains('结余 11654.33 元'));
        expect(richNarrative, contains('「餐饮」（210.50 元）'));
      },
    );
  });
}
