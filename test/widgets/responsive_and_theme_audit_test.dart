import 'dart:io';
import 'dart:math' as math;

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/budget/budget_service.dart';
import 'package:tallyisle/data/catalog/catalog_service.dart';
import 'package:tallyisle/data/catalog/currency_service.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/debt/debt_service.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/data/periodic/periodic_service.dart';
import 'package:tallyisle/data/tools/bank_card_service.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/app_settings_rules.dart';
import 'package:tallyisle/domain/rules/billing_period.dart';
import 'package:tallyisle/domain/rules/budget_rules.dart';
import 'package:tallyisle/domain/rules/periodic_records.dart';
import 'package:tallyisle/domain/rules/template_card_rules.dart';
import 'package:tallyisle/features/automation/automation_providers.dart';
import 'package:tallyisle/features/automation/desktop_widgets_page.dart';
import 'package:tallyisle/features/automation/mcp_settings_page.dart';
import 'package:tallyisle/features/backup/backup_page.dart';
import 'package:tallyisle/features/backup/backup_providers.dart';
import 'package:tallyisle/features/bank_cards/bank_cards_page.dart';
import 'package:tallyisle/features/budget/budget_page.dart';
import 'package:tallyisle/features/calendar/calendar_page.dart';
import 'package:tallyisle/features/csv_transfer/csv_export_page.dart';
import 'package:tallyisle/features/currencies/currencies_page.dart';
import 'package:tallyisle/features/debt/debt_page.dart';
import 'package:tallyisle/features/periodic/periodic_page.dart';
import 'package:tallyisle/features/reminder/reminder_providers.dart';
import 'package:tallyisle/features/settings/about_help_page.dart';
import 'package:tallyisle/features/settings/settings_page.dart';
import 'package:tallyisle/features/stats/stats_page.dart';
import 'package:tallyisle/features/tags/tags_page.dart';
import 'package:tallyisle/platform/app_widgets.dart';
import 'package:tallyisle/platform/auto_bill_bridge.dart';
import 'package:tallyisle/platform/notifications.dart';

const List<Size> _auditViewports = <Size>[
  Size(360, 640), // narrow phone
  Size(390, 844), // standard phone
  Size(960, 800), // widescreen
];

const List<Brightness> _auditBrightnesses = <Brightness>[
  Brightness.light,
  Brightness.dark,
];

const TextScaler _auditTextScaler = TextScaler.linear(1.2);

ThemeData _buildAuditTheme(Brightness brightness) {
  final seedColor = Color(AppSettings.defaults.themeSeedArgb32);
  const segmentedButtonTheme = SegmentedButtonThemeData(
    style: ButtonStyle(
      visualDensity: VisualDensity.compact,
      padding: WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 10, vertical: 0),
      ),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
  );
  return ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: brightness,
    ),
    segmentedButtonTheme: segmentedButtonTheme,
    useMaterial3: true,
  );
}

double _wcagContrastRatio(Color fg, Color bg) {
  final l1 = fg.computeLuminance();
  final l2 = bg.computeLuminance();
  final lighter = math.max(l1, l2);
  final darker = math.min(l1, l2);
  return (lighter + 0.05) / (darker + 0.05);
}

final class _AuditHarness {
  _AuditHarness({
    required this.db,
    required this.tempRoot,
    required this.localBackupDir,
    required this.attachmentsDir,
    required this.scheduler,
    required this.autoBridge,
    required this.widgetBridge,
  });

  final AppDatabase db;
  final Directory tempRoot;
  final Directory localBackupDir;
  final Directory attachmentsDir;
  final InMemoryReminderScheduler scheduler;
  final InMemoryAutoBillBridge autoBridge;
  final InMemoryAppWidgetBridge widgetBridge;

