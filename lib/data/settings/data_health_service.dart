import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../../core/failure.dart';
import '../../core/money.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/asset_overview.dart';
import '../../domain/rules/data_health_rules.dart';
import '../db/database.dart';
import '../db/failures.dart';

/// Summary returned after an atomic `repairDataHealth` execution (`ADR-012`).
final class DataHealthRepairResult {
  const DataHealthRepairResult({
    required this.repairedOrdinaryCount,
    required this.repairedDebtCount,
    required this.removedOrphanTagCount,
    required this.remainingManualIssueCount,
  });

  final int repairedOrdinaryCount;
  final int repairedDebtCount;
  final int removedOrphanTagCount;
  final int remainingManualIssueCount;

  int get totalRepairedCount =>
      repairedOrdinaryCount + repairedDebtCount + removedOrphanTagCount;

  Map<String, Object> toJson() => <String, Object>{
    'repairedOrdinaryCount': repairedOrdinaryCount,
    'repairedDebtCount': repairedDebtCount,
    'removedOrphanTagCount': removedOrphanTagCount,
    'remainingManualIssueCount': remainingManualIssueCount,
  };

  static DataHealthRepairResult fromJsonString(String raw) {
    final decoded = jsonDecode(raw) as Map<String, Object?>;
    return DataHealthRepairResult(
      repairedOrdinaryCount: (decoded['repairedOrdinaryCount'] as int?) ?? 0,
      repairedDebtCount: (decoded['repairedDebtCount'] as int?) ?? 0,
      removedOrphanTagCount: (decoded['removedOrphanTagCount'] as int?) ?? 0,
      remainingManualIssueCount:
          (decoded['remainingManualIssueCount'] as int?) ?? 0,
    );
  }
}

/// On-demand full ledger verification and atomic safe repair service (`ADR-012`).
final class DataHealthService {
  DataHealthService(this.db);
  final AppDatabase db;

  int _now() => db.nowMs();

  Future<DataHealthReport> _evaluateCurrentSnapshot() async {
    final assets = await db.select(db.assets).get();
    final records = await db.select(db.records).get();
    final books = await db.select(db.accountBooks).get();
    final categories = await db.select(db.recordCategories).get();
    final tags = await db.select(db.tags).get();
    final tagRecords = await db.select(db.tagRecords).get();
    final currencies = await db.select(db.currencies).get();
    final budgets = await db.select(db.budgets).get();
    final savePlans = await db.select(db.moneySavePlans).get();

    final rates = RateTable(<String, String>{
      for (final c in currencies) c.code: c.rateToAnchor,
    });

    final auxJsonRows = <HealthAuxJsonRow>[
      for (final b in budgets)
        if (b.extraInfo != null && b.extraInfo!.trim().isNotEmpty)
          HealthAuxJsonRow(
            table: 'budget',
            rowKey: 'id=${b.id}',
            column: 'extra_info',
            rawJson: b.extraInfo,
          ),
      for (final p in savePlans)
        if (p.extraInfo != null && p.extraInfo!.trim().isNotEmpty)
          HealthAuxJsonRow(
            table: 'money_save_plan',
            rowKey: 'id=${p.id}',
            column: 'extra_info',
            rawJson: p.extraInfo,
          ),
    ];

    return evaluateDataHealth(
      assets: <HealthAssetRow>[
        for (final a in assets)
          HealthAssetRow(
            id: a.id,
            name: a.name,
            type: a.type,
            subType: a.subType,
            status: a.status,
            balanceMinor: a.balanceMinor,
            initMoneyMinor: a.initMoneyMinor,
            currency: a.currency,
            extraInfo: a.extraInfo,
            loanInfo: a.loanInfo,
            creditInfo: a.creditInfo,
            fixedDepositInfo: a.fixedDepositInfo,
          ),
      ],
      records: <HealthRecordRow>[
        for (final r in records)
          HealthRecordRow(
            recordId: r.recordId,
            type: r.type,
            subType: r.subType,
            moneyMinor: r.moneyMinor,
            recordTime: r.recordTime,
            createDate: r.createDate,
            recordCatId: r.recordCatId,
            assetId: r.assetId,
            fromAssetId: r.fromAssetId,
            toAssetId: r.toAssetId,
            accountBookId: r.accountBookId,
            relInfo: r.relInfo,
            extraInfo: r.extraInfo,
          ),
      ],
      books: <HealthBookRow>[
        for (final b in books)
          HealthBookRow(id: b.id, name: b.name, extraInfo: b.extraInfo),
      ],
      categories: <HealthCategoryRow>[
        for (final c in categories)
          HealthCategoryRow(
            id: c.id,
            name: c.name,
            accountBookId: c.accountBookId,
            parentCatId: c.parentCatId,
            extraInfo: c.extraInfo,
          ),
      ],
      tags: <HealthTagRow>[
        for (final t in tags)
          HealthTagRow(tagId: t.tagId, name: t.name, extraInfo: t.extraInfo),
      ],
      tagRecords: <HealthTagRecordRow>[
        for (final tr in tagRecords)
          HealthTagRecordRow(tagId: tr.tagId, recordId: tr.recordId),
      ],
      auxJsonRows: auxJsonRows,
      rates: rates,
      nowMs: _now(),
    );
  }

