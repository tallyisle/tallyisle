import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tallyisle/app/adaptive.dart';
import 'package:tallyisle/app/app.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/automation/auto_bill_service.dart';
import 'package:tallyisle/data/backup/s3_client.dart';
import 'package:tallyisle/data/backup/tally_backup_service.dart';
import 'package:tallyisle/data/backup/webdav_client.dart';
import 'package:tallyisle/data/budget/budget_service.dart';
import 'package:tallyisle/data/catalog/catalog_service.dart';
import 'package:tallyisle/data/catalog/currency_service.dart';
import 'package:tallyisle/data/csv_import/csv_excel_service.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/debt/debt_service.dart';
import 'package:tallyisle/data/deposit/fixed_deposit_service.dart';
import 'package:tallyisle/data/installment/installment_service.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/data/periodic/periodic_service.dart';
import 'package:tallyisle/data/reminder/reminder_service.dart';
import 'package:tallyisle/data/savings/savings_service.dart';
import 'package:tallyisle/data/tools/bank_card_service.dart';
import 'package:tallyisle/data/tools/bill_attachment_service.dart';
import 'package:tallyisle/data/tools/note_service.dart';
import 'package:tallyisle/data/tools/template_remark_service.dart';
import 'package:tallyisle/data/tools/wish_service.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/app_settings_rules.dart';
import 'package:tallyisle/domain/rules/auto_map_rules.dart';
import 'package:tallyisle/domain/rules/billing_period.dart';
import 'package:tallyisle/domain/rules/budget_rules.dart';
import 'package:tallyisle/domain/rules/cloud_sync_rules.dart';
import 'package:tallyisle/domain/rules/csv_excel_codec.dart';
import 'package:tallyisle/domain/rules/csv_excel_rules.dart';
import 'package:tallyisle/domain/rules/fixed_deposit.dart';
import 'package:tallyisle/domain/rules/periodic_records.dart';
import 'package:tallyisle/domain/rules/savings_plan.dart';
import 'package:tallyisle/domain/rules/template_card_rules.dart';
import 'package:tallyisle/features/assets/asset_detail_page.dart';
import 'package:tallyisle/features/assets/asset_editor_page.dart';
import 'package:tallyisle/features/assets/assets_page.dart';
import 'package:tallyisle/features/attachments/bill_images_page.dart';
import 'package:tallyisle/features/automation/auto_bill_page.dart';
import 'package:tallyisle/features/automation/automation_providers.dart';
import 'package:tallyisle/features/automation/ocr_bill_page.dart';
import 'package:tallyisle/features/automation/url_scheme_page.dart';
import 'package:tallyisle/features/backup/backup_page.dart';
import 'package:tallyisle/features/backup/backup_providers.dart';
import 'package:tallyisle/features/backup/s3_config_page.dart';
import 'package:tallyisle/features/backup/webdav_config_page.dart';
import 'package:tallyisle/features/bank_cards/bank_card_editor_page.dart';
import 'package:tallyisle/features/bank_cards/bank_cards_page.dart';
import 'package:tallyisle/features/batch_edit/batch_edit_page.dart';
import 'package:tallyisle/features/books/books_page.dart';
import 'package:tallyisle/features/budget/budget_page.dart';
import 'package:tallyisle/features/calendar/calendar_page.dart';
import 'package:tallyisle/features/categories/categories_page.dart';
import 'package:tallyisle/features/category_transfer/category_transfer_page.dart';
import 'package:tallyisle/features/common/desktop_modal_page.dart';
import 'package:tallyisle/features/csv_transfer/csv_export_page.dart';
import 'package:tallyisle/features/csv_transfer/csv_import_page.dart';
import 'package:tallyisle/features/csv_transfer/import_batches_page.dart';
import 'package:tallyisle/features/currencies/currencies_page.dart';
import 'package:tallyisle/features/debt/debt_detail_page.dart';
import 'package:tallyisle/features/debt/debt_editor_page.dart';
import 'package:tallyisle/features/debt/debt_page.dart';
import 'package:tallyisle/features/deposit/fixed_deposit_editor_page.dart';
import 'package:tallyisle/features/deposit/fixed_deposit_page.dart';
import 'package:tallyisle/features/home/home_page.dart';
import 'package:tallyisle/features/installment/installment_detail_page.dart';
import 'package:tallyisle/features/installment/installment_editor_page.dart';
import 'package:tallyisle/features/installment/installment_page.dart';
import 'package:tallyisle/features/me/me_page.dart';
import 'package:tallyisle/features/migration/migration_page.dart';
import 'package:tallyisle/features/notes/note_editor_page.dart';
import 'package:tallyisle/features/notes/note_trash_page.dart';
import 'package:tallyisle/features/notes/notes_page.dart';
import 'package:tallyisle/features/penny_import/penny_import_page.dart';
import 'package:tallyisle/features/periodic/periodic_editor_page.dart';
import 'package:tallyisle/features/periodic/periodic_page.dart';
import 'package:tallyisle/features/receipt/diy_toolbar_settings_page.dart';
import 'package:tallyisle/features/receipt/record_receipt_dialog.dart';
import 'package:tallyisle/features/records/desktop_record_editor_dialog.dart';
import 'package:tallyisle/features/records/record_datetime_dialog.dart';
import 'package:tallyisle/features/records/record_detail_page.dart';
import 'package:tallyisle/features/records/record_keypad.dart';
import 'package:tallyisle/features/reimburse/reimburse_page.dart';
import 'package:tallyisle/features/reminder/reminder_page.dart';
import 'package:tallyisle/features/reminder/reminder_providers.dart';
import 'package:tallyisle/features/savings/savings_detail_page.dart';
import 'package:tallyisle/features/savings/savings_editor_page.dart';
import 'package:tallyisle/features/savings/savings_page.dart';
import 'package:tallyisle/features/search/search_page.dart';
import 'package:tallyisle/features/security/app_lock_settings_page.dart';
import 'package:tallyisle/features/settings/about_help_page.dart';
import 'package:tallyisle/features/settings/data_health_page.dart';
import 'package:tallyisle/features/settings/settings_page.dart';
import 'package:tallyisle/features/settings/stat_stories_page.dart';
import 'package:tallyisle/features/stats/annual_report_page.dart';
import 'package:tallyisle/features/stats/asset_trend_page.dart';
import 'package:tallyisle/features/stats/category_stats_page.dart';
import 'package:tallyisle/features/stats/stats_page.dart';
import 'package:tallyisle/features/stats/tag_stats_page.dart';
import 'package:tallyisle/features/tags/tags_page.dart';
import 'package:tallyisle/features/templates/template_editor_page.dart';
import 'package:tallyisle/features/templates/templates_page.dart';
import 'package:tallyisle/features/wishes/wish_editor_page.dart';
import 'package:tallyisle/features/wishes/wishes_page.dart';
import 'package:tallyisle/platform/app_widgets.dart';
import 'package:tallyisle/platform/auto_bill_bridge.dart';
import 'package:tallyisle/platform/files.dart';
import 'package:tallyisle/platform/notifications.dart';

const TargetPlatformVariant _desktopPlatforms = TargetPlatformVariant(
  <TargetPlatform>{
    TargetPlatform.linux,
    TargetPlatform.windows,
    TargetPlatform.macOS,
  },
);

const List<Size> _desktopSizes = <Size>[
  Size(1280, 800),
  Size(1080, 700),
  Size(900, 700),
  Size(520, 600),
];

/// Valid 1x1 PNG image bytes for seeding bill attachment thumbnails.
final Uint8List _onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

const List<String> _desktopCjkFontFallback = <String>[
  'PingFang SC',
  'Hiragino Sans GB',
  'Microsoft YaHei UI',
  'Microsoft YaHei',
  'Noto Sans CJK SC',
  'Source Han Sans SC',
  'sans-serif',
];

ThemeData _buildDesktopAppTheme(Brightness brightness) {
  final seedColor = Color(AppSettings.defaults.themeSeedArgb32);
  final base = ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: brightness,
    ),
    useMaterial3: true,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(
      fontFamilyFallback: _desktopCjkFontFallback,
    ),
    primaryTextTheme: base.primaryTextTheme.apply(
      fontFamilyFallback: _desktopCjkFontFallback,
    ),
    inputDecorationTheme: base.inputDecorationTheme.copyWith(
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
    ),
    segmentedButtonTheme: const SegmentedButtonThemeData(
      style: ButtonStyle(
        visualDensity: VisualDensity.standard,
        minimumSize: WidgetStatePropertyAll(Size(0, 36)),
        padding: WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        ),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    ),
  );
}

final class _SeedIds {
  const _SeedIds({
    required this.secondBookId,
    required this.foodCatId,
    required this.bankAssetId,
    required this.cashAssetId,
    required this.creditAssetId,
    required this.debtLendId,
    required this.expRecordId,
    required this.reimbRecordId,
    required this.transferRecordId,
    required this.soloTagId,
    required this.templateId,
    required this.periodicId,
    required this.installmentId,
    required this.savingsPlanId,
    required this.depositIndex,
    required this.bankCardId,
    required this.wishId,
    required this.noteId,
    required this.importBatchId,
  });

  final int secondBookId;
  final int foodCatId;
  final int bankAssetId;
  final int cashAssetId;
  final int creditAssetId;
  final int debtLendId;
  final String expRecordId;
  final String reimbRecordId;
  final String transferRecordId;
  final String soloTagId;
  final int templateId;
  final int periodicId;
  final int installmentId;
  final int savingsPlanId;
  final int depositIndex;
  final int bankCardId;
  final String wishId;
  final int noteId;
  final int importBatchId;
}

