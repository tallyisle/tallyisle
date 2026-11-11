import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../../core/failure.dart';
import '../../core/money.dart';
import '../../domain/ledger/record_extra.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/asset_overview.dart'
    show RateTable, normalizeCurrency;
import '../../domain/rules/currency_rates.dart' show baseCurrency, billSnapshot;
import '../../domain/rules/url_scheme_rules.dart';
import '../../platform/auto_bill_bridge.dart';
import '../db/database.dart';
import '../db/failures.dart';
import '../ledger/ledger_service.dart';

/// Outcome of executing a `tallyisle://` or `yyjz://` URI (`F-033`).
final class UrlSchemeExecutionResult {
  const UrlSchemeExecutionResult({
    required this.rawUri,
    required this.action,
    this.targetRoute,
    this.createdRecordId,
    this.resolvedBookId,
  });

  final String rawUri;
  final UrlSchemeAction action;
  final String? targetRoute;
  final String? createdRecordId;
  final int? resolvedBookId;

  bool get wroteRecord => createdRecordId != null;
}

/// Resolves books/categories/assets/tags and executes URL Scheme commands (`F-033`, `ADR-009`).
final class UrlSchemeService {
  UrlSchemeService(
    this.db, {
    LedgerService? ledgerService,
    AutoBillBridge? bridge,
  }) : _ledger = ledgerService ?? LedgerService(db),
       _bridge = bridge;

  final AppDatabase db;
  final LedgerService _ledger;
  final AutoBillBridge? _bridge;

  Stream<String>? get onDeepLink => _bridge?.onDeepLink;

  /// Consumes any cold-start pending deep link from [AutoBillBridge] and executes it.
  Future<UrlSchemeExecutionResult?> consumeAndExecutePendingDeepLink({
    String? commandId,
  }) async {
    final bridge = _bridge;
    if (bridge == null) return null;
    final pending = await bridge.consumePendingDeepLink();
    if (pending == null || pending.trim().isEmpty) return null;
    final effectiveCommandId =
        commandId ??
        'deeplink:${sha256.convert(utf8.encode('${db.nowMs()}:$pending')).toString().substring(0, 32)}';
    return executeUri(pending, commandId: effectiveCommandId);
  }

