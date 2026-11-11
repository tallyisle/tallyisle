import 'dart:convert';

import '../../core/failure.dart';
import '../../core/money.dart';
import '../model/codes.dart';

/// Bill types supported by `RecordTemplates` (`F-016`).
const List<int> supportedTemplateTypes = <int>[
  RecordType.expense,
  RecordType.income,
  RecordType.transfer,
  RecordType.reimbursable,
  RecordType.advanceExpense,
  RecordType.advanceIncome,
];

/// Upper bound matching the bill editor (`88888888888.00`, ledger-catalog §5).
final BigInt maxTemplateAmountMinor = BigInt.parse('8888888888800');

const int maxRemarkLength = 200;
const int maxTemplateNameLength = 50;
const int maxBankCardNameLength = 50;
const int maxBankCardOwnerLength = 50;
const int maxBankCardRemarkLength = 200;
const int minBankCardDigits = 8;
const int maxBankCardDigits = 30;

bool isSupportedTemplateType(int type) => supportedTemplateTypes.contains(type);

/// Expected `record_category.type` (`0` expense / `1` income), or `null` for transfers.
int? templateCategoryTypeFor(int templateType) => switch (templateType) {
  RecordType.expense ||
  RecordType.reimbursable ||
  RecordType.advanceExpense => RecordType.expense,
  RecordType.income || RecordType.advanceIncome => RecordType.income,
  RecordType.transfer => null,
  _ => throw Failure(FailureCode.validation, '不支持的模板账单类型 $templateType'),
};

/// Whether `LedgerService.saveRecord` requires `money > 0` for `[templateType]`.
bool templateRequiresPositiveAmount(int templateType) => switch (templateType) {
  RecordType.transfer ||
  RecordType.reimbursable ||
  RecordType.advanceIncome ||
  RecordType.advanceExpense => true,
  RecordType.expense || RecordType.income => false,
  _ => throw Failure(FailureCode.validation, '不支持的模板账单类型 $templateType'),
};

String templateTypeLabel(int type) => RecordType.names[type] ?? '类型$type';

/// Parses user-entered decimal text into 2-decimal [Money] without `double`.
Money parseTemplateMoneyText(String text, {String currency = 'CNY'}) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return Money.zero(currency);
  final withoutTrailingDot = trimmed.endsWith('.')
      ? trimmed.substring(0, trimmed.length - 1)
      : trimmed;
  if (withoutTrailingDot.isEmpty || withoutTrailingDot == '-') {
    throw const Failure(FailureCode.validation, '请输入有效金额');
  }
  final normalized = withoutTrailingDot.startsWith('.')
      ? '0$withoutTrailingDot'
      : withoutTrailingDot;
  final money = Money.parse(normalized, currency: currency);
  if (money.isNegative) {
    throw const Failure(FailureCode.validation, '金额不能为负数');
  }
  if (money.storageMinor > maxTemplateAmountMinor) {
    throw const Failure(FailureCode.validation, '金额不能超过 88888888888.00');
  }
  return money;
}

/// Parses `record_template.tags` (CSV tag IDs, or legacy JSON string array)
/// into deduplicated non-empty tag IDs preserving order.
List<String> parseTemplateTagsCsv(String? raw) {
  if (raw == null) return const <String>[];
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return const <String>[];

  Iterable<String> tokens;
  if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is List) {
        tokens = decoded.whereType<Object>().map((e) => e.toString());
      } else {
        tokens = trimmed.split(',');
      }
    } on FormatException {
      tokens = trimmed.split(',');
    }
  } else {
    tokens = trimmed.split(',');
  }

  final seen = <String>{};
  final result = <String>[];
  for (final token in tokens) {
    final clean = token.trim();
    if (clean.isNotEmpty && seen.add(clean)) {
      result.add(clean);
    }
  }
  return List<String>.unmodifiable(result);
}

