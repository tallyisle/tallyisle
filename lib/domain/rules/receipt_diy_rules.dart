import 'dart:convert';

import '../../core/failure.dart';
import '../../core/money.dart';
import '../ledger/record_extra.dart';
import '../model/codes.dart';

// ---------------------------------------------------------------------------
// F-022: Bill Image Attachment Path & CSV/JSON Rules
// ---------------------------------------------------------------------------

const int maxBillImages = 9;
const int maxAttachmentFileNameLength = 180;

/// Validates a single relative attachment filename under `<support>/attachments/`.
///
/// Strictly rejects empty strings, path traversal (`..`), path separators (`/`
/// or `\`), drive colons (`:`), leading dots, `.tmp` staging suffixes, and
/// ASCII control characters (R5).
String validateAttachmentFileName(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    throw const Failure(FailureCode.validation, '图片附件文件名不能为空');
  }
  if (trimmed.length > maxAttachmentFileNameLength) {
    throw const Failure(FailureCode.validation, '图片附件文件名过长');
  }
  if (trimmed.contains('/') ||
      trimmed.contains(r'\') ||
      trimmed.contains('..') ||
      trimmed.contains(':') ||
      trimmed.startsWith('.')) {
    throw Failure(FailureCode.validation, '非法的图片附件路径：$trimmed');
  }
  if (trimmed.toLowerCase().endsWith('.tmp')) {
    throw Failure(FailureCode.validation, '临时文件不能作为正式图片附件：$trimmed');
  }
  for (final code in trimmed.codeUnits) {
    if (code < 32 || code == 127) {
      throw const Failure(FailureCode.validation, '图片附件文件名包含非法控制字符');
    }
  }
  return trimmed;
}

/// Parses `record.images` (comma-joined string or legacy `[{"fname":...}]` JSON)
/// into up to [maxBillImages] safe relative filenames (R5).
List<String> parseRecordImages(String? raw) {
  if (raw == null) return const <String>[];
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return const <String>[];

  final candidates = <String>[];
  if (trimmed.startsWith('[')) {
    final Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException {
      throw const Failure(FailureCode.validation, '账单图片字段 JSON 格式损坏');
    }
    if (decoded is! List) {
      throw const Failure(FailureCode.validation, '账单图片字段必须为列表');
    }
    for (final item in decoded) {
      if (item == null) continue;
      if (item is String) {
        if (item.trim().isNotEmpty) candidates.add(item);
      } else if (item is Map) {
        final fname = item['fname'] ?? item['fileName'] ?? item['name'];
        if (fname is String && fname.trim().isNotEmpty) {
          candidates.add(fname);
        } else {
          throw const Failure(FailureCode.validation, '账单图片对象缺少有效文件名');
        }
      } else {
        throw const Failure(FailureCode.validation, '账单图片条目类型无效');
      }
    }
  } else {
    for (final part in trimmed.split(',')) {
      if (part.trim().isNotEmpty) {
        candidates.add(part);
      }
    }
  }

  final seen = <String>{};
  final result = <String>[];
  for (final c in candidates) {
    final safe = validateAttachmentFileName(c);
    if (seen.add(safe)) {
      result.add(safe);
    }
  }
  if (result.length > maxBillImages) {
    throw const Failure(FailureCode.validation, '单笔账单最多添加 9 张图片');
  }
  return List<String>.unmodifiable(result);
}

/// Encodes up to [maxBillImages] validated relative filenames into `record.images`
/// storage format (`null` when empty, comma-joined otherwise) (R5).
String? encodeRecordImages(Iterable<String> fileNames) {
  final seen = <String>{};
  final cleaned = <String>[];
  for (final name in fileNames) {
    final safe = validateAttachmentFileName(name);
    if (seen.add(safe)) {
      cleaned.add(safe);
    }
  }
  if (cleaned.length > maxBillImages) {
    throw const Failure(FailureCode.validation, '单笔账单最多添加 9 张图片');
  }
  return cleaned.isEmpty ? null : cleaned.join(',');
}

