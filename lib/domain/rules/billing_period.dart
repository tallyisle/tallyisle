/// Billing period helpers (docs/modules/home-and-period.md).
///
/// A period starts on the book's `start_day` (1..28) at local 00:00:00.000 and
/// ends one month later minus 1 ms, i.e. a closed interval in local time.
/// Per P-03 the custom start day applies to everyone (no VIP gate).
final class BillingPeriod {
  BillingPeriod._(this.start, this.end);

  /// Period that contains [moment] for a book with [startDay].
  factory BillingPeriod.containing(DateTime moment, int startDay) {
    final day = normalizeStartDay(startDay);
    final local = moment.toLocal();
    var year = local.year;
    var month = local.month;
    if (local.day < day) {
      month -= 1;
      if (month == 0) {
        month = 12;
        year -= 1;
      }
    }
    return BillingPeriod.starting(year, month, day);
  }

  /// Period whose first day is [startDay] of [year]/[month].
  factory BillingPeriod.starting(int year, int month, int startDay) {
    final day = normalizeStartDay(startDay);
    final start = DateTime(year, month, day);
    final next = DateTime(year, month + 1, day);
    return BillingPeriod._(
      start,
      next.subtract(const Duration(milliseconds: 1)),
    );
  }

  /// Annual billing period for [year] starting on Jan [startDay] (02zr §2.2).
  factory BillingPeriod.year(int year, int startDay) {
    final day = normalizeStartDay(startDay);
    final start = DateTime(year, 1, day);
    final next = DateTime(year + 1, 1, day);
    return BillingPeriod._(
      start,
      next.subtract(const Duration(milliseconds: 1)),
    );
  }

  /// Annual billing period that contains [moment] for a book with [startDay].
  factory BillingPeriod.containingYear(DateTime moment, int startDay) {
    final day = normalizeStartDay(startDay);
    final local = moment.toLocal();
    final year = (local.month == 1 && local.day < day)
        ? local.year - 1
        : local.year;
    return BillingPeriod.year(year, day);
  }

  /// Custom closed date interval `[startDay 00:00:00.000, endDay 23:59:59.999]`.
  factory BillingPeriod.custom(DateTime startDate, DateTime endDate) {
    final s = DateTime(startDate.year, startDate.month, startDate.day);
    final e = DateTime(endDate.year, endDate.month, endDate.day);
    final ordered = e.isBefore(s) ? (e, s) : (s, e);
    final nextDay = DateTime(
      ordered.$2.year,
      ordered.$2.month,
      ordered.$2.day + 1,
    );
    return BillingPeriod._(
      ordered.$1,
      nextDay.subtract(const Duration(milliseconds: 1)),
    );
  }

  final DateTime start;
  final DateTime end;

  int get startMs => start.millisecondsSinceEpoch;
  int get endMs => end.millisecondsSinceEpoch;

  /// The label month: the month in which the period starts.
  int get year => start.year;
  int get month => start.month;

  /// Unpadded monthly budget section `"YYYY-M"` (budget.md R1).
  String get monthlySection => '$year-$month';

  /// Annual budget section `"YYYY"` (budget.md R1).
  String get yearlySection => '$year';

  /// Total calendar days in this period (inclusive, DST-safe).
  int get totalDays {
    final s = DateTime.utc(start.year, start.month, start.day);
    final e = DateTime.utc(end.year, end.month, end.day);
    return e.difference(s).inDays + 1;
  }

  /// Elapsed calendar days in this period as of [now] (category-stats.md R1):
  /// 0 for future periods, `totalDays` for past periods, and inclusive days up
  /// to `now`'s local calendar day for the active period.
  int elapsedDays(DateTime now) {
    final local = now.toLocal();
    final s = DateTime.utc(start.year, start.month, start.day);
    final e = DateTime.utc(end.year, end.month, end.day);
    final today = DateTime.utc(local.year, local.month, local.day);
    if (today.isBefore(s)) return 0;
    if (!today.isBefore(e)) return e.difference(s).inDays + 1;
    return today.difference(s).inDays + 1;
  }

  BillingPeriod previous(int startDay) =>
      BillingPeriod.starting(year, month - 1, startDay);
  BillingPeriod next(int startDay) =>
      BillingPeriod.starting(year, month + 1, startDay);

  BillingPeriod previousYear(int startDay) =>
      BillingPeriod.year(year - 1, startDay);
  BillingPeriod nextYear(int startDay) =>
      BillingPeriod.year(year + 1, startDay);

  bool contains(int epochMs) => epochMs >= startMs && epochMs <= endMs;
}

/// The original UI offers 1..28; stored values outside are treated as 1/28.
int normalizeStartDay(int startDay) =>
    startDay < 1 ? 1 : (startDay > 28 ? 28 : startDay);
