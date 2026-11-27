import 'dart:convert';

import '../ledger/asset_json.dart';
import '../ledger/effects.dart';
import '../ledger/record_extra.dart';
import '../ledger/record_relations.dart';
import '../model/codes.dart';
import 'asset_overview.dart';
import 'billing_period.dart';
import 'budget_rules.dart';
import 'cloud_sync_rules.dart';
import 'data_health_rules.dart';
import 'debt_rules.dart';
import 'fixed_deposit.dart';
import 'income_expense.dart';
import 'installment_rules.dart';
import 'periodic_records.dart';
import 'savings_plan.dart';
import 'tally_backup.dart';

/// Source side from which a merged attachment should be materialized.
enum MergeAttachmentSource { local, remote }

/// Merged attachment descriptor produced by [tryThreeWayMergeSyncSnapshots].
final class MergedAttachmentEntry {
  const MergedAttachmentEntry({
    required this.archivePath,
    required this.sha256,
    required this.source,
  });

  final String archivePath;
  final String sha256;
  final MergeAttachmentSource source;
}

/// Row-level incremental mutation patch (`Local -> Merged`) for a single
/// business table so merged state commits in a single SQLite transaction
/// without wiping and re-inserting 100k unchanged rows.
final class SyncTableDelta {
  const SyncTableDelta({
    required this.tableName,
    required this.upserts,
    required this.deletedKeys,
  });

  final String tableName;
  final List<Map<String, Object?>> upserts;
  final List<Object> deletedKeys;

  bool get isEmpty => upserts.isEmpty && deletedKeys.isEmpty;
}

/// Compact per-table diff between `Base` and `Local` that stores ONLY keys for
/// unchanged rows (`99.9%` in typical 100k-bill ledgers), allowing the full
/// `Base` table maps to be garbage-collected before `Remote` is unpacked.
final class BaseLocalTableDiff {
  const BaseLocalTableDiff({
    required this.tableName,
    required this.unchangedBaseKeys,
    required this.modifiedBaseRows,
    required this.deletedBaseRows,
  });

  final String tableName;
  final Set<Object> unchangedBaseKeys;
  final Map<Object, Map<String, Object?>> modifiedBaseRows;
  final Map<Object, Map<String, Object?>> deletedBaseRows;

  bool containsBaseKey(Object key) =>
      unchangedBaseKeys.contains(key) ||
      modifiedBaseRows.containsKey(key) ||
      deletedBaseRows.containsKey(key);

  Map<String, Object?>? lookupBaseRow(
    Object key,
    Map<Object, Map<String, Object?>> localByKey,
  ) {
    if (unchangedBaseKeys.contains(key)) {
      return localByKey[key];
    }
    return modifiedBaseRows[key] ?? deletedBaseRows[key];
  }

  void forEachBaseRow(
    Map<Object, Map<String, Object?>> localByKey,
    void Function(Object key, Map<String, Object?> row) visitor,
  ) {
    for (final k in unchangedBaseKeys) {
      final row = localByKey[k];
      if (row != null) visitor(k, row);
    }
    for (final e in modifiedBaseRows.entries) {
      visitor(e.key, e.value);
    }
    for (final e in deletedBaseRows.entries) {
      visitor(e.key, e.value);
    }
  }
}

/// Lossless `Base -> Local` deduplicated representation across all 22 tables +
/// attachment checksums.
final class BaseLocalDiffRepresentation {
  const BaseLocalDiffRepresentation({
    required this.tables,
    required this.baseAttachmentChecksums,
    required this.localAttachmentChecksums,
  });

  final Map<String, BaseLocalTableDiff> tables;
  final Map<String, String> baseAttachmentChecksums;
  final Map<String, String> localAttachmentChecksums;
}

/// Result of attempting a three-way accounting-conserving merge.
final class SyncThreeWayMergeResult {
  const SyncThreeWayMergeResult._({
    required this.merged,
    this.abortReason,
    this.mergedTables,
    this.mergedAttachments,
    this.tableDeltas,
  });

  const SyncThreeWayMergeResult.aborted(String reason)
    : this._(merged: false, abortReason: reason);

  const SyncThreeWayMergeResult.succeeded({
    required Map<String, List<Map<String, Object?>>> mergedTables,
    required Map<String, MergedAttachmentEntry> mergedAttachments,
    required Map<String, SyncTableDelta> tableDeltas,
  }) : this._(
         merged: true,
         mergedTables: mergedTables,
         mergedAttachments: mergedAttachments,
         tableDeltas: tableDeltas,
       );

  final bool merged;
  final String? abortReason;
  final Map<String, List<Map<String, Object?>>>? mergedTables;
  final Map<String, MergedAttachmentEntry>? mergedAttachments;
  final Map<String, SyncTableDelta>? tableDeltas;
}

/// Sample bill summary surfaced inside [SyncConflictComparison].
final class SyncConflictSampleBill {
  const SyncConflictSampleBill({
    required this.recordId,
    required this.recordTime,
    required this.type,
    required this.moneyMinor,
    required this.currencyCode,
    required this.remark,
  });

  final String recordId;
  final int recordTime;
  final int type;
  final BigInt moneyMinor;
  final String currencyCode;
  final String remark;

  Map<String, Object> toJson() => <String, Object>{
    'recordId': recordId,
    'recordTime': recordTime,
    'type': type,
    'moneyMinor': moneyMinor.toString(),
    'currencyCode': currencyCode,
    'remark': remark,
  };

  factory SyncConflictSampleBill.fromJson(Map<String, Object?> json) =>
      SyncConflictSampleBill(
        recordId: (json['recordId'] as String?) ?? '',
        recordTime: (json['recordTime'] as int?) ?? 0,
        type: (json['type'] as int?) ?? 0,
        moneyMinor:
            BigInt.tryParse('${json['moneyMinor'] ?? '0'}') ?? BigInt.zero,
        currencyCode: (json['currencyCode'] as String?) ?? 'CNY',
        remark: (json['remark'] as String?) ?? '',
      );
}

/// Structured side-by-side summary of Local vs Remote snapshots for the
/// transparent conflict resolution dialog (and offline cursor cache).
final class SyncConflictComparison {
  const SyncConflictComparison({
    required this.localDeviceName,
    required this.remoteDeviceName,
    required this.remoteRevision,
    required this.remoteUpdatedAtMs,
    required this.localRecordCount,
    required this.remoteRecordCount,
    required this.localAssetCount,
    required this.remoteAssetCount,
    required this.localNoteCount,
    required this.remoteNoteCount,
    required this.localOnlyRecordCount,
    required this.remoteOnlyRecordCount,
    required this.modifiedRecordCount,
    required this.localSampleBills,
    required this.remoteSampleBills,
  });

  final String localDeviceName;
  final String remoteDeviceName;
  final int remoteRevision;
  final int? remoteUpdatedAtMs;
  final int localRecordCount;
  final int remoteRecordCount;
  final int localAssetCount;
  final int remoteAssetCount;
  final int localNoteCount;
  final int remoteNoteCount;
  final int localOnlyRecordCount;
  final int remoteOnlyRecordCount;
  final int modifiedRecordCount;
  final List<SyncConflictSampleBill> localSampleBills;
  final List<SyncConflictSampleBill> remoteSampleBills;

  Map<String, Object?> toJson() => <String, Object?>{
    'localDeviceName': localDeviceName,
    'remoteDeviceName': remoteDeviceName,
    'remoteRevision': remoteRevision,
    'remoteUpdatedAtMs': remoteUpdatedAtMs,
    'localRecordCount': localRecordCount,
    'remoteRecordCount': remoteRecordCount,
    'localAssetCount': localAssetCount,
    'remoteAssetCount': remoteAssetCount,
    'localNoteCount': localNoteCount,
    'remoteNoteCount': remoteNoteCount,
    'localOnlyRecordCount': localOnlyRecordCount,
    'remoteOnlyRecordCount': remoteOnlyRecordCount,
    'modifiedRecordCount': modifiedRecordCount,
    'localSampleBills': <Map<String, Object>>[
      for (final b in localSampleBills) b.toJson(),
    ],
    'remoteSampleBills': <Map<String, Object>>[
      for (final b in remoteSampleBills) b.toJson(),
    ],
  };

  factory SyncConflictComparison.fromJson(Map<String, Object?> json) {
    List<SyncConflictSampleBill> parseBills(Object? raw) {
      if (raw is! List) return const <SyncConflictSampleBill>[];
      return <SyncConflictSampleBill>[
        for (final item in raw)
          if (item is Map<String, Object?>)
            SyncConflictSampleBill.fromJson(item),
      ];
    }

    return SyncConflictComparison(
      localDeviceName: (json['localDeviceName'] as String?) ?? '本机',
      remoteDeviceName: (json['remoteDeviceName'] as String?) ?? '云端设备',
      remoteRevision: (json['remoteRevision'] as int?) ?? 0,
      remoteUpdatedAtMs: json['remoteUpdatedAtMs'] as int?,
      localRecordCount: (json['localRecordCount'] as int?) ?? 0,
      remoteRecordCount: (json['remoteRecordCount'] as int?) ?? 0,
      localAssetCount: (json['localAssetCount'] as int?) ?? 0,
      remoteAssetCount: (json['remoteAssetCount'] as int?) ?? 0,
      localNoteCount: (json['localNoteCount'] as int?) ?? 0,
      remoteNoteCount: (json['remoteNoteCount'] as int?) ?? 0,
      localOnlyRecordCount: (json['localOnlyRecordCount'] as int?) ?? 0,
      remoteOnlyRecordCount: (json['remoteOnlyRecordCount'] as int?) ?? 0,
      modifiedRecordCount: (json['modifiedRecordCount'] as int?) ?? 0,
      localSampleBills: parseBills(json['localSampleBills']),
      remoteSampleBills: parseBills(json['remoteSampleBills']),
    );
  }
}

const Set<String> _intPkTables = <String>{
  'account_book',
  'asset',
  'bank_card',
  'budget',
  'import_platform',
  'record_category',
  'remark',
  'record_template',
  'record_period',
  'reminder_event',
  'installment',
  'note',
  'money_save_plan',
  'money_save_plan_record',
  'auto_map',
};

/// Extracts the canonical primary key for [row] in [tableName] across all 22
/// business tables (handling integer PKs, UUID/string PKs on `record`, `tag`,
/// `wish`, `stat_story`, `currency`, and composite PKs on `tag_record` &
/// `asset_book`).
Object extractSyncTableRowKey(String tableName, Map<String, Object?> row) {
  if (_intPkTables.contains(tableName)) {
    return _asInt(row['id']);
  }
  return switch (tableName) {
    'record' => '${row['record_id'] ?? ''}',
    'tag' => '${row['tag_id'] ?? ''}',
    'wish' => '${row['id'] ?? ''}',
    'stat_story' => '${row['id'] ?? ''}',
    'currency' => '${row['code'] ?? ''}',
    'tag_record' => '${row['tag_id'] ?? ''}\x00${row['record_id'] ?? ''}',
    'asset_book' => '${_asInt(row['asset_id'])}\x00${_asInt(row['book_id'])}',
    _ => throw ArgumentError('Unknown sync table: $tableName'),
  };
}

/// Decodes a composite primary key string produced by [extractSyncTableRowKey]
/// for `tag_record` or `asset_book`.
(String, String) splitCompositeSyncKey(Object key) {
  final raw = '$key';
  final idx = raw.indexOf('\x00');
  if (idx < 0) return (raw, '');
  return (raw.substring(0, idx), raw.substring(idx + 1));
}

int _compareRowKeys(String tableName, Object a, Object b) {
  if (_intPkTables.contains(tableName)) {
    return (a as int).compareTo(b as int);
  }
  if (tableName == 'asset_book') {
    final (a1, a2) = splitCompositeSyncKey(a);
    final (b1, b2) = splitCompositeSyncKey(b);
    final c1 = int.parse(a1).compareTo(int.parse(b1));
    return c1 != 0 ? c1 : int.parse(a2).compareTo(int.parse(b2));
  }
  return '$a'.compareTo('$b');
}

int _asInt(Object? v, [int fallback = 0]) {
  if (v is int) return v;
  if (v is BigInt) return v.toInt();
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim()) ?? fallback;
  return fallback;
}

bool _asBool(Object? v, [bool fallback = false]) {
  if (v is bool) return v;
  if (v is int) return v != 0;
  if (v is String) {
    final s = v.trim().toLowerCase();
    if (s == 'true' || s == '1') return true;
    if (s == 'false' || s == '0') return false;
  }
  return fallback;
}

String? _asNullableString(Object? v) {
  if (v == null) return null;
  return '$v';
}

BigInt _asMinor(Object? v) {
  if (v == null) return BigInt.zero;
  return decodeMinorJson(v, field: 'minor');
}

BigInt? _asNullableMinor(Object? v) {
  if (v == null) return null;
  return decodeMinorJson(v, field: 'minor');
}

bool _canonicalValueEqual(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return a == b;
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_canonicalValueEqual(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k)) return false;
      if (!_canonicalValueEqual(a[k], b[k])) return false;
    }
    return true;
  }
  return a == b;
}

bool _canonicalColumnValueEqual(String key, Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return a == b;
  if (key.endsWith('_minor') && a.runtimeType != b.runtimeType) {
    try {
      return _asNullableMinor(a) == _asNullableMinor(b);
    } catch (_) {
      return false;
    }
  }
  return _canonicalValueEqual(a, b);
}

bool _canonicalRowEqual(Map<String, Object?> a, Map<String, Object?> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) {
    final allKeys = <String>{...a.keys, ...b.keys};
    for (final k in allKeys) {
      if (!_canonicalColumnValueEqual(k, a[k], b[k])) return false;
    }
    return true;
  }
  for (final e in a.entries) {
    if (!b.containsKey(e.key) && e.value != null) return false;
    if (!_canonicalColumnValueEqual(e.key, e.value, b[e.key])) return false;
  }
  return true;
}

Map<Object, Map<String, Object?>> _indexTableRows(
  String tableName,
  List<Map<String, Object?>>? rows,
) {
  if (rows == null || rows.isEmpty) return <Object, Map<String, Object?>>{};
  final map = <Object, Map<String, Object?>>{};
  for (final r in rows) {
    map[extractSyncTableRowKey(tableName, r)] = r;
  }
  return map;
}

/// Builds the low-memory [BaseLocalDiffRepresentation] from `Base` and `Local`
/// so the caller can release `baseTables` before decoding `Remote`.
BaseLocalDiffRepresentation buildBaseLocalDiffRepresentation({
  required Map<String, List<Map<String, Object?>>> baseTables,
  required Map<String, List<Map<String, Object?>>> localTables,
  Map<String, String> baseAttachmentChecksums = const <String, String>{},
  Map<String, String> localAttachmentChecksums = const <String, String>{},
}) {
  final diffs = <String, BaseLocalTableDiff>{};
  for (final tableName in tallyBusinessTables) {
    final localByKey = _indexTableRows(tableName, localTables[tableName]);
    final unchanged = <Object>{};
    final modified = <Object, Map<String, Object?>>{};
    final deleted = <Object, Map<String, Object?>>{};

    final baseRows = baseTables[tableName] ?? const <Map<String, Object?>>[];
    for (final baseRow in baseRows) {
      final key = extractSyncTableRowKey(tableName, baseRow);
      final localRow = localByKey[key];
      if (localRow == null) {
        deleted[key] = baseRow;
      } else if (_canonicalRowEqual(baseRow, localRow)) {
        unchanged.add(key);
      } else {
        modified[key] = baseRow;
      }
    }
    diffs[tableName] = BaseLocalTableDiff(
      tableName: tableName,
      unchangedBaseKeys: unchanged,
      modifiedBaseRows: modified,
      deletedBaseRows: deleted,
    );
  }
  return BaseLocalDiffRepresentation(
    tables: diffs,
    baseAttachmentChecksums: <String, String>{
      for (final e in baseAttachmentChecksums.entries)
        normalizeAttachmentArchivePath(e.key): e.value.toLowerCase(),
    },
    localAttachmentChecksums: <String, String>{
      for (final e in localAttachmentChecksums.entries)
        normalizeAttachmentArchivePath(e.key): e.value.toLowerCase(),
    },
  );
}

