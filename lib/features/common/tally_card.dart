import 'package:flutter/material.dart';

import '../../data/db/database.dart';
import '../../data/repo/ledger_queries.dart' show statEntryOf;
import '../../domain/rules/income_expense.dart';
import 'common.dart' show formatDate, formatMinor;

/// Outer horizontal page gutter shared by every borderless tonal card.
const double kTallyPageHorizontalPadding = 16.0;

/// Corner radius of top-level borderless tonal cards.
const double kTallyCardRadius = 16.0;

/// Corner radius of nested tonal sub-blocks inside a card.
const double kTallyNestedRadius = 12.0;

/// Default outer margin of a [TallyDailyRecordCard].
const EdgeInsets kTallyDailyCardMargin = EdgeInsets.fromLTRB(
  kTallyPageHorizontalPadding,
  0,
  kTallyPageHorizontalPadding,
  10,
);

/// Tonal fill of a top-level borderless card for [s].
Color tallyCardColorFromScheme(ColorScheme s) => s.brightness == Brightness.dark
    ? s.surfaceContainerLow
    : Color.lerp(s.surfaceContainerLow, s.surfaceContainer, 0.55)!;

/// Tonal fill of a top-level borderless card for the ambient theme.
Color tallyCardColor(BuildContext context) =>
    tallyCardColorFromScheme(Theme.of(context).colorScheme);

/// Tonal fill of a nested sub-block (12dp radius, no border) inside a card.
Color tallyNestedSurfaceColor(ColorScheme s) => s.brightness == Brightness.dark
    ? s.surfaceContainerHigh.withValues(alpha: 0.65)
    : s.surfaceContainerHighest.withValues(alpha: 0.45);

/// Global borderless tonal [CardThemeData] (zero margin, 16dp radius).
CardThemeData tallyCardTheme(ColorScheme s) => CardThemeData(
  elevation: 0,
  surfaceTintColor: Colors.transparent,
  color: tallyCardColorFromScheme(s),
  margin: EdgeInsets.zero,
  clipBehavior: Clip.antiAlias,
  shape: RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(kTallyCardRadius),
  ),
);

const List<String> _weekdayNames = <String>[
  '周一',
  '周二',
  '周三',
  '周四',
  '周五',
  '周六',
  '周日',
];

/// "2026-11-25 周三": keeps the [formatDate] prefix and appends the weekday.
String formatDateWithWeekday(DateTime d) =>
    '${formatDate(d)} ${_weekdayNames[d.weekday - 1]}';

/// One calendar day of records, in the order they were supplied.
typedef TallyRecordDayGroup = ({DateTime day, List<LedgerRecord> records});

/// Groups consecutive [records] that share a local calendar day.
List<TallyRecordDayGroup> groupRecordsByDay(Iterable<LedgerRecord> records) {
  final groups = <TallyRecordDayGroup>[];
  String? currentKey;
  for (final r in records) {
    final time = DateTime.fromMillisecondsSinceEpoch(r.recordTime);
    final key = formatDate(time);
    if (key != currentKey || groups.isEmpty) {
      currentKey = key;
      groups.add((
        day: DateTime(time.year, time.month, time.day),
        records: <LedgerRecord>[],
      ));
    }
    groups.last.records.add(r);
  }
  return groups;
}

/// Borderless 16dp tonal card holding one day of records: a header row with
/// the date + weekday on the left and the day's expense / income subtotal on
/// the right, followed by [children] with no dividers in between.
class TallyDailyRecordCard extends StatelessWidget {
  const TallyDailyRecordCard({
    super.key,
    required this.day,
    required this.records,
    required this.children,
    this.margin = kTallyDailyCardMargin,
    this.showSubtotal = true,
  });

  final DateTime day;

  /// Records of [day] used for the subtotal (same rules as the period summary).
  final List<LedgerRecord> records;

  /// Record widgets of the day, rendered without dividers.
  final List<Widget> children;

  final EdgeInsetsGeometry margin;

  /// Hide the subtotal when [records] may be an incomplete slice of the day
  /// (e.g. a paginated search result), so a partial sum is never shown.
  final bool showSubtotal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final summary = showSubtotal
        ? aggregateIncomeExpense(records.map(statEntryOf))
        : IncomeExpense.zero;
    final subtotalStyle = theme.textTheme.labelMedium?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final dayKey = formatDate(day);

    return Card(
      key: Key('daily-card-$dayKey'),
      margin: margin,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      formatDateWithWeekday(day),
                      key: Key('daily-card-date-$dayKey'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (summary.expense != BigInt.zero)
                    Padding(
                      padding: const EdgeInsets.only(left: 10),
                      child: Text(
                        '支 ¥${formatMinor(summary.expense)}',
                        key: Key('daily-card-expense-$dayKey'),
                        maxLines: 1,
                        style: subtotalStyle,
                      ),
                    ),
                  if (summary.income != BigInt.zero)
                    Padding(
                      padding: const EdgeInsets.only(left: 10),
                      child: Text(
                        '收 ¥${formatMinor(summary.income)}',
                        key: Key('daily-card-income-$dayKey'),
                        maxLines: 1,
                        style: subtotalStyle,
                      ),
                    ),
                ],
              ),
            ),
            ...children,
          ],
        ),
      ),
    );
  }
}
