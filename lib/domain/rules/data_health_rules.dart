import 'dart:convert';

import '../../core/failure.dart';
import '../../core/money.dart';
import '../ledger/asset_json.dart';
import '../ledger/effects.dart';
import '../ledger/record_extra.dart';
import '../ledger/record_relations.dart';
import '../model/codes.dart';
import 'asset_overview.dart';
import 'debt_rules.dart';
import 'fixed_deposit.dart';

/// Severity level for an ADR-012 Data Health Check finding.
enum DataHealthSeverity { error, warning, info }

/// Classification of an ADR-012 Data Health Check finding.
enum DataHealthIssueKind {
  ordinaryBalanceDrift,
  debtPrincipalDrift,
  creditNegativeLimit,
  creditInitialOffsetInfo,
  orphanTagRecord,
  missingBookRef,
  missingCategoryRef,
  missingAssetRef,
  brokenRelationLink,
  malformedJson,
  invalidRecord,
}

/// Asset projection used by pure ADR-012 Data Health Check rules.
final class HealthAssetRow {
  const HealthAssetRow({
    required this.id,
    required this.name,
    required this.type,
    this.subType = RecordDirection.none,
    this.status = AssetStatus.active,
    required this.balanceMinor,
    required this.initMoneyMinor,
    this.currency,
    this.extraInfo,
    this.loanInfo,
    this.creditInfo,
    this.fixedDepositInfo,
  });

  final int id;
  final String name;
  final int type;
  final int subType;
  final int status;
  final BigInt balanceMinor;
  final BigInt initMoneyMinor;
  final String? currency;
  final String? extraInfo;
  final String? loanInfo;
  final String? creditInfo;
  final String? fixedDepositInfo;
}

/// Record projection used by pure ADR-012 Data Health Check rules.
final class HealthRecordRow {
  const HealthRecordRow({
    required this.recordId,
    required this.type,
    this.subType = RecordDirection.none,
    required this.moneyMinor,
    required this.recordTime,
    this.createDate,
    this.recordCatId = noRef,
    this.assetId = noRef,
    this.fromAssetId = noRef,
    this.toAssetId = noRef,
    required this.accountBookId,
    this.relInfo,
    this.extraInfo,
  });

  final String recordId;
  final int type;
  final int subType;
  final BigInt moneyMinor;
  final int recordTime;
  final int? createDate;
  final int recordCatId;
  final int assetId;
  final int fromAssetId;
  final int toAssetId;
  final int accountBookId;
  final String? relInfo;
  final String? extraInfo;
}

/// Account book projection for reference & JSON checks.
final class HealthBookRow {
  const HealthBookRow({required this.id, required this.name, this.extraInfo});

  final int id;
  final String name;
  final String? extraInfo;
}

/// Category projection for reference & JSON checks.
final class HealthCategoryRow {
  const HealthCategoryRow({
    required this.id,
    required this.name,
    required this.accountBookId,
    this.parentCatId = noRef,
    this.extraInfo,
  });

  final int id;
  final String name;
  final int accountBookId;
  final int parentCatId;
  final String? extraInfo;
}

/// Tag projection for orphan `tag_record` & JSON checks.
final class HealthTagRow {
  const HealthTagRow({required this.tagId, required this.name, this.extraInfo});

  final String tagId;
  final String name;
  final String? extraInfo;
}

/// `tag_record` join row projection.
final class HealthTagRecordRow {
  const HealthTagRecordRow({required this.tagId, required this.recordId});

  final String tagId;
  final String recordId;
}

/// Optional JSON column projection for auxiliary tables (`budget`, `money_save_plan`, etc.).
final class HealthAuxJsonRow {
  const HealthAuxJsonRow({
    required this.table,
    required this.rowKey,
    required this.column,
    this.rawJson,
  });

  final String table;
  final String rowKey;
  final String column;
  final String? rawJson;
}

/// Single diagnostic finding produced by [evaluateDataHealth].
final class DataHealthIssue {
  const DataHealthIssue({
    required this.kind,
    required this.severity,
    required this.title,
    required this.description,
    required this.repairable,
    this.assetId,
    this.recordId,
    this.tagId,
    this.cachedMinor,
    this.expectedMinor,
    this.currency,
  });