String? _stripCreditInfoInstallments(String? rawCreditInfo) {
  if (rawCreditInfo == null || rawCreditInfo.trim().isEmpty) return null;
  try {
    final decoded = jsonDecode(rawCreditInfo);
    if (decoded is! Map<String, Object?>) return rawCreditInfo;
    final copy = Map<String, Object?>.of(decoded)..remove('inst');
    if (copy.isEmpty) return null;
    final sortedKeys = copy.keys.toList()..sort();
    return jsonEncode(<String, Object?>{
      for (final k in sortedKeys) k: copy[k],
    });
  } catch (_) {
    return rawCreditInfo;
  }
}

Map<String, Object?> _fdConfigItemMap(
  FixedDepositItem item,
) => <String, Object?>{
  'money_minor': item.moneyMinor.toString(),
  'from_asset_id': item.fromAssetId,
  'update_asset_balance': item.updateAssetBalance,
  'annual_rate': formatDecimalValue(item.annualRate, trimTrailingZeros: true),
  'period_unit': item.periodUnit,
  'period_count': item.periodCount,
  'deposit_date': item.depositDate,
  'due_date': item.dueDate,
  'expected_income_minor': item.expectedIncomeMinor.toString(),
  'c': item.currency,
  'ac': item.assetCurrency,
  'am_minor': item.assetMoneyMinor.toString(),
  'bc': item.baseCurrency,
  'bm_minor': item.baseMoneyMinor.toString(),
  'remark': item.remark,
  'transfer_record_id': item.transferRecordId,
  'adjust_record_id': item.adjustRecordId,
};

String _fdConfigItemSignature(FixedDepositItem item) =>
    jsonEncode(_fdConfigItemMap(item));

Map<String, FixedDepositItem> _indexFixedDepositByConfigOcc(
  List<FixedDepositItem> items,
) {
  final counts = <String, int>{};
  final indexed = <String, FixedDepositItem>{};
  for (final item in items) {
    final sig = _fdConfigItemSignature(item);
    final occ = counts[sig] ?? 0;
    counts[sig] = occ + 1;
    indexed['$sig#$occ'] = item;
  }
  return indexed;
}

String? _fixedDepositConfigSignature(String? rawFdJson) {
  if (rawFdJson == null || rawFdJson.trim().isEmpty) return null;
  try {
    final items = decodeFixedDepositList(rawFdJson);
    if (items.isEmpty) return null;
    return jsonEncode(<Map<String, Object?>>[
      for (final item in items) _fdConfigItemMap(item),
    ]);
  } catch (_) {
    return rawFdJson;
  }
}

bool _isManuallySettledDebtRow(Map<String, Object?> row) {
  final rawStatus = _asInt(row['status'], AssetStatus.active);
  if (rawStatus != AssetStatus.settled) return false;
  try {
    final info = LoanInfo.parse(_asNullableString(row['loan_info']));
    return info.manualSettled || info.schemaVersion < 2;
  } catch (_) {
    return true;
  }
}

String _debtLoanConfigSignature(String? rawLoanInfo, int rawStatus) {
  try {
    final info = LoanInfo.parse(rawLoanInfo);
    final manualSettled =
        rawStatus == AssetStatus.settled &&
        (info.manualSettled || info.schemaVersion < 2);
    const derivedOrTypedKeys = <String>{
      'sv',
      'startDate',
      'endDate',
      'totalDebtMoney',
      's',
      'sb',
      'scc',
      'sa',
      'pua',
      'cp',
    };
    final rawMap = info.toJson();
    final extraKeys =
        rawMap.keys.where((k) => !derivedOrTypedKeys.contains(k)).toList()
          ..sort();
    return jsonEncode(<String, Object?>{
      'startDate': info.startDate,
      'endDate': info.endDate,
      'isHidden': rawStatus == AssetStatus.hidden,
      'manualSettled': manualSettled,
      if (manualSettled) ...<String, Object?>{
        'sb': info.settledSnapshotMinor?.toString(),
        'scc': info.settledCurrencyCode,
        'sa': info.settledAtMs,
      },
      if (extraKeys.isNotEmpty)
        'extra': <String, Object?>{for (final k in extraKeys) k: rawMap[k]},
    });
  } catch (_) {
    return '${rawStatus == AssetStatus.hidden}|${rawLoanInfo ?? ''}';
  }
}

bool _isAutoDerivedSavingsStatusChange(
  Map<String, Object?> baseRow,
  Map<String, Object?> sideRow,
) {
  final bStatus = _asInt(baseRow['status']);
  final sStatus = _asInt(sideRow['status']);
  if (bStatus == sStatus) return true;
  return _asInt(sideRow['plan_type']) != SavingsPlanType.free &&
      bStatus == SavingsPlanStatus.active &&
      sStatus == SavingsPlanStatus.archived &&
      _asMinor(sideRow['saved_money_minor']) >=
          _asMinor(sideRow['plan_money_minor']);
}

bool _isAutoDerivedSavingsAutoPlanChange(
  Map<String, Object?> baseRow,
  Map<String, Object?> sideRow,
) {
  final bAuto = _asBool(baseRow['auto_plan']);
  final sAuto = _asBool(sideRow['auto_plan']);
  if (bAuto == sAuto) return true;
  return _asInt(sideRow['plan_type']) != SavingsPlanType.free &&
      bAuto &&
      !sAuto &&
      _asInt(sideRow['next_save_date'], noRef) == noRef;
}

/// Projects ONLY user-configured master columns for tables that also store
/// cached/derived accounting progress columns (`asset`, `record_period`,
/// `installment`, `money_save_plan`, `currency`).
Map<String, Object?> _configProjection(
  String tableName,
  Map<String, Object?> row,
) {
  switch (tableName) {
    case 'asset':
      final type = _asInt(row['type']);
      return <String, Object?>{
        'id': _asInt(row['id']),
        'name': row['name'],
        'type': type,
        'sub_type': _asInt(row['sub_type'], -1),
        'create_date': _asInt(row['create_date']),
        'sort': _asInt(row['sort']),
        'icon': row['icon'] ?? '',
        'remark': row['remark'] ?? '',
        'init_money_minor': _asMinor(row['init_money_minor']).toString(),
        'is_effective_asset': _asBool(row['is_effective_asset'], true),
        'color': row['color'],
        // For debt accounts (type == 4), automatic `status` & `cp`/`totalDebtMoney`
        // are derived from principal records via `recomputeDebtPrincipal`, while
        // `startDate`/`endDate`/`manualSettled` are explicit user configuration.
        if (type != AssetType.debt)
          'status': _asInt(row['status'], AssetStatus.active)
        else
          'loan_cfg': _debtLoanConfigSignature(
            _asNullableString(row['loan_info']),
            _asInt(row['status'], AssetStatus.active),
          ),
        'extra_info': row['extra_info'],
        'credit_info_cfg': _stripCreditInfoInstallments(
          _asNullableString(row['credit_info']),
        ),
        'fd_cfg': _fixedDepositConfigSignature(
          _asNullableString(row['fixed_deposit_info']),
        ),
        'group_name': row['group_name'],
        'currency': normalizeCurrency(_asNullableString(row['currency'])),
      };

    case 'record_period':
      final rawState = _asInt(row['state']);
      // `state == 2` (paused) is explicit user configuration; `0 -> 1` (ended)
      // can happen automatically on rule completion.
      return <String, Object?>{
        'id': _asInt(row['id']),
        'record_type': _asInt(row['record_type']),
        'money_minor': _asMinor(row['money_minor']).toString(),
        'fee_minor': _asMinor(row['fee_minor']).toString(),
        'remark': row['remark'] ?? '',
        'cat_id': _asInt(row['cat_id'], noRef),
        'asset_id': _asInt(row['asset_id'], noRef),
        'asset_id2': _asInt(row['asset_id2'], noRef),
        'book_id': _asInt(row['book_id'], 1),
        'images': row['images'],
        'is_paused': rawState == PeriodState.paused,
        'time': row['time'],
        'exclude_budget': _asBool(row['exclude_budget']),
        'exclude_ex_in': _asBool(row['exclude_ex_in']),
        'period_type': _asInt(row['period_type']),
        'period_type_date': row['period_type_date'],
        'period_start_date': _asInt(row['period_start_date']),
        'period_end_date': _asInt(row['period_end_date'], periodEndNever),
        'frequency': _asInt(row['frequency'], 1),
        'create_time': _asInt(row['create_time']),
        'tags': row['tags'],
        'exi': row['exi'],
      };

    case 'installment':
      return <String, Object?>{
        'id': _asInt(row['id']),
        'name': row['name'],
        'cat_id': _asInt(row['cat_id'], noRef),
        'principal_minor': _asMinor(row['principal_minor']).toString(),
        'periods': _asInt(row['periods']),
        'charge_minor': _asMinor(row['charge_minor']).toString(),
        'charge_way': _asInt(row['charge_way']),
        'remainder_in': _asInt(row['remainder_in']),
        'cal_way': _asInt(row['cal_way']),
        'start_date': _asInt(row['start_date']),
        'asset_id': _asInt(row['asset_id'], noRef),
        'book_id': _asInt(row['book_id'], 1),
        'exclude_budget': _asBool(row['exclude_budget']),
        'exclude_ex_in': _asBool(row['exclude_ex_in']),
        'create_date': _asInt(row['create_date']),
        'tags': row['tags'],
        'images': row['images'],
        'exi': row['exi'],
      };

    case 'money_save_plan':
      return <String, Object?>{
        'id': _asInt(row['id']),
        'name': row['name'],
        'remark': row['remark'] ?? '',
        'plan_type': _asInt(row['plan_type']),
        'cycle_type': _asInt(row['cycle_type']),
        'start_date': _asInt(row['start_date']),
        'end_date': _asInt(row['end_date']),
        'plan_money_minor': _asMinor(row['plan_money_minor']).toString(),
        'from_asset_id': _asInt(row['from_asset_id'], noRef),
        'to_asset_id': _asInt(row['to_asset_id'], noRef),
        'book_id': _asInt(row['book_id'], 1),
        'start_money_minor': _asMinor(row['start_money_minor']).toString(),
        'incremental_minor': _asMinor(row['incremental_minor']).toString(),
        'create_date': _asInt(row['create_date']),
        'sort': _asInt(row['sort']),
        'bbz_daily_times': row['bbz_daily_times'],
        'icon': row['icon'] ?? '',
        'extra_info': row['extra_info'],
      };

    case 'currency':
      return <String, Object?>{
        'code': row['code'],
        'name': row['name'],
        'symbol': row['symbol'],
        'type': _asInt(row['type']),
        'anchor_code': row['anchor_code'],
        'icon': row['icon'] ?? '',
        'enable': _asBool(row['enable'], true),
      };

    default:
      return row;
  }
}

String? _transferFeeParentId(Map<String, Object?> recordRow) {
  final rawRel = _asNullableString(recordRow['rel_info']);
  if (rawRel == null || rawRel.trim().isEmpty) return null;
  try {
    return RecordRelations.parse(rawRel).transferFee?.parentId;
  } catch (_) {
    return null;
  }
}

/// Returns `true` when ALL differences in [baseLocalDiff] (`Base -> Local`)
/// were produced exclusively by automatic background maintenance (periodic /
/// installment / auto-savings / fixed-deposit maturity catch-ups, online FX
/// rate refreshes, or auto-copied new-period budgets), with zero manual user
/// edits or deletions.
bool isLocalDiffAutoDerivedOnly({
  required BaseLocalDiffRepresentation baseLocalDiff,
  required Map<String, List<Map<String, Object?>>> localTables,
}) {
  if (!_canonicalValueEqual(
    baseLocalDiff.baseAttachmentChecksums,
    baseLocalDiff.localAttachmentChecksums,
  )) {
    return false;
  }

  const allowedChangedTables = <String>{
    'record',
    'tag_record',
    'asset',
    'record_period',
    'installment',
    'money_save_plan',
    'money_save_plan_record',
    'budget',
    'currency',
  };

  for (final tableName in tallyBusinessTables) {
    final diff = baseLocalDiff.tables[tableName]!;
    if (diff.deletedBaseRows.isNotEmpty) return false;
    final localByKey = _indexTableRows(tableName, localTables[tableName]);
    final hasAdded = localByKey.keys.any((k) => !diff.containsBaseKey(k));
    if (!allowedChangedTables.contains(tableName)) {
      if (diff.modifiedBaseRows.isNotEmpty || hasAdded) return false;
      continue;
    }
    if (tableName == 'asset' ||
        tableName == 'record_period' ||
        tableName == 'installment' ||
        tableName == 'money_save_plan' ||
        tableName == 'currency') {
      if (hasAdded) return false;
      for (final e in diff.modifiedBaseRows.entries) {
        final localRow = localByKey[e.key];
        if (localRow == null) return false;
        if (!_canonicalRowEqual(
          _configProjection(tableName, e.value),
          _configProjection(tableName, localRow),
        )) {
          return false;
        }
        if (tableName == 'asset' &&
            _asBool(e.value['is_default']) != _asBool(localRow['is_default'])) {
          return false;
        }
        if (tableName == 'money_save_plan' &&
            (!_isAutoDerivedSavingsStatusChange(e.value, localRow) ||
                !_isAutoDerivedSavingsAutoPlanChange(e.value, localRow))) {
          return false;
        }
      }
    }
  }

  // Collect IDs of auto-generated savings transfers and fixed-deposit interest records.
  final savingsDiff = baseLocalDiff.tables['money_save_plan_record']!;
  final plansById = _indexTableRows(
    'money_save_plan',
    localTables['money_save_plan'],
  );
  if (savingsDiff.modifiedBaseRows.isNotEmpty) return false;
  final autoSavingsRecordIds = <String>{};
  for (final row
      in localTables['money_save_plan_record'] ??
          const <Map<String, Object?>>[]) {
    final key = extractSyncTableRowKey('money_save_plan_record', row);
    if (savingsDiff.containsBaseKey(key)) continue;
    final plan = plansById[_asInt(row['plan_id'])];
    if (plan == null) return false;
    final planType = _asInt(plan['plan_type']);
    if (planType == SavingsPlanType.free) return false;
    final linkedId = _asNullableString(row['record_id']);
    if (linkedId != null && linkedId.isNotEmpty) {
      autoSavingsRecordIds.add(linkedId);
    }
  }

  final maturedInterestRecordIds = <String>{};
  final assetDiff = baseLocalDiff.tables['asset']!;
  final localAssetsByKey = _indexTableRows('asset', localTables['asset']);
  for (final e in assetDiff.modifiedBaseRows.entries) {
    final baseFd = _asNullableString(e.value['fixed_deposit_info']);
    final localFd = _asNullableString(
      localAssetsByKey[e.key]?['fixed_deposit_info'],
    );
    if (localFd == null || localFd.trim().isEmpty) continue;
    try {
      final baseIds = <String>{
        if (baseFd != null && baseFd.trim().isNotEmpty)
          for (final item in decodeFixedDepositList(baseFd))
            if (item.incomeRecordId != null) item.incomeRecordId!,
      };
      for (final item in decodeFixedDepositList(localFd)) {
        if (item.status == FixedDepositStatus.settled &&
            item.incomeRecordId != null &&
            !baseIds.contains(item.incomeRecordId)) {
          maturedInterestRecordIds.add(item.incomeRecordId!);
        }
      }
    } catch (_) {
      return false;
    }
  }

  final recordDiff = baseLocalDiff.tables['record']!;
  if (recordDiff.modifiedBaseRows.isNotEmpty) return false;
  final addedRecordIds = <String>{};
  final addedPeriodicParentIds = <String>{};
  final localRecords = localTables['record'] ?? const <Map<String, Object?>>[];
  for (final r in localRecords) {
    final rid = '${r['record_id'] ?? ''}';
    if (recordDiff.containsBaseKey(rid)) continue;
    addedRecordIds.add(rid);
    if (_asInt(r['period_id'], noRef) != noRef &&
        _transferFeeParentId(r) == null) {
      addedPeriodicParentIds.add(rid);
    }
  }

  for (final r in localRecords) {
    final rid = '${r['record_id'] ?? ''}';
    if (!addedRecordIds.contains(rid)) continue;
    final isPeriodic = _asInt(r['period_id'], noRef) != noRef;
    final feeParent = _transferFeeParentId(r);
    final isPeriodicFeeChild =
        feeParent != null && addedPeriodicParentIds.contains(feeParent);
    final isInstallment =
        parseInstallmentRecordKey(_asNullableString(r['installment'])) != null;
    final isAutoSavings = autoSavingsRecordIds.contains(rid);
    final isFdInterest =
        _asInt(r['type']) == RecordType.depositInterest &&
        maturedInterestRecordIds.contains(rid);
    if (!isPeriodic &&
        !isPeriodicFeeChild &&
        !isInstallment &&
        !isAutoSavings &&
        !isFdInterest) {
      return false;
    }
  }

  final tagRecordDiff = baseLocalDiff.tables['tag_record']!;
  if (tagRecordDiff.modifiedBaseRows.isNotEmpty) return false;
  for (final tr
      in localTables['tag_record'] ?? const <Map<String, Object?>>[]) {
    final key = extractSyncTableRowKey('tag_record', tr);
    if (tagRecordDiff.containsBaseKey(key)) continue;
    if (!addedRecordIds.contains('${tr['record_id'] ?? ''}')) {
      return false;
    }
  }

  final budgetDiff = baseLocalDiff.tables['budget']!;
  if (budgetDiff.modifiedBaseRows.isNotEmpty) return false;
  for (final b in localTables['budget'] ?? const <Map<String, Object?>>[]) {
    final key = extractSyncTableRowKey('budget', b);
    if (budgetDiff.containsBaseKey(key)) continue;
    final extra = BudgetExtra.fromJson(
      _asNullableString(b['extra_info']),
      fallbackAmountMinor: _asMinor(b['amount_minor']),
    );
    if (!extra.autoCopy) return false;
  }

  return true;
}