/// Encodes tag IDs as a comma-separated string, or `null` when empty.
String? encodeTemplateTagsCsv(Iterable<String> tagIds) {
  final seen = <String>{};
  final cleaned = <String>[];
  for (final id in tagIds) {
    final token = id.trim();
    if (token.isNotEmpty && !token.contains(',') && seen.add(token)) {
      cleaned.add(token);
    } else if (token.contains(',')) {
      for (final sub in token.split(',')) {
        final s = sub.trim();
        if (s.isNotEmpty && seen.add(s)) {
          cleaned.add(s);
        }
      }
    }
  }
  return cleaned.isEmpty ? null : cleaned.join(',');
}

const _corruptTemplateExtra = Failure(FailureCode.corruptData, '模板附加信息格式损坏');

/// Typed codec for `record_template.exi` JSON. Unknown keys survive round-trip.
final class TemplateExtra {
  TemplateExtra([Map<String, Object?>? raw]) : raw = <String, Object?>{...?raw};

  final Map<String, Object?> raw;

  /// Optional human-readable title for the template (`name`).
  String? get name {
    final v = raw['name'];
    if (v is! String) return null;
    final t = v.trim();
    return t.isEmpty ? null : t;
  }

  set name(String? value) {
    final t = value?.trim() ?? '';
    if (t.isEmpty) {
      raw.remove('name');
    } else {
      if (t.length > maxTemplateNameLength) {
        throw const Failure(
          FailureCode.validation,
          '模板名称不能超过 $maxTemplateNameLength 字',
        );
      }
      raw['name'] = t;
    }
  }

  /// Transfer fee payer (`fee_from`: `0` outgoing account, `1` incoming account).
  bool get feeFromTarget => raw['fee_from'] == 1 || raw['fee_from'] == true;

  set feeFromTarget(bool value) => raw['fee_from'] = value ? 1 : 0;

  /// Optional foreign source currency code (`sc`) for non-transfer templates.
  String? get sourceCurrency {
    final v = raw['sc'];
    if (v is! String) return null;
    final code = v.trim().toUpperCase();
    return RegExp(r'^[A-Z]{3,8}$').hasMatch(code) ? code : null;
  }

  set sourceCurrency(String? value) {
    final code = value?.trim().toUpperCase() ?? '';
    if (code.isEmpty) {
      raw.remove('sc');
    } else {
      if (!RegExp(r'^[A-Z]{3,8}$').hasMatch(code)) {
        throw const Failure(FailureCode.validation, '币种代码无效');
      }
      raw['sc'] = code;
    }
  }

  static TemplateExtra parse(String? text) {
    if (text == null || text.trim().isEmpty) return TemplateExtra();
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw _corruptTemplateExtra;
    }
    if (decoded is! Map<String, Object?>) throw _corruptTemplateExtra;
    return TemplateExtra(decoded);
  }

  String? encode() => raw.isEmpty ? null : jsonEncode(raw);
}

/// Pure snapshot of a stored `record_template` row for domain resolution.
final class TemplateSnapshot {
  const TemplateSnapshot({
    required this.id,
    required this.type,
    required this.moneyMinor,
    required this.feeMinor,
    required this.bookId,
    this.recordCatId,
    this.assetId = noRef,
    this.assetId2 = noRef,
    this.remark,
    this.autoSave = false,
    this.excludeBudget = false,
    this.excludeExIn = false,
    this.tags,
    this.exi,
  });

  final int id;
  final int type;
  final BigInt moneyMinor;
  final BigInt feeMinor;
  final int bookId;
  final int? recordCatId;
  final int assetId;
  final int assetId2;
  final String? remark;
  final bool autoSave;
  final bool excludeBudget;
  final bool excludeExIn;
  final String? tags;
  final String? exi;
}

/// Pure category metadata for validating/resolving a template's category.
final class TemplateCategoryRef {
  const TemplateCategoryRef({
    required this.id,
    required this.name,
    required this.type,
    required this.bookId,
    this.parentCatId = noRef,
    this.isHide = false,
  });

  final int id;
  final String name;
  final int type;
  final int bookId;
  final int parentCatId;
  final bool isHide;
}

/// Pure account metadata for validating/resolving a template's account(s).
final class TemplateAssetRef {
  const TemplateAssetRef({
    required this.id,
    required this.name,
    required this.type,
    required this.status,
    this.currency,
  });