  static Future<_AuditHarness> create(WidgetTester tester) async {
    late AppDatabase db;
    late Directory tempRoot;
    late Directory localBackupDir;
    late Directory attachmentsDir;

    await tester.runAsync(() async {
      db = AppDatabase(NativeDatabase.memory());
      tempRoot = await Directory.systemTemp.createTemp('tally_resp_audit_');
      localBackupDir = Directory(p.join(tempRoot.path, 'backups'));
      attachmentsDir = Directory(p.join(tempRoot.path, 'attachments'));
      await localBackupDir.create(recursive: true);
      await attachmentsDir.create(recursive: true);

      final ledger = LedgerService(db);
      final catalog = CatalogService(db);
      final currency = CurrencyService(db);
      final budget = BudgetService(db);
      final periodic = PeriodicService(db);

      final categories = await db.select(db.recordCategories).get();
      final foodCat = categories.firstWhere((c) => c.name == '餐饮');
      final shoppingCat = categories.firstWhere((c) => c.name == '购物');
      final salaryCat = categories.firstWhere((c) => c.name == '工资');

      final bankAssetId = await ledger.createAsset(
        commandId: 'audit-asset-bank',
        name: '招商储蓄卡',
        initial: Money.parse('12800.00'),
      );
      await ledger.createAsset(
        commandId: 'audit-asset-credit',
        name: '招商信用卡',
        type: AssetType.credit,
        initial: Money.parse('-680.50'),
        limit: Money.parse('30000.00'),
        creditInfo: '{"billDay":10,"repaymentDay":25,"repaymentType":0}',
      );

      await currency.saveCurrency(
        commandId: 'audit-cur-usd',
        code: 'USD',
        name: '美元',
        symbol: r'$',
        price: '7.2350',
      );
      await currency.saveCurrency(
        commandId: 'audit-cur-jpy',
        code: 'JPY',
        name: '日元',
        symbol: '¥',
        price: '0.0485',
      );

      final groupTagId = await catalog.createTag(
        commandId: 'audit-tag-group',
        name: '2026差旅项目',
        isGroup: true,
        color: '#1E88E5',
      );
      final childTagId = await catalog.createTag(
        commandId: 'audit-tag-child',
        name: '高铁机票',
        parentTagId: groupTagId,
        color: '#E53935',
      );
      final soloTagId = await catalog.createTag(
        commandId: 'audit-tag-solo',
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

      await ledger.saveRecord(
        commandId: 'audit-rec-exp-1',
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
      await ledger.saveRecord(
        commandId: 'audit-rec-exp-2',
        draft: RecordDraft(
          type: RecordType.expense,
          money: Money.parse('420.00'),
          bookId: 1,
          recordTime: todayNoonMs - 3600000,
          categoryId: shoppingCat.id,
          assetId: bankAssetId,
          remark: '差旅交通票据',
          tagIds: <String>[childTagId],
        ),
      );
      await ledger.saveRecord(
        commandId: 'audit-rec-inc-1',
        draft: RecordDraft(
          type: RecordType.income,
          money: Money.parse('15600.00'),
          bookId: 1,
          recordTime: todayNoonMs - 7200000,
          categoryId: salaryCat.id,
          assetId: bankAssetId,
          remark: '本月薪资入账',
        ),
      );

      final period = BillingPeriod.containing(now, 1);
      final section = BudgetMode.monthly.sectionFor(period);
      await budget.upsertTotalBudget(
        commandId: 'audit-budget-total',
        bookId: 1,
        section: section,
        amountMinor: BigInt.from(500000),
        autoCopy: true,
        forward: true,
      );
      await budget.upsertCategoryBudget(
        commandId: 'audit-budget-food',
        bookId: 1,
        section: section,
        categoryId: foodCat.id,
        budgetType: BudgetTypeCode.expenseCategory,
        amountMinor: BigInt.from(150000),
      );
      await budget.upsertCategoryBudget(
        commandId: 'audit-budget-saving',
        bookId: 1,
        section: section,
        categoryId: salaryCat.id,
        budgetType: BudgetTypeCode.savingCategory,
        amountMinor: BigInt.from(800000),
      );

      await periodic.savePeriod(
        commandId: 'audit-periodic-1',
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

      final debtSvc = DebtService(db);
      final startMs = DateTime(now.year, now.month, 1).millisecondsSinceEpoch;
      await debtSvc.createDebt(
        commandId: 'audit-debt-lend-1',
        subType: AssetType.debtLend,
        name: '张三周转借款',
        principal: Money.parse('3000.00'),
        bookId: 1,
        startDate: startMs,
        remark: '短期周转',
      );
      await debtSvc.createDebt(
        commandId: 'audit-debt-borrow-1',
        subType: AssetType.debtBorrow,
        name: '父母装修拆借',
        principal: Money.parse('1500.00'),
        bookId: 1,
        startDate: startMs,
        countedInNetWorth: false,
      );

      final bankCardSvc = BankCardService(db);
      await bankCardSvc.saveBankCard(
        commandId: 'audit-card-debit-1',
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
      await bankCardSvc.saveBankCard(
        commandId: 'audit-card-credit-1',
        draft: const BankCardDraft(
          cardType: BankCardType.credit,
          cardName: '招商经典白金卡',
          cardNo: '4111111111111111',
          cardOwner: '王小明',
          remark: '日常消费主卡',
          cardColor: '#1E88E5',
        ),
      );
    });

    return _AuditHarness(
      db: db,
      tempRoot: tempRoot,
      localBackupDir: localBackupDir,
      attachmentsDir: attachmentsDir,
      scheduler: InMemoryReminderScheduler(),
      autoBridge: InMemoryAutoBillBridge(),
      widgetBridge: InMemoryAppWidgetBridge(),
    );
  }

  Future<void> dispose(WidgetTester tester) async {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    await tester.pumpWidget(const SizedBox.shrink());
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 40));
    }
    await scheduler.dispose();
    await autoBridge.dispose();
    await widgetBridge.dispose();
    await tester.runAsync(() async {
      await db.close();
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });
    await tester.pump(const Duration(seconds: 1));
  }
}

Future<void> _settleClean(WidgetTester tester, {required String ctx}) async {
  await tester.pump();
  expect(tester.takeException(), isNull, reason: 'Initial pump error ($ctx)');
  for (var i = 0; i < 14; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      tester.takeException(),
      isNull,
      reason: 'Async settle pump #$i error ($ctx)',
    );
  }
}

