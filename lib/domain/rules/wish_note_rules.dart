import '../../core/failure.dart';
import '../../core/money.dart';

// ============================================================================
// F-014 心愿单 (Wish List) 领域规则
// ============================================================================

const int maxWishContentLength = 100;
const int maxWishIconLength = 64;
const int unsetWishTargetDate = 0;
const int unrealizedWishDate = 0;

/// Preset semantic icon descriptor (pure Dart; UI maps [key] to IconData).
final class WishIconOption {
  const WishIconOption(this.key, this.label);
  final String key;
  final String label;
}

const List<WishIconOption> presetWishIcons = [
  WishIconOption('star', '星标'),
  WishIconOption('gift', '礼盒'),
  WishIconOption('digital', '数码'),
  WishIconOption('travel', '旅行'),
  WishIconOption('clothes', '服饰'),
  WishIconOption('home', '家居'),
  WishIconOption('book', '阅读'),
  WishIconOption('sport', '运动'),
  WishIconOption('food', '美食'),
  WishIconOption('saving', '储蓄'),
];

/// Parses a wish target amount strictly in integer minor units via [Money].
/// Rejects negative values, malformed strings, and >2 decimal places without rounding.
Money parseWishAmount(String raw, {String currency = 'CNY'}) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    throw const Failure(FailureCode.validation, '请输入目标金额');
  }
  final money = Money.parse(
    trimmed,
    scale: Money.ledgerScale,
    currency: currency,
  );
  final minor = money.storageMinor;
  if (minor < BigInt.zero) {
    throw const Failure(FailureCode.validation, '心愿金额不能为负数');
  }
  return money;
}

final class ValidatedWishInput {
  const ValidatedWishInput({
    required this.content,
    required this.value,
    required this.valueMinor,
    required this.targetDateMs,
    required this.icon,
    required this.sort,
  });

  final String content;
  final Money value;
  final BigInt valueMinor;
  final int targetDateMs;
  final String? icon;
  final int? sort;
}

/// Validates and normalizes wish input fields (R1, R3, CE-WN-01).
ValidatedWishInput validateWishInput({
  required String content,
  required Money value,
  int targetDateMs = unsetWishTargetDate,
  String? icon,
  int? sort,
}) {
  final trimmedContent = content.trim();
  final contentRuneLen = trimmedContent.runes.length;
  if (contentRuneLen == 0) {
    throw const Failure(FailureCode.validation, '请输入心愿内容');
  }
  if (contentRuneLen > maxWishContentLength) {
    throw const Failure(
      FailureCode.validation,
      '心愿内容不能超过 $maxWishContentLength 个字符',
    );
  }

  final minor = value.storageMinor;
  if (minor < BigInt.zero) {
    throw const Failure(FailureCode.validation, '心愿金额不能为负数');
  }

  // 0 (unset) and -1 (legacy migration 33->34 sentinel) normalize to 0;
  // arbitrary negative values below -1 are rejected.
  if (targetDateMs < -1) {
    throw const Failure(FailureCode.validation, '目标日期无效');
  }
  final normalizedTarget = targetDateMs <= 0
      ? unsetWishTargetDate
      : targetDateMs;

  final trimmedIcon = icon?.trim();
  final normalizedIcon = (trimmedIcon == null || trimmedIcon.isEmpty)
      ? null
      : trimmedIcon;
  if (normalizedIcon != null &&
      normalizedIcon.runes.length > maxWishIconLength) {
    throw const Failure(FailureCode.validation, '心愿图标标识过长');
  }

  return ValidatedWishInput(
    content: trimmedContent,
    value: value,
    valueMinor: minor,
    targetDateMs: normalizedTarget,
    icon: normalizedIcon,
    sort: sort,
  );
}

/// Enforces the realized-date invariant (R2):
/// `0` when unrealized; strictly `> 0` when realized.
int normalizeWishRealizedDate({
  required bool isRealized,
  int? realizedDateMs,
  required int fallbackNowMs,
}) {
  if (!isRealized) return unrealizedWishDate;
  if (realizedDateMs != null && realizedDateMs > 0) return realizedDateMs;
  return fallbackNowMs > 0 ? fallbackNowMs : 1;
}

enum WishDeadlineStatus { unset, upcoming, dueToday, overdue, realized }

final class WishDeadlineInfo {
  const WishDeadlineInfo({required this.status, required this.daysDelta});

  final WishDeadlineStatus status;

  /// Calendar-day delta (`targetLocalDay - nowLocalDay`), or `null` when unset.
  final int? daysDelta;