  final DataHealthIssueKind kind;
  final DataHealthSeverity severity;
  final String title;
  final String description;
  final bool repairable;
  final int? assetId;
  final String? recordId;
  final String? tagId;
  final BigInt? cachedMinor;
  final BigInt? expectedMinor;
  final String? currency;
}

/// Exact balance repair patch for an ordinary/savings/investment account
/// (`asset.type != 4 && asset.type != 6`).
final class OrdinaryBalanceRepairPatch {
  const OrdinaryBalanceRepairPatch({
    required this.assetId,
    required this.assetName,
    required this.previousBalanceMinor,
    required this.expectedBalanceMinor,
    required this.currency,
  });

  final int assetId;
  final String assetName;
  final BigInt previousBalanceMinor;
  final BigInt expectedBalanceMinor;
  final String currency;
}

/// Exact principal & status repair patch for a debt account (`asset.type == 4`).
final class DebtPrincipalRepairPatch {
  const DebtPrincipalRepairPatch({
    required this.assetId,
    required this.assetName,
    required this.previousBalanceMinor,
    required this.expectedBalanceMinor,
    required this.previousStatus,
    required this.expectedStatus,
    required this.encodedLoanInfo,
    required this.currency,
  });

  final int assetId;
  final String assetName;
  final BigInt previousBalanceMinor;
  final BigInt expectedBalanceMinor;
  final int previousStatus;
  final int expectedStatus;
  final String encodedLoanInfo;
  final String currency;
}

/// Exact cleanup patch for an orphan `tag_record` join row.
final class OrphanTagRecordRepairPatch {
  const OrphanTagRecordRepairPatch({
    required this.tagId,
    required this.recordId,
  });

  final String tagId;
  final String recordId;
}

/// Complete ADR-012 Data Health Check report and deterministic repair plan.
final class DataHealthReport {
  const DataHealthReport({
    required this.checkedAtMs,
    required this.checkedAssetCount,
    required this.checkedRecordCount,
    required this.checkedTagRecordCount,
    required this.issues,
    required this.ordinaryRepairs,
    required this.debtRepairs,
    required this.orphanTagRepairs,
  });

  final int checkedAtMs;
  final int checkedAssetCount;
  final int checkedRecordCount;
  final int checkedTagRecordCount;
  final List<DataHealthIssue> issues;
  final List<OrdinaryBalanceRepairPatch> ordinaryRepairs;
  final List<DebtPrincipalRepairPatch> debtRepairs;
  final List<OrphanTagRecordRepairPatch> orphanTagRepairs;

  int get errorCount =>
      issues.where((i) => i.severity == DataHealthSeverity.error).length;

  int get warningCount =>
      issues.where((i) => i.severity == DataHealthSeverity.warning).length;

  int get infoCount =>
      issues.where((i) => i.severity == DataHealthSeverity.info).length;

  int get repairableCount =>
      ordinaryRepairs.length + debtRepairs.length + orphanTagRepairs.length;

  bool get isHealthy => errorCount == 0 && warningCount == 0;
}

String _fmtMoney(BigInt minor, String currency) =>
    '$currency ${Money.minor(minor, currency).decimal}';

bool _isValidJsonMapText(String? raw) {
  if (raw == null || raw.trim().isEmpty) return true;
  try {
    final decoded = jsonDecode(raw);
    return decoded is Map<String, Object?>;
  } on FormatException {
    return false;
  }
}