int _auditSegmentedButtons(WidgetTester tester, {required String ctx}) {
  final segWidgets = tester
      .widgetList(find.byWidgetPredicate((w) => w is SegmentedButton))
      .cast<SegmentedButton<dynamic>>()
      .toList();

  for (final seg in segWidgets) {
    expect(
      seg.showSelectedIcon,
      isFalse,
      reason:
          'SegmentedButton (${seg.key}) must set showSelectedIcon: false ($ctx)',
    );
    final segFinder = find.byWidget(seg);
    final textElements = find
        .descendant(of: segFinder, matching: find.byType(Text))
        .evaluate()
        .toList();
    expect(
      textElements,
      isNotEmpty,
      reason:
          'SegmentedButton (${seg.key}) should contain segment labels ($ctx)',
    );
    for (final textEl in textElements) {
      final textWidget = textEl.widget as Text;
      final richFinder = find.descendant(
        of: find.byElementPredicate((el) => identical(el, textEl)),
        matching: find.byType(RichText),
      );
      expect(richFinder, findsOneWidget);
      final paragraph = tester.renderObject<RenderParagraph>(richFinder.first);
      expect(
        paragraph.size.height,
        lessThan(34),
        reason:
            'ButtonSegment Text "${textWidget.data}" on ${seg.key} must stay single-line (<34px) at 1.2x text scale ($ctx), got ${paragraph.size.height}',
      );
    }
  }
  return segWidgets.length;
}

