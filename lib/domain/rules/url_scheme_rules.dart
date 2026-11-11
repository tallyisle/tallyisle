import '../../core/failure.dart';
import '../../core/money.dart';
import '../model/codes.dart';

/// Maximum single bill amount accepted by URL Scheme (`88,888,888,888.00`).
final BigInt maxUrlSchemeAmountMinor = BigInt.parse('8888888888800');

/// Supported URL schemes (`BRAND-001` primary + original compatibility).
const Set<String> supportedUrlSchemes = {'tallyisle', 'yyjz'};

/// Semantic actions resolved from an incoming deep-link URI (`F-033`).
enum UrlSchemeAction {
  home,
  calendar,
  stat,
  newBill,
  addBill,
  internalReminder,
}

/// Validated parameters for a direct `addbill` execution (`F-033` R2/R3).
final class UrlAddBillParams {
  const UrlAddBillParams({
    required this.type,
    required this.money,
    this.discount,
    this.fee,
    this.feeFromTarget = false,
    this.bookRef,
    this.categoryRef,
    this.asset1Ref,
    this.asset2Ref,
    this.remark = '',
    this.recordTimeMs,
    this.excludeBudget = false,
    this.excludeExIn = false,
    this.tagRefs = const [],
  });

  final int type;

  /// Gross amount entered in the URL (`> 0`).
  final Money money;

  /// Optional discount for expense/income (`>= 0` and `<= money`).
  final Money? discount;

  /// Optional transfer fee (`>= 0`, `type == RecordType.transfer`).
  final Money? fee;
  final bool feeFromTarget;
  final String? bookRef;
  final String? categoryRef;
  final String? asset1Ref;
  final String? asset2Ref;
  final String remark;
  final int? recordTimeMs;
  final bool excludeBudget;
  final bool excludeExIn;
  final List<String> tagRefs;

  /// Net booked amount (`money - discount` for expense/income, `money` otherwise).
  Money get netMoney {
    final d = discount;
    if (d != null &&
        !d.isZero &&
        (type == RecordType.expense || type == RecordType.income)) {
      return money - d;
    }
    return money;
  }
}

/// Result of parsing a `tallyisle://` or `yyjz://` URI (`F-033` R1).
final class ParsedUrlSchemeCommand {
  const ParsedUrlSchemeCommand({
    required this.rawUri,
    required this.scheme,
    required this.action,
    this.targetRoute,
    this.addBill,
    this.year,
    this.month,
    this.bookRef,
  });

  final String rawUri;
  final String scheme;
  final UrlSchemeAction action;

  /// GoRouter path to navigate to when this URI is a navigation or `showsheet` action.
  final String? targetRoute;

  /// Direct ledger write payload when `action == UrlSchemeAction.addBill` and `showsheet` is false.
  final UrlAddBillParams? addBill;

  final int? year;
  final int? month;
  final String? bookRef;

  bool get writesDirectly => addBill != null;
}

/// Ready-to-use URL Scheme template shown in the in-app documentation & tester.
final class UrlSchemeTemplate {
  const UrlSchemeTemplate({
    required this.title,
    required this.description,
    required this.tallyIsleUri,
    required this.legacyUri,
  });

  final String title;
  final String description;
  final String tallyIsleUri;
  final String legacyUri;
}