/// Collects safe filenames referenced across `record.images`, `record_period.images`,
/// and `installment.images` (ignoring corrupt rows only on explicit lenient scan
/// while keeping any raw token conservative so valid files are never misdeleted).
Set<String> collectReferencedAttachmentNames(
  Iterable<String?> rawImageColumns,
) {
  final referenced = <String>{};
  for (final raw in rawImageColumns) {
    if (raw == null || raw.trim().isEmpty) continue;
    try {
      referenced.addAll(parseRecordImages(raw));
    } on Failure {
      // Conservative fallback: keep any raw comma token so a malformed row with
      // >9 images never causes live files to be treated as orphans.
      for (final token in raw.split(',')) {
        final t = token.trim();
        if (t.isNotEmpty) referenced.add(t);
      }
    }
  }
  return referenced;
}

/// Computes unreferenced attachment filenames present on disk (R5).
List<String> computeOrphanAttachmentNames({
  required Iterable<String> filesOnDisk,
  required Iterable<String?> referencedImageColumns,
}) {
  final referenced = collectReferencedAttachmentNames(referencedImageColumns);
  final orphans = <String>[];
  for (final name in filesOnDisk) {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.toLowerCase().endsWith('.tmp')) continue;
    if (!referenced.contains(trimmed)) {
      orphans.add(trimmed);
    }
  }
  orphans.sort();
  return orphans;
}

// ---------------------------------------------------------------------------
// F-036: BillLocationInfo (`RecordExtra.raw['loc']`)
// ---------------------------------------------------------------------------

const _corruptLocation = Failure(FailureCode.corruptData, '账单位置信息格式损坏');

double? _parseOptionalCoord(
  Object? raw, {
  required double min,
  required double max,
  required String label,
}) {
  if (raw == null) return null;
  final double? val = switch (raw) {
    num n => n.toDouble(),
    String s when s.trim().isEmpty => null,
    String s => double.tryParse(s.trim()),
    _ => throw _corruptLocation,
  };
  if (val == null) {
    if (raw is String && raw.trim().isNotEmpty) {
      throw Failure(FailureCode.validation, '$label格式无效');
    }
    return null;
  }
  if (!val.isFinite || val < min || val > max) {
    throw Failure(FailureCode.validation, '$label超出有效范围（$min..$max）');
  }
  return val;
}

/// Geographic / place annotation stored in `record.extra_info.loc` (F-036, R6).
final class BillLocationInfo {
  BillLocationInfo({
    String name = '',
    String simpleName = '',
    this.latitude,
    this.longitude,
  }) : name = name.trim(),
       simpleName = simpleName.trim() {
    if (this.name.length > 200 || this.simpleName.length > 100) {
      throw const Failure(FailureCode.validation, '地点名称过长');
    }
    if ((latitude == null) != (longitude == null)) {
      throw const Failure(FailureCode.validation, '经纬度必须同时填写或同时留空');
    }
    if (latitude != null) {
      if (!latitude!.isFinite || latitude! < -90 || latitude! > 90) {
        throw const Failure(FailureCode.validation, '纬度须在 -90 到 90 之间');
      }
    }
    if (longitude != null) {
      if (!longitude!.isFinite || longitude! < -180 || longitude! > 180) {
        throw const Failure(FailureCode.validation, '经度须在 -180 到 180 之间');
      }
    }
  }

  final String name;
  final String simpleName;
  final double? latitude;
  final double? longitude;

  bool get isEmpty =>
      name.isEmpty &&
      simpleName.isEmpty &&
      latitude == null &&
      longitude == null;

  String get displayLabel {
    if (simpleName.isNotEmpty) return simpleName;
    if (name.isNotEmpty) return name;
    if (latitude != null && longitude != null) {
      return '${latitude!.toStringAsFixed(4)}, ${longitude!.toStringAsFixed(4)}';
    }
    return '';
  }

  String? get detailAddress =>
      simpleName.isNotEmpty && name.isNotEmpty && name != simpleName
      ? name
      : null;

  Map<String, Object> toJson() => {
    'name': name,
    'simpleName': simpleName,
    if (latitude != null) 'latitude': latitude!,
    if (longitude != null) 'longitude': longitude!,
  };

  static BillLocationInfo? fromJson(Object? json) {
    if (json == null) return null;
    if (json is! Map) throw _corruptLocation;
    final rawName = json['name'] ?? json['address'] ?? '';
    final rawSimple = json['simpleName'] ?? json['simple_name'] ?? '';
    if (rawName is! String || rawSimple is! String) {
      throw _corruptLocation;
    }
    final lat = _parseOptionalCoord(
      json['latitude'] ?? json['lat'],
      min: -90,
      max: 90,
      label: '纬度',
    );
    final lng = _parseOptionalCoord(
      json['longitude'] ?? json['lng'] ?? json['lon'],
      min: -180,
      max: 180,
      label: '经度',
    );
    if ((lat == null) != (lng == null)) {
      // Tolerate partial legacy coords by dropping unpaired coordinate if text exists.
      if (rawName.trim().isEmpty && rawSimple.trim().isEmpty) {
        return null;
      }
      return BillLocationInfo(name: rawName, simpleName: rawSimple);
    }
    final info = BillLocationInfo(
      name: rawName,
      simpleName: rawSimple,
      latitude: lat,
      longitude: lng,
    );
    return info.isEmpty ? null : info;
  }

