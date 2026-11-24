import 'dart:convert';

import '../../core/failure.dart';
import '../../core/money.dart';
import '../ledger/asset_json.dart';
import '../ledger/record_extra.dart';
import '../ledger/record_relations.dart';
import '../model/codes.dart';
import 'asset_overview.dart';
import 'billing_period.dart';
import 'budget_rules.dart';
import 'currency_rates.dart';
import 'debt_rules.dart';
import 'installment_rules.dart';
import 'ios_migration_rules.dart';
import 'periodic_records.dart';
import 'savings_plan.dart';
import 'template_card_rules.dart';

/// Metadata attached to a [MigrationPayload] converted from a Haohaojizhang
/// (`好好记账` v1.22.5) `account_record*.db` SQLite database.
final class HaohaoDbPayloadMeta {
  const HaohaoDbPayloadMeta({
    this.upsertCurrencies = const <MigrationCurrencyRow>[],
    this.preferredBookId,
    this.preferredAssetId,
  });

  /// Foreign currencies collected from `user_currencies`, accounts, and bills,
  /// to be upserted into `currency` without overwriting existing local rates.
  final List<MigrationCurrencyRow> upsertCurrencies;

  /// Active book ID from Haohaojizhang `user.account_book_id` if valid.
  final int? preferredBookId;

  /// Default account ID from Haohaojizhang `user.assets_account_id` if valid.
  final int? preferredAssetId;
}

final Expando<HaohaoDbPayloadMeta> _haohaoPayloadMetaExpando =
    Expando<HaohaoDbPayloadMeta>('haohaoDbPayloadMeta');

/// Retrieves [HaohaoDbPayloadMeta] if [payload] originated from a Haohao `.db`.
HaohaoDbPayloadMeta? haohaoPayloadMetaOf(MigrationPayload payload) =>
    _haohaoPayloadMetaExpando[payload];

/// Attaches [meta] to [payload].
void attachHaohaoPayloadMeta(
  MigrationPayload payload,
  HaohaoDbPayloadMeta meta,
) {
  _haohaoPayloadMetaExpando[payload] = meta;
}

/// Returns `true` when [tableNames] matches Haohaojizhang's Room schema
/// (`assets_account` + `bill_info` or `bill_info_new`).
bool isHaohaoDatabaseTables(Iterable<String> tableNames) {
  final lower = <String>{for (final t in tableNames) t.trim().toLowerCase()};
  return lower.contains('assets_account') &&
      (lower.contains('bill_info') || lower.contains('bill_info_new'));
}

/// Converts a SQLite `REAL` / `INTEGER` / `TEXT` major-unit value into exact
/// `int64` minor units (`HALF_UP` at scale 2) with ZERO `double` arithmetic.
BigInt parseHaohaoRealMinor(Object? raw, {String fieldName = '金额'}) {
  if (raw == null) return BigInt.zero;
  if (raw is BigInt) {
    return Money.minor(raw * BigInt.from(100)).storageMinor;
  }
  if (raw is int) {
    return Money.minor(BigInt.from(raw) * BigInt.from(100)).storageMinor;
  }
  if (raw is num) {
    if (!raw.isFinite) {
      throw Failure(FailureCode.corruptData, '$fieldName数值非法');
    }
    final dec = DecimalValue.parse(raw.toStringAsFixed(6));
    final minor = dec.unitsAt(Money.ledgerScale, rounding: RoundingMode.halfUp);
    return Money.minor(minor).storageMinor;
  }
  if (raw is String) {
    final cleaned = raw.trim().replaceAll(',', '');
    if (cleaned.isEmpty) return BigInt.zero;
    final dec = parseExactDecimal(cleaned, fieldName: fieldName);
    final minor = dec.unitsAt(Money.ledgerScale, rounding: RoundingMode.halfUp);
    return Money.minor(minor).storageMinor;
  }
  throw Failure(FailureCode.corruptData, '$fieldName格式无效');
}

/// Parses a SQLite numeric/text column into an exact [DecimalValue] without
/// floating-point math, returning `null` when blank or non-positive/invalid.
DecimalValue? parseHaohaoDecimal(Object? raw) {
  if (raw == null) return null;
  if (raw is DecimalValue) return raw;
  if (raw is BigInt) return DecimalValue(raw, 0);
  if (raw is int) return DecimalValue(BigInt.from(raw), 0);
  if (raw is num) {
    if (!raw.isFinite) return null;
    return DecimalValue.parse(raw.toStringAsFixed(8));
  }
  if (raw is String) {
    final cleaned = raw.trim().replaceAll(',', '');
    if (cleaned.isEmpty) return null;
    try {
      return parseExactDecimal(cleaned);
    } on Failure {
      return null;
    }
  }
  return null;
}

/// Plain-Dart table snapshot extracted read-only from Haohaojizhang SQLite.
final class HaohaoDbSnapshot {
  const HaohaoDbSnapshot({
    this.users = const <Map<String, Object?>>[],
    this.userCurrencies = const <Map<String, Object?>>[],
    this.accountBooks = const <Map<String, Object?>>[],
    this.assetsAccounts = const <Map<String, Object?>>[],
    this.billInitialBalances = const <Map<String, Object?>>[],
    this.debts = const <Map<String, Object?>>[],
    this.billCategories = const <Map<String, Object?>>[],
    this.tags = const <Map<String, Object?>>[],
    this.billTags = const <Map<String, Object?>>[],
    this.budgets = const <Map<String, Object?>>[],
    this.billCategoryBudgets = const <Map<String, Object?>>[],
    this.recycleInfos = const <Map<String, Object?>>[],
    this.recycleTags = const <Map<String, Object?>>[],
    this.installmentBills = const <Map<String, Object?>>[],
    this.savingPlans = const <Map<String, Object?>>[],
    this.savingPlanItems = const <Map<String, Object?>>[],
    this.billTemplates = const <Map<String, Object?>>[],
    this.billTemplateTags = const <Map<String, Object?>>[],
    this.billInfos = const <Map<String, Object?>>[],
  });

  final List<Map<String, Object?>> users;
  final List<Map<String, Object?>> userCurrencies;
  final List<Map<String, Object?>> accountBooks;
  final List<Map<String, Object?>> assetsAccounts;
  final List<Map<String, Object?>> billInitialBalances;
  final List<Map<String, Object?>> debts;
  final List<Map<String, Object?>> billCategories;
  final List<Map<String, Object?>> tags;
  final List<Map<String, Object?>> billTags;
  final List<Map<String, Object?>> budgets;
  final List<Map<String, Object?>> billCategoryBudgets;
  final List<Map<String, Object?>> recycleInfos;
  final List<Map<String, Object?>> recycleTags;
  final List<Map<String, Object?>> installmentBills;
  final List<Map<String, Object?>> savingPlans;
  final List<Map<String, Object?>> savingPlanItems;
  final List<Map<String, Object?>> billTemplates;
  final List<Map<String, Object?>> billTemplateTags;
  final List<Map<String, Object?>> billInfos;
}

const Map<String, String> _currencyAliases = <String, String>{
  'RMB': 'CNY',
  'CNH': 'CNY',
  '￥': 'CNY',
  '¥': 'CNY',
  '人民币': 'CNY',
  r'$': 'USD',
  'US\$': 'USD',
  '美元': 'USD',
  '€': 'EUR',
  '欧元': 'EUR',
  '£': 'GBP',
  '英镑': 'GBP',
  'HK\$': 'HKD',
  '港币': 'HKD',
  'JP¥': 'JPY',
  '日元': 'JPY',
  'NTD': 'TWD',
  'NT\$': 'TWD',
  '新台币': 'TWD',
  'MOP\$': 'MOP',
  'KR₩': 'KRW',
  '韩元': 'KRW',
  'THP': 'THB',
};

const Map<String, String> _builtinDefaultPriceInCny = <String, String>{
  'USD': '7.20',
  'EUR': '7.80',
  'GBP': '9.10',
  'HKD': '0.92',
  'JPY': '0.048',
  'TWD': '0.22',
  'MOP': '0.89',
  'KRW': '0.0052',
  'SGD': '5.35',
  'AUD': '4.70',
  'CAD': '5.20',
  'CHF': '8.10',
  'NZD': '4.30',
  'THB': '0.21',
  'MYR': '1.62',
};