final class _DesktopProbeHarness {
  _DesktopProbeHarness({
    required this.db,
    required this.ids,
    required this.tempRoot,
    required this.localBackupDir,
    required this.attachmentsDir,
    required this.scheduler,
    required this.autoBridge,
    required this.widgetBridge,
  });

  final AppDatabase db;
  final _SeedIds ids;
  final Directory tempRoot;
  final Directory localBackupDir;
  final Directory attachmentsDir;
  final InMemoryReminderScheduler scheduler;
  final InMemoryAutoBillBridge autoBridge;
  final InMemoryAppWidgetBridge widgetBridge;

  static Future<_DesktopProbeHarness> create(WidgetTester tester) async {
    late AppDatabase db;
    late _SeedIds ids;
    late Directory tempRoot;
    late Directory localBackupDir;
    late Directory attachmentsDir;
    final scheduler = InMemoryReminderScheduler();
    final autoBridge = InMemoryAutoBillBridge();
    final widgetBridge = InMemoryAppWidgetBridge();

    await tester.runAsync(() async {
      db = AppDatabase(NativeDatabase.memory());
      tempRoot = await Directory.systemTemp.createTemp('tally_desk_probe_');
      localBackupDir = Directory(p.join(tempRoot.path, 'backups'));
      attachmentsDir = Directory(p.join(tempRoot.path, 'attachments'));
      await localBackupDir.create(recursive: true);
      await attachmentsDir.create(recursive: true);

      final ledger = LedgerService(db);
      final catalog = CatalogService(db);
      final currency = CurrencyService(db);
      final budget = BudgetService(db);
      final periodic = PeriodicService(db);
      final installmentSvc = InstallmentService(db);
      final debtSvc = DebtService(db);
      final depositSvc = FixedDepositService(db);
      final savingsSvc = SavingsService(db);
      final reminderSvc = ReminderService(db, scheduler: scheduler);
      final templateSvc = TemplateRemarkService(db);
      final bankCardSvc = BankCardService(db);
      final wishSvc = WishService(db);
      final noteSvc = NoteService(db);
      final attachSvc = BillAttachmentService(
        db,
        attachmentsDirectoryProvider: () async => attachmentsDir,
      );
      final autoSvc = AutoBillService(db, bridge: autoBridge);
      final csvSvc = CsvExcelService(db);
      final backupSvc = TallyBackupService(
        db,
        reminderService: reminderSvc,
        localBackupsDirectoryProvider: () async => localBackupDir,
        attachmentsDirectoryProvider: () async => attachmentsDir,
      );

      final secondBookId = await catalog.createBook(
        commandId: 'probe-book-2',
        name: '家庭公用账本',
        startDay: 5,
      );

      final categories = await db.select(db.recordCategories).get();
      final foodCat = categories.firstWhere((c) => c.name == '餐饮');
      final shoppingCat = categories.firstWhere((c) => c.name == '购物');
      final salaryCat = categories.firstWhere((c) => c.name == '工资');

      await catalog.createCategory(
        commandId: 'probe-subcat-food',
        accountBookId: 1,
        type: RecordType.expense,
        name: '商务宴请',
        parentCatId: foodCat.id,
      );

      final bankAssetId = await ledger.createAsset(
        commandId: 'probe-asset-bank',
        name: '招商储蓄卡',
        initial: Money.parse('68000.00'),
      );
      final cashAssetId = await ledger.createAsset(
        commandId: 'probe-asset-cash',
        name: '日常备用金',
        initial: Money.parse('3200.00'),
      );
      final creditAssetId = await ledger.createAsset(
        commandId: 'probe-asset-credit',
        name: '招商经典白金卡',
        type: AssetType.credit,
        initial: Money.parse('-1280.50'),
        limit: Money.parse('50000.00'),
        creditInfo: '{"billDay":10,"repaymentDay":25,"repaymentType":0}',
      );

      await currency.saveCurrency(
        commandId: 'probe-cur-usd',
        code: 'USD',
        name: '美元',
        symbol: r'$',
        price: '7.2350',
      );
      await currency.saveCurrency(
        commandId: 'probe-cur-jpy',
        code: 'JPY',
        name: '日元',
        symbol: '¥',
        price: '0.0485',
      );

      final groupTagId = await catalog.createTag(
        commandId: 'probe-tag-group',
        name: '2026差旅项目',
        isGroup: true,
        color: '#1E88E5',
      );
      final childTagId = await catalog.createTag(
        commandId: 'probe-tag-child',
        name: '高铁机票',
        parentTagId: groupTagId,
        color: '#E53935',
      );
      final soloTagId = await catalog.createTag(
        commandId: 'probe-tag-solo',
        name: '日常餐饮',
        color: '#43A047',
      );

      final now = DateTime.now();
      final todayNoonMs = DateTime(
        now.year,
        now.month,
        now.day,
        12,
      ).millisecondsSinceEpoch;

      final expRecordId = await ledger.saveRecord(
        commandId: 'probe-rec-exp-1',
        draft: RecordDraft(
          type: RecordType.expense,
          money: Money.parse('68.50'),
          bookId: 1,
          recordTime: todayNoonMs,
          categoryId: foodCat.id,
          assetId: bankAssetId,
          remark: '团队午餐聚会',
          tagIds: <String>[soloTagId],
        ),
      );
      final savedImgName = await attachSvc.saveImageBytes(
        bytes: _onePixelPng,
        originalName: 'receipt.png',
      );
      await attachSvc.setRecordImages(
        commandId: 'probe-rec-img-1',
        recordId: expRecordId,
        imageNames: <String>[savedImgName],
      );

      final reimbRecordId = await ledger.saveRecord(
        commandId: 'probe-rec-reimb-1',
        draft: RecordDraft(
          type: RecordType.reimbursable,
          money: Money.parse('420.00'),
          bookId: 1,
          recordTime: todayNoonMs - 3600000,
          categoryId: shoppingCat.id,
          fromAssetId: bankAssetId,
          remark: '差旅交通垫付票据',
          tagIds: <String>[childTagId],
        ),
      );

      await ledger.saveRecord(
        commandId: 'probe-rec-inc-1',
        draft: RecordDraft(
          type: RecordType.income,
          money: Money.parse('18600.00'),
          bookId: 1,
          recordTime: todayNoonMs - 7200000,
          categoryId: salaryCat.id,
          assetId: bankAssetId,
          remark: '本月薪资入账',
        ),
      );

      final transferRecordId = await ledger.saveRecord(
        commandId: 'probe-rec-trf-1',
        draft: RecordDraft(
          type: RecordType.transfer,
          money: Money.parse('1000.00'),
          fee: Money.parse('2.00'),
          bookId: 1,
          recordTime: todayNoonMs - 10800000,
          fromAssetId: bankAssetId,
          toAssetId: cashAssetId,
          remark: '提现补充备用金',
        ),
      );

      final period = BillingPeriod.containing(now, 1);
      final section = BudgetMode.monthly.sectionFor(period);
      await budget.upsertTotalBudget(
        commandId: 'probe-budget-total',
        bookId: 1,
        section: section,
        amountMinor: BigInt.from(500000),
        autoCopy: true,
        forward: true,
      );
      await budget.upsertCategoryBudget(
        commandId: 'probe-budget-food',
        bookId: 1,
        section: section,
        categoryId: foodCat.id,
        budgetType: BudgetTypeCode.expenseCategory,
        amountMinor: BigInt.from(150000),
      );
      await budget.upsertCategoryBudget(
        commandId: 'probe-budget-saving',
        bookId: 1,
        section: section,
        categoryId: salaryCat.id,
        budgetType: BudgetTypeCode.savingCategory,
        amountMinor: BigInt.from(800000),
      );

      final templateId = await templateSvc.saveTemplate(
        commandId: 'probe-tpl-1',
        draft: TemplateDraft(
          type: RecordType.expense,
          money: Money.parse('32.00'),
          bookId: 1,
          name: '工作日午餐套餐',
          categoryId: foodCat.id,
          assetId: bankAssetId,
          remark: '园区简餐',
          excludeBudget: true,
          tagIds: <String>[soloTagId],
        ),
      );
      await templateSvc.saveTemplate(
        commandId: 'probe-tpl-2',
        draft: TemplateDraft(
          type: RecordType.transfer,
          money: Money.parse('1000.00'),
          fee: Money.parse('1.50'),
          bookId: 1,
          name: '信用卡快捷还款',
          assetId: bankAssetId,
          assetId2: creditAssetId,
          remark: '每月自动模板',
        ),
      );

      final diyDefaults = DiyToolbarConfig.defaults();
      await attachSvc.saveDiyToolbarConfig(
        commandId: 'probe-diy-1',
        config: DiyToolbarConfig.normalize([
          for (final item in diyDefaults.items)
            item.action == DiyToolbarAction.frequentRemarks
                ? item.copyWith(enabled: true)
                : item,
        ]),
      );
      await templateSvc.createRemark(
        commandId: 'probe-rem-1',
        content: '美团外卖工作餐',
        recordCatId: foodCat.id,
        usedTimes: 12,
      );
      await templateSvc.createRemark(
        commandId: 'probe-rem-2',
        content: '顺丰同城急件',
        recordCatId: noRef,
        usedTimes: 5,
      );

      final periodicId = await periodic.savePeriod(
        commandId: 'probe-periodic-1',
        draft: PeriodicDraft(
          recordType: RecordType.expense,
          money: Money.parse('25.00'),
          bookId: 1,
          periodType: PeriodType.daily,
          periodStartDate: DateTime(
            now.year,
            now.month,
            now.day,
          ).millisecondsSinceEpoch,
          categoryId: foodCat.id,
          assetId: bankAssetId,
          remark: '每日通勤咖啡',
        ),
      );

      final startMs = DateTime(now.year, now.month, 1).millisecondsSinceEpoch;
      final installmentId = await installmentSvc.createInstallment(
        commandId: 'probe-inst-1',
        draft: InstallmentDraft(
          name: 'MacBook Pro 14 分期',
          catId: shoppingCat.id,
          principal: Money.parse('12000.00'),
          periods: 12,
          charge: Money.parse('60.00'),
          startDateMs: startMs,
          assetId: creditAssetId,
          bookId: 1,
        ),
      );

      final debtLendId = await debtSvc.createDebt(
        commandId: 'probe-debt-lend-1',
        subType: AssetType.debtLend,
        name: '张三周转借款',
        principal: Money.parse('3000.00'),
        bookId: 1,
        startDate: startMs,
        remark: '短期周转',
      );
      await debtSvc.createDebt(
        commandId: 'probe-debt-borrow-1',
        subType: AssetType.debtBorrow,
        name: '父母装修拆借',
        principal: Money.parse('1500.00'),
        bookId: 1,
        startDate: startMs,
        countedInNetWorth: false,
      );

      final todayCal = LocalCalendarDate.fromDateTime(now);
      final savingsPlanId = await savingsSvc.savePlan(
        commandId: 'probe-savings-1',
        draft: SavingsPlanDraft(
          name: '年度家庭旅行基金',
          remark: '每月定额转入备用金',
          planType: SavingsPlanType.fixed,
          cycleType: SavingsCycleType.monthly,
          startDateMs: todayCal.startOfDayMs,
          endDateMs: todayCal.plusDays(90).startOfDayMs,
          startMoneyMinor: BigInt.from(200000),
          fromAssetId: bankAssetId,
          toAssetId: cashAssetId,
          bookId: 1,
        ),
      );

      final depositIndex = await depositSvc.createDeposit(
        commandId: 'probe-deposit-1',
        draft: FixedDepositDraft(
          targetAssetId: bankAssetId,
          principal: Money.parse('20000.00'),
          annualRate: DecimalValue.parse('2.15'),
          periodUnit: DepositPeriodUnit.year,
          periodCount: 1,
          depositDate: startMs,
          remark: '一年期整存整取',
          bookId: 1,
        ),
      );

      await reminderSvc.createReminder(
        commandId: 'probe-reminder-1',
        hour: 20,
        minute: 30,
        tip: '记得核对今日收支流水',
      );

      final bankCardId = await bankCardSvc.saveBankCard(
        commandId: 'probe-card-1',
        draft: BankCardDraft(
          cardType: BankCardType.debit,
          cardName: '招商银行工资卡',
          cardNo: '6225880123456789',
          cardOwner: '王小明',
          remark: '代发工资主卡',
          cardColor: '#E53935',
          cardAssetId: bankAssetId,
        ),
      );

      final wishId = await wishSvc.createWish(
        commandId: 'probe-wish-1',
        content: '人体工学办公椅',
        value: Money.parse('2999.00'),
      );
      final doneWishId = await wishSvc.createWish(
        commandId: 'probe-wish-2',
        content: '无线机械键盘',
        value: Money.parse('699.00'),
      );
      await wishSvc.setWishRealized(
        commandId: 'probe-wish-2-done',
        id: doneWishId,
        isRealized: true,
      );

      final noteId = await noteSvc.createNote(
        commandId: 'probe-note-1',
        title: '双十一家庭采购清单',
        content: '1. 纸巾日用品\n2. 猫粮两袋\n3. 冬季四件套',
      );
      final trashNoteId = await noteSvc.createNote(
        commandId: 'probe-note-2',
        title: '过期备忘录',
        content: '已完成的旧采购事项',
      );
      await noteSvc.moveToTrash(
        commandId: 'probe-note-2-trash',
        id: trashNoteId,
      );

      final csvBytes = encodeCsvBytes(const [
        csvExportHeader15,
        [
          '2026-05-01 12:30',
          '支出',
          '日常账本',
          '餐饮',
          '',
          '36.50',
          'CNY',
          '招商储蓄卡',
          '',
          '导入测试午餐',
          '日常餐饮',
          '',
          '',
          '否',
          '否',
        ],
      ]);
      final csvPreview = await csvSvc.previewImport(
        fileName: 'sample_import.csv',
        bytes: csvBytes,
        targetBookId: 1,
      );
      final csvCommit = await csvSvc.commitImport(
        commandId: 'probe-csv-batch-1',
        preview: csvPreview,
        selectedBookId: 1,
      );

      await autoSvc.ingestPaymentText(
        commandId: 'probe-auto-draft-1',
        rawText: '微信支付收款 28.50 元 瑞幸咖啡',
        packageName: 'com.tencent.mm',
        capturedAtMs: todayNoonMs,
      );
      await autoSvc.saveRule(
        commandId: 'probe-auto-rule-1',
        key: '瑞幸咖啡',
        info: AutoMapInfo(
          mapCategoryId: foodCat.id,
          mapAssetId: bankAssetId,
          bookId: 1,
        ),
      );

      await backupSvc.saveWebDavConfig(
        const WebDavConfig(
          serverUrl: 'https://dav.example.com/dav',
          username: 'demo',
          password: 'secret',
          remoteDirectory: '/TallyIsle',
          keepCount: 15,
        ),
      );
      await backupSvc.saveS3Config(
        const S3Config(
          endpoint: 'https://s3.example.com',
          region: 'auto',
          bucket: 'tallyisle-vault',
          accessKeyId: 'AKIAEXAMPLE',
          secretAccessKey: 'SECRETEXAMPLE',
          remotePrefix: 'tallyisle',
          keepCount: 15,
        ),
      );
      await backupSvc.saveLocalAutoBackupPolicy(
        const LocalAutoBackupPolicy(
          keepCount: 20,
          backupOnStartup: false,
          backupOnExit: false,
          backupOnIdle: true,
          idleMinutes: 5,
          backupOnSchedule: true,
          scheduleIntervalMinutes: 60,
        ),
      );
      await backupSvc.saveCloudSyncSettings(
        const CloudSyncSettings(
          backend: CloudBackendType.webdav,
          explicitBackend: true,
          deviceId: 'probe-device-1',
          deviceName: 'Linux-Workstation',
          autoSyncEnabled: true,
          syncOnStartup: false,
          syncOnExit: false,
          syncOnIdle: true,
          idleMinutes: 5,
          syncOnSchedule: true,
          scheduleIntervalMinutes: 60,
          autoArchiveBackupEnabled: true,
        ),
      );
      await backupSvc.createLocalBackup();

      ids = _SeedIds(
        secondBookId: secondBookId,
        foodCatId: foodCat.id,
        bankAssetId: bankAssetId,
        cashAssetId: cashAssetId,
        creditAssetId: creditAssetId,
        debtLendId: debtLendId,
        expRecordId: expRecordId,
        reimbRecordId: reimbRecordId,
        transferRecordId: transferRecordId,
        soloTagId: soloTagId,
        templateId: templateId,
        periodicId: periodicId,
        installmentId: installmentId,
        savingsPlanId: savingsPlanId,
        depositIndex: depositIndex,
        bankCardId: bankCardId,
        wishId: wishId,
        noteId: noteId,
        importBatchId: csvCommit.batchId,
      );
    });

    return _DesktopProbeHarness(
      db: db,
      ids: ids,
      tempRoot: tempRoot,
      localBackupDir: localBackupDir,
      attachmentsDir: attachmentsDir,
      scheduler: scheduler,
      autoBridge: autoBridge,
      widgetBridge: widgetBridge,
    );
  }

