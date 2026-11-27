import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/domain/ledger/asset_json.dart';
import 'package:tallyisle/domain/ledger/record_relations.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/budget_rules.dart';
import 'package:tallyisle/domain/rules/cloud_sync_merge_rules.dart';
import 'package:tallyisle/domain/rules/debt_rules.dart';
import 'package:tallyisle/domain/rules/fixed_deposit.dart';
import 'package:tallyisle/domain/rules/installment_rules.dart';
import 'package:tallyisle/domain/rules/periodic_records.dart';
import 'package:tallyisle/domain/rules/savings_plan.dart';
import 'package:tallyisle/domain/rules/tally_backup.dart';

Map<String, List<Map<String, Object?>>> _seedTables({
  List<Map<String, Object?>>? assets,
  List<Map<String, Object?>>? categories,
  List<Map<String, Object?>>? records,
  List<Map<String, Object?>>? budgets,
  List<Map<String, Object?>>? tags,
  List<Map<String, Object?>>? tagRecords,
  List<Map<String, Object?>>? installments,
  List<Map<String, Object?>>? recordPeriods,
  List<Map<String, Object?>>? wishes,
  List<Map<String, Object?>>? remarks,
  List<Map<String, Object?>>? moneySavePlans,
  List<Map<String, Object?>>? moneySavePlanRecords,
  List<Map<String, Object?>>? assetBooks,
  List<Map<String, Object?>>? statStories,
  List<Map<String, Object?>>? notes,
  List<Map<String, Object?>>? currencies,
}) {
  final map = <String, List<Map<String, Object?>>>{
    for (final t in tallyBusinessTables) t: <Map<String, Object?>>[],
  };
  map['account_book'] = <Map<String, Object?>>[
    <String, Object?>{
      'id': 1,
      'type': 1,
      'name': '默认账本',
      'cover': '',
      'sort': 1,
      'status': 0,
      'start_day': 1,
      'create_date': 1000,
      'display_way': 0,
      'extra_info': null,
    },
  ];
  map['currency'] =
      currencies ??
      <Map<String, Object?>>[
        <String, Object?>{
          'code': 'CNY',
          'name': '人民币',
          'symbol': '¥',
          'type': 0,
          'rate_to_anchor': '1',
          'anchor_code': 'CNY',
          'rate_refresh_time': 0,
          'icon': '',
          'enable': true,
        },
      ];
  map['record_category'] =
      categories ??
      <Map<String, Object?>>[
        <String, Object?>{
          'id': 1,
          'name': '餐饮',
          'icon': 'food',
          'type': 0,
          'sort': 1,
          'parent_cat_id': noRef,
          'color_fill': null,
          'platform_id': noRef,
          'account_book_id': 1,
          'is_hide': false,
          'extra_info': null,
        },
        <String, Object?>{
          'id': 2,
          'name': '工资',
          'icon': 'salary',
          'type': 1,
          'sort': 2,
          'parent_cat_id': noRef,
          'color_fill': null,
          'platform_id': noRef,
          'account_book_id': 1,
          'is_hide': false,
          'extra_info': null,
        },
      ];
  map['asset'] =
      assets ??
      <Map<String, Object?>>[
        _ordinaryAsset(id: 1, name: '现金', initMinor: 100000, balMinor: 100000),
      ];
  if (records != null) map['record'] = records;
  if (budgets != null) map['budget'] = budgets;
  if (tags != null) map['tag'] = tags;
  if (tagRecords != null) map['tag_record'] = tagRecords;
  if (installments != null) map['installment'] = installments;
  if (recordPeriods != null) map['record_period'] = recordPeriods;
  if (wishes != null) map['wish'] = wishes;
  if (remarks != null) map['remark'] = remarks;
  if (moneySavePlans != null) map['money_save_plan'] = moneySavePlans;
  if (moneySavePlanRecords != null) {
    map['money_save_plan_record'] = moneySavePlanRecords;
  }
  if (assetBooks != null) map['asset_book'] = assetBooks;
  if (statStories != null) map['stat_story'] = statStories;
  if (notes != null) map['note'] = notes;
  return map;
}

Map<String, Object?> _ordinaryAsset({
  required int id,
  required String name,
  required int initMinor,
  required int balMinor,
  int usedTimes = 0,
  bool isDefault = false,
  String? color,
  String? fixedDepositInfo,
}) => <String, Object?>{
  'id': id,
  'name': name,
  'balance_minor': encodeMinorJson(BigInt.from(balMinor)),
  'type': AssetType.normal,
  'sub_type': -1,
  'create_date': 1000,
  'sort': id,
  'icon': 'wallet',
  'remark': null,
  'init_money_minor': encodeMinorJson(BigInt.from(initMinor)),
  'is_default': isDefault,
  'is_effective_asset': 1,
  'used_times': usedTimes,
  'color': color,
  'status': AssetStatus.active,
  'extra_info': null,
  'loan_info': null,
  'credit_info': null,
  'fixed_deposit_info': fixedDepositInfo,
  'group_name': null,
  'currency': 'CNY',
};

Map<String, Object?> _record({
  required String id,
  int type = RecordType.expense,
  int subType = RecordDirection.none,
  required int moneyMinor,
  int recordTime = 1700000000000,
  int catId = 1,
  int assetId = 1,
  int fromAssetId = noRef,
  int toAssetId = noRef,
  int bookId = 1,
  int periodId = noRef,
  String? installment,
  String? images,
  String? relInfo,
  String? extraInfo,
  String remark = '',
}) => <String, Object?>{
  'record_id': id,
  'type': type,
  'sub_type': subType,
  'money_minor': encodeMinorJson(BigInt.from(moneyMinor)),
  'remark': remark,
  'record_time': recordTime,
  'record_cat_id': catId,
  'asset_id': assetId,
  'from_asset_id': fromAssetId,
  'to_asset_id': toAssetId,
  'account_book_id': bookId,
  'exclude_budget': false,
  'exclude_ex_in': false,
  'platform_id': noRef,
  'period_id': periodId,
  'installment': installment,
  'images': images,
  'rel_info': relInfo,
  'discount_minor': null,
  'extra_info': extraInfo,
  'create_date': recordTime,
};