  /// Parses and executes a `tallyisle://` or `yyjz://` URI (`F-033`).
  ///
  /// - Navigation & `showsheet` URIs return `targetRoute` (and switch `current_book_id`
  ///   when a valid `book` parameter is supplied).
  /// - Direct `addbill` URIs resolve book/category/asset/tags by ID or name and
  ///   write idempotently via `LedgerService.saveRecord` (`ADR-009`).
  Future<UrlSchemeExecutionResult> executeUri(
    String rawUri, {
    required String commandId,
    int? nowMs,
  }) async {
    if (commandId.isEmpty || commandId.length > 128) {
      throw const Failure(FailureCode.validation, '提交标识无效');
    }
    final parsed = parseUrlScheme(rawUri);

    if (!parsed.writesDirectly) {
      return guardDatabase(() async {
        AccountBook? resolvedBook;
        if (parsed.bookRef != null) {
          resolvedBook = await _tryFindBook(parsed.bookRef!);
          if (resolvedBook != null) {
            await db
                .into(db.preferences)
                .insertOnConflictUpdate(
                  PreferencesCompanion.insert(
                    key: 'current_book_id',
                    value: '${resolvedBook.id}',
                  ),
                );
          }
        }
        var route = parsed.targetRoute;
        if (parsed.action == UrlSchemeAction.stat &&
            parsed.year != null &&
            parsed.month == null &&
            resolvedBook != null) {
          route = Uri(
            path: '/stats/annual',
            queryParameters: {
              'year': '${parsed.year}',
              'bookId': '${resolvedBook.id}',
            },
          ).toString();
        }
        return UrlSchemeExecutionResult(
          rawUri: parsed.rawUri,
          action: parsed.action,
          targetRoute: route,
          resolvedBookId: resolvedBook?.id,
        );
      });
    }

    final params = parsed.addBill!;
    final payloadHash = sha256
        .convert(utf8.encode(jsonEncode(['url-addbill-v1', parsed.rawUri])))
        .toString();

    return guardDatabase(
      () => db.transaction(() async {
        final previous = await (db.select(
          db.writeCommands,
        )..where((t) => t.commandId.equals(commandId))).getSingleOrNull();
        if (previous != null) {
          if (previous.payloadHash != payloadHash) {
            throw const Failure(FailureCode.conflict, '同一提交标识的内容发生变化');
          }
          final sep = previous.resultId.indexOf(':');
          final prevBookId = sep > 0
              ? int.tryParse(previous.resultId.substring(0, sep))
              : null;
          final prevRecordId = sep > 0
              ? previous.resultId.substring(sep + 1)
              : previous.resultId;
          return UrlSchemeExecutionResult(
            rawUri: parsed.rawUri,
            action: parsed.action,
            createdRecordId: prevRecordId,
            resolvedBookId: prevBookId,
          );
        }

        final book = await _resolveBookOrThrow(params.bookRef);
        final categoryId = await _resolveCategoryForAddBill(
          book: book,
          recordType: params.type,
          categoryRef: params.categoryRef,
        );

        final asset1 = await _resolveFundingAsset(
          ref: params.asset1Ref,
          bookId: book.id,
          label: params.type == RecordType.transfer ? '转出账户' : '账户',
        );
        final asset2 = params.type == RecordType.transfer
            ? await _resolveFundingAsset(
                ref: params.asset2Ref,
                bookId: book.id,
                label: '转入账户',
              )
            : null;

        if (params.type == RecordType.transfer) {
          if (asset1 == null || asset2 == null) {
            throw const Failure(
              FailureCode.validation,
              '转账 addbill 必须提供有效的转出账户与转入账户',
            );
          }
          if (asset1.id == asset2.id) {
            throw const Failure(FailureCode.validation, '转出和转入账户不能相同');
          }
        }

        final tagIds = await _resolveTags(params.tagRefs);
        final effectiveTimeMs = params.recordTimeMs ?? nowMs ?? db.nowMs();

        final extra = await _buildCurrencyExtra(
          recordType: params.type,
          grossMoney: params.money,
          netMoney: params.netMoney,
          primaryAsset: asset1,
          secondaryAsset: asset2,
        );

        final draft = RecordDraft(
          type: params.type,
          money: params.netMoney,
          bookId: book.id,
          recordTime: effectiveTimeMs,
          categoryId: categoryId,
          assetId:
              (params.type == RecordType.transfer ||
                  params.type == RecordType.reimbursable)
              ? noRef
              : (asset1?.id ?? noRef),
          fromAssetId: params.type == RecordType.transfer
              ? asset1!.id
              : (params.type == RecordType.reimbursable
                    ? (asset1?.id ?? noRef)
                    : noRef),
          toAssetId: params.type == RecordType.transfer ? asset2!.id : noRef,
          remark: params.remark,
          excludeBudget: params.excludeBudget,
          excludeExIn: params.excludeExIn,
          discount: params.discount,
          extra: extra,
          fee: params.type == RecordType.transfer ? params.fee : null,
          feeFromTarget: params.feeFromTarget,
          tagIds: tagIds,
        );

        final innerCommandId =
            'url-rec:${sha256.convert(utf8.encode(commandId)).toString()}';
        final recordId = await _ledger.saveRecord(
          commandId: innerCommandId,
          draft: draft,
        );

        await db
            .into(db.writeCommands)
            .insert(
              WriteCommandsCompanion.insert(
                commandId: commandId,
                payloadHash: payloadHash,
                resultId: '${book.id}:$recordId',
                committedAt: db.nowMs(),
              ),
            );

        return UrlSchemeExecutionResult(
          rawUri: parsed.rawUri,
          action: parsed.action,
          createdRecordId: recordId,
          resolvedBookId: book.id,
        );
      }),
    );
  }

  Future<AccountBook?> _tryFindBook(String ref) async {
    final trimmed = ref.trim();
    if (trimmed.isEmpty) return null;
    final books =
        await (db.select(db.accountBooks)..orderBy([
              (t) => OrderingTerm.asc(t.sort),
              (t) => OrderingTerm.asc(t.id),
            ]))
            .get();
    final id = int.tryParse(trimmed);
    if (id != null) {
      final byId = books.where((b) => b.id == id).firstOrNull;
      if (byId != null) return byId;
    }
    final lower = trimmed.toLowerCase();
    return books.where((b) => b.name.trim().toLowerCase() == lower).firstOrNull;
  }

  Future<AccountBook> _resolveBookOrThrow(String? bookRef) async {
    if (bookRef != null && bookRef.trim().isNotEmpty) {
      final found = await _tryFindBook(bookRef);
      if (found == null) {
        throw Failure(FailureCode.validation, '找不到账本：$bookRef');
      }
      return found;
    }
    final pref = await (db.select(
      db.preferences,
    )..where((t) => t.key.equals('current_book_id'))).getSingleOrNull();
    final currentId = int.tryParse(pref?.value ?? '') ?? 1;
    final byCurrent = await (db.select(
      db.accountBooks,
    )..where((t) => t.id.equals(currentId))).getSingleOrNull();
    if (byCurrent != null) return byCurrent;

    final first =
        await (db.select(db.accountBooks)
              ..orderBy([(t) => OrderingTerm.asc(t.id)])
              ..limit(1))
            .getSingleOrNull();
    if (first == null) {
      throw const Failure(FailureCode.validation, '当前尚无可用账本');
    }
    return first;
  }