  Future<void> dispose(WidgetTester tester) async {
    tester.platformDispatcher.clearPlatformBrightnessTestValue();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    await tester.pumpWidget(const SizedBox.shrink());
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 40));
    }
    await tester.runAsync(scheduler.dispose);
    await tester.runAsync(autoBridge.dispose);
    await tester.runAsync(widgetBridge.dispose);
    await tester.runAsync(() async {
      await db.close();
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });
    await tester.pump(const Duration(seconds: 1));
  }
}

Future<void> _settleProbe(
  WidgetTester tester,
  List<String> violations,
  String scene,
) async {
  await tester.pump();
  final initialErr = tester.takeException();
  if (initialErr != null) {
    violations.add('[$scene] Exception on initial pump: $initialErr');
  }
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 18)),
    );
    await tester.pump(const Duration(milliseconds: 45));
    final err = tester.takeException();
    if (err != null) {
      violations.add('[$scene] Exception on settle #$i: $err');
    }
  }
}

final class _InputDecoratorMetric {
  const _InputDecoratorMetric({
    required this.element,
    required this.rect,
    required this.labelDesc,
    required this.hasLabel,
    required this.isFloating,
    required this.childDy,
    required this.labelOverlapsChild,
    required this.nearestRow,
  });

  final Element element;
  final Rect rect;
  final String labelDesc;
  final bool hasLabel;
  final bool isFloating;
  final double? childDy;
  final bool labelOverlapsChild;
  final Element? nearestRow;
}

String _describeLabel(InputDecoration dec) {
  final text = dec.labelText?.trim();
  if (text != null && text.isNotEmpty) return text;
  if (dec.label != null) return '<Widget label>';
  final hint = dec.hintText?.trim();
  if (hint != null && hint.isNotEmpty) return 'hint:$hint';
  return '<unlabeled>';
}

Element? _nearestRowOutsideInputDecorator(Element start) {
  Element? row;
  start.visitAncestorElements((ancestor) {
    if (ancestor.widget is InputDecorator) {
      return false;
    }
    if (ancestor.widget is Row) {
      row = ancestor;
      return false;
    }
    return true;
  });
  return row;
}