/// Runs the pure ADR-012 Data Health Check over a ledger snapshot (`R1..R5`).
///
/// Key invariants:
/// - Ordinary/Savings/Investment (`asset.type != 4 && asset.type != 6`):
///   compares `balanceMinor` vs `initMoneyMinor + sum(balanceEffects)`.
/// - Debt (`asset.type == 4`): compares `balanceMinor` and `status` vs
///   `recomputeDebtPrincipal`.
/// - Credit Card (`asset.type == 6`): `initMoneyMinor` is fixed credit limit,
///   NEVER initial balance! Never adds `initMoneyMinor` into credit card
///   balance, never auto-mutates credit card `balanceMinor`, validates
///   `initMoneyMinor >= 0` & `credit_info` JSON, and reports
///   `sum(balanceEffects)` vs `balanceMinor` as `info` if initial debt/surplus
///   existed at card creation.
/// - Checks orphan `tag_record`, missing book/category/asset refs, broken
///   `rel_info` links, and malformed JSON columns.
DataHealthReport evaluateDataHealth({
  required List<HealthAssetRow> assets,
  required List<HealthRecordRow> records,
  required List<HealthBookRow> books,
  required List<HealthCategoryRow> categories,
  required List<HealthTagRow> tags,
  required List<HealthTagRecordRow> tagRecords,
  List<HealthAuxJsonRow> auxJsonRows = const [],
  RateTable? rates,
  required int nowMs,
}) {
  final effectiveRates = rates ?? RateTable(const {});
  final sortedAssets = [...assets]..sort((a, b) => a.id.compareTo(b.id));
  final assetsById = <int, HealthAssetRow>{
    for (final a in sortedAssets) a.id: a,
  };
  final booksById = <int, HealthBookRow>{for (final b in books) b.id: b};
  final categoriesById = <int, HealthCategoryRow>{
    for (final c in categories) c.id: c,
  };
  final tagsById = <String, HealthTagRow>{for (final t in tags) t.tagId: t};
  final recordsById = <String, HealthRecordRow>{
    for (final r in records) r.recordId: r,
  };

  final issues = <DataHealthIssue>[];
  final ordinaryRepairs = <OrdinaryBalanceRepairPatch>[];
  final debtRepairs = <DebtPrincipalRepairPatch>[];
  final orphanTagRepairs = <OrphanTagRecordRepairPatch>[];

  // Track assets touched by records whose JSON or type could not be parsed cleanly
  // so auto-repair never overwrites an account balance from an incomplete sum.
  final taintedAssetIds = <int>{};
  void taintRecordAssets(HealthRecordRow r) {
    if (r.assetId != noRef) taintedAssetIds.add(r.assetId);
    if (r.fromAssetId != noRef) taintedAssetIds.add(r.fromAssetId);
    if (r.toAssetId != noRef) taintedAssetIds.add(r.toAssetId);
  }

  // 1. Validate auxiliary JSON columns on books, categories, tags, and plans.
  for (final b in books) {
    if (!_isValidJsonMapText(b.extraInfo)) {
      issues.add(
        DataHealthIssue(
          kind: DataHealthIssueKind.malformedJson,
          severity: DataHealthSeverity.error,
          title: '账本「${b.name}」扩展 JSON 损坏',
          description: 'account_book(id=${b.id}).extra_info 不是合法的 JSON 对象。',
          repairable: false,
        ),
      );
    }
  }
  for (final c in categories) {
    if (!_isValidJsonMapText(c.extraInfo)) {
      issues.add(
        DataHealthIssue(
          kind: DataHealthIssueKind.malformedJson,
          severity: DataHealthSeverity.error,
          title: '分类「${c.name}」扩展 JSON 损坏',
          description: 'record_category(id=${c.id}).extra_info 不是合法的 JSON 对象。',
          repairable: false,
        ),
      );
    }
  }
  for (final t in tags) {
    if (!_isValidJsonMapText(t.extraInfo)) {
      issues.add(
        DataHealthIssue(
          kind: DataHealthIssueKind.malformedJson,
          severity: DataHealthSeverity.error,
          title: '标签「${t.name}」扩展 JSON 损坏',
          description: 'tag(tag_id=${t.tagId}).extra_info 不是合法的 JSON 对象。',
          repairable: false,
          tagId: t.tagId,
        ),
      );
    }
  }
  for (final aux in auxJsonRows) {
    if (!_isValidJsonMapText(aux.rawJson)) {
      issues.add(
        DataHealthIssue(
          kind: DataHealthIssueKind.malformedJson,
          severity: DataHealthSeverity.error,
          title: '${aux.table} 扩展 JSON 损坏',
          description:
              '${aux.table}(${aux.rowKey}).${aux.column} 不是合法的 JSON 对象。',
          repairable: false,
        ),
      );
    }
  }

  // 2. Scan all records: check refs, JSON columns, broken rel_info links, and accumulate balanceEffects.
  final effectsByAsset = <int, BigInt>{};
  final parsedCurrencyByRecordId = <String, CurrencySnapshot?>{};

  for (final r in records) {
    if (!booksById.containsKey(r.accountBookId)) {
      issues.add(
        DataHealthIssue(
          kind: DataHealthIssueKind.missingBookRef,
          severity: DataHealthSeverity.error,
          title: '账单缺失所属账本引用',
          description:
              '账单 ${r.recordId} 引用的账本 ID (${r.accountBookId}) 在 account_book 表中不存在。',
          repairable: false,
          recordId: r.recordId,
        ),
      );
    }

    if (r.recordCatId != noRef && !categoriesById.containsKey(r.recordCatId)) {
      issues.add(
        DataHealthIssue(
          kind: DataHealthIssueKind.missingCategoryRef,
          severity: DataHealthSeverity.warning,
          title: '账单引用了不存在的分类',
          description:
              '账单 ${r.recordId} 引用的分类 ID (${r.recordCatId}) 在 record_category 表中不存在。',
          repairable: false,
          recordId: r.recordId,
        ),
      );
    }

    for (final refEntry in <(String, int)>[
      ('asset_id', r.assetId),
      ('from_asset_id', r.fromAssetId),
      ('to_asset_id', r.toAssetId),
    ]) {
      final col = refEntry.$1;
      final aid = refEntry.$2;
      if (aid != noRef && !assetsById.containsKey(aid)) {
        issues.add(
          DataHealthIssue(
            kind: DataHealthIssueKind.missingAssetRef,
            severity: DataHealthSeverity.warning,
            title: '账单引用了不存在的账户',
            description: '账单 ${r.recordId} 的 $col ($aid) 在 asset 表中不存在。',
            repairable: false,
            recordId: r.recordId,
            assetId: aid,
          ),
        );
      }
    }

    CurrencySnapshot? currSnapshot;
    if (r.extraInfo != null && r.extraInfo!.trim().isNotEmpty) {
      try {
        final parsedExtra = RecordExtra.parse(r.extraInfo);
        currSnapshot = parsedExtra.currency;
        // Force validation of advance bill info if present.
        parsedExtra.advance;
      } catch (_) {
        taintRecordAssets(r);
        issues.add(
          DataHealthIssue(
            kind: DataHealthIssueKind.malformedJson,
            severity: DataHealthSeverity.error,
            title: '账单扩展信息 JSON 损坏',
            description: '账单 ${r.recordId} 的 extra_info 无法解析，已跳过涉及账户的自动余额改写。',
            repairable: false,
            recordId: r.recordId,
          ),
        );
      }
    }
    parsedCurrencyByRecordId[r.recordId] = currSnapshot;

    if (r.relInfo != null && r.relInfo!.trim().isNotEmpty) {
      try {
        final rel = RecordRelations.parse(r.relInfo);
        final refunds = rel.refunds;
        final reimbursements = rel.reimbursements;
        final transferFee = rel.transferFee;

        void checkLinkedRecord(String? targetId, String relationName) {
          if (targetId == null || targetId.trim().isEmpty) return;
          if (!recordsById.containsKey(targetId)) {
            issues.add(
              DataHealthIssue(
                kind: DataHealthIssueKind.brokenRelationLink,
                severity: DataHealthSeverity.warning,
                title: '账单关联关系断链（$relationName）',
                description:
                    '账单 ${r.recordId} 的 rel_info 指向不存在的关联账单 $targetId。',
                repairable: false,
                recordId: r.recordId,
              ),
            );
          }
        }

        checkLinkedRecord(refunds?.originId, '退款原单');
        for (final child in refunds?.children ?? const <LinkedBill>[]) {
          checkLinkedRecord(child.billId, '退款子单');
        }
        checkLinkedRecord(reimbursements?.originId, '报销原单');
        for (final child in reimbursements?.children ?? const <LinkedBill>[]) {
          checkLinkedRecord(child.billId, '报销收款子单');
        }
        checkLinkedRecord(transferFee?.parentId, '转账手续费父单');
      } catch (_) {
        issues.add(
          DataHealthIssue(
            kind: DataHealthIssueKind.malformedJson,
            severity: DataHealthSeverity.error,
            title: '账单关联信息 JSON 损坏',
            description: '账单 ${r.recordId} 的 rel_info 格式损坏无法解析。',
            repairable: false,
            recordId: r.recordId,
          ),
        );
      }
    }

    try {
      final deltas = balanceEffects(
        EntryFacts(
          type: r.type,
          subType: r.subType,
          moneyMinor: r.moneyMinor,
          assetId: r.assetId,
          fromAssetId: r.fromAssetId,
          toAssetId: r.toAssetId,
          currency: currSnapshot,
        ),
      );
      for (final d in deltas) {
        effectsByAsset[d.assetId] =
            (effectsByAsset[d.assetId] ?? BigInt.zero) + d.minor;
      }
    } on Failure catch (e) {
      taintRecordAssets(r);
      issues.add(
        DataHealthIssue(
          kind: DataHealthIssueKind.invalidRecord,
          severity: DataHealthSeverity.error,
          title: '账单余额影响异常',
          description: '账单 ${r.recordId} 无法计算余额变动：${e.message}',
          repairable: false,
          recordId: r.recordId,
        ),
      );
    }
  }

  // 3. Check each asset by category (Credit Card / Debt / Ordinary).
  const debtPrincipalTypes = <int>{
    RecordType.borrowIn,
    RecordType.lendOut,
    RecordType.repay,
    RecordType.collect,
  };

  for (final asset in sortedAssets) {
    final curr = normalizeCurrency(asset.currency) ?? effectiveRates.base;

    if (asset.type == AssetType.credit) {
      // REDLINE (ADR-012 / DR-CD-01): init_money_minor is fixed credit limit,
      // NEVER initial balance! Never add initMoneyMinor into credit balance!
      if (asset.initMoneyMinor < BigInt.zero) {
        issues.add(
          DataHealthIssue(
            kind: DataHealthIssueKind.creditNegativeLimit,
            severity: DataHealthSeverity.error,
            title: '信用账户「${asset.name}」授信额度为负数',
            description:
                '信用账户固定授信额度（init_money）不能为负，当前值：${_fmtMoney(asset.initMoneyMinor, curr)}。请在账户编辑中修正额度。',
            repairable: false,
            assetId: asset.id,
            cachedMinor: asset.initMoneyMinor,
            currency: curr,
          ),
        );
      }

      try {
        final ci = CreditInfo.parse(asset.creditInfo);
        final bd = ci.billDay;
        final rd = ci.repaymentDay;
        final afterBd = ci.repaymentAfterBillDay;
        ci.billDayCounted;
        ci.interestFreeReminder;
        ci.installments;
        ci.sharedLimitAssetId;
        final validBd =
            bd == unsetDay || bd == endOfMonthDay || (bd >= 1 && bd <= 28);
        final validRd = afterBd
            ? (rd == unsetDay || (rd >= 1 && rd <= 365))
            : (rd == unsetDay || rd == endOfMonthDay || (rd >= 1 && rd <= 28));
        if (!validBd || !validRd) {
          throw const FormatException('invalid credit cycle day');
        }
      } catch (_) {
        issues.add(
          DataHealthIssue(
            kind: DataHealthIssueKind.malformedJson,
            severity: DataHealthSeverity.error,
            title: '信用账户「${asset.name}」配置 JSON 损坏',
            description: 'asset(id=${asset.id}).credit_info 存在非法字段类型或语法错误。',
            repairable: false,
            assetId: asset.id,
          ),
        );
      }

      try {
        final extra = AssetExtra.parse(asset.extraInfo);
        extra.repayAssetId;
        extra.tempAmounts;
      } catch (_) {
        issues.add(
          DataHealthIssue(
            kind: DataHealthIssueKind.malformedJson,
            severity: DataHealthSeverity.error,
            title: '信用账户「${asset.name}」扩展 JSON 损坏',
            description: 'asset(id=${asset.id}).extra_info 格式损坏无法解析。',
            repairable: false,
            assetId: asset.id,
          ),
        );
      }

      final effectsSum = effectsByAsset[asset.id] ?? BigInt.zero;
      if (effectsSum != asset.balanceMinor) {
        final initialOffset = asset.balanceMinor - effectsSum;
        issues.add(
          DataHealthIssue(
            kind: DataHealthIssueKind.creditInitialOffsetInfo,
            severity: DataHealthSeverity.info,
            title: '信用账户「${asset.name}」含建卡期初差额（仅提示）',
            description:
                '信用卡授信额度为 ${_fmtMoney(asset.initMoneyMinor, curr)}（不计入余额）；'
                '历史流水净变动为 ${_fmtMoney(effectsSum, curr)}，当前账面余额为 '
                '${_fmtMoney(asset.balanceMinor, curr)}，期初建卡差额为 '
                '${_fmtMoney(initialOffset, curr)}。数据体检不会改写信用卡余额，如需校准请使用账户详情「调整余额」。',
            repairable: false,
            assetId: asset.id,
            cachedMinor: asset.balanceMinor,
            expectedMinor: effectsSum,
            currency: curr,
          ),
        );
      }
      continue;
    }

    if (asset.type == AssetType.debt) {
      if (asset.subType != AssetType.debtBorrow &&
          asset.subType != AssetType.debtLend) {
        issues.add(
          DataHealthIssue(
            kind: DataHealthIssueKind.malformedJson,
            severity: DataHealthSeverity.error,
            title: '借贷账户「${asset.name}」子类型无效',
            description:
                'asset(id=${asset.id}).sub_type=${asset.subType}，须为 99（借出）或 100（借入）。',
            repairable: false,
            assetId: asset.id,
          ),
        );
        continue;
      }

      final LoanInfo currentLoanInfo;
      try {
        currentLoanInfo = LoanInfo.parse(asset.loanInfo);
      } catch (_) {
        issues.add(
          DataHealthIssue(
            kind: DataHealthIssueKind.malformedJson,
            severity: DataHealthSeverity.error,
            title: '借贷账户「${asset.name}」loan_info 损坏',
            description: 'asset(id=${asset.id}).loan_info 格式损坏，无法自动校准本金。',
            repairable: false,
            assetId: asset.id,
          ),
        );
        continue;
      }

      final principalRecords =
          [
            for (final r in records)
              if (debtPrincipalTypes.contains(r.type) &&
                  (r.fromAssetId == asset.id || r.toAssetId == asset.id))
                r,
          ]..sort((a, b) {
            final t = a.recordTime.compareTo(b.recordTime);
            if (t != 0) return t;
            final c = (a.createDate ?? 0).compareTo(b.createDate ?? 0);
            if (c != 0) return c;
            return a.recordId.compareTo(b.recordId);
          });

      final entries = [
        for (final r in principalRecords)
          DebtRecordEntry(
            recordId: r.recordId,
            type: r.type,
            subType: r.subType,
            moneyMinor: r.moneyMinor,
            recordTime: r.recordTime,
            currency: parsedCurrencyByRecordId[r.recordId],
          ),
      ];

      final recomputed = recomputeDebtPrincipal(
        debtSubType: asset.subType,
        currentStatus: asset.status,
        currentLoanInfo: currentLoanInfo,
        records: entries,
        debtCurrency: curr,
        rates: effectiveRates,
        allowReopen: false,
        nowMs: nowMs,
      );

      final balanceDrifted = asset.balanceMinor != recomputed.balanceMinor;
      final statusDrifted = asset.status != recomputed.status;
      if (balanceDrifted || statusDrifted) {
        final canRepair = !taintedAssetIds.contains(asset.id);
        issues.add(
          DataHealthIssue(
            kind: DataHealthIssueKind.debtPrincipalDrift,
            severity: DataHealthSeverity.warning,
            title: '借贷账户「${asset.name}」剩余本金或结清状态不一致',
            description:
                '当前缓存余额 ${_fmtMoney(asset.balanceMinor, curr)}（状态 ${asset.status}），'
                '按历史本金流水重算应为 ${_fmtMoney(recomputed.balanceMinor, curr)}（状态 ${recomputed.status}）。',
            repairable: canRepair,
            assetId: asset.id,
            cachedMinor: asset.balanceMinor,
            expectedMinor: recomputed.balanceMinor,
            currency: curr,
          ),
        );
        if (canRepair) {
          debtRepairs.add(
            DebtPrincipalRepairPatch(
              assetId: asset.id,
              assetName: asset.name,
              previousBalanceMinor: asset.balanceMinor,
              expectedBalanceMinor: recomputed.balanceMinor,
              previousStatus: asset.status,
              expectedStatus: recomputed.status,
              encodedLoanInfo: recomputed.loanInfo.encode(),
              currency: curr,
            ),
          );
        }
      }
      continue;
    }

    // Ordinary / Savings / Investment account (asset.type != 4 && asset.type != 6).
    var assetJsonCorrupt = false;
    try {
      final extra = AssetExtra.parse(asset.extraInfo);
      extra.repayAssetId;
      extra.tempAmounts;
    } catch (_) {
      assetJsonCorrupt = true;
      issues.add(
        DataHealthIssue(
          kind: DataHealthIssueKind.malformedJson,
          severity: DataHealthSeverity.error,
          title: '账户「${asset.name}」扩展 JSON 损坏',
          description: 'asset(id=${asset.id}).extra_info 格式损坏无法解析。',
          repairable: false,
          assetId: asset.id,
        ),
      );
    }

    if (asset.fixedDepositInfo != null &&
        asset.fixedDepositInfo!.trim().isNotEmpty) {
      try {
        decodeFixedDepositList(asset.fixedDepositInfo);
      } catch (_) {
        assetJsonCorrupt = true;
        issues.add(
          DataHealthIssue(
            kind: DataHealthIssueKind.malformedJson,
            severity: DataHealthSeverity.error,
            title: '账户「${asset.name}」定期存款 JSON 损坏',
            description: 'asset(id=${asset.id}).fixed_deposit_info 格式损坏无法解析。',
            repairable: false,
            assetId: asset.id,
          ),
        );
      }
    }

    final effectsSum = effectsByAsset[asset.id] ?? BigInt.zero;
    final expectedBalance = asset.initMoneyMinor + effectsSum;
    if (asset.balanceMinor != expectedBalance) {
      final diff = expectedBalance - asset.balanceMinor;
      final canRepair =
          !taintedAssetIds.contains(asset.id) && !assetJsonCorrupt;
      issues.add(
        DataHealthIssue(
          kind: DataHealthIssueKind.ordinaryBalanceDrift,
          severity: DataHealthSeverity.warning,
          title: '账户「${asset.name}」缓存余额漂移',
          description:
              '期初金额 ${_fmtMoney(asset.initMoneyMinor, curr)} + 流水净变动 '
              '${_fmtMoney(effectsSum, curr)} = 理论余额 ${_fmtMoney(expectedBalance, curr)}；'
              '当前缓存余额为 ${_fmtMoney(asset.balanceMinor, curr)}（差额 ${_fmtMoney(diff, curr)}）。',
          repairable: canRepair,
          assetId: asset.id,
          cachedMinor: asset.balanceMinor,
          expectedMinor: expectedBalance,
          currency: curr,
        ),
      );
      if (canRepair) {
        ordinaryRepairs.add(
          OrdinaryBalanceRepairPatch(
            assetId: asset.id,
            assetName: asset.name,
            previousBalanceMinor: asset.balanceMinor,
            expectedBalanceMinor: expectedBalance,
            currency: curr,
          ),
        );
      }
    }
  }

  // 4. Check orphan `tag_record` rows.
  final sortedTagRecords = [...tagRecords]
    ..sort((a, b) {
      final c = a.recordId.compareTo(b.recordId);
      return c != 0 ? c : a.tagId.compareTo(b.tagId);
    });
  for (final tr in sortedTagRecords) {
    final missingTag = !tagsById.containsKey(tr.tagId);
    final missingRecord = !recordsById.containsKey(tr.recordId);
    if (missingTag || missingRecord) {
      final reason = missingTag && missingRecord
          ? '标签与账单均已不存在'
          : (missingRecord ? '关联账单已不存在' : '关联标签已不存在');
      issues.add(
        DataHealthIssue(
          kind: DataHealthIssueKind.orphanTagRecord,
          severity: DataHealthSeverity.warning,
          title: '孤立的标签关联记录',
          description:
              'tag_record(tag_id=${tr.tagId}, record_id=${tr.recordId})：$reason。',
          repairable: true,
          tagId: tr.tagId,
          recordId: tr.recordId,
        ),
      );
      orphanTagRepairs.add(
        OrphanTagRecordRepairPatch(tagId: tr.tagId, recordId: tr.recordId),
      );
    }
  }

  return DataHealthReport(
    checkedAtMs: nowMs,
    checkedAssetCount: sortedAssets.length,
    checkedRecordCount: records.length,
    checkedTagRecordCount: sortedTagRecords.length,
    issues: List<DataHealthIssue>.unmodifiable(issues),
    ordinaryRepairs: List<OrdinaryBalanceRepairPatch>.unmodifiable(
      ordinaryRepairs,
    ),
    debtRepairs: List<DebtPrincipalRepairPatch>.unmodifiable(debtRepairs),
    orphanTagRepairs: List<OrphanTagRecordRepairPatch>.unmodifiable(
      orphanTagRepairs,
    ),
  );
}
