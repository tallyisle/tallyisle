import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart'
    show
        assetsProvider,
        booksProvider,
        currenciesProvider,
        currentBookIdProvider,
        databaseProvider;
import '../../data/db/database.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/reimburse_overview.dart';

/// Scope toggle state for `ReimbursePage`:
/// `false` = 当前账本 (`currentBookId`), `true` = 全部账本.
final class ReimburseScopeAllBooksNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;
  void setAllBooks(bool allBooks) => state = allBooks;
}

final reimburseScopeAllBooksProvider =
    NotifierProvider<ReimburseScopeAllBooksNotifier, bool>(
      ReimburseScopeAllBooksNotifier.new,
    );

/// Direct SQLite stream of all `type IN (3, 15)` records (reimbursable bills
/// and reimbursement receipts). Only awaits `databaseProvider.future` so it
/// never suffers from `StreamProvider.future` pause hazards.
final reimburseRawRecordsProvider = StreamProvider<List<LedgerRecord>>((
  ref,
) async* {
  final db = await ref.watch(databaseProvider.future);
  final query = db.select(db.records)
    ..where(
      (r) => r.type.isIn(const <int>[
        RecordType.reimbursable,
        RecordType.reimburseReceipt,
      ]),
    )
    ..orderBy([
      (r) => OrderingTerm.desc(r.recordTime),
      (r) => OrderingTerm.desc(r.createDate),
      (r) => OrderingTerm.desc(r.recordId),
    ]);
  yield* query.watch();
});

/// Direct SQLite stream of all categories across books so both single-book and
/// all-books reimbursement views resolve category icons, colors, and names.
final reimburseAllCategoriesProvider = StreamProvider<List<RecordCategory>>((
  ref,
) async* {
  final db = await ref.watch(databaseProvider.future);
  final query = db.select(db.recordCategories)
    ..orderBy([(c) => OrderingTerm.asc(c.sort), (c) => OrderingTerm.asc(c.id)]);
  yield* query.watch();
});

/// Picks the default receiving funding account (`status != settled` and
/// `type != debt`), preferring active ordinary funding accounts marked
/// `isDefault` or with the highest `usedTimes`.
int pickDefaultReceivingAssetId(List<Asset> eligibleAssets) {
  if (eligibleAssets.isEmpty) return noRef;

  final activeNormal = eligibleAssets
      .where(
        (a) => a.status == AssetStatus.active && a.type != AssetType.credit,
      )
      .toList();
  final activeAny = eligibleAssets
      .where((a) => a.status == AssetStatus.active)
      .toList();

  final pool = activeNormal.isNotEmpty
      ? activeNormal
      : (activeAny.isNotEmpty ? activeAny : List<Asset>.of(eligibleAssets));

  pool.sort((a, b) {
    if (a.isDefault != b.isDefault) {
      return a.isDefault ? -1 : 1;
    }
    final byUsed = b.usedTimes.compareTo(a.usedTimes);
    if (byUsed != 0) return byUsed;
    final bySort = a.sort.compareTo(b.sort);
    if (bySort != 0) return bySort;
    return a.id.compareTo(b.id);
  });

  return pool.first.id;
}

/// Resolved presentation row for a single reimbursable bill.
final class ReimburseBillRowView {
  const ReimburseBillRowView({
    required this.item,
    required this.title,
    required this.categoryDisplayName,
    required this.categoryIconKey,
    required this.parentCategoryIconKey,
    required this.categoryColorHex,
    required this.fundingAccountName,
    required this.fundingAsset,
    required this.bookName,
    required this.currencySymbol,
  });

  final ReimburseBillItem item;
  final String title;
  final String categoryDisplayName;
  final String? categoryIconKey;
  final String? parentCategoryIconKey;
  final String? categoryColorHex;
  final String fundingAccountName;
  final Asset? fundingAsset;
  final String bookName;
  final String currencySymbol;
}

/// Complete reactive view model consumed by `ReimbursePage`.
final class ReimburseViewData {
  const ReimburseViewData({
    required this.allBooksScope,
    required this.currentBookId,
    required this.currentBookName,
    required this.baseCurrencyCode,
    required this.baseCurrencySymbol,
    required this.overview,
    required this.pendingRows,
    required this.settledRows,
    required this.eligibleReceivingAssets,
    required this.defaultReceivingAssetId,
  });

  final bool allBooksScope;
  final int currentBookId;
  final String currentBookName;
  final String baseCurrencyCode;
  final String baseCurrencySymbol;
  final ReimburseOverview overview;
  final List<ReimburseBillRowView> pendingRows;
  final List<ReimburseBillRowView> settledRows;
  final List<Asset> eligibleReceivingAssets;
  final int defaultReceivingAssetId;
}