void main() {
  group('Three-Way Accounting-Conserving Merge Pure Rules', () {
    test(
      'merges independent bills across devices and conserves ordinary, credit-card (ADR-012) & debt balances',
      () {
        final creditAssetBase = <String, Object?>{
          'id': 2,
          'name': '招行信用卡',
          'balance_minor': '-20000',
          'type': AssetType.credit,
          'sub_type': -1,
          'create_date': 1000,
          'sort': 2,
          'icon': 'card',
          'remark': null,
          'init_money_minor':
              '5000000', // 50,000.00 credit limit, NEVER balance!
          'is_default': false,
          'is_effective_asset': 1,
          'used_times': 1,
          'color': '#FF5500',
          'status': AssetStatus.active,
          'extra_info': null,
          'loan_info': null,
          'credit_info':
              (CreditInfo()
                    ..billDay = 5
                    ..repaymentDay = 23)
                  .encode(),
          'fixed_deposit_info': null,
          'group_name': null,
          'currency': 'CNY',
        };
        final debtAssetBase = <String, Object?>{
          'id': 3,
          'name': '借给小王',
          'balance_minor': '100000',
          'type': AssetType.debt,
          'sub_type': AssetType.debtLend,
          'create_date': 1000,
          'sort': 3,
          'icon': 'debt',
          'remark': null,
          'init_money_minor': '0',
          'is_default': false,
          'is_effective_asset': 1,
          'used_times': 1,
          'color': null,
          'status': AssetStatus.active,
          'extra_info': null,
          'loan_info': LoanInfo(
            totalDebtMoneyMinor: BigInt.from(100000),
          ).encode(),
          'credit_info': null,
          'fixed_deposit_info': null,
          'group_name': null,
          'currency': 'CNY',
        };

        final baseLendRec = _record(
          id: 'rec-lend-base',
          type: RecordType.lendOut,
          moneyMinor: 100000,
          catId: noRef,
          assetId: noRef,
          fromAssetId: 1,
          toAssetId: 3,
          recordTime: 1700000001000,
        );
        final baseCreditRec = _record(
          id: 'rec-credit-base',
          type: RecordType.expense,
          moneyMinor: 20000,
          assetId: 2,
          recordTime: 1700000002000,
        );

        final base = _seedTables(
          assets: <Map<String, Object?>>[
            _ordinaryAsset(
              id: 1,
              name: '现金',
              initMinor: 200000,
              balMinor: 100000,
              usedTimes: 1,
            ),
            creditAssetBase,
            debtAssetBase,
          ],
          records: <Map<String, Object?>>[baseLendRec, baseCreditRec],
        );

        // Local: spends 30.00 cash, spends 100.00 credit, collects 300.00 debt into cash,
        // AND creates a brand-new credit card (id=4) with -300.00 initial debt offset!
        final newCardLocal = <String, Object?>{
          ...creditAssetBase,
          'id': 4,
          'name': '新白金卡',
          'init_money_minor': '8000000',
          'balance_minor': '-35000', // -300.00 initial offset + -50.00 bill
        };
        final local = _seedTables(
          assets: <Map<String, Object?>>[
            _ordinaryAsset(
              id: 1,
              name: '现金（随身）', // renames ordinary account!
              initMinor: 200000,
              balMinor: 127000, // 1000 - 30 + 300 = 1270.00
              usedTimes: 3,
              color: '#112233',
            ),
            <String, Object?>{
              ...creditAssetBase,
              'balance_minor': '-30000',
              'used_times': 2,
            },
            <String, Object?>{...debtAssetBase, 'balance_minor': '70000'},
            newCardLocal,
          ],
          records: <Map<String, Object?>>[
            baseLendRec,
            baseCreditRec,
            _record(id: 'rec-local-cash', moneyMinor: 3000, assetId: 1),
            _record(id: 'rec-local-cc', moneyMinor: 10000, assetId: 2),
            _record(
              id: 'rec-local-collect',
              type: RecordType.collect,
              moneyMinor: 30000,
              catId: noRef,
              assetId: noRef,
              fromAssetId: 3,
              toAssetId: 1,
              recordTime: 1700000010000,
            ),
            _record(id: 'rec-local-newcc', moneyMinor: 5000, assetId: 4),
          ],
        );

        // Remote: spends 50.00 cash, spends 150.00 credit, collects remaining 700.00 debt!
        final remote = _seedTables(
          assets: <Map<String, Object?>>[
            _ordinaryAsset(
              id: 1,
              name: '现金',
              initMinor: 200000,
              balMinor: 165000, // 1000 - 50 + 700 = 1650.00
              usedTimes: 3,
            ),
            <String, Object?>{
              ...creditAssetBase,
              'balance_minor': '-35000',
              'used_times': 2,
            },
            <String, Object?>{...debtAssetBase, 'balance_minor': '30000'},
          ],
          records: <Map<String, Object?>>[
            baseLendRec,
            baseCreditRec,
            _record(id: 'rec-remote-cash', moneyMinor: 5000, assetId: 1),
            _record(id: 'rec-remote-cc', moneyMinor: 15000, assetId: 2),
            _record(
              id: 'rec-remote-collect',
              type: RecordType.collect,
              moneyMinor: 70000,
              catId: noRef,
              assetId: noRef,
              fromAssetId: 3,
              toAssetId: 1,
              recordTime: 1700000020000,
            ),
          ],
        );

        final diff = buildBaseLocalDiffRepresentation(
          baseTables: base,
          localTables: local,
        );
        final res = tryThreeWayMergeSyncSnapshots(
          baseLocalDiff: diff,
          localTables: local,
          remoteTables: remote,
          nowMs: 1700000099000,
        );
        expect(res.merged, isTrue, reason: res.abortReason);

        final mergedAssets = {
          for (final a in res.mergedTables!['asset']!) a['id'] as int: a,
        };
        // Cash: 1000 - 30 - 50 + 300 + 700 = 1920.00 (192000 minor), name & color kept!
        expect(mergedAssets[1]!['name'], '现金（随身）');
        expect(mergedAssets[1]!['color'], '#112233');
        expect(mergedAssets[1]!['balance_minor'], 192000);
        expect(mergedAssets[1]!['used_times'], 5);

        // Credit card (ADR-012): -200 - 100 - 150 = -450.00 (-45000 minor), limit untouched!
        expect(mergedAssets[2]!['balance_minor'], -45000);
        expect(
          decodeMinorJson(mergedAssets[2]!['init_money_minor'], field: 'limit'),
          BigInt.from(5000000),
        );

        // New credit card (id=4): preserves -300.00 initial offset -> -350.00 (-35000)!
        expect(mergedAssets[4]!['balance_minor'], -35000);

        // Debt (id=3): 1000 - 300 - 700 = 0 -> auto-settled (`status == settled`)!
        expect(mergedAssets[3]!['balance_minor'], 0);
        expect(mergedAssets[3]!['status'], AssetStatus.settled);
      },
    );

    test(
      'aborts on concurrent RecordType.balanceAdjust (type=4) on same account, but allows isolated balanceAdjust on untouched account',
      () {
        final base = _seedTables(
          assets: <Map<String, Object?>>[
            _ordinaryAsset(
              id: 1,
              name: '账户A',
              initMinor: 10000,
              balMinor: 10000,
            ),
            _ordinaryAsset(
              id: 2,
              name: '账户B',
              initMinor: 20000,
              balMinor: 20000,
            ),
          ],
        );

        // Conflict case: Local posts balanceAdjust +50 on Account 1, Remote spends -30 on Account 1.
        final localConflict = _seedTables(
          assets: <Map<String, Object?>>[
            _ordinaryAsset(
              id: 1,
              name: '账户A',
              initMinor: 10000,
              balMinor: 15000,
            ),
            _ordinaryAsset(
              id: 2,
              name: '账户B',
              initMinor: 20000,
              balMinor: 20000,
            ),
          ],
          records: <Map<String, Object?>>[
            _record(
              id: 'adj-1',
              type: RecordType.balanceAdjust,
              subType: RecordDirection.income,
              moneyMinor: 5000,
              catId: noRef,
              assetId: 1,
            ),
          ],
        );
        final remoteConflict = _seedTables(
          assets: <Map<String, Object?>>[
            _ordinaryAsset(
              id: 1,
              name: '账户A',
              initMinor: 10000,
              balMinor: 7000,
            ),
            _ordinaryAsset(
              id: 2,
              name: '账户B',
              initMinor: 20000,
              balMinor: 20000,
            ),
          ],
          records: <Map<String, Object?>>[
            _record(id: 'exp-1', moneyMinor: 3000, assetId: 1),
          ],
        );

        final conflictRes = tryThreeWayMergeSyncSnapshots(
          baseLocalDiff: buildBaseLocalDiffRepresentation(
            baseTables: base,
            localTables: localConflict,
          ),
          localTables: localConflict,
          remoteTables: remoteConflict,
          nowMs: 1700000050000,
        );
        expect(conflictRes.merged, isFalse);

        // Safe case: Local posts balanceAdjust on Account 2 while Remote spends on Account 1.
        final localIsolated = _seedTables(
          assets: <Map<String, Object?>>[
            _ordinaryAsset(
              id: 1,
              name: '账户A',
              initMinor: 10000,
              balMinor: 10000,
            ),
            _ordinaryAsset(
              id: 2,
              name: '账户B',
              initMinor: 20000,
              balMinor: 25000,
            ),
          ],
          records: <Map<String, Object?>>[
            _record(
              id: 'adj-2',
              type: RecordType.balanceAdjust,
              subType: RecordDirection.income,
              moneyMinor: 5000,
              catId: noRef,
              assetId: 2,
            ),
          ],
        );
        final okRes = tryThreeWayMergeSyncSnapshots(
          baseLocalDiff: buildBaseLocalDiffRepresentation(
            baseTables: base,
            localTables: localIsolated,
          ),
          localTables: localIsolated,
          remoteTables: remoteConflict,
          nowMs: 1700000050000,
        );
        expect(okRes.merged, isTrue, reason: okRes.abortReason);
      },
    );

    test(
      'deduplicates periodic natural-day catch-up bundles (primary + fee child + tag_record) and detects auto-derived-only diff',
      () {
        final periodDef = <String, Object?>{
          'id': 10,
          'record_type': RecordType.transfer,
          'money_minor': '10000',
          'fee_minor': '200',
          'remark': '房租自动转账',
          'cat_id': noRef,
          'asset_id': 1,
          'asset_id2': 2,
          'book_id': 1,
          'images': null,
          'state': 0,
          'time': null,
          'exclude_budget': false,
          'exclude_ex_in': false,
          'period_type': 2,
          'period_type_date': '1',
          'period_start_date': 1700000000000,
          'period_end_date': -1,
          'frequency': 1,
          'last_add_date': -1,
          'period_add_times': 0,
          'create_time': 1000,
          'tags': '["t1"]',
          'exi': null,
        };
        final tagRow = <String, Object?>{
          'tag_id': 't1',
          'name': '固定支出',
          'sort': 1,
          'hidden': false,
          'parent_tag_id': null,
          'parent': 0,
          'color': null,
          'extra_info': null,
        };
        final base = _seedTables(
          assets: <Map<String, Object?>>[
            _ordinaryAsset(
              id: 1,
              name: '卡A',
              initMinor: 50000,
              balMinor: 50000,
            ),
            _ordinaryAsset(id: 2, name: '卡B', initMinor: 0, balMinor: 0),
          ],
          tags: <Map<String, Object?>>[tagRow],
          recordPeriods: <Map<String, Object?>>[periodDef],
        );

        final dayMs = DateTime(2026, 8, 1, 9, 0).millisecondsSinceEpoch;
        final local = _seedTables(
          assets: <Map<String, Object?>>[
            _ordinaryAsset(
              id: 1,
              name: '卡A',
              initMinor: 50000,
              balMinor: 39800,
            ),
            _ordinaryAsset(id: 2, name: '卡B', initMinor: 0, balMinor: 10000),
          ],
          tags: <Map<String, Object?>>[tagRow],
          recordPeriods: <Map<String, Object?>>[
            <String, Object?>{
              ...periodDef,
              'last_add_date': dayMs,
              'period_add_times': 1,
            },
          ],
          records: <Map<String, Object?>>[
            _record(
              id: 'local-per-main',
              type: RecordType.transfer,
              moneyMinor: 10000,
              catId: noRef,
              assetId: noRef,
              fromAssetId: 1,
              toAssetId: 2,
              periodId: 10,
              recordTime: dayMs,
            ),
            _record(
              id: 'local-per-fee',
              type: RecordType.fee,
              subType: RecordDirection.expense,
              moneyMinor: 200,
              catId: noRef,
              assetId: 1,
              recordTime: dayMs,
              relInfo:
                  (RecordRelations()
                        ..transferFee = const TransferFeeLink(
                          feeFromTarget: false,
                          parentId: 'local-per-main',
                        ))
                      .encode(),
            ),
          ],
          tagRecords: <Map<String, Object?>>[
            <String, Object?>{'tag_id': 't1', 'record_id': 'local-per-main'},
          ],
        );

        final remote = _seedTables(
          assets: <Map<String, Object?>>[
            _ordinaryAsset(
              id: 1,
              name: '卡A',
              initMinor: 50000,
              balMinor: 39800,
            ),
            _ordinaryAsset(id: 2, name: '卡B', initMinor: 0, balMinor: 10000),
          ],
          tags: <Map<String, Object?>>[tagRow],
          recordPeriods: <Map<String, Object?>>[
            <String, Object?>{
              ...periodDef,
              'last_add_date': dayMs + 60000,
              'period_add_times': 1,
            },
          ],
          records: <Map<String, Object?>>[
            _record(
              id: 'remote-per-main',
              type: RecordType.transfer,
              moneyMinor: 10000,
              catId: noRef,
              assetId: noRef,
              fromAssetId: 1,
              toAssetId: 2,
              periodId: 10,
              recordTime: dayMs + 60000,
            ),
            _record(
              id: 'remote-per-fee',
              type: RecordType.fee,
              subType: RecordDirection.expense,
              moneyMinor: 200,
              catId: noRef,
              assetId: 1,
              recordTime: dayMs + 60000,
              relInfo:
                  (RecordRelations()
                        ..transferFee = const TransferFeeLink(
                          feeFromTarget: false,
                          parentId: 'remote-per-main',
                        ))
                      .encode(),
            ),
          ],
          tagRecords: <Map<String, Object?>>[
            <String, Object?>{'tag_id': 't1', 'record_id': 'remote-per-main'},
          ],
        );

        final diff = buildBaseLocalDiffRepresentation(
          baseTables: base,
          localTables: local,
        );
        expect(
          isLocalDiffAutoDerivedOnly(baseLocalDiff: diff, localTables: local),
          isTrue,
        );

        final res = tryThreeWayMergeSyncSnapshots(
          baseLocalDiff: diff,
          localTables: local,
          remoteTables: remote,
          nowMs: dayMs + 120000,
        );
        expect(res.merged, isTrue, reason: res.abortReason);
        expect(res.mergedTables!['record'], hasLength(2));
        expect(res.mergedTables!['tag_record'], hasLength(1));
        expect(
          res.mergedTables!['tag_record']!.single['record_id'],
          'remote-per-main',
        );
        expect(
          res.tableDeltas!['record']!.deletedKeys,
          containsAll(<String>['local-per-main', 'local-per-fee']),
        );
        final assets = {
          for (final a in res.mergedTables!['asset']!) a['id'] as int: a,
        };
        expect(assets[1]!['balance_minor'], 39800);
        expect(assets[2]!['balance_minor'], 10000);
      },
    );

    test(
      'deduplicates installment catch-up & rebuilds credit_info.inst[], while aborting on settleEarly vs normal period mismatch',
      () {
        final startMs = DateTime(2026, 6, 10).millisecondsSinceEpoch;
        final instBase = <String, Object?>{
          'id': 5,
          'name': '笔记本分期',
          'cat_id': 1,
          'principal_minor': '30000',
          'periods': 3,
          'charge_minor': '300',
          'charge_way': InstallmentChargeWay.perPeriod,
          'remainder_in': InstallmentRemainderIn.firstPeriod,
          'cal_way': InstallmentCalWay.halfUp2,
          'start_date': startMs,
          'asset_id': 2,
          'next_period': 1,
          'next_period_date': startMs,
          'credited': '[]',
          'book_id': 1,
          'exclude_budget': false,
          'exclude_ex_in': false,
          'create_date': startMs,
          'tags': null,
          'images': null,
          'exi':
              (InstallmentExtra()
                    ..principalCounted = true
                    ..interestCounted = false)
                  .encode(),
        };
        final ccBase = <String, Object?>{
          'id': 2,
          'name': '信用卡',
          'balance_minor': '0',
          'type': AssetType.credit,
          'sub_type': -1,
          'create_date': 1000,
          'sort': 2,
          'icon': 'card',
          'remark': null,
          'init_money_minor': '1000000',
          'is_default': false,
          'is_effective_asset': 1,
          'used_times': 0,
          'color': null,
          'status': AssetStatus.active,
          'extra_info': null,
          'loan_info': null,
          'credit_info':
              (CreditInfo()
                    ..billDay = 1
                    ..repaymentDay = 20)
                  .encode(),
          'fixed_deposit_info': null,
          'group_name': null,
          'currency': 'CNY',
        };
        final base = _seedTables(
          assets: <Map<String, Object?>>[ccBase],
          installments: <Map<String, Object?>>[instBase],
        );

        final localSamePeriod = _seedTables(
          assets: <Map<String, Object?>>[
            <String, Object?>{...ccBase, 'balance_minor': '-10100'},
          ],
          installments: <Map<String, Object?>>[
            <String, Object?>{...instBase, 'next_period': 2, 'credited': '[1]'},
          ],
          records: <Map<String, Object?>>[
            _record(
              id: 'inst-l-p1',
              moneyMinor: 10000,
              assetId: 2,
              installment: formatInstallmentRecordKey(5, 1),
            ),
            _record(
              id: 'inst-l-f1',
              type: RecordType.fee,
              subType: RecordDirection.expense,
              moneyMinor: 100,
              catId: noRef,
              assetId: 2,
              installment: formatInstallmentRecordKey(5, 1),
            ),
          ],
        );
        final remoteSamePeriod = _seedTables(
          assets: <Map<String, Object?>>[
            <String, Object?>{...ccBase, 'balance_minor': -10100},
          ],
          installments: <Map<String, Object?>>[
            <String, Object?>{...instBase, 'next_period': 2, 'credited': '[1]'},
          ],
          records: <Map<String, Object?>>[
            _record(
              id: 'inst-r-p1',
              moneyMinor: 10000,
              assetId: 2,
              installment: formatInstallmentRecordKey(5, 1),
            ),
            _record(
              id: 'inst-r-f1',
              type: RecordType.fee,
              subType: RecordDirection.expense,
              moneyMinor: 100,
              catId: noRef,
              assetId: 2,
              installment: formatInstallmentRecordKey(5, 1),
            ),
          ],
        );

        final ok = tryThreeWayMergeSyncSnapshots(
          baseLocalDiff: buildBaseLocalDiffRepresentation(
            baseTables: base,
            localTables: localSamePeriod,
          ),
          localTables: localSamePeriod,
          remoteTables: remoteSamePeriod,
          nowMs: startMs + 5000,
        );
        expect(ok.merged, isTrue, reason: ok.abortReason);
        expect(ok.mergedTables!['record'], hasLength(2));
        final mergedCc = ok.mergedTables!['asset']!.single;
        expect(mergedCc['balance_minor'], -10100);
        final parsedCi = CreditInfo.parse(mergedCc['credit_info'] as String?);
        expect(parsedCi.installments, isNotNull);
        expect(parsedCi.installments!.single.principal, BigInt.from(20000));

        // SettleEarly mismatch -> aborts!
        final localEarly = _seedTables(
          assets: <Map<String, Object?>>[
            <String, Object?>{...ccBase, 'balance_minor': -30000},
          ],
          installments: <Map<String, Object?>>[
            <String, Object?>{
              ...instBase,
              'exi':
                  (InstallmentExtra()
                        ..principalCounted = true
                        ..settledEarly = true)
                      .encode(),
            },
          ],
          records: <Map<String, Object?>>[
            _record(
              id: 'inst-l-se',
              moneyMinor: 30000,
              assetId: 2,
              installment: formatInstallmentRecordKey(5, 1),
            ),
          ],
        );
        final aborted = tryThreeWayMergeSyncSnapshots(
          baseLocalDiff: buildBaseLocalDiffRepresentation(
            baseTables: base,
            localTables: localEarly,
          ),
          localTables: localEarly,
          remoteTables: remoteSamePeriod,
          nowMs: startMs + 5000,
        );
        expect(aborted.merged, isFalse);
      },
    );

    test(
      'preserves both manual deposits on free savings plan while deduplicating scheduled auto-savings check-ins and fixed-deposit maturity',
      () {
        final fdItemBase = FixedDepositItem(
          moneyMinor: BigInt.from(100000),
          fromAssetId: 1,
          updateAssetBalance: true,
          annualRate: DecimalValue.parse('0.025'),
          periodUnit: DepositPeriodUnit.year,
          periodCount: 1,
          depositDate: DateTime(2025, 1, 1).millisecondsSinceEpoch,
          dueDate: DateTime(2026, 1, 1).millisecondsSinceEpoch,
          expectedIncomeMinor: BigInt.from(2500),
          currency: 'CNY',
          assetCurrency: 'CNY',
          assetMoneyMinor: BigInt.from(100000),
          baseCurrency: 'CNY',
          baseMoneyMinor: BigInt.from(100000),
          remark: '一年定存',
          status: FixedDepositStatus.running,
        );
        final freePlanBase = <String, Object?>{
          'id': 1,
          'name': '自由旅行金',
          'remark': '',
          'plan_type': SavingsPlanType.free,
          'cycle_type': SavingsCycleType.free,
          'start_date': 1700000000000,
          'end_date': -1,
          'plan_money_minor': '50000',
          'saved_money_minor': '0',
          'auto_plan': false,
          'from_asset_id': 1,
          'to_asset_id': 2,
          'book_id': 1,
          'start_money_minor': '0',
          'incremental_minor': '0',
          'status': SavingsPlanStatus.active,
          'create_date': 1000,
          'sort': 1,
          'next_save_date': -1,
          'bbz_daily_times': 0,
          'icon': null,
          'extra_info': null,
        };
        final base = _seedTables(
          assets: <Map<String, Object?>>[
            _ordinaryAsset(
              id: 1,
              name: '活期卡',
              initMinor: 100000,
              balMinor: 100000,
              fixedDepositInfo: encodeFixedDepositList(<FixedDepositItem>[
                fdItemBase,
              ]),
            ),
            _ordinaryAsset(id: 2, name: '心愿金', initMinor: 0, balMinor: 0),
          ],
          moneySavePlans: <Map<String, Object?>>[freePlanBase],
        );

        final dayMs = DateTime(2026, 2, 1, 10).millisecondsSinceEpoch;
        final local = _seedTables(
          assets: <Map<String, Object?>>[
            _ordinaryAsset(
              id: 1,
              name: '活期卡',
              initMinor: 100000,
              balMinor: 92500, // -10000 deposit + 2500 FD interest
              fixedDepositInfo: encodeFixedDepositList(<FixedDepositItem>[
                fdItemBase.copyWith(
                  status: FixedDepositStatus.settled,
                  incomeRecordId: 'fd-int-local',
                ),
              ]),
            ),
            _ordinaryAsset(id: 2, name: '心愿金', initMinor: 0, balMinor: 10000),
          ],
          moneySavePlans: <Map<String, Object?>>[
            <String, Object?>{...freePlanBase, 'saved_money_minor': '10000'},
          ],
          moneySavePlanRecords: <Map<String, Object?>>[
            <String, Object?>{
              'id': 1, // Same auto-increment id=1 on both devices!
              'plan_id': 1,
              'remark': '手机存入',
              'from_asset_id': 1,
              'to_asset_id': 2,
              'record_date': dayMs,
              'record_money_minor': '10000',
              'record_id': 'save-rec-local',
            },
          ],
          records: <Map<String, Object?>>[
            _record(
              id: 'save-rec-local',
              type: RecordType.transfer,
              moneyMinor: 10000,
              catId: noRef,
              assetId: noRef,
              fromAssetId: 1,
              toAssetId: 2,
              recordTime: dayMs,
            ),
            _record(
              id: 'fd-int-local',
              type: RecordType.depositInterest,
              subType: RecordDirection.income,
              moneyMinor: 2500,
              catId: noRef,
              assetId: 1,
              recordTime: dayMs,
            ),
          ],
        );

        final remote = _seedTables(
          assets: <Map<String, Object?>>[
            _ordinaryAsset(
              id: 1,
              name: '活期卡',
              initMinor: 100000,
              balMinor: 82500, // -20000 deposit + 2500 FD interest
              fixedDepositInfo: encodeFixedDepositList(<FixedDepositItem>[
                fdItemBase.copyWith(
                  status: FixedDepositStatus.settled,
                  incomeRecordId: 'fd-int-remote',
                ),
              ]),
            ),
            _ordinaryAsset(id: 2, name: '心愿金', initMinor: 0, balMinor: 20000),
          ],
          moneySavePlans: <Map<String, Object?>>[
            <String, Object?>{...freePlanBase, 'saved_money_minor': '20000'},
          ],
          moneySavePlanRecords: <Map<String, Object?>>[
            <String, Object?>{
              'id': 1, // Colliding id=1!
              'plan_id': 1,
              'remark': '电脑存入',
              'from_asset_id': 1,
              'to_asset_id': 2,
              'record_date': dayMs + 1000,
              'record_money_minor': '20000',
              'record_id': 'save-rec-remote',
            },
          ],
          records: <Map<String, Object?>>[
            _record(
              id: 'save-rec-remote',
              type: RecordType.transfer,
              moneyMinor: 20000,
              catId: noRef,
              assetId: noRef,
              fromAssetId: 1,
              toAssetId: 2,
              recordTime: dayMs + 1000,
            ),
            _record(
              id: 'fd-int-remote',
              type: RecordType.depositInterest,
              subType: RecordDirection.income,
              moneyMinor: 2500,
              catId: noRef,
              assetId: 1,
              recordTime: dayMs + 1000,
            ),
          ],
        );

        final res = tryThreeWayMergeSyncSnapshots(
          baseLocalDiff: buildBaseLocalDiffRepresentation(
            baseTables: base,
            localTables: local,
          ),
          localTables: local,
          remoteTables: remote,
          nowMs: dayMs + 5000,
        );
        expect(res.merged, isTrue, reason: res.abortReason);

        // Both manual free-plan deposits kept (id=1 and re-keyed id=2), total saved = 300.00!
        expect(res.mergedTables!['money_save_plan_record'], hasLength(2));
        expect(
          res.mergedTables!['money_save_plan']!.single['saved_money_minor'],
          30000,
        );
        // FD maturity interest deduplicated to 1 (`fd-int-remote`) -> total 3 records!
        expect(res.mergedTables!['record'], hasLength(3));
        final assets = {
          for (final a in res.mergedTables!['asset']!) a['id'] as int: a,
        };
        // 100000 - 10000 - 20000 + 2500 = 72500!
        expect(assets[1]!['balance_minor'], 72500);
        expect(assets[2]!['balance_minor'], 30000);
      },
    );

    test(
      'deduplicates day-1 auto-copied budgets, recomputes cross-month forward carryover, and enforces R7 total upscale',
      () {
        final prevBudget = <String, Object?>{
          'id': 1,
          'budget_type': BudgetTypeCode.expenseCategory,
          'record_cat_id': 1,
          'amount_minor': '50000',
          'book_id': 1,
          'section': '2026-07',
          'sort': 1,
          'create_date': 1000,
          'remark': null,
          'extra_info': BudgetExtra(
            autoCopy: true,
            forward: true,
            baseMinor: BigInt.from(50000),
          ).toJsonString(),
        };
        final prevTotal = <String, Object?>{
          'id': 2,
          'budget_type': BudgetTypeCode.total,
          'record_cat_id': noRef,
          'amount_minor': '50000',
          'book_id': 1,
          'section': '2026-07',
          'sort': 0,
          'create_date': 1000,
          'remark': null,
          'extra_info': BudgetExtra(
            autoCopy: true,
            forward: false,
            baseMinor: BigInt.from(50000),
          ).toJsonString(),
        };
        final base = _seedTables(
          budgets: <Map<String, Object?>>[prevBudget, prevTotal],
        );

        // Local added a 2026-07 expense of 120.00 AND auto-copied 2026-08 budgets;
        // Remote ALSO auto-copied 2026-08 budgets BEFORE seeing that 120.00 expense!
        final julyMs = DateTime(2026, 7, 28, 12).millisecondsSinceEpoch;
        final local = _seedTables(
          budgets: <Map<String, Object?>>[
            prevBudget,
            prevTotal,
            <String, Object?>{
              'id': 3,
              'budget_type': BudgetTypeCode.expenseCategory,
              'record_cat_id': 1,
              'amount_minor': '88000', // 500 + (500 - 120)
              'book_id': 1,
              'section': '2026-08',
              'sort': 1,
              'create_date': 2000,
              'remark': null,
              'extra_info': BudgetExtra(
                autoCopy: true,
                forward: true,
                baseMinor: BigInt.from(50000),
              ).toJsonString(),
            },
            <String, Object?>{
              'id': 4,
              'budget_type': BudgetTypeCode.total,
              'record_cat_id': noRef,
              'amount_minor': '88000',
              'book_id': 1,
              'section': '2026-08',
              'sort': 0,
              'create_date': 2000,
              'remark': null,
              'extra_info': BudgetExtra(
                autoCopy: true,
                forward: false,
                baseMinor: BigInt.from(50000),
              ).toJsonString(),
            },
          ],
          records: <Map<String, Object?>>[
            _record(
              id: 'july-exp-120',
              moneyMinor: 12000,
              catId: 1,
              recordTime: julyMs,
            ),
          ],
          assets: <Map<String, Object?>>[
            _ordinaryAsset(
              id: 1,
              name: '现金',
              initMinor: 100000,
              balMinor: 88000,
            ),
          ],
        );

        final remote = _seedTables(
          budgets: <Map<String, Object?>>[
            prevBudget,
            prevTotal,
            <String, Object?>{
              'id': 10,
              'budget_type': BudgetTypeCode.expenseCategory,
              'record_cat_id': 1,
              'amount_minor':
                  '100000', // 500 + 500 (did not have july-exp-120 yet!)
              'book_id': 1,
              'section': '2026-08',
              'sort': 1,
              'create_date': 2100,
              'remark': null,
              'extra_info': BudgetExtra(
                autoCopy: true,
                forward: true,
                baseMinor: BigInt.from(50000),
              ).toJsonString(),
            },
            <String, Object?>{
              'id': 11,
              'budget_type': BudgetTypeCode.total,
              'record_cat_id': noRef,
              'amount_minor': '50000',
              'book_id': 1,
              'section': '2026-08',
              'sort': 0,
              'create_date': 2100,
              'remark': null,
              'extra_info': BudgetExtra(
                autoCopy: true,
                forward: false,
                baseMinor: BigInt.from(50000),
              ).toJsonString(),
            },
          ],
        );

        final res = tryThreeWayMergeSyncSnapshots(
          baseLocalDiff: buildBaseLocalDiffRepresentation(
            baseTables: base,
            localTables: local,
          ),
          localTables: local,
          remoteTables: remote,
          nowMs: DateTime(2026, 8, 2).millisecondsSinceEpoch,
        );
        expect(res.merged, isTrue, reason: res.abortReason);

        final augBudgets = res.mergedTables!['budget']!
            .where((b) => b['section'] == '2026-08')
            .toList();
        expect(augBudgets, hasLength(2));
        final augCat = augBudgets.singleWhere((b) => b['record_cat_id'] == 1);
        final augTot = augBudgets.singleWhere(
          (b) => b['budget_type'] == BudgetTypeCode.total,
        );
        // Recomputed with july-exp-120: 500 + (500 - 120) = 880.00, AND R7 upscales total to 880.00!
        expect(augCat['amount_minor'], 88000);
        expect(augTot['amount_minor'], 88000);
        expect(
          BudgetExtra.fromJson(
            augTot['extra_info'] as String?,
            fallbackAmountMinor: BigInt.zero,
          ).baseMinor,
          BigInt.from(88000),
        );
      },
    );

    test(
      'handles wish/stat_story UUID PKs, protects live referenced attachments, and aborts via evaluateDataHealth when peer references deleted category',
      () {
        final shaPic = 'a' * 64;
        final base = _seedTables(
          wishes: <Map<String, Object?>>[
            <String, Object?>{
              'id': 'wish-uuid-1',
              'content': '降噪耳机',
              'value_minor': '199900',
              'create_date': 1000,
              'is_realized': false,
              'realized_date': 0,
              'sort': 1,
              'icon': null,
              'target_date': 0,
            },
          ],
          statStories: <Map<String, Object?>>[
            <String, Object?>{
              'id': 'story-uuid-1',
              'story': '七月总结',
              'book_id': 1,
              'sdate': 1000,
              'edate': 2000,
              'dsection': '2026-07',
            },
          ],
        );

        // Local deletes `attachments/receipt.jpg` (had no local reference), adds wish-uuid-2;
        // Remote adds a bill referencing `receipt.jpg` -> merged attachments MUST retain `receipt.jpg`!
        final local = _seedTables(
          wishes: <Map<String, Object?>>[
            ...base['wish']!,
            <String, Object?>{
              'id': 'wish-uuid-2',
              'content': '显示器',
              'value_minor': '299900',
              'create_date': 2000,
              'is_realized': false,
              'realized_date': 0,
              'sort': 2,
              'icon': null,
              'target_date': 0,
            },
          ],
          statStories: base['stat_story'],
        );
        final remote = _seedTables(
          wishes: base['wish'],
          statStories: <Map<String, Object?>>[
            ...base['stat_story']!,
            <String, Object?>{
              'id': 'story-uuid-2',
              'story': '八月总结',
              'book_id': 1,
              'sdate': 3000,
              'edate': 4000,
              'dsection': '2026-08',
            },
          ],
          assets: <Map<String, Object?>>[
            _ordinaryAsset(
              id: 1,
              name: '现金',
              initMinor: 100000,
              balMinor: 99000,
            ),
          ],
          records: <Map<String, Object?>>[
            _record(
              id: 'rec-with-img',
              moneyMinor: 1000,
              images: jsonEncode(<String>['receipt.jpg']),
            ),
          ],
        );

        final res = tryThreeWayMergeSyncSnapshots(
          baseLocalDiff: buildBaseLocalDiffRepresentation(
            baseTables: base,
            localTables: local,
            baseAttachmentChecksums: <String, String>{
              'attachments/receipt.jpg': shaPic,
            },
            localAttachmentChecksums: const <String, String>{},
          ),
          localTables: local,
          remoteTables: remote,
          remoteAttachmentChecksums: <String, String>{
            'attachments/receipt.jpg': shaPic,
          },
          nowMs: 5000,
        );
        expect(res.merged, isTrue, reason: res.abortReason);
        expect(res.mergedTables!['wish'], hasLength(2));
        expect(res.mergedTables!['stat_story'], hasLength(2));
        expect(
          res.mergedAttachments!.containsKey('attachments/receipt.jpg'),
          isTrue,
        );

        // Now Local deletes category id=1 while Remote adds a bill referencing catId=1 -> health gate aborts!
        final localDeletedCat = _seedTables(
          categories: <Map<String, Object?>>[base['record_category']![1]],
        );
        final healthAbort = tryThreeWayMergeSyncSnapshots(
          baseLocalDiff: buildBaseLocalDiffRepresentation(
            baseTables: base,
            localTables: localDeletedCat,
          ),
          localTables: localDeletedCat,
          remoteTables: remote,
          nowMs: 5000,
        );
        expect(healthAbort.merged, isFalse);
      },
    );

    test(
      'Extreme Scale (100,000 bills): BaseLocalDiffRepresentation deduplicates 100k unchanged rows and produces minimal 5-row SyncTableDelta',
      () {
        const count = 100000;
        final baseRecords = List<Map<String, Object?>>.generate(
          count,
          (i) => _record(
            id: 'r-${i.toString().padLeft(6, '0')}',
            moneyMinor: 100, // 1.00 each -> -100,000.00 total
            recordTime: 1700000000000 + i,
          ),
        );
        const initMinor = 20000000; // 200,000.00
        const baseBal = initMinor - (count * 100); // 100,000.00

        final base = _seedTables(
          assets: <Map<String, Object?>>[
            _ordinaryAsset(
              id: 1,
              name: '主卡',
              initMinor: initMinor,
              balMinor: baseBal,
            ),
          ],
          records: baseRecords,
        );

        final localNew = List<Map<String, Object?>>.generate(
          5,
          (i) => _record(
            id: 'local-new-$i',
            moneyMinor: 200,
            recordTime: 1700900000000 + i,
          ),
        );
        final remoteNew = List<Map<String, Object?>>.generate(
          5,
          (i) => _record(
            id: 'remote-new-$i',
            moneyMinor: 300,
            recordTime: 1700950000000 + i,
          ),
        );

        final local = _seedTables(
          assets: <Map<String, Object?>>[
            _ordinaryAsset(
              id: 1,
              name: '主卡',
              initMinor: initMinor,
              balMinor: baseBal - 1000,
            ),
          ],
          records: <Map<String, Object?>>[...baseRecords, ...localNew],
        );
        final remote = _seedTables(
          assets: <Map<String, Object?>>[
            _ordinaryAsset(
              id: 1,
              name: '主卡',
              initMinor: initMinor,
              balMinor: baseBal - 1500,
            ),
          ],
          records: <Map<String, Object?>>[...baseRecords, ...remoteNew],
        );

        final sw = Stopwatch()..start();
        final diff = buildBaseLocalDiffRepresentation(
          baseTables: base,
          localTables: local,
        );
        expect(diff.tables['record']!.unchangedBaseKeys, hasLength(count));
        expect(diff.tables['record']!.modifiedBaseRows, isEmpty);
        expect(diff.tables['record']!.deletedBaseRows, isEmpty);

        final res = tryThreeWayMergeSyncSnapshots(
          baseLocalDiff: diff,
          localTables: local,
          remoteTables: remote,
          nowMs: 1701000000000,
        );
        sw.stop();

        expect(res.merged, isTrue, reason: res.abortReason);
        expect(res.mergedTables!['record'], hasLength(count + 10));
        expect(
          res.mergedTables!['asset']!.single['balance_minor'],
          baseBal - 2500,
        );
        // Delta upserts ONLY the 5 remote records (not 100,010 rows)!
        expect(res.tableDeltas!['record']!.upserts, hasLength(5));
        expect(res.tableDeltas!['record']!.deletedKeys, isEmpty);
        expect(sw.elapsedMilliseconds, lessThan(15000));
      },
    );

    test(
      'preserves exact decimal String encoding for int64 minor magnitudes exceeding 2^53 - 1',
      () {
        final hugeInit = BigInt.parse('9007199254741500'); // > 2^53 - 1
        final hugeAsset = <String, Object?>{
          ..._ordinaryAsset(id: 1, name: '巨额资产', initMinor: 0, balMinor: 0),
          'init_money_minor': encodeMinorJson(hugeInit),
          'balance_minor': encodeMinorJson(hugeInit),
        };
        final base = _seedTables(assets: <Map<String, Object?>>[hugeAsset]);
        final local = _seedTables(
          assets: <Map<String, Object?>>[
            <String, Object?>{
              ...hugeAsset,
              'balance_minor': encodeMinorJson(hugeInit - BigInt.from(200)),
            },
          ],
          records: <Map<String, Object?>>[
            _record(id: 'l-1', moneyMinor: 200, assetId: 1),
          ],
        );
        final remote = _seedTables(
          assets: <Map<String, Object?>>[
            <String, Object?>{
              ...hugeAsset,
              'balance_minor': encodeMinorJson(hugeInit - BigInt.from(300)),
            },
          ],
          records: <Map<String, Object?>>[
            _record(id: 'r-1', moneyMinor: 300, assetId: 1),
          ],
        );
        final res = tryThreeWayMergeSyncSnapshots(
          baseLocalDiff: buildBaseLocalDiffRepresentation(
            baseTables: base,
            localTables: local,
          ),
          localTables: local,
          remoteTables: remote,
          nowMs: 1700000100000,
        );
        expect(res.merged, isTrue, reason: res.abortReason);
        expect(
          res.mergedTables!['asset']!.single['balance_minor'],
          (hugeInit - BigInt.from(500)).toString(),
        );
      },
    );

    test(
      'preserves manual debt settlement & loan dates (3a) and aborts on concurrent manual settle vs principal repayment',
      () {
        final baseLoan = LoanInfo(
          schemaVersion: 2,
          startDate: 1700000000000,
          endDate: -1,
          totalDebtMoneyMinor: BigInt.from(50000),
          manualSettled: false,
          currencyPositions: <LoanCurrencyPosition>[
            LoanCurrencyPosition(
              currencyCode: 'CNY',
              principalBalanceMinor: BigInt.from(50000),
              totalPrincipalMinor: BigInt.from(50000),
            ),
          ],
        );
        final debtBase = <String, Object?>{
          'id': 9,
          'name': '朋友借款',
          'balance_minor': '50000',
          'type': AssetType.debt,
          'sub_type': AssetType.debtLend,
          'create_date': 1000,
          'sort': 9,
          'icon': 'debt',
          'remark': '',
          'init_money_minor': '0',
          'is_default': false,
          'is_effective_asset': 0,
          'used_times': 1,
          'color': null,
          'status': AssetStatus.active,
          'extra_info': null,
          'loan_info': baseLoan.encode(),
          'credit_info': null,
          'fixed_deposit_info': null,
          'group_name': null,
          'currency': 'CNY',
        };
        final lendRec = _record(
          id: 'lend-base-1',
          type: RecordType.lendOut,
          moneyMinor: 50000,
          catId: noRef,
          assetId: noRef,
          fromAssetId: 1,
          toAssetId: 9,
          recordTime: 1700000000001,
        );
        final base = _seedTables(
          assets: <Map<String, Object?>>[
            _ordinaryAsset(
              id: 1,
              name: '现金',
              initMinor: 100000,
              balMinor: 50000,
            ),
            debtBase,
          ],
          records: <Map<String, Object?>>[lendRec],
        );

        // Local manually settles (forgives) the 500.00 debt & sets endDate.
        final settledLoan = baseLoan.copyWith(
          endDate: 1700500000000,
          manualSettled: true,
          settledSnapshotMinor: BigInt.from(50000),
          settledCurrencyCode: 'CNY',
          settledAtMs: 1700100000000,
        );
        final localSettled = _seedTables(
          assets: <Map<String, Object?>>[
            _ordinaryAsset(
              id: 1,
              name: '现金',
              initMinor: 100000,
              balMinor: 50000,
            ),
            <String, Object?>{
              ...debtBase,
              'balance_minor': '0',
              'status': AssetStatus.settled,
              'loan_info': settledLoan.encode(),
            },
          ],
          records: <Map<String, Object?>>[lendRec],
        );
        final diffSettled = buildBaseLocalDiffRepresentation(
          baseTables: base,
          localTables: localSettled,
        );
        expect(
          isLocalDiffAutoDerivedOnly(
            baseLocalDiff: diffSettled,
            localTables: localSettled,
          ),
          isFalse,
        );

        // Remote adds an unrelated cash expense (-20.00).
        final remoteUnrelated = _seedTables(
          assets: <Map<String, Object?>>[
            _ordinaryAsset(
              id: 1,
              name: '现金',
              initMinor: 100000,
              balMinor: 48000,
            ),
            debtBase,
          ],
          records: <Map<String, Object?>>[
            lendRec,
            _record(id: 'r-cash', moneyMinor: 2000, assetId: 1),
          ],
        );
        final ok = tryThreeWayMergeSyncSnapshots(
          baseLocalDiff: diffSettled,
          localTables: localSettled,
          remoteTables: remoteUnrelated,
          nowMs: 1700200000000,
        );
        expect(ok.merged, isTrue, reason: ok.abortReason);
        final mergedDebt = ok.mergedTables!['asset']!.singleWhere(
          (a) => a['id'] == 9,
        );
        expect(mergedDebt['status'], AssetStatus.settled);
        expect(mergedDebt['balance_minor'], 0);
        final mergedLoan = LoanInfo.parse(mergedDebt['loan_info'] as String?);
        expect(mergedLoan.manualSettled, isTrue);
        expect(mergedLoan.endDate, 1700500000000);

        // Remote adds a collect repayment (+100.00) on the SAME debt -> must abort!
        final remoteCollect = _seedTables(
          assets: <Map<String, Object?>>[
            _ordinaryAsset(
              id: 1,
              name: '现金',
              initMinor: 100000,
              balMinor: 60000,
            ),
            <String, Object?>{...debtBase, 'balance_minor': '40000'},
          ],
          records: <Map<String, Object?>>[
            lendRec,
            _record(
              id: 'r-collect',
              type: RecordType.collect,
              moneyMinor: 10000,
              catId: noRef,
              assetId: noRef,
              fromAssetId: 9,
              toAssetId: 1,
              recordTime: 1700150000001,
            ),
          ],
        );
        final conflict = tryThreeWayMergeSyncSnapshots(
          baseLocalDiff: diffSettled,
          localTables: localSettled,
          remoteTables: remoteCollect,
          nowMs: 1700200000000,
        );
        expect(conflict.merged, isFalse);
      },
    );

    test(
      'preserves one-sided asset.is_default switch (3b), savings auto_plan/unarchive toggles (3c), periodic resume/extension (3d), and cross-length FD maturity (3e)',
      () {
        final fd1Running = FixedDepositItem(
          moneyMinor: BigInt.from(100000),
          fromAssetId: 1,
          updateAssetBalance: true,
          annualRate: DecimalValue.parse('0.025'),
          periodUnit: DepositPeriodUnit.year,
          periodCount: 1,
          depositDate: DateTime(2025, 1, 1).millisecondsSinceEpoch,
          dueDate: DateTime(2026, 1, 1).millisecondsSinceEpoch,
          expectedIncomeMinor: BigInt.from(2500),
          currency: 'CNY',
          assetCurrency: 'CNY',
          assetMoneyMinor: BigInt.from(100000),
          baseCurrency: 'CNY',
          baseMoneyMinor: BigInt.from(100000),
          remark: '首笔定存',
          status: FixedDepositStatus.running,
        );
        final fd2Running = FixedDepositItem(
          moneyMinor: BigInt.from(200000),
          fromAssetId: 1,
          updateAssetBalance: true,
          annualRate: DecimalValue.parse('0.028'),
          periodUnit: DepositPeriodUnit.year,
          periodCount: 1,
          depositDate: DateTime(2026, 1, 2).millisecondsSinceEpoch,
          dueDate: DateTime(2027, 1, 2).millisecondsSinceEpoch,
          expectedIncomeMinor: BigInt.from(5600),
          currency: 'CNY',
          assetCurrency: 'CNY',
          assetMoneyMinor: BigInt.from(200000),
          baseCurrency: 'CNY',
          baseMoneyMinor: BigInt.from(200000),
          remark: '新增二号定存',
          status: FixedDepositStatus.running,
        );
        final startDayMs = DateTime(2026, 1, 1).millisecondsSinceEpoch;
        final endDayMs = DateTime(2026, 12, 31).millisecondsSinceEpoch;

        final pausedPeriod = <String, Object?>{
          'id': 1,
          'record_type': RecordType.expense,
          'money_minor': '3000',
          'fee_minor': '0',
          'remark': '月卡会员',
          'cat_id': 1,
          'asset_id': 1,
          'asset_id2': noRef,
          'book_id': 1,
          'images': null,
          'state': PeriodState.paused,
          'time': null,
          'exclude_budget': false,
          'exclude_ex_in': false,
          'period_type': PeriodType.daily,
          'period_type_date': '[]',
          'period_start_date': startDayMs,
          'period_end_date': periodEndNever,
          'frequency': 1,
          'last_add_date': startDayMs,
          'period_add_times': 1,
          'create_time': 1000,
          'tags': null,
          'exi': null,
        };
        final endedCountPeriod = <String, Object?>{
          ...pausedPeriod,
          'id': 2,
          'remark': '五次定投',
          'state': PeriodState.ended,
          'period_end_date': 5,
          'period_add_times': 5,
        };
        final schedPlanBase = <String, Object?>{
          'id': 10,
          'name': '定额存钱',
          'remark': '',
          'plan_type': SavingsPlanType.fixed,
          'cycle_type': SavingsCycleType.monthly,
          'start_date': startDayMs,
          'end_date': endDayMs,
          'plan_money_minor': '120000',
          'saved_money_minor': '0',
          'auto_plan': false,
          'from_asset_id': 1,
          'to_asset_id': 2,
          'book_id': 1,
          'start_money_minor': '10000',
          'incremental_minor': '0',
          'status': SavingsPlanStatus.active,
          'create_date': 1000,
          'sort': 1,
          'next_save_date': startDayMs,
          'bbz_daily_times': 0,
          'icon': null,
          'extra_info': null,
        };
        final archivedPlanBase = <String, Object?>{
          ...schedPlanBase,
          'id': 11,
          'name': '已归档计划',
          'saved_money_minor': '120000',
          'status': SavingsPlanStatus.archived,
          'next_save_date': -1,
        };

        final base = _seedTables(
          assets: <Map<String, Object?>>[
            _ordinaryAsset(
              id: 1,
              name: '招行一卡通',
              initMinor: 500000,
              balMinor: 500000,
              isDefault: true,
              fixedDepositInfo: encodeFixedDepositList(<FixedDepositItem>[
                fd1Running,
              ]),
            ),
            _ordinaryAsset(
              id: 2,
              name: '零钱通',
              initMinor: 10000,
              balMinor: 10000,
              isDefault: false,
            ),
          ],
          recordPeriods: <Map<String, Object?>>[pausedPeriod, endedCountPeriod],
          moneySavePlans: <Map<String, Object?>>[
            schedPlanBase,
            archivedPlanBase,
          ],
        );

        // Local:
        // - Switches default account from 1 -> 2, and adds FD2 on Asset 1
        // - Enables `auto_plan = true` on plan 10, and manually unarchives plan 11
        // - Resumes period 1 (`paused -> active`) & extends period 2 (`5 -> 10`, `ended -> active`)
        final local = _seedTables(
          assets: <Map<String, Object?>>[
            _ordinaryAsset(
              id: 1,
              name: '招行一卡通',
              initMinor: 500000,
              balMinor: 500000,
              isDefault: false,
              fixedDepositInfo: encodeFixedDepositList(<FixedDepositItem>[
                fd1Running,
                fd2Running,
              ]),
            ),
            _ordinaryAsset(
              id: 2,
              name: '零钱通',
              initMinor: 10000,
              balMinor: 10000,
              isDefault: true,
            ),
          ],
          recordPeriods: <Map<String, Object?>>[
            <String, Object?>{...pausedPeriod, 'state': PeriodState.active},
            <String, Object?>{
              ...endedCountPeriod,
              'period_end_date': 10,
              'state': PeriodState.active,
            },
          ],
          moneySavePlans: <Map<String, Object?>>[
            <String, Object?>{...schedPlanBase, 'auto_plan': true},
            <String, Object?>{
              ...archivedPlanBase,
              'status': SavingsPlanStatus.active,
            },
          ],
        );

        final localOnlyDefaultDiff = buildBaseLocalDiffRepresentation(
          baseTables: base,
          localTables: _seedTables(
            assets: <Map<String, Object?>>[
              _ordinaryAsset(
                id: 1,
                name: '招行一卡通',
                initMinor: 500000,
                balMinor: 500000,
                isDefault: false,
                fixedDepositInfo: encodeFixedDepositList(<FixedDepositItem>[
                  fd1Running,
                ]),
              ),
              _ordinaryAsset(
                id: 2,
                name: '零钱通',
                initMinor: 10000,
                balMinor: 10000,
                isDefault: true,
              ),
            ],
            recordPeriods: <Map<String, Object?>>[
              pausedPeriod,
              endedCountPeriod,
            ],
            moneySavePlans: <Map<String, Object?>>[
              schedPlanBase,
              archivedPlanBase,
            ],
          ),
        );
        expect(
          isLocalDiffAutoDerivedOnly(
            baseLocalDiff: localOnlyDefaultDiff,
            localTables: _seedTables(
              assets: <Map<String, Object?>>[
                _ordinaryAsset(
                  id: 1,
                  name: '招行一卡通',
                  initMinor: 500000,
                  balMinor: 500000,
                  isDefault: false,
                  fixedDepositInfo: encodeFixedDepositList(<FixedDepositItem>[
                    fd1Running,
                  ]),
                ),
                _ordinaryAsset(
                  id: 2,
                  name: '零钱通',
                  initMinor: 10000,
                  balMinor: 10000,
                  isDefault: true,
                ),
              ],
              recordPeriods: <Map<String, Object?>>[
                pausedPeriod,
                endedCountPeriod,
              ],
              moneySavePlans: <Map<String, Object?>>[
                schedPlanBase,
                archivedPlanBase,
              ],
            ),
          ),
          isFalse,
        );

        // Remote auto-settles FD1 (+25.00 interest) while leaving Asset 1 `isDefault: true` from Base!
        final remote = _seedTables(
          assets: <Map<String, Object?>>[
            _ordinaryAsset(
              id: 1,
              name: '招行一卡通',
              initMinor: 500000,
              balMinor: 502500,
              isDefault: true,
              fixedDepositInfo: encodeFixedDepositList(<FixedDepositItem>[
                fd1Running.copyWith(
                  status: FixedDepositStatus.settled,
                  incomeRecordId: 'fd1-int-remote',
                ),
              ]),
            ),
            _ordinaryAsset(
              id: 2,
              name: '零钱通',
              initMinor: 10000,
              balMinor: 10000,
              isDefault: false,
            ),
          ],
          records: <Map<String, Object?>>[
            _record(
              id: 'fd1-int-remote',
              type: RecordType.depositInterest,
              subType: RecordDirection.income,
              moneyMinor: 2500,
              catId: noRef,
              assetId: 1,
            ),
          ],
          recordPeriods: <Map<String, Object?>>[pausedPeriod, endedCountPeriod],
          moneySavePlans: <Map<String, Object?>>[
            schedPlanBase,
            archivedPlanBase,
          ],
        );

        final merged = tryThreeWayMergeSyncSnapshots(
          baseLocalDiff: buildBaseLocalDiffRepresentation(
            baseTables: base,
            localTables: local,
          ),
          localTables: local,
          remoteTables: remote,
          nowMs: startDayMs + 86400000,
        );
        expect(merged.merged, isTrue, reason: merged.abortReason);

        final mergedAssets = merged.mergedTables!['asset']!;
        final mA1 = mergedAssets.singleWhere((a) => a['id'] == 1);
        final mA2 = mergedAssets.singleWhere((a) => a['id'] == 2);
        expect(mA1['is_default'], isFalse);
        expect(mA2['is_default'], isTrue); // 3b preserved!
        expect(mA1['balance_minor'], 502500);

        final mFds = decodeFixedDepositList(
          mA1['fixed_deposit_info'] as String,
        );
        expect(mFds, hasLength(2));
        expect(mFds[0].status, FixedDepositStatus.settled); // 3e preserved!
        expect(mFds[0].incomeRecordId, 'fd1-int-remote');
        expect(mFds[1].status, FixedDepositStatus.running);
        expect(mFds[1].remark, '新增二号定存');

        final mPeriods = merged.mergedTables!['record_period']!;
        expect(
          mPeriods.singleWhere((p) => p['id'] == 1)['state'],
          PeriodState.active,
        ); // 3d resume preserved!
        expect(
          mPeriods.singleWhere((p) => p['id'] == 2)['state'],
          PeriodState.active,
        ); // 3d extension preserved!

        final mPlans = merged.mergedTables!['money_save_plan']!;
        expect(
          mPlans.singleWhere((p) => p['id'] == 10)['auto_plan'],
          isTrue,
        ); // 3c auto_plan preserved!
        expect(
          mPlans.singleWhere((p) => p['id'] == 11)['status'],
          SavingsPlanStatus.active,
        ); // 3c manual unarchive preserved!

        // Deleting FD1 on Local while Remote auto-settles FD1 must abort cleanly!
        final localDeletedFd = _seedTables(
          assets: <Map<String, Object?>>[
            _ordinaryAsset(
              id: 1,
              name: '招行一卡通',
              initMinor: 500000,
              balMinor: 500000,
              isDefault: true,
              fixedDepositInfo: null,
            ),
            _ordinaryAsset(
              id: 2,
              name: '零钱通',
              initMinor: 10000,
              balMinor: 10000,
              isDefault: false,
            ),
          ],
          recordPeriods: <Map<String, Object?>>[pausedPeriod, endedCountPeriod],
          moneySavePlans: <Map<String, Object?>>[
            schedPlanBase,
            archivedPlanBase,
          ],
        );
        final delVsSettle = tryThreeWayMergeSyncSnapshots(
          baseLocalDiff: buildBaseLocalDiffRepresentation(
            baseTables: base,
            localTables: localDeletedFd,
          ),
          localTables: localDeletedFd,
          remoteTables: remote,
          nowMs: startDayMs + 86400000,
        );
        expect(delVsSettle.merged, isFalse);
      },
    );
  });
}