const List<UrlSchemeTemplate> urlSchemeTemplates = [
  UrlSchemeTemplate(
    title: '打开首页明细',
    description: '直接拉起帐屿并定位至首页明细列表。',
    tallyIsleUri: 'tallyisle://home',
    legacyUri: 'yyjz://home',
  ),
  UrlSchemeTemplate(
    title: '打开日历视图',
    description: '直接进入月度收支日历页。',
    tallyIsleUri: 'tallyisle://calendar',
    legacyUri: 'yyjz://calendar',
  ),
  UrlSchemeTemplate(
    title: '打开统计总览（可指定年月）',
    description: '进入统计页，支持可选 year 与 month 参数。',
    tallyIsleUri: 'tallyisle://stat?year=2026&month=11',
    legacyUri: 'yyjz://stat?year=2026&month=11',
  ),
  UrlSchemeTemplate(
    title: '拉起新建记账页（预填参数）',
    description: '打开“记一笔”表单并预填金额与备注，确认后保存。',
    tallyIsleUri: 'tallyisle://newbill?type=0&money=25.50&remark=工作午餐',
    legacyUri: 'yyjz://newbill?type=0&money=25.50&remark=工作午餐',
  ),
  UrlSchemeTemplate(
    title: '直接记一笔支出（静默入账）',
    description: '按分类名/账户名或 ID 解析并通过账务引擎直接幂等入账。',
    tallyIsleUri:
        'tallyisle://addbill?type=0&money=18.50&category=餐饮&remark=瑞幸咖啡',
    legacyUri: 'yyjz://addbill?type=0&money=18.50&category=餐饮&remark=瑞幸咖啡',
  ),
  UrlSchemeTemplate(
    title: '直接记一笔转账（含手续费）',
    description: '在两个资金账户间记一笔转账，可选附带手续费。',
    tallyIsleUri:
        'tallyisle://addbill?type=2&money=1000.00&fee=1.00&asset1=储蓄卡&asset2=信用卡&remark=信用卡还款',
    legacyUri:
        'yyjz://addbill?type=2&money=1000.00&fee=1.00&asset1=储蓄卡&asset2=信用卡&remark=信用卡还款',
  ),
];

/// Parses a decimal money string into 2-decimal `Money` using `BigInt` (`HALF_UP`),
/// never touching `double` (`ADR-011`).
Money parseUrlMoney(
  String raw, {
  required String fieldLabel,
  bool allowZero = false,
  String currency = 'CNY',
}) {
  var cleaned = raw.trim();
  if (cleaned.startsWith('¥') || cleaned.startsWith('￥')) {
    cleaned = cleaned.substring(1).trim();
  } else if (cleaned.toUpperCase().startsWith('CNY') ||
      cleaned.toUpperCase().startsWith('RMB')) {
    cleaned = cleaned.substring(3).trim();
  }
  if (cleaned.endsWith('元')) {
    cleaned = cleaned.substring(0, cleaned.length - 1).trim();
  }
  cleaned = cleaned.replaceAll(',', '');
  if (cleaned.startsWith('+')) {
    cleaned = cleaned.substring(1).trim();
  }
  if (cleaned.isEmpty) {
    throw Failure(FailureCode.validation, '$fieldLabel不能为空');
  }
  if (cleaned.startsWith('.')) {
    cleaned = '0$cleaned';
  }
  if (cleaned.endsWith('.') && cleaned.length > 1) {
    cleaned = cleaned.substring(0, cleaned.length - 1);
  }
  final DecimalValue decimal;
  try {
    decimal = DecimalValue.parse(cleaned);
  } on Failure {
    throw Failure(FailureCode.validation, '$fieldLabel格式无效：$raw');
  }
  final minor = decimal.unitsAt(
    Money.ledgerScale,
    rounding: RoundingMode.halfUp,
  );
  if (minor.isNegative || (!allowZero && minor == BigInt.zero)) {
    throw Failure(
      FailureCode.validation,
      allowZero ? '$fieldLabel不能为负数' : '$fieldLabel须大于 0',
    );
  }
  if (minor > maxUrlSchemeAmountMinor) {
    throw Failure(FailureCode.validation, '$fieldLabel不能超过 88888888888.00');
  }
  return Money.minor(minor, currency);
}

/// Parses `type` parameter (numeric code or Chinese/English alias).
int parseUrlRecordType(String? raw) {
  final v = raw?.trim();
  if (v == null || v.isEmpty) return RecordType.expense;
  switch (v.toLowerCase()) {
    case '0':
    case '支出':
    case 'expense':
    case 'out':
      return RecordType.expense;
    case '1':
    case '收入':
    case 'income':
    case 'in':
      return RecordType.income;
    case '2':
    case '转账':
    case 'transfer':
      return RecordType.transfer;
    case '3':
    case '报销':
    case 'reimbursable':
    case 'reimburse':
      return RecordType.reimbursable;
    case '9':
    case '预收':
    case 'advance_income':
    case 'advanceincome':
      return RecordType.advanceIncome;
    case '16':
    case '预支':
    case 'advance_expense':
    case 'advanceexpense':
      return RecordType.advanceExpense;
    default:
      throw Failure(FailureCode.validation, '不支持的账单类型：$v');
  }
}