/// Converts a [HaohaoDbSnapshot] into a validated [MigrationPayload] (with
/// attached [HaohaoDbPayloadMeta] for non-clobbering currency upsert).
MigrationPayload convertHaohaoDbSnapshot(
  HaohaoDbSnapshot snapshot, {
  int fallbackNowMs = 1700000000000,
}) {
  final effectiveNowMs = fallbackNowMs > 0 ? fallbackNowMs : 1700000000000;

  // ---------------------------------------------------------------------------
  // 0. User preferences (`user`) & Custom FX Currencies (`user_currencies`)
  // ---------------------------------------------------------------------------
  var defaultStartDay = 1;
  var preferredBookIdRaw = 0;
  var preferredAssetIdRaw = 0;

  for (final u in snapshot.users) {
    if (_isSoftDeleted(_intCol(u, const ['status'], fallback: 0))) continue;
    defaultStartDay = normalizeStartDay(
      _intCol(u, const ['start_bill_day', 'bill_day'], fallback: 1),
    );
    preferredBookIdRaw = _intCol(u, const ['account_book_id'], fallback: 0);
    preferredAssetIdRaw = _intCol(u, const ['assets_account_id'], fallback: 0);
    break;
  }

  final worldByCode = <String, WorldCurrencySpec>{
    for (final w in worldCurrencies) w.code: w,
  };
  final upsertCurrencyByCode = <String, MigrationCurrencyRow>{};

  void registerForeignCurrency(
    String? rawCode, {
    DecimalValue? priceInCny,
    String? customName,
    String? customSymbol,
    bool overwriteRate = false,
  }) {
    final code = _normalizeHaohaoCurrency(rawCode);
    if (code == null || code == baseCurrency) return;
    final existing = upsertCurrencyByCode[code];
    if (existing != null && !overwriteRate) return;

    String? rateToAnchor;
    if (priceInCny != null && priceInCny.coefficient > BigInt.zero) {
      try {
        rateToAnchor = rateToAnchorFromPrice(
          formatExactDecimalString(priceInCny),
        );
      } on Failure {
        rateToAnchor = null;
      }
    }
    if (rateToAnchor == null) {
      if (existing != null) {
        rateToAnchor = existing.rateToAnchor;
      } else {
        final fallbackPrice = _builtinDefaultPriceInCny[code] ?? '1';
        rateToAnchor = rateToAnchorFromPrice(fallbackPrice);
      }
    }

    final spec = worldByCode[code];
    final name = _nonEmpty(customName) ?? spec?.name ?? code;
    final symbol = _nonEmpty(customSymbol) ?? spec?.symbol ?? code;
    upsertCurrencyByCode[code] = MigrationCurrencyRow(
      code: code,
      name: name,
      symbol: symbol,
      rateToAnchor: rateToAnchor,
      anchorCode: baseCurrency,
      rateRefreshTime: effectiveNowMs,
      icon: code.toLowerCase(),
      enable: true,
    );
  }

  for (final row in snapshot.userCurrencies) {
    if (_isSoftDeleted(_intCol(row, const ['status'], fallback: 0))) continue;
    final code = _normalizeHaohaoCurrency(
      _strCol(row, const ['currency_code', 'code']),
    );
    if (code == null || code == baseCurrency) continue;
    final rateDec = parseHaohaoDecimal(row['currency_rate'] ?? row['rate']);
    registerForeignCurrency(
      code,
      priceInCny: rateDec,
      customName: _strCol(row, const ['currency_name', 'name']),
      customSymbol: _strCol(row, const ['currency_symbol', 'symbol']),
      overwriteRate: true,
    );
  }

  // ---------------------------------------------------------------------------
  // 1. Account Books (`account_book` / `account_book_new`)
  // ---------------------------------------------------------------------------
  final books = <MigrationBookRow>[];
  final seenBookIds = <int>{};
  for (var i = 0; i < snapshot.accountBooks.length; i++) {
    final row = snapshot.accountBooks[i];
    final status = _intCol(row, const ['status'], fallback: 0);
    if (_isSoftDeleted(status)) continue;
    final id = _intCol(row, const ['account_book_id', 'id'], fallback: 0);
    if (id <= 0 || !seenBookIds.add(id)) continue;
    final name = _nonEmpty(_strCol(row, const ['name'])) ?? '账本$id';
    final cover = _strCol(row, const ['cover', 'bg_img', 'icon']).trim();
    final sort = _intCol(row, const [
      'order_num',
      'index',
      'sort',
    ], fallback: i);
    final startDay = normalizeStartDay(
      _intCol(row, const [
        'start_bill_day',
        'start_day',
      ], fallback: defaultStartDay),
    );
    final createDate = _positiveEpoch(
      _intCol(row, const ['create_by', 'create_at', 'create_date']),
      effectiveNowMs,
    );
    books.add(
      MigrationBookRow(
        id: id,
        name: name,
        cover: cover,
        sort: sort,
        status: 0,
        startDay: startDay,
        createDate: createDate,
      ),
    );
  }

  if (books.isEmpty) {
    final fallbackId = preferredBookIdRaw > 0 ? preferredBookIdRaw : 1;
    books.add(
      MigrationBookRow(
        id: fallbackId,
        name: '日常账本',
        sort: 0,
        startDay: defaultStartDay,
        createDate: effectiveNowMs,
      ),
    );
    seenBookIds.add(fallbackId);
  }

  final bookById = <int, MigrationBookRow>{for (final b in books) b.id: b};
  final primaryBookId = bookById.containsKey(preferredBookIdRaw)
      ? preferredBookIdRaw
      : books.first.id;

  int resolveBookId(int rawBookId) =>
      bookById.containsKey(rawBookId) ? rawBookId : primaryBookId;

  // ---------------------------------------------------------------------------
  // 2. Ordinary & Credit Accounts (`assets_account` + `bill_initial_balance`)
  // ---------------------------------------------------------------------------
  final initialBalanceByAccountId = <int, BigInt>{};
  for (final row in snapshot.billInitialBalances) {
    final aid = _intCol(row, const ['assets_account_id'], fallback: 0);
    if (aid > 0 && row['initial_amount'] != null) {
      initialBalanceByAccountId[aid] = parseHaohaoRealMinor(
        row['initial_amount'],
        fieldName: 'bill_initial_balance.initial_amount',
      );
    }
  }

  final ordinaryAndCreditAssets = <int, MigrationAssetRow>{};
  final assetCurrencyById = <int, String>{};
  final assetBookSet = <(int, int)>{};
  final assetBookRefs = <MigrationAssetBookRow>[];
  var maxAssetId = 0;

  void addAssetBookBinding(int assetId, int bookId) {
    if (assetId <= 0 || !bookById.containsKey(bookId)) return;
    if (assetBookSet.add((assetId, bookId))) {
      assetBookRefs.add(
        MigrationAssetBookRow(assetId: assetId, bookId: bookId),
      );
    }
  }

  for (var i = 0; i < snapshot.assetsAccounts.length; i++) {
    final row = snapshot.assetsAccounts[i];
    final rawStatus = _intCol(row, const ['status'], fallback: 0);
    if (_isSoftDeleted(rawStatus)) continue;
    final id = _intCol(row, const ['assets_account_id', 'id'], fallback: 0);
    if (id <= 0 || ordinaryAndCreditAssets.containsKey(id)) continue;
    if (id > maxAssetId) maxAssetId = id;

    final name = _nonEmpty(_strCol(row, const ['name'])) ?? '账户$id';
    final rawCategory = _strCol(row, const ['category', 'type']).trim();
    final isCredit =
        rawCategory.toUpperCase() == 'CREDIT_CARD' || rawCategory == '信用卡';

    final normCurrency =
        _normalizeHaohaoCurrency(
          _strCol(row, const ['currency_code', 'currency']),
        ) ??
        baseCurrency;
    final storedCurrency = normCurrency == baseCurrency ? null : normCurrency;
    if (storedCurrency != null) {
      registerForeignCurrency(
        storedCurrency,
        priceInCny: parseHaohaoDecimal(row['base_currency_rate']),
      );
    }
    assetCurrencyById[id] = normCurrency;

    final balanceMinor = row['balance'] != null
        ? parseHaohaoRealMinor(
            row['balance'],
            fieldName: 'assets_account.balance',
          )
        : (initialBalanceByAccountId[id] ?? BigInt.zero);

    final isIncluded = _intCol(row, const ['is_included'], fallback: 1) != 0;
    final assetStatus = rawStatus == 2
        ? AssetStatus.hidden
        : AssetStatus.active;
    final createDate = _positiveEpoch(
      _intCol(row, const ['create_by', 'create_at', 'create_date']),
      effectiveNowMs,
    );
    final sort = _intCol(row, const [
      'order_num',
      'index',
      'sort',
    ], fallback: i);
    final remark = _nullableTrimmed(_strCol(row, const ['remark', 'remarks']));
    final icon = _strCol(row, const ['icon', 'logo']).trim();
    final color = _nullableTrimmed(_strCol(row, const ['color']));

    BigInt initMoneyMinor;
    String? creditInfoJson;
    if (isCredit) {
      final quotaMinor = parseHaohaoRealMinor(
        row['quota'],
        fieldName: 'assets_account.quota',
      );
      initMoneyMinor = quotaMinor < BigInt.zero ? BigInt.zero : quotaMinor;
      final billDay = _mapCreditCycleDay(
        _intCol(row, const ['bill_day'], fallback: unsetDay),
      );
      final isFixedRepay =
          _intCol(row, const ['is_fixed_repayment_date'], fallback: 1) != 0;
      final rawRepayDay = _intCol(row, const [
        'repayment_day',
      ], fallback: unsetDay);
      final rawPostpone = _intCol(row, const [
        'postpone_day',
      ], fallback: unsetDay);
      final repaymentAfterBillDay = !isFixedRepay && rawPostpone > 0;
      final repaymentDay = repaymentAfterBillDay
          ? rawPostpone
          : _mapCreditCycleDay(rawRepayDay);
      final info = CreditInfo()
        ..billDay = billDay
        ..repaymentDay = repaymentDay
        ..repaymentAfterBillDay = repaymentAfterBillDay
        ..billDayCounted = true;
      creditInfoJson = info.encode();
    } else {
      initMoneyMinor =
          row['init_money'] != null || row['initial_balance'] != null
          ? parseHaohaoRealMinor(row['init_money'] ?? row['initial_balance'])
          : (initialBalanceByAccountId[id] ?? BigInt.zero);
      creditInfoJson = null;
    }

    ordinaryAndCreditAssets[id] = MigrationAssetRow(
      id: id,
      name: name,
      balanceMinor: balanceMinor,
      type: isCredit ? AssetType.credit : AssetType.normal,
      subType: noRef,
      createDate: createDate,
      sort: sort,
      icon: icon,
      remark: remark,
      initMoneyMinor: initMoneyMinor,
      isDefault: id == preferredAssetIdRaw,
      isEffectiveAsset: isIncluded ? 1 : 0,
      status: assetStatus,
      color: color,
      creditInfo: creditInfoJson,
      currency: storedCurrency,
    );

    final boundBookId = _intCol(row, const ['account_book_id'], fallback: 0);
    if (boundBookId > 0 && bookById.containsKey(boundBookId)) {
      addAssetBookBinding(id, boundBookId);
    }
  }

  int resolveAssetId(int rawAssetId) =>
      ordinaryAndCreditAssets.containsKey(rawAssetId) ? rawAssetId : noRef;

  // ---------------------------------------------------------------------------
  // 3. Debt Accounts Pre-Indexing (`debt_info`)
  // ---------------------------------------------------------------------------
  final debtOffset = ((maxAssetId ~/ 10000) + 1) * 10000;
  final debtAssetIdByDebtId = <int, int>{};
  final rawDebtsByDebtId = <int, Map<String, Object?>>{};
  final debtSubTypeByDebtId = <int, int>{};
  final debtCurrencyByDebtId = <int, String>{};

  for (final row in snapshot.debts) {
    final rawStatus = _intCol(row, const ['status'], fallback: 0);
    if (_isSoftDeleted(rawStatus)) continue;
    final debtId = _intCol(row, const ['debt_id', 'id'], fallback: 0);
    if (debtId <= 0 || rawDebtsByDebtId.containsKey(debtId)) continue;

    final assetId = debtOffset + debtId;
    debtAssetIdByDebtId[debtId] = assetId;
    rawDebtsByDebtId[debtId] = row;

    final rawTypeText = _strCol(row, const ['type']).trim();
    final rawTypeInt = _intCol(row, const ['type'], fallback: 0);
    // Haohao DebtTypeEnum: VALUE_0(0, "借入") -> debtBorrow(100); VALUE_1(1, "借出") -> debtLend(99).
    final isLend =
        rawTypeText == '借出' ||
        rawTypeText.toUpperCase() == 'LEND' ||
        rawTypeInt == 1 ||
        rawTypeInt == AssetType.debtLend;
    debtSubTypeByDebtId[debtId] = isLend
        ? AssetType.debtLend
        : AssetType.debtBorrow;

    final normCurrency =
        _normalizeHaohaoCurrency(
          _strCol(row, const ['currency_code', 'currency']),
        ) ??
        baseCurrency;
    if (normCurrency != baseCurrency) {
      registerForeignCurrency(normCurrency);
    }
    debtCurrencyByDebtId[debtId] = normCurrency;
    assetCurrencyById[assetId] = normCurrency;
  }

  // ---------------------------------------------------------------------------
  // 4. Categories (`bill_category` / `bill_category_new`) — 2-Level Hierarchy
  // ---------------------------------------------------------------------------
  final rawCategoryById = <int, Map<String, Object?>>{};
  var maxCategoryId = 0;
  for (final row in snapshot.billCategories) {
    final rawStatus = _intCol(row, const ['status'], fallback: 0);
    if (_isSoftDeleted(rawStatus)) continue;
    final id = _intCol(row, const ['bill_category_id', 'id'], fallback: 0);
    if (id <= 0 || rawCategoryById.containsKey(id)) continue;
    rawCategoryById[id] = row;
    if (id > maxCategoryId) maxCategoryId = id;
  }

  int parseCategoryType(Map<String, Object?> row) {
    final raw = _strCol(row, const [
      'category_name',
      'category',
      'type',
    ]).trim();
    final upper = raw.toUpperCase();
    // Haohao CategoryEnums: CONSUME("支出", 1) -> 0, INCOME("收入", 2) -> 1.
    if (raw == '收入' || upper == 'INCOME' || raw == '2') {
      return RecordType.income;
    }
    return RecordType.expense;
  }

  bool isPseudoTransferOrDebtCategory(Map<String, Object?> row) {
    final raw = _strCol(row, const [
      'category_name',
      'category',
      'type',
    ]).trim();
    final upper = raw.toUpperCase();
    return raw == '转账' || upper == 'FORWARD' || raw == '债务' || upper == 'DEBT';
  }

  final categories = <MigrationCategoryRow>[];
  final categoryById = <int, MigrationCategoryRow>{};

  // Pass 4a: root categories first
  var catIndex = 0;
  for (final entry in rawCategoryById.entries) {
    final id = entry.key;
    final row = entry.value;
    if (isPseudoTransferOrDebtCategory(row)) continue;
    final rawParent = _intCol(row, const [
      'bill_category_parent_id',
      'parent_bill_category_id',
      'parent_id',
    ], fallback: noRef);
    final hasValidParent =
        rawParent > 0 &&
        rawParent != id &&
        rawCategoryById.containsKey(rawParent) &&
        !isPseudoTransferOrDebtCategory(rawCategoryById[rawParent]!);
    if (hasValidParent) continue;

    final type = parseCategoryType(row);
    final bookId = resolveBookId(
      _intCol(row, const [
        'account_book_id',
        'book_id',
      ], fallback: primaryBookId),
    );
    final status = _intCol(row, const ['status'], fallback: 0);
    final cat = MigrationCategoryRow(
      id: id,
      name: _nonEmpty(_strCol(row, const ['name'])) ?? '分类$id',
      icon: _strCol(row, const ['icon']).trim(),
      type: type,
      sort: _intCol(row, const [
        'order_num',
        'index',
        'sort',
      ], fallback: catIndex),
      parentCatId: noRef,
      colorFill: _nullableTrimmed(_strCol(row, const ['color', 'color_fill'])),
      accountBookId: bookId,
      isHide: status == 2,
    );
    categories.add(cat);
    categoryById[id] = cat;
    catIndex++;
  }

  // Pass 4b: child categories (flattened to 2-level root if deeper)
  for (final entry in rawCategoryById.entries) {
    final id = entry.key;
    if (categoryById.containsKey(id)) continue;
    final row = entry.value;
    if (isPseudoTransferOrDebtCategory(row)) continue;

    var parentId = _intCol(row, const [
      'bill_category_parent_id',
      'parent_bill_category_id',
      'parent_id',
    ], fallback: noRef);
    final visited = <int>{id};
    while (parentId > 0 &&
        !categoryById.containsKey(parentId) &&
        rawCategoryById.containsKey(parentId) &&
        visited.add(parentId)) {
      final parentRow = rawCategoryById[parentId]!;
      final grandParent = _intCol(parentRow, const [
        'bill_category_parent_id',
        'parent_bill_category_id',
        'parent_id',
      ], fallback: noRef);
      if (grandParent <= 0 || !rawCategoryById.containsKey(grandParent)) break;
      parentId = grandParent;
    }

    final resolvedParent = categoryById[parentId];
    final effectiveParentId =
        resolvedParent != null && resolvedParent.parentCatId == noRef
        ? resolvedParent.id
        : noRef;
    final type = resolvedParent?.type ?? parseCategoryType(row);
    final bookId =
        resolvedParent?.accountBookId ??
        resolveBookId(
          _intCol(row, const [
            'account_book_id',
            'book_id',
          ], fallback: primaryBookId),
        );
    final status = _intCol(row, const ['status'], fallback: 0);
    final cat = MigrationCategoryRow(
      id: id,
      name: _nonEmpty(_strCol(row, const ['name'])) ?? '分类$id',
      icon: _strCol(row, const ['icon']).trim(),
      type: type,
      sort: _intCol(row, const [
        'order_num',
        'index',
        'sort',
      ], fallback: catIndex),
      parentCatId: effectiveParentId,
      colorFill: _nullableTrimmed(_strCol(row, const ['color', 'color_fill'])),
      accountBookId: bookId,
      isHide: status == 2,
    );
    categories.add(cat);
    categoryById[id] = cat;
    catIndex++;
  }

  final fallbackExpenseCatByBook = <int, int>{};
  final fallbackIncomeCatByBook = <int, int>{};
  for (final c in categories) {
    if (c.type == RecordType.expense) {
      fallbackExpenseCatByBook.putIfAbsent(c.accountBookId, () => c.id);
    } else if (c.type == RecordType.income) {
      fallbackIncomeCatByBook.putIfAbsent(c.accountBookId, () => c.id);
    }
  }

  int ensureBookFallbackCategory(int bookId, int catType, {String? hintName}) {
    final map = catType == RecordType.income
        ? fallbackIncomeCatByBook
        : fallbackExpenseCatByBook;
    if (hintName == null || hintName.trim().isEmpty) {
      final existing = map[bookId];
      if (existing != null) return existing;
    } else {
      final trimmedHint = hintName.trim();
      for (final c in categories) {
        if (c.accountBookId == bookId &&
            c.type == catType &&
            c.name == trimmedHint) {
          return c.id;
        }
      }
    }
    final newId = ++maxCategoryId;
    final name =
        _nonEmpty(hintName) ?? (catType == RecordType.income ? '其他收入' : '其他支出');
    final created = MigrationCategoryRow(
      id: newId,
      name: name,
      type: catType,
      sort: categories.length,
      parentCatId: noRef,
      accountBookId: bookId,
    );
    categories.add(created);
    categoryById[newId] = created;
    map.putIfAbsent(bookId, () => newId);
    return newId;
  }

  int resolveCategoryId({
    required int rawCatId,
    required int bookId,
    required int expectedType,
    String? fallbackName,
  }) {
    final existing = categoryById[rawCatId];
    if (existing != null && existing.type == expectedType) {
      return existing.id;
    }
    return ensureBookFallbackCategory(
      bookId,
      expectedType,
      hintName: fallbackName,
    );
  }

  // ---------------------------------------------------------------------------
  // 5. Tags (`tags` / `tag`)
  // ---------------------------------------------------------------------------
  final tags = <MigrationTagRow>[];
  final tagById = <String, MigrationTagRow>{};
  final tagIdByName = <String, String>{};
  var syntheticTagCounter = 1;

  for (var i = 0; i < snapshot.tags.length; i++) {
    final row = snapshot.tags[i];
    final rawStatus = _intCol(row, const ['status'], fallback: 0);
    if (_isSoftDeleted(rawStatus)) continue;
    final rawId = _strCol(row, const ['tag_id', 'id']).trim();
    if (rawId.isEmpty || rawId == '0' || rawId == '-1') continue;
    if (tagById.containsKey(rawId)) continue;
    final name = _nonEmpty(_strCol(row, const ['name'])) ?? '标签$rawId';
    final tagRow = MigrationTagRow(
      tagId: rawId,
      name: name,
      sort: _intCol(row, const ['weight', 'order_num', 'sort'], fallback: i),
      hidden: rawStatus == 2,
      parent: 0,
      color: _nullableTrimmed(_strCol(row, const ['color'])),
    );
    tags.add(tagRow);
    tagById[rawId] = tagRow;
    tagIdByName.putIfAbsent(name, () => rawId);
  }

  String ensureTagForToken(String token) {
    final trimmed = token.trim();
    if (tagById.containsKey(trimmed)) return trimmed;
    final byName = tagIdByName[trimmed];
    if (byName != null) return byName;
    var candidateId = 'hh_tag_${syntheticTagCounter++}';
    while (tagById.containsKey(candidateId)) {
      candidateId = 'hh_tag_${syntheticTagCounter++}';
    }
    final created = MigrationTagRow(
      tagId: candidateId,
      name: trimmed,
      sort: tags.length,
    );
    tags.add(created);
    tagById[candidateId] = created;
    tagIdByName[trimmed] = candidateId;
    return candidateId;
  }

  List<String> resolveTagIdsFromJoinAndText(
    Iterable<String> joinedIds,
    String? rawTagsText,
  ) {
    final out = <String>[];
    final seen = <String>{};
    for (final id in joinedIds) {
      if (tagById.containsKey(id) && seen.add(id)) {
        out.add(id);
      }
    }
    if (out.isEmpty && rawTagsText != null && rawTagsText.trim().isNotEmpty) {
      for (final part in rawTagsText.split(RegExp(r'[\s,，;；#]+'))) {
        final token = part.trim();
        if (token.isEmpty) continue;
        final resolvedId = ensureTagForToken(token);
        if (seen.add(resolvedId)) {
          out.add(resolvedId);
        }
      }
    }
    return out;
  }

  // Pre-collect foreign currencies referenced in bills before building RateTable.
  for (final row in snapshot.billInfos) {
    final rawStatus = _intCol(row, const ['status'], fallback: 0);
    if (_isSoftDeleted(rawStatus)) continue;
    final origCode = _normalizeHaohaoCurrency(
      _strCol(row, const ['original_currency_code']),
    );
    final baseRate = parseHaohaoDecimal(row['base_currency_rate']);
    if (origCode != null && origCode != baseCurrency) {
      registerForeignCurrency(origCode, priceInCny: baseRate);
    }
    final acctCode = _normalizeHaohaoCurrency(
      _strCol(row, const ['assets_account_currency_code']),
    );
    final acctRate = parseHaohaoDecimal(
      row['assets_account_base_currency_rate'],
    );
    if (acctCode != null && acctCode != baseCurrency) {
      registerForeignCurrency(acctCode, priceInCny: acctRate ?? baseRate);
    }
    final toCode = _normalizeHaohaoCurrency(
      _strCol(row, const ['to_assets_currency_code']),
    );
    final toRate = parseHaohaoDecimal(row['to_assets_base_currency_rate']);
    if (toCode != null && toCode != baseCurrency) {
      registerForeignCurrency(toCode, priceInCny: toRate);
    }
  }

  final effectiveRates = RateTable({
    baseCurrency: '1',
    for (final e in upsertCurrencyByCode.entries) e.key: e.value.rateToAnchor,
  });

  // ---------------------------------------------------------------------------
  // 6. Bills (`bill_info` / `bill_info_new`) -> `MigrationRecordRow`
  // ---------------------------------------------------------------------------
  final activeBillRows = <Map<String, Object?>>[];
  final billIdSet = <int>{};
  for (final row in snapshot.billInfos) {
    final rawStatus = _intCol(row, const ['status'], fallback: 0);
    if (_isSoftDeleted(rawStatus)) continue;
    final billId = _intCol(row, const ['bill_info_id', 'id'], fallback: 0);
    if (billId <= 0 || !billIdSet.add(billId)) continue;
    activeBillRows.add(row);
  }

  // Sort parent bills before child bills (`parent_id > 0`) so relations link cleanly.
  activeBillRows.sort((a, b) {
    final pa = _intCol(a, const ['parent_id'], fallback: noRef) > 0 ? 1 : 0;
    final pb = _intCol(b, const ['parent_id'], fallback: noRef) > 0 ? 1 : 0;
    if (pa != pb) return pa.compareTo(pb);
    final ta = _intCol(a, const ['create_by', 'same_date'], fallback: 0);
    final tb = _intCol(b, const ['create_by', 'same_date'], fallback: 0);
    if (ta != tb) return ta.compareTo(tb);
    final ida = _intCol(a, const ['bill_info_id', 'id'], fallback: 0);
    final idb = _intCol(b, const ['bill_info_id', 'id'], fallback: 0);
    return ida.compareTo(idb);
  });

  // Index standalone refund / reimbursement child rows (`parent_id > 0`) to prevent
  // generating duplicate synthetic child rows when both inline columns and child rows exist.
  final standaloneRefundParentIds = <int>{};
  final standaloneReimburseParentIds = <int>{};
  final maxBillTimeByRecycleId = <int, int>{};

  for (final row in activeBillRows) {
    final recycleId = _intCol(row, const ['recycle_id'], fallback: 0);
    final billTime = _positiveEpoch(
      _intCol(row, const ['create_by', 'record_time', 'same_date']),
      effectiveNowMs,
    );
    if (recycleId > 0) {
      final prev = maxBillTimeByRecycleId[recycleId];
      if (prev == null || billTime > prev) {
        maxBillTimeByRecycleId[recycleId] = billTime;
      }
    }

    final parentId = _intCol(row, const ['parent_id'], fallback: noRef);
    if (parentId <= 0 || !billIdSet.contains(parentId)) continue;
    final billType = _intCol(row, const ['bill_type'], fallback: 0);
    final category = _strCol(row, const ['category']).trim();
    final billFrom = _strCol(row, const ['bill_from', 'from']).trim();
    final incomeMinor = parseHaohaoRealMinor(row['income']);
    if (billType == 2 || billType == 22 || category == '退款') {
      standaloneRefundParentIds.add(parentId);
    } else if (category == '报销' ||
        billType == 11 ||
        (billFrom == '自动生成' && incomeMinor > BigInt.zero)) {
      standaloneReimburseParentIds.add(parentId);
    }
  }

  final recordsById = <String, MigrationRecordRow>{};
  final recordOrder = <String>[];
  final pendingRefundChildren = <String, List<LinkedBill>>{};
  final pendingReimburseChildren = <String, List<LinkedBill>>{};
  final debtRecordsByDebtId = <int, List<DebtRecordEntry>>{};
  final debtBooksByDebtId = <int, Set<int>>{};

  void putRecord(MigrationRecordRow row) {
    if (!recordsById.containsKey(row.recordId)) {
      recordOrder.add(row.recordId);
    }
    recordsById[row.recordId] = row;
  }

  String? buildExtraWithCurrency(CurrencySnapshot? snapshot) {
    if (snapshot == null) return null;
    final extra = RecordExtra()..currency = snapshot;
    return extra.raw.isEmpty ? null : jsonEncode(extra.raw);
  }

  ({CurrencySnapshot snapshot, BigInt sourceDiscountMinor})?
  buildNonTransferCurrencySnapshot({
    required Map<String, Object?> row,
    required String accountCurrency,
    required BigInt netAmountInRow,
    required BigInt discountInRow,
    bool allowDiscount = true,
  }) {
    final sourceCode =
        _normalizeHaohaoCurrency(
          _strCol(row, const ['original_currency_code']),
        ) ??
        accountCurrency;
    final acctCode =
        _normalizeHaohaoCurrency(
          _strCol(row, const ['assets_account_currency_code']),
        ) ??
        accountCurrency;
    if (sourceCode == baseCurrency && acctCode == baseCurrency) {
      return null;
    }

    final rawAssetMinor = parseHaohaoRealMinor(row['assets_account_money']);
    final rawOrigMinor = parseHaohaoRealMinor(row['original_money']);
    final baseRateDec = parseHaohaoDecimal(row['base_currency_rate']);

    if (sourceCode != baseCurrency) {
      BigInt srcNet;
      if (acctCode == sourceCode && rawAssetMinor > BigInt.zero) {
        srcNet = rawAssetMinor;
      } else if (allowDiscount &&
          rawOrigMinor > BigInt.zero &&
          netAmountInRow > BigInt.zero) {
        final origInBase =
            baseRateDec != null && baseRateDec.coefficient > BigInt.zero
            ? _multiplyMinorByDecimal(rawOrigMinor, baseRateDec)
            : effectiveRates.convert(rawOrigMinor, sourceCode, baseCurrency);
        if (origInBase > netAmountInRow + BigInt.from(5)) {
          srcNet = baseRateDec != null && baseRateDec.coefficient > BigInt.zero
              ? divideRounded(
                  netAmountInRow * powerOfTen(baseRateDec.scale),
                  baseRateDec.coefficient,
                  RoundingMode.halfUp,
                )
              : effectiveRates.convert(
                  netAmountInRow,
                  baseCurrency,
                  sourceCode,
                );
        } else {
          srcNet = rawOrigMinor;
        }
      } else {
        srcNet = rawOrigMinor > BigInt.zero ? rawOrigMinor : netAmountInRow;
      }

      final srcGross = allowDiscount
          ? (rawOrigMinor > srcNet ? rawOrigMinor : srcNet + discountInRow)
          : srcNet;
      final computedBase =
          baseRateDec != null && baseRateDec.coefficient > BigInt.zero
          ? _multiplyMinorByDecimal(srcNet, baseRateDec)
          : effectiveRates.convert(srcNet, sourceCode, baseCurrency);
      final baseNet =
          netAmountInRow > BigInt.zero &&
              (netAmountInRow - computedBase).abs() <= BigInt.from(5)
          ? netAmountInRow
          : computedBase;
      final acctNet = rawAssetMinor > BigInt.zero
          ? rawAssetMinor
          : (acctCode == sourceCode
                ? srcNet
                : (acctCode == baseCurrency
                      ? baseNet
                      : effectiveRates.convert(srcNet, sourceCode, acctCode)));
      final disc = allowDiscount && srcGross > srcNet
          ? srcGross - srcNet
          : BigInt.zero;
      return (
        snapshot: CurrencySnapshot(
          sourceCode: sourceCode,
          sourceGross: srcGross,
          assetCode: acctCode,
          assetNet: acctNet,
          baseCode: baseCurrency,
          baseAmount: baseNet,
          assetDiscount: disc > BigInt.zero
              ? (acctCode == sourceCode
                    ? disc
                    : (acctCode == baseCurrency &&
                              baseRateDec != null &&
                              baseRateDec.coefficient > BigInt.zero
                          ? _multiplyMinorByDecimal(disc, baseRateDec)
                          : effectiveRates.convert(disc, sourceCode, acctCode)))
              : null,
          baseDiscount: disc > BigInt.zero
              ? (baseRateDec != null && baseRateDec.coefficient > BigInt.zero
                    ? _multiplyMinorByDecimal(disc, baseRateDec)
                    : effectiveRates.convert(disc, sourceCode, baseCurrency))
              : null,
        ),
        sourceDiscountMinor: disc,
      );
    }

    // Source is CNY while account is foreign (e.g. spending CNY on a USD card).
    final effectiveDisc = allowDiscount && discountInRow > BigInt.zero
        ? discountInRow
        : BigInt.zero;
    final srcGross = netAmountInRow + effectiveDisc;
    final acctNet = rawAssetMinor > BigInt.zero
        ? rawAssetMinor
        : effectiveRates.convert(netAmountInRow, baseCurrency, acctCode);
    return (
      snapshot: CurrencySnapshot(
        sourceCode: baseCurrency,
        sourceGross: srcGross,
        assetCode: acctCode,
        assetNet: acctNet,
        baseCode: baseCurrency,
        baseAmount: netAmountInRow,
        assetDiscount: effectiveDisc > BigInt.zero
            ? effectiveRates.convert(effectiveDisc, baseCurrency, acctCode)
            : null,
        baseDiscount: effectiveDisc > BigInt.zero ? effectiveDisc : null,
      ),
      sourceDiscountMinor: effectiveDisc,
    );
  }

  ({String? extraInfo, LinkedBill link}) buildRefundChildLink({
    required String childId,
    required BigInt refundAmountMinor,
    required int refundAssetId,
  }) {
    final targetCurr = assetCurrencyById[refundAssetId] ?? baseCurrency;
    CurrencySnapshot? childSnap;
    if (targetCurr != baseCurrency) {
      childSnap = billSnapshot(
        source: targetCurr,
        sourceMinor: -refundAmountMinor,
        account: targetCurr,
        assetMinor: -refundAmountMinor,
        rates: effectiveRates,
      );
    }
    return (
      extraInfo: buildExtraWithCurrency(childSnap),
      link: LinkedBill(
        billId: childId,
        amount: refundAmountMinor,
        assetCode: childSnap?.assetCode,
        assetAmount: childSnap?.assetNet?.abs(),
        baseCode: childSnap?.baseCode,
        baseAmount: childSnap?.baseAmount?.abs(),
      ),
    );
  }

  ({String? extraInfo, LinkedBill link}) buildReimburseChildLink({
    required String childId,
    required BigInt reimburseAmountMinor,
    required int receiptAssetId,
  }) {
    final targetCurr = assetCurrencyById[receiptAssetId] ?? baseCurrency;
    CurrencySnapshot? childSnap;
    if (targetCurr != baseCurrency) {
      childSnap = billSnapshot(
        source: targetCurr,
        sourceMinor: reimburseAmountMinor,
        account: targetCurr,
        assetMinor: reimburseAmountMinor,
        rates: effectiveRates,
      );
    }
    return (
      extraInfo: buildExtraWithCurrency(childSnap),
      link: LinkedBill(
        billId: childId,
        amount: reimburseAmountMinor,
        assetCode: childSnap?.assetCode,
        assetAmount: childSnap?.assetNet,
        baseCode: childSnap?.baseCode,
        baseAmount: childSnap?.baseAmount,
      ),
    );
  }

  for (final row in activeBillRows) {
    final billId = _intCol(row, const ['bill_info_id', 'id'], fallback: 0);
    final recordId = 'hh_bill_$billId';
    final parentBillId = _intCol(row, const ['parent_id'], fallback: noRef);
    final bookId = resolveBookId(
      _intCol(row, const ['account_book_id'], fallback: primaryBookId),
    );
    final recordTime = _positiveEpoch(
      _intCol(row, const ['create_by', 'record_time']),
      _positiveEpoch(_intCol(row, const ['same_date']), effectiveNowMs),
    );
    final createDate = _positiveEpoch(
      _intCol(row, const ['same_date', 'create_by']),
      recordTime,
    );
    final remark = _strCol(row, const ['remark', 'remarks']).trim();
    final excludeBudget =
        _intCol(row, const ['no_include_budget_flag'], fallback: 0) != 0;
    final excludeExIn =
        _intCol(row, const ['no_include_income_consume'], fallback: 0) != 0;
    final rawCategory = _strCol(row, const ['category']).trim();
    final billType = _intCol(row, const ['bill_type'], fallback: 0);
    final billStatus = _intCol(row, const ['status'], fallback: 0);
    final debtId = _intCol(row, const ['debt_id'], fallback: 0);
    final recycleId = _intCol(row, const ['recycle_id'], fallback: noRef);

    final consumeMinor = parseHaohaoRealMinor(row['consume']);
    final incomeMinor = parseHaohaoRealMinor(row['income']);
    final origMinor = parseHaohaoRealMinor(row['original_money']);
    final feeMinor = parseHaohaoRealMinor(row['handling_fee']);
    final reimbFieldMinor = parseHaohaoRealMinor(row['reimbursement_money']);
    final refundFieldMinor = parseHaohaoRealMinor(row['refund_money']);

    final rawAssetId = _intCol(row, const [
      'assets_account_id',
    ], fallback: noRef);
    final rawToAssetId = _intCol(row, const [
      'to_assets_account_id',
    ], fallback: noRef);
    final mappedAssetId = resolveAssetId(rawAssetId);
    final mappedToAssetId = resolveAssetId(rawToAssetId);
    final acctCurrency = assetCurrencyById[mappedAssetId] ?? baseCurrency;

    // -------------------------------------------------------------------------
    // Case A: Debt principal records (`debt_id > 0` -> `type = 5 / 6 / 7 / 8`)
    // -------------------------------------------------------------------------
    if (debtId > 0 && debtAssetIdByDebtId.containsKey(debtId)) {
      final debtAssetId = debtAssetIdByDebtId[debtId]!;
      final debtCurrency = debtCurrencyByDebtId[debtId] ?? baseCurrency;
      debtBooksByDebtId.putIfAbsent(debtId, () => <int>{}).add(bookId);

      // Haohao debt bill_type: 0=借入(5), 1=借出(6), 2=还款(7), 3=收款(8).
      final (
        int recType,
        int fromId,
        int toId,
        BigInt rawAmt,
      ) = switch (billType) {
        1 => (
          RecordType.lendOut,
          mappedAssetId,
          debtAssetId,
          consumeMinor > BigInt.zero ? consumeMinor : incomeMinor,
        ),
        2 => (
          RecordType.repay,
          mappedAssetId,
          debtAssetId,
          consumeMinor > BigInt.zero ? consumeMinor : incomeMinor,
        ),
        3 => (
          RecordType.collect,
          debtAssetId,
          mappedAssetId,
          incomeMinor > BigInt.zero ? incomeMinor : consumeMinor,
        ),
        _ => (
          RecordType.borrowIn,
          debtAssetId,
          mappedAssetId,
          incomeMinor > BigInt.zero ? incomeMinor : consumeMinor,
        ),
      };

      final currRes = buildNonTransferCurrencySnapshot(
        row: row,
        accountCurrency: mappedAssetId != noRef ? acctCurrency : debtCurrency,
        netAmountInRow: rawAmt,
        discountInRow: BigInt.zero,
        allowDiscount: false,
      );
      final currSnap = currRes?.snapshot;
      final effectiveMoney = currSnap != null
          ? (mappedAssetId != noRef
                ? (currSnap.assetNet ?? rawAmt)
                : currSnap.sourceGross)
          : rawAmt;

      putRecord(
        MigrationRecordRow(
          recordId: recordId,
          type: recType,
          subType: RecordDirection.none,
          moneyMinor: effectiveMoney,
          remark: remark,
          recordTime: recordTime,
          recordCatId: noRef,
          assetId: noRef,
          fromAssetId: fromId,
          toAssetId: toId,
          accountBookId: bookId,
          excludeBudget: excludeBudget,
          excludeExIn: excludeExIn,
          extraInfo: buildExtraWithCurrency(currSnap),
          createDate: createDate,
        ),
      );
      debtRecordsByDebtId
          .putIfAbsent(debtId, () => <DebtRecordEntry>[])
          .add(
            DebtRecordEntry(
              recordId: recordId,
              type: recType,
              moneyMinor: effectiveMoney,
              recordTime: recordTime,
              currency: currSnap,
            ),
          );
      continue;
    }

    // -------------------------------------------------------------------------
    // Case B: Standalone Refund Child Row (`parent_id > 0` & refund type)
    // -------------------------------------------------------------------------
    final parentRecordId = 'hh_bill_$parentBillId';
    if (parentBillId > 0 &&
        recordsById.containsKey(parentRecordId) &&
        (billType == 2 || billType == 22 || rawCategory == '退款')) {
      final parentRow = recordsById[parentRecordId]!;
      final targetAsset = mappedToAssetId != noRef
          ? mappedToAssetId
          : (mappedAssetId != noRef ? mappedAssetId : parentRow.assetId);
      final targetCurr = assetCurrencyById[targetAsset] ?? baseCurrency;
      final rawToAssetMinor = parseHaohaoRealMinor(
        row['to_assets_account_money'],
      );
      final rawFromAssetMinor = parseHaohaoRealMinor(
        row['assets_account_money'],
      );
      final fallbackMag = refundFieldMinor > BigInt.zero
          ? refundFieldMinor
          : (incomeMinor > BigInt.zero ? incomeMinor : consumeMinor);
      final refundMag =
          targetCurr != baseCurrency && rawToAssetMinor > BigInt.zero
          ? rawToAssetMinor
          : (targetCurr != baseCurrency && rawFromAssetMinor > BigInt.zero
                ? rawFromAssetMinor
                : fallbackMag);
      if (refundMag > BigInt.zero) {
        final childTime = recordTime <= parentRow.recordTime
            ? parentRow.recordTime + 1
            : recordTime;
        final childFx = buildRefundChildLink(
          childId: recordId,
          refundAmountMinor: refundMag,
          refundAssetId: targetAsset,
        );
        final childRels = RecordRelations()
          ..refunds = BillLinks(originId: parentRecordId);
        putRecord(
          MigrationRecordRow(
            recordId: recordId,
            type: RecordType.expense,
            subType: RecordDirection.none,
            moneyMinor: -refundMag,
            remark: remark.isEmpty ? '退款' : remark,
            recordTime: childTime,
            recordCatId: parentRow.recordCatId,
            assetId: targetAsset,
            accountBookId: bookId,
            excludeBudget: excludeBudget,
            excludeExIn: excludeExIn,
            extraInfo: childFx.extraInfo,
            relInfo: childRels.encode(),
            createDate: createDate,
          ),
        );
        pendingRefundChildren
            .putIfAbsent(parentRecordId, () => <LinkedBill>[])
            .add(childFx.link);
      }
      continue;
    }

    // -------------------------------------------------------------------------
    // Case C: Standalone Reimbursement Recovery Child Row (`parent_id > 0`)
    // -------------------------------------------------------------------------
    if (parentBillId > 0 &&
        recordsById.containsKey(parentRecordId) &&
        standaloneReimburseParentIds.contains(parentBillId)) {
      final parentRow = recordsById[parentRecordId]!;
      final targetAsset = mappedToAssetId != noRef
          ? mappedToAssetId
          : (mappedAssetId != noRef ? mappedAssetId : parentRow.fromAssetId);
      final targetCurr = assetCurrencyById[targetAsset] ?? baseCurrency;
      final rawToAssetMinor = parseHaohaoRealMinor(
        row['to_assets_account_money'],
      );
      final rawFromAssetMinor = parseHaohaoRealMinor(
        row['assets_account_money'],
      );
      final fallbackMag = incomeMinor > BigInt.zero
          ? incomeMinor
          : (reimbFieldMinor > BigInt.zero ? reimbFieldMinor : consumeMinor);
      final reimbMag =
          targetCurr != baseCurrency && rawToAssetMinor > BigInt.zero
          ? rawToAssetMinor
          : (targetCurr != baseCurrency && rawFromAssetMinor > BigInt.zero
                ? rawFromAssetMinor
                : fallbackMag);
      if (reimbMag > BigInt.zero) {
        final childTime = recordTime <= parentRow.recordTime
            ? parentRow.recordTime + 1
            : recordTime;
        final childFx = buildReimburseChildLink(
          childId: recordId,
          reimburseAmountMinor: reimbMag,
          receiptAssetId: targetAsset,
        );
        final childRels = RecordRelations()
          ..reimbursements = BillLinks(originId: parentRecordId);
        putRecord(
          MigrationRecordRow(
            recordId: recordId,
            type: RecordType.reimburseReceipt,
            subType: RecordDirection.income,
            moneyMinor: reimbMag,
            remark: remark.isEmpty ? '报销入账' : remark,
            recordTime: childTime,
            recordCatId: parentRow.recordCatId,
            assetId: targetAsset,
            accountBookId: bookId,
            excludeBudget: excludeBudget,
            excludeExIn: excludeExIn,
            extraInfo: childFx.extraInfo,
            relInfo: childRels.encode(),
            createDate: createDate,
          ),
        );
        pendingReimburseChildren
            .putIfAbsent(parentRecordId, () => <LinkedBill>[])
            .add(childFx.link);
      }
      continue;
    }

    // -------------------------------------------------------------------------
    // Case D: Transfer (`category == '转账'` / `'FORWARD'`) + Fee Child (`type=12`)
    // -------------------------------------------------------------------------
    if (rawCategory == '转账' || rawCategory.toUpperCase() == 'FORWARD') {
      final feeFromTarget =
          _intCol(row, const ['forward_type'], fallback: 0) != 0;
      BigInt principalMinor;
      if (feeMinor > BigInt.zero &&
          incomeMinor > BigInt.zero &&
          consumeMinor == incomeMinor + feeMinor) {
        principalMinor = incomeMinor;
      } else if (feeMinor > BigInt.zero &&
          consumeMinor > BigInt.zero &&
          incomeMinor + feeMinor == consumeMinor) {
        principalMinor = consumeMinor;
      } else if (consumeMinor > BigInt.zero) {
        principalMinor = consumeMinor;
      } else if (incomeMinor > BigInt.zero) {
        principalMinor = incomeMinor;
      } else {
        principalMinor = origMinor;
      }

      final fromCurr =
          assetCurrencyById[mappedAssetId] ??
          _normalizeHaohaoCurrency(
            _strCol(row, const [
              'assets_account_currency_code',
              'original_currency_code',
            ]),
          ) ??
          baseCurrency;
      final toCurr =
          assetCurrencyById[mappedToAssetId] ??
          _normalizeHaohaoCurrency(
            _strCol(row, const ['to_assets_currency_code']),
          ) ??
          fromCurr;

      final rawFromAssetMoney = parseHaohaoRealMinor(
        row['assets_account_money'],
      );
      final rawToAssetMoney = parseHaohaoRealMinor(
        row['to_assets_account_money'],
      );

      var transferMoneyMinor = principalMinor;
      CurrencySnapshot? transferCurr;
      if (fromCurr != baseCurrency || toCurr != baseCurrency) {
        final fromMinor = rawFromAssetMoney > BigInt.zero
            ? (feeMinor > BigInt.zero &&
                      !feeFromTarget &&
                      rawFromAssetMoney == principalMinor + feeMinor
                  ? principalMinor
                  : rawFromAssetMoney)
            : (fromCurr == baseCurrency
                  ? principalMinor
                  : (origMinor > BigInt.zero ? origMinor : principalMinor));
        final toMinor = rawToAssetMoney > BigInt.zero
            ? rawToAssetMoney
            : (toCurr == fromCurr
                  ? fromMinor
                  : effectiveRates.convert(fromMinor, fromCurr, toCurr));
        final baseMinor = fromCurr == baseCurrency
            ? fromMinor
            : (toCurr == baseCurrency
                  ? toMinor
                  : (principalMinor > BigInt.zero
                        ? principalMinor
                        : effectiveRates.convert(
                            fromMinor,
                            fromCurr,
                            baseCurrency,
                          )));
        transferMoneyMinor = fromMinor;
        transferCurr = CurrencySnapshot(
          sourceCode: fromCurr,
          sourceGross: fromMinor,
          assetCode: toCurr,
          assetNet: toMinor,
          baseCode: baseCurrency,
          baseAmount: baseMinor,
        );
      }

      final isCreditRepay =
          ordinaryAndCreditAssets[mappedToAssetId]?.type == AssetType.credit;
      String? parentRelInfo;
      if (feeMinor > BigInt.zero) {
        final rels = RecordRelations()
          ..transferFee = TransferFeeLink(
            feeFromTarget: feeFromTarget,
            repay: isCreditRepay,
          );
        parentRelInfo = rels.encode();
      }

      putRecord(
        MigrationRecordRow(
          recordId: recordId,
          type: RecordType.transfer,
          subType: RecordDirection.none,
          moneyMinor: transferMoneyMinor,
          remark: remark,
          recordTime: recordTime,
          recordCatId: noRef,
          assetId: noRef,
          fromAssetId: mappedAssetId,
          toAssetId: mappedToAssetId,
          accountBookId: bookId,
          excludeBudget: excludeBudget,
          excludeExIn: excludeExIn,
          periodId: recycleId > 0 ? recycleId : noRef,
          relInfo: parentRelInfo,
          extraInfo: buildExtraWithCurrency(transferCurr),
          createDate: createDate,
        ),
      );

      if (feeMinor > BigInt.zero) {
        final feeAssetId = feeFromTarget ? mappedToAssetId : mappedAssetId;
        final feeCurrCode = assetCurrencyById[feeAssetId] ?? baseCurrency;
        CurrencySnapshot? feeCurr;
        if (feeCurrCode != baseCurrency) {
          feeCurr = CurrencySnapshot(
            sourceCode: feeCurrCode,
            sourceGross: feeMinor,
            assetCode: feeCurrCode,
            assetNet: feeMinor,
            baseCode: baseCurrency,
            baseAmount: effectiveRates.convert(
              feeMinor,
              feeCurrCode,
              baseCurrency,
            ),
          );
        }
        final childRels = RecordRelations()
          ..transferFee = TransferFeeLink(
            feeFromTarget: feeFromTarget,
            repay: isCreditRepay,
            parentId: recordId,
          );
        putRecord(
          MigrationRecordRow(
            recordId: '${recordId}_fee',
            type: RecordType.fee,
            subType: RecordDirection.expense,
            moneyMinor: feeMinor,
            remark: remark.isEmpty ? '转账手续费' : '$remark（手续费）',
            recordTime: recordTime + 1,
            recordCatId: noRef,
            assetId: feeAssetId,
            accountBookId: bookId,
            excludeBudget: excludeBudget,
            excludeExIn: excludeExIn,
            relInfo: childRels.encode(),
            extraInfo: buildExtraWithCurrency(feeCurr),
            createDate: createDate,
          ),
        );
      }
      continue;
    }

    // -------------------------------------------------------------------------
    // Case E: Reimbursable Expense (`bill_type == 1` or `category == '报销'`)
    // -------------------------------------------------------------------------
    if (billType == 1 || rawCategory == '报销') {
      final catId = resolveCategoryId(
        rawCatId: _intCol(row, const ['bill_category_id'], fallback: noRef),
        bookId: bookId,
        expectedType: RecordType.expense,
        fallbackName: _nonEmpty(_strCol(row, const ['name'])) ?? '报销',
      );

      final BigInt parentExpenseMinor;
      if (consumeMinor > BigInt.zero) {
        parentExpenseMinor =
            (billStatus == 1 &&
                reimbFieldMinor > consumeMinor &&
                origMinor == reimbFieldMinor)
            ? reimbFieldMinor
            : consumeMinor;
      } else if (reimbFieldMinor > BigInt.zero) {
        parentExpenseMinor = reimbFieldMinor;
      } else {
        parentExpenseMinor = origMinor;
      }

      // L-01: Reimbursable (`type = 3`) never carries `discount_minor`; keep
      // `sourceGross == srcNet` and `discountMinor: null`.
      final currRes = buildNonTransferCurrencySnapshot(
        row: row,
        accountCurrency: acctCurrency,
        netAmountInRow: parentExpenseMinor,
        discountInRow: BigInt.zero,
        allowDiscount: false,
      );
      final currSnap = currRes?.snapshot;
      final storedParentMoney = currSnap != null
          ? (currSnap.assetNet ?? parentExpenseMinor)
          : parentExpenseMinor;

      putRecord(
        MigrationRecordRow(
          recordId: recordId,
          type: RecordType.reimbursable,
          subType: RecordDirection.none,
          moneyMinor: storedParentMoney,
          remark: remark,
          recordTime: recordTime,
          recordCatId: catId,
          assetId: noRef,
          fromAssetId: mappedAssetId,
          toAssetId: noRef,
          accountBookId: bookId,
          excludeBudget: excludeBudget,
          excludeExIn: excludeExIn,
          periodId: recycleId > 0 ? recycleId : noRef,
          discountMinor: null,
          extraInfo: buildExtraWithCurrency(currSnap),
          createDate: createDate,
        ),
      );

      if (reimbFieldMinor > BigInt.zero &&
          !standaloneReimburseParentIds.contains(billId)) {
        final rawReimbursedMinor =
            (billStatus == 1 &&
                consumeMinor == BigInt.zero &&
                incomeMinor > BigInt.zero)
            ? reimbFieldMinor + incomeMinor
            : reimbFieldMinor;
        final receiptAssetId = mappedToAssetId != noRef
            ? mappedToAssetId
            : mappedAssetId;
        final receiptCurr = assetCurrencyById[receiptAssetId] ?? baseCurrency;
        final rawToAssetMinor = parseHaohaoRealMinor(
          row['to_assets_account_money'],
        );
        final reimbursedMinor =
            receiptCurr != baseCurrency && rawToAssetMinor > BigInt.zero
            ? rawToAssetMinor
            : rawReimbursedMinor;
        final rawReimbDate = _intCol(row, const [
          'reimbursement_date',
        ], fallback: 0);
        final reimbDate = rawReimbDate > recordTime
            ? rawReimbDate
            : recordTime + 1;
        final childId = '${recordId}_reimb';
        final childFx = buildReimburseChildLink(
          childId: childId,
          reimburseAmountMinor: reimbursedMinor,
          receiptAssetId: receiptAssetId,
        );
        final childRels = RecordRelations()
          ..reimbursements = BillLinks(originId: recordId);
        putRecord(
          MigrationRecordRow(
            recordId: childId,
            type: RecordType.reimburseReceipt,
            subType: RecordDirection.income,
            moneyMinor: reimbursedMinor,
            remark: remark.isEmpty ? '报销到账' : '$remark（报销）',
            recordTime: reimbDate,
            recordCatId: catId,
            assetId: receiptAssetId,
            accountBookId: bookId,
            excludeBudget: excludeBudget,
            excludeExIn: excludeExIn,
            extraInfo: childFx.extraInfo,
            relInfo: childRels.encode(),
            createDate: reimbDate,
          ),
        );
        pendingReimburseChildren
            .putIfAbsent(recordId, () => <LinkedBill>[])
            .add(childFx.link);
      }
      continue;
    }

    // -------------------------------------------------------------------------
    // Case F: Normal Income (`type=1`) & Normal Expense (`type=0` + Refund/Discount)
    // -------------------------------------------------------------------------
    final isIncome =
        rawCategory == '收入' || rawCategory.toUpperCase() == 'INCOME';
    if (isIncome) {
      final catId = resolveCategoryId(
        rawCatId: _intCol(row, const ['bill_category_id'], fallback: noRef),
        bookId: bookId,
        expectedType: RecordType.income,
        fallbackName: _nonEmpty(_strCol(row, const ['name'])),
      );
      final netMinor = incomeMinor > BigInt.zero ? incomeMinor : consumeMinor;
      final sourceCode = _normalizeHaohaoCurrency(
        _strCol(row, const ['original_currency_code']),
      );
      final isForeignSource = sourceCode != null && sourceCode != baseCurrency;
      final discountMinor = !isForeignSource && origMinor > netMinor
          ? origMinor - netMinor
          : BigInt.zero;
      final currRes = buildNonTransferCurrencySnapshot(
        row: row,
        accountCurrency: acctCurrency,
        netAmountInRow: netMinor,
        discountInRow: discountMinor,
      );
      final currSnap = currRes?.snapshot;
      final effectiveMoney = currSnap != null
          ? (currSnap.assetNet ?? netMinor)
          : netMinor;
      // `record.discount_minor` is ALWAYS in `sourceCode` (`currSnap.sourceCode`),
      // NEVER `currSnap.assetDiscount`.
      final effectiveDiscount = currRes?.sourceDiscountMinor ?? discountMinor;
      putRecord(
        MigrationRecordRow(
          recordId: recordId,
          type: RecordType.income,
          subType: RecordDirection.none,
          moneyMinor: effectiveMoney,
          remark: remark,
          recordTime: recordTime,
          recordCatId: catId,
          assetId: mappedAssetId,
          accountBookId: bookId,
          excludeBudget: excludeBudget,
          excludeExIn: excludeExIn,
          periodId: recycleId > 0 ? recycleId : noRef,
          discountMinor: effectiveDiscount > BigInt.zero
              ? effectiveDiscount
              : null,
          extraInfo: buildExtraWithCurrency(currSnap),
          createDate: createDate,
        ),
      );
      continue;
    }

    // Normal Expense (`type=0`)
    final catId = resolveCategoryId(
      rawCatId: _intCol(row, const ['bill_category_id'], fallback: noRef),
      bookId: bookId,
      expectedType: RecordType.expense,
      fallbackName: _nonEmpty(_strCol(row, const ['name'])),
    );
    final hasInlineRefund =
        refundFieldMinor > BigInt.zero &&
        !standaloneRefundParentIds.contains(billId);
    final BigInt netMinor;
    if (consumeMinor > BigInt.zero) {
      netMinor = consumeMinor;
    } else if (hasInlineRefund) {
      netMinor = origMinor >= refundFieldMinor ? origMinor : refundFieldMinor;
    } else {
      netMinor = incomeMinor;
    }
    final sourceCode = _normalizeHaohaoCurrency(
      _strCol(row, const ['original_currency_code']),
    );
    final isForeignSource = sourceCode != null && sourceCode != baseCurrency;
    final discountMinor = !isForeignSource && origMinor > netMinor
        ? origMinor - netMinor
        : BigInt.zero;

    final currRes = buildNonTransferCurrencySnapshot(
      row: row,
      accountCurrency: acctCurrency,
      netAmountInRow: netMinor,
      discountInRow: discountMinor,
    );
    final currSnap = currRes?.snapshot;

    final effectiveMoney = currSnap != null
        ? (currSnap.assetNet ?? netMinor)
        : netMinor;
    // `record.discount_minor` is ALWAYS in `sourceCode` (`currSnap.sourceCode`),
    // NEVER `currSnap.assetDiscount`.
    final effectiveDiscount = currRes?.sourceDiscountMinor ?? discountMinor;

    putRecord(
      MigrationRecordRow(
        recordId: recordId,
        type: RecordType.expense,
        subType: RecordDirection.none,
        moneyMinor: effectiveMoney,
        remark: remark,
        recordTime: recordTime,
        recordCatId: catId,
        assetId: mappedAssetId,
        accountBookId: bookId,
        excludeBudget: excludeBudget,
        excludeExIn: excludeExIn,
        periodId: recycleId > 0 ? recycleId : noRef,
        discountMinor: effectiveDiscount > BigInt.zero
            ? effectiveDiscount
            : null,
        extraInfo: buildExtraWithCurrency(currSnap),
        createDate: createDate,
      ),
    );

    if (hasInlineRefund) {
      final refundAssetId = mappedToAssetId != noRef
          ? mappedToAssetId
          : mappedAssetId;
      final refundCurr = assetCurrencyById[refundAssetId] ?? baseCurrency;
      final rawToAssetMinor = parseHaohaoRealMinor(
        row['to_assets_account_money'],
      );
      final refundAmtMinor =
          refundCurr != baseCurrency && rawToAssetMinor > BigInt.zero
          ? rawToAssetMinor
          : refundFieldMinor;
      final rawRefundDate = _intCol(row, const ['refund_date'], fallback: 0);
      final refundDate = rawRefundDate > recordTime
          ? rawRefundDate
          : recordTime + 1;
      final childId = '${recordId}_refund';
      final childFx = buildRefundChildLink(
        childId: childId,
        refundAmountMinor: refundAmtMinor,
        refundAssetId: refundAssetId,
      );
      final childRels = RecordRelations()
        ..refunds = BillLinks(originId: recordId);
      putRecord(
        MigrationRecordRow(
          recordId: childId,
          type: RecordType.expense,
          subType: RecordDirection.none,
          moneyMinor: -refundAmtMinor,
          remark: remark.isEmpty ? '退款' : '$remark（退款）',
          recordTime: refundDate,
          recordCatId: catId,
          assetId: refundAssetId,
          accountBookId: bookId,
          excludeBudget: excludeBudget,
          excludeExIn: excludeExIn,
          extraInfo: childFx.extraInfo,
          relInfo: childRels.encode(),
          createDate: refundDate,
        ),
      );
      pendingRefundChildren
          .putIfAbsent(recordId, () => <LinkedBill>[])
          .add(childFx.link);
    }
  }

  // Patch bidirectional `lrefundi` and `lreimbursei` onto parent records.
  final patchedParentIds = <String>{
    ...pendingRefundChildren.keys,
    ...pendingReimburseChildren.keys,
  };
  for (final pid in patchedParentIds) {
    final existing = recordsById[pid];
    if (existing == null) continue;
    final rels = RecordRelations.parse(existing.relInfo);
    final refunds = pendingRefundChildren[pid];
    if (refunds != null && refunds.isNotEmpty) {
      rels.refunds = BillLinks(children: refunds);
    }
    final reimbs = pendingReimburseChildren[pid];
    if (reimbs != null && reimbs.isNotEmpty) {
      rels.reimbursements = BillLinks(children: reimbs);
    }
    recordsById[pid] = MigrationRecordRow(
      recordId: existing.recordId,
      type: existing.type,
      subType: existing.subType,
      moneyMinor: existing.moneyMinor,
      remark: existing.remark,
      recordTime: existing.recordTime,
      recordCatId: existing.recordCatId,
      assetId: existing.assetId,
      fromAssetId: existing.fromAssetId,
      toAssetId: existing.toAssetId,
      accountBookId: existing.accountBookId,
      excludeBudget: existing.excludeBudget,
      excludeExIn: existing.excludeExIn,
      platformId: existing.platformId,
      periodId: existing.periodId,
      installment: existing.installment,
      images: existing.images,
      relInfo: rels.encode(),
      discountMinor: existing.discountMinor,
      extraInfo: existing.extraInfo,
      createDate: existing.createDate,
    );
  }

  final records = <MigrationRecordRow>[
    for (final id in recordOrder) recordsById[id]!,
  ];

  // ---------------------------------------------------------------------------
  // 7. Tag References (`bill_tags` / `bill_tag` + fallback `bill_info.tags`)
  // ---------------------------------------------------------------------------
  final billTagIdsByBillId = <int, List<String>>{};
  for (final row in snapshot.billTags) {
    final billId = _intCol(row, const ['bill_info_id', 'bill_id'], fallback: 0);
    final tagId = _strCol(row, const ['tag_id']).trim();
    if (billId <= 0 || tagId.isEmpty) continue;
    billTagIdsByBillId.putIfAbsent(billId, () => <String>[]).add(tagId);
  }

  final tagRefs = <MigrationTagRefRow>[];
  final seenTagRefs = <(String, String)>{};
  for (final row in activeBillRows) {
    final billId = _intCol(row, const ['bill_info_id', 'id'], fallback: 0);
    final recordId = 'hh_bill_$billId';
    if (!recordsById.containsKey(recordId)) continue;
    final resolvedTagIds = resolveTagIdsFromJoinAndText(
      billTagIdsByBillId[billId] ?? const <String>[],
      _strCol(row, const ['tags']),
    );
    for (final tagId in resolvedTagIds) {
      if (seenTagRefs.add((tagId, recordId))) {
        tagRefs.add(MigrationTagRefRow(tagId: tagId, recordId: recordId));
      }
    }
  }

  // ---------------------------------------------------------------------------
  // 8. Finalize Debt Accounts (`debt_info`) via `recomputeDebtPrincipal`
  // ---------------------------------------------------------------------------
  final debtAssets = <MigrationAssetRow>[];
  var debtSortIndex = ordinaryAndCreditAssets.length;
  for (final entry in rawDebtsByDebtId.entries) {
    final debtId = entry.key;
    final row = entry.value;
    final assetId = debtAssetIdByDebtId[debtId]!;
    final subType = debtSubTypeByDebtId[debtId]!;
    final normCurrency = debtCurrencyByDebtId[debtId] ?? baseCurrency;
    final storedCurrency = normCurrency == baseCurrency ? null : normCurrency;

    final createAt = _positiveEpoch(
      _intCol(row, const ['create_at', 'create_by', 'create_date']),
      effectiveNowMs,
    );
    final rawEndDate = _intCol(row, const [
      'repayment_date',
      'end_date',
    ], fallback: noRef);
    final endDate = rawEndDate > 0 ? rawEndDate : noRef;
    final rawStatus = _intCol(row, const ['status'], fallback: 0);
    final isSettled = rawStatus == 1;

    // Invert polarity per `tables.dart` line 45 (`0` = counted in net worth, `1` = excluded).
    final countedInNetWorth =
        _intCol(row, const ['is_assets_flag', 'is_included'], fallback: 1) != 0;
    final effectiveFlag = debtEffectiveAssetFlag(
      countedInNetWorth: countedInNetWorth,
    );

    final debtEntries =
        debtRecordsByDebtId[debtId] ?? const <DebtRecordEntry>[];
    BigInt finalBalanceMinor;
    int finalStatus;
    String loanInfoJson;

    if (debtEntries.isNotEmpty) {
      final seedLoan = LoanInfo(
        schemaVersion: 2,
        startDate: createAt,
        endDate: endDate,
        manualSettled: isSettled,
      );
      final recomputed = recomputeDebtPrincipal(
        debtSubType: subType,
        currentStatus: isSettled ? AssetStatus.settled : AssetStatus.active,
        currentLoanInfo: seedLoan,
        records: debtEntries,
        debtCurrency: storedCurrency,
        rates: effectiveRates,
        nowMs: effectiveNowMs,
      );
      finalBalanceMinor = recomputed.balanceMinor;
      finalStatus = recomputed.status;
      loanInfoJson = recomputed.loanInfo.encode();
    } else {
      final fallbackPrincipal = parseHaohaoRealMinor(
        row['amount'] ?? row['money'] ?? row['balance'],
      ).abs();
      finalStatus = isSettled ? AssetStatus.settled : AssetStatus.active;
      finalBalanceMinor = isSettled ? BigInt.zero : fallbackPrincipal;
      loanInfoJson = LoanInfo(
        schemaVersion: 2,
        startDate: createAt,
        endDate: endDate,
        totalDebtMoneyMinor: fallbackPrincipal,
        manualSettled: isSettled,
        settledSnapshotMinor: isSettled ? fallbackPrincipal : null,
        settledCurrencyCode: isSettled ? normCurrency : null,
        settledAtMs: isSettled ? effectiveNowMs : null,
        positionsUpdatedAtMs: effectiveNowMs,
        currencyPositions: fallbackPrincipal > BigInt.zero
            ? <LoanCurrencyPosition>[
                LoanCurrencyPosition(
                  currencyCode: normCurrency,
                  principalBalanceMinor: finalBalanceMinor,
                  totalPrincipalMinor: fallbackPrincipal,
                ),
              ]
            : const <LoanCurrencyPosition>[],
      ).encode();
    }

    debtAssets.add(
      MigrationAssetRow(
        id: assetId,
        name: _nonEmpty(_strCol(row, const ['name'])) ?? '借贷$debtId',
        balanceMinor: finalBalanceMinor,
        type: AssetType.debt,
        subType: subType,
        createDate: createAt,
        sort: debtSortIndex++,
        icon: _strCol(row, const ['icon']).trim(),
        remark: _nullableTrimmed(_strCol(row, const ['remarks', 'remark'])),
        initMoneyMinor: BigInt.zero,
        isEffectiveAsset: effectiveFlag,
        status: finalStatus,
        loanInfo: loanInfoJson,
        currency: storedCurrency,
      ),
    );

    final boundBooks = <int>{...?debtBooksByDebtId[debtId]};
    final explicitBook = _intCol(row, const ['account_book_id'], fallback: 0);
    if (explicitBook > 0 && bookById.containsKey(explicitBook)) {
      boundBooks.add(explicitBook);
    }
    if (boundBooks.isEmpty && primaryBookId != 1) {
      boundBooks.add(primaryBookId);
    }
    for (final bid in boundBooks) {
      addAssetBookBinding(assetId, bid);
    }
  }

  // ---------------------------------------------------------------------------
  // 9. Budgets (`budget` / `budget_new` + `bill_category_budget`)
  // ---------------------------------------------------------------------------
  final categoryIdsByBudgetId = <int, List<int>>{};
  for (final row in snapshot.billCategoryBudgets) {
    final bid = _intCol(row, const ['budget_id'], fallback: 0);
    final cid = _intCol(row, const ['bill_category_id'], fallback: 0);
    if (bid <= 0 || cid <= 0) continue;
    categoryIdsByBudgetId.putIfAbsent(bid, () => <int>[]).add(cid);
  }

  final budgetsBySlot = <(int, int, String, int), MigrationBudgetRow>{};
  var nextBudgetId = 1;
  for (var i = 0; i < snapshot.budgets.length; i++) {
    final row = snapshot.budgets[i];
    final rawStatus = _intCol(row, const ['status'], fallback: 0);
    if (_isSoftDeleted(rawStatus)) continue;
    final rawBudgetId = _intCol(row, const ['budget_id', 'id'], fallback: 0);
    final amountMinor = parseHaohaoRealMinor(
      row['amount'],
      fieldName: 'budget.amount',
    );
    if (amountMinor <= BigInt.zero) continue;

    final bookId = resolveBookId(
      _intCol(row, const [
        'account_book_id',
        'book_id',
      ], fallback: primaryBookId),
    );
    final startDay = bookById[bookId]?.startDay ?? defaultStartDay;
    final rawBudgetMode = _intCol(row, const ['budget_type'], fallback: 1);
    final anchorMs = _positiveEpoch(
      _intCol(row, const ['start_date']),
      _positiveEpoch(_intCol(row, const ['create_by']), effectiveNowMs),
    );
    final anchorDt = DateTime.fromMillisecondsSinceEpoch(anchorMs);
    // Haohao BudgetTypeEnums: 1 = MONTH_BUDGET, 2 = YEAR_BUDGET, 3 = CUSTOM_BUDGET.
    final section = rawBudgetMode == 2
        ? BillingPeriod.containingYear(anchorDt, startDay).yearlySection
        : BillingPeriod.containing(anchorDt, startDay).monthlySection;

    final directCatId = _intCol(row, const [
      'bill_category_id',
    ], fallback: noRef);
    final linkedCats = <int>{
      if (rawBudgetId > 0) ...?categoryIdsByBudgetId[rawBudgetId],
      if (directCatId > 0) directCatId,
    }.where(categoryById.containsKey).toList();

    final createDate = _positiveEpoch(
      _intCol(row, const ['create_by']),
      anchorMs,
    );
    final sort = _intCol(row, const [
      'order_num',
      'index',
      'sort',
    ], fallback: i);
    final remark = _nullableTrimmed(_strCol(row, const ['name', 'remark']));
    final extraInfo = BudgetExtra(
      autoCopy: true,
      forward: false,
      baseMinor: amountMinor,
    ).toJsonString();

    if (linkedCats.isEmpty) {
      final slot = (bookId, BudgetTypeCode.total, section, noRef);
      budgetsBySlot[slot] = MigrationBudgetRow(
        id: budgetsBySlot[slot]?.id ?? nextBudgetId++,
        budgetType: BudgetTypeCode.total,
        recordCatId: noRef,
        amountMinor: amountMinor,
        bookId: bookId,
        section: section,
        sort: sort,
        createDate: createDate,
        remark: remark,
        extraInfo: extraInfo,
      );
    } else {
      for (final cid in linkedCats) {
        final cat = categoryById[cid]!;
        final bType = cat.type == RecordType.income
            ? BudgetTypeCode.savingCategory
            : BudgetTypeCode.expenseCategory;
        final slot = (bookId, bType, section, cid);
        budgetsBySlot[slot] = MigrationBudgetRow(
          id: budgetsBySlot[slot]?.id ?? nextBudgetId++,
          budgetType: bType,
          recordCatId: cid,
          amountMinor: amountMinor,
          bookId: bookId,
          section: section,
          sort: sort,
          createDate: createDate,
          remark: remark,
          extraInfo: extraInfo,
        );
      }
    }
  }
  final budgets = budgetsBySlot.values.toList();

  // ---------------------------------------------------------------------------
  // 10. Periodic Rules & Installments (`recycle_info` + `installment_bill`)
  // ---------------------------------------------------------------------------
  final recycleTagIdsById = <int, List<String>>{};
  for (final row in snapshot.recycleTags) {
    final rid = _intCol(row, const ['recycle_id'], fallback: 0);
    final tid = _strCol(row, const ['tag_id']).trim();
    if (rid <= 0 || tid.isEmpty) continue;
    recycleTagIdsById.putIfAbsent(rid, () => <String>[]).add(tid);
  }

  final installmentItemsByRecycleId = <int, List<Map<String, Object?>>>{};
  for (final row in snapshot.installmentBills) {
    final rawStatus = _intCol(row, const ['status'], fallback: 0);
    if (_isSoftDeleted(rawStatus)) continue;
    final rid = _intCol(row, const ['recycle_id'], fallback: 0);
    if (rid <= 0) continue;
    installmentItemsByRecycleId
        .putIfAbsent(rid, () => <Map<String, Object?>>[])
        .add(row);
  }
  for (final list in installmentItemsByRecycleId.values) {
    list.sort(
      (a, b) => _intCol(a, const [
        'num',
      ], fallback: 0).compareTo(_intCol(b, const ['num'], fallback: 0)),
    );
  }

  final periods = <MigrationPeriodRow>[];
  final installments = <MigrationInstallmentRow>[];
  final seenRecycleIds = <int>{};

  for (final row in snapshot.recycleInfos) {
    final rawStatus = _intCol(row, const ['status'], fallback: 0);
    if (_isSoftDeleted(rawStatus)) continue;
    final recycleId = _intCol(row, const ['recycle_id', 'id'], fallback: 0);
    if (recycleId <= 0 || !seenRecycleIds.add(recycleId)) continue;

    final rType = _intCol(row, const ['type'], fallback: 1);
    final bookId = resolveBookId(
      _intCol(row, const [
        'account_book_id',
        'book_id',
      ], fallback: primaryBookId),
    );
    final startDateMs = _positiveEpoch(
      _intCol(row, const ['start_date', 'record_time', 'create_by']),
      effectiveNowMs,
    );
    final createDate = _positiveEpoch(
      _intCol(row, const ['create_by', 'record_time']),
      startDateMs,
    );
    final excludeBudget =
        _intCol(row, const ['no_include_budget_flag'], fallback: 0) != 0;
    final excludeExIn =
        _intCol(row, const ['no_include_income_consume'], fallback: 0) != 0;
    final resolvedTagIds = resolveTagIdsFromJoinAndText(
      recycleTagIdsById[recycleId] ?? const <String>[],
      _strCol(row, const ['tags']),
    );
    final mappedAssetId = resolveAssetId(
      _intCol(row, const ['assets_account_id'], fallback: noRef),
    );

    if (rType == 2) {
      // INSTALLMENT_BILL
      final items =
          installmentItemsByRecycleId[recycleId] ??
          const <Map<String, Object?>>[];
      final totalPeriodsRaw = _intCol(row, const [
        'installment_total_num',
        'periods',
      ], fallback: items.length);
      final totalPeriods = totalPeriodsRaw < 1 ? 1 : totalPeriodsRaw;

      BigInt principalMinor;
      BigInt chargeMinor;
      if (items.isNotEmpty) {
        principalMinor = BigInt.zero;
        chargeMinor = BigInt.zero;
        for (final it in items) {
          principalMinor += parseHaohaoRealMinor(it['money']);
          chargeMinor += parseHaohaoRealMinor(
            it['handle_free'] ?? it['handling_fee'],
          );
        }
        if (principalMinor <= BigInt.zero) {
          principalMinor = parseHaohaoRealMinor(row['money']);
        }
      } else {
        principalMinor = parseHaohaoRealMinor(row['money']);
        chargeMinor = parseHaohaoRealMinor(row['handling_fee']);
      }
      if (principalMinor <= BigInt.zero) continue;

      // Haohao HandleFeeTypeEnums: 1=每期均摊, 2=首期收取, 3=末期收取.
      final chargeWay = switch (_intCol(row, const [
        'handle_fee_type',
      ], fallback: 1)) {
        2 => InstallmentChargeWay.firstPeriod,
        3 => InstallmentChargeWay.lastPeriod,
        _ => InstallmentChargeWay.perPeriod,
      };
      // Haohao RemainderIncludedEnums: 1=首期, 2=末期.
      final remainderIn =
          _intCol(row, const ['remainder_included'], fallback: 1) == 2
          ? InstallmentRemainderIn.lastPeriod
          : InstallmentRemainderIn.firstPeriod;

      final creditedSet = <int>{};
      if (rawStatus == 2) {
        for (var p = 1; p <= totalPeriods; p++) {
          creditedSet.add(p);
        }
      } else if (items.isNotEmpty) {
        for (final it in items) {
          final pNum = _intCol(it, const ['num'], fallback: 0);
          final itStatus = _intCol(it, const ['status'], fallback: 0);
          if (itStatus == 1 && pNum >= 1 && pNum <= totalPeriods) {
            creditedSet.add(pNum);
          }
        }
      } else {
        final postedCount = _intCol(row, const [
          'installment_num',
          'run_count',
        ], fallback: 0).clamp(0, totalPeriods);
        for (var p = 1; p <= postedCount; p++) {
          creditedSet.add(p);
        }
      }

      final schedule = buildInstallmentSchedule(
        installmentId: recycleId,
        principalMinor: principalMinor,
        periods: totalPeriods,
        chargeMinor: chargeMinor,
        chargeWay: chargeWay,
        calWay: InstallmentCalWay.halfUp2,
        remainderIn: remainderIn,
        startDateMs: startDateMs,
        creditedPeriods: creditedSet,
      );
      final progress = computeInstallmentProgress(
        schedule: schedule,
        principalMinor: principalMinor,
        chargeMinor: chargeMinor,
        startDateMs: startDateMs,
      );

      final catId = resolveCategoryId(
        rawCatId: _intCol(row, const ['bill_category_id'], fallback: noRef),
        bookId: bookId,
        expectedType: RecordType.expense,
        fallbackName: _nonEmpty(_strCol(row, const ['bill_category_name'])),
      );
      final name =
          _nonEmpty(_strCol(row, const ['remarks', 'remark'])) ??
          _nonEmpty(_strCol(row, const ['bill_category_name'])) ??
          '分期#$recycleId';

      final creditedList = creditedSet.toList()..sort();
      final instExtra = InstallmentExtra()
        ..principalCounted = true
        ..interestCounted = false;

      installments.add(
        MigrationInstallmentRow(
          id: recycleId,
          name: name,
          catId: catId,
          principalMinor: principalMinor,
          periods: totalPeriods,
          chargeMinor: chargeMinor,
          chargeWay: chargeWay,
          remainderIn: remainderIn,
          calWay: InstallmentCalWay.halfUp2,
          startDate: startDateMs,
          assetId: mappedAssetId,
          nextPeriod: progress.nextPeriod,
          nextPeriodDate: progress.nextPeriodDateMs,
          credited: jsonEncode(creditedList),
          bookId: bookId,
          excludeBudget: excludeBudget,
          excludeExIn: excludeExIn,
          createDate: createDate,
          tags: encodeTemplateTagsCsv(resolvedTagIds),
          exi: instExtra.encode(),
        ),
      );

      // Synchronize credit card's `credit_info.inst` for active installments.
      final creditAsset = ordinaryAndCreditAssets[mappedAssetId];
      if (creditAsset != null && creditAsset.type == AssetType.credit) {
        final syncedCreditInfo = syncCreditInfoInstallment(
          currentCreditInfoJson: creditAsset.creditInfo,
          installmentId: recycleId,
          remainingPrincipalMinor: progress.remainingPrincipalMinor,
          remainingFeeMinor: progress.remainingFeeMinor,
          isFinished: progress.isFinished,
          principalCounted: true,
          interestCounted: false,
        );
        ordinaryAndCreditAssets[mappedAssetId] = MigrationAssetRow(
          id: creditAsset.id,
          name: creditAsset.name,
          balanceMinor: creditAsset.balanceMinor,
          type: creditAsset.type,
          subType: creditAsset.subType,
          createDate: creditAsset.createDate,
          sort: creditAsset.sort,
          icon: creditAsset.icon,
          remark: creditAsset.remark,
          initMoneyMinor: creditAsset.initMoneyMinor,
          isDefault: creditAsset.isDefault,
          isEffectiveAsset: creditAsset.isEffectiveAsset,
          usedTimes: creditAsset.usedTimes,
          color: creditAsset.color,
          status: creditAsset.status,
          extraInfo: creditAsset.extraInfo,
          loanInfo: creditAsset.loanInfo,
          creditInfo: syncedCreditInfo,
          fixedDepositInfo: creditAsset.fixedDepositInfo,
          groupName: creditAsset.groupName,
          currency: creditAsset.currency,
        );
      }
    } else {
      // RECYCLE_BILL (`type == 1`) -> `MigrationPeriodRow`
      final rawCat = _strCol(row, const ['category']).trim();
      final recordType = switch (rawCat) {
        '收入' || 'INCOME' => RecordType.income,
        '转账' || 'FORWARD' => RecordType.transfer,
        _ => RecordType.expense,
      };
      final moneyMinor = parseHaohaoRealMinor(row['money']);
      if (moneyMinor <= BigInt.zero) continue;
      final feeMinor = parseHaohaoRealMinor(row['handling_fee']);
      final mappedToAssetId = resolveAssetId(
        _intCol(row, const ['to_assets_account_id'], fallback: noRef),
      );
      final catId = recordType == RecordType.transfer
          ? noRef
          : resolveCategoryId(
              rawCatId: _intCol(row, const [
                'bill_category_id',
              ], fallback: noRef),
              bookId: bookId,
              expectedType: recordType == RecordType.income
                  ? RecordType.income
                  : RecordType.expense,
              fallbackName: _nonEmpty(
                _strCol(row, const ['bill_category_name']),
              ),
            );

      final startDt = DateTime.fromMillisecondsSinceEpoch(startDateMs);
      final rawPeriod = _strCol(row, const ['period']).trim();
      final (int periodType, String periodTypeDate) = switch (rawPeriod) {
        'weekDays' => (
          PeriodType.weekly,
          encodePeriodTypeDateJson(PeriodType.weekly, const [
            '1',
            '2',
            '3',
            '4',
            '5',
          ]),
        ),
        'everyWeek' => (
          PeriodType.weekly,
          encodePeriodTypeDateJson(PeriodType.weekly, ['${startDt.weekday}']),
        ),
        'everyMonth' => (
          PeriodType.monthly,
          encodePeriodTypeDateJson(PeriodType.monthly, ['${startDt.day}']),
        ),
        'everyYear' => (
          PeriodType.yearly,
          encodePeriodTypeDateJson(PeriodType.yearly, [
            '${startDt.month.toString().padLeft(2, '0')}-${startDt.day.toString().padLeft(2, '0')}',
          ]),
        ),
        _ => (
          PeriodType.daily,
          encodePeriodTypeDateJson(PeriodType.daily, const []),
        ),
      };

      final endRecycleType = _intCol(row, const [
        'end_recycle_type',
      ], fallback: 0);
      final rawEndDate = _intCol(row, const ['end_date'], fallback: 0);
      final rawEndCount = _intCol(row, const ['end_count'], fallback: 0);
      final periodEndDate = switch (endRecycleType) {
        1 when rawEndDate > periodMaxEndCount => rawEndDate,
        2 when rawEndCount >= 1 => rawEndCount.clamp(1, periodMaxEndCount),
        _ => periodEndNever,
      };

      // Haohao recycle status: 0=进行中, 1=暂停执行, 2=已完结.
      final state = switch (rawStatus) {
        1 => PeriodState.paused,
        2 => PeriodState.ended,
        _ => PeriodState.active,
      };
      final runCount = _intCol(row, const ['run_count'], fallback: 0);
      final lastAddDate = maxBillTimeByRecycleId[recycleId] ?? noLastAddDate;
      final feeFromTarget =
          _intCol(row, const ['forward_type'], fallback: 0) != 0;
      final pExtra = PeriodExtra()..feeFromTarget = feeFromTarget;

      periods.add(
        MigrationPeriodRow(
          id: recycleId,
          recordType: recordType,
          moneyMinor: moneyMinor,
          feeMinor: feeMinor,
          remark: _strCol(row, const ['remarks', 'remark']).trim(),
          catId: catId,
          assetId: mappedAssetId,
          assetId2: recordType == RecordType.transfer ? mappedToAssetId : noRef,
          bookId: bookId,
          state: state,
          excludeBudget: excludeBudget,
          excludeExIn: excludeExIn,
          periodType: periodType,
          periodTypeDate: periodTypeDate,
          periodStartDate: startDateMs,
          periodEndDate: periodEndDate,
          frequency: 1,
          lastAddDate: lastAddDate,
          periodAddTimes: runCount < 0 ? 0 : runCount,
          createTime: createDate,
          tags: encodePeriodTagTokens(resolvedTagIds),
          exi: pExtra.encode(),
        ),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // 11. Savings Plans (`saving_plan` + `saving_plan_item`)
  // ---------------------------------------------------------------------------
  final savedItemsByPlanId = <int, List<Map<String, Object?>>>{};
  for (final row in snapshot.savingPlanItems) {
    // Only `status == 1` rows represent completed check-in savings records;
    // `status == 0` rows are uncompleted preview schedule slots in Haohao.
    if (_intCol(row, const ['status'], fallback: 0) != 1) continue;
    final pid = _intCol(row, const ['saving_plan_id', 'plan_id'], fallback: 0);
    if (pid <= 0) continue;
    savedItemsByPlanId
        .putIfAbsent(pid, () => <Map<String, Object?>>[])
        .add(row);
  }

  final savingsPlans = <MigrationSavingsPlanRow>[];
  final savingsRecords = <MigrationSavingsRecordRow>[];
  final seenPlanIds = <int>{};
  var nextSaveRecordId = 1;

  for (var i = 0; i < snapshot.savingPlans.length; i++) {
    final row = snapshot.savingPlans[i];
    final rawStatus = _intCol(row, const ['status'], fallback: 0);
    if (_isSoftDeleted(rawStatus)) continue;
    final planId = _intCol(row, const ['saving_plan_id', 'id'], fallback: 0);
    if (planId <= 0 || !seenPlanIds.add(planId)) continue;

    final startMoneyMinor = parseHaohaoRealMinor(row['init_amount']);
    final incrementalMinor = parseHaohaoRealMinor(row['incremental_amount']);
    final modeCode = _intCol(row, const ['type'], fallback: 4);
    final rawCycleCode = _intCol(row, const ['plan_type'], fallback: 1);

    int mapSavingCycle(int c) => switch (c) {
      2 => SavingsCycleType.weekly,
      3 => SavingsCycleType.monthly,
      _ => SavingsCycleType.daily,
    };

    // Haohao SavingPlanModeEnum: 1=365天, 2=52周, 3=12月, 4=定额, 5=自由, 6=递增.
    final (int planType, int cycleType) = switch (modeCode) {
      1 => (SavingsPlanType.incremental, SavingsCycleType.daily),
      2 => (SavingsPlanType.incremental, SavingsCycleType.weekly),
      3 => (
        incrementalMinor > BigInt.zero
            ? SavingsPlanType.incremental
            : SavingsPlanType.fixed,
        SavingsCycleType.monthly,
      ),
      4 => (SavingsPlanType.fixed, mapSavingCycle(rawCycleCode)),
      5 => (SavingsPlanType.free, SavingsCycleType.free),
      6 => (SavingsPlanType.incremental, mapSavingCycle(rawCycleCode)),
      _ => (SavingsPlanType.free, SavingsCycleType.free),
    };

    final fromAssetId = resolveAssetId(
      _intCol(row, const ['assets_account_id'], fallback: noRef),
    );
    final toAssetId = resolveAssetId(
      _intCol(row, const ['to_assets_account_id'], fallback: noRef),
    );
    final startDate = _positiveEpoch(
      _intCol(row, const ['start_date', 'create_at']),
      effectiveNowMs,
    );
    final endDate = _positiveEpoch(
      _intCol(row, const ['end_date']),
      startDate + 365 * 86400000,
    );
    final createDate = _positiveEpoch(
      _intCol(row, const ['create_at', 'create_by']),
      startDate,
    );

    var savedMoneyMinor = BigInt.zero;
    var maxSavedDate = startDate;
    final planItems =
        savedItemsByPlanId[planId] ?? const <Map<String, Object?>>[];
    for (final item in planItems) {
      final itemMoney = parseHaohaoRealMinor(item['amount']);
      if (itemMoney <= BigInt.zero) continue;
      savedMoneyMinor += itemMoney;
      final recDate = _positiveEpoch(
        _intCol(item, const ['plan_date', 'update_at', 'create_at']),
        startDate,
      );
      if (recDate > maxSavedDate) maxSavedDate = recDate;
      final linkedBillId = _intCol(item, const ['bill_info_id'], fallback: 0);
      final candidateRecordId = 'hh_bill_$linkedBillId';
      final itemId = _intCol(item, const [
        'saving_plan_item_id',
        'id',
      ], fallback: nextSaveRecordId);
      if (itemId >= nextSaveRecordId) nextSaveRecordId = itemId + 1;
      savingsRecords.add(
        MigrationSavingsRecordRow(
          id: itemId,
          planId: planId,
          remark: _strCol(item, const ['remarks', 'remark']).trim(),
          fromAssetId: fromAssetId,
          toAssetId: toAssetId,
          recordDate: recDate,
          recordMoneyMinor: itemMoney,
          recordId:
              linkedBillId > 0 && recordsById.containsKey(candidateRecordId)
              ? candidateRecordId
              : null,
        ),
      );
    }

    final rawTotalTarget = parseHaohaoRealMinor(row['total_amount']);
    final planMoneyMinor = rawTotalTarget > BigInt.zero
        ? rawTotalTarget
        : savedMoneyMinor;

    savingsPlans.add(
      MigrationSavingsPlanRow(
        id: planId,
        name: _nonEmpty(_strCol(row, const ['name'])) ?? '存钱计划#$planId',
        remark: _strCol(row, const ['remarks', 'remark']).trim(),
        planType: planType,
        cycleType: cycleType,
        startDate: startDate,
        endDate: endDate,
        planMoneyMinor: planMoneyMinor,
        savedMoneyMinor: savedMoneyMinor,
        autoPlan: false,
        fromAssetId: fromAssetId,
        toAssetId: toAssetId,
        bookId: resolveBookId(
          _intCol(row, const ['account_book_id'], fallback: primaryBookId),
        ),
        startMoneyMinor: startMoneyMinor,
        incrementalMinor: incrementalMinor,
        status: rawStatus == 1
            ? SavingsPlanStatus.archived
            : SavingsPlanStatus.active,
        createDate: createDate,
        sort: _intCol(row, const ['weight', 'order_num', 'sort'], fallback: i),
        nextSaveDate: maxSavedDate,
        icon: _nullableTrimmed(_strCol(row, const ['cover', 'icon'])),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 12. Templates (`bill_template` + `bill_template_tags`)
  // ---------------------------------------------------------------------------
  final templateTagIdsById = <int, List<String>>{};
  for (final row in snapshot.billTemplateTags) {
    final tid = _intCol(row, const [
      'bill_template_id',
      'template_id',
    ], fallback: 0);
    final tagId = _strCol(row, const ['tag_id']).trim();
    if (tid <= 0 || tagId.isEmpty) continue;
    templateTagIdsById.putIfAbsent(tid, () => <String>[]).add(tagId);
  }

  final templates = <MigrationTemplateRow>[];
  final seenTemplateIds = <int>{};
  for (var i = 0; i < snapshot.billTemplates.length; i++) {
    final row = snapshot.billTemplates[i];
    final rawStatus = _intCol(row, const ['status'], fallback: 0);
    if (_isSoftDeleted(rawStatus)) continue;
    final templateId = _intCol(row, const [
      'bill_template_id',
      'id',
    ], fallback: 0);
    if (templateId <= 0 || !seenTemplateIds.add(templateId)) continue;

    final rawCat = _strCol(row, const ['category']).trim();
    final billType = _intCol(row, const ['bill_type'], fallback: 0);
    final int templateType;
    if (rawCat == '收入' || rawCat.toUpperCase() == 'INCOME') {
      templateType = RecordType.income;
    } else if (rawCat == '转账' || rawCat.toUpperCase() == 'FORWARD') {
      templateType = RecordType.transfer;
    } else if (billType == 1 || rawCat == '报销') {
      templateType = RecordType.reimbursable;
    } else {
      templateType = RecordType.expense;
    }

    final bookId = resolveBookId(
      _intCol(row, const [
        'account_book_id',
        'book_id',
      ], fallback: primaryBookId),
    );
    final rawMoney = row['money'] != null
        ? parseHaohaoRealMinor(row['money'])
        : (parseHaohaoRealMinor(row['consume']) > BigInt.zero
              ? parseHaohaoRealMinor(row['consume'])
              : parseHaohaoRealMinor(row['income']));
    if (templateRequiresPositiveAmount(templateType) &&
        rawMoney <= BigInt.zero) {
      continue;
    }

    final feeMinor = parseHaohaoRealMinor(row['handling_fee']);
    final mappedFrom = resolveAssetId(
      _intCol(row, const ['assets_account_id'], fallback: noRef),
    );
    final mappedTo = resolveAssetId(
      _intCol(row, const ['to_assets_account_id'], fallback: noRef),
    );
    final catId = templateType == RecordType.transfer
        ? null
        : resolveCategoryId(
            rawCatId: _intCol(row, const ['bill_category_id'], fallback: noRef),
            bookId: bookId,
            expectedType: templateType == RecordType.income
                ? RecordType.income
                : RecordType.expense,
            fallbackName: _nonEmpty(_strCol(row, const ['name'])),
          );

    final resolvedTagIds = resolveTagIdsFromJoinAndText(
      templateTagIdsById[templateId] ?? const <String>[],
      _strCol(row, const ['tags']),
    );
    final rawName = _strCol(row, const ['name']).trim();
    final clippedName = rawName.length > maxTemplateNameLength
        ? rawName.substring(0, maxTemplateNameLength)
        : rawName;
    final tExtra = TemplateExtra();
    if (clippedName.isNotEmpty) {
      tExtra.name = clippedName;
    }
    if (templateType == RecordType.transfer &&
        _intCol(row, const ['forward_type'], fallback: 0) != 0) {
      tExtra.feeFromTarget = true;
    }

    templates.add(
      MigrationTemplateRow(
        id: templateId,
        type: templateType,
        remark: _nullableTrimmed(_strCol(row, const ['remark', 'remarks'])),
        moneyMinor: rawMoney < BigInt.zero ? BigInt.zero : rawMoney,
        feeMinor: feeMinor < BigInt.zero ? BigInt.zero : feeMinor,
        recordCatId: catId,
        assetId: mappedFrom,
        assetId2: templateType == RecordType.transfer ? mappedTo : noRef,
        sort: _intCol(row, const ['order_num', 'index', 'sort'], fallback: i),
        bookId: bookId,
        excludeBudget:
            _intCol(row, const ['no_include_budget_flag'], fallback: 0) != 0,
        excludeExIn:
            _intCol(row, const ['no_include_income_consume'], fallback: 0) != 0,
        createDate: _positiveEpoch(
          _intCol(row, const ['create_by', 'create_at']),
          effectiveNowMs,
        ),
        tags: encodeTemplateTagsCsv(resolvedTagIds),
        exi: tExtra.encode(),
      ),
    );
  }

  // Combine ordinary/credit assets + debt assets in stable order.
  final allAssets = <MigrationAssetRow>[
    ...ordinaryAndCreditAssets.values,
    ...debtAssets,
  ];

  final payload = MigrationPayload(
    books: books,
    categories: categories,
    assets: allAssets,
    records: records,
    budgets: budgets,
    installments: installments,
    periods: periods,
    tags: tags,
    tagRefs: tagRefs,
    templates: templates,
    moneySavePlans: savingsPlans,
    moneySavePlanRecords: savingsRecords,
    assetBookRefs: assetBookRefs,
  );

  attachHaohaoPayloadMeta(
    payload,
    HaohaoDbPayloadMeta(
      upsertCurrencies: upsertCurrencyByCode.values.toList(),
      preferredBookId: primaryBookId,
      preferredAssetId: ordinaryAndCreditAssets.containsKey(preferredAssetIdRaw)
          ? preferredAssetIdRaw
          : null,
    ),
  );

  return payload;
}

// =============================================================================
// Private Pure Helpers
// =============================================================================

bool _isSoftDeleted(int status) => status < 0 || status == 4 || status == 9;

int _mapCreditCycleDay(int rawDay) {
  if (rawDay >= 1 && rawDay <= 28) return rawDay;
  if (rawDay >= 29 && rawDay <= 31) return endOfMonthDay;
  return unsetDay;
}

String? _normalizeHaohaoCurrency(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final alias =
      _currencyAliases[trimmed] ?? _currencyAliases[trimmed.toUpperCase()];
  if (alias != null) return alias;
  return normalizeCurrency(trimmed);
}

BigInt _multiplyMinorByDecimal(BigInt minor, DecimalValue rate) {
  if (minor == BigInt.zero || rate.coefficient <= BigInt.zero) {
    return BigInt.zero;
  }
  if (rate.scale == 0) return minor * rate.coefficient;
  return divideRounded(
    minor * rate.coefficient,
    powerOfTen(rate.scale),
    RoundingMode.halfUp,
  );
}

int _intCol(Map<String, Object?> row, List<String> keys, {int fallback = 0}) {
  for (final k in keys) {
    final v = row[k];
    if (v == null) continue;
    if (v is int) return v;
    if (v is BigInt) return v.toInt();
    if (v is num) return v.isFinite ? v.toInt() : fallback;
    if (v is String) {
      final parsed = int.tryParse(v.trim());
      if (parsed != null) return parsed;
    }
  }
  return fallback;
}

String _strCol(Map<String, Object?> row, List<String> keys) {
  for (final k in keys) {
    final v = row[k];
    if (v == null) continue;
    if (v is String) return v;
    return v.toString();
  }
  return '';
}

String? _nonEmpty(String? s) {
  if (s == null) return null;
  final t = s.trim();
  return t.isEmpty ? null : t;
}

String? _nullableTrimmed(String? s) {
  if (s == null) return null;
  final t = s.trim();
  return t.isEmpty ? null : t;
}

int _positiveEpoch(int candidate, int fallback) =>
    candidate > 0 ? candidate : fallback;
