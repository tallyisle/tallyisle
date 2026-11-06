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

  final DateTime start;
  final DateTime end;

  int get startMs => start.millisecondsSinceEpoch;
  int get endMs => end.millisecondsSinceEpoch;

  /// The label month: the month in which the period starts.
  int get year => start.year;
  int get month => start.month;

  BillingPeriod previous(int startDay) =>
      BillingPeriod.starting(year, month - 1, startDay);
  BillingPeriod next(int startDay) =>
      BillingPeriod.starting(year, month + 1, startDay);

  bool contains(int epochMs) => epochMs >= startMs && epochMs <= endMs;
}

/// The original UI offers 1..28; stored values outside are treated as 1/28.
int normalizeStartDay(int startDay) =>
    startDay < 1 ? 1 : (startDay > 28 ? 28 : startDay);
