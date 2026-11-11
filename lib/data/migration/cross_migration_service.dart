import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:sqlite3/sqlite3.dart' as raw_sqlite;

import '../../core/failure.dart';
import '../../core/money.dart';
import '../../domain/rules/ios_migration_rules.dart';
import '../../domain/rules/reminder_rules.dart';
import '../../platform/notifications.dart';
import '../db/database.dart';
import '../db/failures.dart';
import '../db/seed.dart';
import '../reminder/reminder_service.dart';
import 'lan_zip_crypto.dart';

/// Source kind of a migration / restore operation.
enum MigrationSourceKind {
  /// iOS -> Android `.yi2a` JSON file.
  yi2a,

  /// LAN `ServerBackup.zip` (plain or WinZip AE-2) or bare SQLite `.db` file.
  lanBackup,
}

/// Summary & cleaned payload returned by preflight before touching SQLite.
final class MigrationPreview {
  const MigrationPreview({
    required this.sourceKind,
    required this.fileName,
    required this.entryName,
    required this.payload,
    this.wasEncrypted = false,
    this.usedHistoricalPassword = false,
  });

  final MigrationSourceKind sourceKind;
  final String fileName;
  final String entryName;
  final MigrationPayload payload;
  final bool wasEncrypted;
  final bool usedHistoricalPassword;

  int get bookCount => payload.books.length;
  int get categoryCount => payload.categories.length;
  int get assetCount => payload.assets.length;
  int get recordCount => payload.records.length;
  int get budgetCount => payload.budgets.length;
  int get reminderCount => payload.reminders.length;
  int get assetBookRefCount => payload.assetBookRefs.length;
  int get statStoryCount => payload.statStory.length;
  int get totalEntityCount => payload.totalCrossEntityCount;
}

/// Outcome of inspecting a LAN `ServerBackup.zip` or bare `.db` file (`R8`, `CE-IOS-03`).
sealed class LanInspectOutcome {
  const LanInspectOutcome();
}

/// Ready to preview and restore in a single transaction.
final class LanInspectReady extends LanInspectOutcome {
  const LanInspectReady(this.preview);

  final MigrationPreview preview;
}

/// Archive is encrypted with a custom password (historical `"YYjz@23!"` did not match),
/// so UI should prompt the user to enter their custom password (`CE-IOS-03`).
final class LanInspectPasswordRequired extends LanInspectOutcome {
  const LanInspectPasswordRequired({
    required this.fileName,
    required this.entryName,
  });

  final String fileName;
  final String entryName;
}

/// User-supplied password failed verification (2-byte verifier or 10-byte HMAC-SHA1-80 MAC).
final class LanInspectWrongPassword extends LanInspectOutcome {
  const LanInspectWrongPassword({
    required this.fileName,
    required this.entryName,
    required this.verifierMatched,
  });

  final String fileName;
  final String entryName;
  final bool verifierMatched;
}

/// Result summary after committing a migration or LAN restore transaction.
final class MigrationApplyResult {
  const MigrationApplyResult({
    required this.activeBookId,
    required this.bookCount,
    required this.assetCount,
    required this.recordCount,
    required this.assetBookRefCount,
    required this.statStoryCount,
  });

  final int activeBookId;
  final int bookCount;
  final int assetCount;
  final int recordCount;
  final int assetBookRefCount;
  final int statStoryCount;
}

final class _AsyncMutex {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() action) {
    final completer = Completer<void>();
    final prev = _tail;
    _tail = prev.whenComplete(() => completer.future);
    return prev.then((_) => action()).whenComplete(() {
      if (!completer.isCompleted) completer.complete();
    });
  }
}

final Expando<_AsyncMutex> _dbMigrationLocks = Expando<_AsyncMutex>(
  'CrossMigrationServiceLocks',
);

/// Data service for M5 Module 4 (`F-035`):
/// - `.ya2i` export (Android -> iOS) across all 19 tables + optional `extraNotes`
/// - `.yi2a` preflight & single-transaction atomic import preserving `note`/`auto_map`/`currency`
/// - LAN `ServerBackup.zip` (plain + Zip4j WinZip AE-2 `"YYjz@23!"` / custom password) & `.db` restore
final class CrossMigrationService {
  CrossMigrationService(
    this.db, {
    ReminderService? reminderService,
    ReminderScheduler? reminderScheduler,
    Directory? tempRootDir,
  }) : _reminderService =
           reminderService ?? ReminderService(db, scheduler: reminderScheduler),
       _tempRootDir = tempRootDir;

  final AppDatabase db;
  final ReminderService _reminderService;
  final Directory? _tempRootDir;

  _AsyncMutex get _lock => _dbMigrationLocks[db] ??= _AsyncMutex();

  // ==========================================================================
  // 1. `.ya2i` Export (Android -> iOS)
  // ==========================================================================

  /// Reads all 19 cross-OS tables (plus local `note` for optional `extraNotes`)
  /// inside a consistent read transaction and encodes UTF-8 `.ya2i` bytes.
  Future<Uint8List> exportYa2iBytes({bool includeExtraNotes = true}) async {
    final payload = await buildExportPayload();
    return encodeYa2iBytes(payload, includeExtraNotes: includeExtraNotes);
  }