final class _PeriodicBundle {
  _PeriodicBundle({
    required this.primary,
    this.feeChild,
    required this.tagRecords,
  });

  final Map<String, Object?> primary;
  Map<String, Object?>? feeChild;
  final List<Map<String, Object?>> tagRecords;
}

final class _InstallmentBundle {
  _InstallmentBundle({required this.records, required this.tagRecords});

  final List<Map<String, Object?>> records;
  final List<Map<String, Object?>> tagRecords;

  BigInt get principalMinor {
    var sum = BigInt.zero;
    for (final r in records) {
      if (_asInt(r['type']) != RecordType.fee) {
        sum += _asMinor(r['money_minor']);
      }
    }
    return sum;
  }

  BigInt get feeMinor {
    var sum = BigInt.zero;
    for (final r in records) {
      if (_asInt(r['type']) == RecordType.fee) {
        sum += _asMinor(r['money_minor']);
      }
    }
    return sum;
  }
}

/// Performs a three-way accounting-conserving merge over `Base` (represented
/// compactly via [baseLocalDiff]), [localTables], and [remoteTables].
///
/// Returns [SyncThreeWayMergeResult.aborted] on any row-level configuration
/// conflict, concurrent `type = 4` balance adjustment on a touched account, or
/// `evaluateDataHealth` invariant violation so the caller safely falls back to
/// archiving `conflict_*.tally` and presenting the comparison dialog.
SyncThreeWayMergeResult tryThreeWayMergeSyncSnapshots({
  required BaseLocalDiffRepresentation baseLocalDiff,
  required Map<String, List<Map<String, Object?>>> localTables,
  required Map<String, List<Map<String, Object?>>> remoteTables,
  Map<String, String> remoteAttachmentChecksums = const <String, String>{},
  required int nowMs,
}) {
  try {
    return _tryThreeWayMergeInner(
      baseLocalDiff: baseLocalDiff,
      localTables: localTables,
      remoteTables: remoteTables,
      remoteAttachmentChecksums: remoteAttachmentChecksums,
      nowMs: nowMs,
    );
  } catch (e) {
    return SyncThreeWayMergeResult.aborted('合并校验异常：$e');
  }
}