/// Parses flexible URL `datetime` parameter into local epoch milliseconds.
int? parseUrlDateTimeMs(String? raw) {
  final text = raw?.trim();
  if (text == null || text.isEmpty) return null;

  if (RegExp(r'^\d{13}$').hasMatch(text)) {
    return int.parse(text);
  }
  if (RegExp(r'^\d{10}$').hasMatch(text)) {
    return int.parse(text) * 1000;
  }

  final compact14 = RegExp(
    r'^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})$',
  ).firstMatch(text);
  if (compact14 != null) {
    return _validatedLocalDateTime(
      int.parse(compact14.group(1)!),
      int.parse(compact14.group(2)!),
      int.parse(compact14.group(3)!),
      int.parse(compact14.group(4)!),
      int.parse(compact14.group(5)!),
      int.parse(compact14.group(6)!),
      text,
    );
  }

  final compact12 = RegExp(
    r'^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})$',
  ).firstMatch(text);
  if (compact12 != null) {
    return _validatedLocalDateTime(
      int.parse(compact12.group(1)!),
      int.parse(compact12.group(2)!),
      int.parse(compact12.group(3)!),
      int.parse(compact12.group(4)!),
      int.parse(compact12.group(5)!),
      0,
      text,
    );
  }

  final compact8 = RegExp(r'^(\d{4})(\d{2})(\d{2})$').firstMatch(text);
  if (compact8 != null) {
    return _validatedLocalDateTime(
      int.parse(compact8.group(1)!),
      int.parse(compact8.group(2)!),
      int.parse(compact8.group(3)!),
      12,
      0,
      0,
      text,
    );
  }

  final standard = RegExp(
    r'^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})(?:[ T](\d{1,2}):(\d{1,2})(?::(\d{1,2}))?)?$',
  ).firstMatch(text);
  if (standard != null) {
    return _validatedLocalDateTime(
      int.parse(standard.group(1)!),
      int.parse(standard.group(2)!),
      int.parse(standard.group(3)!),
      standard.group(4) == null ? 12 : int.parse(standard.group(4)!),
      standard.group(5) == null ? 0 : int.parse(standard.group(5)!),
      standard.group(6) == null ? 0 : int.parse(standard.group(6)!),
      text,
    );
  }

  final iso = DateTime.tryParse(text);
  if (iso != null) {
    return iso.millisecondsSinceEpoch;
  }

  throw Failure(FailureCode.validation, '日期时间格式无效：$text');
}

int _validatedLocalDateTime(
  int year,
  int month,
  int day,
  int hour,
  int minute,
  int second,
  String raw,
) {
  if (year < 1970 ||
      year > 2100 ||
      month < 1 ||
      month > 12 ||
      day < 1 ||
      day > 31 ||
      hour < 0 ||
      hour > 23 ||
      minute < 0 ||
      minute > 59 ||
      second < 0 ||
      second > 59) {
    throw Failure(FailureCode.validation, '日期时间超出有效范围：$raw');
  }
  final dt = DateTime(year, month, day, hour, minute, second);
  if (dt.year != year || dt.month != month || dt.day != day) {
    throw Failure(FailureCode.validation, '不存在的日历日期：$raw');
  }
  return dt.millisecondsSinceEpoch;
}

bool _parseBoolFlag(String? raw) {
  if (raw == null) return false;
  final v = raw.trim().toLowerCase();
  return v == '1' || v == 'true' || v == 'yes';
}

String? _firstNonBlank(Map<String, String> q, List<String> keys) {
  for (final k in keys) {
    final v = q[k]?.trim();
    if (v != null && v.isNotEmpty) return v;
  }
  return null;
}

