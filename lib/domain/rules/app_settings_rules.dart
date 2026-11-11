import 'dart:convert';

import '../../core/failure.dart';
import '../../core/money.dart';
import '../model/codes.dart';
import 'income_expense.dart';

/// `ti_preference` key storing serialized [AppSettings] JSON (`F-038`).
const String appSettingsPreferenceKey = 'app_settings';

/// Default brand seed hex matching `Color(0xff138eaa)` (`BRAND-001`).
const String defaultThemeSeedHex = '138EAA';

/// Allowed default record types when opening "记一笔" (`0` 支出, `1` 收入, `2` 转账).
const Set<int> allowedDefaultRecordTypes = <int>{
  RecordType.expense,
  RecordType.income,
  RecordType.transfer,
};

const _corruptSettings = Failure(FailureCode.corruptData, '应用设置格式损坏');

/// Pure Dart theme mode preference (`F-038`, `P-03`).
enum AppThemeModePreference {
  system('system', '跟随系统'),
  light('light', '浅色模式'),
  dark('dark', '深色模式');

  const AppThemeModePreference(this.code, this.label);
  final String code;
  final String label;

  static AppThemeModePreference fromCode(String? code) => switch (code) {
    'light' => AppThemeModePreference.light,
    'dark' => AppThemeModePreference.dark,
    'system' || null || '' => AppThemeModePreference.system,
    _ => throw _corruptSettings,
  };
}

/// Curated free theme color swatches (`P-03`: zero VIP gating).
final class ThemeSeedPreset {
  const ThemeSeedPreset({required this.hex, required this.name});

  final String hex;
  final String name;

  int get argb32 => 0xFF000000 | int.parse(hex, radix: 16);
}

const List<ThemeSeedPreset> themeSeedPresets = <ThemeSeedPreset>[
  ThemeSeedPreset(hex: '138EAA', name: '海岛青（默认）'),
  ThemeSeedPreset(hex: '2E7D32', name: '松林绿'),
  ThemeSeedPreset(hex: '1565C0', name: '深海蓝'),
  ThemeSeedPreset(hex: '6A1B9A', name: '暮光紫'),
  ThemeSeedPreset(hex: 'C62828', name: '珊瑚红'),
  ThemeSeedPreset(hex: 'EF6C00', name: '暖阳橙'),
  ThemeSeedPreset(hex: '455A64', name: '岩灰蓝'),
];

/// Validates and normalizes a 6-digit RGB hex string (accepts optional `#`).
String normalizeThemeSeedHex(String raw) {
  var trimmed = raw.trim();
  if (trimmed.startsWith('#')) {
    trimmed = trimmed.substring(1);
  }
  if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(trimmed)) {
    throw const Failure(FailureCode.validation, '主题色须为 6 位十六进制颜色码（如 138EAA）');
  }
  return trimmed.toUpperCase();
}

/// Validates that [recordType] is allowed as a default new-bill tab (`{0, 1, 2}`).
void validateDefaultRecordType(int recordType) {
  if (!allowedDefaultRecordTypes.contains(recordType)) {
    throw const Failure(FailureCode.validation, '默认记账类型仅支持支出、收入或转账');
  }
}

/// System & Home page configuration model (`F-038`).
final class AppSettings {
  const AppSettings({
    this.showBalanceChangeRecordOnHome = false,
    this.showHomeAssetSummaryBanner = true,
    this.showHomeBudgetCard = true,
    this.defaultRecordType = RecordType.expense,
    this.themeMode = AppThemeModePreference.system,
    this.themeSeedHex = defaultThemeSeedHex,
  });

  static const AppSettings defaults = AppSettings();

  /// `home-and-period.md` R2: whether `type=4` balance adjustments appear on Home.
  final bool showBalanceChangeRecordOnHome;

  /// Whether Home shows the net-worth / asset summary banner card.
  final bool showHomeAssetSummaryBanner;

  /// Whether Home shows the current-period budget progress card.
  final bool showHomeBudgetCard;

  /// Default record type (`0` expense, `1` income, `2` transfer).
  final int defaultRecordType;

  /// Appearance mode (`system` / `light` / `dark`).
  final AppThemeModePreference themeMode;

  /// Normalized 6-char uppercase RGB hex seed color (`138EAA` by default).
  final String themeSeedHex;

  /// ARGB 32-bit integer (`0xFFRRGGBB`) ready for `Color(...)`.
  int get themeSeedArgb32 => 0xFF000000 | int.parse(themeSeedHex, radix: 16);

  AppSettings validated() {
    validateDefaultRecordType(defaultRecordType);
    final normalizedHex = normalizeThemeSeedHex(themeSeedHex);
    return AppSettings(
      showBalanceChangeRecordOnHome: showBalanceChangeRecordOnHome,
      showHomeAssetSummaryBanner: showHomeAssetSummaryBanner,
      showHomeBudgetCard: showHomeBudgetCard,
      defaultRecordType: defaultRecordType,
      themeMode: themeMode,
      themeSeedHex: normalizedHex,
    );
  }

  AppSettings copyWith({
    bool? showBalanceChangeRecordOnHome,
    bool? showHomeAssetSummaryBanner,
    bool? showHomeBudgetCard,
    int? defaultRecordType,
    AppThemeModePreference? themeMode,
    String? themeSeedHex,
  }) => AppSettings(
    showBalanceChangeRecordOnHome:
        showBalanceChangeRecordOnHome ?? this.showBalanceChangeRecordOnHome,
    showHomeAssetSummaryBanner:
        showHomeAssetSummaryBanner ?? this.showHomeAssetSummaryBanner,
    showHomeBudgetCard: showHomeBudgetCard ?? this.showHomeBudgetCard,
    defaultRecordType: defaultRecordType ?? this.defaultRecordType,
    themeMode: themeMode ?? this.themeMode,
    themeSeedHex: themeSeedHex != null
        ? normalizeThemeSeedHex(themeSeedHex)
        : this.themeSeedHex,
  );

