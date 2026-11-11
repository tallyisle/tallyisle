import 'package:drift/drift.dart';

import '../../domain/ledger/record_extra.dart';
import '../../domain/ledger/record_relations.dart';
import '../../domain/rules/category_stats.dart';
import '../db/database.dart';

/// Selection mode for filtering category IDs.
enum CategoryFilterMode { includeSelected, excludeSelected }

/// Filter criteria for category statistics (F-008 / F-030).
final class AnalyzeFilter {
  const AnalyzeFilter({
    required this.bookIds,
    required this.startMs,
    required this.endMs,
    this.categoryIds,
    this.categoryFilterMode = CategoryFilterMode.includeSelected,
    this.assetIds,
    this.tagIds,
    this.includeExcludeBudget = true,
    this.dimension = StatDimension.expense,
    this.rangeKind = StatRangeKind.month,
    this.outlierSmoothing = OutlierSmoothing.none,
  });

  final List<int> bookIds;
  final int startMs;
  final int endMs;
  final Set<int>? categoryIds;
  final CategoryFilterMode categoryFilterMode;
  final Set<int>? assetIds;
  final Set<String>? tagIds;
  final bool includeExcludeBudget;
  final StatDimension dimension;
  final StatRangeKind rangeKind;
  final OutlierSmoothing outlierSmoothing;