  final int id;
  final String name;
  final int type;
  final int status;
  final String? currency;

  bool get isUsableForTemplate =>
      type != AssetType.debt && status != AssetStatus.settled;
}

/// Resolved prefill payload for `RecordEditorPage` (`F-016` R3).
final class TemplatePrefill {
  const TemplatePrefill({
    required this.templateId,
    this.name,
    required this.displayTitle,
    required this.type,
    required this.bookId,
    required this.bookExists,
    required this.moneyMinor,
    required this.feeMinor,
    required this.feeFromTarget,
    required this.categoryId,
    required this.parentCategoryId,
    required this.assetId,
    required this.fromAssetId,
    required this.toAssetId,
    required this.remark,
    required this.excludeBudget,
    required this.excludeExIn,
    required this.tagIds,
    this.sourceCurrency,
    required this.autoSave,
    required this.warnings,
    required this.hasDanglingReference,
  });

  final int templateId;
  final String? name;
  final String displayTitle;
  final int type;
  final int bookId;
  final bool bookExists;
  final BigInt moneyMinor;
  final BigInt feeMinor;
  final bool feeFromTarget;

  /// Resolved category ID (`null` for transfer or when missing/invalid).
  final int? categoryId;

  /// Top-level category ID for two-tier category pickers.
  final int? parentCategoryId;

  /// Funding account ID for single-account forms (`expense`, `income`,
  /// `reimbursable`, `advanceIncome`, `advanceExpense`), or `noRef`.
  final int assetId;

  /// Source account ID for `transfer` forms, or `noRef`.
  final int fromAssetId;

  /// Target account ID for `transfer` forms, or `noRef`.
  final int toAssetId;

  final String remark;
  final bool excludeBudget;
  final bool excludeExIn;
  final List<String> tagIds;
  final String? sourceCurrency;
  final bool autoSave;
  final List<String> warnings;
  final bool hasDanglingReference;

  Money get money => Money.minor(moneyMinor);
  Money get fee => Money.minor(feeMinor);

  String get amountText =>
      moneyMinor <= BigInt.zero ? '' : Money.minor(moneyMinor).decimal;

  String get feeText =>
      feeMinor <= BigInt.zero ? '' : Money.minor(feeMinor).decimal;

  /// Exact `RecordDraft.assetId` column mapping (`reimbursable` uses `fromAssetId`).
  int get draftAssetId =>
      (type == RecordType.transfer || type == RecordType.reimbursable)
      ? noRef
      : assetId;

  /// Exact `RecordDraft.fromAssetId` column mapping.
  int get draftFromAssetId => type == RecordType.transfer
      ? fromAssetId
      : (type == RecordType.reimbursable ? assetId : noRef);

  /// Exact `RecordDraft.toAssetId` column mapping.
  int get draftToAssetId => type == RecordType.transfer ? toAssetId : noRef;

  /// Whether this template can be saved directly via `LedgerService.saveRecord`
  /// without further user edits.
  bool get canInstantSave {
    if (!isSupportedTemplateType(type) || !bookExists || hasDanglingReference) {
      return false;
    }
    if (moneyMinor.isNegative || moneyMinor > maxTemplateAmountMinor) {
      return false;
    }
    if (templateRequiresPositiveAmount(type) && moneyMinor <= BigInt.zero) {
      return false;
    }
    if (type == RecordType.transfer) {
      return fromAssetId != noRef &&
          toAssetId != noRef &&
          fromAssetId != toAssetId &&
          !feeMinor.isNegative;
    }
    return categoryId != null && categoryId != noRef;
  }
}