  @override
  bool operator ==(Object other) =>
      other is BillLocationInfo &&
      other.name == name &&
      other.simpleName == simpleName &&
      other.latitude == latitude &&
      other.longitude == longitude;

  @override
  int get hashCode => Object.hash(name, simpleName, latitude, longitude);
}

/// Typed `loc` accessor on [RecordExtra] without mutating unknown keys (F-036).
extension RecordExtraLocation on RecordExtra {
  BillLocationInfo? get location => BillLocationInfo.fromJson(raw['loc']);

  set location(BillLocationInfo? value) {
    if (value == null || value.isEmpty) {
      raw.remove('loc');
    } else {
      raw['loc'] = value.toJson();
    }
  }
}

// ---------------------------------------------------------------------------
// F-036: DiyToolbarConfig (`ti_preference` key `record_diy_toolbar`)
// ---------------------------------------------------------------------------

const String prefKeyRecordDiyToolbar = 'record_diy_toolbar';

enum DiyToolbarAction {
  tags('tags', '标签', '为账单绑定一个或多个分类标签'),
  images('images', '图片', '添加最多 9 张小票或实物照片附件'),
  discount('discount', '优惠', '记录立减、红包或满减优惠金额'),
  location('location', '位置', '记录消费地点简称与详细地址'),
  excludeBudget('exclude_budget', '不计入预算', '开启后本笔账单不占用当期预算额度'),
  excludeExIn('exclude_ex_in', '不计入收支', '开启后本笔账单不计入月度/年度收支统计'),
  currency('currency', '多币种', '选择外币录入并按汇率折算入账金额'),
  templates('templates', '模板', '从常用记账模板快速填充账单内容');

  const DiyToolbarAction(this.key, this.label, this.description);
  final String key;
  final String label;
  final String description;

  static DiyToolbarAction? fromKey(String key) {
    for (final a in values) {
      if (a.key == key) return a;
    }
    return null;
  }
}

final class DiyToolbarItem {
  const DiyToolbarItem({required this.action, this.enabled = true});

  final DiyToolbarAction action;
  final bool enabled;

  DiyToolbarItem copyWith({bool? enabled}) =>
      DiyToolbarItem(action: action, enabled: enabled ?? this.enabled);

  Map<String, Object> toJson() => {'key': action.key, 'enabled': enabled};

  @override
  bool operator ==(Object other) =>
      other is DiyToolbarItem &&
      other.action == action &&
      other.enabled == enabled;

  @override
  int get hashCode => Object.hash(action, enabled);
}

/// Customizable order & visibility of record-editor toolbar buttons (F-036, R6).
final class DiyToolbarConfig {
  DiyToolbarConfig._(List<DiyToolbarItem> items)
    : items = List<DiyToolbarItem>.unmodifiable(items);

  factory DiyToolbarConfig.defaults() => DiyToolbarConfig._([
    for (final action in DiyToolbarAction.values)
      DiyToolbarItem(action: action, enabled: true),
  ]);

  factory DiyToolbarConfig.normalize(Iterable<DiyToolbarItem> rawItems) {
    final seen = <DiyToolbarAction>{};
    final normalized = <DiyToolbarItem>[];
    for (final item in rawItems) {
      if (seen.add(item.action)) {
        normalized.add(item);
      }
    }
    for (final action in DiyToolbarAction.values) {
      if (seen.add(action)) {
        normalized.add(DiyToolbarItem(action: action, enabled: true));
      }
    }
    return DiyToolbarConfig._(normalized);
  }

  final List<DiyToolbarItem> items;

  List<DiyToolbarAction> get visibleActions => [
    for (final item in items)
      if (item.enabled) item.action,
  ];

  bool isEnabled(DiyToolbarAction action) =>
      items.firstWhere((e) => e.action == action).enabled;