/// Parses and validates a `tallyisle://` or `yyjz://` URI (`F-033`).
ParsedUrlSchemeCommand parseUrlScheme(String rawUri) {
  final trimmed = rawUri.trim();
  if (trimmed.isEmpty) {
    throw const Failure(FailureCode.validation, 'URL 链接不能为空');
  }
  final Uri uri;
  try {
    uri = Uri.parse(trimmed);
  } on FormatException {
    throw Failure(FailureCode.validation, 'URL 链接格式无效：$trimmed');
  }

  final scheme = uri.scheme.toLowerCase();
  if (!supportedUrlSchemes.contains(scheme)) {
    throw Failure(
      FailureCode.validation,
      '不支持的协议头：${uri.scheme.isEmpty ? trimmed : uri.scheme}（仅支持 tallyisle:// 与 yyjz://）',
    );
  }

  var actionToken = uri.host.trim().toLowerCase();
  if (actionToken.isEmpty && uri.pathSegments.isNotEmpty) {
    actionToken = uri.pathSegments.first.trim().toLowerCase();
  }
  if (actionToken.isEmpty) {
    throw const Failure(FailureCode.validation, 'URL 链接缺少动作名称');
  }

  final q = <String, String>{
    for (final entry in uri.queryParameters.entries)
      entry.key.toLowerCase(): entry.value,
  };

  switch (actionToken) {
    case 'reminder':
      return ParsedUrlSchemeCommand(
        rawUri: trimmed,
        scheme: scheme,
        action: UrlSchemeAction.internalReminder,
      );
    case 'reminder-open':
      return ParsedUrlSchemeCommand(
        rawUri: trimmed,
        scheme: scheme,
        action: UrlSchemeAction.newBill,
        targetRoute: '/record/new',
      );
    case 'home':
    case 'main':
      return ParsedUrlSchemeCommand(
        rawUri: trimmed,
        scheme: scheme,
        action: UrlSchemeAction.home,
        targetRoute: '/',
      );
    case 'calendar':
      return ParsedUrlSchemeCommand(
        rawUri: trimmed,
        scheme: scheme,
        action: UrlSchemeAction.calendar,
        targetRoute: '/calendar',
      );
    case 'stat':
    case 'stats':
      final yearStr = _firstNonBlank(q, const ['year']);
      final monthStr = _firstNonBlank(q, const ['month']);
      final bookRef = _firstNonBlank(q, const ['book', 'bookid']);
      int? year;
      int? month;
      if (yearStr != null) {
        year = int.tryParse(yearStr);
        if (year == null || year < 1970 || year > 2100) {
          throw Failure(FailureCode.validation, '年份参数无效：$yearStr');
        }
      }
      if (monthStr != null) {
        month = int.tryParse(monthStr);
        if (month == null || month < 1 || month > 12) {
          throw Failure(FailureCode.validation, '月份参数无效：$monthStr');
        }
      }
      final String route;
      if (year != null && month == null) {
        final bookId = int.tryParse(bookRef ?? '');
        final query = <String, String>{
          'year': '$year',
          if (bookId != null) 'bookId': '$bookId',
        };
        route = Uri(path: '/stats/annual', queryParameters: query).toString();
      } else if (year != null && month != null) {
        route = Uri(
          path: '/stats',
          queryParameters: {'year': '$year', 'month': '$month'},
        ).toString();
      } else {
        route = '/stats';
      }
      return ParsedUrlSchemeCommand(
        rawUri: trimmed,
        scheme: scheme,
        action: UrlSchemeAction.stat,
        targetRoute: route,
        year: year,
        month: month,
        bookRef: bookRef,
      );
    case 'newbill':
      return _buildNewBillNavigation(
        rawUri: trimmed,
        scheme: scheme,
        q: q,
        action: UrlSchemeAction.newBill,
      );
    case 'addbill':
      if (_parseBoolFlag(_firstNonBlank(q, const ['showsheet']))) {
        return _buildNewBillNavigation(
          rawUri: trimmed,
          scheme: scheme,
          q: q,
          action: UrlSchemeAction.addBill,
        );
      }
      final type = parseUrlRecordType(_firstNonBlank(q, const ['type']));
      final moneyRaw = _firstNonBlank(q, const ['money', 'amount']);
      if (moneyRaw == null) {
        throw const Failure(FailureCode.validation, 'addbill 缺少金额参数 money');
      }
      final money = parseUrlMoney(moneyRaw, fieldLabel: '金额');

      final discountRaw = _firstNonBlank(q, const ['discount']);
      Money? discount;
      if (discountRaw != null) {
        discount = parseUrlMoney(
          discountRaw,
          fieldLabel: '优惠金额',
          allowZero: true,
        );
        if (discount.units > money.units) {
          throw const Failure(FailureCode.validation, '优惠金额不能大于账单金额');
        }
        if (discount.isZero) discount = null;
      }

      final feeRaw = _firstNonBlank(q, const ['fee']);
      Money? fee;
      if (feeRaw != null) {
        fee = parseUrlMoney(feeRaw, fieldLabel: '手续费', allowZero: true);
        if (fee.isZero) fee = null;
      }

      final asset1Ref = _firstNonBlank(q, const [
        'asset1',
        'asset',
        'from',
        'assetid',
        'fromasset',
      ]);
      final asset2Ref = _firstNonBlank(q, const [
        'asset2',
        'to',
        'toasset',
        'toassetid',
      ]);
      if (type == RecordType.transfer) {
        if (asset1Ref == null || asset2Ref == null) {
          throw const Failure(
            FailureCode.validation,
            '转账 addbill 必须同时提供转出账户（asset1）与转入账户（asset2）',
          );
        }
      }

      final remark = (_firstNonBlank(q, const ['remark', 'note']) ?? '').trim();
      if (remark.length > 2000) {
        throw const Failure(FailureCode.validation, '备注长度不能超过 2000 字');
      }

      final recordTimeMs = parseUrlDateTimeMs(
        _firstNonBlank(q, const ['datetime', 'time', 'date']),
      );

      final tagsRaw = _firstNonBlank(q, const ['tags', 'tag']);
      final tagRefs = tagsRaw == null
          ? const <String>[]
          : tagsRaw
                .split(RegExp(r'[,，]'))
                .map((s) => s.trim())
                .where((s) => s.isNotEmpty)
                .toList(growable: false);

      final bookRef = _firstNonBlank(q, const ['book', 'bookid']);
      final categoryRef = _firstNonBlank(q, const [
        'category',
        'cat',
        'categoryid',
      ]);

      return ParsedUrlSchemeCommand(
        rawUri: trimmed,
        scheme: scheme,
        action: UrlSchemeAction.addBill,
        bookRef: bookRef,
        addBill: UrlAddBillParams(
          type: type,
          money: money,
          discount: discount,
          fee: fee,
          feeFromTarget: _parseBoolFlag(
            _firstNonBlank(q, const ['feefromtarget']),
          ),
          bookRef: bookRef,
          categoryRef: categoryRef,
          asset1Ref: asset1Ref,
          asset2Ref: asset2Ref,
          remark: remark,
          recordTimeMs: recordTimeMs,
          excludeBudget: _parseBoolFlag(
            _firstNonBlank(q, const ['exbudget', 'excludebudget']),
          ),
          excludeExIn: _parseBoolFlag(
            _firstNonBlank(q, const ['exstat', 'excludeexin']),
          ),
          tagRefs: tagRefs,
        ),
      );
    default:
      throw Failure(FailureCode.validation, '不支持的 URL 动作：$actionToken');
  }
}