  /// Builds a [MigrationPayload] snapshot from the current [AppDatabase].
  Future<MigrationPayload> buildExportPayload() => _lock.run(
    () => guardDatabase(
      () => db.transaction(() async {
        final books = await (db.select(
          db.accountBooks,
        )..orderBy([(t) => OrderingTerm.asc(t.id)])).get();
        final categories = await (db.select(
          db.recordCategories,
        )..orderBy([(t) => OrderingTerm.asc(t.id)])).get();
        final assets = await (db.select(
          db.assets,
        )..orderBy([(t) => OrderingTerm.asc(t.id)])).get();
        final records = await (db.select(
          db.records,
        )..orderBy([(t) => OrderingTerm.asc(t.recordTime)])).get();
        final budgets = await (db.select(
          db.budgets,
        )..orderBy([(t) => OrderingTerm.asc(t.id)])).get();
        final platforms = await (db.select(
          db.importPlatforms,
        )..orderBy([(t) => OrderingTerm.asc(t.id)])).get();
        final installments = await (db.select(
          db.installments,
        )..orderBy([(t) => OrderingTerm.asc(t.id)])).get();
        final periods = await (db.select(
          db.recordPeriods,
        )..orderBy([(t) => OrderingTerm.asc(t.id)])).get();
        final reminders = await (db.select(
          db.reminderEvents,
        )..orderBy([(t) => OrderingTerm.asc(t.id)])).get();
        final tags = await (db.select(
          db.tags,
        )..orderBy([(t) => OrderingTerm.asc(t.tagId)])).get();
        final tagRefs = await db.select(db.tagRecords).get();
        final templates = await (db.select(
          db.recordTemplates,
        )..orderBy([(t) => OrderingTerm.asc(t.id)])).get();
        final bankCards = await (db.select(
          db.bankCards,
        )..orderBy([(t) => OrderingTerm.asc(t.id)])).get();
        final wishes = await (db.select(
          db.wishes,
        )..orderBy([(t) => OrderingTerm.asc(t.id)])).get();
        final remarks = await (db.select(
          db.remarks,
        )..orderBy([(t) => OrderingTerm.asc(t.id)])).get();
        final savePlans = await (db.select(
          db.moneySavePlans,
        )..orderBy([(t) => OrderingTerm.asc(t.id)])).get();
        final saveRecords = await (db.select(
          db.moneySavePlanRecords,
        )..orderBy([(t) => OrderingTerm.asc(t.id)])).get();
        final assetBookRefs = await db.select(db.assetBooks).get();
        final statStories = await (db.select(
          db.statStories,
        )..orderBy([(t) => OrderingTerm.asc(t.id)])).get();
        final notes = await (db.select(
          db.notes,
        )..orderBy([(t) => OrderingTerm.asc(t.id)])).get();

        return MigrationPayload(
          books: [
            for (final r in books)
              MigrationBookRow(
                id: r.id,
                type: r.type,
                name: r.name,
                cover: r.cover,
                sort: r.sort,
                status: r.status,
                startDay: r.startDay,
                createDate: r.createDate,
                displayWay: r.displayWay,
                extraInfo: r.extraInfo,
              ),
          ],
          categories: [
            for (final r in categories)
              MigrationCategoryRow(
                id: r.id,
                name: r.name,
                icon: r.icon,
                type: r.type,
                sort: r.sort,
                parentCatId: r.parentCatId,
                colorFill: r.colorFill,
                platformId: r.platformId,
                accountBookId: r.accountBookId,
                isHide: r.isHide,
                extraInfo: r.extraInfo,
              ),
          ],
          assets: [
            for (final r in assets)
              MigrationAssetRow(
                id: r.id,
                name: r.name,
                balanceMinor: r.balanceMinor,
                type: r.type,
                subType: r.subType,
                createDate: r.createDate,
                sort: r.sort,
                icon: r.icon,
                remark: r.remark,
                initMoneyMinor: r.initMoneyMinor,
                isDefault: r.isDefault,
                isEffectiveAsset: r.isEffectiveAsset,
                usedTimes: r.usedTimes,
                color: r.color,
                status: r.status,
                extraInfo: r.extraInfo,
                loanInfo: r.loanInfo,
                creditInfo: r.creditInfo,
                fixedDepositInfo: r.fixedDepositInfo,
                groupName: r.groupName,
                currency: r.currency,
              ),
          ],
          records: [
            for (final r in records)
              MigrationRecordRow(
                recordId: r.recordId,
                type: r.type,
                subType: r.subType,
                moneyMinor: r.moneyMinor,
                remark: r.remark,
                recordTime: r.recordTime,
                recordCatId: r.recordCatId,
                assetId: r.assetId,
                fromAssetId: r.fromAssetId,
                toAssetId: r.toAssetId,
                accountBookId: r.accountBookId,
                excludeBudget: r.excludeBudget,
                excludeExIn: r.excludeExIn,
                platformId: r.platformId,
                periodId: r.periodId,
                installment: r.installment,
                images: r.images,
                relInfo: r.relInfo,
                discountMinor: r.discountMinor,
                extraInfo: r.extraInfo,
                createDate: r.createDate,
              ),
          ],
          budgets: [
            for (final r in budgets)
              MigrationBudgetRow(
                id: r.id,
                budgetType: r.budgetType,
                recordCatId: r.recordCatId,
                amountMinor: r.amountMinor,
                bookId: r.bookId,
                section: r.section,
                sort: r.sort,
                createDate: r.createDate,
                remark: r.remark,
                extraInfo: r.extraInfo,
              ),
          ],
          importPlatforms: [
            for (final r in platforms)
              MigrationImportPlatformRow(
                id: r.id,
                platform: r.platform,
                importRecordCount: r.importRecordCount,
                importCategoryCount: r.importCategoryCount,
                importTime: r.importTime,
                hidden: r.hidden,
              ),
          ],
          installments: [
            for (final r in installments)
              MigrationInstallmentRow(
                id: r.id,
                name: r.name,
                catId: r.catId,
                principalMinor: r.principalMinor,
                periods: r.periods,
                chargeMinor: r.chargeMinor,
                chargeWay: r.chargeWay,
                remainderIn: r.remainderIn,
                calWay: r.calWay,
                startDate: r.startDate,
                assetId: r.assetId,
                nextPeriod: r.nextPeriod,
                nextPeriodDate: r.nextPeriodDate,
                credited: r.credited,
                bookId: r.bookId,
                excludeBudget: r.excludeBudget,
                excludeExIn: r.excludeExIn,
                createDate: r.createDate,
                tags: r.tags,
                images: r.images,
                exi: r.exi,
              ),
          ],
          periods: [
            for (final r in periods)
              MigrationPeriodRow(
                id: r.id,
                recordType: r.recordType,
                moneyMinor: r.moneyMinor,
                feeMinor: r.feeMinor,
                remark: r.remark,
                catId: r.catId,
                assetId: r.assetId,
                assetId2: r.assetId2,
                bookId: r.bookId,
                images: r.images,
                state: r.state,
                time: r.time,
                excludeBudget: r.excludeBudget,
                excludeExIn: r.excludeExIn,
                periodType: r.periodType,
                periodTypeDate: r.periodTypeDate,
                periodStartDate: r.periodStartDate,
                periodEndDate: r.periodEndDate,
                frequency: r.frequency,
                lastAddDate: r.lastAddDate,
                periodAddTimes: r.periodAddTimes,
                createTime: r.createTime,
                tags: r.tags,
                exi: r.exi,
              ),
          ],
          reminders: [
            for (final r in reminders)
              MigrationReminderRow(
                id: r.id,
                reminderTime: r.reminderTime,
                reminderTip: r.reminderTip,
              ),
          ],
          tags: [
            for (final r in tags)
              MigrationTagRow(
                tagId: r.tagId,
                name: r.name,
                sort: r.sort,
                hidden: r.hidden,
                parentTagId: r.parentTagId,
                parent: r.parent,
                color: r.color,
                extraInfo: r.extraInfo,
              ),
          ],
          tagRefs: [
            for (final r in tagRefs)
              MigrationTagRefRow(tagId: r.tagId, recordId: r.recordId),
          ],
          templates: [
            for (final r in templates)
              MigrationTemplateRow(
                id: r.id,
                type: r.type,
                remark: r.remark,
                moneyMinor: r.moneyMinor,
                feeMinor: r.feeMinor,
                recordCatId: r.recordCatId,
                assetId: r.assetId,
                assetId2: r.assetId2,
                sort: r.sort,
                autoSave: r.autoSave,
                bookId: r.bookId,
                excludeBudget: r.excludeBudget,
                excludeExIn: r.excludeExIn,
                createDate: r.createDate,
                tags: r.tags,
                exi: r.exi,
              ),
          ],
          bankCards: [
            for (final r in bankCards)
              MigrationBankCardRow(
                id: r.id,
                cardType: r.cardType,
                cardName: r.cardName,
                cardNo: r.cardNo,
                cardOwner: r.cardOwner,
                remark: r.remark,
                cardColor: r.cardColor,
                sort: r.sort,
                createDate: r.createDate,
                cardAssetId: r.cardAssetId,
              ),
          ],
          wishes: [
            for (final r in wishes)
              MigrationWishRow(
                id: r.id,
                content: r.content,
                valueMinor: r.valueMinor,
                createDate: r.createDate,
                isRealized: r.isRealized,
                realizedDate: r.realizedDate,
                sort: r.sort,
                icon: r.icon,
                targetDate: r.targetDate,
              ),
          ],
          remarks: [
            for (final r in remarks)
              MigrationRemarkRow(
                id: r.id,
                content: r.content,
                recordCatId: r.recordCatId,
                usedTimes: r.usedTimes,
              ),
          ],
          moneySavePlans: [
            for (final r in savePlans)
              MigrationSavingsPlanRow(
                id: r.id,
                name: r.name,
                remark: r.remark,
                planType: r.planType,
                cycleType: r.cycleType,
                startDate: r.startDate,
                endDate: r.endDate,
                planMoneyMinor: r.planMoneyMinor,
                savedMoneyMinor: r.savedMoneyMinor,
                autoPlan: r.autoPlan,
                fromAssetId: r.fromAssetId,
                toAssetId: r.toAssetId,
                bookId: r.bookId,
                startMoneyMinor: r.startMoneyMinor,
                incrementalMinor: r.incrementalMinor,
                status: r.status,
                createDate: r.createDate,
                sort: r.sort,
                nextSaveDate: r.nextSaveDate,
                bbzDailyTimes: r.bbzDailyTimes,
                icon: r.icon,
                extraInfo: r.extraInfo,
              ),
          ],
          moneySavePlanRecords: [
            for (final r in saveRecords)
              MigrationSavingsRecordRow(
                id: r.id,
                planId: r.planId,
                remark: r.remark,
                fromAssetId: r.fromAssetId,
                toAssetId: r.toAssetId,
                recordDate: r.recordDate,
                recordMoneyMinor: r.recordMoneyMinor,
                recordId: r.recordId,
              ),
          ],
          assetBookRefs: [
            for (final r in assetBookRefs)
              MigrationAssetBookRow(assetId: r.assetId, bookId: r.bookId),
          ],
          statStory: [
            for (final r in statStories)
              MigrationStatStoryRow(
                id: r.id,
                story: r.story,
                bookId: r.bookId,
                sdate: r.sdate,
                edate: r.edate,
                dsection: r.dsection,
              ),
          ],
          extraNotes: [
            for (final n in notes)
              MigrationNoteRow(
                id: n.id,
                title: n.title,
                content: n.content,
                createTime: n.createTime,
                updateTime: n.updateTime,
                trashTime: n.trashTime,
              ),
          ],
        );
      }),
    ),
  );

  // ==========================================================================
  // 2. `.yi2a` Preflight & Direct Import (`R1..R7`, `CE-IOS-01..02`)
  // ==========================================================================

  /// Validates extension, JSON structure, short-key mapping, and non-empty
  /// preflight (`R1`) WITHOUT touching the local SQLite database.
  MigrationPreview preflightYi2a({
    required String fileName,
    required Uint8List bytes,
  }) {
    final payload = parseYi2aBytes(bytes, fileName: fileName);
    return MigrationPreview(
      sourceKind: MigrationSourceKind.yi2a,
      fileName: fileName,
      entryName: fileName,
      payload: payload,
    );
  }

  /// Convenience one-step preflight + atomic import for `.yi2a` bytes.
  Future<MigrationApplyResult> importYi2aBytes({
    required String commandId,
    required String fileName,
    required Uint8List bytes,
  }) async {
    final preview = preflightYi2a(fileName: fileName, bytes: bytes);
    return applyMigrationPayload(
      commandId: commandId,
      payload: preview.payload,
    );
  }

  // ==========================================================================
  // 3. LAN `ServerBackup.zip` & Bare `.db` Inspection (`R8`, `DR-IMP-09`, `CE-IOS-03`)
  // ==========================================================================