  DiyToolbarConfig setEnabled(DiyToolbarAction action, bool enabled) =>
      DiyToolbarConfig._([
        for (final item in items)
          if (item.action == action) item.copyWith(enabled: enabled) else item,
      ]);

  /// Reorders items using `ReorderableListView`'s `(oldIndex, newIndex)` convention.
  DiyToolbarConfig reorderForListView(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= items.length) {
      throw const Failure(FailureCode.validation, '工具栏原序号越界');
    }
    var target = newIndex;
    if (target > oldIndex) target -= 1;
    target = target.clamp(0, items.length - 1);
    return moveItem(oldIndex, target);
  }

  /// Moves item at [fromIndex] directly to [toIndex].
  DiyToolbarConfig moveItem(int fromIndex, int toIndex) {
    if (fromIndex < 0 ||
        fromIndex >= items.length ||
        toIndex < 0 ||
        toIndex >= items.length) {
      throw const Failure(FailureCode.validation, '工具栏排序位置无效');
    }
    if (fromIndex == toIndex) return this;
    final next = items.toList();
    final moved = next.removeAt(fromIndex);
    next.insert(toIndex, moved);
    return DiyToolbarConfig._(next);
  }

  Map<String, Object> toJson() => {
    'version': 1,
    'items': [for (final item in items) item.toJson()],
  };

  String encode() => jsonEncode(toJson());

  static DiyToolbarConfig decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return DiyToolbarConfig.defaults();
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return DiyToolbarConfig.defaults();
    }
    final List<Object?>? rawList = switch (decoded) {
      Map m when m['items'] is List => m['items'] as List<Object?>,
      List l => l,
      _ => null,
    };
    if (rawList == null) return DiyToolbarConfig.defaults();

    final parsed = <DiyToolbarItem>[];
    for (final entry in rawList) {
      if (entry is Map) {
        final key = entry['key'];
        if (key is! String) continue;
        final action = DiyToolbarAction.fromKey(key.trim());
        if (action == null) continue;
        final enabled = entry['enabled'] is bool
            ? entry['enabled'] as bool
            : true;
        parsed.add(DiyToolbarItem(action: action, enabled: enabled));
      } else if (entry is String) {
        final action = DiyToolbarAction.fromKey(entry.trim());
        if (action != null) {
          parsed.add(DiyToolbarItem(action: action, enabled: true));
        }
      }
    }
    return DiyToolbarConfig.normalize(parsed);
  }
}

// ---------------------------------------------------------------------------
// F-036: Paper Receipt Pure Formatting Model (`RecordReceiptDialog`)
// ---------------------------------------------------------------------------

final class ReceiptLineItem {
  const ReceiptLineItem(this.label, this.value);
  final String label;
  final String value;
}

final class ReceiptViewModel {
  const ReceiptViewModel({
    required this.typeTitle,
    required this.amountText,
    required this.currencyCode,
    required this.serialNo,
    required this.dateTimeText,
    required this.lines,
    required this.remark,
    required this.flags,
    required this.brandStamp,
    required this.suggestedFileName,
  });

  final String typeTitle;
  final String amountText;
  final String currencyCode;
  final String serialNo;
  final String dateTimeText;
  final List<ReceiptLineItem> lines;
  final String remark;
  final List<String> flags;
  final String brandStamp;
  final String suggestedFileName;
}