  Future<int> _resolveCategoryForAddBill({
    required AccountBook book,
    required int recordType,
    required String? categoryRef,
  }) async {
    if (recordType == RecordType.transfer) return noRef;
    final wantCatType =
        (recordType == RecordType.income ||
            recordType == RecordType.advanceIncome)
        ? RecordType.income
        : RecordType.expense;

    final categories =
        await (db.select(db.recordCategories)
              ..where(
                (t) =>
                    t.accountBookId.equals(book.id) &
                    t.type.equals(wantCatType),
              )
              ..orderBy([
                (t) => OrderingTerm.asc(t.sort),
                (t) => OrderingTerm.asc(t.id),
              ]))
            .get();

    if (categoryRef != null && categoryRef.trim().isNotEmpty) {
      final matched = matchCategoryByRef(categories, categoryRef);
      if (matched == null) {
        throw Failure(
          FailureCode.validation,
          '在账本“${book.name}”中找不到分类：$categoryRef',
        );
      }
      return matched.id;
    }

    final fallback =
        categories.where((c) => !c.isHide).firstOrNull ??
        categories.firstOrNull;
    if (fallback == null) {
      throw Failure(FailureCode.validation, '账本“${book.name}”下暂无可用分类');
    }
    return fallback.id;
  }

  Future<Asset?> _resolveFundingAsset({
    required String? ref,
    required int bookId,
    required String label,
  }) async {
    if (ref == null || ref.trim().isEmpty) return null;
    final assets =
        await (db.select(db.assets)..orderBy([
              (t) => OrderingTerm.asc(t.sort),
              (t) => OrderingTerm.asc(t.id),
            ]))
            .get();
    final links = await db.select(db.assetBooks).get();
    final matched = matchFundingAssetByRef(
      assets: assets,
      links: links,
      bookId: bookId,
      rawRef: ref,
    );
    if (matched == null) {
      throw Failure(FailureCode.validation, '找不到可用$label：$ref');
    }
    return matched;
  }

  Future<List<String>> _resolveTags(List<String> tagRefs) async {
    if (tagRefs.isEmpty) return const [];
    final allTags = await db.select(db.tags).get();
    final out = <String>[];
    for (final rawRef in tagRefs) {
      final trimmed = rawRef.trim();
      if (trimmed.isEmpty) continue;
      final lower = trimmed.toLowerCase();
      final hit =
          allTags.where((t) => t.tagId == trimmed).firstOrNull ??
          allTags
              .where((t) => !t.hidden && t.name.trim().toLowerCase() == lower)
              .firstOrNull ??
          allTags
              .where((t) => t.name.trim().toLowerCase() == lower)
              .firstOrNull;
      if (hit != null && !out.contains(hit.tagId)) {
        out.add(hit.tagId);
      }
    }
    return out;
  }

  Future<RecordExtra> _buildCurrencyExtra({
    required int recordType,
    required Money grossMoney,
    required Money netMoney,
    required Asset? primaryAsset,
    required Asset? secondaryAsset,
  }) async {
    final extra = RecordExtra();
    final primaryCurrency =
        normalizeCurrency(primaryAsset?.currency) ?? baseCurrency;
    final secondaryCurrency =
        normalizeCurrency(secondaryAsset?.currency) ?? baseCurrency;

    if (recordType == RecordType.transfer) {
      if (primaryCurrency == baseCurrency &&
          secondaryCurrency == baseCurrency) {
        return extra;
      }
      final rates = await _loadRateTable();
      final convertedTargetMinor = primaryCurrency == secondaryCurrency
          ? netMoney.storageMinor
          : rates.convert(
              netMoney.storageMinor,
              primaryCurrency,
              secondaryCurrency,
            );
      extra.currency = billSnapshot(
        source: primaryCurrency,
        sourceMinor: netMoney.storageMinor,
        account: secondaryCurrency,
        assetMinor: convertedTargetMinor,
        rates: rates,
      );
      return extra;
    }

    if (primaryCurrency != baseCurrency) {
      final rates = await _loadRateTable();
      extra.currency = billSnapshot(
        source: primaryCurrency,
        sourceMinor: grossMoney.storageMinor,
        account: primaryCurrency,
        assetMinor: netMoney.storageMinor,
        rates: rates,
      );
    }
    return extra;
  }

  Future<RateTable> _loadRateTable() async {
    final rows = await db.select(db.currencies).get();
    return RateTable({for (final c in rows) c.code: c.rateToAnchor});
  }
}