/// Resolves a stored [TemplateSnapshot] against live books, categories, assets,
/// and active tag IDs, gracefully falling back to empty selections when
/// referenced entities were deleted or closed (`F-016` R3 / `SAFE-TM-01`).
TemplatePrefill resolveTemplatePrefill({
  required TemplateSnapshot template,
  required bool bookExists,
  required Map<int, TemplateCategoryRef> categoriesById,
  required Map<int, TemplateAssetRef> assetsById,
  required Set<String> validTagIds,
}) {
  final extra = TemplateExtra.parse(template.exi);
  final warnings = <String>[];
  var dangling = false;

  if (!bookExists) {
    warnings.add('模板关联的账本已不存在');
    dangling = true;
  }

  int? resolvedCatId;
  int? resolvedParentCatId;
  String? resolvedCatName;

  if (template.type != RecordType.transfer) {
    final rawCatId = template.recordCatId ?? noRef;
    if (rawCatId != noRef) {
      final cat = categoriesById[rawCatId];
      final wantType = isSupportedTemplateType(template.type)
          ? templateCategoryTypeFor(template.type)
          : null;
      if (cat == null ||
          cat.isHide ||
          cat.bookId != template.bookId ||
          (wantType != null && cat.type != wantType)) {
        warnings.add('原分类已删除或不可用，请重新选择分类');
        dangling = true;
      } else {
        resolvedCatId = cat.id;
        resolvedCatName = cat.name;
        resolvedParentCatId = cat.parentCatId == noRef
            ? cat.id
            : cat.parentCatId;
      }
    }
  }

  int resolveAsset(int rawId, String label) {
    if (rawId == noRef) return noRef;
    final asset = assetsById[rawId];
    if (asset == null) {
      warnings.add('原$label已删除，已回退为未选账户');
      dangling = true;
      return noRef;
    }
    if (!asset.isUsableForTemplate) {
      warnings.add('原$label已结清或不可用，已回退为未选账户');
      dangling = true;
      return noRef;
    }
    return asset.id;
  }

  var resolvedAssetId = noRef;
  var resolvedFromId = noRef;
  var resolvedToId = noRef;
  if (template.type == RecordType.transfer) {
    resolvedFromId = resolveAsset(template.assetId, '转出账户');
    resolvedToId = resolveAsset(template.assetId2, '转入账户');
    if (resolvedFromId != noRef && resolvedFromId == resolvedToId) {
      warnings.add('转出与转入账户相同，请重新选择转入账户');
      dangling = true;
      resolvedToId = noRef;
    }
  } else {
    resolvedAssetId = resolveAsset(template.assetId, '账户');
  }

  final rawTags = parseTemplateTagsCsv(template.tags);
  final resolvedTags = <String>[
    for (final id in rawTags)
      if (validTagIds.contains(id)) id,
  ];

  final cleanRemark = (template.remark ?? '').trim();
  final customName = extra.name;
  final displayTitle =
      customName ??
      (cleanRemark.isNotEmpty
          ? cleanRemark
          : (resolvedCatName ?? templateTypeLabel(template.type)));

  return TemplatePrefill(
    templateId: template.id,
    name: customName,
    displayTitle: displayTitle,
    type: template.type,
    bookId: template.bookId,
    bookExists: bookExists,
    moneyMinor: template.moneyMinor,
    feeMinor: template.type == RecordType.transfer
        ? template.feeMinor
        : BigInt.zero,
    feeFromTarget: template.type == RecordType.transfer && extra.feeFromTarget,
    categoryId: resolvedCatId,
    parentCategoryId: resolvedParentCatId,
    assetId: resolvedAssetId,
    fromAssetId: resolvedFromId,
    toAssetId: resolvedToId,
    remark: cleanRemark,
    excludeBudget:
        template.type != RecordType.transfer && template.excludeBudget,
    excludeExIn: template.type != RecordType.transfer && template.excludeExIn,
    tagIds: List<String>.unmodifiable(resolvedTags),
    sourceCurrency: template.type == RecordType.transfer
        ? null
        : extra.sourceCurrency,
    autoSave: template.autoSave,
    warnings: List<String>.unmodifiable(warnings),
    hasDanglingReference: dangling,
  );
}

// ---- Frequent Remarks Rules (F-016 R4) ----

