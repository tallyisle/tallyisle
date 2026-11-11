import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/domain/ledger/effects.dart';
import 'package:tallyisle/domain/ledger/record_extra.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/asset_overview.dart';
import 'package:tallyisle/domain/rules/debt_rules.dart';

void main() {
  group('CE-DM-01 polarity contract', () {
    test(
      'countedInNetWorth maps to inverted DB flag matching OverviewAccount',
      () {
        final effCounted = debtEffectiveAssetFlag(countedInNetWorth: true);
        final effExcluded = debtEffectiveAssetFlag(countedInNetWorth: false);

        expect(effCounted, 0);
        expect(effExcluded, 1);
        expect(isDebtCountedInNetWorth(effCounted), isTrue);
        expect(isDebtCountedInNetWorth(effExcluded), isFalse);

        final countedOverview = OverviewAccount(
          id: 1,
          type: AssetType.debt,
          subType: AssetType.debtLend,
          balanceMinor: BigInt.from(50000),
          isEffectiveAsset: effCounted,
        );
        final excludedOverview = OverviewAccount(
          id: 2,
          type: AssetType.debt,
          subType: AssetType.debtLend,
          balanceMinor: BigInt.from(50000),
          isEffectiveAsset: effExcluded,
        );
        expect(countedOverview.counted, isTrue);
        expect(excludedOverview.counted, isFalse);
      },
    );
  });

  group('CE-DM-06 book isolation', () {
    test('bound debts only show in bound books or all-books view', () {
      expect(isDebtVisibleInBook(boundBookIds: {1}, queryBookId: 1), isTrue);
      expect(isDebtVisibleInBook(boundBookIds: {1}, queryBookId: 2), isFalse);
      expect(isDebtVisibleInBook(boundBookIds: {1}, queryBookId: null), isTrue);
    });

    test(
      'unbound legacy debts show only in default book or all-books view',
      () {
        expect(
          isDebtVisibleInBook(boundBookIds: const {}, queryBookId: 1),
          isTrue,
        );
        expect(
          isDebtVisibleInBook(boundBookIds: const {}, queryBookId: 2),
          isFalse,
        );
        expect(
          isDebtVisibleInBook(boundBookIds: const {}, queryBookId: null),
          isTrue,
        );
      },
    );
  });

  group('R2 record specs and timestamps', () {
    test('timestamps preserve +1ms principal and +2ms interest ordering', () {
      const baseMs = 1700000000000;
      expect(principalRecordTimestamp(baseMs), baseMs + 1);
      expect(interestRecordTimestamp(baseMs), baseMs + 2);
      expect(
        interestRecordTimestamp(baseMs),
        greaterThan(principalRecordTimestamp(baseMs)),
      );
    });

    test(
      'record directions align with effects.dart funding account deltas',
      () {
        const debtId = 201;
        const bankId = 101;
        final amount = BigInt.from(10000);

        // 5: 借入 (funding receives +amount)
        final borrowSpec = buildPrincipalRecordSpec(
          debtSubType: AssetType.debtBorrow,
          debtId: debtId,
          fundingAssetId: bankId,
          isRepayment: false,
        );
        expect(borrowSpec.type, RecordType.borrowIn);
        expect(borrowSpec.fromAssetId, debtId);
        expect(borrowSpec.toAssetId, bankId);
        expect(
          balanceEffects(
            EntryFacts(
              type: borrowSpec.type,
              subType: borrowSpec.subType,
              moneyMinor: amount,
              fromAssetId: borrowSpec.fromAssetId,
              toAssetId: borrowSpec.toAssetId,
            ),
          ),
          [AssetDelta(bankId, amount)],
        );

        // 7: 还款 (funding pays -amount)
        final repaySpec = buildPrincipalRecordSpec(
          debtSubType: AssetType.debtBorrow,
          debtId: debtId,
          fundingAssetId: bankId,
          isRepayment: true,
        );
        expect(repaySpec.type, RecordType.repay);
        expect(repaySpec.fromAssetId, bankId);
        expect(repaySpec.toAssetId, debtId);
        expect(
          balanceEffects(
            EntryFacts(
              type: repaySpec.type,
              subType: repaySpec.subType,
              moneyMinor: amount,
              fromAssetId: repaySpec.fromAssetId,
              toAssetId: repaySpec.toAssetId,
            ),
          ),
          [AssetDelta(bankId, -amount)],
        );

        // 6: 借出 (funding pays -amount)
        final lendSpec = buildPrincipalRecordSpec(
          debtSubType: AssetType.debtLend,
          debtId: debtId,
          fundingAssetId: bankId,
          isRepayment: false,
        );
        expect(lendSpec.type, RecordType.lendOut);
        expect(lendSpec.fromAssetId, bankId);
        expect(lendSpec.toAssetId, debtId);
        expect(
          balanceEffects(
            EntryFacts(
              type: lendSpec.type,
              subType: lendSpec.subType,
              moneyMinor: amount,
              fromAssetId: lendSpec.fromAssetId,
              toAssetId: lendSpec.toAssetId,
            ),
          ),
          [AssetDelta(bankId, -amount)],
        );

        // 8: 收款 (funding receives +amount)
        final collectSpec = buildPrincipalRecordSpec(
          debtSubType: AssetType.debtLend,
          debtId: debtId,
          fundingAssetId: bankId,
          isRepayment: true,
        );
        expect(collectSpec.type, RecordType.collect);
        expect(collectSpec.fromAssetId, debtId);
        expect(collectSpec.toAssetId, bankId);
        expect(
          balanceEffects(
            EntryFacts(
              type: collectSpec.type,
              subType: collectSpec.subType,
              moneyMinor: amount,
              fromAssetId: collectSpec.fromAssetId,
              toAssetId: collectSpec.toAssetId,
            ),
          ),
          [AssetDelta(bankId, amount)],
        );

        // 10 sub 0: 利息支出 (funding pays -amount)
        final expIntSpec = buildInterestRecordSpec(
          debtSubType: AssetType.debtBorrow,
          debtId: debtId,
          fundingAssetId: bankId,
          interestExcludeBudget: true,
        );
        expect(expIntSpec.type, RecordType.debtInterest);
        expect(expIntSpec.subType, RecordDirection.expense);
        expect(expIntSpec.fromAssetId, bankId);
        expect(expIntSpec.toAssetId, debtId);
        expect(expIntSpec.excludeBudget, isTrue);
        expect(
          balanceEffects(
            EntryFacts(
              type: expIntSpec.type,
              subType: expIntSpec.subType,
              moneyMinor: amount,
              fromAssetId: expIntSpec.fromAssetId,
              toAssetId: expIntSpec.toAssetId,
            ),
          ),
          [AssetDelta(bankId, -amount)],
        );

        // 10 sub 1: 利息收入 (funding receives +amount, excludeBudget forced false)
        final incIntSpec = buildInterestRecordSpec(
          debtSubType: AssetType.debtLend,
          debtId: debtId,
          fundingAssetId: bankId,
          interestExcludeBudget: true,
        );
        expect(incIntSpec.type, RecordType.debtInterest);
        expect(incIntSpec.subType, RecordDirection.income);
        expect(incIntSpec.fromAssetId, debtId);
        expect(incIntSpec.toAssetId, bankId);
        expect(incIntSpec.excludeBudget, isFalse);
        expect(
          balanceEffects(
            EntryFacts(
              type: incIntSpec.type,
              subType: incIntSpec.subType,
              moneyMinor: amount,
              fromAssetId: incIntSpec.fromAssetId,
              toAssetId: incIntSpec.toAssetId,
            ),
          ),
          [AssetDelta(bankId, amount)],
        );
      },
    );
  });

  group('Golden vectors: DR-DM-04, CE-DM-07, DM-12, ASYM-DM-01, CE-DM-02', () {
    test(
      'DR-DM-04: lending 1000 -> collect 300 (30.0%) -> collect 700 auto-settles (100.0%)',
      () {
        final info0 = LoanInfo(startDate: 1000, endDate: -1);
        final step1 = recomputeDebtPrincipal(
          debtSubType: AssetType.debtLend,
          currentStatus: AssetStatus.active,
          currentLoanInfo: info0,
          records: [
            DebtRecordEntry(
              recordId: 'r1',
              type: RecordType.lendOut,
              moneyMinor: BigInt.from(100000),
              recordTime: 1001,
            ),
            DebtRecordEntry(
              recordId: 'r2',
              type: RecordType.collect,
              moneyMinor: BigInt.from(30000),
              recordTime: 2001,
            ),
          ],
        );

        expect(step1.status, AssetStatus.active);
        expect(step1.balanceMinor, BigInt.from(70000));
        expect(step1.totalPrincipalMinor, BigInt.from(100000));
        expect(step1.totalRepaidMinor, BigInt.from(30000));
        expect(
          formatDebtProgress(
            status: step1.status,
            totalPrincipalMinor: step1.totalPrincipalMinor,
            repaidPrincipalMinor: step1.totalRepaidMinor,
          ),
          '30.0%',
        );

        final step2 = recomputeDebtPrincipal(
          debtSubType: AssetType.debtLend,
          currentStatus: step1.status,
          currentLoanInfo: step1.loanInfo,
          records: [
            DebtRecordEntry(
              recordId: 'r1',
              type: RecordType.lendOut,
              moneyMinor: BigInt.from(100000),
              recordTime: 1001,
            ),
            DebtRecordEntry(
              recordId: 'r2',
              type: RecordType.collect,
              moneyMinor: BigInt.from(30000),
              recordTime: 2001,
            ),
            DebtRecordEntry(
              recordId: 'r3',
              type: RecordType.collect,
              moneyMinor: BigInt.from(70000),
              recordTime: 3001,
            ),
          ],
        );

        expect(step2.status, AssetStatus.settled);
        expect(step2.balanceMinor, BigInt.zero);
        expect(step2.loanInfo.manualSettled, isFalse);
        expect(
          formatDebtProgress(
            status: step2.status,
            totalPrincipalMinor: step2.totalPrincipalMinor,
            repaidPrincipalMinor: step2.totalRepaidMinor,
          ),
          '100.0%',
        );

        // Removing the second collection from an auto-settled debt reopens it cleanly.
        final reopenedFromAuto = recomputeDebtPrincipal(
          debtSubType: AssetType.debtLend,
          currentStatus: step2.status,
          currentLoanInfo: step2.loanInfo,
          records: [
            DebtRecordEntry(
              recordId: 'r1',
              type: RecordType.lendOut,
              moneyMinor: BigInt.from(100000),
              recordTime: 1001,
            ),
            DebtRecordEntry(
              recordId: 'r2',
              type: RecordType.collect,
              moneyMinor: BigInt.from(30000),
              recordTime: 2001,
            ),
          ],
        );
        expect(reopenedFromAuto.status, AssetStatus.active);
        expect(reopenedFromAuto.balanceMinor, BigInt.from(70000));
      },
    );

    test(
      'CE-DM-07: exact BigInt 1-decimal HALF_UP progress formatting (100/300 -> 33.3%)',
      () {
        expect(
          formatDebtProgress(
            status: AssetStatus.active,
            totalPrincipalMinor: BigInt.from(30000),
            repaidPrincipalMinor: BigInt.from(10000),
          ),
          '33.3%',
        );
        expect(
          formatDebtProgress(
            status: AssetStatus.active,
            totalPrincipalMinor: BigInt.from(30000),
            repaidPrincipalMinor: BigInt.from(20000),
          ),
          '66.7%',
        );
        expect(
          formatDebtProgress(
            status: AssetStatus.settled,
            totalPrincipalMinor: BigInt.from(30000),
            repaidPrincipalMinor: BigInt.from(10000),
          ),
          '100.0%',
        );
        expect(
          formatDebtProgress(
            status: AssetStatus.active,
            totalPrincipalMinor: BigInt.zero,
            repaidPrincipalMinor: BigInt.zero,
          ),
          '0.0%',
        );
      },
    );

    test(
      'DM-12: type=10 interest records do not affect principal recomputation and sum into totalInterest',
      () {
        final records = [
          DebtRecordEntry(
            recordId: 'p1',
            type: RecordType.borrowIn,
            moneyMinor: BigInt.from(60000),
            recordTime: 1001,
          ),
          DebtRecordEntry(
            recordId: 'i1',
            type: RecordType.debtInterest,
            subType: RecordDirection.expense,
            moneyMinor: BigInt.from(5000),
            recordTime: 2002,
          ),
          DebtRecordEntry(
            recordId: 'i2',
            type: RecordType.debtInterest,
            subType: RecordDirection.expense,
            moneyMinor: BigInt.from(1500),
            recordTime: 3002,
          ),
        ];

        final res = recomputeDebtPrincipal(
          debtSubType: AssetType.debtBorrow,
          currentStatus: AssetStatus.active,
          currentLoanInfo: LoanInfo(startDate: 1000),
          records: records,
        );
        expect(res.totalPrincipalMinor, BigInt.from(60000));
        expect(res.remainingPrincipalMinor, BigInt.from(60000));
        expect(res.balanceMinor, BigInt.from(60000));
        expect(computeDebtTotalInterest(records), BigInt.from(6500));
      },
    );

    test(
      'ASYM-DM-01: manually settled debt stays status=2 on recalibration/edit until explicit reopen',
      () {
        final manualLoanInfo = LoanInfo(
          schemaVersion: 2,
          startDate: 1000,
          totalDebtMoneyMinor: BigInt.from(100000),
          manualSettled: true,
          settledSnapshotMinor: BigInt.from(60000),
        );
        final records = [
          DebtRecordEntry(
            recordId: 'b1',
            type: RecordType.borrowIn,
            moneyMinor: BigInt.from(100000),
            recordTime: 1001,
          ),
          DebtRecordEntry(
            recordId: 'p1',
            type: RecordType.repay,
            moneyMinor: BigInt.from(40000),
            recordTime: 2001,
          ),
        ];

        final recalibrated = recomputeDebtPrincipal(
          debtSubType: AssetType.debtBorrow,
          currentStatus: AssetStatus.settled,
          currentLoanInfo: manualLoanInfo,
          records: records,
        );
        expect(recalibrated.status, AssetStatus.settled);
        expect(recalibrated.balanceMinor, BigInt.zero);
        expect(recalibrated.loanInfo.manualSettled, isTrue);

        final reopened = recomputeDebtPrincipal(
          debtSubType: AssetType.debtBorrow,
          currentStatus: AssetStatus.settled,
          currentLoanInfo: manualLoanInfo,
          records: records,
          allowReopen: true,
        );
        expect(reopened.status, AssetStatus.active);
        expect(reopened.balanceMinor, BigInt.from(60000));
        expect(reopened.loanInfo.manualSettled, isFalse);
      },
    );

    test(
      'CE-DM-02: FX appreciation with positive foreign position keeps proportional cost instead of settling',
      () {
        // Lend 100 USD @ 7.50 = 750.00 CNY; collect 95 USD @ 8.00 = 760.00 CNY.
        // Remaining 5 USD > 0 -> proportional cost 750 * (5 / 100) = 37.50 CNY.
        final res = recomputeDebtPrincipal(
          debtSubType: AssetType.debtLend,
          currentStatus: AssetStatus.active,
          currentLoanInfo: LoanInfo(startDate: 1000),
          debtCurrency: 'CNY',
          records: [
            DebtRecordEntry(
              recordId: 'l1',
              type: RecordType.lendOut,
              moneyMinor: BigInt.from(75000),
              recordTime: 1001,
              currency: CurrencySnapshot(
                sourceCode: 'USD',
                sourceGross: BigInt.from(10000),
                assetCode: 'CNY',
                assetNet: BigInt.from(75000),
                baseCode: 'CNY',
                baseAmount: BigInt.from(75000),
              ),
            ),
            DebtRecordEntry(
              recordId: 'c1',
              type: RecordType.collect,
              moneyMinor: BigInt.from(76000),
              recordTime: 2001,
              currency: CurrencySnapshot(
                sourceCode: 'USD',
                sourceGross: BigInt.from(9500),
                assetCode: 'CNY',
                assetNet: BigInt.from(76000),
                baseCode: 'CNY',
                baseAmount: BigInt.from(76000),
              ),
            ),
          ],
        );

        expect(res.status, AssetStatus.active);
        expect(res.balanceMinor, BigInt.from(3750));
        expect(res.loanInfo.currencyPositions.single.currencyCode, 'USD');
        expect(
          res.loanInfo.currencyPositions.single.principalBalanceMinor,
          BigInt.from(500),
        );
      },
    );
  });

  group('LoanInfo JSON and DebtOverviewSummary', () {
    test('LoanInfo preserves unknown keys and rejects corrupt JSON', () {
      final parsed = LoanInfo.parse(
        '{"sv":2,"startDate":100,"endDate":200,"totalDebtMoney":"50000",'
        '"s":true,"sb":"12000","cp":[{"cc":"usd","pb":"12000","tp":"50000"}],'
        '"customKey":"keepMe"}',
      );
      expect(parsed.schemaVersion, 2);
      expect(parsed.totalDebtMoneyMinor, BigInt.from(50000));
      expect(parsed.manualSettled, isTrue);
      expect(parsed.settledSnapshotMinor, BigInt.from(12000));
      expect(parsed.currencyPositions.single.currencyCode, 'USD');

      final reencoded = LoanInfo.parse(parsed.encode());
      expect(reencoded.toJson()['customKey'], 'keepMe');

      expect(
        () => LoanInfo.parse('{bad json'),
        throwsA(
          isA<Failure>().having((f) => f.code, 'code', FailureCode.corruptData),
        ),
      );
    });

    test(
      'computeDebtOverview filters settled/excluded debts and converts FX',
      () {
        final rates = RateTable({'CNY': '1', 'USD': '0.125'}); // 1 USD = 8 CNY
        final summary = computeDebtOverview([
          DebtSummaryInput(
            subType: AssetType.debtLend,
            status: AssetStatus.active,
            balanceMinor: BigInt.from(20000), // 200 CNY
            isEffectiveAsset: 0, // counted
          ),
          DebtSummaryInput(
            subType: AssetType.debtLend,
            status: AssetStatus.active,
            balanceMinor: BigInt.from(5000), // 50 USD -> 400 CNY
            isEffectiveAsset: 0, // counted
            currency: 'USD',
          ),
          DebtSummaryInput(
            subType: AssetType.debtBorrow,
            status: AssetStatus.active,
            balanceMinor: BigInt.from(60000), // 600 CNY
            isEffectiveAsset: 0, // counted
          ),
          DebtSummaryInput(
            subType: AssetType.debtBorrow,
            status: AssetStatus.active,
            balanceMinor: BigInt.from(50000), // excluded!
            isEffectiveAsset: 1,
          ),
          DebtSummaryInput(
            subType: AssetType.debtLend,
            status: AssetStatus.settled, // settled!
            balanceMinor: BigInt.from(30000),
            isEffectiveAsset: 0,
          ),
        ], rates);

        expect(summary.totalReceivableMinor, BigInt.from(60000)); // 200 + 400
        expect(summary.totalPayableMinor, BigInt.from(60000)); // 600
        expect(summary.netReceivableMinor, BigInt.zero);
      },
    );
  });
}