  /// Inspects a LAN `ServerBackup.zip` (unencrypted, `"YYjz@23!"` AE-2, or custom
  /// password AE-2) or bare `.db` file without modifying the active database:
  /// - When [password] is null or blank and an encrypted ZIP is encountered,
  ///   automatically tries historical password `"YYjz@23!"` (`DR-IMP-09`).
  /// - If `"YYjz@23!"` fails, returns [LanInspectPasswordRequired] cleanly so the
  ///   UI prompts the user for their custom password (`CE-IOS-03`).
  /// - If a user-supplied [password] fails, returns [LanInspectWrongPassword].
  /// - Extracts the SQLite `.db` to a temporary directory, inspects Room v42 /
  ///   TallyIsle tables read-only via `package:sqlite3`, converts REAL amounts to
  ///   exact `int64` minor units, drops `sstatus == 4` tombstones, and always
  ///   deletes temporary files in `finally`.
  Future<LanInspectOutcome> inspectLanBackup({
    required String fileName,
    required Uint8List bytes,
    String? password,
  }) async {
    final hasUserPassword = password != null && password.isNotEmpty;
    var usedHistoricalPassword = false;

    LanExtractionResult extraction = extractLanSqliteBytes(
      bytes: bytes,
      fileName: fileName,
      password: hasUserPassword ? password : null,
    );

    if (extraction is LanExtractionPasswordRequired && !hasUserPassword) {
      final historicalAttempt = extractLanSqliteBytes(
        bytes: bytes,
        fileName: fileName,
        password: historicalLanZipPassword,
      );
      if (historicalAttempt is LanExtractionSuccess) {
        extraction = historicalAttempt;
        usedHistoricalPassword = true;
      } else {
        return LanInspectPasswordRequired(
          fileName: fileName,
          entryName: extraction.entryName,
        );
      }
    }

    switch (extraction) {
      case LanExtractionPasswordRequired(:final entryName):
        return LanInspectPasswordRequired(
          fileName: fileName,
          entryName: entryName,
        );
      case LanExtractionWrongPassword(:final entryName, :final verifierMatched):
        return LanInspectWrongPassword(
          fileName: fileName,
          entryName: entryName,
          verifierMatched: verifierMatched,
        );
      case LanExtractionSuccess(
        :final dbBytes,
        :final entryName,
        :final wasEncrypted,
      ):
        final payload = await _readPayloadFromSqliteBytes(dbBytes);
        return LanInspectReady(
          MigrationPreview(
            sourceKind: MigrationSourceKind.lanBackup,
            fileName: fileName,
            entryName: entryName,
            payload: payload,
            wasEncrypted: wasEncrypted,
            usedHistoricalPassword: usedHistoricalPassword,
          ),
        );
    }
  }

  Future<MigrationPayload> _readPayloadFromSqliteBytes(
    Uint8List dbBytes,
  ) async {
    final rootDir = _tempRootDir ?? Directory.systemTemp;
    final tempDir = rootDir.createTempSync('ti_lan_restore_');
    raw_sqlite.Database? sourceDb;
    try {
      final dbFile = File('${tempDir.path}/source.db');
      dbFile.writeAsBytesSync(dbBytes, flush: true);

      try {
        sourceDb = raw_sqlite.sqlite3.open(
          dbFile.path,
          mode: raw_sqlite.OpenMode.readOnly,
        );
      } on raw_sqlite.SqliteException {
        throw const Failure(FailureCode.corruptData, '备份数据库文件损坏，无法读取');
      }

      return _extractMigrationPayloadFromRawDb(sourceDb);
    } on Failure {
      rethrow;
    } on raw_sqlite.SqliteException {
      throw const Failure(FailureCode.corruptData, '备份数据库结构损坏，无法完成解析');
    } finally {
      try {
        sourceDb?.close();
      } catch (_) {}
      try {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      } catch (_) {}
    }
  }