/// Synchronous reactive combiner watching all required SQLite streams via
/// `ref.watch(...)` with zero `.future` pause hazards on `StreamProvider`s.
final reimburseViewProvider = Provider<AsyncValue<ReimburseViewData>>((ref) {
  final allBooksScope = ref.watch(reimburseScopeAllBooksProvider);
  final currentBookIdAsync = ref.watch(currentBookIdProvider);
  final booksAsync = ref.watch(booksProvider);
  final assetsAsync = ref.watch(assetsProvider);
  final currenciesAsync = ref.watch(currenciesProvider);
  final recordsAsync = ref.watch(reimburseRawRecordsProvider);
  final categoriesAsync = ref.watch(reimburseAllCategoriesProvider);

  for (final asyncVal in <AsyncValue<Object?>>[
    currentBookIdAsync,
    booksAsync,
    assetsAsync,
    currenciesAsync,
    recordsAsync,
    categoriesAsync,
  ]) {
    if (asyncVal.hasError) {
      return AsyncValue.error(asyncVal.error!, asyncVal.stackTrace!);
    }
  }

  if (currentBookIdAsync.isLoading ||
      booksAsync.isLoading ||
      assetsAsync.isLoading ||
      recordsAsync.isLoading ||
      categoriesAsync.isLoading) {
    return const AsyncValue.loading();
  }

  final currentBookId = currentBookIdAsync.value!;
  final books = booksAsync.value!;
  final assets = assetsAsync.value!;
  final currencies = currenciesAsync.value ?? const <Currency>[];
  final allRecords = recordsAsync.value!;
  final categories = categoriesAsync.value!;

  final bookById = <int, AccountBook>{for (final b in books) b.id: b};
  final assetById = <int, Asset>{for (final a in assets) a.id: a};
  final catById = <int, RecordCategory>{for (final c in categories) c.id: c};

  var baseCurrencyCode = 'CNY';
  final symbolByCode = <String, String>{'CNY': '¥'};
  for (final c in currencies) {
    final code = c.code.trim().toUpperCase();
    if (code.isNotEmpty && c.symbol.trim().isNotEmpty) {
      symbolByCode[code] = c.symbol.trim();
    }
    if (c.anchorCode.trim().isNotEmpty) {
      baseCurrencyCode = c.anchorCode.trim().toUpperCase();
    }
  }
  final baseCurrencySymbol = symbolByCode[baseCurrencyCode] ?? '¥';

  final liveReceipts = <String, ReimburseReceiptInput>{};
  final scopedBills = <ReimburseBillInput>[];

  for (final r in allRecords) {
    if (r.type == RecordType.reimburseReceipt) {
      liveReceipts[r.recordId] = ReimburseReceiptInput(
        recordId: r.recordId,
        moneyMinor: r.moneyMinor,
        recordTime: r.recordTime,
        assetId: r.assetId,
        remark: r.remark,
        relInfo: r.relInfo,
        extraInfo: r.extraInfo,
      );
    } else if (r.type == RecordType.reimbursable) {
      if (!allBooksScope && r.accountBookId != currentBookId) {
        continue;
      }
      final fundingId = r.fromAssetId != noRef ? r.fromAssetId : r.assetId;
      scopedBills.add(
        ReimburseBillInput(
          recordId: r.recordId,
          bookId: r.accountBookId,
          type: r.type,
          moneyMinor: r.moneyMinor,
          recordTime: r.recordTime,
          createDate: r.createDate,
          categoryId: r.recordCatId,
          assetId: r.assetId,
          fromAssetId: r.fromAssetId,
          remark: r.remark,
          relInfo: r.relInfo,
          extraInfo: r.extraInfo,
          fallbackCurrencyCode: assetById[fundingId]?.currency,
        ),
      );
    }
  }

  final overview = computeReimburseOverview(
    scopedBills,
    liveReceipts: liveReceipts,
    baseCurrencyCode: baseCurrencyCode,
  );

  ReimburseBillRowView buildRowView(ReimburseBillItem item) {
    final cat = item.categoryId == noRef ? null : catById[item.categoryId];
    final parentCat = (cat != null && cat.parentCatId != noRef)
        ? catById[cat.parentCatId]
        : null;
    final categoryDisplayName = cat == null
        ? '未分类'
        : (parentCat != null ? '${parentCat.name} · ${cat.name}' : cat.name);
    final categoryColorHex =
        (cat?.colorFill != null && cat!.colorFill!.trim().isNotEmpty)
        ? cat.colorFill
        : parentCat?.colorFill;
    final trimmedRemark = item.remark.trim();
    final title = trimmedRemark.isNotEmpty
        ? trimmedRemark
        : categoryDisplayName;

    final fundingAsset = item.fundingAssetId == noRef
        ? null
        : assetById[item.fundingAssetId];
    final fundingAccountName = item.fundingAssetId == noRef
        ? '无账户'
        : (fundingAsset?.name ?? '账户已删除');
    final bookName = bookById[item.bookId]?.name ?? '日常账本';
    final currencySymbol = symbolByCode[item.currencyCode] ?? '¥';

    return ReimburseBillRowView(
      item: item,
      title: title,
      categoryDisplayName: categoryDisplayName,
      categoryIconKey: cat?.icon,
      parentCategoryIconKey: parentCat?.icon,
      categoryColorHex: categoryColorHex,
      fundingAccountName: fundingAccountName,
      fundingAsset: fundingAsset,
      bookName: bookName,
      currencySymbol: currencySymbol,
    );
  }

  final eligibleAssets = assets
      .where((a) => a.status != AssetStatus.settled && a.type != AssetType.debt)
      .toList();

  return AsyncValue.data(
    ReimburseViewData(
      allBooksScope: allBooksScope,
      currentBookId: currentBookId,
      currentBookName: bookById[currentBookId]?.name ?? '日常账本',
      baseCurrencyCode: baseCurrencyCode,
      baseCurrencySymbol: baseCurrencySymbol,
      overview: overview,
      pendingRows: overview.pendingItems.map(buildRowView).toList(),
      settledRows: overview.settledItems.map(buildRowView).toList(),
      eligibleReceivingAssets: eligibleAssets,
      defaultReceivingAssetId: pickDefaultReceivingAssetId(eligibleAssets),
    ),
  );
});