/// Shared category resolver supporting numeric `id`, `"父分类>子分类"` path, or name.
RecordCategory? matchCategoryByRef(
  List<RecordCategory> categories,
  String rawRef,
) {
  final trimmed = rawRef.trim();
  if (trimmed.isEmpty) return null;

  final numericId = int.tryParse(trimmed);
  if (numericId != null) {
    final byId = categories.where((c) => c.id == numericId).firstOrNull;
    if (byId != null) return byId;
  }

  final pathMatch = RegExp(r'^(.+?)\s*[>/／\-]\s*(.+)$').firstMatch(trimmed);
  if (pathMatch != null) {
    final parentName = pathMatch.group(1)!.trim().toLowerCase();
    final childName = pathMatch.group(2)!.trim().toLowerCase();
    final parents = categories
        .where(
          (c) =>
              c.parentCatId == noRef &&
              c.name.trim().toLowerCase() == parentName,
        )
        .map((c) => c.id)
        .toSet();
    if (parents.isNotEmpty) {
      final childHit =
          categories
              .where(
                (c) =>
                    !c.isHide &&
                    parents.contains(c.parentCatId) &&
                    c.name.trim().toLowerCase() == childName,
              )
              .firstOrNull ??
          categories
              .where(
                (c) =>
                    parents.contains(c.parentCatId) &&
                    c.name.trim().toLowerCase() == childName,
              )
              .firstOrNull;
      if (childHit != null) return childHit;
    }
  }

  final lower = trimmed.toLowerCase();
  return categories
          .where((c) => !c.isHide && c.name.trim().toLowerCase() == lower)
          .firstOrNull ??
      categories.where((c) => c.name.trim().toLowerCase() == lower).firstOrNull;
}

/// Shared non-debt funding asset resolver supporting numeric `id` or exact name.
Asset? matchFundingAssetByRef({
  required List<Asset> assets,
  required List<AssetBook> links,
  required int bookId,
  required String rawRef,
}) => _matchAssetInternal(
  assets: assets,
  links: links,
  bookId: bookId,
  ref: rawRef,
  allowSubstringFallback: false,
);

/// Fuzzy funding asset resolver used by payment text & OCR hint pre-matching.
Asset? matchFundingAssetByHint({
  required List<Asset> assets,
  required List<AssetBook> links,
  required int bookId,
  required String? rawHint,
}) {
  if (rawHint == null || rawHint.trim().isEmpty) return null;
  return _matchAssetInternal(
    assets: assets,
    links: links,
    bookId: bookId,
    ref: rawHint,
    allowSubstringFallback: true,
  );
}

Asset? _matchAssetInternal({
  required List<Asset> assets,
  required List<AssetBook> links,
  required int bookId,
  required String ref,
  required bool allowSubstringFallback,
}) {
  final trimmed = ref.trim();
  if (trimmed.isEmpty) return null;

  final boundBooks = <int, Set<int>>{};
  for (final l in links) {
    boundBooks.putIfAbsent(l.assetId, () => <int>{}).add(l.bookId);
  }
  bool visibleInBook(Asset a) =>
      boundBooks[a.id] == null || boundBooks[a.id]!.contains(bookId);

  final eligible = assets
      .where((a) => a.type != AssetType.debt && a.status != AssetStatus.settled)
      .toList(growable: false);

  final numericId = int.tryParse(trimmed);
  if (numericId != null) {
    final byId = eligible.where((a) => a.id == numericId).firstOrNull;
    if (byId != null) return byId;
  }

  final lower = trimmed.toLowerCase();
  final exactCandidates = eligible
      .where((a) => a.name.trim().toLowerCase() == lower)
      .toList(growable: false);
  if (exactCandidates.isNotEmpty) {
    return exactCandidates
            .where((a) => visibleInBook(a) && a.status == AssetStatus.active)
            .firstOrNull ??
        exactCandidates.where(visibleInBook).firstOrNull ??
        exactCandidates.first;
  }

  if (!allowSubstringFallback) return null;

  final fuzzyCandidates = eligible
      .where((a) {
        final nameLower = a.name.trim().toLowerCase();
        return nameLower.isNotEmpty &&
            (lower.contains(nameLower) || nameLower.contains(lower));
      })
      .toList(growable: false);
  if (fuzzyCandidates.isEmpty) return null;
  fuzzyCandidates.sort((a, b) => b.name.length.compareTo(a.name.length));
  return fuzzyCandidates
          .where((a) => visibleInBook(a) && a.status == AssetStatus.active)
          .firstOrNull ??
      fuzzyCandidates.where(visibleInBook).firstOrNull ??
      fuzzyCandidates.first;
}