SyncThreeWayMergeResult _tryThreeWayMergeInner({
  required BaseLocalDiffRepresentation baseLocalDiff,
  required Map<String, List<Map<String, Object?>>> localTables,
  required Map<String, List<Map<String, Object?>>> remoteTables,
  required Map<String, String> remoteAttachmentChecksums,
  required int nowMs,
}) {
  // Shallow-clone working Local copies for tables where duplicate auto-generated
  // bundles or leaf autoincrement collisions are normalized prior to 3-way merge.
  final droppedLocalRecordIds = <String>{};
  final droppedLocalTagRecordKeys = <Object>{};
  final droppedLocalSavingsRowIds = <int>{};
  final rekeyedLocalSavingsRows = <int, Map<String, Object?>>{};
  final droppedLocalBudgetIds = <int>{};
  final rekeyedLocalBudgetRows = <int, Map<String, Object?>>{};
  final settledFdOverridesByAssetId = <int, Map<String, FixedDepositItem>>{};

  final recordBaseDiff = baseLocalDiff.tables['record']!;
  final tagRecordBaseDiff = baseLocalDiff.tables['tag_record']!;
  final savingsRecBaseDiff = baseLocalDiff.tables['money_save_plan_record']!;
  final budgetBaseDiff = baseLocalDiff.tables['budget']!;

  final localRecordsRaw =
      localTables['record'] ?? const <Map<String, Object?>>[];
  final remoteRecordsRaw =
      remoteTables['record'] ?? const <Map<String, Object?>>[];
  final localRecordsById = _indexTableRows('record', localRecordsRaw);
  final remoteRecordsById = _indexTableRows('record', remoteRecordsRaw);

  final localAddedRecords = <Map<String, Object?>>[
    for (final r in localRecordsRaw)
      if (!recordBaseDiff.containsBaseKey('${r['record_id'] ?? ''}')) r,
  ];
  final remoteAddedRecords = <Map<String, Object?>>[
    for (final r in remoteRecordsRaw)
      if (!recordBaseDiff.containsBaseKey('${r['record_id'] ?? ''}')) r,
  ];

  final localAddedTagRecordsByRecId = <String, List<Map<String, Object?>>>{};
  for (final tr
      in localTables['tag_record'] ?? const <Map<String, Object?>>[]) {
    final k = extractSyncTableRowKey('tag_record', tr);
    if (tagRecordBaseDiff.containsBaseKey(k)) continue;
    (localAddedTagRecordsByRecId['${tr['record_id'] ?? ''}'] ??=
            <Map<String, Object?>>[])
        .add(tr);
  }
  final remoteAddedTagRecordsByRecId = <String, List<Map<String, Object?>>>{};
  for (final tr
      in remoteTables['tag_record'] ?? const <Map<String, Object?>>[]) {
    final k = extractSyncTableRowKey('tag_record', tr);
    if (tagRecordBaseDiff.containsBaseKey(k)) continue;
    (remoteAddedTagRecordsByRecId['${tr['record_id'] ?? ''}'] ??=
            <Map<String, Object?>>[])
        .add(tr);
  }

  // --------------------------------------------------------------------------
  // Step A1: Deduplicate concurrent periodic occurrence bundles by
  // `(period_id, CalendarDate)` (primary + transfer fee child + tag_record).
  // --------------------------------------------------------------------------
  Map<String, List<_PeriodicBundle>> groupPeriodicBundles(
    List<Map<String, Object?>> addedRecs,
    Map<String, List<Map<String, Object?>>> addedTagsByRec,
  ) {
    final feeByParentId = <String, Map<String, Object?>>{};
    for (final r in addedRecs) {
      final parentId = _transferFeeParentId(r);
      if (parentId != null) {
        feeByParentId[parentId] = r;
      }
    }
    final map = <String, List<_PeriodicBundle>>{};
    for (final r in addedRecs) {
      final pid = _asInt(r['period_id'], noRef);
      if (pid == noRef || _transferFeeParentId(r) != null) continue;
      final rid = '${r['record_id'] ?? ''}';
      final fee = feeByParentId[rid];
      final tags = <Map<String, Object?>>[
        ...?addedTagsByRec[rid],
        if (fee != null) ...?addedTagsByRec['${fee['record_id'] ?? ''}'],
      ];
      final calDate = CalendarDate.fromEpochMs(_asInt(r['record_time']));
      final key = '$pid|${calDate.formatIso()}';
      (map[key] ??= <_PeriodicBundle>[]).add(
        _PeriodicBundle(primary: r, feeChild: fee, tagRecords: tags),
      );
    }
    return map;
  }

  final localPeriodicBundles = groupPeriodicBundles(
    localAddedRecords,
    localAddedTagRecordsByRecId,
  );
  final remotePeriodicBundles = groupPeriodicBundles(
    remoteAddedRecords,
    remoteAddedTagRecordsByRecId,
  );
  for (final entry in localPeriodicBundles.entries) {
    final rList = remotePeriodicBundles[entry.key];
    if (rList == null || rList.length != 1 || entry.value.length != 1) continue;
    final lb = entry.value.single;
    final rb = rList.single;
    final sameShape =
        _asInt(lb.primary['type']) == _asInt(rb.primary['type']) &&
        _asMinor(lb.primary['money_minor']) ==
            _asMinor(rb.primary['money_minor']) &&
        _asInt(lb.primary['asset_id'], noRef) ==
            _asInt(rb.primary['asset_id'], noRef) &&
        _asInt(lb.primary['from_asset_id'], noRef) ==
            _asInt(rb.primary['from_asset_id'], noRef) &&
        _asInt(lb.primary['to_asset_id'], noRef) ==
            _asInt(rb.primary['to_asset_id'], noRef) &&
        _asMinor(lb.feeChild?['money_minor']) ==
            _asMinor(rb.feeChild?['money_minor']);
    if (sameShape) {
      droppedLocalRecordIds.add('${lb.primary['record_id'] ?? ''}');
      if (lb.feeChild != null) {
        droppedLocalRecordIds.add('${lb.feeChild!['record_id'] ?? ''}');
      }
      for (final tr in lb.tagRecords) {
        droppedLocalTagRecordKeys.add(extractSyncTableRowKey('tag_record', tr));
      }
    }
  }

  // --------------------------------------------------------------------------
  // Step A2: Deduplicate concurrent installment period bundles by
  // `(installmentId, period)`, guarding against `settleEarly` custom amounts.
  // --------------------------------------------------------------------------
  Map<String, _InstallmentBundle> groupInstallmentBundles(
    List<Map<String, Object?>> addedRecs,
    Map<String, List<Map<String, Object?>>> addedTagsByRec,
  ) {
    final map = <String, _InstallmentBundle>{};
    for (final r in addedRecs) {
      final parsed = parseInstallmentRecordKey(
        _asNullableString(r['installment']),
      );
      if (parsed == null) continue;
      final key = '${parsed.installmentId}-${parsed.period}';
      final bundle = map.putIfAbsent(
        key,
        () => _InstallmentBundle(
          records: <Map<String, Object?>>[],
          tagRecords: <Map<String, Object?>>[],
        ),
      );
      bundle.records.add(r);
      final rid = '${r['record_id'] ?? ''}';
      bundle.tagRecords.addAll(
        addedTagsByRec[rid] ?? const <Map<String, Object?>>[],
      );
    }
    return map;
  }

  final localInstBundles = groupInstallmentBundles(
    localAddedRecords,
    localAddedTagRecordsByRecId,
  );
  final remoteInstBundles = groupInstallmentBundles(
    remoteAddedRecords,
    remoteAddedTagRecordsByRecId,
  );
  for (final entry in localInstBundles.entries) {
    final rb = remoteInstBundles[entry.key];
    if (rb == null) continue;
    final lb = entry.value;
    final lAsset = _asInt(lb.records.first['asset_id'], noRef);
    final rAsset = _asInt(rb.records.first['asset_id'], noRef);
    if (lb.principalMinor != rb.principalMinor ||
        lb.feeMinor != rb.feeMinor ||
        lAsset != rAsset) {
      return const SyncThreeWayMergeResult.aborted(
        '同一分期期次在双端产生了不同本息金额（如提前结清冲突）',
      );
    }
    for (final r in lb.records) {
      droppedLocalRecordIds.add('${r['record_id'] ?? ''}');
    }
    for (final tr in lb.tagRecords) {
      droppedLocalTagRecordKeys.add(extractSyncTableRowKey('tag_record', tr));
    }
  }

  // Guard against one side performing `settleEarly` while the other side
  // concurrently posted any non-deduplicated installment period bill for the
  // same `installmentId` (even on a different period number).
  final localInstMapForGuard = _indexTableRows(
    'installment',
    localTables['installment'],
  );
  final remoteInstMapForGuard = _indexTableRows(
    'installment',
    remoteTables['installment'],
  );
  for (final iid in <Object>{
    ...localInstMapForGuard.keys,
    ...remoteInstMapForGuard.keys,
  }) {
    final lInst = localInstMapForGuard[iid];
    final rInst = remoteInstMapForGuard[iid];
    if (lInst == null || rInst == null) continue;
    final lEarly = InstallmentExtra.parse(
      _asNullableString(lInst['exi']),
    ).settledEarly;
    final rEarly = InstallmentExtra.parse(
      _asNullableString(rInst['exi']),
    ).settledEarly;
    if (lEarly == rEarly) continue;
    final prefix = '$iid-';
    if (lEarly) {
      final remoteAddedAny = remoteInstBundles.keys.any(
        (k) => k.startsWith(prefix),
      );
      if (remoteAddedAny) {
        return const SyncThreeWayMergeResult.aborted('分期提前结清与另一端新增入账期次冲突');
      }
    } else {
      final localAddedAny = localInstBundles.keys.any(
        (k) => k.startsWith(prefix),
      );
      if (localAddedAny) {
        return const SyncThreeWayMergeResult.aborted('分期提前结清与另一端新增入账期次冲突');
      }
    }
  }

  // --------------------------------------------------------------------------
  // Step A3: Deduplicate scheduled auto-savings check-ins, while preserving
  // free-plan (`plan_type == 3`) manual multiple deposits via leaf re-keying.
  // --------------------------------------------------------------------------
  final localPlansById = _indexTableRows(
    'money_save_plan',
    localTables['money_save_plan'],
  );
  final remotePlansById = _indexTableRows(
    'money_save_plan',
    remoteTables['money_save_plan'],
  );
  final localSavingsRecs =
      localTables['money_save_plan_record'] ?? const <Map<String, Object?>>[];
  final remoteSavingsRecs =
      remoteTables['money_save_plan_record'] ?? const <Map<String, Object?>>[];

  var maxSavingsRecId = 0;
  for (final r in localSavingsRecs) {
    final id = _asInt(r['id']);
    if (id > maxSavingsRecId) maxSavingsRecId = id;
  }
  for (final r in remoteSavingsRecs) {
    final id = _asInt(r['id']);
    if (id > maxSavingsRecId) maxSavingsRecId = id;
  }

  final remoteAddedSavingsBySlot = <String, List<Map<String, Object?>>>{};
  final remoteAddedSavingsIds = <int>{};
  for (final r in remoteSavingsRecs) {
    final id = _asInt(r['id']);
    if (savingsRecBaseDiff.containsBaseKey(id)) continue;
    remoteAddedSavingsIds.add(id);
    final pid = _asInt(r['plan_id']);
    final dateKey = LocalCalendarDate.fromEpochMs(
      _asInt(r['record_date']),
    ).dateKey;
    (remoteAddedSavingsBySlot['$pid|$dateKey'] ??= <Map<String, Object?>>[])
        .add(r);
  }

  for (final lr in localSavingsRecs) {
    final id = _asInt(lr['id']);
    if (savingsRecBaseDiff.containsBaseKey(id)) continue;
    final pid = _asInt(lr['plan_id']);
    final plan = remotePlansById[pid] ?? localPlansById[pid];
    final planType = plan == null
        ? SavingsPlanType.free
        : _asInt(plan['plan_type']);
    final dateKey = LocalCalendarDate.fromEpochMs(
      _asInt(lr['record_date']),
    ).dateKey;

    if (planType != SavingsPlanType.free) {
      final rMatches = remoteAddedSavingsBySlot['$pid|$dateKey'];
      if (rMatches != null && rMatches.length == 1) {
        final rr = rMatches.single;
        if (_asMinor(lr['record_money_minor']) ==
                _asMinor(rr['record_money_minor']) &&
            _asInt(lr['from_asset_id'], noRef) ==
                _asInt(rr['from_asset_id'], noRef) &&
            _asInt(lr['to_asset_id'], noRef) ==
                _asInt(rr['to_asset_id'], noRef)) {
          droppedLocalSavingsRowIds.add(id);
          final linkedRecId = _asNullableString(lr['record_id']);
          if (linkedRecId != null &&
              linkedRecId.isNotEmpty &&
              !recordBaseDiff.containsBaseKey(linkedRecId)) {
            droppedLocalRecordIds.add(linkedRecId);
          }
          continue;
        }
      }
    }

    // Independent manual check-ins (e.g. free plan same-day deposits) that
    // collided on SQLite AUTOINCREMENT `id`: re-key Local's leaf row safely.
    if (remoteAddedSavingsIds.contains(id)) {
      final newId = ++maxSavingsRecId;
      rekeyedLocalSavingsRows[id] = Map<String, Object?>.of(lr)..['id'] = newId;
    }
  }

  // --------------------------------------------------------------------------
  // Step A4: Deduplicate fixed-deposit maturity interest records & carry
  // auto-settled status across list-length changes on the same account.
  // --------------------------------------------------------------------------
  final assetBaseDiff = baseLocalDiff.tables['asset']!;
  final localAssetsById = _indexTableRows('asset', localTables['asset']);
  final remoteAssetsById = _indexTableRows('asset', remoteTables['asset']);
  for (final assetKey in localAssetsById.keys) {
    if (!assetBaseDiff.containsBaseKey(assetKey)) continue;
    final baseAsset = assetBaseDiff.lookupBaseRow(assetKey, localAssetsById);
    final localAsset = localAssetsById[assetKey];
    final remoteAsset = remoteAssetsById[assetKey];
    if (baseAsset == null || localAsset == null || remoteAsset == null) {
      continue;
    }
    final baseFdRaw = _asNullableString(baseAsset['fixed_deposit_info']);
    if (baseFdRaw == null || baseFdRaw.isEmpty) continue;
    final baseList = decodeFixedDepositList(baseFdRaw);
    if (baseList.isEmpty) continue;

    final localFdRaw = _asNullableString(localAsset['fixed_deposit_info']);
    final remoteFdRaw = _asNullableString(remoteAsset['fixed_deposit_info']);
    final localList = (localFdRaw == null || localFdRaw.isEmpty)
        ? const <FixedDepositItem>[]
        : decodeFixedDepositList(localFdRaw);
    final remoteList = (remoteFdRaw == null || remoteFdRaw.isEmpty)
        ? const <FixedDepositItem>[]
        : decodeFixedDepositList(remoteFdRaw);

    final baseByOcc = _indexFixedDepositByConfigOcc(baseList);
    final localByOcc = _indexFixedDepositByConfigOcc(localList);
    final remoteByOcc = _indexFixedDepositByConfigOcc(remoteList);

    for (final entry in baseByOcc.entries) {
      final occKey = entry.key;
      final bi = entry.value;
      if (bi.status != FixedDepositStatus.running) continue;

      final li = localByOcc[occKey];
      final ri = remoteByOcc[occKey];
      final lSettled = li != null && li.status == FixedDepositStatus.settled;
      final rSettled = ri != null && ri.status == FixedDepositStatus.settled;

      if ((lSettled && ri == null) || (rSettled && li == null)) {
        return const SyncThreeWayMergeResult.aborted(
          '定期存款在一端被删除或改动、另一端已自动到期结息，需人工确认',
        );
      }

      if (lSettled && rSettled) {
        if (li.incomeRecordId != null &&
            ri.incomeRecordId != null &&
            li.incomeRecordId != ri.incomeRecordId &&
            !recordBaseDiff.containsBaseKey(li.incomeRecordId!)) {
          final lRec = localRecordsById[li.incomeRecordId!];
          final rRec = remoteRecordsById[ri.incomeRecordId!];
          if (lRec != null &&
              rRec != null &&
              _asMinor(lRec['money_minor']) == _asMinor(rRec['money_minor'])) {
            droppedLocalRecordIds.add(li.incomeRecordId!);
          } else {
            return const SyncThreeWayMergeResult.aborted('同一到期定存在双端结息金额不一致');
          }
        }
        (settledFdOverridesByAssetId[assetKey as int] ??=
                <String, FixedDepositItem>{})[occKey] =
            ri;
      } else if (lSettled) {
        (settledFdOverridesByAssetId[assetKey as int] ??=
                <String, FixedDepositItem>{})[occKey] =
            li;
      } else if (rSettled) {
        (settledFdOverridesByAssetId[assetKey as int] ??=
                <String, FixedDepositItem>{})[occKey] =
            ri;
      }
    }
  }

  // --------------------------------------------------------------------------
  // Step A5: Deduplicate auto-copied (`acopy == true`) new-period budgets by
  // `(book_id, section, budget_type, record_cat_id)` & resolve leaf ID collisions.
  // --------------------------------------------------------------------------
  final localBudgets = localTables['budget'] ?? const <Map<String, Object?>>[];
  final remoteBudgets =
      remoteTables['budget'] ?? const <Map<String, Object?>>[];
  var maxBudgetId = 0;
  for (final b in localBudgets) {
    final id = _asInt(b['id']);
    if (id > maxBudgetId) maxBudgetId = id;
  }
  for (final b in remoteBudgets) {
    final id = _asInt(b['id']);
    if (id > maxBudgetId) maxBudgetId = id;
  }

  String budgetSlotKey(Map<String, Object?> b) =>
      '${_asInt(b['book_id'], 1)}|${b['section'] ?? ''}|'
      '${_asInt(b['budget_type'])}|${_asInt(b['record_cat_id'], noRef)}';

  final remoteAddedBudgetsBySlot = <String, Map<String, Object?>>{};
  final remoteAddedBudgetIds = <int>{};
  for (final rb in remoteBudgets) {
    final id = _asInt(rb['id']);
    if (budgetBaseDiff.containsBaseKey(id)) continue;
    remoteAddedBudgetIds.add(id);
    remoteAddedBudgetsBySlot[budgetSlotKey(rb)] = rb;
  }

  final recomputeBudgetBookSections = <(int, String)>{};
  for (final lb in localBudgets) {
    final id = _asInt(lb['id']);
    if (budgetBaseDiff.containsBaseKey(id)) continue;
    final slot = budgetSlotKey(lb);
    final lExtra = BudgetExtra.fromJson(
      _asNullableString(lb['extra_info']),
      fallbackAmountMinor: _asMinor(lb['amount_minor']),
    );
    final rb = remoteAddedBudgetsBySlot[slot];
    if (rb != null) {
      final rExtra = BudgetExtra.fromJson(
        _asNullableString(rb['extra_info']),
        fallbackAmountMinor: _asMinor(rb['amount_minor']),
      );
      if (lExtra.autoCopy &&
          rExtra.autoCopy &&
          lExtra.forward == rExtra.forward &&
          lExtra.baseMinor == rExtra.baseMinor) {
        droppedLocalBudgetIds.add(id);
        recomputeBudgetBookSections.add((
          _asInt(rb['book_id'], 1),
          '${rb['section'] ?? ''}',
        ));
        continue;
      }
      if (!_canonicalRowEqual(lb, rb)) {
        return const SyncThreeWayMergeResult.aborted('同一周期与分类的预算在双端被同时新增为不同金额');
      }
      droppedLocalBudgetIds.add(id);
      continue;
    }
    if (lExtra.autoCopy) {
      recomputeBudgetBookSections.add((
        _asInt(lb['book_id'], 1),
        '${lb['section'] ?? ''}',
      ));
    }
    if (remoteAddedBudgetIds.contains(id)) {
      final newId = ++maxBudgetId;
      rekeyedLocalBudgetRows[id] = Map<String, Object?>.of(lb)..['id'] = newId;
    }
  }
  for (final rb in remoteBudgets) {
    final id = _asInt(rb['id']);
    if (budgetBaseDiff.containsBaseKey(id)) continue;
    final rExtra = BudgetExtra.fromJson(
      _asNullableString(rb['extra_info']),
      fallbackAmountMinor: _asMinor(rb['amount_minor']),
    );
    if (rExtra.autoCopy) {
      recomputeBudgetBookSections.add((
        _asInt(rb['book_id'], 1),
        '${rb['section'] ?? ''}',
      ));
    }
  }

  // Build effective Local rows after Step A deduplications / leaf re-keying.
  List<Map<String, Object?>> effectiveLocalTableRows(String tableName) {
    final raw = localTables[tableName] ?? const <Map<String, Object?>>[];
    switch (tableName) {
      case 'record':
        if (droppedLocalRecordIds.isEmpty) return raw;
        return <Map<String, Object?>>[
          for (final r in raw)
            if (!droppedLocalRecordIds.contains('${r['record_id'] ?? ''}')) r,
        ];
      case 'tag_record':
        if (droppedLocalTagRecordKeys.isEmpty) return raw;
        return <Map<String, Object?>>[
          for (final tr in raw)
            if (!droppedLocalTagRecordKeys.contains(
              extractSyncTableRowKey('tag_record', tr),
            ))
              tr,
        ];
      case 'money_save_plan_record':
        if (droppedLocalSavingsRowIds.isEmpty &&
            rekeyedLocalSavingsRows.isEmpty) {
          return raw;
        }
        return <Map<String, Object?>>[
          for (final r in raw)
            if (!droppedLocalSavingsRowIds.contains(_asInt(r['id'])))
              rekeyedLocalSavingsRows[_asInt(r['id'])] ?? r,
        ];
      case 'budget':
        if (droppedLocalBudgetIds.isEmpty && rekeyedLocalBudgetRows.isEmpty) {
          return raw;
        }
        return <Map<String, Object?>>[
          for (final b in raw)
            if (!droppedLocalBudgetIds.contains(_asInt(b['id'])))
              rekeyedLocalBudgetRows[_asInt(b['id'])] ?? b,
        ];
      default:
        return raw;
    }
  }

  // --------------------------------------------------------------------------
  // Step B: Three-way merge across all 22 tables (separating config vs derived
  // columns on master tables and merging `remark.used_times` counters).
  // --------------------------------------------------------------------------
  const masterDerivedTables = <String>{
    'asset',
    'record_period',
    'installment',
    'money_save_plan',
    'currency',
  };

  final mergedByTable = <String, Map<Object, Map<String, Object?>>>{};

  for (final tableName in tallyBusinessTables) {
    if (tableName == 'remark') {
      final mergedRemarks = _mergeRemarkRows(
        baseDiff: baseLocalDiff.tables['remark']!,
        origLocalRows: localTables['remark'] ?? const <Map<String, Object?>>[],
        remoteRows: remoteTables['remark'] ?? const <Map<String, Object?>>[],
      );
      if (mergedRemarks == null) {
        return const SyncThreeWayMergeResult.aborted('常用备注同主键记录在双端被同时修改为不同内容');
      }
      mergedByTable['remark'] = mergedRemarks;
      continue;
    }

    final baseDiff = baseLocalDiff.tables[tableName]!;
    final origLocalByKey = _indexTableRows(tableName, localTables[tableName]);
    final localByKey = _indexTableRows(
      tableName,
      effectiveLocalTableRows(tableName),
    );
    final remoteByKey = _indexTableRows(tableName, remoteTables[tableName]);

    final allKeys = <Object>{
      ...baseDiff.unchangedBaseKeys,
      ...baseDiff.modifiedBaseRows.keys,
      ...baseDiff.deletedBaseRows.keys,
      ...localByKey.keys,
      ...remoteByKey.keys,
    };

    final mergedMap = <Object, Map<String, Object?>>{};
    final isMasterDerived = masterDerivedTables.contains(tableName);

    for (final key in allKeys) {
      final inBase = baseDiff.containsBaseKey(key);
      final baseRow = inBase
          ? baseDiff.lookupBaseRow(key, origLocalByKey)
          : null;
      final localRow = localByKey[key];
      final remoteRow = remoteByKey[key];

      if (!inBase) {
        if (localRow != null && remoteRow == null) {
          mergedMap[key] = Map<String, Object?>.of(localRow);
        } else if (remoteRow != null && localRow == null) {
          mergedMap[key] = Map<String, Object?>.of(remoteRow);
        } else if (localRow != null && remoteRow != null) {
          if (isMasterDerived) {
            if (!_canonicalRowEqual(
              _configProjection(tableName, localRow),
              _configProjection(tableName, remoteRow),
            )) {
              return SyncThreeWayMergeResult.aborted(
                '表 $tableName 新增同主键记录存在双端冲突',
              );
            }
            mergedMap[key] = _mergeCompatibleMasterRow(
              tableName: tableName,
              baseRow: null,
              localRow: localRow,
              remoteRow: remoteRow,
            );
          } else if (_canonicalRowEqual(localRow, remoteRow)) {
            mergedMap[key] = Map<String, Object?>.of(remoteRow);
          } else {
            return SyncThreeWayMergeResult.aborted(
              '表 $tableName 新增同主键记录存在双端冲突',
            );
          }
        }
        continue;
      }

      // Row existed in Base (`baseRow != null`).
      if (localRow == null && remoteRow == null) {
        continue; // Deleted on both sides.
      }
      if (localRow == null) {
        // Deleted on Local: safe ONLY if Remote did not modify it at all.
        if (_canonicalRowEqual(baseRow!, remoteRow!)) {
          continue;
        }
        return SyncThreeWayMergeResult.aborted(
          '表 $tableName 同一记录在一端被删除、另一端被修改',
        );
      }
      if (remoteRow == null) {
        // Deleted on Remote: safe ONLY if Local did not modify it at all.
        if (_canonicalRowEqual(baseRow!, localRow)) {
          continue;
        }
        return SyncThreeWayMergeResult.aborted(
          '表 $tableName 同一记录在一端被修改、另一端被删除',
        );
      }

      if (isMasterDerived) {
        final baseCfg = _configProjection(tableName, baseRow!);
        final localCfg = _configProjection(tableName, localRow);
        final remoteCfg = _configProjection(tableName, remoteRow);
        final lCfgChanged = !_canonicalRowEqual(baseCfg, localCfg);
        final rCfgChanged = !_canonicalRowEqual(baseCfg, remoteCfg);
        final lManualPlanState =
            tableName == 'money_save_plan' &&
            (!_isAutoDerivedSavingsStatusChange(baseRow, localRow) ||
                !_isAutoDerivedSavingsAutoPlanChange(baseRow, localRow));
        final rManualPlanState =
            tableName == 'money_save_plan' &&
            (!_isAutoDerivedSavingsStatusChange(baseRow, remoteRow) ||
                !_isAutoDerivedSavingsAutoPlanChange(baseRow, remoteRow));
        final lEffChanged = lCfgChanged || lManualPlanState;
        final rEffChanged = rCfgChanged || rManualPlanState;
        if (lEffChanged && rEffChanged) {
          final sameCfg = _canonicalRowEqual(localCfg, remoteCfg);
          final samePlanState =
              tableName != 'money_save_plan' ||
              (_asInt(localRow['status']) == _asInt(remoteRow['status']) &&
                  _asBool(localRow['auto_plan']) ==
                      _asBool(remoteRow['auto_plan']));
          if (!sameCfg || !samePlanState) {
            return SyncThreeWayMergeResult.aborted(
              '表 $tableName 同一主数据配置在双端同时修改',
            );
          }
        }
        final chosenBase = lEffChanged && !rEffChanged ? localRow : remoteRow;
        mergedMap[key] = _mergeCompatibleMasterRow(
          tableName: tableName,
          baseRow: baseRow,
          localRow: localRow,
          remoteRow: remoteRow,
          preferredConfigSource: chosenBase,
        );
      } else {
        final lChanged = !_canonicalRowEqual(baseRow!, localRow);
        final rChanged = !_canonicalRowEqual(baseRow, remoteRow);
        if (!lChanged && !rChanged) {
          mergedMap[key] = Map<String, Object?>.of(baseRow);
        } else if (lChanged && !rChanged) {
          mergedMap[key] = Map<String, Object?>.of(localRow);
        } else if (!lChanged && rChanged) {
          mergedMap[key] = Map<String, Object?>.of(remoteRow);
        } else if (_canonicalRowEqual(localRow, remoteRow)) {
          mergedMap[key] = Map<String, Object?>.of(remoteRow);
        } else {
          return SyncThreeWayMergeResult.aborted('表 $tableName 同一记录在双端被修改为不同值');
        }
      }
    }

    mergedByTable[tableName] = mergedMap;
  }

  // --------------------------------------------------------------------------
  // Step C: Balance-adjust (`record.type == 4`) concurrency guard!
  // If either side added/modified/deleted a `type == 4` balance-adjust record
  // on an account AND the other side touched that same account's balance or
  // `init_money_minor`, abort merge cleanly to prevent double-counting.
  // --------------------------------------------------------------------------
  final origLocalRecById = _indexTableRows('record', localRecordsRaw);
  final effectiveLocalRecById = _indexTableRows(
    'record',
    effectiveLocalTableRows('record'),
  );
  final remoteRecById = remoteRecordsById;
  final mergedRecById = mergedByTable['record']!;

  Set<int> recordTouchedAssets(Map<String, Object?> r) {
    final ids = <int>{};
    final a = _asInt(r['asset_id'], noRef);
    final f = _asInt(r['from_asset_id'], noRef);
    final t = _asInt(r['to_asset_id'], noRef);
    if (a != noRef) ids.add(a);
    if (f != noRef) ids.add(f);
    if (t != noRef) ids.add(t);
    return ids;
  }

  const debtPrincipalRecordTypes = <int>{
    RecordType.borrowIn,
    RecordType.lendOut,
    RecordType.repay,
    RecordType.collect,
  };

  ({
    Set<int> adjustAssets,
    Set<int> balanceTouchedAssets,
    Set<int> manualSettleDebts,
    Set<int> debtPrincipalAssets,
  })
  inspectSideRecordChanges(
    Map<Object, Map<String, Object?>> sideRecs,
    Map<Object, Map<String, Object?>> sideAssets,
  ) {
    final adjust = <int>{};
    final touched = <int>{};
    final manualSettleDebts = <int>{};
    final debtPrincipalAssets = <int>{};

    recordBaseDiff.forEachBaseRow(origLocalRecById, (key, baseRec) {
      final sideRec = sideRecs[key];
      if (sideRec == null) {
        final assets = recordTouchedAssets(baseRec);
        touched.addAll(assets);
        final t = _asInt(baseRec['type']);
        if (t == RecordType.balanceAdjust) {
          adjust.addAll(assets);
        }
        if (debtPrincipalRecordTypes.contains(t)) {
          debtPrincipalAssets.addAll(assets);
        }
      } else if (!_canonicalRowEqual(baseRec, sideRec)) {
        final assets = <int>{
          ...recordTouchedAssets(baseRec),
          ...recordTouchedAssets(sideRec),
        };
        touched.addAll(assets);
        final bt = _asInt(baseRec['type']);
        final st = _asInt(sideRec['type']);
        if (bt == RecordType.balanceAdjust || st == RecordType.balanceAdjust) {
          adjust.addAll(assets);
        }
        if (debtPrincipalRecordTypes.contains(bt) ||
            debtPrincipalRecordTypes.contains(st)) {
          debtPrincipalAssets.addAll(assets);
        }
      }
    });

    for (final e in sideRecs.entries) {
      if (recordBaseDiff.containsBaseKey(e.key)) continue;
      final assets = recordTouchedAssets(e.value);
      touched.addAll(assets);
      final t = _asInt(e.value['type']);
      if (t == RecordType.balanceAdjust) {
        adjust.addAll(assets);
      }
      if (debtPrincipalRecordTypes.contains(t)) {
        debtPrincipalAssets.addAll(assets);
      }
    }

    for (final e in sideAssets.entries) {
      if (!assetBaseDiff.containsBaseKey(e.key)) continue;
      final baseA = assetBaseDiff.lookupBaseRow(e.key, localAssetsById);
      if (baseA == null) continue;
      if (_asMinor(baseA['init_money_minor']) !=
          _asMinor(e.value['init_money_minor'])) {
        touched.add(e.key as int);
      }
      if (_asInt(e.value['type']) == AssetType.debt &&
          _isManuallySettledDebtRow(baseA) !=
              _isManuallySettledDebtRow(e.value)) {
        manualSettleDebts.add(e.key as int);
      }
    }
    return (
      adjustAssets: adjust,
      balanceTouchedAssets: touched,
      manualSettleDebts: manualSettleDebts,
      debtPrincipalAssets: debtPrincipalAssets,
    );
  }

  final localChanges = inspectSideRecordChanges(
    effectiveLocalRecById,
    localAssetsById,
  );
  final remoteChanges = inspectSideRecordChanges(
    remoteRecById,
    remoteAssetsById,
  );
  final hasAdjustCollision =
      localChanges.adjustAssets.any(
        remoteChanges.balanceTouchedAssets.contains,
      ) ||
      remoteChanges.adjustAssets.any(
        localChanges.balanceTouchedAssets.contains,
      );
  if (hasAdjustCollision) {
    return const SyncThreeWayMergeResult.aborted('同一账户存在并发余额变更（平账）与流水改动，需人工确认');
  }
  final hasDebtManualSettleCollision =
      localChanges.manualSettleDebts.any(
        remoteChanges.debtPrincipalAssets.contains,
      ) ||
      remoteChanges.manualSettleDebts.any(
        localChanges.debtPrincipalAssets.contains,
      );
  if (hasDebtManualSettleCollision) {
    return const SyncThreeWayMergeResult.aborted(
      '同一借贷账户一端手动结清或重开、另一端变动本金流水，需人工确认',
    );
  }

  // --------------------------------------------------------------------------
  // Step D: Post-merge deterministic accounting & progress recomputation.
  // --------------------------------------------------------------------------
  final mergedTags = mergedByTable['tag']!;
  final mergedTagRecords = mergedByTable['tag_record']!;

  // D1: Guard against a newly-added `tag_record` referencing a tag/record
  // deleted on the other side; clean up stale `tag_record`s from deleted records.
  final trKeysToRemove = <Object>[];
  for (final e in mergedTagRecords.entries) {
    final tid = '${e.value['tag_id'] ?? ''}';
    final rid = '${e.value['record_id'] ?? ''}';
    final missingTag = !mergedTags.containsKey(tid);
    final missingRec = !mergedRecById.containsKey(rid);
    if (missingTag || missingRec) {
      if (!tagRecordBaseDiff.containsBaseKey(e.key)) {
        return const SyncThreeWayMergeResult.aborted('新增账单引用了另一端已删除的标签或关联账单');
      }
      trKeysToRemove.add(e.key);
    }
  }
  for (final k in trKeysToRemove) {
    mergedTagRecords.remove(k);
  }

  // D2: Recompute `record_period` progress (`last_add_date`, `period_add_times`, `state`).
  final mergedPeriods = mergedByTable['record_period']!;
  if (mergedPeriods.isNotEmpty) {
    final addedPeriodicDatesByPid = <int, List<int>>{};
    for (final e in mergedRecById.entries) {
      if (recordBaseDiff.containsBaseKey(e.key)) continue;
      final pid = _asInt(e.value['period_id'], noRef);
      if (pid == noRef || _transferFeeParentId(e.value) != null) continue;
      final dueStartMs = CalendarDate.fromEpochMs(
        _asInt(e.value['record_time']),
      ).startOfDayMs;
      (addedPeriodicDatesByPid[pid] ??= <int>[]).add(dueStartMs);
    }

    final origLocalPeriods = _indexTableRows(
      'record_period',
      localTables['record_period'],
    );
    final remotePeriods = _indexTableRows(
      'record_period',
      remoteTables['record_period'],
    );
    final periodBaseDiff = baseLocalDiff.tables['record_period']!;

    for (final entry in mergedPeriods.entries) {
      final pid = entry.key as int;
      final row = entry.value;
      final lRow = origLocalPeriods[pid];
      final rRow = remotePeriods[pid];
      final bRow = periodBaseDiff.containsBaseKey(pid)
          ? periodBaseDiff.lookupBaseRow(pid, origLocalPeriods)
          : null;

      var lastAdd = _asInt(row['last_add_date'], noLastAddDate);
      if (lRow != null) {
        final lLast = _asInt(lRow['last_add_date'], noLastAddDate);
        if (lLast > lastAdd) lastAdd = lLast;
      }
      if (rRow != null) {
        final rLast = _asInt(rRow['last_add_date'], noLastAddDate);
        if (rLast > lastAdd) lastAdd = rLast;
      }
      final addedDates = addedPeriodicDatesByPid[pid] ?? const <int>[];
      for (final d in addedDates) {
        if (d > lastAdd) lastAdd = d;
      }
      row['last_add_date'] = lastAdd;

      if (bRow != null) {
        final baseTimes = _asInt(bRow['period_add_times']);
        row['period_add_times'] = baseTimes + addedDates.length;
      }

      // `row['state']` comes from 3-way merged `chosenBase`, so explicit pause /
      // resume transitions (`active <-> paused`) are already resolved against Base.
      final isPaused = _asInt(row['state']) == PeriodState.paused;
      if (isPaused) {
        row['state'] = PeriodState.paused;
      } else {
        final periodEndDate = _asInt(row['period_end_date'], periodEndNever);
        final addTimes = _asInt(row['period_add_times']);
        var ended = false;
        try {
          ended = shouldRuleEnd(
            PeriodScheduleSpec(
              periodType: _asInt(row['period_type']),
              periodTypeDateJson: '${row['period_type_date'] ?? '[]'}',
              frequency: _asInt(row['frequency'], 1),
              periodStartDateMs: _asInt(row['period_start_date']),
              periodEndDate: periodEndDate,
              lastAddDateMs: lastAdd,
              periodAddTimes: addTimes,
              state: PeriodState.active,
            ),
          );
        } catch (_) {
          if (classifyPeriodEndDate(periodEndDate) == PeriodEndMode.count &&
              addTimes >= periodEndDate) {
            ended = true;
          }
        }
        row['state'] = ended ? PeriodState.ended : PeriodState.active;
      }
    }
  }

  // D3: Recompute `installment` progress (`credited`, `next_period`, `next_period_date`).
  final mergedInstallments = mergedByTable['installment']!;
  final instProgressById =
      <
        int,
        ({InstallmentProgress progress, InstallmentExtra extra, int assetId})
      >{};
  if (mergedInstallments.isNotEmpty) {
    final livePeriodsByInstId = <int, Set<int>>{};
    for (final r in mergedRecById.values) {
      final parsed = parseInstallmentRecordKey(
        _asNullableString(r['installment']),
      );
      if (parsed == null) continue;
      (livePeriodsByInstId[parsed.installmentId] ??= <int>{}).add(
        parsed.period,
      );
    }
    final deletedInstPeriods = <int, Set<int>>{};
    recordBaseDiff.forEachBaseRow(origLocalRecById, (key, baseRec) {
      if (mergedRecById.containsKey(key)) return;
      final parsed = parseInstallmentRecordKey(
        _asNullableString(baseRec['installment']),
      );
      if (parsed != null) {
        (deletedInstPeriods[parsed.installmentId] ??= <int>{}).add(
          parsed.period,
        );
      }
    });

    final localInstById = _indexTableRows(
      'installment',
      localTables['installment'],
    );
    final remoteInstById = _indexTableRows(
      'installment',
      remoteTables['installment'],
    );

    for (final entry in mergedInstallments.entries) {
      final iid = entry.key as int;
      final row = entry.value;
      final periods = _asInt(row['periods'], 1);
      final principalMinor = _asMinor(row['principal_minor']);
      final chargeMinor = _asMinor(row['charge_minor']);
      final chargeWay = _asInt(row['charge_way']);
      final calWay = _asInt(row['cal_way']);
      final remainderIn = _asInt(row['remainder_in']);
      final startDateMs = _asInt(row['start_date']);
      final extra = InstallmentExtra.parse(_asNullableString(row['exi']));

      final creditedUnion = <int>{
        ...parseCreditedPeriods(
          _asNullableString(localInstById[iid]?['credited']),
          maxPeriod: periods,
        ),
        ...parseCreditedPeriods(
          _asNullableString(remoteInstById[iid]?['credited']),
          maxPeriod: periods,
        ),
        ...?livePeriodsByInstId[iid]?.where((p) => p >= 1 && p <= periods),
      };
      for (final delP in deletedInstPeriods[iid] ?? const <int>{}) {
        if (!(livePeriodsByInstId[iid]?.contains(delP) ?? false)) {
          creditedUnion.remove(delP);
        }
      }

      if (extra.settledEarly) {
        for (var p = 1; p <= periods; p++) {
          creditedUnion.add(p);
        }
      }

      final schedule = buildInstallmentSchedule(
        installmentId: iid,
        principalMinor: principalMinor,
        periods: periods,
        chargeMinor: chargeMinor,
        chargeWay: chargeWay,
        calWay: calWay,
        remainderIn: remainderIn,
        startDateMs: startDateMs,
        creditedPeriods: creditedUnion,
      );
      final progress = computeInstallmentProgress(
        schedule: schedule,
        principalMinor: principalMinor,
        chargeMinor: chargeMinor,
        startDateMs: startDateMs,
        currentNextPeriod: 1,
      );

      row['credited'] = encodeCreditedPeriods(
        progress.creditedPeriods,
        maxPeriod: periods,
      );
      row['next_period'] = extra.settledEarly
          ? periods + 1
          : progress.nextPeriod;
      row['next_period_date'] = progress.nextPeriodDateMs;
      instProgressById[iid] = (
        progress: progress,
        extra: extra,
        assetId: _asInt(row['asset_id'], noRef),
      );
    }
  }

  // D4: Recompute `money_save_plan` (`saved_money_minor`, `next_save_date`, `status`, `auto_plan`).
  final mergedSavingsPlans = mergedByTable['money_save_plan']!;
  final mergedSavingsRecords = mergedByTable['money_save_plan_record']!;
  if (mergedSavingsPlans.isNotEmpty) {
    final planBaseDiff = baseLocalDiff.tables['money_save_plan']!;
    final origLocalPlans = localPlansById;
    final origLocalSavingsRecsByKey = _indexTableRows(
      'money_save_plan_record',
      localSavingsRecs,
    );

    final baseSavedByPlan = <int, BigInt>{};
    savingsRecBaseDiff.forEachBaseRow(origLocalSavingsRecsByKey, (_, r) {
      final pid = _asInt(r['plan_id']);
      baseSavedByPlan[pid] =
          (baseSavedByPlan[pid] ?? BigInt.zero) +
          _asMinor(r['record_money_minor']);
    });

    final mergedRecsByPlan = <int, List<Map<String, Object?>>>{};
    final mergedSavedByPlan = <int, BigInt>{};
    for (final r in mergedSavingsRecords.values) {
      final pid = _asInt(r['plan_id']);
      (mergedRecsByPlan[pid] ??= <Map<String, Object?>>[]).add(r);
      mergedSavedByPlan[pid] =
          (mergedSavedByPlan[pid] ?? BigInt.zero) +
          _asMinor(r['record_money_minor']);
    }

    for (final entry in mergedSavingsPlans.entries) {
      final pid = entry.key as int;
      final row = entry.value;
      final bPlan = planBaseDiff.containsBaseKey(pid)
          ? planBaseDiff.lookupBaseRow(pid, origLocalPlans)
          : null;
      final lPlan = origLocalPlans[pid];
      final rPlan = remotePlansById[pid];

      final BigInt newSavedMinor;
      if (bPlan != null) {
        final basePlanSaved = _asMinor(bPlan['saved_money_minor']);
        final delta =
            (mergedSavedByPlan[pid] ?? BigInt.zero) -
            (baseSavedByPlan[pid] ?? BigInt.zero);
        newSavedMinor = basePlanSaved + delta;
      } else {
        newSavedMinor = mergedSavedByPlan[pid] ?? BigInt.zero;
      }
      row['saved_money_minor'] = encodeMinorJson(newSavedMinor);

      final planType = _asInt(row['plan_type']);
      final planMoney = _asMinor(row['plan_money_minor']);
      int manualStatus = _asInt(row['status'], SavingsPlanStatus.active);
      bool manualAutoPlan = _asBool(row['auto_plan']);
      var explicitlyUnarchived = false;
      if (bPlan != null && lPlan != null && rPlan != null) {
        if (!_isAutoDerivedSavingsStatusChange(bPlan, lPlan)) {
          manualStatus = _asInt(lPlan['status'], SavingsPlanStatus.active);
          if (_asInt(bPlan['status']) == SavingsPlanStatus.archived &&
              manualStatus == SavingsPlanStatus.active) {
            explicitlyUnarchived = true;
          }
        } else if (!_isAutoDerivedSavingsStatusChange(bPlan, rPlan)) {
          manualStatus = _asInt(rPlan['status'], SavingsPlanStatus.active);
          if (_asInt(bPlan['status']) == SavingsPlanStatus.archived &&
              manualStatus == SavingsPlanStatus.active) {
            explicitlyUnarchived = true;
          }
        } else {
          manualStatus = _asInt(bPlan['status'], SavingsPlanStatus.active);
        }

        if (!_isAutoDerivedSavingsAutoPlanChange(bPlan, lPlan)) {
          manualAutoPlan = _asBool(lPlan['auto_plan']);
        } else if (!_isAutoDerivedSavingsAutoPlanChange(bPlan, rPlan)) {
          manualAutoPlan = _asBool(rPlan['auto_plan']);
        } else {
          manualAutoPlan = _asBool(bPlan['auto_plan']);
        }
      }

      final baseSavedMinor = bPlan != null
          ? _asMinor(bPlan['saved_money_minor'])
          : BigInt.zero;
      final keepExplicitUnarchive =
          explicitlyUnarchived && newSavedMinor <= baseSavedMinor;

      if (planType != SavingsPlanType.free) {
        final mergedSched = mergeSavingsSchedule<Map<String, Object?>>(
          planType: planType,
          cycleType: _asInt(row['cycle_type']),
          startDateMs: _asInt(row['start_date']),
          endDateMs: _asInt(row['end_date']),
          startMoneyMinor: _asMinor(row['start_money_minor']),
          incrementalMinor: _asMinor(row['incremental_minor']),
          records: mergedRecsByPlan[pid] ?? const <Map<String, Object?>>[],
          recordDateOf: (r) => _asInt(r['record_date']),
          recordIdOf: (r) => _asInt(r['id']),
          recordMoneyOf: (r) => _asMinor(r['record_money_minor']),
        );
        int nextSave = noRef;
        for (final s in mergedSched.slots) {
          if (s.matchedRecord == null) {
            nextSave = s.slot.date.startOfDayMs;
            break;
          }
        }
        if (manualStatus == SavingsPlanStatus.archived ||
            (!keepExplicitUnarchive &&
                planMoney > BigInt.zero &&
                newSavedMinor >= planMoney)) {
          row['status'] = SavingsPlanStatus.archived;
          row['auto_plan'] = false;
          row['next_save_date'] = noRef;
        } else {
          row['status'] = SavingsPlanStatus.active;
          row['next_save_date'] = nextSave;
          row['auto_plan'] = nextSave == noRef ? false : manualAutoPlan;
        }
      } else {
        if (manualStatus == SavingsPlanStatus.archived ||
            (!keepExplicitUnarchive &&
                planMoney > BigInt.zero &&
                newSavedMinor > baseSavedMinor &&
                newSavedMinor >= planMoney)) {
          row['status'] = SavingsPlanStatus.archived;
          row['auto_plan'] = false;
          row['next_save_date'] = noRef;
        } else {
          row['status'] = SavingsPlanStatus.active;
          row['auto_plan'] = false;
          row['next_save_date'] = noRef;
        }
      }
    }
  }

  // D5: Recompute `asset` balances, single `is_default`, `used_times`,
  // `credit_info.inst[]`, `fixed_deposit_info`, and debt `loan_info` / `status`!
  final mergedAssets = mergedByTable['asset']!;
  final mergedCurrencies = mergedByTable['currency']!;
  final rawRatesMap = <String, String>{
    for (final c in mergedCurrencies.values)
      '${c['code'] ?? 'CNY'}': '${c['rate_to_anchor'] ?? '1'}',
  };
  final effectiveRates = RateTable(rawRatesMap);

  Map<int, BigInt> computeEffectsMap(Iterable<Map<String, Object?>> recRows) {
    final map = <int, BigInt>{};
    for (final r in recRows) {
      CurrencySnapshot? curr;
      final rawExtra = _asNullableString(r['extra_info']);
      if (rawExtra != null && rawExtra.trim().isNotEmpty) {
        curr = RecordExtra.parse(rawExtra).currency;
      }
      final deltas = balanceEffects(
        EntryFacts(
          type: _asInt(r['type']),
          subType: _asInt(r['sub_type'], RecordDirection.none),
          moneyMinor: _asMinor(r['money_minor']),
          assetId: _asInt(r['asset_id'], noRef),
          fromAssetId: _asInt(r['from_asset_id'], noRef),
          toAssetId: _asInt(r['to_asset_id'], noRef),
          currency: curr,
        ),
      );
      for (final d in deltas) {
        map[d.assetId] = (map[d.assetId] ?? BigInt.zero) + d.minor;
      }
    }
    return map;
  }

  final baseEffectsByAsset = <int, BigInt>{};
  recordBaseDiff.forEachBaseRow(origLocalRecById, (_, r) {
    CurrencySnapshot? curr;
    final rawExtra = _asNullableString(r['extra_info']);
    if (rawExtra != null && rawExtra.trim().isNotEmpty) {
      curr = RecordExtra.parse(rawExtra).currency;
    }
    final deltas = balanceEffects(
      EntryFacts(
        type: _asInt(r['type']),
        subType: _asInt(r['sub_type'], RecordDirection.none),
        moneyMinor: _asMinor(r['money_minor']),
        assetId: _asInt(r['asset_id'], noRef),
        fromAssetId: _asInt(r['from_asset_id'], noRef),
        toAssetId: _asInt(r['to_asset_id'], noRef),
        currency: curr,
      ),
    );
    for (final d in deltas) {
      baseEffectsByAsset[d.assetId] =
          (baseEffectsByAsset[d.assetId] ?? BigInt.zero) + d.minor;
    }
  });
  final localEffectsByAsset = computeEffectsMap(effectiveLocalRecById.values);
  final remoteEffectsByAsset = computeEffectsMap(remoteRecById.values);
  final mergedEffectsByAsset = computeEffectsMap(mergedRecById.values);

  const debtPrincipalTypes = <int>{
    RecordType.borrowIn,
    RecordType.lendOut,
    RecordType.repay,
    RecordType.collect,
  };
  final mergedDebtRecordsByAsset = <int, List<Map<String, Object?>>>{};
  for (final r in mergedRecById.values) {
    if (!debtPrincipalTypes.contains(_asInt(r['type']))) continue;
    final fromId = _asInt(r['from_asset_id'], noRef);
    final toId = _asInt(r['to_asset_id'], noRef);
    if (fromId != noRef) {
      (mergedDebtRecordsByAsset[fromId] ??= <Map<String, Object?>>[]).add(r);
    }
    if (toId != noRef && toId != fromId) {
      (mergedDebtRecordsByAsset[toId] ??= <Map<String, Object?>>[]).add(r);
    }
  }

  var defaultAssetChosen = false;
  // Among assets whose 3-way merged `is_default` is `true`, prefer Remote's
  // choice only when both sides concurrently promoted different defaults.
  int? preferredDefaultAssetId;
  for (final e in mergedAssets.entries) {
    final aid = e.key as int;
    if (_asBool(e.value['is_default']) &&
        _asBool(remoteAssetsById[aid]?['is_default'])) {
      preferredDefaultAssetId = aid;
      break;
    }
  }
  preferredDefaultAssetId ??= mergedAssets.entries
      .where((e) => _asBool(e.value['is_default']))
      .map((e) => e.key as int)
      .firstOrNull;

  for (final entry in mergedAssets.entries) {
    final aid = entry.key as int;
    final row = entry.value;
    final bRow = assetBaseDiff.containsBaseKey(aid)
        ? assetBaseDiff.lookupBaseRow(aid, localAssetsById)
        : null;
    final lRow = localAssetsById[aid];
    final rRow = remoteAssetsById[aid];

    if (preferredDefaultAssetId == aid && !defaultAssetChosen) {
      row['is_default'] = true;
      defaultAssetChosen = true;
    } else {
      row['is_default'] = false;
    }

    if (bRow != null && lRow != null && rRow != null) {
      final baseUsed = _asInt(bRow['used_times']);
      final lUsed = _asInt(lRow['used_times']);
      final rUsed = _asInt(rRow['used_times']);
      final nextUsed = baseUsed + (lUsed - baseUsed) + (rUsed - baseUsed);
      row['used_times'] = nextUsed < 0 ? 0 : nextUsed;
    }

    final fdSettledOverrides = settledFdOverridesByAssetId[aid];
    if (fdSettledOverrides != null && fdSettledOverrides.isNotEmpty) {
      final curFdRaw = _asNullableString(row['fixed_deposit_info']);
      if (curFdRaw != null && curFdRaw.isNotEmpty) {
        final curFdList = decodeFixedDepositList(curFdRaw);
        final occCounts = <String, int>{};
        final patchedFdList = <FixedDepositItem>[];
        for (final item in curFdList) {
          final sig = _fdConfigItemSignature(item);
          final occ = occCounts[sig] ?? 0;
          occCounts[sig] = occ + 1;
          patchedFdList.add(fdSettledOverrides['$sig#$occ'] ?? item);
        }
        row['fixed_deposit_info'] = encodeFixedDepositList(patchedFdList);
      }
    }

    final assetType = _asInt(row['type']);
    final mergedEffects = mergedEffectsByAsset[aid] ?? BigInt.zero;

    if (assetType == AssetType.credit) {
      // REDLINE (ADR-012): `init_money_minor` is fixed credit limit, NEVER
      // initial balance! Never add `init_money_minor` or `initDelta`!
      final BigInt mergedCreditBalance;
      if (bRow != null) {
        final baseBal = _asMinor(bRow['balance_minor']);
        final baseEff = baseEffectsByAsset[aid] ?? BigInt.zero;
        mergedCreditBalance = baseBal + (mergedEffects - baseEff);
      } else if (lRow != null && rRow == null) {
        final initialOffset =
            _asMinor(lRow['balance_minor']) -
            (localEffectsByAsset[aid] ?? BigInt.zero);
        mergedCreditBalance = initialOffset + mergedEffects;
      } else if (rRow != null && lRow == null) {
        final initialOffset =
            _asMinor(rRow['balance_minor']) -
            (remoteEffectsByAsset[aid] ?? BigInt.zero);
        mergedCreditBalance = initialOffset + mergedEffects;
      } else {
        final lOffset =
            _asMinor(lRow!['balance_minor']) -
            (localEffectsByAsset[aid] ?? BigInt.zero);
        final rOffset =
            _asMinor(rRow!['balance_minor']) -
            (remoteEffectsByAsset[aid] ?? BigInt.zero);
        if (lOffset != rOffset) {
          return const SyncThreeWayMergeResult.aborted('新建信用卡期初差额在双端不一致');
        }
        mergedCreditBalance = rOffset + mergedEffects;
      }
      row['balance_minor'] = encodeMinorJson(mergedCreditBalance);

      // Rebuild `credit_info.inst[]` deterministically from merged installments!
      final rawCi = _asNullableString(row['credit_info']);
      final boundInstIds = <int>[
        for (final ie in instProgressById.entries)
          if (ie.value.assetId == aid) ie.key,
      ]..sort();
      if (boundInstIds.isNotEmpty ||
          (rawCi != null && CreditInfo.parse(rawCi).installments != null)) {
        final info = CreditInfo.parse(rawCi);
        if (info.installments != null || boundInstIds.isNotEmpty) {
          info.installments = const <UncreditedInstallment>[];
        }
        var updatedCi = info.encode();
        for (final iid in boundInstIds) {
          final item = instProgressById[iid]!;
          updatedCi = syncCreditInfoInstallment(
            currentCreditInfoJson: updatedCi,
            installmentId: iid,
            remainingPrincipalMinor: item.progress.remainingPrincipalMinor,
            remainingFeeMinor: item.progress.remainingFeeMinor,
            isFinished: item.progress.isFinished || item.extra.settledEarly,
            principalCounted: item.extra.principalCounted,
            interestCounted: item.extra.interestCounted,
          );
        }
        row['credit_info'] = updatedCi;
      }
      continue;
    }

    if (assetType == AssetType.debt) {
      final curr =
          normalizeCurrency(_asNullableString(row['currency'])) ??
          effectiveRates.base;
      final currentLoanInfo = LoanInfo.parse(
        _asNullableString(row['loan_info']),
      );
      final principalRecs = [...?mergedDebtRecordsByAsset[aid]]
        ..sort((a, b) {
          final t = _asInt(
            a['record_time'],
          ).compareTo(_asInt(b['record_time']));
          if (t != 0) return t;
          final c = _asInt(
            a['create_date'],
          ).compareTo(_asInt(b['create_date']));
          if (c != 0) return c;
          return '${a['record_id'] ?? ''}'.compareTo('${b['record_id'] ?? ''}');
        });
      final entries = <DebtRecordEntry>[
        for (final r in principalRecs)
          DebtRecordEntry(
            recordId: '${r['record_id'] ?? ''}',
            type: _asInt(r['type']),
            subType: _asInt(r['sub_type'], RecordDirection.none),
            moneyMinor: _asMinor(r['money_minor']),
            recordTime: _asInt(r['record_time']),
            currency: () {
              final rawExtra = _asNullableString(r['extra_info']);
              return (rawExtra == null || rawExtra.trim().isEmpty)
                  ? null
                  : RecordExtra.parse(rawExtra).currency;
            }(),
          ),
      ];
      final recomputed = recomputeDebtPrincipal(
        debtSubType: _asInt(row['sub_type']),
        currentStatus: _asInt(row['status'], AssetStatus.active),
        currentLoanInfo: currentLoanInfo,
        records: entries,
        debtCurrency: curr,
        rates: effectiveRates,
        allowReopen: false,
        nowMs: nowMs,
      );
      row['balance_minor'] = encodeMinorJson(recomputed.balanceMinor);
      row['status'] = recomputed.status;
      row['loan_info'] = recomputed.loanInfo.encode();
      continue;
    }

    // Ordinary / Savings / Investment account (`type != 4 && type != 6`).
    final mergedInit = _asMinor(row['init_money_minor']);
    final BigInt mergedOrdinaryBalance;
    if (bRow != null) {
      final baseBal = _asMinor(bRow['balance_minor']);
      final baseInit = _asMinor(bRow['init_money_minor']);
      final baseEff = baseEffectsByAsset[aid] ?? BigInt.zero;
      mergedOrdinaryBalance =
          baseBal + (mergedInit - baseInit) + (mergedEffects - baseEff);
    } else if (lRow != null && rRow == null) {
      final sideOffset =
          _asMinor(lRow['balance_minor']) -
          (_asMinor(lRow['init_money_minor']) +
              (localEffectsByAsset[aid] ?? BigInt.zero));
      mergedOrdinaryBalance = mergedInit + mergedEffects + sideOffset;
    } else if (rRow != null && lRow == null) {
      final sideOffset =
          _asMinor(rRow['balance_minor']) -
          (_asMinor(rRow['init_money_minor']) +
              (remoteEffectsByAsset[aid] ?? BigInt.zero));
      mergedOrdinaryBalance = mergedInit + mergedEffects + sideOffset;
    } else {
      mergedOrdinaryBalance = mergedInit + mergedEffects;
    }
    row['balance_minor'] = encodeMinorJson(mergedOrdinaryBalance);
  }

  // D6: Recompute cross-period `forward` auto-copied budgets & R7 total upscale!
  final mergedBudgets = mergedByTable['budget']!;
  if (mergedBudgets.isNotEmpty) {
    _recomputeForwardBudgetsAndR7Upscale(
      mergedBudgets: mergedBudgets,
      mergedBooks: mergedByTable['account_book']!,
      mergedCategories: mergedByTable['record_category']!,
      mergedRecords: mergedRecById,
      targetBookSections: recomputeBudgetBookSections,
    );
  }

  // --------------------------------------------------------------------------
  // Step E: Merge attachments and protect any file still referenced by live rows.
  // --------------------------------------------------------------------------
  final normRemoteAtt = <String, String>{
    for (final e in remoteAttachmentChecksums.entries)
      normalizeAttachmentArchivePath(e.key): e.value.toLowerCase(),
  };
  final referencedArchivePaths = _collectReferencedAttachmentArchivePaths(
    mergedRecById.values,
    mergedPeriods.values,
    mergedInstallments.values,
  );

  final allAttPaths = <String>{
    ...baseLocalDiff.baseAttachmentChecksums.keys,
    ...baseLocalDiff.localAttachmentChecksums.keys,
    ...normRemoteAtt.keys,
  };
  final mergedAttachments = <String, MergedAttachmentEntry>{};
  for (final path in allAttPaths) {
    final bSha = baseLocalDiff.baseAttachmentChecksums[path];
    final lSha = baseLocalDiff.localAttachmentChecksums[path];
    final rSha = normRemoteAtt[path];

    if (bSha == null) {
      if (lSha != null && rSha == null) {
        mergedAttachments[path] = MergedAttachmentEntry(
          archivePath: path,
          sha256: lSha,
          source: MergeAttachmentSource.local,
        );
      } else if (rSha != null && lSha == null) {
        mergedAttachments[path] = MergedAttachmentEntry(
          archivePath: path,
          sha256: rSha,
          source: MergeAttachmentSource.remote,
        );
      } else if (lSha != null && rSha != null) {
        if (lSha != rSha) {
          return SyncThreeWayMergeResult.aborted('同名附件图片内容冲突：$path');
        }
        mergedAttachments[path] = MergedAttachmentEntry(
          archivePath: path,
          sha256: lSha,
          source: MergeAttachmentSource.local,
        );
      }
      continue;
    }

    if (lSha == null && rSha == null) continue;
    if (lSha == null) {
      if (rSha != bSha) {
        return SyncThreeWayMergeResult.aborted('附件在一端被删除、另一端被替换：$path');
      }
      if (referencedArchivePaths.contains(path)) {
        mergedAttachments[path] = MergedAttachmentEntry(
          archivePath: path,
          sha256: rSha!,
          source: MergeAttachmentSource.remote,
        );
      }
      continue;
    }
    if (rSha == null) {
      if (lSha != bSha) {
        return SyncThreeWayMergeResult.aborted('附件在一端被替换、另一端被删除：$path');
      }
      if (referencedArchivePaths.contains(path)) {
        mergedAttachments[path] = MergedAttachmentEntry(
          archivePath: path,
          sha256: lSha,
          source: MergeAttachmentSource.local,
        );
      }
      continue;
    }
    if (lSha != bSha && rSha != bSha && lSha != rSha) {
      return SyncThreeWayMergeResult.aborted('同一附件在双端被修改为不同内容：$path');
    }
    if (lSha != bSha && rSha == bSha) {
      mergedAttachments[path] = MergedAttachmentEntry(
        archivePath: path,
        sha256: lSha,
        source: MergeAttachmentSource.local,
      );
    } else {
      mergedAttachments[path] = MergedAttachmentEntry(
        archivePath: path,
        sha256: rSha,
        source: lSha == rSha
            ? MergeAttachmentSource.local
            : MergeAttachmentSource.remote,
      );
    }
  }

  // --------------------------------------------------------------------------
  // Step F: Canonical table sorting & differential `evaluateDataHealth` gate!
  // --------------------------------------------------------------------------
  final canonicalMergedTables = <String, List<Map<String, Object?>>>{};
  for (final tableName in tallyBusinessTables) {
    final map = mergedByTable[tableName]!;
    final sortedKeys = map.keys.toList()
      ..sort((a, b) => _compareRowKeys(tableName, a, b));
    canonicalMergedTables[tableName] = <Map<String, Object?>>[
      for (final k in sortedKeys) map[k]!,
    ];
  }

  final mergedHealth = _runHealthCheckOnTables(
    canonicalMergedTables,
    effectiveRates,
    nowMs,
  );
  if (!mergedHealth.isHealthy) {
    final localHealth = _runHealthCheckOnTables(
      localTables,
      effectiveRates,
      nowMs,
    );
    final remoteHealth = _runHealthCheckOnTables(
      remoteTables,
      effectiveRates,
      nowMs,
    );
    String issueSig(DataHealthIssue i) =>
        '${i.kind.name}|${i.severity.name}|${i.assetId}|${i.recordId}|${i.tagId}';
    final preExistingSigs = <String>{
      for (final i in localHealth.issues) issueSig(i),
      for (final i in remoteHealth.issues) issueSig(i),
    };
    for (final issue in mergedHealth.issues) {
      if (issue.severity == DataHealthSeverity.info) continue;
      if (issue.severity == DataHealthSeverity.error ||
          !preExistingSigs.contains(issueSig(issue))) {
        return SyncThreeWayMergeResult.aborted('合并后数据体检拦截：${issue.title}');
      }
    }
  }

  // --------------------------------------------------------------------------
  // Step G: Compute `Local -> Merged` row-level deltas (`SyncTableDelta`).
  // --------------------------------------------------------------------------
  final tableDeltas = <String, SyncTableDelta>{};
  for (final tableName in tallyBusinessTables) {
    final origLocalMap = _indexTableRows(tableName, localTables[tableName]);
    final mergedList = canonicalMergedTables[tableName]!;
    final mergedKeys = <Object>{};
    final upserts = <Map<String, Object?>>[];

    for (final mRow in mergedList) {
      final k = extractSyncTableRowKey(tableName, mRow);
      mergedKeys.add(k);
      final lRow = origLocalMap[k];
      if (lRow == null || !_canonicalRowEqual(lRow, mRow)) {
        upserts.add(mRow);
      }
    }
    final deletedKeys = <Object>[
      for (final k in origLocalMap.keys)
        if (!mergedKeys.contains(k)) k,
    ];
    if (upserts.isNotEmpty || deletedKeys.isNotEmpty) {
      tableDeltas[tableName] = SyncTableDelta(
        tableName: tableName,
        upserts: upserts,
        deletedKeys: deletedKeys,
      );
    }
  }

  return SyncThreeWayMergeResult.succeeded(
    mergedTables: canonicalMergedTables,
    mergedAttachments: mergedAttachments,
    tableDeltas: tableDeltas,
  );
}

