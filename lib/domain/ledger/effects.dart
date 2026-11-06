import '../../core/failure.dart';
import '../model/codes.dart';
import 'record_extra.dart';

/// The subset of a record that determines its effect on account balances.
final class EntryFacts {
  const EntryFacts({
    required this.type,
    this.subType = RecordDirection.none,
    required this.moneyMinor,
    this.assetId = noRef,
    this.fromAssetId = noRef,
    this.toAssetId = noRef,
    this.currency,
  });

  final int type;
  final int subType;

  /// `record.money`: net amount (after discount) in the asset currency for
  /// income/expense; source-currency amount for transfers.
  final BigInt moneyMinor;
  final int assetId;
  final int fromAssetId;
  final int toAssetId;
  final CurrencySnapshot? currency;

  /// Amount in the asset/target currency: `curr.am ?? money` (ledger-catalog §1).
  BigInt get assetAmount =>
      (currency != null && currency!.isValid ? currency!.assetNet : null) ??
      moneyMinor;
}

final class AssetDelta {
  const AssetDelta(this.assetId, this.minor);
  final int assetId;
  final BigInt minor;

  @override
  bool operator ==(Object other) =>
      other is AssetDelta && other.assetId == assetId && other.minor == minor;
  @override
  int get hashCode => Object.hash(assetId, minor);
  @override
  String toString() => 'AssetDelta($assetId, $minor)';
}

/// Balance effect of one stored record on ordinary account balances.
///
/// Debt account (asset.type=4) balances are recomputed by the debt module from
/// principal history and are not covered by these deltas; only the funding
/// accounts of debt records are affected here.
///
/// Rules: docs/reference/ledger-catalog.md §1. Deliberate decisions where the
/// original is unconfirmed are marked "decision".
List<AssetDelta> balanceEffects(EntryFacts r) {
  final deltas = <AssetDelta>[];
  void add(int assetId, BigInt minor) {
    if (assetId == noRef || assetId < 0 || minor == BigInt.zero) return;
    deltas.add(AssetDelta(assetId, minor));
  }

  final amount = r.assetAmount;
  switch (r.type) {
    case RecordType.expense:
    case RecordType.installmentPrincipal:
    case RecordType.fee:
      // Negative amounts (refund child / discount fee) add back.
      add(r.assetId, -amount);
    case RecordType.income:
    case RecordType.reimburseReceipt:
    case RecordType.depositInterest:
      add(r.assetId, amount);
    case RecordType.transfer:
      if (r.fromAssetId == r.toAssetId && r.fromAssetId != noRef) {
        throw const Failure(FailureCode.validation, '转出和转入账户不能相同');
      }
      add(r.fromAssetId, -r.moneyMinor);
      add(r.toAssetId, amount);
    case RecordType.reimbursable:
      // decision: the paying account is from_asset_id (original column unconfirmed).
      add(r.fromAssetId, -r.moneyMinor);
    case RecordType.balanceAdjust:
      add(r.fromAssetId, r.moneyMinor);
    case RecordType.borrowIn:
    case RecordType.collect:
      add(r.toAssetId, r.moneyMinor); // funding account receives
    case RecordType.lendOut:
    case RecordType.repay:
      add(r.fromAssetId, -r.moneyMinor); // funding account pays
    case RecordType.debtInterest:
      if (r.subType == RecordDirection.expense) {
        add(r.fromAssetId, -r.moneyMinor);
      } else if (r.subType == RecordDirection.income) {
        add(r.toAssetId, r.moneyMinor);
      }
    case RecordType.reimburseDiff:
      if (r.subType == RecordDirection.expense) {
        add(r.assetId, -amount);
      } else if (r.subType == RecordDirection.income) {
        add(r.assetId, amount);
      }
    case RecordType.advanceIncome:
    case RecordType.advanceExpense:
      // decision: advance bills are pending memos; settlement creates the
      // real income/expense record that moves money.
      break;
    case RecordType.billInstallment:
      // decision pending (meaning unconfirmed); handled by the credit module.
      break;
    default:
      throw Failure(FailureCode.unsupportedCapability, '未知的账单类型 ${r.type}');
  }
  return deltas;
}

/// Net per-account change of replacing [before] with [after] (either may be null).
Map<int, BigInt> netEffects({
  Iterable<EntryFacts> before = const [],
  Iterable<EntryFacts> after = const [],
}) {
  final net = <int, BigInt>{};
  for (final r in before) {
    for (final d in balanceEffects(r)) {
      net[d.assetId] = (net[d.assetId] ?? BigInt.zero) - d.minor;
    }
  }
  for (final r in after) {
    for (final d in balanceEffects(r)) {
      net[d.assetId] = (net[d.assetId] ?? BigInt.zero) + d.minor;
    }
  }
  net.removeWhere((_, v) => v == BigInt.zero);
  return net;
}