  /// Runs a consistent read-only health check across all ledger tables (`ADR-012`).
  Future<DataHealthReport> checkHealth() =>
      guardDatabase(() => db.transaction(_evaluateCurrentSnapshot));

  /// Atomically repairs drifted non-credit cached balances, drifted debt
  /// principals/statuses, and orphan `tag_record` rows (`ADR-009`, `ADR-012`).
  ///
  /// Never modifies credit card (`asset.type == 6`) balances or `init_money_minor`,
  /// and never alters user bill records.
  Future<DataHealthRepairResult> repairDataHealth({
    required String commandId,
  }) async {
    if (commandId.isEmpty || commandId.length > 128) {
      throw const Failure(FailureCode.validation, '提交标识无效');
    }
    const payload = <Object?>['repair-data-health-v1'];
    final hash = sha256.convert(utf8.encode(jsonEncode(payload))).toString();

    return guardDatabase(
      () => db.transaction(() async {
        final previous = await (db.select(
          db.writeCommands,
        )..where((t) => t.commandId.equals(commandId))).getSingleOrNull();
        if (previous != null) {
          if (previous.payloadHash != hash) {
            throw const Failure(FailureCode.conflict, '同一提交标识的内容发生变化');
          }
          return DataHealthRepairResult.fromJsonString(previous.resultId);
        }

        final report = await _evaluateCurrentSnapshot();

        // 1. Repair ordinary / savings / investment cached balances (strictly non-credit, non-debt).
        for (final patch in report.ordinaryRepairs) {
          final live = await (db.select(
            db.assets,
          )..where((t) => t.id.equals(patch.assetId))).getSingleOrNull();
          if (live == null ||
              live.type == AssetType.credit ||
              live.type == AssetType.debt) {
            continue;
          }
          final checkedMinor = Money.minor(
            patch.expectedBalanceMinor,
            patch.currency,
          ).storageMinor;
          await (db.update(db.assets)..where((t) => t.id.equals(patch.assetId)))
              .write(AssetsCompanion(balanceMinor: Value(checkedMinor)));
        }

        // 2. Repair debt principals, statuses, and `loan_info` snapshots.
        for (final patch in report.debtRepairs) {
          final live = await (db.select(
            db.assets,
          )..where((t) => t.id.equals(patch.assetId))).getSingleOrNull();
          if (live == null || live.type != AssetType.debt) {
            continue;
          }
          final checkedMinor = Money.minor(
            patch.expectedBalanceMinor,
            patch.currency,
          ).storageMinor;
          await (db.update(
            db.assets,
          )..where((t) => t.id.equals(patch.assetId))).write(
            AssetsCompanion(
              balanceMinor: Value(checkedMinor),
              status: Value(patch.expectedStatus),
              loanInfo: Value(patch.encodedLoanInfo),
            ),
          );
        }

        // 3. Delete orphan `tag_record` rows.
        for (final patch in report.orphanTagRepairs) {
          await (db.delete(db.tagRecords)..where(
                (t) =>
                    t.tagId.equals(patch.tagId) &
                    t.recordId.equals(patch.recordId),
              ))
              .go();
        }

        final postReport = await _evaluateCurrentSnapshot();
        final manualIssues = postReport.issues
            .where((i) => i.severity != DataHealthSeverity.info)
            .length;
        final result = DataHealthRepairResult(
          repairedOrdinaryCount: report.ordinaryRepairs.length,
          repairedDebtCount: report.debtRepairs.length,
          removedOrphanTagCount: report.orphanTagRepairs.length,
          remainingManualIssueCount: manualIssues,
        );

        await db
            .into(db.writeCommands)
            .insert(
              WriteCommandsCompanion.insert(
                commandId: commandId,
                payloadHash: hash,
                resultId: jsonEncode(result.toJson()),
                committedAt: _now(),
              ),
            );
        return result;
      }),
    );
  }
}