  bool get hasTargetDate => daysDelta != null;
  bool get isDueToday => status == WishDeadlineStatus.dueToday;
  bool get isOverdue => status == WishDeadlineStatus.overdue;

  int get remainingDays =>
      status == WishDeadlineStatus.upcoming &&
          daysDelta != null &&
          daysDelta! > 0
      ? daysDelta!
      : 0;

  int get overdueDays =>
      status == WishDeadlineStatus.overdue &&
          daysDelta != null &&
          daysDelta! < 0
      ? -daysDelta!
      : 0;

  String? get label => switch (status) {
    WishDeadlineStatus.unset => null,
    WishDeadlineStatus.realized => null,
    WishDeadlineStatus.upcoming => '剩余 $remainingDays 天',
    WishDeadlineStatus.dueToday => '今天到期',
    WishDeadlineStatus.overdue => '已逾期 $overdueDays 天',
  };
}

/// Computes local-calendar countdown / due-today / overdue days vs [nowMs] (R3).
/// Uses UTC day ordinals on local `(year, month, day)` to avoid DST 23h/25h drift.
WishDeadlineInfo evaluateWishDeadline({
  required int targetDateMs,
  required int nowMs,
  bool isRealized = false,
}) {
  if (targetDateMs <= 0) {
    return WishDeadlineInfo(
      status: isRealized
          ? WishDeadlineStatus.realized
          : WishDeadlineStatus.unset,
      daysDelta: null,
    );
  }

  final nowLocal = DateTime.fromMillisecondsSinceEpoch(nowMs);
  final targetLocal = DateTime.fromMillisecondsSinceEpoch(targetDateMs);
  final nowDayOrdinal = DateTime.utc(
    nowLocal.year,
    nowLocal.month,
    nowLocal.day,
  );
  final targetDayOrdinal = DateTime.utc(
    targetLocal.year,
    targetLocal.month,
    targetLocal.day,
  );
  final deltaDays = targetDayOrdinal.difference(nowDayOrdinal).inDays;

  if (isRealized) {
    return WishDeadlineInfo(
      status: WishDeadlineStatus.realized,
      daysDelta: deltaDays,
    );
  }
  if (deltaDays > 0) {
    return WishDeadlineInfo(
      status: WishDeadlineStatus.upcoming,
      daysDelta: deltaDays,
    );
  }
  if (deltaDays == 0) {
    return const WishDeadlineInfo(
      status: WishDeadlineStatus.dueToday,
      daysDelta: 0,
    );
  }
  return WishDeadlineInfo(
    status: WishDeadlineStatus.overdue,
    daysDelta: deltaDays,
  );
}

/// Lightweight domain entry for pure rule testing and callers.
final class WishEntry {
  const WishEntry({
    required this.id,
    required this.content,
    required this.valueMinor,
    required this.createDate,
    this.isRealized = false,
    this.realizedDate = unrealizedWishDate,
    this.sort = 0,
    this.icon,
    this.targetDate = unsetWishTargetDate,
  });

  final String id;
  final String content;
  final BigInt valueMinor;
  final int createDate;
  final bool isRealized;
  final int realizedDate;
  final int sort;
  final String? icon;
  final int targetDate;
}

final class WishSummary {
  const WishSummary({
    required this.unrealizedCount,
    required this.realizedCount,
    required this.unrealizedTotalMinor,
    required this.realizedTotalMinor,
  });

  final int unrealizedCount;
  final int realizedCount;
  final BigInt unrealizedTotalMinor;
  final BigInt realizedTotalMinor;

  int get totalCount => unrealizedCount + realizedCount;
  BigInt get totalMinor => unrealizedTotalMinor + realizedTotalMinor;

  Money unrealizedTotal([String currency = 'CNY']) =>
      Money.minor(unrealizedTotalMinor, currency);

  Money realizedTotal([String currency = 'CNY']) =>
      Money.minor(realizedTotalMinor, currency);

  @override
  bool operator ==(Object other) =>
      other is WishSummary &&
      unrealizedCount == other.unrealizedCount &&
      realizedCount == other.realizedCount &&
      unrealizedTotalMinor == other.unrealizedTotalMinor &&
      realizedTotalMinor == other.realizedTotalMinor;

  @override
  int get hashCode => Object.hash(
    unrealizedCount,
    realizedCount,
    unrealizedTotalMinor,
    realizedTotalMinor,
  );
}