Map<Object, Map<String, Object?>>? _mergeRemarkRows({
  required BaseLocalTableDiff baseDiff,
  required List<Map<String, Object?>> origLocalRows,
  required List<Map<String, Object?>> remoteRows,
}) {
  final origLocalByKey = _indexTableRows('remark', origLocalRows);
  final remoteByKey = _indexTableRows('remark', remoteRows);
  var maxId = 0;
  for (final k in origLocalByKey.keys) {
    if ((k as int) > maxId) maxId = k;
  }
  for (final k in remoteByKey.keys) {
    if ((k as int) > maxId) maxId = k;
  }

  final merged = <Object, Map<String, Object?>>{};
  final remoteAddedByContent = <String, Map<String, Object?>>{};

  for (final e in remoteByKey.entries) {
    if (baseDiff.containsBaseKey(e.key)) continue;
    final copy = Map<String, Object?>.of(e.value);
    merged[e.key] = copy;
    final sig = '${_asInt(copy['record_cat_id'])}|${copy['content'] ?? ''}';
    remoteAddedByContent[sig] = copy;
  }

  final baseKeys = <Object>{
    ...baseDiff.unchangedBaseKeys,
    ...baseDiff.modifiedBaseRows.keys,
    ...baseDiff.deletedBaseRows.keys,
  };
  for (final key in baseKeys) {
    final bRow = baseDiff.lookupBaseRow(key, origLocalByKey)!;
    final lRow = origLocalByKey[key];
    final rRow = remoteByKey[key];
    if (lRow == null && rRow == null) continue;
    if (lRow == null) {
      if (_canonicalRowEqual(bRow, rRow!)) continue;
      return null;
    }
    if (rRow == null) {
      if (_canonicalRowEqual(bRow, lRow)) continue;
      return null;
    }
    final bCore = '${_asInt(bRow['record_cat_id'])}|${bRow['content'] ?? ''}';
    final lCore = '${_asInt(lRow['record_cat_id'])}|${lRow['content'] ?? ''}';
    final rCore = '${_asInt(rRow['record_cat_id'])}|${rRow['content'] ?? ''}';
    if (lCore != bCore && rCore != bCore && lCore != rCore) {
      return null;
    }
    final chosen = lCore != bCore ? lRow : rRow;
    final bUsed = _asInt(bRow['used_times'], 1);
    final lUsed = _asInt(lRow['used_times'], 1);
    final rUsed = _asInt(rRow['used_times'], 1);
    final nextUsed = bUsed + (lUsed - bUsed) + (rUsed - bUsed);
    merged[key] = Map<String, Object?>.of(chosen)
      ..['used_times'] = nextUsed < 0 ? 0 : nextUsed;
  }

  for (final e in origLocalByKey.entries) {
    if (baseDiff.containsBaseKey(e.key)) continue;
    final lRow = e.value;
    final sig = '${_asInt(lRow['record_cat_id'])}|${lRow['content'] ?? ''}';
    final dupRemote = remoteAddedByContent[sig];
    if (dupRemote != null) {
      dupRemote['used_times'] =
          _asInt(dupRemote['used_times'], 1) + _asInt(lRow['used_times'], 1);
      continue;
    }
    if (merged.containsKey(e.key)) {
      final newId = ++maxId;
      merged[newId] = Map<String, Object?>.of(lRow)..['id'] = newId;
    } else {
      merged[e.key] = Map<String, Object?>.of(lRow);
    }
  }
  return merged;
}