/// Validates and trims remark content.
String normalizeRemarkContent(String raw, {bool allowEmpty = false}) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    if (allowEmpty) return '';
    throw const Failure(FailureCode.validation, '备注内容不能为空');
  }
  if (trimmed.length > maxRemarkLength) {
    throw const Failure(FailureCode.validation, '常用备注不能超过 $maxRemarkLength 字');
  }
  return trimmed;
}

/// Filters remarks matching `recordCatId == categoryId` or `-1` (`noRef`),
/// sorted strictly by `usedTimes DESC, id DESC` (`F-016` R4).
List<T> filterAndSortRemarksForCategory<T>(
  Iterable<T> remarks, {
  required int categoryId,
  required int Function(T) recordCatIdOf,
  required int Function(T) usedTimesOf,
  required int Function(T) idOf,
}) {
  final matched = <T>[
    for (final item in remarks)
      if (recordCatIdOf(item) == categoryId || recordCatIdOf(item) == noRef)
        item,
  ];
  matched.sort((a, b) {
    final byUsed = usedTimesOf(b).compareTo(usedTimesOf(a));
    if (byUsed != 0) return byUsed;
    return idOf(b).compareTo(idOf(a));
  });
  return matched;
}

// ---- Bank Card Memo Folder Rules (F-023 R5) ----

/// `bank_card.card_type` codes (`0` 储蓄卡, `1` 信用卡).
abstract final class BankCardType {
  static const debit = 0; // 储蓄卡
  static const credit = 1; // 信用卡

  static const labels = <int, String>{debit: '储蓄卡', credit: '信用卡'};

  static bool isValid(int type) => type == debit || type == credit;
  static String labelOf(int type) => labels[type] ?? '银行卡';
}

/// Preset card colors `(hex, label)` for `bank_card.card_color`.
const List<(String, String)> presetBankCardColors = <(String, String)>[
  ('#1565C0', '深海蓝'),
  ('#00796B', '翡翠绿'),
  ('#C62828', '丹霞红'),
  ('#EF6C00', '琥珀橙'),
  ('#5E35B1', '暮光紫'),
  ('#37474F', '石墨灰'),
];

/// Strips spaces, tabs, newlines, and `-` separators from a card number string.
String stripCardSeparators(String raw) =>
    raw.replaceAll(RegExp(r'[\s\-]+'), '');

/// Normalizes and validates a user-entered bank card number to pure ASCII digits
/// (`8..30` digits).
String normalizeBankCardNumber(String raw) {
  final cleaned = stripCardSeparators(raw);
  if (cleaned.isEmpty) {
    throw const Failure(FailureCode.validation, '请输入银行卡号');
  }
  if (!RegExp(r'^[0-9]+$').hasMatch(cleaned)) {
    throw const Failure(FailureCode.validation, '卡号只能包含数字、空格或连字符');
  }
  if (cleaned.length < minBankCardDigits ||
      cleaned.length > maxBankCardDigits) {
    throw const Failure(
      FailureCode.validation,
      '卡号长度须为 $minBankCardDigits–$maxBankCardDigits 位数字',
    );
  }
  return cleaned;
}

/// Formats a card number into 4-character groups separated by spaces
/// (e.g. `"6222021234567890"` -> `"6222 0212 3456 7890"`).
String formatCardNumberGrouped(String raw) {
  final cleaned = stripCardSeparators(raw);
  if (cleaned.isEmpty) return '';
  final buffer = StringBuffer();
  for (var i = 0; i < cleaned.length; i++) {
    if (i > 0 && i % 4 == 0) buffer.write(' ');
    buffer.write(cleaned[i]);
  }
  return buffer.toString();
}

/// Formats a card number in masked form (`"**** 1234"`).
String formatCardNumberMasked(String raw) {
  final cleaned = stripCardSeparators(raw);
  if (cleaned.isEmpty) return '****';
  if (cleaned.length <= 4) return '**** $cleaned';
  return '**** ${cleaned.substring(cleaned.length - 4)}';
}

