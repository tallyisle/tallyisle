import 'package:drift/drift.dart';

import '../../domain/model/codes.dart';
import '../../domain/rules/income_expense.dart';
import '../db/database.dart';
import 'ledger_queries.dart';

/// Escapes special pattern characters (`\`, `%`, `_`) for SQLite `LIKE ... ESCAPE '\'`.
String escapeSqlLike(String input) {
  return input
      .replaceAll(r'\', r'\\')
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');
}

/// Filter criteria for bill search (F-002).
final class SearchFilter {
  const SearchFilter({
    required this.bookId,
    this.startMs,
    this.endMs,
    this.type,
    this.categoryIds,
    this.assetId,
    this.keyword,
    this.minMoneyMinor,
    this.maxMoneyMinor,
    this.limit = 50,
    this.offset = 0,
  });

  final int bookId;
  final int? startMs;
  final int? endMs;

  /// Optional record type: e.g. [RecordType.expense], [RecordType.income],
  /// [RecordType.transfer]. Null means all records (except internal type 15).
  final int? type;

  /// Optional set of category IDs to filter.
  final Set<int>? categoryIds;

  /// Optional asset ID. Matches `asset_id`, `from_asset_id`, or `to_asset_id`.
  final int? assetId;

  /// Keyword to match against `remark` via `LIKE`.
  final String? keyword;

  /// Minimum amount in minor units (int64 cents).
  final BigInt? minMoneyMinor;

  /// Maximum amount in minor units (int64 cents).
  final BigInt? maxMoneyMinor;

  /// Page size limit.
  final int? limit;

  /// Page offset.
  final int? offset;

  SearchFilter copyWith({
    int? bookId,
    int? startMs,
    bool clearStartMs = false,
    int? endMs,
    bool clearEndMs = false,
    int? type,
    bool clearType = false,
    Set<int>? categoryIds,
    bool clearCategoryIds = false,
    int? assetId,
    bool clearAssetId = false,
    String? keyword,
    bool clearKeyword = false,
    BigInt? minMoneyMinor,
    bool clearMinMoney = false,
    BigInt? maxMoneyMinor,
    bool clearMaxMoney = false,
    int? limit,
    int? offset,
  }) {
    return SearchFilter(
      bookId: bookId ?? this.bookId,
      startMs: clearStartMs ? null : (startMs ?? this.startMs),
      endMs: clearEndMs ? null : (endMs ?? this.endMs),
      type: clearType ? null : (type ?? this.type),
      categoryIds: clearCategoryIds ? null : (categoryIds ?? this.categoryIds),
      assetId: clearAssetId ? null : (assetId ?? this.assetId),
      keyword: clearKeyword ? null : (keyword ?? this.keyword),
      minMoneyMinor: clearMinMoney
          ? null
          : (minMoneyMinor ?? this.minMoneyMinor),
      maxMoneyMinor: clearMaxMoney
          ? null
          : (maxMoneyMinor ?? this.maxMoneyMinor),
      limit: limit ?? this.limit,
      offset: offset ?? this.offset,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SearchFilter &&
          runtimeType == other.runtimeType &&
          bookId == other.bookId &&
          startMs == other.startMs &&
          endMs == other.endMs &&
          type == other.type &&
          _setEquals(categoryIds, other.categoryIds) &&
          assetId == other.assetId &&
          keyword == other.keyword &&
          minMoneyMinor == other.minMoneyMinor &&
          maxMoneyMinor == other.maxMoneyMinor &&
          limit == other.limit &&
          offset == other.offset;

  @override
  int get hashCode => Object.hash(
    bookId,
    startMs,
    endMs,
    type,
    categoryIds == null ? null : Object.hashAll(categoryIds!),
    assetId,
    keyword,
    minMoneyMinor,
    maxMoneyMinor,
    limit,
    offset,
  );

  static bool _setEquals<E>(Set<E>? a, Set<E>? b) {
    if (a == null) return b == null;
    if (b == null || a.length != b.length) return false;
    return a.containsAll(b);
  }
}

/// Search and filter queries for ledger records (F-002).
final class SearchQueries {
  SearchQueries(this.db);
  final AppDatabase db;

  SimpleSelectStatement<$RecordsTable, LedgerRecord> _buildQuery(
    SearchFilter filter, {
    bool applyPagination = true,
  }) {
    final query = db.select(db.records);
    query.where((t) {
      Expression<bool> predicate =
          t.accountBookId.equals(filter.bookId) & t.type.equals(15).not();

      if (filter.startMs != null) {
        predicate =
            predicate & t.recordTime.isBiggerOrEqualValue(filter.startMs!);
      }
      if (filter.endMs != null) {
        predicate =
            predicate & t.recordTime.isSmallerOrEqualValue(filter.endMs!);
      }
      if (filter.type != null) {
        predicate = predicate & t.type.equals(filter.type!);
      }
      if (filter.categoryIds != null && filter.categoryIds!.isNotEmpty) {
        predicate = predicate & t.recordCatId.isIn(filter.categoryIds!);
      }
      if (filter.assetId != null && filter.assetId != noRef) {
        predicate =
            predicate &
            (t.assetId.equals(filter.assetId!) |
                t.fromAssetId.equals(filter.assetId!) |
                t.toAssetId.equals(filter.assetId!));
      }
      if (filter.keyword != null && filter.keyword!.trim().isNotEmpty) {
        final escaped = escapeSqlLike(filter.keyword!.trim());
        predicate = predicate & t.remark.like('%$escaped%', escapeChar: r'\');
      }
      if (filter.minMoneyMinor != null) {
        predicate =
            predicate &
            t.moneyMinor.isBiggerOrEqualValue(filter.minMoneyMinor!);
      }
      if (filter.maxMoneyMinor != null) {
        predicate =
            predicate &
            t.moneyMinor.isSmallerOrEqualValue(filter.maxMoneyMinor!);
      }
      return predicate;
    });

    query.orderBy([
      (t) => OrderingTerm.desc(t.recordTime),
      (t) => OrderingTerm.desc(t.createDate),
      (t) => OrderingTerm.desc(t.recordId),
    ]);

    if (applyPagination && filter.limit != null) {
      query.limit(filter.limit!, offset: filter.offset ?? 0);
    }

    return query;
  }

  /// Watch paginated records matching [filter].
  Stream<List<LedgerRecord>> watchRecords(
    SearchFilter filter, {
    bool paginate = true,
  }) => _buildQuery(filter, applyPagination: paginate).watch();

  /// Get paginated records matching [filter] once.
  Future<List<LedgerRecord>> getRecords(
    SearchFilter filter, {
    bool paginate = true,
  }) => _buildQuery(filter, applyPagination: paginate).get();

  /// Watch all records matching [filter] (without pagination limit) for summary aggregation.
  Stream<List<LedgerRecord>> watchAllRecords(SearchFilter filter) =>
      _buildQuery(filter, applyPagination: false).watch();

  /// Watch income/expense summary of all records matching [filter].
  Stream<IncomeExpense> watchSummary(SearchFilter filter) => watchAllRecords(
    filter,
  ).map((records) => aggregateIncomeExpense(records.map(statEntryOf)));
}