Map<String, Object?> _mergeCompatibleMasterRow({
  required String tableName,
  required Map<String, Object?>? baseRow,
  required Map<String, Object?> localRow,
  required Map<String, Object?> remoteRow,
  Map<String, Object?>? preferredConfigSource,
}) {
  if (tableName == 'currency') {
    final lTime = _asInt(localRow['rate_refresh_time']);
    final rTime = _asInt(remoteRow['rate_refresh_time']);
    final base = Map<String, Object?>.of(preferredConfigSource ?? remoteRow);
    if (lTime > rTime) {
      base['rate_to_anchor'] = localRow['rate_to_anchor'];
      base['rate_refresh_time'] = localRow['rate_refresh_time'];
    } else {
      base['rate_to_anchor'] = remoteRow['rate_to_anchor'];
      base['rate_refresh_time'] = remoteRow['rate_refresh_time'];
    }
    return base;
  }
  final out = Map<String, Object?>.of(preferredConfigSource ?? remoteRow);
  if (tableName == 'asset' && baseRow != null) {
    final bDef = _asBool(baseRow['is_default']);
    final lDef = _asBool(localRow['is_default']);
    final rDef = _asBool(remoteRow['is_default']);
    if (lDef != bDef && rDef == bDef) {
      out['is_default'] = lDef;
    } else if (rDef != bDef) {
      out['is_default'] = rDef;
    }
  }
  return out;
}

