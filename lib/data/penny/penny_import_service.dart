import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../../core/failure.dart';
import '../../domain/rules/penny_backup.dart';
import '../db/database.dart';
import '../db/failures.dart';
import '../reminder/reminder_service.dart';

/// Outcome of a committed `.penny` / `.yy` restore operation.
final class PennyImportResult {
  const PennyImportResult({
    required this.preview,
    required this.targetBookId,
    this.deduplicated = false,
  });

  final PennyBackupPreview preview;
  final int targetBookId;
  final bool deduplicated;
}

/// Atomic restore service for original `.penny` / `.yy` encrypted backups
/// (`docs/modules/import-original-backup.md` F-035, R1..R7, HR-01..HR-05).
final class PennyImportService {
  PennyImportService(this.db, {ReminderService? reminderService})
    : _reminderService = reminderService ?? ReminderService(db);

  final AppDatabase db;
  final ReminderService _reminderService;

  /// Decrypts, validates, and summarizes [bytes] in memory without touching SQLite.
  Future<PennyBackupPreview> previewPenny({
    required String fileName,
    required Uint8List bytes,
  }) async {
    final staged = stagePennyBackup(
      bytes: bytes,
      fileName: fileName,
      fallbackNowMs: db.nowMs(),
    );
    return staged.preview;
  }

