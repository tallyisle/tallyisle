import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart' show databaseProvider;
import '../../data/db/database.dart';
import '../../domain/ledger/record_extra.dart';
import '../../domain/ledger/record_relations.dart';
import '../../domain/rules/billing_period.dart';
import '../../domain/rules/category_stats.dart';
import '../../domain/rules/tag_stats.dart';
import 'category_stats_providers.dart'
    show categoryStatsActivePeriodProvider, categoryStatsDimensionProvider;

/// Period mode for tag statistics (`全部 | 按月 | 按年`).
enum TagStatsPeriodMode { all, month, year }

/// Converts a Drift [Tag] row to pure domain [TagStatMeta].
TagStatMeta tagStatMetaOf(Tag t) => TagStatMeta(
  tagId: t.tagId,
  name: t.name,
  parentId: t.parentTagId,
  isGroup: t.parent == 1,
  color: t.color,
  sort: t.sort,
  hidden: t.hidden,
);

/// Converts a Drift [RecordCategory] row to pure domain [CategoryMeta].
CategoryMeta _categoryMetaOf(RecordCategory c) => CategoryMeta(
  id: c.id,
  name: c.name,
  icon: c.icon,
  type: c.type,
  parentCatId: c.parentCatId,
  sort: c.sort,
  accountBookId: c.accountBookId,
);