bool _isInsideHorizontalScrollable(Element start) {
  var inside = false;
  start.visitAncestorElements((ancestor) {
    final w = ancestor.widget;
    if (w is Scrollable &&
        (w.axisDirection == AxisDirection.left ||
            w.axisDirection == AxisDirection.right)) {
      inside = true;
      return false;
    }
    return true;
  });
  return inside;
}

Rect _globalRectOf(RenderBox box) {
  return MatrixUtils.transformRect(
    box.getTransformTo(null),
    Offset.zero & box.size,
  );
}

void _probeCurrentTree(
  WidgetTester tester, {
  required String scene,
  required Size viewport,
  required List<String> violations,
}) {
  final err = tester.takeException();
  if (err != null) {
    violations.add('[$scene] Unhandled Flutter exception: $err');
  }

  final inputMetrics = <_InputDecoratorMetric>[];
  final onStageElements = find
      .byElementPredicate((_) => true)
      .evaluate()
      .toList();

  for (final el in onStageElements) {
    final ro = el.renderObject;
    if (ro is! RenderBox || !ro.hasSize) continue;
    final size = ro.size;
    if (!size.width.isFinite ||
        !size.height.isFinite ||
        size.width < 0 ||
        size.height < 0) {
      violations.add(
        '[$scene] Invalid RenderBox size $size on ${el.widget.runtimeType}(key=${el.widget.key})',
      );
      continue;
    }

    final w = el.widget;
    final isInteractiveControl =
        w is InputDecorator ||
        w is DropdownButton ||
        w is SegmentedButton ||
        w is Chip ||
        w is ChoiceChip ||
        w is FilterChip ||
        w is ActionChip ||
        w is InputChip ||
        w is FilledButton ||
        w is OutlinedButton ||
        w is ElevatedButton ||
        w is TextButton ||
        w is FloatingActionButton ||
        w is SwitchListTile ||
        w is CheckboxListTile ||
        w is ListTile ||
        w is TabBar;

    if (isInteractiveControl) {
      if (size.height <= 0.0 || size.width <= 0.0) {
        violations.add(
          '[$scene] Zero-dimension control ${w.runtimeType}(key=${w.key}) size=$size',
        );
        continue;
      }

      final rect = _globalRectOf(ro);
      final verticallyVisible =
          rect.bottom > 1.0 && rect.top < viewport.height - 1.0;
      if (verticallyVisible && !_isInsideHorizontalScrollable(el)) {
        if (rect.left < -1.5 || rect.right > viewport.width + 1.5) {
          violations.add(
            '[$scene] Control exceeds horizontal viewport (${viewport.width}): '
            '${w.runtimeType}(key=${w.key}) rect=${rect.left.toStringAsFixed(1)}..${rect.right.toStringAsFixed(1)}',
          );
        }
      }
    }

    if (w is InputDecorator) {
      final dec = w.decoration;
      final hasLabel =
          ((dec.labelText ?? '').trim().isNotEmpty) || dec.label != null;
      final isFloating =
          hasLabel &&
          (!w.isEmpty ||
              dec.floatingLabelBehavior == FloatingLabelBehavior.always);
      final labelDesc = _describeLabel(dec);
      final rect = _globalRectOf(ro);

      // Measure inner content child top dy relative to InputDecorator
      double? childDy;
      Element? contentChildEl;
      void findContentChild(Element node) {
        if (contentChildEl != null) return;
        final nw = node.widget;
        if (nw is DropdownButton || nw is EditableText) {
          contentChildEl = node;
          return;
        }
        node.visitChildElements(findContentChild);
      }

      el.visitChildElements(findContentChild);
      if (contentChildEl?.renderObject is RenderBox) {
        final childBox = contentChildEl!.renderObject! as RenderBox;
        if (childBox.hasSize) {
          childDy = childBox.localToGlobal(Offset.zero, ancestor: ro).dy;
        }
      }

      // Check RenderParagraph overlap between floating label and content value
      // (skipping invisible hintText/counter subtrees wrapped in Opacity(0)).
      var labelOverlapsChild = false;
      if (isFloating && contentChildEl?.renderObject is RenderBox) {
        final contentRect = _globalRectOf(
          contentChildEl!.renderObject! as RenderBox,
        );
        final paragraphs = <RenderParagraph>[];
        void collectParagraphs(Element node) {
          if (identical(node, contentChildEl)) return;
          final nw = node.widget;
          if (nw is Opacity && nw.opacity <= 0.01) return;
          if (nw is Visibility && !nw.visible) return;
          if (nw is Offstage && nw.offstage) return;
          final nro = node.renderObject;
          if (nro is RenderAnimatedOpacity && nro.opacity.value <= 0.01) {
            return;
          }
          if (nro is RenderParagraph) {
            paragraphs.add(nro);
          }
          node.visitChildElements(collectParagraphs);
        }

        el.visitChildElements(collectParagraphs);
        for (final pBox in paragraphs) {
          if (!pBox.hasSize) continue;
          final pRect = _globalRectOf(pBox);
          final horizOverlap =
              pRect.right > contentRect.left + 2.0 &&
              pRect.left < contentRect.right - 2.0;
          final isAboveContentCenter =
              pRect.center.dy < contentRect.center.dy - 2.0;
          if (horizOverlap &&
              isAboveContentCenter &&
              pRect.bottom > contentRect.top + 1.0) {
            labelOverlapsChild = true;
          }
        }
      }

      if (hasLabel) {
        final tooShort = size.height < 40.0;
        final childTooHigh = isFloating && childDy != null && childDy < 10.0;
        if (tooShort || childTooHigh || labelOverlapsChild) {
          violations.add(
            '[$scene] Labeled InputDecorator("$labelDesc", key=${w.key}) squashed: '
            'height=${size.height.toStringAsFixed(1)}px (<40), '
            'childDy=${childDy?.toStringAsFixed(1) ?? "n/a"} (<10 when floating=$isFloating), '
            'labelOverlapsValue=$labelOverlapsChild',
          );
        }
      }

      inputMetrics.add(
        _InputDecoratorMetric(
          element: el,
          rect: rect,
          labelDesc: labelDesc,
          hasLabel: hasLabel,
          isFloating: isFloating,
          childDy: childDy,
          labelOverlapsChild: labelOverlapsChild,
          nearestRow: _nearestRowOutsideInputDecorator(el),
        ),
      );
    }

    if (w is ListTile || w is SwitchListTile || w is CheckboxListTile) {
      // Check title vs subtitle vertical collision inside dense tiles
      final paragraphs = <Rect>[];
      void collectTileText(Element node) {
        if (node.renderObject is RenderParagraph) {
          final pb = node.renderObject! as RenderParagraph;
          if (pb.hasSize && pb.size.width > 20 && pb.size.height > 8) {
            paragraphs.add(_globalRectOf(pb));
          }
        }
        node.visitChildElements(collectTileText);
      }

      el.visitChildElements(collectTileText);
      for (var i = 0; i < paragraphs.length; i++) {
        for (var j = i + 1; j < paragraphs.length; j++) {
          final a = paragraphs[i];
          final b = paragraphs[j];
          final sameColumn = a.right > b.left + 8.0 && a.left < b.right - 8.0;
          if (sameColumn) {
            final upper = a.top <= b.top ? a : b;
            final lower = a.top <= b.top ? b : a;
            if ((lower.top - upper.top).abs() > 2.0 &&
                upper.bottom > lower.top + 1.0) {
              violations.add(
                '[$scene] ${w.runtimeType}(key=${w.key}) text lines overlap vertically: '
                'upper=${upper.top.toStringAsFixed(1)}..${upper.bottom.toStringAsFixed(1)}, '
                'lower=${lower.top.toStringAsFixed(1)}..${lower.bottom.toStringAsFixed(1)}',
              );
            }
          }
        }
      }
    }
  }

  // Check adjacent InputDecorators in the same Row for height mismatch > 3.0px
  final byRow = <Element, List<_InputDecoratorMetric>>{};
  for (final m in inputMetrics) {
    if (m.nearestRow != null) {
      byRow.putIfAbsent(m.nearestRow!, () => <_InputDecoratorMetric>[]).add(m);
    }
  }
  for (final group in byRow.values) {
    if (group.length < 2) continue;
    group.sort((a, b) => a.rect.left.compareTo(b.rect.left));
    for (var i = 0; i < group.length - 1; i++) {
      final left = group[i];
      final right = group[i + 1];
      final sameBand =
          (left.rect.center.dy - right.rect.center.dy).abs() < 24.0;
      final heightDiff = (left.rect.height - right.rect.height).abs();
      if (sameBand && heightDiff > 3.0) {
        violations.add(
          '[$scene] Row sibling InputDecorator height mismatch (${heightDiff.toStringAsFixed(1)}px > 3.0px): '
          '"${left.labelDesc}"=${left.rect.height.toStringAsFixed(1)}px vs '
          '"${right.labelDesc}"=${right.rect.height.toStringAsFixed(1)}px',
        );
      }
    }
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets(
    'Desktop RenderBox geometry probe across all workspaces, MePage 31+ embedded pages, secondary pages, and 11+ modal forms',
    variant: _desktopPlatforms,
    (tester) async {
      final platform =
          debugDefaultTargetPlatformOverride ?? TargetPlatform.linux;
      final harness = await _DesktopProbeHarness.create(tester);
      addTearDown(() => harness.dispose(tester));

      final violations = <String>[];
      final ids = harness.ids;

      final providerOverrides = [
        databaseProvider.overrideWith((ref) async => harness.db),
        reminderSchedulerProvider.overrideWithValue(harness.scheduler),
        backupLocalDirectoryOverrideProvider.overrideWithValue(
          () async => harness.localBackupDir,
        ),
        backupAttachmentsDirectoryOverrideProvider.overrideWithValue(
          () async => harness.attachmentsDir,
        ),
        webDavBackupsProvider.overrideWith(
          (_) async => const <BackupFileMetadata>[],
        ),
        s3BackupsProvider.overrideWith(
          (_) async => const <BackupFileMetadata>[],
        ),
        activeCloudBackupsProvider.overrideWith(
          (_) async => const <BackupFileMetadata>[],
        ),
        autoBillBridgeProvider.overrideWithValue(harness.autoBridge),
        appWidgetBridgeProvider.overrideWithValue(harness.widgetBridge),
      ];

      // -----------------------------------------------------------------------
      // Part 1: Full TallyIsleApp shell across Light & Dark × 4 desktop sizes
      // + MePage 33 embedded pages + Templates/Remarks in-place & height gates
      // -----------------------------------------------------------------------
      for (final brightness in const <Brightness>[
        Brightness.light,
        Brightness.dark,
      ]) {
        tester.platformDispatcher.platformBrightnessTestValue = brightness;

        for (final size in _desktopSizes) {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;

          await tester.pumpWidget(
            ProviderScope(
              key: ValueKey<String>(
                'full-app-${platform.name}-${brightness.name}-${size.width.toInt()}x${size.height.toInt()}',
              ),
              retry: (_, _) => null,
              overrides: providerOverrides,
              child: const TallyIsleApp(),
            ),
          );
          final tagPrefix =
              '${platform.name}@${size.width.toInt()}x${size.height.toInt()}:${brightness.name}';
          await _settleProbe(tester, violations, '$tagPrefix:Home');
          _probeCurrentTree(
            tester,
            scene: '$tagPrefix:Home',
            viewport: size,
            violations: violations,
          );

          // Stats branch
          await tester.tap(find.byKey(const Key('nav-slot-stats')));
          await _settleProbe(tester, violations, '$tagPrefix:Stats');
          _probeCurrentTree(
            tester,
            scene: '$tagPrefix:Stats',
            viewport: size,
            violations: violations,
          );

          // Assets branch
          await tester.tap(find.byKey(const Key('nav-slot-assets')));
          await _settleProbe(tester, violations, '$tagPrefix:Assets');
          _probeCurrentTree(
            tester,
            scene: '$tagPrefix:Assets',
            viewport: size,
            violations: violations,
          );

          // More (MePage) branch
          await tester.tap(find.byKey(const Key('nav-slot-more')));
          await _settleProbe(tester, violations, '$tagPrefix:Me');
          _probeCurrentTree(
            tester,
            scene: '$tagPrefix:Me',
            viewport: size,
            violations: violations,
          );

          // At 1280x800, walk ALL 33 desktop MePage directory items in-place!
          if (size == const Size(1280, 800)) {
            const meKeys = <String>[
              'me-books',
              'me-categories',
              'me-tags',
              'me-currencies',
              'me-reimburse',
              'me-periodic',
              'me-installments',
              'me-debts',
              'me-savings',
              'me-deposits',
              'me-reminders',
              'me-backup',
              'me-import-csv',
              'me-import-batches',
              'me-export-csv',
              'me-migration',
              'me-wishes',
              'me-notes',
              'me-templates',
              'me-remarks',
              'me-bank-cards',
              'me-batch-records',
              'me-category-transfer',
              'me-attachments',
              'me-stat-stories',
              'me-auto-bill',
              'me-ocr',
              'me-url-scheme',
              'me-app-lock',
              'me-settings',
              'me-diy-toolbar',
              'me-data-health',
              'me-about',
            ];
            for (final keyName in meKeys) {
              final itemFinder = find.byKey(Key(keyName));
              await tester.ensureVisible(itemFinder);
              await tester.pump(const Duration(milliseconds: 30));
              await tester.tap(itemFinder);
              await _settleProbe(tester, violations, '$tagPrefix:Me/$keyName');
              _probeCurrentTree(
                tester,
                scene: '$tagPrefix:Me/$keyName',
                viewport: size,
                violations: violations,
              );

              if (keyName == 'me-templates') {
                // Hard assertion 1a: TemplatesPage book filter dropdown >= 44px
                final tplDecorator = find
                    .ancestor(
                      of: find.byKey(const Key('templates_book_filter')),
                      matching: find.byType(InputDecorator),
                    )
                    .first;
                final tplHeight = tester.getSize(tplDecorator).height;
                expect(
                  tplHeight,
                  greaterThanOrEqualTo(44.0),
                  reason:
                      '[$tagPrefix] TemplatesPage book filter height ($tplHeight) must be >= 44px',
                );

                // Hard assertion 2: Clicking "常用备注" inside MePage dual-pane
                // switches stage in-place without leaving dual-pane!
                await tester.tap(
                  find.byKey(const Key('open_remarks_page_button')),
                );
                await _settleProbe(
                  tester,
                  violations,
                  '$tagPrefix:Me/templates->remarks-inplace',
                );
                expect(find.byKey(const Key('remarks_page')), findsOneWidget);
                expect(find.byKey(const Key('me-templates')), findsOneWidget);
                expect(
                  find.descendant(
                    of: find.byKey(const Key('remarks_page')),
                    matching: find.byType(BackButton),
                  ),
                  findsNothing,
                );

                // Hard assertion 1b: RemarksPage filter dropdown & search box
                // both >= 44px and row sibling height diff <= 2.0px
                final remFilterDec = find
                    .ancestor(
                      of: find.byKey(const Key('remarks_category_filter')),
                      matching: find.byType(InputDecorator),
                    )
                    .first;
                final remSearchDec = find
                    .descendant(
                      of: find.byKey(const Key('remarks_search_input')),
                      matching: find.byType(InputDecorator),
                    )
                    .first;
                final remFilterH = tester.getSize(remFilterDec).height;
                final remSearchH = tester.getSize(remSearchDec).height;
                expect(
                  remFilterH,
                  greaterThanOrEqualTo(44.0),
                  reason:
                      '[$tagPrefix] RemarksPage category filter height ($remFilterH) must be >= 44px',
                );
                expect(
                  remSearchH,
                  greaterThanOrEqualTo(44.0),
                  reason:
                      '[$tagPrefix] RemarksPage search box height ($remSearchH) must be >= 44px',
                );
                expect(
                  (remFilterH - remSearchH).abs(),
                  lessThanOrEqualTo(2.0),
                  reason:
                      '[$tagPrefix] RemarksPage filter ($remFilterH) vs search ($remSearchH) height diff must be <= 2px',
                );
              }
            }
          }
        }
      }
      tester.platformDispatcher.clearPlatformBrightnessTestValue();

      // -----------------------------------------------------------------------
      // Part 2: Direct Light & Dark probes of all secondary pages, stats pages,
      // interactive sub-states, and all 11+ create/edit modal forms/dialogs.
      // -----------------------------------------------------------------------
      Future<void> mountStandalonePage({
        required String name,
        required Size size,
        required Brightness brightness,
        required Widget Function() builder,
        Future<void> Function(String scene)? afterMount,
      }) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        final theme = _buildDesktopAppTheme(brightness);
        final scene =
            '${platform.name}@${size.width.toInt()}x${size.height.toInt()}:${brightness.name}:$name';

        await tester.pumpWidget(
          ProviderScope(
            key: ValueKey<String>('standalone-$scene'),
            retry: (_, _) => null,
            overrides: providerOverrides,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              locale: const Locale('zh'),
              supportedLocales: const <Locale>[Locale('zh'), Locale('en')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              theme: theme,
              darkTheme: theme,
              themeMode: brightness == Brightness.dark
                  ? ThemeMode.dark
                  : ThemeMode.light,
              builder: (ctx, child) => DesktopAdaptiveScope(
                isDesktop: true,
                child: child ?? const SizedBox.shrink(),
              ),
              home: builder(),
            ),
          ),
        );
        await _settleProbe(tester, violations, scene);
        _probeCurrentTree(
          tester,
          scene: scene,
          viewport: size,
          violations: violations,
        );
        if (afterMount != null) {
          await afterMount(scene);
        }
      }

      final standalonePages = <(String, Widget Function(), Future<void> Function(String scene)?)>[
        ('HomePage', () => const HomePage(), null),
        ('AssetsPage', () => const AssetsPage(), null),
        (
          'AssetDetailPage(Credit)',
          () => AssetDetailPage(assetId: ids.creditAssetId),
          null,
        ),
        (
          'RecordDetailPage',
          () => RecordDetailPage(recordId: ids.expRecordId),
          null,
        ),
        (
          'SearchPage(ExpandedFilters)',
          () => const SearchPage(),
          (scene) async {
            final toggle = find.byKey(const Key('search-filter-toggle'));
            if (toggle.evaluate().isNotEmpty) {
              await tester.tap(toggle);
              await _settleProbe(tester, violations, '$scene+FilterOpen');
              _probeCurrentTree(
                tester,
                scene: '$scene+FilterOpen',
                viewport: const Size(1280, 800),
                violations: violations,
              );
            }
          },
        ),
        ('CalendarPage', () => const CalendarPage(), null),
        ('StatsPage', () => const StatsPage(), null),
        ('BudgetPage', () => const BudgetPage(), null),
        (
          'CategoryStatsPage+DrilldownDetail',
          () => const CategoryStatsPage(),
          (scene) async {
            // Hard assertion 3a (standalone): CategoryStatsPage -> drilldown -> bill detail visible on top
            final catRow = find.byKey(Key('category-row-${ids.foodCatId}'));
            expect(catRow, findsOneWidget);
            await tester.tap(catRow);
            await _settleProbe(tester, violations, '$scene+Drilldown');
            final billTile = find.byKey(
              Key('drilldown-bill-${ids.expRecordId}'),
            );
            expect(billTile, findsOneWidget);
            await tester.tap(billTile);
            await _settleProbe(tester, violations, '$scene+RecordDetail');
            expect(
              find.byKey(const Key('detail-amount')).hitTestable(),
              findsOneWidget,
            );
            _probeCurrentTree(
              tester,
              scene: '$scene+RecordDetail',
              viewport: const Size(1280, 800),
              violations: violations,
            );
          },
        ),
        (
          'CategoryRouteDrilldownPage',
          () => CategoryRouteDrilldownPage(categoryId: ids.foodCatId),
          null,
        ),
        ('TagRankingsPage', () => const TagRankingsPage(), null),
        (
          'TagDetailStatsPage',
          () => TagDetailStatsPage(tagId: ids.soloTagId),
          null,
        ),
        ('AssetTrendPage', () => const AssetTrendPage(), null),
        ('AnnualReportPage', () => const AnnualReportPage(), null),
        ('TemplatesPage', () => const TemplatesPage(), null),
        (
          'RemarksPage+Dialog',
          () => const RemarksPage(),
          (scene) async {
            final fab = find.byKey(const Key('add_remark_fab'));
            if (fab.evaluate().isNotEmpty) {
              await tester.tap(fab);
              await _settleProbe(tester, violations, '$scene+RemarkDialog');
              _probeCurrentTree(
                tester,
                scene: '$scene+RemarkDialog',
                viewport: const Size(1280, 800),
                violations: violations,
              );
            }
          },
        ),
        (
          'CurrenciesPage+AddDialog',
          () => const CurrenciesPage(),
          (scene) async {
            final fab = find.byKey(const Key('add-currency'));
            if (fab.evaluate().isNotEmpty) {
              await tester.tap(fab);
              await _settleProbe(tester, violations, '$scene+CurrencyDialog');
              _probeCurrentTree(
                tester,
                scene: '$scene+CurrencyDialog',
                viewport: const Size(1280, 800),
                violations: violations,
              );
            }
          },
        ),
        ('PeriodicPage', () => PeriodicPage(onRecordTap: (_) {}), null),
        ('InstallmentPage', () => InstallmentPage(onRecordTap: (_) {}), null),
        ('DebtPage', () => const DebtPage(), null),
        ('SavingsPage', () => const SavingsPage(), null),
        (
          'PeriodicHistoryPage',
          () => PeriodicHistoryPage(
            periodId: ids.periodicId,
            onRecordTap: (_) {},
          ),
          null,
        ),
        (
          'InstallmentDetailPage',
          () => InstallmentDetailPage(
            installmentId: ids.installmentId,
            onRecordTap: (_) {},
          ),
          null,
        ),
        (
          'DebtDetailPage+RepayDialog',
          () => DebtDetailPage(debtId: ids.debtLendId),
          (scene) async {
            final collectBtn = find.text('收款');
            if (collectBtn.evaluate().isNotEmpty) {
              await tester.tap(collectBtn.first);
              await _settleProbe(tester, violations, '$scene+CollectDialog');
              _probeCurrentTree(
                tester,
                scene: '$scene+CollectDialog',
                viewport: const Size(1280, 800),
                violations: violations,
              );
            }
          },
        ),
        (
          'SavingsDetailPage',
          () => SavingsDetailPage(planId: ids.savingsPlanId),
          null,
        ),
        ('FixedDepositPage', () => FixedDepositPage(onRecordTap: (_) {}), null),
        (
          'ReimbursePage+DesktopDialogs',
          () => ReimbursePage(onRecordTap: (_) {}),
          (scene) async {
            // Hard assertion 5a: Single reimburse opens centered Dialog, NOT BottomSheet
            final singleBtn = find.byKey(
              Key('reimburse-action-${ids.reimbRecordId}'),
            );
            expect(singleBtn, findsOneWidget);
            await tester.tap(singleBtn);
            await _settleProbe(
              tester,
              violations,
              '$scene+SingleReimburseDialog',
            );
            expect(find.byType(Dialog), findsOneWidget);
            expect(find.byType(BottomSheet), findsNothing);
            expect(
              find.descendant(
                of: find.byType(Dialog),
                matching: find.byKey(const Key('reimburse-dialog-amount')),
              ),
              findsOneWidget,
            );
            _probeCurrentTree(
              tester,
              scene: '$scene+SingleReimburseDialog',
              viewport: const Size(1280, 800),
              violations: violations,
            );
            await tester.tap(
              find.descendant(
                of: find.byType(Dialog),
                matching: find.byType(CloseButton),
              ),
            );
            await _settleProbe(tester, violations, '$scene+ClosedSingle');

            // Hard assertion 5b: Batch reimburse opens centered Dialog, NOT BottomSheet
            await tester.tap(find.byKey(const Key('reimburse-batch-toggle')));
            await _settleProbe(tester, violations, '$scene+BatchMode');
            await tester.tap(
              find.byKey(const Key('reimburse-batch-select-all')),
            );
            await _settleProbe(tester, violations, '$scene+BatchSelected');
            await tester.tap(find.byKey(const Key('reimburse-batch-submit')));
            await _settleProbe(
              tester,
              violations,
              '$scene+BatchReimburseDialog',
            );
            expect(find.byType(Dialog), findsOneWidget);
            expect(find.byType(BottomSheet), findsNothing);
            expect(
              find.descendant(
                of: find.byType(Dialog),
                matching: find.byKey(const Key('reimburse-batch-remark')),
              ),
              findsOneWidget,
            );
            _probeCurrentTree(
              tester,
              scene: '$scene+BatchReimburseDialog',
              viewport: const Size(1280, 800),
              violations: violations,
            );
          },
        ),
        (
          'ReminderPage+Dialog',
          () => const ReminderPage(),
          (scene) async {
            final fab = find.byKey(const Key('add_reminder_fab'));
            if (fab.evaluate().isNotEmpty) {
              await tester.tap(fab);
              await _settleProbe(tester, violations, '$scene+ReminderDialog');
              _probeCurrentTree(
                tester,
                scene: '$scene+ReminderDialog',
                viewport: const Size(1280, 800),
                violations: violations,
              );
            }
          },
        ),
        (
          'BackupPage(Scrolled)',
          () => const BackupPage(),
          (scene) async {
            final scrollable = find.byType(Scrollable);
            if (scrollable.evaluate().isNotEmpty) {
              await tester.drag(scrollable.first, const Offset(0, -520));
              await _settleProbe(tester, violations, '$scene+Scroll1');
              _probeCurrentTree(
                tester,
                scene: '$scene+Scroll1',
                viewport: const Size(1280, 800),
                violations: violations,
              );
              await tester.drag(scrollable.first, const Offset(0, -520));
              await _settleProbe(tester, violations, '$scene+Scroll2');
              _probeCurrentTree(
                tester,
                scene: '$scene+Scroll2',
                viewport: const Size(1280, 800),
                violations: violations,
              );
            }
          },
        ),
        ('WebDavConfigPage', () => const WebDavConfigPage(), null),
        ('S3ConfigPage', () => const S3ConfigPage(), null),
        (
          'CsvImportPage+Preview',
          () => CsvImportPage(
            pickFile: () async => SelectedBytes(
              'sample_import.csv',
              encodeCsvBytes(const [
                csvExportHeader15,
                [
                  '2026-05-02 12:30',
                  '支出',
                  '',
                  '餐饮',
                  '',
                  '28.00',
                  'CNY',
                  '招商储蓄卡',
                  '',
                  '午餐',
                  '',
                  '',
                  '',
                  '否',
                  '否',
                ],
              ]),
            ),
          ),
          (scene) async {
            final btn = find.byKey(const Key('pick_import_file_button'));
            if (btn.evaluate().isNotEmpty) {
              await tester.tap(btn);
              await _settleProbe(tester, violations, '$scene+Preview');
              _probeCurrentTree(
                tester,
                scene: '$scene+Preview',
                viewport: const Size(1280, 800),
                violations: violations,
              );
            }
          },
        ),
        ('CsvExportPage', () => const CsvExportPage(), null),
        ('ImportBatchesPage', () => const ImportBatchesPage(), null),
        (
          'ImportBatchDetailPage',
          () => ImportBatchDetailPage(batchId: ids.importBatchId),
          null,
        ),
        ('MigrationPage', () => const MigrationPage(), null),
        ('PennyImportPage', () => const PennyImportPage(), null),
        ('NoteTrashPage', () => const NoteTrashPage(), null),
        (
          'BatchEditPage+Sheet',
          () => const BatchEditPage(),
          (scene) async {
            final selectAll = find.byKey(const Key('batch-select-all'));
            if (selectAll.evaluate().isNotEmpty) {
              await tester.tap(selectAll);
              await _settleProbe(tester, violations, '$scene+Selected');
              final modifyBtn = find.byKey(const Key('batch-open-edit-btn'));
              if (modifyBtn.evaluate().isNotEmpty) {
                await tester.tap(modifyBtn);
                await _settleProbe(tester, violations, '$scene+ConfigSheet');
                // Hard assertion 5c: BatchEditPage opens centered Dialog, NOT BottomSheet
                expect(
                  find.byKey(const Key('batch-edit-dialog')),
                  findsOneWidget,
                );
                expect(find.byType(BottomSheet), findsNothing);
                for (final toggleKey in const <String>[
                  'batch-toggle-category',
                  'batch-toggle-asset',
                  'batch-toggle-book',
                ]) {
                  final tf = find.byKey(Key(toggleKey));
                  if (tf.evaluate().isNotEmpty) {
                    await tester.ensureVisible(tf);
                    await tester.tap(tf);
                    await tester.pump(const Duration(milliseconds: 50));
                  }
                }
                await _settleProbe(
                  tester,
                  violations,
                  '$scene+ConfigSheetExpanded',
                );
                _probeCurrentTree(
                  tester,
                  scene: '$scene+ConfigSheetExpanded',
                  viewport: const Size(1280, 800),
                  violations: violations,
                );
              }
            }
          },
        ),
        (
          'CategoryTransferPage(BothTabs)',
          () => const CategoryTransferPage(initialTab: 1),
          null,
        ),
        ('BillImagesPage', () => const BillImagesPage(), null),
        (
          'AutoBillPage+Dialogs',
          () => const AutoBillPage(),
          (scene) async {
            final confirmBtn = find.text('核对入账');
            if (confirmBtn.evaluate().isNotEmpty) {
              await tester.tap(confirmBtn.first);
              await _settleProbe(tester, violations, '$scene+ConfirmDialog');
              _probeCurrentTree(
                tester,
                scene: '$scene+ConfirmDialog',
                viewport: const Size(1280, 800),
                violations: violations,
              );
            }
          },
        ),
        (
          'OcrBillPage(ParsedCandidates)',
          () => const OcrBillPage(),
          (scene) async {
            final input = find.byKey(const Key('ocr_text_input'));
            if (input.evaluate().isNotEmpty) {
              await tester.enterText(
                input,
                '2026年11月\n11月10日 09:15\n星巴克\n-32.00\n11月11日 12:10\n麦当劳\n-28.50',
              );
              await tester.pump();
              final parseBtn = find.byKey(const Key('ocr_parse_text_button'));
              if (parseBtn.evaluate().isNotEmpty) {
                await tester.tap(parseBtn);
                await _settleProbe(tester, violations, '$scene+Candidates');
                _probeCurrentTree(
                  tester,
                  scene: '$scene+Candidates',
                  viewport: const Size(1280, 800),
                  violations: violations,
                );
              }
            }
          },
        ),
        ('UrlSchemePage', () => const UrlSchemePage(), null),
        ('AppLockSettingsPage', () => const AppLockSettingsPage(), null),
        ('SettingsPage', () => const SettingsPage(), null),
        ('DiyToolbarSettingsPage', () => const DiyToolbarSettingsPage(), null),
        ('DataHealthPage', () => const DataHealthPage(), null),
        (
          'StatStoriesPage+Dialog',
          () => const StatStoriesPage(),
          (scene) async {
            final fab = find.byKey(const Key('stat_story_add_fab'));
            if (fab.evaluate().isNotEmpty) {
              await tester.tap(fab);
              await _settleProbe(tester, violations, '$scene+StoryDialog');
              _probeCurrentTree(
                tester,
                scene: '$scene+StoryDialog',
                viewport: const Size(1280, 800),
                violations: violations,
              );
            }
          },
        ),
        ('AboutHelpPage', () => const AboutHelpPage(), null),
        ('BooksPage', () => const BooksPage(), null),
        ('CategoriesPage', () => const CategoriesPage(), null),
        ('TagsPage', () => const TagsPage(), null),
        ('BankCardsPage', () => const BankCardsPage(), null),
        ('WishesPage', () => const WishesPage(), null),
        ('NotesPage', () => const NotesPage(), null),
        ('MePage', () => const MePage(), null),
      ];

      for (final (name, builder, afterMount) in standalonePages) {
        await mountStandalonePage(
          name: name,
          size: const Size(1280, 800),
          brightness: Brightness.light,
          builder: builder,
          afterMount: afterMount,
        );
        await mountStandalonePage(
          name: name,
          size: const Size(1280, 800),
          brightness: Brightness.dark,
          builder: builder,
        );
      }

      // -----------------------------------------------------------------------
      // Part 3: All 11+ Create/Edit Desktop Modal Dialogs & Record Popups
      // -----------------------------------------------------------------------
      final modalForms = <(String, Future<void> Function(BuildContext ctx))>[
        (
          'Modal:DesktopRecordEditor(Expense)',
          (ctx) => showDesktopRecordEditorDialog(ctx),
        ),
        (
          'Modal:DesktopRecordEditor(Transfer)',
          (ctx) => showDesktopRecordEditorDialog(
            ctx,
            initialType: RecordType.transfer,
          ),
        ),
        (
          'Modal:AssetEditor(Credit)',
          (ctx) => pushDesktopModalOrMaterialRoute<void>(
            ctx,
            child: AssetEditorPage(assetId: ids.creditAssetId),
          ),
        ),
        (
          'Modal:DebtEditor',
          (ctx) => pushDesktopModalOrMaterialRoute<void>(
            ctx,
            child: DebtEditorPage(debtId: ids.debtLendId),
          ),
        ),
        (
          'Modal:InstallmentEditor',
          (ctx) => pushDesktopModalOrMaterialRoute<void>(
            ctx,
            child: InstallmentEditorPage(installmentId: ids.installmentId),
          ),
        ),
        (
          'Modal:PeriodicEditor(Transfer)',
          (ctx) => pushDesktopModalOrMaterialRoute<void>(
            ctx,
            child: PeriodicEditorPage(periodId: ids.periodicId),
          ),
        ),
        (
          'Modal:FixedDepositEditor',
          (ctx) => pushDesktopModalOrMaterialRoute<void>(
            ctx,
            child: FixedDepositEditorPage(
              assetId: ids.bankAssetId,
              depositIndex: ids.depositIndex,
            ),
          ),
        ),
        (
          'Modal:SavingsEditor',
          (ctx) => pushDesktopModalOrMaterialRoute<void>(
            ctx,
            child: SavingsEditorPage(planId: ids.savingsPlanId),
          ),
        ),
        (
          'Modal:TemplateEditor',
          (ctx) => pushDesktopModalOrMaterialRoute<void>(
            ctx,
            child: TemplateEditorPage(templateId: ids.templateId),
          ),
        ),
        (
          'Modal:BankCardEditor',
          (ctx) => pushDesktopModalOrMaterialRoute<void>(
            ctx,
            child: BankCardEditorPage(cardId: ids.bankCardId),
          ),
        ),
        (
          'Modal:WishEditor',
          (ctx) => pushDesktopModalOrMaterialRoute<void>(
            ctx,
            child: WishEditorPage(wishId: ids.wishId),
          ),
        ),
        (
          'Modal:NoteEditor',
          (ctx) => pushDesktopModalOrMaterialRoute<void>(
            ctx,
            child: NoteEditorPage(noteId: ids.noteId),
          ),
        ),
        (
          'Modal:RecordDateTimeDialog',
          (ctx) => showDialog<void>(
            context: ctx,
            builder: (_) => RecordDateTimeDialog(
              initialDateTime: DateTime(2026, 5, 15, 14, 30),
            ),
          ),
        ),
        (
          'Modal:RecordReceiptDialog',
          (ctx) => showRecordReceiptDialog(ctx, recordId: ids.expRecordId),
        ),
      ];

      for (final brightness in const <Brightness>[
        Brightness.light,
        Brightness.dark,
      ]) {
        for (final modalSize in const <Size>[Size(1280, 800), Size(520, 600)]) {
          for (final (formName, openModal) in modalForms) {
            tester.view.physicalSize = modalSize;
            tester.view.devicePixelRatio = 1.0;
            final scene =
                '${platform.name}@${modalSize.width.toInt()}x${modalSize.height.toInt()}:${brightness.name}:$formName';

            late BuildContext hostCtx;
            await tester.pumpWidget(
              ProviderScope(
                key: ValueKey<String>('modal-host-$scene'),
                retry: (_, _) => null,
                overrides: providerOverrides,
                child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  locale: const Locale('zh'),
                  supportedLocales: const <Locale>[Locale('zh'), Locale('en')],
                  localizationsDelegates: GlobalMaterialLocalizations.delegates,
                  theme: _buildDesktopAppTheme(brightness),
                  darkTheme: _buildDesktopAppTheme(brightness),
                  themeMode: brightness == Brightness.dark
                      ? ThemeMode.dark
                      : ThemeMode.light,
                  builder: (ctx, child) => DesktopAdaptiveScope(
                    isDesktop: true,
                    child: child ?? const SizedBox.shrink(),
                  ),
                  home: Scaffold(
                    body: Builder(
                      builder: (ctx) {
                        hostCtx = ctx;
                        return const SizedBox.expand();
                      },
                    ),
                  ),
                ),
              ),
            );
            await tester.pump();
            // Launch modal without awaiting dismissal
            // ignore: unawaited_futures
            openModal(hostCtx);
            await _settleProbe(tester, violations, scene);
            _probeCurrentTree(
              tester,
              scene: scene,
              viewport: modalSize,
              violations: violations,
            );

            // Hard assertion 4: RecordEditorPage remark row vertical center
            // alignment (dy diff <= 1.5px) AND expanded custom keypad with
            // wrapped multi-pill toolbar keeps editor-summary-amount-row 100%
            // visible without clipping/overlap and category grid >= 120px!
            if (formName == 'Modal:DesktopRecordEditor(Expense)') {
              final remarkRowFinder = find.byKey(
                const Key('editor-remark-row'),
              );
              final leftNoteIconFinder = find.descendant(
                of: remarkRowFinder,
                matching: find.byIcon(Icons.edit_note_rounded),
              );
              final remarkEditableFinder = find.descendant(
                of: find.byKey(const Key('remark')),
                matching: find.byType(EditableText),
              );

              // ①a Empty hint state center.dy alignment <= 1.5px
              final emptyIconDy = tester.getCenter(leftNoteIconFinder).dy;
              final emptyEditableDy = tester.getCenter(remarkEditableFinder).dy;
              expect(
                (emptyIconDy - emptyEditableDy).abs(),
                lessThanOrEqualTo(1.5),
                reason:
                    '[$scene] Empty remark icon dy ($emptyIconDy) vs EditableText dy ($emptyEditableDy) must be <= 1.5px',
              );

              // ①b Populated remark ('午饭') with clear & frequent-remarks icons
              await tester.enterText(find.byKey(const Key('remark')), '午饭');
              await tester.pump();
              final clearBtnFinder = find.byKey(
                const Key('editor-remark-clear-btn'),
              );
              expect(clearBtnFinder, findsOneWidget);
              final iconDy = tester.getCenter(leftNoteIconFinder).dy;
              final editableDy = tester.getCenter(remarkEditableFinder).dy;
              final clearBtnDy = tester.getCenter(clearBtnFinder).dy;
              expect(
                (iconDy - editableDy).abs(),
                lessThanOrEqualTo(1.5),
                reason:
                    '[$scene] Remark left icon dy ($iconDy) vs EditableText dy ($editableDy) must be <= 1.5px',
              );
              expect(
                (editableDy - clearBtnDy).abs(),
                lessThanOrEqualTo(1.5),
                reason:
                    '[$scene] Remark EditableText dy ($editableDy) vs clear button dy ($clearBtnDy) must be <= 1.5px',
              );
              final remarksToggleFinder = find.byKey(
                const Key('editor-remarks-toggle-btn'),
              );
              if (remarksToggleFinder.evaluate().isNotEmpty) {
                final toggleDy = tester.getCenter(remarksToggleFinder).dy;
                expect(
                  (iconDy - toggleDy).abs(),
                  lessThanOrEqualTo(1.5),
                  reason:
                      '[$scene] Remark left icon dy ($iconDy) vs remarks toggle dy ($toggleDy) must be <= 1.5px',
                );
              }

              // ② Multi-pill wrap + expanded keypad geometry & visibility gate
              expect(
                find.byKey(const Key('editor-exclude-exin-pill')),
                findsOneWidget,
              );
              final firstPillDy = tester
                  .getCenter(find.byKey(const Key('asset')))
                  .dy;
              final lastPillDy = tester
                  .getCenter(find.byKey(const Key('editor-exclude-exin-pill')))
                  .dy;
              expect(
                lastPillDy - firstPillDy,
                greaterThan(16.0),
                reason:
                    '[$scene] Toolbar pills must wrap onto >= 2 rows for multi-pill wrap assertion',
              );

              final keypadToggle = find.byKey(
                const Key('desktop-toggle-keypad'),
              );
              expect(keypadToggle, findsOneWidget);
              await tester.tap(keypadToggle);
              await _settleProbe(tester, violations, '$scene+KeypadExpanded');
              await tester.tap(find.byKey(const Key('keypad-1')));
              await tester.pump();
              await tester.tap(find.byKey(const Key('keypad-4')));
              await _settleProbe(tester, violations, '$scene+KeypadExpanded14');

              final dialogSurfaceRect = tester.getRect(
                find
                    .descendant(
                      of: find.byKey(const Key('desktop-record-editor-dialog')),
                      matching: find.byType(Material),
                    )
                    .first,
              );
              final zone2Rect = tester.getRect(
                find.byKey(const Key('editor-zone2-scroll')),
              );
              final dockRect = tester.getRect(
                find.byKey(const Key('editor-bottom-dock')),
              );
              final summaryRect = tester.getRect(
                find.byKey(const Key('editor-summary-amount-row')),
              );
              final amountRect = tester.getRect(
                find.byKey(const Key('amount')),
              );
              final remarkRect = tester.getRect(remarkRowFinder);
              final pillRect = tester.getRect(
                find.byKey(const Key('editor-pill-toolbar')),
              );
              final slotRect = tester.getRect(
                find.byKey(const Key('editor-bottom-panel-slot')),
              );
              final keypadRect = tester.getRect(
                find.byType(RecordCustomKeypad),
              );
              final actionBarRect = tester.getRect(
                find.byKey(const Key('desktop-editor-action-bar')),
              );

              expect(
                zone2Rect.height,
                greaterThanOrEqualTo(120.0),
                reason:
                    '[$scene] Category grid height (${zone2Rect.height}) with expanded keypad & wrapped pills must be >= 120px',
              );

              for (final (rect, label) in <(Rect, String)>[
                (summaryRect, 'editor-summary-amount-row'),
                (amountRect, 'amount'),
                (remarkRect, 'editor-remark-row'),
                (pillRect, 'editor-pill-toolbar'),
                (keypadRect, 'RecordCustomKeypad'),
                (actionBarRect, 'desktop-editor-action-bar'),
              ]) {
                expect(
                  rect.left,
                  greaterThanOrEqualTo(dialogSurfaceRect.left - 0.5),
                  reason: '[$scene] $label.left outside dialog surface',
                );
                expect(
                  rect.right,
                  lessThanOrEqualTo(dialogSurfaceRect.right + 0.5),
                  reason: '[$scene] $label.right outside dialog surface',
                );
                expect(
                  rect.top,
                  greaterThanOrEqualTo(dialogSurfaceRect.top - 0.5),
                  reason: '[$scene] $label.top outside dialog surface',
                );
                expect(
                  rect.bottom,
                  lessThanOrEqualTo(dialogSurfaceRect.bottom + 0.5),
                  reason: '[$scene] $label.bottom outside dialog surface',
                );
              }

              expect(
                summaryRect.top,
                greaterThanOrEqualTo(dockRect.top - 0.5),
                reason:
                    '[$scene] editor-summary-amount-row must not be scrolled/clipped above bottom dock',
              );
              expect(
                keypadRect.height,
                lessThanOrEqualTo(slotRect.height + 0.5),
                reason:
                    '[$scene] RecordCustomKeypad must fit inside editor-bottom-panel-slot without cropping',
              );
              expect(
                zone2Rect.bottom,
                lessThanOrEqualTo(summaryRect.top + 0.5),
              );
              expect(
                summaryRect.bottom,
                lessThanOrEqualTo(remarkRect.top + 0.5),
              );
              expect(remarkRect.bottom, lessThanOrEqualTo(pillRect.top + 0.5));
              expect(pillRect.bottom, lessThanOrEqualTo(keypadRect.top + 0.5));
              expect(
                keypadRect.bottom,
                lessThanOrEqualTo(actionBarRect.top + 0.5),
              );
              expect(
                find
                    .byKey(const Key('editor-summary-amount-row'))
                    .hitTestable(),
                findsOneWidget,
                reason:
                    '[$scene] editor-summary-amount-row must be unoccluded and hit-testable',
              );
              expect(
                find.byKey(const Key('amount')).hitTestable(),
                findsOneWidget,
                reason: '[$scene] amount must be unoccluded and hit-testable',
              );

              _probeCurrentTree(
                tester,
                scene: '$scene+KeypadExpanded',
                viewport: modalSize,
                violations: violations,
              );
            }
          }
        }
      }

      // -----------------------------------------------------------------------
      // Part 4: Routed TallyIsleApp CategoryStatsPage -> Drilldown -> RecordDetail
      // -----------------------------------------------------------------------
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      await tester.pumpWidget(
        ProviderScope(
          key: ValueKey<String>('routed-cat-drill-${platform.name}'),
          retry: (_, _) => null,
          overrides: providerOverrides,
          child: const TallyIsleApp(),
        ),
      );
      await _settleProbe(tester, violations, '${platform.name}:RoutedStatsHub');
      await tester.tap(find.byKey(const Key('nav-slot-stats')));
      await _settleProbe(tester, violations, '${platform.name}:RoutedStatsTab');
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('stats-category-overview-card')),
          matching: find.text('查看完整分析'),
        ),
      );
      await _settleProbe(
        tester,
        violations,
        '${platform.name}:RoutedCategoryStats',
      );
      await tester.tap(find.byKey(Key('category-row-${ids.foodCatId}')));
      await _settleProbe(
        tester,
        violations,
        '${platform.name}:RoutedCategoryDrilldown',
      );
      final routedBillTile = find.byKey(
        Key('drilldown-bill-${ids.expRecordId}'),
      );
      expect(routedBillTile, findsOneWidget);
      await tester.tap(routedBillTile);
      await _settleProbe(
        tester,
        violations,
        '${platform.name}:RoutedCategoryRecordDetail',
      );
      // Hard assertion 3b (routed): RecordDetailPage opens visibly on top!
      expect(
        find.byKey(const Key('detail-amount')).hitTestable(),
        findsOneWidget,
      );
      _probeCurrentTree(
        tester,
        scene: '${platform.name}:RoutedCategoryRecordDetail',
        viewport: const Size(1280, 800),
        violations: violations,
      );

      // Drain widget tree before final assertion so Drift stream teardown
      // timers settle cleanly.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(Duration.zero);

      if (violations.isNotEmpty) {
        final deduped = violations.toSet().toList();
        debugPrint(
          '=== DESKTOP GEOMETRY PROBE (${platform.name}): '
          '${deduped.length} UNIQUE VIOLATIONS ===',
        );
        for (final v in deduped) {
          debugPrint('VIOLATION: $v');
        }
      }

      expect(
        violations,
        isEmpty,
        reason:
            'Desktop geometry probe detected ${violations.length} violation(s) on ${platform.name}',
      );
    },
  );
}