/// Aggregates wish counts and exact BigInt minor-unit totals (R4, ADR-011).
WishSummary summarizeWishes<T>(
  Iterable<T> items, {
  required bool Function(T item) isRealizedOf,
  required BigInt Function(T item) valueMinorOf,
}) {
  var unrealizedCount = 0;
  var realizedCount = 0;
  var unrealizedTotalMinor = BigInt.zero;
  var realizedTotalMinor = BigInt.zero;

  for (final item in items) {
    final amount = valueMinorOf(item);
    if (isRealizedOf(item)) {
      realizedCount += 1;
      realizedTotalMinor += amount;
    } else {
      unrealizedCount += 1;
      unrealizedTotalMinor += amount;
    }
  }

  return WishSummary(
    unrealizedCount: unrealizedCount,
    realizedCount: realizedCount,
    unrealizedTotalMinor: unrealizedTotalMinor,
    realizedTotalMinor: realizedTotalMinor,
  );
}

/// Computes the next top sort index (`minSort - 1`, or `0` when empty).
int nextTopWishSort(Iterable<int> existingSorts) {
  final iterator = existingSorts.iterator;
  if (!iterator.moveNext()) return 0;
  var minSort = iterator.current;
  while (iterator.moveNext()) {
    if (iterator.current < minSort) minSort = iterator.current;
  }
  return minSort - 1;
}

/// Stable total order for unrealized wishes: `sort ASC -> createDate DESC -> id ASC` (R4).
List<T> sortUnrealizedWishes<T>(
  Iterable<T> items, {
  required int Function(T item) sortOf,
  required int Function(T item) createDateOf,
  required String Function(T item) idOf,
}) {
  final list = items.toList();
  list.sort((a, b) {
    final bySort = sortOf(a).compareTo(sortOf(b));
    if (bySort != 0) return bySort;
    final byCreate = createDateOf(b).compareTo(createDateOf(a));
    if (byCreate != 0) return byCreate;
    return idOf(a).compareTo(idOf(b));
  });
  return list;
}

/// Stable total order for realized wishes:
/// `realizedDate DESC -> sort ASC -> createDate DESC -> id ASC` (R4).
List<T> sortRealizedWishes<T>(
  Iterable<T> items, {
  required int Function(T item) realizedDateOf,
  required int Function(T item) sortOf,
  required int Function(T item) createDateOf,
  required String Function(T item) idOf,
}) {
  final list = items.toList();
  list.sort((a, b) {
    final byRealized = realizedDateOf(b).compareTo(realizedDateOf(a));
    if (byRealized != 0) return byRealized;
    final bySort = sortOf(a).compareTo(sortOf(b));
    if (bySort != 0) return bySort;
    final byCreate = createDateOf(b).compareTo(createDateOf(a));
    if (byCreate != 0) return byCreate;
    return idOf(a).compareTo(idOf(b));
  });
  return list;
}

/// Unified stable sort placing unrealized wishes before realized wishes.
List<T> sortWishes<T>(
  Iterable<T> items, {
  required bool Function(T item) isRealizedOf,
  required int Function(T item) realizedDateOf,
  required int Function(T item) sortOf,
  required int Function(T item) createDateOf,
  required String Function(T item) idOf,
}) {
  final unrealized = <T>[];
  final realized = <T>[];
  for (final item in items) {
    if (isRealizedOf(item)) {
      realized.add(item);
    } else {
      unrealized.add(item);
    }
  }
  return [
    ...sortUnrealizedWishes(
      unrealized,
      sortOf: sortOf,
      createDateOf: createDateOf,
      idOf: idOf,
    ),
    ...sortRealizedWishes(
      realized,
      realizedDateOf: realizedDateOf,
      sortOf: sortOf,
      createDateOf: createDateOf,
      idOf: idOf,
    ),
  ];
}

// ============================================================================
// F-015 便签与回收站 (Notes & Recycle Bin) 领域规则
// ============================================================================

const int maxNoteTitleLength = 100;
const int maxNoteContentLength = 20000;
const int defaultNoteSnippetMaxChars = 80;
const int activeNoteTrashTime = 0;

/// Active notes have `trashTime == 0` (also tolerates legacy `<= 0` such as `-1`).
bool isNoteActive(int trashTime) => trashTime <= 0;

/// Trashed notes have `trashTime > 0` (epoch milliseconds).
bool isNoteTrashed(int trashTime) => trashTime > 0;

final class ValidatedNoteInput {
  const ValidatedNoteInput({required this.title, required this.content});

  final String? title;
  final String content;
}