  Map<String, Object> toJson() => <String, Object>{
    'showBalanceChangeRecordOnHome': showBalanceChangeRecordOnHome,
    'showHomeAssetSummaryBanner': showHomeAssetSummaryBanner,
    'showHomeBudgetCard': showHomeBudgetCard,
    'defaultRecordType': defaultRecordType,
    'themeMode': themeMode.code,
    'themeSeedHex': themeSeedHex,
  };

  String encode() => jsonEncode(toJson());

  static AppSettings parse(String? text) {
    if (text == null || text.trim().isEmpty) return defaults;
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw _corruptSettings;
    }
    if (decoded is! Map<String, Object?>) throw _corruptSettings;

    final showBalanceChange = decoded['showBalanceChangeRecordOnHome'] ?? false;
    final showAssetBanner = decoded['showHomeAssetSummaryBanner'] ?? true;
    final showBudgetCard = decoded['showHomeBudgetCard'] ?? true;
    final defaultType = decoded['defaultRecordType'] ?? RecordType.expense;
    final rawMode = decoded['themeMode'] as String?;
    final rawHex = (decoded['themeSeedHex'] as String?) ?? defaultThemeSeedHex;

    if (showBalanceChange is! bool ||
        showAssetBanner is! bool ||
        showBudgetCard is! bool ||
        defaultType is! int ||
        !allowedDefaultRecordTypes.contains(defaultType)) {
      throw _corruptSettings;
    }

    final String cleanHex;
    try {
      cleanHex = normalizeThemeSeedHex(rawHex);
    } on Failure {
      throw _corruptSettings;
    }

    return AppSettings(
      showBalanceChangeRecordOnHome: showBalanceChange,
      showHomeAssetSummaryBanner: showAssetBanner,
      showHomeBudgetCard: showBudgetCard,
      defaultRecordType: defaultType,
      themeMode: AppThemeModePreference.fromCode(rawMode),
      themeSeedHex: cleanHex,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppSettings &&
          showBalanceChangeRecordOnHome ==
              other.showBalanceChangeRecordOnHome &&
          showHomeAssetSummaryBanner == other.showHomeAssetSummaryBanner &&
          showHomeBudgetCard == other.showHomeBudgetCard &&
          defaultRecordType == other.defaultRecordType &&
          themeMode == other.themeMode &&
          themeSeedHex == other.themeSeedHex;

  @override
  int get hashCode => Object.hash(
    showBalanceChangeRecordOnHome,
    showHomeAssetSummaryBanner,
    showHomeBudgetCard,
    defaultRecordType,
    themeMode,
    themeSeedHex,
  );
}

/// Validated input draft for creating or editing a `stat_story` row (`R6`).
final class StatStoryDraft {
  const StatStoryDraft({
    required this.story,
    required this.bookId,
    required this.sdate,
    required this.edate,
    this.dsection,
  });

  final String story;
  final int bookId;
  final int sdate;
  final int edate;
  final String? dsection;

  StatStoryDraft validated() {
    final cleanStory = story.trim();
    if (cleanStory.isEmpty || cleanStory.length > 2000) {
      throw const Failure(FailureCode.validation, '统计故事内容须为 1–2000 字');
    }
    if (bookId != noRef && bookId <= 0) {
      throw const Failure(FailureCode.validation, '所属账本无效');
    }
    if (sdate < 0 || edate < 0 || sdate > edate) {
      throw const Failure(FailureCode.validation, '起始日期不能晚于结束日期');
    }
    final trimmedSection = dsection?.trim();
    if (trimmedSection != null && trimmedSection.length > 64) {
      throw const Failure(FailureCode.validation, '区间标签长度不能超过 64 字');
    }
    return StatStoryDraft(
      story: cleanStory,
      bookId: bookId,
      sdate: sdate,
      edate: edate,
      dsection: (trimmedSection == null || trimmedSection.isEmpty)
          ? null
          : trimmedSection,
    );
  }

  List<Object?> get payload => <Object?>[story, bookId, sdate, edate, dsection];
}

/// Builds a deterministic local narrative template from exact `BigInt`/`Money`
/// period figures (`docs/modules/settings-and-health.md` §6, zero `double`).
String buildStatStoryNarrative({
  required String periodLabel,
  required String bookLabel,
  required int recordCount,
  required IncomeExpense summary,
  String? topExpenseCategoryName,
  BigInt? topExpenseCategoryMinor,
  String currency = 'CNY',
}) {
  if (recordCount <= 0) {
    return '【$periodLabel · $bookLabel】本阶段暂无收支流水，不妨写下这一阶段的生活计划与财务心愿。';
  }
  final incomeText = Money.minor(summary.income, currency).decimal;
  final expenseText = Money.minor(summary.expense, currency).decimal;
  final balanceText = Money.minor(summary.balance, currency).decimal;
  final buf = StringBuffer(
    '【$periodLabel · $bookLabel】共记录 $recordCount 笔账单，'
    '总收入 $incomeText 元，总支出 $expenseText 元，结余 $balanceText 元',
  );
  if (topExpenseCategoryName != null &&
      topExpenseCategoryName.trim().isNotEmpty &&
      topExpenseCategoryMinor != null &&
      topExpenseCategoryMinor > BigInt.zero) {
    final topText = Money.minor(topExpenseCategoryMinor, currency).decimal;
    buf.write('；主要支出集中在「$topExpenseCategoryName」（$topText 元）');
  }
  buf.write('。');
  return buf.toString();
}