  MigrationPayload _extractMigrationPayloadFromRawDb(
    raw_sqlite.Database sourceDb,
  ) {
    final tableRows = sourceDb.select(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    );
    final tables = <String>{
      for (final r in tableRows)
        if (r['name'] is String) r['name'] as String,
    };

    Set<String> columnsOf(String table) {
      if (!tables.contains(table)) return const {};
      final info = sourceDb.select('PRAGMA table_info("$table")');
      return <String>{
        for (final r in info)
          if (r['name'] is String) r['name'] as String,
      };
    }

    List<raw_sqlite.Row> activeRows(String table, Set<String> cols) {
      if (cols.isEmpty) return const [];
      if (cols.contains('sstatus')) {
        return sourceDb.select(
          'SELECT * FROM "$table" WHERE COALESCE(sstatus, 0) != 4',
        );
      }
      return sourceDb.select('SELECT * FROM "$table"');
    }

    const recognizedTables = <String>{
      'account_book',
      'record_category',
      'asset',
      'record',
      'budget',
      'import_platform',
      'installment',
      'record_period',
      'reminder_event',
      'tag',
      'tag_record',
      'record_template',
      'bank_card',
      'wish',
      'remark',
      'money_save_plan',
      'money_save_plan_record',
      'asset_book',
      'stat_story',
      'note',
      'auto_map',
      'currency',
    };
    if (tables.intersection(recognizedTables).isEmpty) {
      throw const Failure(FailureCode.corruptData, '数据库内未找到可识别的账本数据表');
    }

    // 1. account_book
    final bookCols = columnsOf('account_book');
    final books = deduplicateBooks([
      for (final r in activeRows('account_book', bookCols))
        MigrationBookRow(
          id: _sqlInt(r['id'], label: 'account_book.id'),
          type: _sqlInt(r['type'], fallback: 1),
          name: _sqlString(r['name'], fallback: '日常账本'),
          cover: _sqlString(r['cover'], fallback: ''),
          sort: _sqlInt(r['sort'], fallback: 1),
          status: _sqlInt(r['status'], fallback: 0),
          startDay: _sqlInt(r['start_day'], fallback: 1),
          createDate: _sqlInt(r['create_date'], fallback: 0),
          displayWay: _sqlInt(r['display_way'], fallback: 0),
          extraInfo: _sqlNullableString(r['extra_info']),
        ),
    ]);

    // 2. record_category
    final catCols = columnsOf('record_category');
    final categories = _dedupeRows([
      for (final r in activeRows('record_category', catCols))
        MigrationCategoryRow(
          id: _sqlInt(r['id'], label: 'record_category.id'),
          name: _sqlString(r['name'], fallback: ''),
          icon: _sqlString(r['icon'], fallback: ''),
          type: _sqlInt(r['type'], fallback: 0),
          sort: _sqlInt(r['sort'], fallback: 0),
          parentCatId: _sqlInt(r['parent_cat_id'], fallback: -1),
          colorFill: _sqlNullableString(r['color_fill']),
          platformId: _sqlInt(r['platform_id'], fallback: -1),
          accountBookId: _sqlInt(r['account_book_id'], fallback: 1),
          isHide: _sqlBool(r['is_hide']),
          extraInfo: _sqlNullableString(r['extra_info']),
        ),
    ], (r) => r.id);

    // 3. asset
    final assetCols = columnsOf('asset');
    final assetIsMinor = assetCols.contains('balance_minor');
    final assets = _dedupeRows([
      for (final r in activeRows('asset', assetCols))
        MigrationAssetRow(
          id: _sqlInt(r['id'], label: 'asset.id'),
          name: _sqlString(r['name'], fallback: ''),
          balanceMinor: _sqlMoneyMinor(
            r,
            minorCol: 'balance_minor',
            majorCol: 'balance',
            hasMinorCol: assetIsMinor,
          ),
          type: _sqlInt(r['type'], fallback: 0),
          subType: _sqlInt(r['sub_type'], fallback: -1),
          createDate: _sqlInt(r['create_date'], fallback: 0),
          sort: _sqlInt(r['sort'], fallback: 0),
          icon: _sqlString(r['icon'], fallback: ''),
          remark: _sqlNullableString(r['remark']),
          initMoneyMinor: _sqlMoneyMinor(
            r,
            minorCol: 'init_money_minor',
            majorCol: 'init_money',
            hasMinorCol: assetCols.contains('init_money_minor'),
          ),
          isDefault: _sqlBool(r['is_default']),
          isEffectiveAsset: _sqlInt(r['is_effective_asset'], fallback: 1),
          usedTimes: _sqlInt(r['used_times'], fallback: 0),
          color: _sqlNullableString(r['color']),
          status: _sqlInt(r['status'], fallback: 0),
          extraInfo: convertAssetExtraInfoOnImport(
            _sqlNullableString(r['extra_info']),
            sourceIsMinor: assetIsMinor,
          ),
          loanInfo: convertAssetLoanInfoOnImport(
            _sqlNullableString(r['loan_info']),
            sourceIsMinor: assetIsMinor,
          ),
          creditInfo: convertAssetCreditInfoOnImport(
            _sqlNullableString(r['credit_info']),
            sourceIsMinor: assetIsMinor,
          ),
          fixedDepositInfo: convertAssetFixedDepositInfoOnImport(
            _sqlNullableString(r['fixed_deposit_info']),
            sourceIsMinor: assetIsMinor,
          ),
          groupName: _sqlNullableString(r['group_name']),
          currency: _sqlNullableString(r['currency']),
        ),
    ], (r) => r.id);

    // 4. record
    final recCols = columnsOf('record');
    final recIsMinor = recCols.contains('money_minor');
    final records = _dedupeRows([
      for (final r in activeRows('record', recCols))
        MigrationRecordRow(
          recordId: _sqlNonEmptyString(r['record_id'], 'record.record_id'),
          type: _sqlInt(r['type'], fallback: 0),
          subType: _sqlInt(r['sub_type'], fallback: -1),
          moneyMinor: _sqlMoneyMinor(
            r,
            minorCol: 'money_minor',
            majorCol: 'money',
            hasMinorCol: recIsMinor,
          ),
          remark: _sqlString(r['remark'], fallback: ''),
          recordTime: _sqlInt(r['record_time'], label: 'record.record_time'),
          recordCatId: _sqlInt(r['record_cat_id'], fallback: -1),
          assetId: _sqlInt(r['asset_id'], fallback: -1),
          fromAssetId: _sqlInt(r['from_asset_id'], fallback: -1),
          toAssetId: _sqlInt(r['to_asset_id'], fallback: -1),
          accountBookId: _sqlInt(r['account_book_id'], fallback: 1),
          excludeBudget: _sqlBool(r['exclude_budget']),
          excludeExIn: _sqlBool(r['exclude_ex_in']),
          platformId: _sqlInt(r['platform_id'], fallback: -1),
          periodId: _sqlInt(r['period_id'], fallback: -1),
          installment: _sqlNullableString(r['installment']),
          images: _sqlNullableString(r['images']),
          relInfo: convertRecordRelInfoOnImport(
            _sqlNullableString(r['rel_info']),
            sourceIsMinor: recIsMinor,
          ),
          discountMinor: _sqlNullableMoneyMinor(
            r,
            minorCol: 'discount_minor',
            majorCol: 'discount',
            hasMinorCol: recCols.contains('discount_minor'),
          ),
          extraInfo: convertRecordExtraInfoOnImport(
            _sqlNullableString(r['extra_info']),
            sourceIsMinor: recIsMinor,
          ),
          createDate: r['create_date'] == null
              ? null
              : _sqlInt(r['create_date']),
        ),
    ], (r) => r.recordId);

    // 5. budget
    final budCols = columnsOf('budget');
    final budIsMinor = budCols.contains('amount_minor');
    final budgets = _dedupeRows([
      for (final r in activeRows('budget', budCols))
        MigrationBudgetRow(
          id: _sqlInt(r['id'], label: 'budget.id'),
          budgetType: _sqlInt(r['budget_type'], fallback: 0),
          recordCatId: _sqlInt(r['record_cat_id'], fallback: -1),
          amountMinor: _sqlMoneyMinor(
            r,
            minorCol: 'amount_minor',
            majorCol: 'amount',
            hasMinorCol: budIsMinor,
          ),
          bookId: _sqlInt(r['book_id'], fallback: 1),
          section: _sqlString(r['section'], fallback: ''),
          sort: _sqlInt(r['sort'], fallback: 0),
          createDate: _sqlInt(r['create_date'], fallback: 0),
          remark: _sqlNullableString(r['remark']),
          extraInfo: convertBudgetExtraInfoOnImport(
            _sqlNullableString(r['extra_info']),
            sourceIsMinor: budIsMinor,
          ),
        ),
    ], (r) => r.id);

    // 6. import_platform
    final platCols = columnsOf('import_platform');
    final importPlatforms = _dedupeRows([
      for (final r in activeRows('import_platform', platCols))
        MigrationImportPlatformRow(
          id: _sqlInt(r['id'], label: 'import_platform.id'),
          platform: _sqlString(r['platform'], fallback: ''),
          importRecordCount: _sqlInt(r['import_record_count'], fallback: 0),
          importCategoryCount: _sqlInt(r['import_category_count'], fallback: 0),
          importTime: _sqlInt(r['import_time'], fallback: 0),
          hidden: _sqlBool(r['hidden']),
        ),
    ], (r) => r.id);

    // 7. installment
    final instCols = columnsOf('installment');
    final instIsMinor = instCols.contains('principal_minor');
    final installments = _dedupeRows([
      for (final r in activeRows('installment', instCols))
        MigrationInstallmentRow(
          id: _sqlInt(r['id'], label: 'installment.id'),
          name: _sqlString(r['name'], fallback: ''),
          catId: _sqlInt(r['cat_id'], fallback: -1),
          principalMinor: _sqlMoneyMinor(
            r,
            minorCol: 'principal_minor',
            majorCol: 'principal_money',
            hasMinorCol: instIsMinor,
          ),
          periods: _sqlInt(r['periods'], fallback: 1),
          chargeMinor: _sqlMoneyMinor(
            r,
            minorCol: 'charge_minor',
            majorCol: 'charge',
            hasMinorCol: instCols.contains('charge_minor'),
          ),
          chargeWay: _sqlInt(r['charge_way'], fallback: 1),
          remainderIn: _sqlInt(r['remainder_in'], fallback: 0),
          calWay: _sqlInt(r['cal_way'], fallback: 2),
          startDate: _sqlInt(r['start_date'], fallback: 0),
          assetId: _sqlInt(r['asset_id'], fallback: -1),
          nextPeriod: _sqlInt(r['next_period'], fallback: 1),
          nextPeriodDate: _sqlInt(r['next_period_date'], fallback: 0),
          credited: _sqlNullableString(r['credited']),
          bookId: _sqlInt(r['book_id'], fallback: 1),
          excludeBudget: _sqlBool(r['exclude_budget']),
          excludeExIn: _sqlBool(r['exclude_ex_in']),
          createDate: _sqlInt(r['create_date'], fallback: 0),
          tags: _sqlNullableString(r['tags']),
          images: _sqlNullableString(r['images']),
          exi: _sqlNullableString(r['exi']),
        ),
    ], (r) => r.id);

    // 8. record_period
    final perCols = columnsOf('record_period');
    final perIsMinor = perCols.contains('money_minor');
    final periods = _dedupeRows([
      for (final r in activeRows('record_period', perCols))
        MigrationPeriodRow(
          id: _sqlInt(r['id'], label: 'record_period.id'),
          recordType: _sqlInt(r['record_type'], fallback: 0),
          moneyMinor: _sqlMoneyMinor(
            r,
            minorCol: 'money_minor',
            majorCol: 'money',
            hasMinorCol: perIsMinor,
          ),
          feeMinor: _sqlMoneyMinor(
            r,
            minorCol: 'fee_minor',
            majorCol: 'fee',
            hasMinorCol: perCols.contains('fee_minor'),
          ),
          remark: _sqlString(r['remark'], fallback: ''),
          catId: _sqlInt(r['cat_id'], fallback: -1),
          assetId: _sqlInt(r['asset_id'], fallback: -1),
          assetId2: _sqlInt(r['asset_id2'], fallback: -1),
          bookId: _sqlInt(r['book_id'], fallback: 1),
          images: _sqlNullableString(r['images']),
          state: _sqlInt(r['state'], fallback: 0),
          time: _sqlNullableString(r['time']),
          excludeBudget: _sqlBool(r['exclude_budget']),
          excludeExIn: _sqlBool(r['exclude_ex_in']),
          periodType: _sqlInt(r['period_type'], fallback: 0),
          periodTypeDate: _sqlString(r['period_type_date'], fallback: '[]'),
          periodStartDate: _sqlInt(r['period_start_date'], fallback: 0),
          periodEndDate: _sqlInt(r['period_end_date'], fallback: -1),
          frequency: _sqlInt(r['frequency'], fallback: 1),
          lastAddDate: _sqlInt(r['last_add_date'], fallback: -1),
          periodAddTimes: _sqlInt(r['period_add_times'], fallback: 0),
          createTime: _sqlInt(r['create_time'], fallback: 0),
          tags: _sqlNullableString(r['tags']),
          exi: _sqlNullableString(r['exi']),
        ),
    ], (r) => r.id);

    // 9. reminder_event
    final remCols = columnsOf('reminder_event');
    final reminders = _dedupeRows([
      for (final r in activeRows('reminder_event', remCols))
        MigrationReminderRow(
          id: _sqlInt(r['id'], label: 'reminder_event.id'),
          reminderTime: normalizeReminderMinuteOfDay(
            _sqlInt(r['reminder_time'], label: 'reminder_event.reminder_time'),
          ),
          reminderTip: r['reminder_tip'] == null
              ? null
              : normalizeReminderTip(r['reminder_tip'].toString()),
        ),
    ], (r) => r.id);

    // 10. tag
    final tagCols = columnsOf('tag');
    final tags = _dedupeRows([
      for (final r in activeRows('tag', tagCols))
        MigrationTagRow(
          tagId: _sqlNonEmptyString(r['tag_id'], 'tag.tag_id'),
          name: _sqlString(r['name'], fallback: ''),
          sort: _sqlInt(r['sort'], fallback: 0),
          hidden: _sqlBool(r['hidden']),
          parentTagId: _sqlNullableString(r['parent_tag_id']),
          parent: _sqlInt(r['parent'], fallback: 0),
          color: _sqlNullableString(r['color']),
          extraInfo: _sqlNullableString(r['extra_info']),
        ),
    ], (r) => r.tagId);

    // 11. tag_record
    final tagRefCols = columnsOf('tag_record');
    final tagRefs = _dedupeRows([
      for (final r in activeRows('tag_record', tagRefCols))
        MigrationTagRefRow(
          tagId: _sqlNonEmptyString(r['tag_id'], 'tag_record.tag_id'),
          recordId: _sqlNonEmptyString(r['record_id'], 'tag_record.record_id'),
        ),
    ], (r) => '${r.tagId}\u0000${r.recordId}');

    // 12. record_template
    final tplCols = columnsOf('record_template');
    final tplIsMinor = tplCols.contains('money_minor');
    final templates = _dedupeRows([
      for (final r in activeRows('record_template', tplCols))
        MigrationTemplateRow(
          id: _sqlInt(r['id'], label: 'record_template.id'),
          type: _sqlInt(r['type'], fallback: 0),
          remark: _sqlNullableString(r['remark']),
          moneyMinor: _sqlMoneyMinor(
            r,
            minorCol: 'money_minor',
            majorCol: 'money',
            hasMinorCol: tplIsMinor,
          ),
          feeMinor: _sqlMoneyMinor(
            r,
            minorCol: 'fee_minor',
            majorCol: 'fee',
            hasMinorCol: tplCols.contains('fee_minor'),
          ),
          recordCatId: r['record_cat_id'] == null
              ? null
              : _sqlInt(r['record_cat_id']),
          assetId: _sqlInt(r['asset_id'], fallback: -1),
          assetId2: _sqlInt(r['asset_id2'], fallback: -1),
          sort: _sqlInt(r['sort'], fallback: 0),
          autoSave: _sqlBool(r['auto_save']),
          bookId: _sqlInt(r['book_id'], fallback: 1),
          excludeBudget: _sqlBool(r['exclude_budget']),
          excludeExIn: _sqlBool(r['exclude_ex_in']),
          createDate: _sqlInt(r['create_date'], fallback: 0),
          tags: _sqlNullableString(r['tags']),
          exi: convertRecordExtraInfoOnImport(
            _sqlNullableString(r['exi']),
            sourceIsMinor: tplIsMinor,
          ),
        ),
    ], (r) => r.id);

    // 13. bank_card
    final cardCols = columnsOf('bank_card');
    final bankCards = _dedupeRows([
      for (final r in activeRows('bank_card', cardCols))
        MigrationBankCardRow(
          id: _sqlInt(r['id'], label: 'bank_card.id'),
          cardType: _sqlInt(r['card_type'], fallback: 0),
          cardName: _sqlString(r['card_name'], fallback: ''),
          cardNo: _sqlString(r['card_no'], fallback: ''),
          cardOwner: _sqlString(r['card_owner'], fallback: ''),
          remark: _sqlString(r['remark'], fallback: ''),
          cardColor: _sqlNullableString(r['card_color']),
          sort: _sqlInt(r['sort'], fallback: -1),
          createDate: _sqlInt(r['create_date'], fallback: 0),
          cardAssetId: _sqlInt(r['card_asset_id'], fallback: -1),
        ),
    ], (r) => r.id);

    // 14. wish
    final wishCols = columnsOf('wish');
    final wishIsMinor = wishCols.contains('value_minor');
    final wishes = _dedupeRows([
      for (final r in activeRows('wish', wishCols))
        MigrationWishRow(
          id: _sqlNonEmptyString(r['id'], 'wish.id'),
          content: _sqlString(r['content'], fallback: ''),
          valueMinor: _sqlMoneyMinor(
            r,
            minorCol: 'value_minor',
            majorCol: 'value',
            hasMinorCol: wishIsMinor,
          ),
          createDate: _sqlInt(r['create_date'], fallback: 0),
          isRealized: _sqlBool(r['is_realized']),
          realizedDate: _sqlInt(r['realized_date'], fallback: 0),
          sort: _sqlInt(r['sort'], fallback: 0),
          icon: _sqlNullableString(r['icon']),
          targetDate: _sqlInt(r['target_date'], fallback: 0),
        ),
    ], (r) => r.id);

    // 15. remark
    final remarkCols = columnsOf('remark');
    final remarks = _dedupeRows([
      for (final r in activeRows('remark', remarkCols))
        MigrationRemarkRow(
          id: _sqlInt(r['id'], label: 'remark.id'),
          content: _sqlString(r['content'], fallback: ''),
          recordCatId: _sqlInt(r['record_cat_id'], fallback: -1),
          usedTimes: _sqlInt(r['used_times'], fallback: 0),
        ),
    ], (r) => r.id);

    // 16. money_save_plan
    final planCols = columnsOf('money_save_plan');
    final planIsMinor = planCols.contains('plan_money_minor');
    final moneySavePlans = _dedupeRows([
      for (final r in activeRows('money_save_plan', planCols))
        MigrationSavingsPlanRow(
          id: _sqlInt(r['id'], label: 'money_save_plan.id'),
          name: _sqlString(r['name'], fallback: ''),
          remark: _sqlString(r['remark'], fallback: ''),
          planType: _sqlInt(r['plan_type'], fallback: 0),
          cycleType: _sqlInt(r['cycle_type'], fallback: -1),
          startDate: _sqlInt(r['start_date'], fallback: 0),
          endDate: _sqlInt(r['end_date'], fallback: 0),
          planMoneyMinor: _sqlMoneyMinor(
            r,
            minorCol: 'plan_money_minor',
            majorCol: 'plan_money',
            hasMinorCol: planIsMinor,
          ),
          savedMoneyMinor: _sqlMoneyMinor(
            r,
            minorCol: 'saved_money_minor',
            majorCol: 'saved_money',
            hasMinorCol: planCols.contains('saved_money_minor'),
          ),
          autoPlan: _sqlBool(r['auto_plan']),
          fromAssetId: _sqlInt(r['from_asset_id'], fallback: -1),
          toAssetId: _sqlInt(r['to_asset_id'], fallback: -1),
          bookId: _sqlInt(r['book_id'], fallback: -1),
          startMoneyMinor: _sqlMoneyMinor(
            r,
            minorCol: 'start_money_minor',
            majorCol: 'start_money',
            hasMinorCol: planCols.contains('start_money_minor'),
          ),
          incrementalMinor: _sqlMoneyMinor(
            r,
            minorCol: 'incremental_minor',
            majorCol: 'incremental',
            hasMinorCol: planCols.contains('incremental_minor'),
          ),
          status: _sqlInt(r['status'], fallback: 0),
          createDate: _sqlInt(r['create_date'], fallback: 0),
          sort: _sqlInt(r['sort'], fallback: 0),
          nextSaveDate: _sqlInt(r['next_save_date'], fallback: 0),
          bbzDailyTimes: _sqlInt(r['bbz_daily_times'], fallback: 0),
          icon: _sqlNullableString(r['icon']),
          extraInfo: _sqlNullableString(r['extra_info']),
        ),
    ], (r) => r.id);

    // 17. money_save_plan_record
    final planRecCols = columnsOf('money_save_plan_record');
    final planRecIsMinor = planRecCols.contains('record_money_minor');
    final moneySavePlanRecords = _dedupeRows([
      for (final r in activeRows('money_save_plan_record', planRecCols))
        MigrationSavingsRecordRow(
          id: _sqlInt(r['id'], label: 'money_save_plan_record.id'),
          planId: _sqlInt(r['plan_id'], fallback: 0),
          remark: _sqlString(r['remark'], fallback: ''),
          fromAssetId: _sqlInt(r['from_asset_id'], fallback: -1),
          toAssetId: _sqlInt(r['to_asset_id'], fallback: -1),
          recordDate: _sqlInt(r['record_date'], fallback: 0),
          recordMoneyMinor: _sqlMoneyMinor(
            r,
            minorCol: 'record_money_minor',
            majorCol: 'record_money',
            hasMinorCol: planRecIsMinor,
          ),
          recordId: _sqlNullableString(r['record_id']),
        ),
    ], (r) => r.id);

    // 18. asset_book
    final abCols = columnsOf('asset_book');
    final assetBookRefs = _dedupeRows([
      for (final r in activeRows('asset_book', abCols))
        MigrationAssetBookRow(
          assetId: _sqlInt(r['asset_id'], label: 'asset_book.asset_id'),
          bookId: _sqlInt(r['book_id'], label: 'asset_book.book_id'),
        ),
    ], (r) => '${r.assetId}:${r.bookId}');

    // 19. stat_story
    final storyCols = columnsOf('stat_story');
    final statStory = _dedupeRows([
      for (final r in activeRows('stat_story', storyCols))
        MigrationStatStoryRow(
          id: _sqlNonEmptyString(r['id'], 'stat_story.id'),
          story: _sqlString(r['story'], fallback: ''),
          bookId: _sqlInt(r['book_id'], fallback: 1),
          sdate: _sqlInt(r['sdate'], fallback: 0),
          edate: _sqlInt(r['edate'], fallback: 0),
          dsection: _sqlNullableString(r['dsection']),
        ),
    ], (r) => r.id);

    // Optional LAN tables: preserved locally when absent or empty in source `.db`
    final noteCols = columnsOf('note');
    final parsedNotes = _dedupeRows([
      for (final r in activeRows('note', noteCols))
        MigrationNoteRow(
          id: _sqlInt(r['id'], label: 'note.id'),
          title: _sqlNullableString(r['title']),
          content: _sqlString(r['content'], fallback: ''),
          createTime: _sqlInt(r['create_time'], fallback: 0),
          updateTime: _sqlInt(r['update_time'], fallback: 0),
          trashTime: _sqlInt(r['trash_time'], fallback: 0),
        ),
    ], (r) => r.id);

    final autoMapCols = columnsOf('auto_map');
    final parsedAutoMaps = _dedupeRows([
      for (final r in activeRows('auto_map', autoMapCols))
        MigrationAutoMapRow(
          id: _sqlInt(r['id'], label: 'auto_map.id'),
          key: _sqlString(r['key'], fallback: ''),
          mapInfo: _sqlNullableString(r['map_info']),
          draft: _sqlNullableString(r['draft']),
        ),
    ], (r) => r.id);

    final currCols = columnsOf('currency');
    final parsedCurrencies = <MigrationCurrencyRow>[];
    final seenCodes = <String>{};
    for (final r in activeRows('currency', currCols)) {
      final code = _sqlString(r['code'], fallback: '').trim();
      if (code.isEmpty || !seenCodes.add(code)) continue;
      final rateDec = parseExactDecimal(
        r['rate_to_anchor'] ?? '1',
        fieldName: 'currency.rate_to_anchor',
      );
      if (rateDec.coefficient <= BigInt.zero) continue;
      parsedCurrencies.add(
        MigrationCurrencyRow(
          code: code,
          name: _sqlString(r['name'], fallback: code),
          symbol: _sqlString(r['symbol'], fallback: code),
          type: _sqlInt(r['type'], fallback: 0),
          rateToAnchor: formatExactDecimalString(rateDec),
          anchorCode: _sqlString(r['anchor_code'], fallback: 'CNY'),
          rateRefreshTime: _sqlInt(r['rate_refresh_time'], fallback: 0),
          icon: _sqlNullableString(r['icon']),
          enable: _sqlBool(r['enable'], fallback: true),
        ),
      );
    }

    final payload = MigrationPayload(
      books: books,
      categories: categories,
      assets: assets,
      records: records,
      budgets: budgets,
      importPlatforms: importPlatforms,
      installments: installments,
      periods: periods,
      reminders: reminders,
      tags: tags,
      tagRefs: tagRefs,
      templates: templates,
      bankCards: bankCards,
      wishes: wishes,
      remarks: remarks,
      moneySavePlans: moneySavePlans,
      moneySavePlanRecords: moneySavePlanRecords,
      assetBookRefs: assetBookRefs,
      statStory: statStory,
      lanNotes: parsedNotes.isEmpty ? null : parsedNotes,
      lanAutoMaps: parsedAutoMaps.isEmpty ? null : parsedAutoMaps,
      lanCurrencies: parsedCurrencies.isEmpty ? null : parsedCurrencies,
    );

    if (payload.isEmptyCrossPayload &&
        payload.lanNotes == null &&
        payload.lanAutoMaps == null) {
      throw const Failure(
        FailureCode.validation,
        '备份数据库不包含有效账本记录，已拒绝恢复以保护本地数据',
      );
    }
    return payload;
  }