/// Converts a Drift [LedgerRecord] row to pure domain [CategoryStatEntry].
CategoryStatEntry _statEntryOfRecord(
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

/// Resolves the active [BillingPeriod] for [mode] and [offset], or `null` for `all`.
BillingPeriod? resolveTagStatsPeriod({
  required TagStatsPeriodMode mode,
  required int offset,
  required int startDay,
  DateTime? now,
}) {
  final moment = now ?? DateTime.now();
  switch (mode) {
    case TagStatsPeriodMode.all:
      return null;
    case TagStatsPeriodMode.month:
      final cur = BillingPeriod.containing(moment, startDay);
      return BillingPeriod.starting(cur.year, cur.month + offset, startDay);
    case TagStatsPeriodMode.year:
      final cur = BillingPeriod.containingYear(moment, startDay);
      return BillingPeriod.year(cur.year + offset, startDay);
  }
}

/// Formats period display text (`全部时间`, `YYYY-MM`, or `YYYY`).
String formatTagStatsPeriodLabel(
  TagStatsPeriodMode mode,
  BillingPeriod? period,
) {
  switch (mode) {
    case TagStatsPeriodMode.all:
      return '全部时间';
    case TagStatsPeriodMode.month:
      if (period == null) return '';
      return '${period.year}-${period.month.toString().padLeft(2, '0')}';
    case TagStatsPeriodMode.year:
      if (period == null) return '';
      return '${period.year}';
  }
}

/// Direct reactive stream of current book ID from `ti_preference`.
final tagStatsCurrentBookIdProvider = StreamProvider<int>((ref) async* {
  final db = await ref.watch(databaseProvider.future);
  final query = db.select(db.preferences)
    ..where((t) => t.key.equals('current_book_id'));
  yield* query.watchSingleOrNull().map(
    (p) => int.tryParse(p?.value ?? '') ?? 1,
  );
});

/// Direct reactive stream of the active [AccountBook].
final tagStatsCurrentBookProvider = StreamProvider<AccountBook?>((ref) async* {
  final db = await ref.watch(databaseProvider.future);
  final bookId = await ref.watch(tagStatsCurrentBookIdProvider.future);
  yield* (db.select(
    db.accountBooks,
  )..where((b) => b.id.equals(bookId))).watchSingleOrNull();
});

/// Direct reactive stream of all [Tag] rows ordered by `sort`, `name`.
final tagStatsAllTagsProvider = StreamProvider<List<Tag>>((ref) async* {
  final db = await ref.watch(databaseProvider.future);
  yield* (db.select(db.tags)..orderBy([
        (t) => OrderingTerm.asc(t.sort),
        (t) => OrderingTerm.asc(t.name),
      ]))
      .watch();
});

/// Direct reactive stream of [RecordCategory] rows in the current book.
final tagStatsCategoriesProvider = StreamProvider<List<RecordCategory>>((
  ref,
) async* {
  final db = await ref.watch(databaseProvider.future);
  final bookId = await ref.watch(tagStatsCurrentBookIdProvider.future);
  yield* (db.select(db.recordCategories)
        ..where((c) => c.accountBookId.equals(bookId))
        ..orderBy([
          (c) => OrderingTerm.asc(c.sort),
          (c) => OrderingTerm.asc(c.id),
        ]))
      .watch();
});

/// Direct reactive stream of all [Asset] rows.
final tagStatsAssetsProvider = StreamProvider<List<Asset>>((ref) async* {
  final db = await ref.watch(databaseProvider.future);
  yield* (db.select(db.assets)..orderBy([
        (a) => OrderingTerm.asc(a.sort),
        (a) => OrderingTerm.asc(a.id),
      ]))
      .watch();
});

/// Direct reactive stream of base currency code from `currency` table (defaults to `'CNY'`).
final tagStatsBaseCurrencyProvider = StreamProvider<String>((ref) async* {
  final db = await ref.watch(databaseProvider.future);
  yield* db.select(db.currencies).watch().map((rows) {
    for (final c in rows) {
      if (c.anchorCode.trim().isNotEmpty) {
        return c.anchorCode.trim().toUpperCase();
      }
    }
    return 'CNY';
  });
});

/// Reactive `Stream<Map<String, int>>` mapping `tagId -> distinct non-type-15 bill count`
/// in the current book (plus aggregated distinct bill count for parent tag groups).
final tagRecordCountsProvider = StreamProvider<Map<String, int>>((ref) async* {
  final db = await ref.watch(databaseProvider.future);
  final bookId = await ref.watch(tagStatsCurrentBookIdProvider.future);
  final tags = await ref.watch(tagStatsAllTagsProvider.future);
  final tagMetas = tags.map(tagStatMetaOf).toList();

  final joined =
      db.select(db.tagRecords).join([
        innerJoin(
          db.records,
          db.records.recordId.equalsExp(db.tagRecords.recordId),
          useColumns: false,
        ),
      ])..where(
        db.records.accountBookId.equals(bookId) &
            db.records.type.equals(15).not(),
      );

  await for (final rows in joined.watch()) {
    final recordTagIds = <String, List<String>>{};
    for (final row in rows) {
      final tr = row.readTable(db.tagRecords);
      recordTagIds.putIfAbsent(tr.recordId, () => <String>[]).add(tr.tagId);
    }
    yield computeTagRecordCounts(recordTagIds: recordTagIds, tags: tagMetas);
  }
});

// ---------------------------------------------------------------------------
// Tag Rankings Page (/stats/tags) state & providers
// ---------------------------------------------------------------------------

final class TagRankingsPeriodModeNotifier extends Notifier<TagStatsPeriodMode> {
  @override
  TagStatsPeriodMode build() => TagStatsPeriodMode.all;
  void setMode(TagStatsPeriodMode mode) => state = mode;
}

final tagRankingsPeriodModeProvider =
    NotifierProvider<TagRankingsPeriodModeNotifier, TagStatsPeriodMode>(
      TagRankingsPeriodModeNotifier.new,
    );

final class TagRankingsOffsetNotifier extends Notifier<int> {
  @override
  int build() => 0;
  void previous() => state = state - 1;
  void next() => state = state + 1;
  void reset() => state = 0;
}

final tagRankingsOffsetProvider =
    NotifierProvider<TagRankingsOffsetNotifier, int>(
      TagRankingsOffsetNotifier.new,
    );

final class TagRankingsBucketNotifier extends Notifier<StatBucket> {
  @override
  StatBucket build() => StatBucket.expense;
  void setBucket(StatBucket bucket) => state = bucket;
}

final tagRankingsBucketProvider =
    NotifierProvider<TagRankingsBucketNotifier, StatBucket>(
      TagRankingsBucketNotifier.new,
    );

final class TagRankingsRollupNotifier extends Notifier<bool> {
  @override
  bool build() => false;
  void setRollup(bool rollup) => state = rollup;
}

final tagRankingsRollupProvider =
    NotifierProvider<TagRankingsRollupNotifier, bool>(
      TagRankingsRollupNotifier.new,
    );

/// Query key for watching records + tag links in a time window `(startMs, endMs)`.
typedef _BookWindowKey = ({int bookId, int? startMs, int? endMs});

final _windowRecordsProvider =
    StreamProvider.family<List<LedgerRecord>, _BookWindowKey>((
      ref,
      key,
    ) async* {
      final db = await ref.watch(databaseProvider.future);
      final query = db.select(db.records)
        ..where((r) {
          Expression<bool> pred =
              r.accountBookId.equals(key.bookId) & r.type.equals(15).not();
          if (key.startMs != null && key.endMs != null) {
            pred =
                pred & r.recordTime.isBetweenValues(key.startMs!, key.endMs!);
          }
          return pred;
        })
        ..orderBy([
          (r) => OrderingTerm.desc(r.recordTime),
          (r) => OrderingTerm.desc(r.createDate),
          (r) => OrderingTerm.desc(r.recordId),
        ]);
      yield* query.watch();
    });

final _windowRecordTagIdsProvider =
    StreamProvider.family<Map<String, List<String>>, _BookWindowKey>((
      ref,
      key,
    ) async* {
      final db = await ref.watch(databaseProvider.future);
      final joined = db.select(db.tagRecords).join([
        innerJoin(
          db.records,
          db.records.recordId.equalsExp(db.tagRecords.recordId),
          useColumns: false,
        ),
      ]);
      Expression<bool> pred =
          db.records.accountBookId.equals(key.bookId) &
          db.records.type.equals(15).not();
      if (key.startMs != null && key.endMs != null) {
        pred =
            pred &
            db.records.recordTime.isBetweenValues(key.startMs!, key.endMs!);
      }
      joined.where(pred);

      await for (final rows in joined.watch()) {
        final map = <String, List<String>>{};
        for (final row in rows) {
          final tr = row.readTable(db.tagRecords);
          map.putIfAbsent(tr.recordId, () => <String>[]).add(tr.tagId);
        }
        yield map;
      }
    });

/// View model for `TagRankingsPage` (`/stats/tags`).
final class TagRankingsViewData {
  const TagRankingsViewData({
    required this.periodMode,
    required this.period,
    required this.rankings,
    required this.hasAnyTags,
    required this.hasTagGroups,
  });

  final TagStatsPeriodMode periodMode;
  final BillingPeriod? period;
  final TagRankingsResult rankings;
  final bool hasAnyTags;
  final bool hasTagGroups;
}

final tagRankingsViewProvider = Provider<AsyncValue<TagRankingsViewData>>((
  ref,
) {
  final bookIdAsync = ref.watch(tagStatsCurrentBookIdProvider);
  final bookAsync = ref.watch(tagStatsCurrentBookProvider);
  final tagsAsync = ref.watch(tagStatsAllTagsProvider);
  final baseCurrAsync = ref.watch(tagStatsBaseCurrencyProvider);
  final mode = ref.watch(tagRankingsPeriodModeProvider);
  final offset = ref.watch(tagRankingsOffsetProvider);
  final bucket = ref.watch(tagRankingsBucketProvider);
  final rollupGroups = ref.watch(tagRankingsRollupProvider);

  if (bookIdAsync.isLoading || bookAsync.isLoading || tagsAsync.isLoading) {
    return const AsyncValue.loading();
  }
  if (bookIdAsync.hasError) {
    return AsyncValue.error(bookIdAsync.error!, bookIdAsync.stackTrace!);
  }
  if (bookAsync.hasError) {
    return AsyncValue.error(bookAsync.error!, bookAsync.stackTrace!);
  }
  if (tagsAsync.hasError) {
    return AsyncValue.error(tagsAsync.error!, tagsAsync.stackTrace!);
  }

  final bookId = bookIdAsync.value!;
  final startDay = bookAsync.value?.startDay ?? 1;
  final period = resolveTagStatsPeriod(
    mode: mode,
    offset: offset,
    startDay: startDay,
  );
  final winKey = (
    bookId: bookId,
    startMs: period?.startMs,
    endMs: period?.endMs,
  );

  final recordsAsync = ref.watch(_windowRecordsProvider(winKey));
  final tagLinksAsync = ref.watch(_windowRecordTagIdsProvider(winKey));

  if (recordsAsync.isLoading || tagLinksAsync.isLoading) {
    return const AsyncValue.loading();
  }
  if (recordsAsync.hasError) {
    return AsyncValue.error(recordsAsync.error!, recordsAsync.stackTrace!);
  }
  if (tagLinksAsync.hasError) {
    return AsyncValue.error(tagLinksAsync.error!, tagLinksAsync.stackTrace!);
  }

  final allTags = tagsAsync.value!;
  final tagMetas = allTags.map(tagStatMetaOf).toList();
  final recordTagIds = tagLinksAsync.value!;
  final entries = recordsAsync.value!
      .map(
        (r) => _statEntryOfRecord(
          r,
          tagIds: recordTagIds[r.recordId] ?? const <String>[],
        ),
      )
      .toList();

  final targetCurrency = baseCurrAsync.value ?? 'CNY';
  final rankings = computeTagRankings(
    entries: entries,
    recordTagIds: recordTagIds,
    tags: tagMetas,
    bucket: bucket,
    rollupGroups: rollupGroups,
    targetCurrency: targetCurrency,
  );

  final hasGroups = allTags.any((t) => t.parent == 1);

  return AsyncValue.data(
    TagRankingsViewData(
      periodMode: mode,
      period: period,
      rankings: rankings,
      hasAnyTags: allTags.isNotEmpty,
      hasTagGroups: hasGroups,
    ),
  );
});

// ---------------------------------------------------------------------------
// Stats Hub (/stats) Tag Overview Card provider
// ---------------------------------------------------------------------------

/// Top tag rankings for the currently selected period & dimension on `StatsPage`.
final statsHubTagRankingsProvider = Provider<AsyncValue<TagRankingsResult>>((
  ref,
) {
  final bookIdAsync = ref.watch(tagStatsCurrentBookIdProvider);
  final periodAsync = ref.watch(categoryStatsActivePeriodProvider);
  final tagsAsync = ref.watch(tagStatsAllTagsProvider);
  final baseCurrAsync = ref.watch(tagStatsBaseCurrencyProvider);
  final dim = ref.watch(categoryStatsDimensionProvider);

  if (bookIdAsync.isLoading || periodAsync.isLoading || tagsAsync.isLoading) {
    return const AsyncValue.loading();
  }
  if (bookIdAsync.hasError) {
    return AsyncValue.error(bookIdAsync.error!, bookIdAsync.stackTrace!);
  }
  if (periodAsync.hasError) {
    return AsyncValue.error(periodAsync.error!, periodAsync.stackTrace!);
  }
  if (tagsAsync.hasError) {
    return AsyncValue.error(tagsAsync.error!, tagsAsync.stackTrace!);
  }

  final period = periodAsync.value!;
  final winKey = (
    bookId: bookIdAsync.value!,
    startMs: period.startMs,
    endMs: period.endMs,
  );

  final recordsAsync = ref.watch(_windowRecordsProvider(winKey));
  final tagLinksAsync = ref.watch(_windowRecordTagIdsProvider(winKey));

  if (recordsAsync.isLoading || tagLinksAsync.isLoading) {
    return const AsyncValue.loading();
  }
  if (recordsAsync.hasError) {
    return AsyncValue.error(recordsAsync.error!, recordsAsync.stackTrace!);
  }
  if (tagLinksAsync.hasError) {
    return AsyncValue.error(tagLinksAsync.error!, tagLinksAsync.stackTrace!);
  }

  final tagMetas = tagsAsync.value!.map(tagStatMetaOf).toList();
  final recordTagIds = tagLinksAsync.value!;
  final entries = recordsAsync.value!
      .map(
        (r) => _statEntryOfRecord(
          r,
          tagIds: recordTagIds[r.recordId] ?? const <String>[],
        ),
      )
      .toList();

  return AsyncValue.data(
    computeTagRankings(
      entries: entries,
      recordTagIds: recordTagIds,
      tags: tagMetas,
      bucket: StatBucket.fromStatDimension(dim),
      targetCurrency: baseCurrAsync.value ?? 'CNY',
    ),
  );
});

// ---------------------------------------------------------------------------
// Single Tag / Tag Group Detail Page (/stats/tag/:id) provider
// ---------------------------------------------------------------------------

typedef TagDetailQuery = ({String tagId, TagStatsPeriodMode mode, int offset});

final class TagDetailViewData {
  const TagDetailViewData({
    required this.periodMode,
    required this.period,
    required this.stats,
    required this.matchingRecords,
    required this.recordTags,
    required this.categories,
    required this.assets,
  });

  final TagStatsPeriodMode periodMode;
  final BillingPeriod? period;
  final SingleTagStatsResult stats;
  final List<LedgerRecord> matchingRecords;
  final Map<String, List<Tag>> recordTags;
  final List<RecordCategory> categories;
  final List<Asset> assets;
}

final tagDetailViewProvider =
    Provider.family<AsyncValue<TagDetailViewData>, TagDetailQuery>((
      ref,
      query,
    ) {
      final bookIdAsync = ref.watch(tagStatsCurrentBookIdProvider);
      final bookAsync = ref.watch(tagStatsCurrentBookProvider);
      final tagsAsync = ref.watch(tagStatsAllTagsProvider);
      final catsAsync = ref.watch(tagStatsCategoriesProvider);
      final assetsAsync = ref.watch(tagStatsAssetsProvider);
      final baseCurrAsync = ref.watch(tagStatsBaseCurrencyProvider);

      if (bookIdAsync.isLoading ||
          bookAsync.isLoading ||
          tagsAsync.isLoading ||
          catsAsync.isLoading ||
          assetsAsync.isLoading) {
        return const AsyncValue.loading();
      }
      if (bookIdAsync.hasError) {
        return AsyncValue.error(bookIdAsync.error!, bookIdAsync.stackTrace!);
      }
      if (bookAsync.hasError) {
        return AsyncValue.error(bookAsync.error!, bookAsync.stackTrace!);
      }
      if (tagsAsync.hasError) {
        return AsyncValue.error(tagsAsync.error!, tagsAsync.stackTrace!);
      }
      if (catsAsync.hasError) {
        return AsyncValue.error(catsAsync.error!, catsAsync.stackTrace!);
      }
      if (assetsAsync.hasError) {
        return AsyncValue.error(assetsAsync.error!, assetsAsync.stackTrace!);
      }

      final bookId = bookIdAsync.value!;
      final startDay = bookAsync.value?.startDay ?? 1;
      final period = resolveTagStatsPeriod(
        mode: query.mode,
        offset: query.offset,
        startDay: startDay,
      );
      final winKey = (
        bookId: bookId,
        startMs: period?.startMs,
        endMs: period?.endMs,
      );

      final recordsAsync = ref.watch(_windowRecordsProvider(winKey));
      final tagLinksAsync = ref.watch(_windowRecordTagIdsProvider(winKey));

      if (recordsAsync.isLoading || tagLinksAsync.isLoading) {
        return const AsyncValue.loading();
      }
      if (recordsAsync.hasError) {
        return AsyncValue.error(recordsAsync.error!, recordsAsync.stackTrace!);
      }
      if (tagLinksAsync.hasError) {
        return AsyncValue.error(
          tagLinksAsync.error!,
          tagLinksAsync.stackTrace!,
        );
      }

      final allTags = tagsAsync.value!;
      final tagById = <String, Tag>{for (final t in allTags) t.tagId: t};
      final tagMetas = allTags.map(tagStatMetaOf).toList();
      final categories = catsAsync.value!;
      final catMetas = <int, CategoryMeta>{
        for (final c in categories) c.id: _categoryMetaOf(c),
      };
      final assets = assetsAsync.value!;

      final allWindowRecords = recordsAsync.value!;
      final recordById = <String, LedgerRecord>{
        for (final r in allWindowRecords) r.recordId: r,
      };
      final recordTagIds = tagLinksAsync.value!;

      final entries = allWindowRecords
          .map(
            (r) => _statEntryOfRecord(
              r,
              tagIds: recordTagIds[r.recordId] ?? const <String>[],
            ),
          )
          .toList();

      final stats = computeSingleTagStats(
        targetTagId: query.tagId,
        entries: entries,
        recordTagIds: recordTagIds,
        tags: tagMetas,
        categories: catMetas,
        targetCurrency: baseCurrAsync.value ?? 'CNY',
      );

      final matchingRecords = <LedgerRecord>[
        for (final id in stats.matchingRecordIds)
          if (recordById.containsKey(id)) recordById[id]!,
      ];

      final recordTags = <String, List<Tag>>{};
      for (final r in matchingRecords) {
        final ids = recordTagIds[r.recordId] ?? const <String>[];
        final seen = <String>{};
        final list = <Tag>[];
        for (final tid in ids) {
          if (seen.add(tid) && tagById.containsKey(tid)) {
            list.add(tagById[tid]!);
          }
        }
        recordTags[r.recordId] = list;
      }

      return AsyncValue.data(
        TagDetailViewData(
          periodMode: query.mode,
          period: period,
          stats: stats,
          matchingRecords: matchingRecords,
          recordTags: recordTags,
          categories: categories,
          assets: assets,
        ),
      );
    });