  /// Atomically replaces ONLY the 20 `.penny` ledger tables inside a single
  /// SQLite transaction while preserving `note` (便签) and `currency` (自定义汇率)
  /// (`HR-01` / `R5` / `DR-BK-11`), unconditionally importing active `remarks`
  /// (`R6`), updating `current_book_id` (`R7` / §6.2), and resyncing reminders.
  Future<PennyImportResult> importPenny({
    required String commandId,
    required String fileName,
    required Uint8List bytes,
  }) async {
    if (commandId.isEmpty || commandId.length > 128) {
      throw const Failure(FailureCode.validation, '提交标识无效');
    }

    // 1. Full in-memory staging & preflight validation BEFORE touching DB (R2/HR-03).
    final staged = stagePennyBackup(
      bytes: bytes,
      fileName: fileName,
      fallbackNowMs: db.nowMs(),
    );

    final bytesDigest = sha256.convert(bytes).toString();
    final payloadHash = sha256
        .convert(utf8.encode(jsonEncode(['penny-import-v1', bytesDigest])))
        .toString();

    var deduplicated = false;
    var committedBookId = staged.targetBookId;

    // 2. Single atomic SQLite transaction replacing ONLY the 20 tables (R4, R5).
    await guardDatabase(
      () => db.transaction(() async {
        final previous = await (db.select(
          db.writeCommands,
        )..where((t) => t.commandId.equals(commandId))).getSingleOrNull();
        if (previous != null) {
          if (previous.payloadHash != payloadHash) {
            throw const Failure(FailureCode.conflict, '同一提交标识的内容发生变化');
          }
          deduplicated = true;
          committedBookId =
              int.tryParse(previous.resultId) ?? staged.targetBookId;
          return;
        }

        // Clear ONLY the 20 `.penny` tables — NEVER touch `db.notes` or `db.currencies`!
        await db.delete(db.tagRecords).go();
        await db.delete(db.assetBooks).go();
        await db.delete(db.moneySavePlanRecords).go();
        await db.delete(db.moneySavePlans).go();
        await db.delete(db.records).go();
        await db.delete(db.budgets).go();
        await db.delete(db.installments).go();
        await db.delete(db.recordPeriods).go();
        await db.delete(db.recordTemplates).go();
        await db.delete(db.reminderEvents).go();
        await db.delete(db.bankCards).go();
        await db.delete(db.wishes).go();
        await db.delete(db.remarks).go();
        await db.delete(db.statStories).go();
        await db.delete(db.autoMaps).go();
        await db.delete(db.importPlatforms).go();
        await db.delete(db.tags).go();
        await db.delete(db.recordCategories).go();
        await db.delete(db.assets).go();
        await db.delete(db.accountBooks).go();

        await db.batch((b) {
          // 1. account_book
          if (staged.books.isNotEmpty) {
            b.insertAll(db.accountBooks, [
              for (final row in staged.books)
                AccountBooksCompanion.insert(
                  id: Value(row.id),
                  type: Value(row.type),
                  name: row.name,
                  cover: Value(row.cover),
                  sort: Value(row.sort),
                  status: Value(row.status),
                  startDay: Value(row.startDay),
                  createDate: row.createDate,
                  displayWay: Value(row.displayWay),
                  extraInfo: Value(row.extraInfo),
                ),
            ], mode: InsertMode.insert);
          }

          // 2. record_category
          if (staged.categories.isNotEmpty) {
            b.insertAll(db.recordCategories, [
              for (final row in staged.categories)
                RecordCategoriesCompanion.insert(
                  id: row.id == null ? const Value.absent() : Value(row.id!),
                  name: row.name,
                  icon: Value(row.icon),
                  type: row.type,
                  sort: Value(row.sort),
                  parentCatId: Value(row.parentCatId),
                  colorFill: Value(row.colorFill),
                  platformId: Value(row.platformId),
                  accountBookId: row.accountBookId,
                  isHide: Value(row.isHide),
                  extraInfo: Value(row.extraInfo),
                ),
            ], mode: InsertMode.insert);
          }

          // 3. asset
          if (staged.assets.isNotEmpty) {
            b.insertAll(db.assets, [
              for (final row in staged.assets)
                AssetsCompanion.insert(
                  id: row.id == null ? const Value.absent() : Value(row.id!),
                  name: row.name,
                  balanceMinor: row.balanceMinor,
                  type: row.type,
                  subType: Value(row.subType),
                  createDate: row.createDate,
                  sort: Value(row.sort),
                  icon: Value(row.icon),
                  remark: Value(row.remark),
                  initMoneyMinor: row.initMoneyMinor,
                  isDefault: Value(row.isDefault),
                  isEffectiveAsset: Value(row.isEffectiveAsset),
                  usedTimes: Value(row.usedTimes),
                  color: Value(row.color),
                  status: Value(row.status),
                  extraInfo: Value(row.extraInfo),
                  loanInfo: Value(row.loanInfo),
                  creditInfo: Value(row.creditInfo),
                  fixedDepositInfo: Value(row.fixedDepositInfo),
                  groupName: Value(row.groupName),
                  currency: Value(row.currency),
                ),
            ], mode: InsertMode.insert);
          }

          // 4. record
          if (staged.records.isNotEmpty) {
            b.insertAll(db.records, [
              for (final row in staged.records)
                RecordsCompanion.insert(
                  recordId: row.recordId,
                  type: row.type,
                  subType: Value(row.subType),
                  moneyMinor: row.moneyMinor,
                  remark: Value(row.remark),
                  recordTime: row.recordTime,
                  recordCatId: Value(row.recordCatId),
                  assetId: Value(row.assetId),
                  fromAssetId: Value(row.fromAssetId),
                  toAssetId: Value(row.toAssetId),
                  accountBookId: row.accountBookId,
                  excludeBudget: Value(row.excludeBudget),
                  excludeExIn: Value(row.excludeExIn),
                  platformId: Value(row.platformId),
                  periodId: Value(row.periodId),
                  installment: Value(row.installment),
                  images: Value(row.images),
                  relInfo: Value(row.relInfo),
                  discountMinor: Value(row.discountMinor),
                  extraInfo: Value(row.extraInfo),
                  createDate: Value(row.createDate),
                ),
            ], mode: InsertMode.insert);
          }

          // 5. budget
          if (staged.budgets.isNotEmpty) {
            b.insertAll(db.budgets, [
              for (final row in staged.budgets)
                BudgetsCompanion.insert(
                  id: Value(row.id),
                  budgetType: row.budgetType,
                  recordCatId: row.recordCatId,
                  amountMinor: row.amountMinor,
                  bookId: row.bookId,
                  section: row.section,
                  sort: Value(row.sort),
                  createDate: row.createDate,
                  remark: Value(row.remark),
                  extraInfo: Value(row.extraInfo),
                ),
            ], mode: InsertMode.insert);
          }

          // 6. import_platform
          if (staged.importPlatforms.isNotEmpty) {
            b.insertAll(db.importPlatforms, [
              for (final row in staged.importPlatforms)
                ImportPlatformsCompanion.insert(
                  id: row.id == null ? const Value.absent() : Value(row.id!),
                  platform: row.platform,
                  importRecordCount: row.importRecordCount,
                  importCategoryCount: row.importCategoryCount,
                  importTime: row.importTime,
                  hidden: Value(row.hidden),
                ),
            ], mode: InsertMode.insert);
          }

          // 7. installment
          if (staged.installments.isNotEmpty) {
            b.insertAll(db.installments, [
              for (final row in staged.installments)
                InstallmentsCompanion.insert(
                  id: row.id == null ? const Value.absent() : Value(row.id!),
                  name: row.name,
                  catId: Value(row.catId),
                  principalMinor: row.principalMinor,
                  periods: row.periods,
                  chargeMinor: row.chargeMinor,
                  chargeWay: row.chargeWay,
                  remainderIn: row.remainderIn,
                  calWay: row.calWay,
                  startDate: row.startDate,
                  assetId: row.assetId,
                  nextPeriod: row.nextPeriod,
                  nextPeriodDate: row.nextPeriodDate,
                  credited: Value(row.credited),
                  bookId: row.bookId,
                  excludeBudget: Value(row.excludeBudget),
                  excludeExIn: Value(row.excludeExIn),
                  createDate: row.createDate,
                  tags: Value(row.tags),
                  images: Value(row.images),
                  exi: Value(row.exi),
                ),
            ], mode: InsertMode.insert);
          }

          // 8. record_period
          if (staged.periods.isNotEmpty) {
            b.insertAll(db.recordPeriods, [
              for (final row in staged.periods)
                RecordPeriodsCompanion.insert(
                  id: row.id == null ? const Value.absent() : Value(row.id!),
                  recordType: row.recordType,
                  moneyMinor: row.moneyMinor,
                  feeMinor: Value(row.feeMinor),
                  remark: Value(row.remark),
                  catId: Value(row.catId),
                  assetId: Value(row.assetId),
                  assetId2: Value(row.assetId2),
                  bookId: row.bookId,
                  images: Value(row.images),
                  state: Value(row.state),
                  time: Value(row.time),
                  excludeBudget: Value(row.excludeBudget),
                  excludeExIn: Value(row.excludeExIn),
                  periodType: row.periodType,
                  periodTypeDate: row.periodTypeDate,
                  periodStartDate: row.periodStartDate,
                  periodEndDate: row.periodEndDate,
                  frequency: Value(row.frequency),
                  lastAddDate: Value(row.lastAddDate),
                  periodAddTimes: Value(row.periodAddTimes),
                  createTime: row.createTime,
                  tags: Value(row.tags),
                  exi: Value(row.exi),
                ),
            ], mode: InsertMode.insert);
          }

          // 9. reminder_event
          if (staged.reminders.isNotEmpty) {
            b.insertAll(db.reminderEvents, [
              for (final row in staged.reminders)
                ReminderEventsCompanion.insert(
                  id: row.id == null ? const Value.absent() : Value(row.id!),
                  reminderTime: row.reminderTime,
                  reminderTip: Value(row.reminderTip),
                ),
            ], mode: InsertMode.insert);
          }

          // 10. tag
          if (staged.tags.isNotEmpty) {
            b.insertAll(db.tags, [
              for (final row in staged.tags)
                TagsCompanion.insert(
                  tagId: row.tagId,
                  name: row.name,
                  sort: Value(row.sort),
                  hidden: Value(row.hidden),
                  parentTagId: Value(row.parentTagId),
                  parent: Value(row.parent),
                  color: Value(row.color),
                  extraInfo: Value(row.extraInfo),
                ),
            ], mode: InsertMode.insert);
          }

          // 11. tag_record
          if (staged.tagRefs.isNotEmpty) {
            b.insertAll(db.tagRecords, [
              for (final row in staged.tagRefs)
                TagRecordsCompanion.insert(
                  tagId: row.tagId,
                  recordId: row.recordId,
                ),
            ], mode: InsertMode.insert);
          }

          // 12. record_template
          if (staged.templates.isNotEmpty) {
            b.insertAll(db.recordTemplates, [
              for (final row in staged.templates)
                RecordTemplatesCompanion.insert(
                  id: Value(row.id),
                  type: row.type,
                  remark: Value(row.remark),
                  moneyMinor: row.moneyMinor,
                  feeMinor: Value(row.feeMinor),
                  recordCatId: Value(row.recordCatId),
                  assetId: Value(row.assetId),
                  assetId2: Value(row.assetId2),
                  sort: Value(row.sort),
                  autoSave: Value(row.autoSave),
                  bookId: row.bookId,
                  excludeBudget: Value(row.excludeBudget),
                  excludeExIn: Value(row.excludeExIn),
                  createDate: row.createDate,
                  tags: Value(row.tags),
                  exi: Value(row.exi),
                ),
            ], mode: InsertMode.insert);
          }

          // 13. bank_card
          if (staged.bankCards.isNotEmpty) {
            b.insertAll(db.bankCards, [
              for (final row in staged.bankCards)
                BankCardsCompanion.insert(
                  id: row.id == null ? const Value.absent() : Value(row.id!),
                  cardType: row.cardType,
                  cardName: row.cardName,
                  cardNo: row.cardNo,
                  cardOwner: row.cardOwner,
                  remark: Value(row.remark),
                  cardColor: Value(row.cardColor),
                  sort: Value(row.sort),
                  createDate: row.createDate,
                  cardAssetId: Value(row.cardAssetId),
                ),
            ], mode: InsertMode.insert);
          }

          // 14. wish
          if (staged.wishes.isNotEmpty) {
            b.insertAll(db.wishes, [
              for (final row in staged.wishes)
                WishesCompanion.insert(
                  id: row.id,
                  content: row.content,
                  valueMinor: row.valueMinor,
                  createDate: row.createDate,
                  isRealized: Value(row.isRealized),
                  realizedDate: Value(row.realizedDate),
                  sort: Value(row.sort),
                  icon: Value(row.icon),
                  targetDate: Value(row.targetDate),
                ),
            ], mode: InsertMode.insert);
          }

          // 15. remark (unconditionally imported per R6)
          if (staged.remarks.isNotEmpty) {
            b.insertAll(db.remarks, [
              for (final row in staged.remarks)
                RemarksCompanion.insert(
                  id: row.id == null ? const Value.absent() : Value(row.id!),
                  content: row.content,
                  recordCatId: row.recordCatId,
                  usedTimes: Value(row.usedTimes),
                ),
            ], mode: InsertMode.insert);
          }

          // 16. money_save_plan
          if (staged.moneySavePlans.isNotEmpty) {
            b.insertAll(db.moneySavePlans, [
              for (final row in staged.moneySavePlans)
                MoneySavePlansCompanion.insert(
                  id: Value(row.id),
                  name: row.name,
                  remark: Value(row.remark),
                  planType: row.planType,
                  cycleType: row.cycleType,
                  startDate: row.startDate,
                  endDate: row.endDate,
                  planMoneyMinor: row.planMoneyMinor,
                  savedMoneyMinor: row.savedMoneyMinor,
                  autoPlan: Value(row.autoPlan),
                  fromAssetId: Value(row.fromAssetId),
                  toAssetId: Value(row.toAssetId),
                  bookId: Value(row.bookId),
                  startMoneyMinor: row.startMoneyMinor,
                  incrementalMinor: row.incrementalMinor,
                  status: Value(row.status),
                  createDate: row.createDate,
                  sort: Value(row.sort),
                  nextSaveDate: row.nextSaveDate,
                  bbzDailyTimes: Value(row.bbzDailyTimes),
                  icon: Value(row.icon),
                  extraInfo: Value(row.extraInfo),
                ),
            ], mode: InsertMode.insert);
          }

          // 17. money_save_plan_record
          if (staged.moneySavePlanRecords.isNotEmpty) {
            b.insertAll(db.moneySavePlanRecords, [
              for (final row in staged.moneySavePlanRecords)
                MoneySavePlanRecordsCompanion.insert(
                  id: Value(row.id),
                  planId: row.planId,
                  remark: Value(row.remark),
                  fromAssetId: Value(row.fromAssetId),
                  toAssetId: Value(row.toAssetId),
                  recordDate: row.recordDate,
                  recordMoneyMinor: row.recordMoneyMinor,
                  recordId: Value(row.recordId),
                ),
            ], mode: InsertMode.insert);
          }

          // 18. asset_book
          if (staged.assetBookRefs.isNotEmpty) {
            b.insertAll(db.assetBooks, [
              for (final row in staged.assetBookRefs)
                AssetBooksCompanion.insert(
                  assetId: row.assetId,
                  bookId: row.bookId,
                ),
            ], mode: InsertMode.insert);
          }

          // 19. stat_story
          if (staged.statStory.isNotEmpty) {
            b.insertAll(db.statStories, [
              for (final row in staged.statStory)
                StatStoriesCompanion.insert(
                  id: row.id,
                  story: row.story,
                  bookId: row.bookId,
                  sdate: row.sdate,
                  edate: row.edate,
                  dsection: Value(row.dsection),
                ),
            ], mode: InsertMode.insert);
          }

          // 20. auto_map
          if (staged.autoBillMaps.isNotEmpty) {
            b.insertAll(db.autoMaps, [
              for (final row in staged.autoBillMaps)
                AutoMapsCompanion.insert(
                  id: row.id == null ? const Value.absent() : Value(row.id!),
                  key: row.key,
                  mapInfo: Value(row.mapInfo),
                  draft: Value(row.draft),
                ),
            ], mode: InsertMode.insert);
          }
        });

        // Reset active book ID & month start day in preferences (R7, §6.2).
        await db
            .into(db.preferences)
            .insertOnConflictUpdate(
              PreferencesCompanion.insert(
                key: 'current_book_id',
                value: '${staged.targetBookId}',
              ),
            );
        await db
            .into(db.preferences)
            .insertOnConflictUpdate(
              PreferencesCompanion.insert(key: 'month_start_day', value: '1'),
            );

        await db
            .into(db.writeCommands)
            .insert(
              WriteCommandsCompanion.insert(
                commandId: commandId,
                payloadHash: payloadHash,
                resultId: '${staged.targetBookId}',
                committedAt: db.nowMs(),
              ),
            );
      }),
    );

    if (!deduplicated) {
      await _reminderService.resyncAll();
    }

    return PennyImportResult(
      preview: staged.preview,
      targetBookId: committedBookId,
      deduplicated: deduplicated,
    );
  }
}