/// Builds a pure receipt view-model using exact [Money] (`BigInt`) formatting (R6).
ReceiptViewModel buildReceiptViewModel({
  required String recordId,
  required int type,
  required int subType,
  required BigInt moneyMinor,
  BigInt? discountMinor,
  required int recordTimeMs,
  required String bookName,
  required String categoryLabel,
  required String accountLabel,
  String currencyCode = 'CNY',
  String remark = '',
  bool excludeBudget = false,
  bool excludeExIn = false,
  List<String> tagNames = const [],
  RecordExtra? extra,
  int attachmentCount = 0,
}) {
  final effectiveExtra = extra ?? RecordExtra();
  final code = currencyCode.trim().isEmpty
      ? 'CNY'
      : currencyCode.trim().toUpperCase();

  final isRefund =
      (type == RecordType.expense || type == RecordType.income) &&
      moneyMinor < BigInt.zero;
  final typeName = isRefund
      ? (type == RecordType.expense ? '支出退款' : '收入冲回')
      : '${RecordType.names[type] ?? '账单'}小票';

  final absAmount = Money.minor(moneyMinor.abs(), code).decimal;
  final String prefix = switch (type) {
    RecordType.expense when moneyMinor < BigInt.zero => '+',
    RecordType.income when moneyMinor < BigInt.zero => '-',
    RecordType.expense ||
    RecordType.reimbursable ||
    RecordType.fee ||
    RecordType.installmentPrincipal ||
    RecordType.advanceExpense => '-',
    RecordType.income ||
    RecordType.reimburseReceipt ||
    RecordType.depositInterest ||
    RecordType.advanceIncome => '+',
    RecordType.debtInterest ||
    RecordType.reimburseDiff => subType == RecordDirection.income ? '+' : '-',
    RecordType.balanceAdjust => moneyMinor.isNegative ? '-' : '+',
    _ => '',
  };
  final amountText = '$prefix$absAmount';

  final dt = DateTime.fromMillisecondsSinceEpoch(recordTimeMs);
  String two(int v) => v.toString().padLeft(2, '0');
  final dateTimeText =
      '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';

  final lines = <ReceiptLineItem>[
    ReceiptLineItem('账本', bookName.trim().isEmpty ? '日常账本' : bookName.trim()),
  ];
  if (requiredCategoryTypeFromReceipt(type) != null ||
      (categoryLabel.trim().isNotEmpty && categoryLabel.trim() != '未分类')) {
    lines.add(
      ReceiptLineItem(
        '分类',
        categoryLabel.trim().isEmpty ? '未分类' : categoryLabel.trim(),
      ),
    );
  }
  if (accountLabel.trim().isNotEmpty) {
    lines.add(ReceiptLineItem('账户', accountLabel.trim()));
  }
  if (discountMinor != null && discountMinor > BigInt.zero) {
    final gross = Money.minor(moneyMinor.abs() + discountMinor, code).decimal;
    final disc = Money.minor(discountMinor, code).decimal;
    lines.add(ReceiptLineItem('原价 / 优惠', '$gross / -$disc'));
  }

  final fx = effectiveExtra.currency;
  if (fx != null && fx.isValid && fx.sourceCode.trim().toUpperCase() != code) {
    final srcCode = fx.sourceCode.trim().toUpperCase();
    final srcDec = Money.minor(fx.sourceGross.abs(), 'CNY').decimal;
    lines.add(ReceiptLineItem('外币原额', '$srcCode $srcDec'));
  }

  final loc = effectiveExtra.location;
  if (loc != null && !loc.isEmpty) {
    final detail = loc.detailAddress;
    lines.add(
      ReceiptLineItem(
        '地点',
        detail == null ? loc.displayLabel : '${loc.displayLabel}（$detail）',
      ),
    );
  }
  if (tagNames.isNotEmpty) {
    lines.add(ReceiptLineItem('标签', tagNames.map((t) => '#$t').join(' ')));
  }
  if (attachmentCount > 0) {
    lines.add(ReceiptLineItem('图片附件', '$attachmentCount 张'));
  }

  final flags = <String>[if (excludeBudget) '不计入预算', if (excludeExIn) '不计入收支'];

  final compactId = recordId.replaceAll('-', '').toUpperCase();
  final serialSuffix = compactId.length > 8
      ? compactId.substring(0, 8)
      : compactId.padLeft(8, '0');

  return ReceiptViewModel(
    typeTitle: typeName,
    amountText: amountText,
    currencyCode: code,
    serialNo: 'NO.$serialSuffix',
    dateTimeText: dateTimeText,
    lines: lines,
    remark: remark.trim(),
    flags: flags,
    brandStamp: '帐屿 · TallyIsle',
    suggestedFileName: formatReceiptFileName(recordId, dt),
  );
}

int? requiredCategoryTypeFromReceipt(int type) => switch (type) {
  RecordType.expense ||
  RecordType.income ||
  RecordType.reimbursable ||
  RecordType.advanceIncome ||
  RecordType.advanceExpense => 0,
  _ => null,
};

String formatReceiptFileName(String recordId, DateTime when) {
  String two(int v) => v.toString().padLeft(2, '0');
  final cleanId = recordId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
  final shortId = cleanId.length > 8 ? cleanId.substring(0, 8) : cleanId;
  final y = when.year.toString().padLeft(4, '0');
  final m = two(when.month);
  final d = two(when.day);
  return 'receipt_${y}${m}${d}_${shortId.isEmpty ? 'bill' : shortId}.png';
}
