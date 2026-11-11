import 'package:drift/drift.dart';

import '../../domain/ledger/record_extra.dart';
import '../../domain/ledger/record_relations.dart';
import '../../domain/rules/annual_report.dart';
import '../../domain/rules/billing_period.dart';
import '../db/database.dart';

/// Read-side queries for annual billing and reports (F-030).
final class AnnualReportQueries {
  AnnualReportQueries(this.db);
  final AppDatabase db;

  /// Returns descending list of available years with recorded transactions
  /// up to the current year. Always contains at least the current year.
  Stream<List<int>> watchAvailableYears({int? bookId}) {
    final hasBook = bookId != null;
    final sql =
        'SELECT MIN(record_time) AS min_time, MAX(record_time) AS max_time '
        'FROM record '
        'WHERE type != 15 ${hasBook ? 'AND account_book_id = ?' : ''}';

    final variables = <Variable>[if (hasBook) Variable.withInt(bookId)];

    return db
        .customSelect(sql, variables: variables, readsFrom: {db.records})
        .watchSingleOrNull()
        .map((row) {
          final currentYear = DateTime.now().year;
          if (row == null) return [currentYear];
          final minMs = row.readNullable<int>('min_time');
          final maxMs = row.readNullable<int>('max_time');
          if (minMs == null || maxMs == null) return [currentYear];

          final minYear = DateTime.fromMillisecondsSinceEpoch(minMs).year;
          final maxYear = DateTime.fromMillisecondsSinceEpoch(maxMs).year;
          final endYear = maxYear > currentYear ? maxYear : currentYear;
          final startYear = minYear < currentYear ? minYear : currentYear;

          final years = <int>[];
          for (var y = endYear; y >= startYear; y--) {
            years.add(y);
          }
          return years.isEmpty ? [currentYear] : years;
        });
  }

  /// Watches all records within [startMs, endMs] (inclusive), with joined category
  /// and asset names. Ordered newest first.
  Stream<List<AnnualRecordItem>> watchAnnualRecords({
    required int startMs,
    required int endMs,
    int? bookId,
  }) {
    final hasBook = bookId != null;
    final sql =
        'SELECT '
        '  r.record_id, r.type, r.sub_type, r.money_minor, r.discount_minor, '
        '  r.extra_info, r.rel_info, r.exclude_ex_in, r.exclude_budget, '
        '  r.record_time, r.account_book_id, '
        '  CASE WHEN c.parent_cat_id IS NOT NULL AND c.parent_cat_id != -1 AND pc.id IS NOT NULL '
        '       THEN pc.id ELSE r.record_cat_id END AS effective_cat_id, '
        '  r.asset_id, r.from_asset_id, r.to_asset_id, '
        '  COALESCE(pc.name, c.name) AS category_name, '
        '  COALESCE(pc.icon, c.icon) AS category_icon, '
        '  COALESCE(a.name, fa.name, ta.name) AS asset_name '
        'FROM record r '
        'LEFT JOIN record_category c ON r.record_cat_id = c.id '
        'LEFT JOIN record_category pc ON c.parent_cat_id = pc.id AND c.parent_cat_id != -1 '
        'LEFT JOIN asset a ON r.asset_id = a.id '
        'LEFT JOIN asset fa ON r.from_asset_id = fa.id '
        'LEFT JOIN asset ta ON r.to_asset_id = ta.id '
        'WHERE r.record_time BETWEEN ? AND ? '
        '  AND r.type != 15 '
        '  ${hasBook ? 'AND r.account_book_id = ? ' : ''}'
        'ORDER BY r.record_time DESC, r.record_id DESC';

    final variables = <Variable>[
      Variable.withInt(startMs),
      Variable.withInt(endMs),
      if (hasBook) Variable.withInt(bookId),
    ];

    return db
        .customSelect(
          sql,
          variables: variables,
          readsFrom: {db.records, db.recordCategories, db.assets},
        )
        .watch()
        .map((rows) => rows.map(_mapRowToAnnualRecordItem).toList());
  }

  /// Full annual report computation stream for [year] and [startDay].
  Stream<AnnualReportResult> watchAnnualReport({
    required int year,
    required int startDay,
    int? bookId,
    String baseCurrency = 'CNY',
  }) {
    final day = normalizeStartDay(startDay);
    final period = BillingPeriod.year(year, day);

    return watchAnnualRecords(
      startMs: period.startMs,
      endMs: period.endMs,
      bookId: bookId,
    ).map((records) {
      return computeAnnualReport(
        year: year,
        startDay: day,
        records: records,
        baseCurrency: baseCurrency,
      );
    });
  }

  AnnualRecordItem _mapRowToAnnualRecordItem(QueryRow row) {
    final assetIdVal = row.read<int>('asset_id');
    final fromAssetIdVal = row.read<int>('from_asset_id');
    final toAssetIdVal = row.read<int>('to_asset_id');

    final effectiveAssetId = assetIdVal != -1
        ? assetIdVal
        : (fromAssetIdVal != -1
              ? fromAssetIdVal
              : (toAssetIdVal != -1 ? toAssetIdVal : null));

    final discountMinorVal = row.readNullable<BigInt>('discount_minor');
    final extraInfoStr = row.readNullable<String>('extra_info');
    final relInfoStr = row.readNullable<String>('rel_info');

    return AnnualRecordItem(
      id: row.read<String>('record_id'),
      type: row.read<int>('type'),
      subType: row.read<int>('sub_type'),
      moneyMinor: row.read<BigInt>('money_minor'),
      discountMinor: discountMinorVal,
      currency: RecordExtra.parse(extraInfoStr).currency,
      relations: RecordRelations.parse(relInfoStr),
      excludeExIn: row.read<bool>('exclude_ex_in'),
      excludeBudget: row.read<bool>('exclude_budget'),
      recordTime: row.read<int>('record_time'),
      bookId: row.read<int>('account_book_id'),
      categoryId: row.read<int>('effective_cat_id'),
      categoryName: row.readNullable<String>('category_name'),
      categoryIcon: row.readNullable<String>('category_icon'),
      assetId: effectiveAssetId,
      assetName: row.readNullable<String>('asset_name'),
    );
  }
}