/// Validates note title and content (R5).
ValidatedNoteInput validateNoteInput({String? title, required String content}) {
  final trimmedTitle = title?.trim();
  final cleanTitle = (trimmedTitle == null || trimmedTitle.isEmpty)
      ? null
      : trimmedTitle;
  if (cleanTitle != null && cleanTitle.runes.length > maxNoteTitleLength) {
    throw const Failure(
      FailureCode.validation,
      '便签标题不能超过 $maxNoteTitleLength 个字符',
    );
  }

  if (content.trim().isEmpty) {
    throw const Failure(FailureCode.validation, '请输入便签内容');
  }
  if (content.runes.length > maxNoteContentLength) {
    throw const Failure(
      FailureCode.validation,
      '便签内容不能超过 $maxNoteContentLength 个字符',
    );
  }

  return ValidatedNoteInput(title: cleanTitle, content: content);
}

/// Case-insensitive substring search across note [title] and [content] (R6).
bool matchesNoteSearch({
  String? title,
  required String content,
  required String query,
}) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return true;
  if (title != null && title.toLowerCase().contains(needle)) return true;
  return content.toLowerCase().contains(needle);
}

List<T> filterNotesByQuery<T>(
  Iterable<T> notes,
  String query, {
  required String? Function(T note) titleOf,
  required String Function(T note) contentOf,
}) {
  final needle = query.trim();
  if (needle.isEmpty) return notes.toList();
  return [
    for (final note in notes)
      if (matchesNoteSearch(
        title: titleOf(note),
        content: contentOf(note),
        query: needle,
      ))
        note,
  ];
}

/// Collapses consecutive whitespace and truncates cleanly on Unicode code points (R5).
String buildNoteSnippet(
  String content, {
  int maxChars = defaultNoteSnippetMaxChars,
}) {
  if (maxChars <= 0) return '';
  final collapsed = content.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (collapsed.isEmpty) return '';
  final runes = collapsed.runes.toList(growable: false);
  if (runes.length <= maxChars) return collapsed;
  return '${String.fromCharCodes(runes.take(maxChars))}…';
}

/// Resolves a note card title: explicit [title] if non-blank, otherwise first non-empty line.
String resolveNoteDisplayTitle({
  String? title,
  required String content,
  int fallbackMaxChars = 24,
}) {
  final trimmedTitle = title?.trim();
  if (trimmedTitle != null && trimmedTitle.isNotEmpty) {
    return trimmedTitle;
  }
  for (final rawLine in content.split(RegExp(r'\r?\n'))) {
    final line = rawLine.trim();
    if (line.isNotEmpty) {
      return buildNoteSnippet(line, maxChars: fallbackMaxChars);
    }
  }
  return '无标题便签';
}

/// Lightweight domain entry for pure rule testing.
final class NoteEntry {
  const NoteEntry({
    required this.id,
    this.title,
    required this.content,
    required this.createTime,
    required this.updateTime,
    this.trashTime = activeNoteTrashTime,
  });

  final int id;
  final String? title;
  final String content;
  final int createTime;
  final int updateTime;
  final int trashTime;
}

/// Stable total order for active notes: `updateTime DESC -> createTime DESC -> id DESC` (R6).
List<T> sortActiveNotes<T>(
  Iterable<T> notes, {
  required int Function(T note) updateTimeOf,
  required int Function(T note) createTimeOf,
  required int Function(T note) idOf,
}) {
  final list = notes.toList();
  list.sort((a, b) {
    final byUpdate = updateTimeOf(b).compareTo(updateTimeOf(a));
    if (byUpdate != 0) return byUpdate;
    final byCreate = createTimeOf(b).compareTo(createTimeOf(a));
    if (byCreate != 0) return byCreate;
    return idOf(b).compareTo(idOf(a));
  });
  return list;
}

/// Stable total order for trashed notes: `trashTime DESC -> updateTime DESC -> id DESC` (R6).
List<T> sortTrashedNotes<T>(
  Iterable<T> notes, {
  required int Function(T note) trashTimeOf,
  required int Function(T note) updateTimeOf,
  required int Function(T note) idOf,
}) {
  final list = notes.toList();
  list.sort((a, b) {
    final byTrash = trashTimeOf(b).compareTo(trashTimeOf(a));
    if (byTrash != 0) return byTrash;
    final byUpdate = updateTimeOf(b).compareTo(updateTimeOf(a));
    if (byUpdate != 0) return byUpdate;
    return idOf(b).compareTo(idOf(a));
  });
  return list;
}