Future<void> _runPageAuditMatrix(
  WidgetTester tester, {
  required String pageName,
  required _AuditHarness harness,
  required Widget Function() pageBuilder,
  int expectedMinSegmentedButtons = 0,
  Future<void> Function(
    WidgetTester tester,
    Size viewport,
    Brightness brightness,
    ThemeData theme,
    String ctx,
  )?
  onViewportReady,
  void Function(
    WidgetTester tester,
    Size viewport,
    Brightness brightness,
    ThemeData theme,
    String ctx,
  )?
  onScrollStep,
}) async {
  for (final viewport in _auditViewports) {
    for (final brightness in _auditBrightnesses) {
      final ctx =
          '$pageName @ ${viewport.width.toInt()}x${viewport.height.toInt()} ${brightness.name} 1.2x';
      tester.view.physicalSize = viewport;
      tester.view.devicePixelRatio = 1.0;

      final theme = _buildAuditTheme(brightness);

      await tester.pumpWidget(
        ProviderScope(
          key: ValueKey<String>('scope-$ctx'),
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => harness.db),
            reminderSchedulerProvider.overrideWithValue(harness.scheduler),
            backupLocalDirectoryOverrideProvider.overrideWithValue(
              () async => harness.localBackupDir,
            ),
            backupAttachmentsDirectoryOverrideProvider.overrideWithValue(
              () async => harness.attachmentsDir,
            ),
            autoBillBridgeProvider.overrideWithValue(harness.autoBridge),
            appWidgetBridgeProvider.overrideWithValue(harness.widgetBridge),
          ],
          child: MaterialApp(
            key: ValueKey<String>('app-$ctx'),
            debugShowCheckedModeBanner: false,
            locale: const Locale('zh'),
            supportedLocales: const <Locale>[Locale('zh'), Locale('en')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            theme: theme,
            darkTheme: theme,
            themeMode: brightness == Brightness.dark
                ? ThemeMode.dark
                : ThemeMode.light,
            builder: (context, child) {
              final mq = MediaQuery.of(context);
              return MediaQuery(
                data: mq.copyWith(textScaler: _auditTextScaler),
                child: child ?? const SizedBox.shrink(),
              );
            },
            home: pageBuilder(),
          ),
        ),
      );

      await _settleClean(tester, ctx: ctx);

      var maxObservedSegmented = _auditSegmentedButtons(tester, ctx: ctx);

      if (onViewportReady != null) {
        await onViewportReady(tester, viewport, brightness, theme, ctx);
        expect(
          tester.takeException(),
          isNull,
          reason: 'Post-onViewportReady error ($ctx)',
        );
      }
      if (onScrollStep != null) {
        onScrollStep(tester, viewport, brightness, theme, ctx);
      }

      // Walk vertical scrollables so lazy offscreen cards/controls are also laid out & audited.
      final verticalScrollables = tester
          .stateList<ScrollableState>(find.byType(Scrollable))
          .where((s) => s.position.axisDirection == AxisDirection.down)
          .toList();

      for (final scrollable in verticalScrollables) {
        if (!scrollable.mounted) continue;
        final step = viewport.height * 0.6;
        var target = step;
        var guard = 0;
        while (scrollable.mounted &&
            scrollable.position.hasContentDimensions &&
            scrollable.position.pixels < scrollable.position.maxScrollExtent &&
            guard < 12) {
          final next = math.min(target, scrollable.position.maxScrollExtent);
          scrollable.position.jumpTo(next);
          await tester.pump(const Duration(milliseconds: 50));
          expect(
            tester.takeException(),
            isNull,
            reason: 'Overflow/exception while scrolling to $next ($ctx)',
          );
          final seen = _auditSegmentedButtons(
            tester,
            ctx: '$ctx [scroll=${next.toStringAsFixed(0)}]',
          );
          if (seen > maxObservedSegmented) {
            maxObservedSegmented = seen;
          }
          if (onScrollStep != null) {
            onScrollStep(
              tester,
              viewport,
              brightness,
              theme,
              '$ctx [scroll=${next.toStringAsFixed(0)}]',
            );
          }
          target += step;
          guard++;
        }
        if (scrollable.mounted && scrollable.position.hasContentDimensions) {
          scrollable.position.jumpTo(0);
          await tester.pump();
          expect(tester.takeException(), isNull, reason: 'Jump-to-top ($ctx)');
        }
      }

      if (expectedMinSegmentedButtons > 0) {
        expect(
          maxObservedSegmented,
          greaterThanOrEqualTo(expectedMinSegmentedButtons),
          reason:
              'Expected at least $expectedMinSegmentedButtons SegmentedButton(s) on $ctx',
        );
      }
    }
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets(
    'SettingsPage: zero overflow & single-line SegmentedButtons across 360x640, 390x844, 960x800 in Light & Dark @ 1.2x',
    (tester) async {
      final harness = await _AuditHarness.create(tester);
      try {
        await _runPageAuditMatrix(
          tester,
          pageName: 'SettingsPage',
          harness: harness,
          pageBuilder: () => const SettingsPage(),
          expectedMinSegmentedButtons: 1,
        );
      } finally {
        await harness.dispose(tester);
      }
    },
  );

  testWidgets(
    'BackupPage: renders "S3 存储", zero overflow & single-line SegmentedButton across 360x640, 390x844, 960x800 in Light & Dark @ 1.2x',
    (tester) async {
      final harness = await _AuditHarness.create(tester);
      try {
        await _runPageAuditMatrix(
          tester,
          pageName: 'BackupPage',
          harness: harness,
          pageBuilder: () => const BackupPage(),
          expectedMinSegmentedButtons: 1,
          onViewportReady: (tester, viewport, brightness, theme, ctx) async {
            expect(
              find.text('S3 存储'),
              findsOneWidget,
              reason: '"S3 存储" must be rendered on BackupPage ($ctx)',
            );
          },
        );
      } finally {
        await harness.dispose(tester);
      }
    },
  );

  testWidgets(
    'CsvExportPage: zero overflow (including date-filter row) & single-line SegmentedButton across 360x640, 390x844, 960x800 in Light & Dark @ 1.2x',
    (tester) async {
      final harness = await _AuditHarness.create(tester);
      try {
        await _runPageAuditMatrix(
          tester,
          pageName: 'CsvExportPage',
          harness: harness,
          pageBuilder: () => CsvExportPage(
            saveFile: (_, _) async {},
            shareFile: (_, _) async {},
          ),
          expectedMinSegmentedButtons: 1,
          onViewportReady: (tester, viewport, brightness, theme, ctx) async {
            final dateSwitch = find.byKey(
              const Key('export_date_filter_switch'),
            );
            expect(dateSwitch, findsOneWidget);
            await tester.tap(dateSwitch);
            await tester.pump();
            expect(
              tester.takeException(),
              isNull,
              reason: 'CsvExportPage date-range row overflow ($ctx)',
            );
            expect(
              find.byKey(const Key('export_start_date_button')),
              findsOneWidget,
            );
            expect(
              find.byKey(const Key('export_end_date_button')),
              findsOneWidget,
            );
          },
        );
      } finally {
        await harness.dispose(tester);
      }
    },
  );

  testWidgets(
    'PeriodicPage: zero overflow & single-line SegmentedButton tabs across 360x640, 390x844, 960x800 in Light & Dark @ 1.2x',
    (tester) async {
      final harness = await _AuditHarness.create(tester);
      try {
        await _runPageAuditMatrix(
          tester,
          pageName: 'PeriodicPage',
          harness: harness,
          pageBuilder: () => const PeriodicPage(),
          expectedMinSegmentedButtons: 1,
          onViewportReady: (tester, viewport, brightness, theme, ctx) async {
            expect(find.byKey(const Key('periodic_tab_0')), findsOneWidget);
            expect(find.byKey(const Key('periodic_tab_1')), findsOneWidget);
            expect(find.byKey(const Key('periodic_tab_2')), findsOneWidget);
          },
        );
      } finally {
        await harness.dispose(tester);
      }
    },
  );

  testWidgets(
    'DesktopWidgetsPage: zero overflow & full-width "添加到桌面" buttons across 360x640, 390x844, 960x800 in Light & Dark @ 1.2x',
    (tester) async {
      final harness = await _AuditHarness.create(tester);
      try {
        final seenPinKeys = <String>{};
        await _runPageAuditMatrix(
          tester,
          pageName: 'DesktopWidgetsPage',
          harness: harness,
          pageBuilder: () => const DesktopWidgetsPage(),
          onViewportReady: (tester, viewport, brightness, theme, ctx) async {
            seenPinKeys.clear();
          },
          onScrollStep: (tester, viewport, brightness, theme, ctx) {
            for (final kind in DesktopWidgetKind.values) {
              final sectionFinder = find.byKey(
                Key('widget_section_${kind.wireKey}'),
              );
              final pinFinder = find.byKey(Key('widget_pin_${kind.wireKey}'));
              if (sectionFinder.evaluate().isEmpty ||
                  pinFinder.evaluate().isEmpty) {
                continue;
              }
              seenPinKeys.add(kind.wireKey);
              final cardRect = tester.getRect(sectionFinder);
              final pinRect = tester.getRect(pinFinder);
              // M3 Card has default 4dp margin per side + 16dp inner Padding = 20dp per side (40dp total).
              final expectedContentWidth = cardRect.width - 40.0;
              expect(
                (pinRect.width - expectedContentWidth).abs(),
                lessThanOrEqualTo(2.0),
                reason:
                    '"添加到桌面" button (${kind.wireKey}) must span full card content width ($expectedContentWidth), got ${pinRect.width} ($ctx)',
              );
              final leftInset = pinRect.left - cardRect.left;
              final rightInset = cardRect.right - pinRect.right;
              expect(
                (leftInset - rightInset).abs(),
                lessThanOrEqualTo(1.5),
                reason:
                    '"添加到桌面" button (${kind.wireKey}) must not dangle right-aligned (left=$leftInset, right=$rightInset) ($ctx)',
              );
            }
            if (!ctx.contains('[scroll=')) {
              expect(
                find.text('添加到桌面'),
                findsAtLeastNWidgets(1),
                reason: 'At least one "添加到桌面" button must be visible ($ctx)',
              );
            }
          },
        );
        expect(
          seenPinKeys,
          containsAll(<String>[
            for (final kind in DesktopWidgetKind.values) kind.wireKey,
          ]),
        );
      } finally {
        await harness.dispose(tester);
      }
    },
  );

  testWidgets(
    'TagsPage: zero overflow & "标签组" badge uses secondaryContainer/onSecondaryContainer with contrast > 4.5 across Light & Dark @ 1.2x',
    (tester) async {
      final harness = await _AuditHarness.create(tester);
      try {
        await _runPageAuditMatrix(
          tester,
          pageName: 'TagsPage',
          harness: harness,
          pageBuilder: () => const TagsPage(),
          onViewportReady: (tester, viewport, brightness, theme, ctx) async {
            final badgeTextFinder = find.text('标签组');
            expect(
              badgeTextFinder,
              findsAtLeastNWidgets(1),
              reason: '"标签组" badge must be rendered on TagsPage ($ctx)',
            );

            final badgeText = tester.widget<Text>(badgeTextFinder.first);
            final containerFinder = find.ancestor(
              of: badgeTextFinder.first,
              matching: find.byWidgetPredicate(
                (w) => w is Container && w.decoration is BoxDecoration,
              ),
            );
            expect(containerFinder, findsAtLeastNWidgets(1));
            final badgeContainer = tester.widget<Container>(
              containerFinder.first,
            );
            final boxDecoration = badgeContainer.decoration! as BoxDecoration;

            final scheme = theme.colorScheme;
            expect(
              boxDecoration.color,
              equals(scheme.secondaryContainer),
              reason:
                  '"标签组" badge background must use colorScheme.secondaryContainer ($ctx)',
            );
            expect(
              badgeText.style?.color,
              equals(scheme.onSecondaryContainer),
              reason:
                  '"标签组" badge text must use colorScheme.onSecondaryContainer ($ctx)',
            );

            final contrast = _wcagContrastRatio(
              badgeText.style!.color!,
              boxDecoration.color!,
            );
            expect(
              contrast,
              greaterThan(4.5),
              reason:
                  '"标签组" badge contrast ratio ($contrast) must exceed 4.5:1 ($ctx)',
            );
          },
        );
      } finally {
        await harness.dispose(tester);
      }
    },
  );

  testWidgets(
    'StatsPage: zero overflow across 360x640, 390x844, 960x800 in Light & Dark @ 1.2x',
    (tester) async {
      final harness = await _AuditHarness.create(tester);
      try {
        await _runPageAuditMatrix(
          tester,
          pageName: 'StatsPage',
          harness: harness,
          pageBuilder: () => const StatsPage(),
        );
      } finally {
        await harness.dispose(tester);
      }
    },
  );

  testWidgets(
    'BudgetPage: zero overflow & single-line SegmentedButton across 360x640, 390x844, 960x800 in Light & Dark @ 1.2x',
    (tester) async {
      final harness = await _AuditHarness.create(tester);
      try {
        await _runPageAuditMatrix(
          tester,
          pageName: 'BudgetPage',
          harness: harness,
          pageBuilder: () => const BudgetPage(),
          expectedMinSegmentedButtons: 1,
        );
      } finally {
        await harness.dispose(tester);
      }
    },
  );

  testWidgets(
    'CalendarPage: zero overflow across 360x640, 390x844, 960x800 in Light & Dark @ 1.2x',
    (tester) async {
      final harness = await _AuditHarness.create(tester);
      try {
        await _runPageAuditMatrix(
          tester,
          pageName: 'CalendarPage',
          harness: harness,
          pageBuilder: () => const CalendarPage(),
        );
      } finally {
        await harness.dispose(tester);
      }
    },
  );

  testWidgets(
    'CurrenciesPage: zero overflow across 360x640, 390x844, 960x800 in Light & Dark @ 1.2x',
    (tester) async {
      final harness = await _AuditHarness.create(tester);
      try {
        await _runPageAuditMatrix(
          tester,
          pageName: 'CurrenciesPage',
          harness: harness,
          pageBuilder: () => const CurrenciesPage(),
        );
      } finally {
        await harness.dispose(tester);
      }
    },
  );

  testWidgets(
    'DebtPage: zero overflow, single-line SegmentedButton (<34px, showSelectedIcon: false) & "新建借贷" FAB across 360x640, 390x844, 960x800 in Light & Dark @ 1.2x',
    (tester) async {
      final harness = await _AuditHarness.create(tester);
      try {
        await _runPageAuditMatrix(
          tester,
          pageName: 'DebtPage',
          harness: harness,
          pageBuilder: () => const DebtPage(),
          expectedMinSegmentedButtons: 1,
          onViewportReady: (tester, viewport, brightness, theme, ctx) async {
            expect(
              find.byKey(const Key('debt_state_tabs')),
              findsOneWidget,
              reason: 'DebtPage SegmentedButton must be rendered ($ctx)',
            );
            expect(find.byKey(const Key('debt_tab_active')), findsOneWidget);
            expect(find.byKey(const Key('debt_tab_settled')), findsOneWidget);
            expect(
              find.byType(ChoiceChip),
              findsNothing,
              reason: 'DebtPage must not render legacy ChoiceChip ($ctx)',
            );
            expect(
              find.byKey(const Key('add_debt_button')),
              findsOneWidget,
              reason: '"新建借贷" FAB key must exist on DebtPage ($ctx)',
            );
            expect(
              find.widgetWithText(FloatingActionButton, '新建借贷'),
              findsOneWidget,
              reason: '"新建借贷" FAB must be rendered on DebtPage ($ctx)',
            );
          },
        );
      } finally {
        await harness.dispose(tester);
      }
    },
  );

  testWidgets(
    'BankCardsPage: zero overflow & single-line SegmentedButton (<34px, showSelectedIcon: false) across 360x640, 390x844, 960x800 in Light & Dark @ 1.2x',
    (tester) async {
      final harness = await _AuditHarness.create(tester);
      try {
        await _runPageAuditMatrix(
          tester,
          pageName: 'BankCardsPage',
          harness: harness,
          pageBuilder: () => const BankCardsPage(),
          expectedMinSegmentedButtons: 1,
          onViewportReady: (tester, viewport, brightness, theme, ctx) async {
            expect(
              find.byKey(const Key('bank_card_filter_tabs')),
              findsOneWidget,
              reason: 'BankCardsPage SegmentedButton must be rendered ($ctx)',
            );
            expect(find.byKey(const Key('card_filter_all')), findsOneWidget);
            expect(find.byKey(const Key('card_filter_0')), findsOneWidget);
            expect(find.byKey(const Key('card_filter_1')), findsOneWidget);
            expect(
              find.byType(ChoiceChip),
              findsNothing,
              reason: 'BankCardsPage must not render legacy ChoiceChip ($ctx)',
            );
          },
        );
      } finally {
        await harness.dispose(tester);
      }
    },
  );

  testWidgets(
    'AboutHelpPage: zero overflow & renders GitHub repo + feedback links across 360x640, 390x844, 960x800 in Light & Dark @ 1.2x',
    (tester) async {
      final harness = await _AuditHarness.create(tester);
      try {
        await _runPageAuditMatrix(
          tester,
          pageName: 'AboutHelpPage',
          harness: harness,
          pageBuilder: () => const AboutHelpPage(),
          onViewportReady: (tester, viewport, brightness, theme, ctx) async {
            expect(
              find.text('https://github.com/tallyisle/tallyisle'),
              findsOneWidget,
              reason:
                  'GitHub repo URL must be rendered on AboutHelpPage ($ctx)',
            );
            expect(
              find.text('问题反馈与建议'),
              findsOneWidget,
              reason:
                  '"问题反馈与建议" entry must be rendered on AboutHelpPage ($ctx)',
            );
            expect(
              find.byKey(const Key('about_github_repo_tile')),
              findsOneWidget,
            );
            expect(
              find.byKey(const Key('about_github_issues_tile')),
              findsOneWidget,
            );
            expect(
              find.byKey(const Key('about_licenses_tile')),
              findsOneWidget,
            );
          },
        );
      } finally {
        await harness.dispose(tester);
      }
    },
  );

  testWidgets(
    'McpSettingsPage: zero overflow & single-line SegmentedButton across 360x640, 390x844, 960x800 in Light & Dark @ 1.2x',
    (tester) async {
      final harness = await _AuditHarness.create(tester);
      try {
        await _runPageAuditMatrix(
          tester,
          pageName: 'McpSettingsPage',
          harness: harness,
          pageBuilder: () => const McpSettingsPage(),
          expectedMinSegmentedButtons: 1,
          onViewportReady: (tester, viewport, brightness, theme, ctx) async {
            expect(
              find.byKey(const Key('mcp_permission_tier_segmented')),
              findsOneWidget,
              reason:
                  'McpSettingsPage permission tier SegmentedButton must be rendered ($ctx)',
            );
            expect(
              find.byKey(const Key('mcp_enable_switch')),
              findsOneWidget,
              reason: 'McpSettingsPage enable switch must be rendered ($ctx)',
            );
          },
        );
      } finally {
        await harness.dispose(tester);
      }
    },
  );
}
