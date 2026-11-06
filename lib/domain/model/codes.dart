/// Original `record.type` codes (docs/reference/ledger-catalog.md §1).
/// Codes are kept identical to the original app so backups map 1:1.
abstract final class RecordType {
  static const expense = 0;
  static const income = 1;
  static const transfer = 2;
  static const reimbursable = 3; // 报销支出（待报销/垫付）
  static const balanceAdjust = 4; // 余额变更 / 平账
  static const borrowIn = 5; // 借入
  static const lendOut = 6; // 借出
  static const repay = 7; // 还款（借入方向）
  static const collect = 8; // 收款（借出方向）
  static const advanceIncome = 9; // 预收
  static const debtInterest = 10; // 借贷利息 sub 0 支出 / 1 收入
  static const reimburseDiff = 11; // 报销差额 sub 0 支出 / 1 收入
  static const fee = 12; // 手续费（转账子单或独立）
  static const billInstallment = 13; // 账单分期（含义未完全确认）
  static const installmentPrincipal = 14; // 分期每期本金（无分类）
  static const reimburseReceipt = 15; // 报销收款
  static const advanceExpense = 16; // 预支
  static const depositInterest = 17; // 定存到期收益

  static const names = <int, String>{
    expense: '支出',
    income: '收入',
    transfer: '转账',
    reimbursable: '报销',
    balanceAdjust: '余额变更',
    borrowIn: '借入',
    lendOut: '借出',
    repay: '还款',
    collect: '收款',
    advanceIncome: '预收',
    debtInterest: '借贷利息',
    reimburseDiff: '报销差额',
    fee: '手续费',
    billInstallment: '账单分期',
    installmentPrincipal: '分期本金',
    reimburseReceipt: '报销收款',
    advanceExpense: '预支',
    depositInterest: '定存收益',
  };
}

/// `sub_type` direction values used by the generic statistics chain.
abstract final class RecordDirection {
  static const none = -1;
  static const expense = 0;
  static const income = 1;
}

/// Original `asset.type` codes that are confirmed (ledger-catalog §3).
abstract final class AssetType {
  static const normal = 0;
  static const debt = 4; // sub 99 借出(债权) / 100 借入(债务)
  static const credit = 6;

  static const debtLend = 99;
  static const debtBorrow = 100;
}

/// `asset.status`.
abstract final class AssetStatus {
  static const active = 0;
  static const hidden = 1;
  static const settled = 2;
}

/// "No reference" sentinel used by original integer reference columns.
const noRef = -1;