ParsedUrlSchemeCommand _buildNewBillNavigation({
  required String rawUri,
  required String scheme,
  required Map<String, String> q,
  required UrlSchemeAction action,
}) {
  final routeParams = <String, String>{};
  final typeRaw = _firstNonBlank(q, const ['type']);
  int? resolvedType;
  if (typeRaw != null) {
    resolvedType = parseUrlRecordType(typeRaw);
    routeParams['type'] = '$resolvedType';
  }
  final moneyRaw = _firstNonBlank(q, const ['money', 'amount']);
  if (moneyRaw != null) {
    final parsedMoney = parseUrlMoney(
      moneyRaw,
      fieldLabel: '金额',
      allowZero: true,
    );
    routeParams['amount'] = parsedMoney.decimal;
  }
  final asset1 = _firstNonBlank(q, const ['asset1', 'asset', 'from']);
  final asset2 = _firstNonBlank(q, const ['asset2', 'to']);
  if (asset1 != null && int.tryParse(asset1) != null) {
    if (resolvedType == RecordType.transfer) {
      routeParams['from'] = asset1;
    } else {
      routeParams['asset'] = asset1;
    }
  }
  if (asset2 != null && int.tryParse(asset2) != null) {
    routeParams['to'] = asset2;
  }
  final remark = _firstNonBlank(q, const ['remark', 'note']);
  if (remark != null) {
    routeParams['remark'] = remark;
  }
  final route = routeParams.isEmpty
      ? '/record/new'
      : Uri(path: '/record/new', queryParameters: routeParams).toString();
  return ParsedUrlSchemeCommand(
    rawUri: rawUri,
    scheme: scheme,
    action: action,
    targetRoute: route,
    bookRef: _firstNonBlank(q, const ['book', 'bookid']),
  );
}