  // ==========================================================================
  // 4. Single-Transaction Atomic Replacement (`R5`, `R6`, `CE-IOS-02`)
  // ==========================================================================

  /// Atomically replaces the 19 cross-OS tables inside a single SQLite
  /// transaction (`R5`), preserving local `note`, `auto_map`, and `currency`
  /// (`R6` / `CE-IOS-02`), resetting `current_book_id` to a valid book, and
  /// resynchronizing OS daily reminders upon commit.
  Future<MigrationApplyResult> applyMigrationPayload({
    required String commandId,
    required MigrationPayload payload,
    void Function()? debugFailAfterClear,
  }) async {
    if (commandId.isEmpty || commandId.length > 128) {
      throw const Failure(FailureCode.validation, '提交标识无效');
    }
    if (payload.isEmptyCrossPayload &&
        (payload.lanNotes == null || payload.lanNotes!.isEmpty)) {
      throw const Failure(FailureCode.validation, '迁移数据为空，已拦截导入以保护本地账本');
    }

    final hashInput = <Object?>[
      'cross-migration-apply-v1',
      sha256
          .convert(encodeYa2iBytes(payload, includeExtraNotes: false))
          .toString(),
      payload.lanNotes?.length,
      payload.lanAutoMaps?.length,
      payload.lanCurrencies?.length,
    ];
    final payloadHash = sha256
        .convert(utf8.encode(jsonEncode(hashInput)))
        .toString();

    final applyResult = await _lock.run(
      () => guardDatabase(
        () => db.transaction(() async {
          final existingCmd = await (db.select(
            db.writeCommands,
          )..where((t) => t.commandId.equals(commandId))).getSingleOrNull();
          if (existingCmd != null) {
            if (existingCmd.payloadHash != payloadHash) {
              throw const Failure(FailureCode.conflict, '同一提交标识的内容发生变化');
            }
            final parsedActiveBook =
                int.tryParse(existingCmd.resultId) ??
                payload.resolveActiveBookId();
            return MigrationApplyResult(
              activeBookId: parsedActiveBook,
              bookCount: payload.books.isEmpty ? 1 : payload.books.length,
              assetCount: payload.assets.length,
              recordCount: payload.records.length,
              assetBookRefCount: payload.assetBookRefs.length,
              statStoryCount: payload.statStory.length,
            );
          }

          // 1. Delete ONLY the 19 cross-OS tables (NEVER `note`, `auto_map`, `currency` unless LAN `.db` explicitly carries non-empty rows)
          await db.delete(db.tagRecords).go();
          await db.delete(db.assetBooks).go();
          await db.delete(db.moneySavePlanRecords).go();
          await db.delete(db.moneySavePlans).go();
          await db.delete(db.records).go();
          await db.delete(db.budgets).go();
          await db.delete(db.installments).go();
          await db.delete(db.recordPeriods).go();
          await db.delete(db.reminderEvents).go();
          await db.delete(db.recordTemplates).go();
          await db.delete(db.bankCards).go();
          await db.delete(db.wishes).go();
          await db.delete(db.remarks).go();
          await db.delete(db.importPlatforms).go();
          await db.delete(db.tags).go();
          await db.delete(db.statStories).go();
          await db.delete(db.assets).go();
          await db.delete(db.recordCategories).go();
          await db.delete(db.accountBooks).go();

          if (payload.lanNotes != null && payload.lanNotes!.isNotEmpty) {
            await db.delete(db.notes).go();
          }
          if (payload.lanAutoMaps != null && payload.lanAutoMaps!.isNotEmpty) {
            await db.delete(db.autoMaps).go();
          }
          if (payload.lanCurrencies != null &&
              payload.lanCurrencies!.isNotEmpty) {
            await db.delete(db.currencies).go();
          }

          // Optional fault-injection hook for verifying full transaction rollback (`R5`)
          if (debugFailAfterClear != null) {
            debugFailAfterClear();
          }

          final nowMs = db.nowMs();
          final effectiveBooks = payload.books.isNotEmpty
              ? payload.books
              : <MigrationBookRow>[
                  MigrationBookRow(
                    id: defaultBookId,
                    name: '日常账本',
                    createDate: nowMs,
                  ),
                ];

          // 2. Batch-insert all 19 tables (preserving exact primary keys & references)
          await db.batch((b) {
            b.insertAll(db.accountBooks, [
              for (final r in effectiveBooks)
                AccountBooksCompanion.insert(
                  id: Value(r.id),
                  type: Value(r.type),
                  name: r.name,
                  cover: Value(r.cover),
                  sort: Value(r.sort),
                  status: Value(r.status),
                  startDay: Value(r.startDay),
                  createDate: r.createDate,
                  displayWay: Value(r.displayWay),
                  extraInfo: Value(r.extraInfo),
                ),
            ]);

            if (payload.categories.isNotEmpty) {
              b.insertAll(db.recordCategories, [
                for (final r in payload.categories)
                  RecordCategoriesCompanion.insert(
                    id: Value(r.id),
                    name: r.name,
                    icon: Value(r.icon),
                    type: r.type,
                    sort: Value(r.sort),
                    parentCatId: Value(r.parentCatId),
                    colorFill: Value(r.colorFill),
                    platformId: Value(r.platformId),
                    accountBookId: r.accountBookId,
                    isHide: Value(r.isHide),
                    extraInfo: Value(r.extraInfo),
                  ),
              ]);
            }

            if (payload.assets.isNotEmpty) {
              b.insertAll(db.assets, [
                for (final r in payload.assets)
                  AssetsCompanion.insert(
                    id: Value(r.id),
                    name: r.name,
                    balanceMinor: r.balanceMinor,
                    type: r.type,
                    subType: Value(r.subType),
                    createDate: r.createDate,
                    sort: Value(r.sort),
                    icon: Value(r.icon),
                    remark: Value(r.remark),
                    initMoneyMinor: r.initMoneyMinor,
                    isDefault: Value(r.isDefault),
                    isEffectiveAsset: Value(r.isEffectiveAsset),
                    usedTimes: Value(r.usedTimes),
                    color: Value(r.color),
                    status: Value(r.status),
                    extraInfo: Value(r.extraInfo),
                    loanInfo: Value(r.loanInfo),
                    creditInfo: Value(r.creditInfo),
                    fixedDepositInfo: Value(r.fixedDepositInfo),
                    groupName: Value(r.groupName),
                    currency: Value(r.currency),
                  ),
              ]);
            }

            if (payload.records.isNotEmpty) {
              b.insertAll(db.records, [
                for (final r in payload.records)
                  RecordsCompanion.insert(
                    recordId: r.recordId,
                    type: r.type,
                    subType: Value(r.subType),
                    moneyMinor: r.moneyMinor,
                    remark: Value(r.remark),
                    recordTime: r.recordTime,
                    recordCatId: Value(r.recordCatId),
                    assetId: Value(r.assetId),
                    fromAssetId: Value(r.fromAssetId),
                    toAssetId: Value(r.toAssetId),
                    accountBookId: r.accountBookId,
                    excludeBudget: Value(r.excludeBudget),
                    excludeExIn: Value(r.excludeExIn),
                    platformId: Value(r.platformId),
                    periodId: Value(r.periodId),
                    installment: Value(r.installment),
                    images: Value(r.images),
                    relInfo: Value(r.relInfo),
                    discountMinor: Value(r.discountMinor),
                    extraInfo: Value(r.extraInfo),
                    createDate: Value(r.createDate),
                  ),
              ]);
            }

            if (payload.budgets.isNotEmpty) {
              b.insertAll(db.budgets, [
                for (final r in payload.budgets)
                  BudgetsCompanion.insert(
                    id: Value(r.id),
                    budgetType: r.budgetType,
                    recordCatId: r.recordCatId,
                    amountMinor: r.amountMinor,
                    bookId: r.bookId,
                    section: r.section,
                    sort: Value(r.sort),
                    createDate: r.createDate,
                    remark: Value(r.remark),
                    extraInfo: Value(r.extraInfo),
                  ),
              ]);
            }

            if (payload.importPlatforms.isNotEmpty) {
              b.insertAll(db.importPlatforms, [
                for (final r in payload.importPlatforms)
                  ImportPlatformsCompanion.insert(
                    id: Value(r.id),
                    platform: r.platform,
                    importRecordCount: r.importRecordCount,
                    importCategoryCount: r.importCategoryCount,
                    importTime: r.importTime,
                    hidden: Value(r.hidden),
                  ),
              ]);
            }

            if (payload.installments.isNotEmpty) {
              b.insertAll(db.installments, [
                for (final r in payload.installments)
                  InstallmentsCompanion.insert(
                    id: Value(r.id),
                    name: r.name,
                    catId: Value(r.catId),
                    principalMinor: r.principalMinor,
                    periods: r.periods,
                    chargeMinor: r.chargeMinor,
                    chargeWay: r.chargeWay,
                    remainderIn: r.remainderIn,
                    calWay: r.calWay,
                    startDate: r.startDate,
                    assetId: r.assetId,
                    nextPeriod: r.nextPeriod,
                    nextPeriodDate: r.nextPeriodDate,
                    credited: Value(r.credited),
                    bookId: r.bookId,
                    excludeBudget: Value(r.excludeBudget),
                    excludeExIn: Value(r.excludeExIn),
                    createDate: r.createDate,
                    tags: Value(r.tags),
                    images: Value(r.images),
                    exi: Value(r.exi),
                  ),
              ]);
            }

            if (payload.periods.isNotEmpty) {
              b.insertAll(db.recordPeriods, [
                for (final r in payload.periods)
                  RecordPeriodsCompanion.insert(
                    id: Value(r.id),
                    recordType: r.recordType,
                    moneyMinor: r.moneyMinor,
                    feeMinor: Value(r.feeMinor),
                    remark: Value(r.remark),
                    catId: Value(r.catId),
                    assetId: Value(r.assetId),
                    assetId2: Value(r.assetId2),
                    bookId: r.bookId,
                    images: Value(r.images),
                    state: Value(r.state),
                    time: Value(r.time),
                    excludeBudget: Value(r.excludeBudget),
                    excludeExIn: Value(r.excludeExIn),
                    periodType: r.periodType,
                    periodTypeDate: r.periodTypeDate,
                    periodStartDate: r.periodStartDate,
                    periodEndDate: r.periodEndDate,
                    frequency: Value(r.frequency),
                    lastAddDate: Value(r.lastAddDate),
                    periodAddTimes: Value(r.periodAddTimes),
                    createTime: r.createTime,
                    tags: Value(r.tags),
                    exi: Value(r.exi),
                  ),
              ]);
            }

            if (payload.reminders.isNotEmpty) {
              b.insertAll(db.reminderEvents, [
                for (final r in payload.reminders)
                  ReminderEventsCompanion.insert(
                    id: Value(r.id),
                    reminderTime: r.reminderTime,
                    reminderTip: Value(r.reminderTip),
                  ),
              ]);
            }

            if (payload.tags.isNotEmpty) {
              b.insertAll(db.tags, [
                for (final r in payload.tags)
                  TagsCompanion.insert(
                    tagId: r.tagId,
                    name: r.name,
                    sort: Value(r.sort),
                    hidden: Value(r.hidden),
                    parentTagId: Value(r.parentTagId),
                    parent: Value(r.parent),
                    color: Value(r.color),
                    extraInfo: Value(r.extraInfo),
                  ),
              ]);
            }

            if (payload.tagRefs.isNotEmpty) {
              b.insertAll(db.tagRecords, [
                for (final r in payload.tagRefs)
                  TagRecordsCompanion.insert(
                    tagId: r.tagId,
                    recordId: r.recordId,
                  ),
              ]);
            }

            if (payload.templates.isNotEmpty) {
              b.insertAll(db.recordTemplates, [
                for (final r in payload.templates)
                  RecordTemplatesCompanion.insert(
                    id: Value(r.id),
                    type: r.type,
                    remark: Value(r.remark),
                    moneyMinor: r.moneyMinor,
                    feeMinor: Value(r.feeMinor),
                    recordCatId: Value(r.recordCatId),
                    assetId: Value(r.assetId),
                    assetId2: Value(r.assetId2),
                    sort: Value(r.sort),
                    autoSave: Value(r.autoSave),
                    bookId: r.bookId,
                    excludeBudget: Value(r.excludeBudget),
                    excludeExIn: Value(r.excludeExIn),
                    createDate: r.createDate,
                    tags: Value(r.tags),
                    exi: Value(r.exi),
                  ),
              ]);
            }

            if (payload.bankCards.isNotEmpty) {
              b.insertAll(db.bankCards, [
                for (final r in payload.bankCards)
                  BankCardsCompanion.insert(
                    id: Value(r.id),
                    cardType: r.cardType,
                    cardName: r.cardName,
                    cardNo: r.cardNo,
                    cardOwner: r.cardOwner,
                    remark: Value(r.remark),
                    cardColor: Value(r.cardColor),
                    sort: Value(r.sort),
                    createDate: r.createDate,
                    cardAssetId: Value(r.cardAssetId),
                  ),
              ]);
            }

            if (payload.wishes.isNotEmpty) {
              b.insertAll(db.wishes, [
                for (final r in payload.wishes)
                  WishesCompanion.insert(
                    id: r.id,
                    content: r.content,
                    valueMinor: r.valueMinor,
                    createDate: r.createDate,
                    isRealized: Value(r.isRealized),
                    realizedDate: Value(r.realizedDate),
                    sort: Value(r.sort),
                    icon: Value(r.icon),
                    targetDate: Value(r.targetDate),
                  ),
              ]);
            }

            if (payload.remarks.isNotEmpty) {
              b.insertAll(db.remarks, [
                for (final r in payload.remarks)
                  RemarksCompanion.insert(
                    id: Value(r.id),
                    content: r.content,
                    recordCatId: r.recordCatId,
                    usedTimes: Value(r.usedTimes),
                  ),
              ]);
            }

            if (payload.moneySavePlans.isNotEmpty) {
              b.insertAll(db.moneySavePlans, [
                for (final r in payload.moneySavePlans)
                  MoneySavePlansCompanion.insert(
                    id: Value(r.id),
                    name: r.name,
                    remark: Value(r.remark),
                    planType: r.planType,
                    cycleType: r.cycleType,
                    startDate: r.startDate,
                    endDate: r.endDate,
                    planMoneyMinor: r.planMoneyMinor,
                    savedMoneyMinor: r.savedMoneyMinor,
                    autoPlan: Value(r.autoPlan),
                    fromAssetId: Value(r.fromAssetId),
                    toAssetId: Value(r.toAssetId),
                    bookId: Value(r.bookId),
                    startMoneyMinor: r.startMoneyMinor,
                    incrementalMinor: r.incrementalMinor,
                    status: Value(r.status),
                    createDate: r.createDate,
                    sort: Value(r.sort),
                    nextSaveDate: r.nextSaveDate,
                    bbzDailyTimes: Value(r.bbzDailyTimes),
                    icon: Value(r.icon),
                    extraInfo: Value(r.extraInfo),
                  ),
              ]);
            }

            if (payload.moneySavePlanRecords.isNotEmpty) {
              b.insertAll(db.moneySavePlanRecords, [
                for (final r in payload.moneySavePlanRecords)
                  MoneySavePlanRecordsCompanion.insert(
                    id: Value(r.id),
                    planId: r.planId,
                    remark: Value(r.remark),
                    fromAssetId: Value(r.fromAssetId),
                    toAssetId: Value(r.toAssetId),
                    recordDate: r.recordDate,
                    recordMoneyMinor: r.recordMoneyMinor,
                    recordId: Value(r.recordId),
                  ),
              ]);
            }

            if (payload.assetBookRefs.isNotEmpty) {
              b.insertAll(db.assetBooks, [
                for (final r in payload.assetBookRefs)
                  AssetBooksCompanion.insert(
                    assetId: r.assetId,
                    bookId: r.bookId,
                  ),
              ]);
            }

            if (payload.statStory.isNotEmpty) {
              b.insertAll(db.statStories, [
                for (final r in payload.statStory)
                  StatStoriesCompanion.insert(
                    id: r.id,
                    story: r.story,
                    bookId: r.bookId,
                    sdate: r.sdate,
                    edate: r.edate,
                    dsection: Value(r.dsection),
                  ),
              ]);
            }

            if (payload.lanNotes != null && payload.lanNotes!.isNotEmpty) {
              b.insertAll(db.notes, [
                for (final n in payload.lanNotes!)
                  NotesCompanion.insert(
                    id: Value(n.id),
                    title: Value(n.title),
                    content: n.content,
                    createTime: n.createTime,
                    updateTime: n.updateTime,
                    trashTime: Value(n.trashTime),
                  ),
              ]);
            }

            if (payload.lanAutoMaps != null &&
                payload.lanAutoMaps!.isNotEmpty) {
              b.insertAll(db.autoMaps, [
                for (final a in payload.lanAutoMaps!)
                  AutoMapsCompanion.insert(
                    id: Value(a.id),
                    key: a.key,
                    mapInfo: Value(a.mapInfo),
                    draft: Value(a.draft),
                  ),
              ]);
            }

            if (payload.lanCurrencies != null &&
                payload.lanCurrencies!.isNotEmpty) {
              final hasCny = payload.lanCurrencies!.any((c) => c.code == 'CNY');
              final effectiveCurrencies = [
                if (!hasCny)
                  const MigrationCurrencyRow(
                    code: 'CNY',
                    name: '人民币',
                    symbol: '¥',
                    rateToAnchor: '1',
                    anchorCode: 'CNY',
                  ),
                ...payload.lanCurrencies!,
              ];
              b.insertAll(db.currencies, [
                for (final c in effectiveCurrencies)
                  CurrenciesCompanion.insert(
                    code: c.code,
                    name: c.name,
                    symbol: c.symbol,
                    type: Value(c.type),
                    rateToAnchor: c.rateToAnchor,
                    anchorCode: c.anchorCode,
                    rateRefreshTime: Value(c.rateRefreshTime),
                    icon: Value(c.icon),
                    enable: Value(c.enable),
                  ),
              ]);
            }
          });

          // 3. Reset active book ID in `ti_preference` to a valid imported book
          final activeBookId = payload.books.isEmpty
              ? defaultBookId
              : payload.resolveActiveBookId();
          await db
              .into(db.preferences)
              .insertOnConflictUpdate(
                PreferencesCompanion.insert(
                  key: 'current_book_id',
                  value: '$activeBookId',
                ),
              );

          // 4. Clear stale command receipts and persist this migration command receipt
          await db.delete(db.writeCommands).go();
          await db
              .into(db.writeCommands)
              .insert(
                WriteCommandsCompanion.insert(
                  commandId: commandId,
                  payloadHash: payloadHash,
                  resultId: '$activeBookId',
                  committedAt: nowMs,
                ),
              );

          return MigrationApplyResult(
            activeBookId: activeBookId,
            bookCount: effectiveBooks.length,
            assetCount: payload.assets.length,
            recordCount: payload.records.length,
            assetBookRefCount: payload.assetBookRefs.length,
            statStoryCount: payload.statStory.length,
          );
        }),
      ),
    );

    // 5. Resynchronize OS daily reminders outside the SQLite transaction
    await _reminderService.resyncAll();
    return applyResult;
  }
}