void _recomputeForwardBudgetsAndR7Upscale({
  required Map<Object, Map<String, Object?>> mergedBudgets,
  required Map<Object, Map<String, Object?>> mergedBooks,
  required Map<Object, Map<String, Object?>> mergedCategories,
  required Map<Object, Map<String, Object?>> mergedRecords,
  required Set<(int, String)> targetBookSections,
}) {
  // Also include any `(book_id, section)` that has budgets in `mergedBudgets`
  // so R7 total budget upscale always holds after category budget merges.
  final allBookSections = <(int, String)>{...targetBookSections};
  final budgetsByBookSection = <(int, String), List<Map<String, Object?>>>{};
  final budgetsByCanonicalBookSection =
      <(int, String), List<Map<String, Object?>>>{};
  for (final b in mergedBudgets.values) {
    final bookId = _asInt(b['book_id'], 1);
    final rawSec = '${b['section'] ?? ''}';
    final pair = (bookId, rawSec);
    allBookSections.add(pair);
    (budgetsByBookSection[pair] ??= <Map<String, Object?>>[]).add(b);
    (budgetsByCanonicalBookSection[(
              bookId,
              _canonicalBudgetSection(rawSec),
            )] ??=
            <Map<String, Object?>>[])
        .add(b);
  }

  final catNodesByBook = <int, Map<int, BudgetCategoryNode>>{};
  for (final c in mergedCategories.values) {
    final bid = _asInt(c['account_book_id'], 1);
    final cid = _asInt(c['id']);
    (catNodesByBook[bid] ??=
        <int, BudgetCategoryNode>{})[cid] = BudgetCategoryNode(
      id: cid,
      name: '${c['name'] ?? ''}',
      icon: '${c['icon'] ?? ''}',
      type: _asInt(c['type']),
      parentCatId: _asInt(c['parent_cat_id'], noRef),
    );
  }

  for (final (bookId, section) in allBookSections) {
    final curList = budgetsByBookSection[(bookId, section)];
    if (curList == null || curList.isEmpty) continue;

    // Recompute `forward == true` carryover when `(bookId, section)` had an
    // auto-copied budget added during merge.
    if (targetBookSections.contains((bookId, section))) {
      final bookRow = mergedBooks[bookId];
      final startDay = _asInt(bookRow?['start_day'], 1);
      final prevInfo = _resolvePreviousBudgetPeriod(section, startDay);
      if (prevInfo != null) {
        final prevBudgets =
            budgetsByBookSection[(bookId, prevInfo.section)] ??
            budgetsByCanonicalBookSection[(
              bookId,
              _canonicalBudgetSection(prevInfo.section),
            )];
        if (prevBudgets != null && prevBudgets.isNotEmpty) {
          final prevBySlot = <String, Map<String, Object?>>{
            for (final pb in prevBudgets)
              '${_asInt(pb['budget_type'])}|${_asInt(pb['record_cat_id'], noRef)}':
                  pb,
          };
          final prevRecInputs = <BudgetRecordInput>[];
          for (final r in mergedRecords.values) {
            if (_asInt(r['account_book_id'], 1) != bookId) continue;
            final rt = _asInt(r['record_time']);
            if (rt < prevInfo.period.startMs || rt > prevInfo.period.endMs) {
              continue;
            }
            CurrencySnapshot? curr;
            final rawExtra = _asNullableString(r['extra_info']);
            if (rawExtra != null && rawExtra.trim().isNotEmpty) {
              curr = RecordExtra.parse(rawExtra).currency;
            }
            RecordRelations? rel;
            final rawRel = _asNullableString(r['rel_info']);
            if (rawRel != null && rawRel.trim().isNotEmpty) {
              rel = RecordRelations.parse(rawRel);
            }
            prevRecInputs.add(
              BudgetRecordInput(
                recordId: '${r['record_id'] ?? ''}',
                recordCatId: _asInt(r['record_cat_id'], noRef),
                entry: StatEntry(
                  type: _asInt(r['type']),
                  subType: _asInt(r['sub_type'], RecordDirection.none),
                  moneyMinor: _asMinor(r['money_minor']),
                  discountMinor: _asNullableMinor(r['discount_minor']),
                  currency: curr,
                  relations: rel,
                  excludeExIn: _asBool(r['exclude_ex_in']),
                  excludeBudget: _asBool(r['exclude_budget']),
                ),
              ),
            );
          }

          final bookCats =
              catNodesByBook[bookId] ?? const <int, BudgetCategoryNode>{};
          for (final cb in curList) {
            final extra = BudgetExtra.fromJson(
              _asNullableString(cb['extra_info']),
              fallbackAmountMinor: _asMinor(cb['amount_minor']),
            );
            if (!extra.autoCopy || !extra.forward) continue;
            final bType = _asInt(cb['budget_type']);
            final catId = _asInt(cb['record_cat_id'], noRef);
            final prevRow = prevBySlot['$bType|$catId'];
            if (prevRow == null) continue;
            final prevAmount = _asMinor(prevRow['amount_minor']);
            BigInt? rawPrevUsed;
            if (bType == BudgetTypeCode.total) {
              rawPrevUsed = computeTotalBudgetUsage(
                amountMinor: prevAmount,
                records: prevRecInputs,
              ).rawUsedMinor;
            } else {
              final node = bookCats[catId];
              if (node != null) {
                rawPrevUsed = computeCategoryBudgetUsage(
                  category: node,
                  allCategories: bookCats.values,
                  amountMinor: prevAmount,
                  budgetType: bType,
                  records: prevRecInputs,
                ).rawUsedMinor;
              }
            }
            if (rawPrevUsed != null) {
              final nextMinor = computeNextPeriodCarryover(
                baseAmountMinor: extra.baseMinor,
                prevAmountMinor: prevAmount,
                rawPrevUsedMinor: rawPrevUsed,
                forward: true,
              );
              cb['amount_minor'] = encodeMinorJson(nextMinor);
            }
          }
        }
      }
    }

    // Enforce R7: total budget >= sum of expense category budgets.
    Map<String, Object?>? totalRow;
    final expCatMinors = <BigInt>[];
    for (final cb in curList) {
      final bType = _asInt(cb['budget_type']);
      if (bType == BudgetTypeCode.total) {
        totalRow = cb;
      } else if (bType == BudgetTypeCode.expenseCategory) {
        expCatMinors.add(_asMinor(cb['amount_minor']));
      }
    }
    if (totalRow != null && expCatMinors.isNotEmpty) {
      final curTotal = _asMinor(totalRow['amount_minor']);
      final upscaled = upscaledTotalBudget(
        expenseCategoryBudgets: expCatMinors,
        currentTotalMinor: curTotal,
      );
      if (upscaled != null && upscaled != curTotal) {
        totalRow['amount_minor'] = encodeMinorJson(upscaled);
        final curExtra = BudgetExtra.fromJson(
          _asNullableString(totalRow['extra_info']),
          fallbackAmountMinor: curTotal,
        );
        totalRow['extra_info'] = BudgetExtra(
          autoCopy: curExtra.autoCopy,
          forward: curExtra.forward,
          baseMinor: upscaled,
        ).toJsonString();
      }
    }
  }
}