  AnalyzeFilter copyWith({
    List<int>? bookIds,
    int? startMs,
    int? endMs,
    Set<int>? categoryIds,
    bool clearCategoryIds = false,
    CategoryFilterMode? categoryFilterMode,
    Set<int>? assetIds,
    bool clearAssetIds = false,
    Set<String>? tagIds,
    bool clearTagIds = false,
    bool? includeExcludeBudget,
    StatDimension? dimension,
    StatRangeKind? rangeKind,
    OutlierSmoothing? outlierSmoothing,
  }) {
    return AnalyzeFilter(
      bookIds: bookIds ?? this.bookIds,
      startMs: startMs ?? this.startMs,
      endMs: endMs ?? this.endMs,
      categoryIds: clearCategoryIds ? null : (categoryIds ?? this.categoryIds),
      categoryFilterMode: categoryFilterMode ?? this.categoryFilterMode,
      assetIds: clearAssetIds ? null : (assetIds ?? this.assetIds),
      tagIds: clearTagIds ? null : (tagIds ?? this.tagIds),
      includeExcludeBudget: includeExcludeBudget ?? this.includeExcludeBudget,
      dimension: dimension ?? this.dimension,
      rangeKind: rangeKind ?? this.rangeKind,
      outlierSmoothing: outlierSmoothing ?? this.outlierSmoothing,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AnalyzeFilter &&
          runtimeType == other.runtimeType &&
          _listEquals(bookIds, other.bookIds) &&
          startMs == other.startMs &&
          endMs == other.endMs &&
          _setEquals(categoryIds, other.categoryIds) &&
          categoryFilterMode == other.categoryFilterMode &&
          _setEquals(assetIds, other.assetIds) &&
          _setEquals(tagIds, other.tagIds) &&
          includeExcludeBudget == other.includeExcludeBudget &&
          dimension == other.dimension &&
          rangeKind == other.rangeKind &&
          outlierSmoothing == other.outlierSmoothing;

  @override
  int get hashCode => Object.hash(
    Object.hashAll(bookIds),
    startMs,
    endMs,
    categoryIds == null ? null : Object.hashAll(categoryIds!),
    categoryFilterMode,
    assetIds == null ? null : Object.hashAll(assetIds!),
    tagIds == null ? null : Object.hashAll(tagIds!),
    includeExcludeBudget,
    dimension,
    rangeKind,
    outlierSmoothing,
  );

  static bool _listEquals<E>(List<E> a, List<E> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _setEquals<E>(Set<E>? a, Set<E>? b) {
    if (a == null) return b == null;
    if (b == null || a.length != b.length) return false;
    return a.containsAll(b);
  }
}

/// Query repository for category statistics and drilldown analysis.
final class CategoryStatsQueries {
  CategoryStatsQueries(this.db);
  final AppDatabase db;

  SimpleSelectStatement<$RecordsTable, LedgerRecord> _buildSimpleQuery(
    AnalyzeFilter filter,
  ) {
    final query = db.select(db.records);
    query.where((t) {
      Expression<bool> predicate =
          t.accountBookId.isIn(filter.bookIds) &
          t.recordTime.isBetweenValues(filter.startMs, filter.endMs) &
          t.excludeExIn.equals(false);

      if (!filter.includeExcludeBudget) {
        predicate = predicate & t.excludeBudget.equals(false);
      }
      if (filter.categoryIds != null && filter.categoryIds!.isNotEmpty) {
        if (filter.categoryFilterMode == CategoryFilterMode.includeSelected) {
          predicate = predicate & t.recordCatId.isIn(filter.categoryIds!);
        } else {
          predicate = predicate & t.recordCatId.isIn(filter.categoryIds!).not();
        }
      }
      if (filter.assetIds != null && filter.assetIds!.isNotEmpty) {
        predicate =
            predicate &
            (t.assetId.isIn(filter.assetIds!) |
                t.fromAssetId.isIn(filter.assetIds!) |
                t.toAssetId.isIn(filter.assetIds!));
      }
      return predicate;
    });

    query.orderBy([
      (t) => OrderingTerm.desc(t.recordTime),
      (t) => OrderingTerm.desc(t.createDate),
      (t) => OrderingTerm.desc(t.recordId),
    ]);

    return query;
  }

  JoinedSelectStatement _buildJoinedQuery(AnalyzeFilter filter) {
    final joined = db.select(db.records, distinct: true).join([
      innerJoin(
        db.tagRecords,
        db.tagRecords.recordId.equalsExp(db.records.recordId),
        useColumns: false,
      ),
    ]);

    Expression<bool> predicate =
        db.records.accountBookId.isIn(filter.bookIds) &
        db.records.recordTime.isBetweenValues(filter.startMs, filter.endMs) &
        db.records.excludeExIn.equals(false) &
        db.tagRecords.tagId.isIn(filter.tagIds!);

    if (!filter.includeExcludeBudget) {
      predicate = predicate & db.records.excludeBudget.equals(false);
    }
    if (filter.categoryIds != null && filter.categoryIds!.isNotEmpty) {
      if (filter.categoryFilterMode == CategoryFilterMode.includeSelected) {
        predicate =
            predicate & db.records.recordCatId.isIn(filter.categoryIds!);
      } else {
        predicate =
            predicate & db.records.recordCatId.isIn(filter.categoryIds!).not();
      }
    }
    if (filter.assetIds != null && filter.assetIds!.isNotEmpty) {
      predicate =
          predicate &
          (db.records.assetId.isIn(filter.assetIds!) |
              db.records.fromAssetId.isIn(filter.assetIds!) |
              db.records.toAssetId.isIn(filter.assetIds!));
    }

    joined.where(predicate);
    joined.orderBy([
      OrderingTerm.desc(db.records.recordTime),
      OrderingTerm.desc(db.records.createDate),
      OrderingTerm.desc(db.records.recordId),
    ]);

    return joined;
  }

  /// Watch transaction records matching [filter].
  Stream<List<LedgerRecord>> watchRecords(AnalyzeFilter filter) {
    if (filter.tagIds != null && filter.tagIds!.isNotEmpty) {
      return _buildJoinedQuery(filter).watch().map(
        (rows) => rows.map((r) => r.readTable(db.records)).toList(),
      );
    }
    return _buildSimpleQuery(filter).watch();
  }

  /// Retrieve transaction records matching [filter] once.
  Future<List<LedgerRecord>> getRecords(AnalyzeFilter filter) async {
    if (filter.tagIds != null && filter.tagIds!.isNotEmpty) {
      final rows = await _buildJoinedQuery(filter).get();
      return rows.map((r) => r.readTable(db.records)).toList();
    }
    return _buildSimpleQuery(filter).get();
  }

  /// Watch all categories belonging to any of the specified [bookIds].
  Stream<List<RecordCategory>> watchCategories(List<int> bookIds) {
    return (db.select(db.recordCategories)
          ..where((t) => t.accountBookId.isIn(bookIds))
          ..orderBy([
            (t) => OrderingTerm.asc(t.sort),
            (t) => OrderingTerm.asc(t.id),
          ]))
        .watch();
  }

  /// Retrieve all categories belonging to [bookIds] once.
  Future<List<RecordCategory>> getCategories(List<int> bookIds) {
    return (db.select(db.recordCategories)
          ..where((t) => t.accountBookId.isIn(bookIds))
          ..orderBy([
            (t) => OrderingTerm.asc(t.sort),
            (t) => OrderingTerm.asc(t.id),
          ]))
        .get();
  }
}

/// Convert Drift [RecordCategory] to pure domain [CategoryMeta].
CategoryMeta categoryMetaOf(RecordCategory cat) => CategoryMeta(
  id: cat.id,
  name: cat.name,
  icon: cat.icon,
  type: cat.type,
  parentCatId: cat.parentCatId,
  sort: cat.sort,
  accountBookId: cat.accountBookId,
);

/// Convert Drift [LedgerRecord] to pure domain [CategoryStatEntry].
CategoryStatEntry categoryStatEntryOf(
  LedgerRecord r, {
  List<String> tagIds = const [],
}) => CategoryStatEntry(
  recordId: r.recordId,
  accountBookId: r.accountBookId,
  recordTime: r.recordTime,
  type: r.type,
  subType: r.subType,
  moneyMinor: r.moneyMinor,
  discountMinor: r.discountMinor,
  recordCatId: r.recordCatId,
  assetId: r.assetId,
  fromAssetId: r.fromAssetId,
  toAssetId: r.toAssetId,
  currency: RecordExtra.parse(r.extraInfo).currency,
  relations: RecordRelations.parse(r.relInfo),
  excludeExIn: r.excludeExIn,
  excludeBudget: r.excludeBudget,
  remark: r.remark,
  tagIds: tagIds,
  createDate: r.createDate,
);