// ============================================================================
// Raw SQLite Value Readers (Zero `double` Accounting)
// ============================================================================

List<T> _dedupeRows<T, K>(Iterable<T> items, K Function(T) keyOf) {
  final seen = <K>{};
  final out = <T>[];
  for (final item in items) {
    if (seen.add(keyOf(item))) out.add(item);
  }
  return out;
}

int _sqlInt(Object? raw, {int? fallback, String label = '整数列'}) {
  if (raw == null) {
    if (fallback != null) return fallback;
    throw Failure(FailureCode.corruptData, '数据库缺少必填字段 $label');
  }
  if (raw is int) return raw;
  if (raw is BigInt) return raw.toInt();
  if (raw is num) {
    if (!raw.isFinite) throw Failure(FailureCode.corruptData, '$label数值损坏');
    return raw.toInt();
  }
  if (raw is String) {
    final parsed = int.tryParse(raw.trim());
    if (parsed != null) return parsed;
  }
  throw Failure(FailureCode.corruptData, '字段 $label 类型非法');
}

bool _sqlBool(Object? raw, {bool fallback = false}) {
  if (raw == null) return fallback;
  if (raw is bool) return raw;
  if (raw is int) return raw != 0;
  if (raw is BigInt) return raw != BigInt.zero;
  if (raw is num) return raw.toInt() != 0;
  if (raw is String) {
    final lower = raw.trim().toLowerCase();
    if (lower == '1' || lower == 'true') return true;
    if (lower == '0' || lower == 'false' || lower.isEmpty) return false;
  }
  return fallback;
}