/// Pure ISO/IEC 7812 Luhn mod-10 check. Never throws; informational only.
bool isValidLuhn(String raw) {
  final cleaned = stripCardSeparators(raw);
  if (cleaned.length < 2 || !RegExp(r'^[0-9]+$').hasMatch(cleaned)) {
    return false;
  }
  var allZero = true;
  var sum = 0;
  for (var i = cleaned.length - 1; i >= 0; i--) {
    final digit = cleaned.codeUnitAt(i) - 0x30;
    if (digit != 0) allZero = false;
    final fromRight = cleaned.length - 1 - i;
    if (fromRight.isOdd) {
      final doubled = digit * 2;
      sum += doubled > 9 ? doubled - 9 : doubled;
    } else {
      sum += digit;
    }
  }
  if (allZero) return false;
  return sum % 10 == 0;
}

/// Informational Luhn inspection status for UI badges.
final class CardLuhnStatus {
  const CardLuhnStatus({
    required this.digitCount,
    required this.isAllDigits,
    required this.passesLuhn,
  });

  final int digitCount;
  final bool isAllDigits;
  final bool passesLuhn;

  bool get isCheckApplicable => isAllDigits && digitCount >= minBankCardDigits;

  String get badgeLabel {
    if (!isAllDigits || digitCount == 0) return '待输入卡号';
    if (digitCount < minBankCardDigits) return '位数不足';
    return passesLuhn ? 'Luhn 校验通过' : '非标准校验号（仍可保存）';
  }
}

CardLuhnStatus inspectCardLuhn(String raw) {
  final cleaned = stripCardSeparators(raw);
  if (cleaned.isEmpty) {
    return const CardLuhnStatus(
      digitCount: 0,
      isAllDigits: false,
      passesLuhn: false,
    );
  }
  final allDigits = RegExp(r'^[0-9]+$').hasMatch(cleaned);
  return CardLuhnStatus(
    digitCount: cleaned.length,
    isAllDigits: allDigits,
    passesLuhn: allDigits && isValidLuhn(cleaned),
  );
}

/// Validates and normalizes an optional hex card color (`#RRGGBB` or `#AARRGGBB`).
String? normalizeCardColorHex(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final withHash = trimmed.startsWith('#') ? trimmed : '#$trimmed';
  if (!RegExp(r'^#(?:[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$').hasMatch(withHash)) {
    throw const Failure(FailureCode.validation, '卡片颜色格式无效');
  }
  return withHash.toUpperCase();
}

/// Validates and trims `bank_card.card_name`.
String normalizeBankCardName(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty || trimmed.length > maxBankCardNameLength) {
    throw const Failure(
      FailureCode.validation,
      '卡片名称须为 1–$maxBankCardNameLength 字',
    );
  }
  return trimmed;
}

/// Validates and trims `bank_card.card_owner`.
String normalizeBankCardOwner(String raw) {
  final trimmed = raw.trim();
  if (trimmed.length > maxBankCardOwnerLength) {
    throw const Failure(
      FailureCode.validation,
      '持卡人姓名不能超过 $maxBankCardOwnerLength 字',
    );
  }
  return trimmed;
}

/// Validates and trims `bank_card.remark`.
String normalizeBankCardRemark(String raw) {
  final trimmed = raw.trim();
  if (trimmed.length > maxBankCardRemarkLength) {
    throw const Failure(
      FailureCode.validation,
      '卡片备注不能超过 $maxBankCardRemarkLength 字',
    );
  }
  return trimmed;
}

/// Formats complete bank card memo info for copying to `Clipboard`.
String formatBankCardFullInfo({
  required String cardName,
  required int cardType,
  required String cardNo,
  String cardOwner = '',
  String remark = '',
  String? linkedAssetName,
}) {
  final lines = <String>[
    '$cardName（${BankCardType.labelOf(cardType)}）',
    '卡号：${formatCardNumberGrouped(cardNo)}',
  ];
  final owner = cardOwner.trim();
  if (owner.isNotEmpty) {
    lines.add('持卡人：$owner');
  }
  final asset = linkedAssetName?.trim() ?? '';
  if (asset.isNotEmpty) {
    lines.add('关联账户：$asset');
  }
  final note = remark.trim();
  if (note.isNotEmpty) {
    lines.add('备注：$note');
  }
  return lines.join('\n');
}