String _canonicalBudgetSection(String rawSection) {
  final trimmed = rawSection.trim();
  final m = RegExp(r'^(\d{4})-(\d{1,2})$').firstMatch(trimmed);
  if (m != null) {
    return '${int.parse(m.group(1)!)}-${int.parse(m.group(2)!)}';
  }
  return trimmed;
}

({BillingPeriod period, String section})? _resolvePreviousBudgetPeriod(
  String currentSection,
  int startDay,
) {
  final trimmed = currentSection.trim();
  final monthlyMatch = RegExp(r'^(\d{4})-(\d{1,2})$').firstMatch(trimmed);
  if (monthlyMatch != null) {
    var year = int.parse(monthlyMatch.group(1)!);
    var month = int.parse(monthlyMatch.group(2)!);
    month -= 1;
    if (month <= 0) {
      month = 12;
      year -= 1;
    }
    final p = BillingPeriod.starting(year, month, startDay);
    return (period: p, section: p.monthlySection);
  }
  final yearlyMatch = RegExp(r'^(\d{4})$').firstMatch(trimmed);
  if (yearlyMatch != null) {
    final prevYear = int.parse(yearlyMatch.group(1)!) - 1;
    final p = BillingPeriod.year(prevYear, startDay);
    return (period: p, section: p.yearlySection);
  }
  return null;
}

Set<String> _collectReferencedAttachmentArchivePaths(
  Iterable<Map<String, Object?>> records,
  Iterable<Map<String, Object?>> periods,
  Iterable<Map<String, Object?>> installments,
) {
  final refs = <String>{};
  void scanRawImages(Object? raw) {
    if (raw is! String || raw.trim().isEmpty) return;
    final trimmed = raw.trim();
    if (trimmed.startsWith('[')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is String && item.trim().isNotEmpty) {
              try {
                refs.add(normalizeAttachmentArchivePath(item.trim()));
              } catch (_) {}
            }
          }
          return;
        }
      } catch (_) {}
    }
    for (final part in trimmed.split(',')) {
      final p = part.trim();
      if (p.isNotEmpty) {
        try {
          refs.add(normalizeAttachmentArchivePath(p));
        } catch (_) {}
      }
    }
  }

  for (final r in records) {
    scanRawImages(r['images']);
  }
  for (final p in periods) {
    scanRawImages(p['images']);
  }
  for (final i in installments) {
    scanRawImages(i['images']);
  }
  return refs;
}

DataHealthReport _runHealthCheckOnTables(
  Map<String, List<Map<String, Object?>>> tables,
  RateTable rates,
  int nowMs,
) {
  final assets = <HealthAssetRow>[
    for (final a in tables['asset'] ?? const <Map<String, Object?>>[])
      HealthAssetRow(
        id: _asInt(a['id']),
        name: '${a['name'] ?? ''}',
        type: _asInt(a['type']),
        subType: _asInt(a['sub_type'], RecordDirection.none),
        status: _asInt(a['status'], AssetStatus.active),
        balanceMinor: _asMinor(a['balance_minor']),
        initMoneyMinor: _asMinor(a['init_money_minor']),
        currency: _asNullableString(a['currency']),
        extraInfo: _asNullableString(a['extra_info']),
        loanInfo: _asNullableString(a['loan_info']),
        creditInfo: _asNullableString(a['credit_info']),
        fixedDepositInfo: _asNullableString(a['fixed_deposit_info']),
      ),
  ];
  final records = <HealthRecordRow>[
    for (final r in tables['record'] ?? const <Map<String, Object?>>[])
      HealthRecordRow(
        recordId: '${r['record_id'] ?? ''}',
        type: _asInt(r['type']),
        subType: _asInt(r['sub_type'], RecordDirection.none),
        moneyMinor: _asMinor(r['money_minor']),
        recordTime: _asInt(r['record_time']),
        createDate: r['create_date'] == null ? null : _asInt(r['create_date']),
        recordCatId: _asInt(r['record_cat_id'], noRef),
        assetId: _asInt(r['asset_id'], noRef),
        fromAssetId: _asInt(r['from_asset_id'], noRef),
        toAssetId: _asInt(r['to_asset_id'], noRef),
        accountBookId: _asInt(r['account_book_id'], 1),
        relInfo: _asNullableString(r['rel_info']),
        extraInfo: _asNullableString(r['extra_info']),
      ),
  ];
  final books = <HealthBookRow>[
    for (final b in tables['account_book'] ?? const <Map<String, Object?>>[])
      HealthBookRow(
        id: _asInt(b['id']),
        name: '${b['name'] ?? ''}',
        extraInfo: _asNullableString(b['extra_info']),
      ),
  ];
  final categories = <HealthCategoryRow>[
    for (final c in tables['record_category'] ?? const <Map<String, Object?>>[])
      HealthCategoryRow(
        id: _asInt(c['id']),
        name: '${c['name'] ?? ''}',
        accountBookId: _asInt(c['account_book_id'], 1),
        parentCatId: _asInt(c['parent_cat_id'], noRef),
        extraInfo: _asNullableString(c['extra_info']),
      ),
  ];
  final tags = <HealthTagRow>[
    for (final t in tables['tag'] ?? const <Map<String, Object?>>[])
      HealthTagRow(
        tagId: '${t['tag_id'] ?? ''}',
        name: '${t['name'] ?? ''}',
        extraInfo: _asNullableString(t['extra_info']),
      ),
  ];
  final tagRecords = <HealthTagRecordRow>[
    for (final tr in tables['tag_record'] ?? const <Map<String, Object?>>[])
      HealthTagRecordRow(
        tagId: '${tr['tag_id'] ?? ''}',
        recordId: '${tr['record_id'] ?? ''}',
      ),
  ];
  final auxRows = <HealthAuxJsonRow>[
    for (final b in tables['budget'] ?? const <Map<String, Object?>>[])
      HealthAuxJsonRow(
        table: 'budget',
        rowKey: '${b['id']}',
        column: 'extra_info',
        rawJson: _asNullableString(b['extra_info']),
      ),
    for (final p in tables['money_save_plan'] ?? const <Map<String, Object?>>[])
      HealthAuxJsonRow(
        table: 'money_save_plan',
        rowKey: '${p['id']}',
        column: 'extra_info',
        rawJson: _asNullableString(p['extra_info']),
      ),
  ];
  return evaluateDataHealth(
    assets: assets,
    records: records,
    books: books,
    categories: categories,
    tags: tags,
    tagRecords: tagRecords,
    auxJsonRows: auxRows,
    rates: rates,
    nowMs: nowMs,
  );
}

/// Computes a human-readable [SyncConflictComparison] between [localTables]
/// and [remoteTables] (or falls back to [remoteHead] metadata when the remote
/// snapshot is temporarily unreachable offline).
SyncConflictComparison computeSyncConflictComparison({
  required String localDeviceName,
  required Map<String, List<Map<String, Object?>>> localTables,
  Map<String, List<Map<String, Object?>>>? remoteTables,
  CloudSyncHead? remoteHead,
  int maxSamples = 5,
}) {
  final localRecords = localTables['record'] ?? const <Map<String, Object?>>[];
  final localAssets = localTables['asset'] ?? const <Map<String, Object?>>[];
  final localNotes = localTables['note'] ?? const <Map<String, Object?>>[];

  final remoteName = remoteHead?.deviceName.trim().isNotEmpty == true
      ? remoteHead!.deviceName.trim()
      : '云端设备';
  final remoteRev = remoteHead?.revision ?? 0;

  SyncConflictSampleBill toSample(Map<String, Object?> r) {
    var currCode = 'CNY';
    final rawExtra = _asNullableString(r['extra_info']);
    if (rawExtra != null && rawExtra.trim().isNotEmpty) {
      try {
        currCode = RecordExtra.parse(rawExtra).currency?.sourceCode ?? 'CNY';
      } catch (_) {}
    }
    return SyncConflictSampleBill(
      recordId: '${r['record_id'] ?? ''}',
      recordTime: _asInt(r['record_time']),
      type: _asInt(r['type']),
      moneyMinor: _asMinor(r['money_minor']),
      currencyCode: currCode,
      remark: '${r['remark'] ?? ''}',
    );
  }

  if (remoteTables == null) {
    final sortedLocal = [...localRecords]
      ..sort(
        (a, b) => _asInt(b['record_time']).compareTo(_asInt(a['record_time'])),
      );
    return SyncConflictComparison(
      localDeviceName: localDeviceName,
      remoteDeviceName: remoteName,
      remoteRevision: remoteRev,
      remoteUpdatedAtMs: remoteHead?.updatedAtMs,
      localRecordCount: localRecords.length,
      remoteRecordCount: remoteHead?.recordCount ?? 0,
      localAssetCount: localAssets.length,
      remoteAssetCount: 0,
      localNoteCount: localNotes.length,
      remoteNoteCount: 0,
      localOnlyRecordCount: 0,
      remoteOnlyRecordCount: 0,
      modifiedRecordCount: 0,
      localSampleBills: sortedLocal.take(maxSamples).map(toSample).toList(),
      remoteSampleBills: const <SyncConflictSampleBill>[],
    );
  }

  final remoteRecords =
      remoteTables['record'] ?? const <Map<String, Object?>>[];
  final remoteAssets = remoteTables['asset'] ?? const <Map<String, Object?>>[];
  final remoteNotes = remoteTables['note'] ?? const <Map<String, Object?>>[];

  final localById = _indexTableRows('record', localRecords);
  final remoteById = _indexTableRows('record', remoteRecords);

  final localDiffRows = <Map<String, Object?>>[];
  final remoteDiffRows = <Map<String, Object?>>[];
  var localOnlyCount = 0;
  var remoteOnlyCount = 0;
  var modifiedCount = 0;

  for (final e in localById.entries) {
    final rRow = remoteById[e.key];
    if (rRow == null) {
      localOnlyCount++;
      localDiffRows.add(e.value);
    } else if (!_canonicalRowEqual(e.value, rRow)) {
      modifiedCount++;
      localDiffRows.add(e.value);
      remoteDiffRows.add(rRow);
    }
  }
  for (final e in remoteById.entries) {
    if (!localById.containsKey(e.key)) {
      remoteOnlyCount++;
      remoteDiffRows.add(e.value);
    }
  }

  localDiffRows.sort(
    (a, b) => _asInt(b['record_time']).compareTo(_asInt(a['record_time'])),
  );
  remoteDiffRows.sort(
    (a, b) => _asInt(b['record_time']).compareTo(_asInt(a['record_time'])),
  );

  return SyncConflictComparison(
    localDeviceName: localDeviceName,
    remoteDeviceName: remoteName,
    remoteRevision: remoteRev,
    remoteUpdatedAtMs: remoteHead?.updatedAtMs,
    localRecordCount: localRecords.length,
    remoteRecordCount: remoteRecords.length,
    localAssetCount: localAssets.length,
    remoteAssetCount: remoteAssets.length,
    localNoteCount: localNotes.length,
    remoteNoteCount: remoteNotes.length,
    localOnlyRecordCount: localOnlyCount,
    remoteOnlyRecordCount: remoteOnlyCount,
    modifiedRecordCount: modifiedCount,
    localSampleBills: localDiffRows.take(maxSamples).map(toSample).toList(),
    remoteSampleBills: remoteDiffRows.take(maxSamples).map(toSample).toList(),
  );
}