String _sqlString(Object? raw, {required String fallback}) {
  if (raw == null) return fallback;
  if (raw is String) return raw;
  return raw.toString();
}

String _sqlNonEmptyString(Object? raw, String label) {
  final text = _sqlString(raw, fallback: '').trim();
  if (text.isEmpty) {
    throw Failure(FailureCode.corruptData, '数据库主键字段 $label 为空');
  }
  return text;
}

String? _sqlNullableString(Object? raw) {
  if (raw == null) return null;
  if (raw is String) return raw;
  return raw.toString();
}

BigInt _sqlMoneyMinor(
  raw_sqlite.Row row, {
  required String minorCol,
  required String majorCol,
  required bool hasMinorCol,
}) {
  if (hasMinorCol) {
    final rawMinor = row[minorCol];
    if (rawMinor == null) return BigInt.zero;
    if (rawMinor is int) return Money.minor(BigInt.from(rawMinor)).storageMinor;
    if (rawMinor is BigInt) return Money.minor(rawMinor).storageMinor;
    final parsed = BigInt.tryParse(rawMinor.toString().trim());
    if (parsed != null) return Money.minor(parsed).storageMinor;
    return parseMajorToMinor(rawMinor, fieldName: minorCol);
  }
  final rawMajor = row[majorCol];
  if (rawMajor == null) return BigInt.zero;
  return parseMajorToMinor(rawMajor, fieldName: majorCol);
}

BigInt? _sqlNullableMoneyMinor(
  raw_sqlite.Row row, {
  required String minorCol,
  required String majorCol,
  required bool hasMinorCol,
}) {
  if (hasMinorCol) {
    final rawMinor = row[minorCol];
    if (rawMinor == null) return null;
    if (rawMinor is int) return Money.minor(BigInt.from(rawMinor)).storageMinor;
    if (rawMinor is BigInt) return Money.minor(rawMinor).storageMinor;
    final parsed = BigInt.tryParse(rawMinor.toString().trim());
    if (parsed != null) return Money.minor(parsed).storageMinor;
    return parseMajorToMinor(rawMinor, fieldName: minorCol);
  }
  final rawMajor = row[majorCol];
  if (rawMajor == null) return null;
  return parseMajorToMinor(rawMajor, fieldName: majorCol);
}
