import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:tallyisle/app/app.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/catalog/catalog_service.dart';
import 'package:tallyisle/data/catalog/currency_service.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/db/seed.dart' show defaultBookId;
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/data/repo/ledger_queries.dart';
import 'package:tallyisle/data/settings/app_settings_service.dart';
import 'package:tallyisle/data/tools/bill_attachment_service.dart';
import 'package:tallyisle/data/tools/template_remark_service.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/app_settings_rules.dart';
import 'package:tallyisle/features/backup/backup_providers.dart';
import 'package:tallyisle/features/common/desktop_modal_page.dart';
import 'package:tallyisle/features/records/desktop_record_editor_dialog.dart';
import 'package:tallyisle/features/records/record_datetime_dialog.dart';
import 'package:tallyisle/features/records/record_detail_page.dart';
import 'package:tallyisle/features/records/record_editor_page.dart';
import 'package:tallyisle/features/records/record_keypad.dart';
import 'package:tallyisle/features/reminder/reminder_providers.dart';
import 'package:tallyisle/platform/notifications.dart';

Future<T> _runDb<T>(WidgetTester tester, Future<T> Function() fn) async {
  Object? caught;
  StackTrace? stack;
  T? value;
  await tester.runAsync(() async {
    try {
      value = await fn();
    } catch (e, s) {
      caught = e;
      stack = s;
    }
  });
  if (caught != null) {
    Error.throwWithStackTrace(caught!, stack!);
  }
  return value as T;
}

Future<void> _settle(WidgetTester tester, [int ticks = 10]) async {
  await tester.pump();
  for (var i = 0; i < ticks; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<
  (AppDatabase, Directory, InMemoryReminderScheduler, Future<void> Function())
>
_openAppHarness(WidgetTester tester) async {
  late AppDatabase db;
  late Directory tempRoot;
  final scheduler = InMemoryReminderScheduler();
  await tester.runAsync(() async {
    db = AppDatabase(NativeDatabase.memory());
    tempRoot = await Directory.systemTemp.createTemp('rec_audit_swipe_');
  });

  var closed = false;
  Future<void> cleanUp() async {
    if (closed) return;
    closed = true;
    await tester.pumpWidget(const SizedBox.shrink());
    await _settle(tester, 4);
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(scheduler.dispose);
    await tester.runAsync(db.close);
    await tester.runAsync(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });
  }

  addTearDown(() async {
    if (closed) return;
    closed = true;
    await tester.pumpWidget(const SizedBox.shrink());
    await _settle(tester, 6);
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() async {
      await scheduler.dispose();
      await db.close();
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });
  });
  return (db, tempRoot, scheduler, cleanUp);
}

String _topLocation(GoRouter router) {
  final config = router.routerDelegate.currentConfiguration;
  return config.isNotEmpty ? config.last.matchedLocation : config.uri.path;
}

Widget _wrapTallyIsleApp(
  AppDatabase db,
  Directory tempRoot,
  InMemoryReminderScheduler scheduler,
) {
  return ProviderScope(
    retry: (_, _) => null,
    overrides: [
      databaseProvider.overrideWith((ref) async => db),
      reminderSchedulerProvider.overrideWithValue(scheduler),
      backupLocalDirectoryOverrideProvider.overrideWithValue(
        () async => Directory(p.join(tempRoot.path, 'local')),
      ),
      backupAttachmentsDirectoryOverrideProvider.overrideWithValue(
        () async => Directory(p.join(tempRoot.path, 'att')),
      ),
    ],
    child: const TallyIsleApp(),
  );
}

bool _isTypeSelected(WidgetTester tester, int recordType) {
  return tester
      .widget<ChoiceChip>(find.byKey(Key('type-$recordType')))
      .selected;
}

Future<void> _tapKeypadDigits(WidgetTester tester, List<String> keys) async {
  for (final k in keys) {
    await tester.tap(find.byKey(Key('keypad-$k')));
    await tester.pump();
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('B-02: RecordDetailPage safe modal/route replacement & pop', () {
    testWidgets(
      'handles embeddedInPane callback, desktop imperative DialogRoute, mobile imperative MaterialPageRoute, and GoRouter Page single-match vs multi-match safely without wiping StatefulShellRoute',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final (db, tempRoot, scheduler, cleanUp) = await _openAppHarness(
          tester,
        );
        late String transferId;
        late String feeId;
        late String deletableTransferId;
        late String deletableFeeId;

        await tester.runAsync(() async {
          final ledger = LedgerService(db);
          final a1 = await ledger.createAsset(
            commandId: 'b02-a1',
            name: '转出储蓄卡',
            initial: Money.parse('5000.00'),
          );
          final a2 = await ledger.createAsset(
            commandId: 'b02-a2',
            name: '转入钱包',
            initial: Money.parse('1000.00'),
          );
          transferId = await ledger.saveRecord(
            commandId: 'b02-transfer-1',
            draft: RecordDraft(
              type: RecordType.transfer,
              money: Money.parse('200.00'),
              bookId: defaultBookId,
              recordTime: DateTime.now().millisecondsSinceEpoch,
              categoryId: noRef,
              assetId: noRef,
              fromAssetId: a1,
              toAssetId: a2,
              fee: Money.parse('2.50'),
            ),
          );
          feeId = (await LedgerQueries(db).feeChildOf(transferId))!.recordId;

          deletableTransferId = await ledger.saveRecord(
            commandId: 'b02-transfer-2',
            draft: RecordDraft(
              type: RecordType.transfer,
              money: Money.parse('88.00'),
              bookId: defaultBookId,
              recordTime: DateTime.now().millisecondsSinceEpoch,
              categoryId: noRef,
              assetId: noRef,
              fromAssetId: a1,
              toAssetId: a2,
              fee: Money.parse('1.00'),
            ),
          );
          deletableFeeId = (await LedgerQueries(
            db,
          ).feeChildOf(deletableTransferId))!.recordId;
        });

        // 1. Embedded pane mode: delegates feeParent & delete close to callbacks.
        String? selectedRelated;
        var closedPaneCount = 0;
        await tester.pumpWidget(
          ProviderScope(
            retry: (_, _) => null,
            overrides: [databaseProvider.overrideWith((ref) async => db)],
            child: MaterialApp(
              theme: ThemeData(
                platform: TargetPlatform.linux,
                useMaterial3: true,
              ),
              home: Scaffold(
                body: RecordDetailPage(
                  recordId: feeId,
                  embeddedInPane: true,
                  onSelectRelatedRecord: (id) => selectedRelated = id,
                  onClosePane: () => closedPaneCount++,
                ),
              ),
            ),
          ),
        );
        await _settle(tester);
        await tester.tap(find.byKey(const Key('view-fee-parent')));
        await tester.pump();
        expect(selectedRelated, transferId);
        expect(closedPaneCount, 0);

        // 2. Desktop imperative modal (`pushDesktopModalOrMaterialRoute` on top of GoRouter `/budget`):
        await tester.pumpWidget(
          ProviderScope(
            key: const ValueKey('b02-desktop-app'),
            retry: (_, _) => null,
            overrides: [
              databaseProvider.overrideWith((ref) async => db),
              reminderSchedulerProvider.overrideWithValue(scheduler),
              backupLocalDirectoryOverrideProvider.overrideWithValue(
                () async => Directory(p.join(tempRoot.path, 'local')),
              ),
              backupAttachmentsDirectoryOverrideProvider.overrideWithValue(
                () async => Directory(p.join(tempRoot.path, 'att')),
              ),
            ],
            child: Theme(
              data: ThemeData(
                platform: TargetPlatform.linux,
                useMaterial3: true,
              ),
              child: const TallyIsleApp(),
            ),
          ),
        );
        await _settle(tester);

        final shellCtx = tester.element(find.byType(Scaffold).first);
        final router = GoRouter.of(shellCtx);
        unawaited(router.push('/budget'));
        await _settle(tester);
        expect(_topLocation(router), '/budget');

        final budgetCtx = tester.element(find.text('预算管理').first);
        unawaited(
          pushDesktopModalOrMaterialRoute<void>(
            budgetCtx,
            maxWidth: 560,
            maxHeight: 740,
            barrierDismissible: true,
            child: RecordDetailPage(recordId: deletableFeeId),
          ),
        );
        await _settle(tester);
        expect(
          find.byKey(const Key('desktop-modal-dialog-surface')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('view-fee-parent')), findsOneWidget);

        // Click '这是转账手续费，查看所属转账' -> replaces imperative DialogRoute without touching GoRouter `/budget`!
        await tester.tap(find.byKey(const Key('view-fee-parent')));
        await _settle(tester);
        expect(tester.takeException(), isNull);
        expect(_topLocation(router), '/budget');
        expect(
          find.byKey(const Key('desktop-modal-dialog-surface')),
          findsOneWidget,
        );
        expect(find.text('88.00'), findsWidgets);
        expect(find.byKey(const Key('delete')), findsOneWidget);

        // Delete parent transfer inside imperative modal -> pops ONLY imperative DialogRoute, keeping `/budget`!
        await tester.tap(find.byKey(const Key('delete')));
        await _settle(tester, 4);
        await tester.tap(find.widgetWithText(FilledButton, '删除'));
        await _settle(tester);
        expect(
          find.byKey(const Key('desktop-modal-dialog-surface')),
          findsNothing,
        );
        expect(_topLocation(router), '/budget');

        // 3. GoRouter Page route:
        // (a) Single match (`router.go('/record/$feeId')` where matches.length == 1 && !canPop):
        //     uses `context.push` instead of `pushReplacement` so route stack stays valid!
        router.go('/record/$feeId');
        await _settle(tester);
        expect(router.routerDelegate.currentConfiguration.matches.length, 1);
        await tester.tap(find.byKey(const Key('view-fee-parent')));
        await _settle(tester);
        expect(tester.takeException(), isNull);
        expect(_topLocation(router), '/record/$transferId');
        expect(
          router.routerDelegate.currentConfiguration.matches.length,
          greaterThan(1),
        );

        // (b) Stacked match (`router.go('/')` then `router.push('/record/$feeId')`):
        //     replaces `/record/$feeId` with `/record/$transferId` while keeping `/` shell underneath!
        router.go('/');
        await _settle(tester);
        unawaited(router.push('/record/$feeId'));
        await _settle(tester);
        await tester.tap(find.byKey(const Key('view-fee-parent')));
        await _settle(tester);
        expect(tester.takeException(), isNull);
        expect(_topLocation(router), '/record/$transferId');
        router.pop();
        await _settle(tester);
        expect(_topLocation(router), '/');

        await cleanUp();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.linux),
    );

    testWidgets(
      'mobile imperative MaterialPageRoute replaces & pops on local Navigator without popping GoRouter route underneath',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final (db, tempRoot, scheduler, cleanUp) = await _openAppHarness(
          tester,
        );
        late String transferId;
        late String feeId;

        await tester.runAsync(() async {
          final ledger = LedgerService(db);
          final a1 = await ledger.createAsset(
            commandId: 'b02-mob-a1',
            name: '手机储蓄卡',
            initial: Money.parse('1000.00'),
          );
          final a2 = await ledger.createAsset(
            commandId: 'b02-mob-a2',
            name: '手机零钱',
            initial: Money.parse('200.00'),
          );
          transferId = await ledger.saveRecord(
            commandId: 'b02-mob-tr',
            draft: RecordDraft(
              type: RecordType.transfer,
              money: Money.parse('50.00'),
              bookId: defaultBookId,
              recordTime: DateTime.now().millisecondsSinceEpoch,
              categoryId: noRef,
              assetId: noRef,
              fromAssetId: a1,
              toAssetId: a2,
              fee: Money.parse('1.50'),
            ),
          );
          feeId = (await LedgerQueries(db).feeChildOf(transferId))!.recordId;
        });

        await tester.pumpWidget(_wrapTallyIsleApp(db, tempRoot, scheduler));
        await _settle(tester);

        final router = GoRouter.of(tester.element(find.byType(Scaffold).first));
        unawaited(router.push('/budget'));
        await _settle(tester);
        expect(_topLocation(router), '/budget');

        final budgetCtx = tester.element(find.text('预算管理').first);
        unawaited(
          pushDesktopModalOrMaterialRoute<void>(
            budgetCtx,
            child: RecordDetailPage(recordId: feeId),
          ),
        );
        await _settle(tester);
        expect(find.byKey(const Key('view-fee-parent')), findsOneWidget);

        await tester.tap(find.byKey(const Key('view-fee-parent')));
        await _settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('delete')), findsOneWidget);
        expect(_topLocation(router), '/budget');

        // Delete transfer -> pops imperative MaterialPageRoute, leaving GoRouter `/budget` intact!
        await tester.tap(find.byKey(const Key('delete')));
        await _settle(tester, 4);
        await tester.tap(find.widgetWithText(FilledButton, '删除'));
        await _settle(tester);
        expect(find.text('预算管理'), findsWidgets);
        expect(_topLocation(router), '/budget');

        await cleanUp();
      },
    );
  });

  group('B-03: Reconcile stale accounts & currency sync in create mode', () {
    testWidgets(
      'clears hidden/settled/deleted/unbound assetId, fromAssetId, and toAssetId immediately in create mode and on 再记 without UI/RecordDraft divergence',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final (db, tempRoot, scheduler, cleanUp) = await _openAppHarness(
          tester,
        );
        late int defaultWalletId;
        late int usdCardId;
        late int tempCashId;
        late int book2Id;

        await _runDb(tester, () async {
          final ledger = LedgerService(db);
          final catalog = CatalogService(db);
          await CurrencyService(db).saveCurrency(
            commandId: 'b03-usd',
            code: 'USD',
            name: '美元',
            symbol: r'$',
            price: '7.20',
          );
          book2Id = await catalog.createBook(
            commandId: 'b03-book2',
            name: '副账本',
          );
          defaultWalletId = await ledger.createAsset(
            commandId: 'b03-def-wallet',
            name: '默认人民币户',
            initial: Money.parse('2000.00'),
          );
          usdCardId = await ledger.createAsset(
            commandId: 'b03-usd-card',
            name: '外币美元卡',
            currency: 'USD',
            initial: Money.parse('500.00'),
          );
          tempCashId = await ledger.createAsset(
            commandId: 'b03-temp-cash',
            name: '待删备用金',
            initial: Money.zero(),
          );
          final attSvc = BillAttachmentService(db);
          final cfg = await attSvc.getDiyToolbarConfig();
          await attSvc.saveDiyToolbarConfig(
            commandId: 'b03-set-default',
            config: cfg.copyWithDefaultAccount(
              autoSelectDefaultAccount: true,
              defaultAccountId: defaultWalletId,
            ),
          );
        });

        final editorNotifier = ValueNotifier<Widget>(
          const RecordEditorPage(key: ValueKey('b03-editor-1')),
        );
        addTearDown(editorNotifier.dispose);

        await tester.pumpWidget(
          ProviderScope(
            retry: (_, _) => null,
            overrides: [databaseProvider.overrideWith((ref) async => db)],
            child: ValueListenableBuilder<Widget>(
              valueListenable: editorNotifier,
              builder: (_, child, _) => MaterialApp(home: child),
            ),
          ),
        );
        await _settle(tester);

        // Initially prefilled with defaultWalletId ('默认人民币户').
        expect(
          find.descendant(
            of: find.byKey(const Key('asset')),
            matching: find.text('默认人民币户'),
          ),
          findsOneWidget,
        );

        // User manually picks USD account ('外币美元卡') -> _userTouchedAsset = true, currency badge shows USD.
        await tester.tap(find.byKey(const Key('asset')));
        await _settle(tester, 4);
        await tester.tap(find.text('外币美元卡').last);
        await _settle(tester, 4);
        expect(
          find.descendant(
            of: find.byKey(const Key('asset')),
            matching: find.text('外币美元卡'),
          ),
          findsOneWidget,
        );
        expect(find.byKey(const Key('amount-currency-badge')), findsOneWidget);

        // Hide '外币美元卡' while editor is open -> because _userTouchedAsset == true,
        // assetId immediately clears to noRef ('不选账户') and currency syncs back to CNY ('¥')!
        await _runDb(
          tester,
          () => LedgerService(db).setAssetStatus(
            commandId: 'b03-hide-usd',
            assetId: usdCardId,
            status: AssetStatus.hidden,
          ),
        );
        await _settle(tester, 6);
        expect(
          find.descendant(
            of: find.byKey(const Key('asset')),
            matching: find.text('不选账户'),
          ),
          findsOneWidget,
        );
        expect(find.byKey(const Key('amount-currency-badge')), findsNothing);
        expect(find.byKey(const Key('amount-currency-symbol')), findsOneWidget);

        // Save 1st bill via 再记 -> verify saved RecordDraft has assetId == noRef (CNY) AND
        // after 再记, _userTouchedAsset resets to false and re-applies '默认人民币户'!
        await tester.tap(find.byKey(const Key('cat-餐饮')));
        await tester.pump();
        await _tapKeypadDigits(tester, ['3', '0']);
        await tester.tap(find.byKey(const Key('save-and-new')));
        await _settle(tester);

        final firstSaved = await _runDb(
          tester,
          () => db.select(db.records).get(),
        );
        expect(firstSaved, hasLength(1));
        expect(firstSaved.single.assetId, noRef);
        expect(firstSaved.single.moneyMinor, BigInt.from(3000));

        // After 再记: _userTouchedAsset is false and '默认人民币户' is re-applied!
        expect(
          find.descendant(
            of: find.byKey(const Key('asset')),
            matching: find.text('默认人民币户'),
          ),
          findsOneWidget,
        );

        // Switch to Transfer -> fromAssetId = tempCashId, toAssetId = usdCardId;
        // then delete tempCashId & settle usdCardId!
        await _runDb(
          tester,
          () => LedgerService(db).setAssetStatus(
            commandId: 'b03-unhide-usd',
            assetId: usdCardId,
            status: AssetStatus.active,
          ),
        );
        await _settle(tester, 4);

        await tester.tap(find.byKey(const Key('type-2')));
        await _settle(tester, 4);
        await tester.tap(find.byKey(const Key('from')));
        await _settle(tester, 4);
        await tester.tap(find.text('待删备用金').last);
        await _settle(tester, 4);
        await tester.tap(find.byKey(const Key('to')));
        await _settle(tester, 4);
        await tester.tap(find.text('外币美元卡').last);
        await _settle(tester, 4);
        expect(find.byKey(const Key('converted-summary-tap')), findsOneWidget);

        // Delete tempCashId and settle usdCardId -> both from & to clear to '选择账户' and conversion summary disappears!
        await _runDb(
          tester,
          () => LedgerService(
            db,
          ).deleteAsset(commandId: 'b03-del-temp', assetId: tempCashId),
        );
        await _settle(tester, 4);
        await _runDb(
          tester,
          () => LedgerService(db).setAssetStatus(
            commandId: 'b03-settle-usd',
            assetId: usdCardId,
            status: AssetStatus.settled,
          ),
        );
        await _settle(tester, 6);
        expect(
          find.descendant(
            of: find.byKey(const Key('from')),
            matching: find.text('选择账户'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const Key('to')),
            matching: find.text('选择账户'),
          ),
          findsOneWidget,
        );
        expect(find.byKey(const Key('converted-summary-tap')), findsNothing);

        // Verify explicit initialAsset keeps its active account across 再记, and falls back if unbound/hidden!
        await _runDb(
          tester,
          () => LedgerService(db).setAssetStatus(
            commandId: 'b03-reactivate-usd',
            assetId: usdCardId,
            status: AssetStatus.active,
          ),
        );
        editorNotifier.value = RecordEditorPage(
          key: const ValueKey('b03-explicit-asset'),
          initialAsset: usdCardId,
        );
        await _settle(tester);
        expect(
          find.descendant(
            of: find.byKey(const Key('asset')),
            matching: find.text('外币美元卡'),
          ),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const Key('cat-餐饮')));
        await tester.pump();
        await _tapKeypadDigits(tester, ['1', '0']);
        await tester.tap(find.byKey(const Key('save-and-new')));
        await _settle(tester);
        // initialAsset is still active & visible -> stays on '外币美元卡' (not hijacked by defaultWalletId)!
        expect(
          find.descendant(
            of: find.byKey(const Key('asset')),
            matching: find.text('外币美元卡'),
          ),
          findsOneWidget,
        );

        // Now bind usdCardId exclusively to book2Id -> immediately clears to '不选账户'!
        await _runDb(
          tester,
          () => db
              .into(db.assetBooks)
              .insert(
                AssetBooksCompanion.insert(assetId: usdCardId, bookId: book2Id),
              ),
        );
        await _settle(tester, 6);
        expect(
          find.descendant(
            of: find.byKey(const Key('asset')),
            matching: find.text('不选账户'),
          ),
          findsOneWidget,
        );

        await cleanUp();
      },
    );
  });

  group('B-18 & B-23: Mobile middle-zone reserve & Desktop text-scale safety', () {
    testWidgets(
      'B-18: mobile 360x640 / 390x780 & landscape 640x360 / 780x390 with OS keyboard on Transfer Key(fee) never collapses middle zone to 0px and never overflows',
      (tester) async {
        addTearDown(() {
          tester.view.reset();
        });

        final (db, _, _, cleanUp) = await _openAppHarness(tester);
        await tester.runAsync(() async {
          final ledger = LedgerService(db);
          await ledger.createAsset(
            commandId: 'b18-a1',
            name: '招行卡',
            initial: Money.parse('1000.00'),
          );
          await ledger.createAsset(
            commandId: 'b18-a2',
            name: '支付宝',
            initial: Money.parse('500.00'),
          );
        });

        await tester.pumpWidget(
          ProviderScope(
            retry: (_, _) => null,
            overrides: [databaseProvider.overrideWith((ref) async => db)],
            child: const MaterialApp(
              home: RecordEditorPage(initialType: RecordType.transfer),
            ),
          ),
        );

        for (final (viewport, imeBottom) in const <(Size, double)>[
          (Size(360, 640), 300.0),
          (Size(360, 640), 350.0),
          (Size(390, 780), 340.0),
          (Size(640, 360), 0.0),
          (Size(640, 360), 180.0),
          (Size(780, 390), 200.0),
        ]) {
          tester.view.devicePixelRatio = 1.0;
          tester.view.physicalSize = viewport;
          tester.view.viewInsets = FakeViewPadding(bottom: imeBottom);
          await _settle(tester, 4);
          if (imeBottom > 0) {
            await tester.ensureVisible(find.byKey(const Key('fee')));
            await tester.pump();
            await tester.tap(find.byKey(const Key('fee')), warnIfMissed: false);
            await _settle(tester, 3);
          }
          expect(
            tester.takeException(),
            isNull,
            reason: 'Zero overflow at $viewport (ime=$imeBottom)',
          );

          final zone2Rect = tester.getRect(
            find.byKey(const Key('editor-zone2-scroll')),
          );
          expect(
            zone2Rect.height,
            greaterThanOrEqualTo(84.0),
            reason:
                'Middle zone height (${zone2Rect.height}) must stay >= 84px at $viewport (ime=$imeBottom)',
          );
          expect(find.byKey(const Key('fee')), findsOneWidget);
        }

        await cleanUp();
      },
    );

    testWidgets(
      'B-23: desktop modal across 520x600, 900x700, 1080x700, 1280x800 at 1.0x–1.3x text scale has zero overflow, remark row dy <= 1.5px, and category grid height >= 120px',
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final (db, tempRoot, scheduler, cleanUp) = await _openAppHarness(
          tester,
        );
        late int usdAssetId;
        await tester.runAsync(() async {
          await CurrencyService(db).saveCurrency(
            commandId: 'b23-usd',
            code: 'USD',
            name: '美元',
            symbol: r'$',
            price: '7.25',
          );
          usdAssetId = await LedgerService(db).createAsset(
            commandId: 'b23-usd-acct',
            name: '美元账户',
            currency: 'USD',
            initial: Money.parse('1000.00'),
          );
          final attSvc = BillAttachmentService(db);
          final base = await attSvc.getDiyToolbarConfig();
          final allEnabled = DiyToolbarConfig.normalize([
            for (final item in base.items)
              item.copyWith(
                enabled:
                    item.action != DiyToolbarAction.autoSelectFirstCategory,
              ),
          ]);
          await attSvc.saveDiyToolbarConfig(
            commandId: 'b23-all-pills',
            config: allEnabled,
          );
        });

        final scaleNotifier = ValueNotifier<double>(1.0);
        addTearDown(scaleNotifier.dispose);

        await tester.pumpWidget(
          ProviderScope(
            retry: (_, _) => null,
            overrides: [
              databaseProvider.overrideWith((ref) async => db),
              reminderSchedulerProvider.overrideWithValue(scheduler),
              backupLocalDirectoryOverrideProvider.overrideWithValue(
                () async => Directory(p.join(tempRoot.path, 'local')),
              ),
              backupAttachmentsDirectoryOverrideProvider.overrideWithValue(
                () async => Directory(p.join(tempRoot.path, 'att')),
              ),
            ],
            child: ValueListenableBuilder<double>(
              valueListenable: scaleNotifier,
              builder: (_, scale, _) => MediaQuery(
                data: MediaQueryData.fromView(
                  tester.view,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: MaterialApp(
                  theme: ThemeData(
                    platform: TargetPlatform.linux,
                    useMaterial3: true,
                  ),
                  home: Navigator(
                    onDidRemovePage: (_) {},
                    pages: <Page<Object?>>[
                      const MaterialPage<void>(
                        child: Scaffold(body: SizedBox.expand()),
                      ),
                      DesktopRecordDialogPage<Object?>(
                        key: const ValueKey('b23-dialog'),
                        initialAssetId: usdAssetId,
                        initialAmount: '12+8',
                        initialRemark: '测试备注对齐',
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        tester.view.physicalSize = const Size(1280, 800);
        await _settle(tester);

        // Switch source currency to CNY so conversion summary line is active,
        // trigger validation error ('请选择分类'), and expand virtual keypad!
        await tester.tap(find.byKey(const Key('editor-currency-pill')));
        await _settle(tester, 4);
        await tester.tap(find.byKey(const Key('currency-option-CNY')));
        await _settle(tester, 4);
        await tester.tap(find.byKey(const Key('editor-quick-save-btn')));
        await _settle(tester, 4);
        expect(find.byKey(const Key('form-error')), findsOneWidget);
        await tester.tap(find.byKey(const Key('desktop-toggle-keypad')));
        await _settle(tester, 4);
        expect(find.byType(RecordCustomKeypad), findsOneWidget);

        for (final size in const <Size>[
          Size(520, 600),
          Size(900, 700),
          Size(1080, 700),
          Size(1280, 800),
        ]) {
          for (final scale in const <double>[1.0, 1.15, 1.3]) {
            tester.view.physicalSize = size;
            scaleNotifier.value = scale;
            await _settle(tester, 3);
            expect(
              tester.takeException(),
              isNull,
              reason: 'Zero overflow at $size @ ${scale}x',
            );

            final zone2Rect = tester.getRect(
              find.byKey(const Key('editor-zone2-scroll')),
            );
            expect(
              zone2Rect.height,
              greaterThanOrEqualTo(120.0),
              reason:
                  'Category grid height (${zone2Rect.height}) < 120px at $size @ ${scale}x',
            );

            final remarkRowFinder = find.byKey(const Key('editor-remark-row'));
            final iconDy = tester
                .getCenter(
                  find.descendant(
                    of: remarkRowFinder,
                    matching: find.byIcon(Icons.edit_note_rounded),
                  ),
                )
                .dy;
            final editableDy = tester
                .getCenter(
                  find.descendant(
                    of: find.byKey(const Key('remark')),
                    matching: find.byType(EditableText),
                  ),
                )
                .dy;
            final clearDy = tester
                .getCenter(find.byKey(const Key('editor-remark-clear-btn')))
                .dy;
            expect(
              (iconDy - editableDy).abs(),
              lessThanOrEqualTo(1.5),
              reason: 'Remark icon vs editable dy at $size @ ${scale}x',
            );
            expect(
              (editableDy - clearDy).abs(),
              lessThanOrEqualTo(1.5),
              reason: 'Remark editable vs clear dy at $size @ ${scale}x',
            );
          }
        }

        await cleanUp();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.linux),
    );
  });

  group('B-28: Honor defaultRecordType on unspecified new record & edit-mode 再记', () {
    testWidgets(
      'initializes type from defaultRecordType for /record/new?time=... & /record/new?asset=... and resets edit-mode 再记 to defaultRecordType',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final (db, tempRoot, scheduler, cleanUp) = await _openAppHarness(
          tester,
        );
        late int bankId;
        late String existingExpenseId;

        await tester.runAsync(() async {
          final ledger = LedgerService(db);
          bankId = await ledger.createAsset(
            commandId: 'b28-bank',
            name: '工资卡',
            initial: Money.parse('3000.00'),
          );
          final cats = await db.select(db.recordCategories).get();
          final foodCatId = cats
              .firstWhere(
                (c) => c.accountBookId == defaultBookId && c.name == '餐饮',
              )
              .id;
          existingExpenseId = await ledger.saveRecord(
            commandId: 'b28-exp-1',
            draft: RecordDraft(
              type: RecordType.expense,
              money: Money.parse('28.00'),
              bookId: defaultBookId,
              recordTime: DateTime(2026, 8, 10, 12).millisecondsSinceEpoch,
              categoryId: foodCatId,
              assetId: bankId,
            ),
          );
          await AppSettingsService(db).saveSettings(
            commandId: 'b28-default-income',
            settings: AppSettings.defaults.copyWith(
              defaultRecordType: RecordType.income,
            ),
          );
        });

        await tester.pumpWidget(_wrapTallyIsleApp(db, tempRoot, scheduler));
        await _settle(tester);

        final router = GoRouter.of(tester.element(find.byType(Scaffold).first));

        // 1. `/record/new?time=...` (Calendar entry without ?type=) -> opens on 收入 (type 1)!
        final targetMs = DateTime(2026, 8, 5, 9, 30).millisecondsSinceEpoch;
        unawaited(router.push('/record/new?time=$targetMs'));
        await _settle(tester);
        expect(_isTypeSelected(tester, RecordType.income), isTrue);
        router.pop();
        await _settle(tester);

        // 2. `/record/new?asset=...` (AssetDetail entry without ?type=) -> opens on 收入 with bankId selected!
        unawaited(router.push('/record/new?asset=$bankId'));
        await _settle(tester);
        expect(_isTypeSelected(tester, RecordType.income), isTrue);
        expect(
          find.descendant(
            of: find.byKey(const Key('asset')),
            matching: find.text('工资卡'),
          ),
          findsOneWidget,
        );
        router.pop();
        await _settle(tester);

        // 3. Edit-mode 再记 (`/record/:id/edit` on expense bill) -> saves edit & transitions to defaultRecordType (收入)!
        unawaited(router.push('/record/$existingExpenseId/edit'));
        await _settle(tester);
        expect(_isTypeSelected(tester, RecordType.expense), isTrue);
        await tester.tap(find.byKey(const Key('save-and-new')));
        await _settle(tester);
        expect(find.text('记一笔'), findsOneWidget);
        expect(_isTypeSelected(tester, RecordType.income), isTrue);
        router.pop();
        await _settle(tester);

        // 4. When defaultRecordType == RecordType.transfer, `/record/new?asset=...` pre-selects `from`!
        await tester.runAsync(
          () => AppSettingsService(db).saveSettings(
            commandId: 'b28-default-transfer',
            settings: AppSettings.defaults.copyWith(
              defaultRecordType: RecordType.transfer,
            ),
          ),
        );
        await _settle(tester, 4);

        unawaited(router.push('/record/new?asset=$bankId'));
        await _settle(tester);
        expect(_isTypeSelected(tester, RecordType.transfer), isTrue);
        expect(
          find.descendant(
            of: find.byKey(const Key('from')),
            matching: find.text('工资卡'),
          ),
          findsOneWidget,
        );

        await cleanUp();
      },
    );
  });

  group('RecordDateTimeDialog & RecordEditorPage Horizontal Swipes', () {
    testWidgets(
      'RecordDateTimeDialog calendar grid steps month on horizontal swipe/fling, clamps at boundaries, and debounces desktop trackpad PointerScrollEvent while keeping keys intact',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => Center(
                  child: FilledButton(
                    key: const Key('open-dt'),
                    onPressed: () => showRecordDateTimeDialog(
                      context: context,
                      initialDateTime: DateTime(2026, 8, 15, 14, 30),
                      firstDate: DateTime(2026, 7, 1),
                      lastDate: DateTime(2026, 9, 30),
                    ),
                    child: const Text('打开日期'),
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.byKey(const Key('open-dt')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('datetime-prev-month')), findsOneWidget);
        expect(find.byKey(const Key('datetime-next-month')), findsOneWidget);
        expect(find.byKey(const Key('datetime-calendar-grid')), findsOneWidget);
        expect(find.text('2026年8月'), findsOneWidget);

        final gridFinder = find.byKey(const Key('datetime-calendar-grid'));

        // Swipe right -> previous month (2026年7月), then clamp at firstDate month!
        await tester.drag(gridFinder, const Offset(110, 0));
        await tester.pumpAndSettle();
        expect(find.text('2026年7月'), findsOneWidget);

        await tester.drag(gridFinder, const Offset(110, 0));
        await tester.pumpAndSettle();
        expect(find.text('2026年7月'), findsOneWidget);

        // Swipe left -> 2026年8月; fling left -> 2026年9月; clamp at lastDate month!
        await tester.drag(gridFinder, const Offset(-110, 0));
        await tester.pumpAndSettle();
        expect(find.text('2026年8月'), findsOneWidget);

        await tester.fling(gridFinder, const Offset(-90, 0), 900);
        await tester.pumpAndSettle();
        expect(find.text('2026年9月'), findsOneWidget);

        await tester.drag(gridFinder, const Offset(-110, 0));
        await tester.pumpAndSettle();
        expect(find.text('2026年9月'), findsOneWidget);

        // Desktop trackpad horizontal PointerScrollEvent burst: debounces within 320ms!
        final gridCenter = tester.getCenter(gridFinder);
        final pointer = TestPointer(1, PointerDeviceKind.mouse);
        await tester.sendEventToBinding(pointer.hover(gridCenter));
        await tester.sendEventToBinding(pointer.scroll(const Offset(-60, 0)));
        await tester.pump(const Duration(milliseconds: 50));
        // Second scroll within cooldown must be ignored!
        await tester.sendEventToBinding(pointer.scroll(const Offset(-60, 0)));
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.text('2026年8月'), findsOneWidget);

        // After 350ms cooldown expires, scrolling right (+60) advances to 2026年9月!
        await tester.pump(const Duration(milliseconds: 350));
        await tester.sendEventToBinding(pointer.scroll(const Offset(60, 0)));
        await tester.pumpAndSettle();
        expect(find.text('2026年9月'), findsOneWidget);
      },
    );

    testWidgets(
      'RecordEditorPage middle zone steps through [支出, 收入, 转账, 报销, 预支, 预收] with end clamping in create mode, yields to TemplateQuickBar & RecordSubcategoryStrip horizontal drags, and ignores swipes in edit mode',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final (db, _, _, cleanUp) = await _openAppHarness(tester);
        late String existingId;

        await tester.runAsync(() async {
          final catalog = CatalogService(db);
          final tplSvc = TemplateRemarkService(db);
          final ledger = LedgerService(db);
          final cats = await db.select(db.recordCategories).get();
          final foodCat = cats.firstWhere(
            (c) => c.accountBookId == defaultBookId && c.name == '餐饮',
          );
          for (var i = 1; i <= 5; i++) {
            await catalog.createCategory(
              commandId: 'swipe-sub-$i',
              accountBookId: defaultBookId,
              type: RecordType.expense,
              name: '子分类$i',
              parentCatId: foodCat.id,
            );
          }
          for (var i = 1; i <= 6; i++) {
            await tplSvc.saveTemplate(
              commandId: 'swipe-tpl-$i',
              draft: TemplateDraft(
                type: RecordType.expense,
                money: Money.parse('${10 + i}.00'),
                bookId: defaultBookId,
                name: '快捷模板项目$i',
                categoryId: foodCat.id,
              ),
            );
          }
          existingId = await ledger.saveRecord(
            commandId: 'swipe-existing-bill',
            draft: RecordDraft(
              type: RecordType.expense,
              money: Money.parse('15.00'),
              bookId: defaultBookId,
              recordTime: DateTime.now().millisecondsSinceEpoch,
              categoryId: foodCat.id,
            ),
          );
        });

        final pageNotifier = ValueNotifier<Widget>(
          const RecordEditorPage(key: ValueKey('swipe-create')),
        );
        addTearDown(pageNotifier.dispose);

        await tester.pumpWidget(
          ProviderScope(
            retry: (_, _) => null,
            overrides: [databaseProvider.overrideWith((ref) async => db)],
            child: ValueListenableBuilder<Widget>(
              valueListenable: pageNotifier,
              builder: (_, child, _) => MaterialApp(home: child),
            ),
          ),
        );
        await _settle(tester);
        expect(_isTypeSelected(tester, RecordType.expense), isTrue);

        // 1. Horizontal drag inside TemplateQuickBar scrolls templates without switching record type!
        expect(find.byKey(const Key('template_quick_bar')), findsOneWidget);
        await tester.drag(
          find.byKey(const Key('template_quick_bar')),
          const Offset(-150, 0),
        );
        await _settle(tester, 3);
        expect(_isTypeSelected(tester, RecordType.expense), isTrue);

        // 2. Tap '餐饮' to expand RecordSubcategoryStrip -> horizontal drag inside strip does NOT switch record type!
        await tester.tap(find.byKey(const Key('cat-餐饮')));
        await _settle(tester, 3);
        expect(find.byType(RecordSubcategoryStrip), findsOneWidget);
        await tester.drag(
          find.byType(RecordSubcategoryStrip),
          const Offset(-150, 0),
        );
        await _settle(tester, 3);
        expect(_isTypeSelected(tester, RecordType.expense), isTrue);

        // 3. Diagonal drag (|dx| <= |dy| * 1.5) and swipe right at start end (支出) stay on 支出!
        final zone2 = find.byKey(const Key('editor-zone2-scroll'));
        await tester.drag(zone2, const Offset(-65, 55));
        await _settle(tester, 2);
        expect(_isTypeSelected(tester, RecordType.expense), isTrue);

        await tester.drag(zone2, const Offset(120, 0));
        await _settle(tester, 2);
        expect(_isTypeSelected(tester, RecordType.expense), isTrue);

        // 4. Swipe left across all 6 types: 支出 -> 收入 -> 转账 -> 报销 -> 预支 -> 预收, then clamp at 预收!
        const expectedOrder = <int>[
          RecordType.income,
          RecordType.transfer,
          RecordType.reimbursable,
          RecordType.advanceExpense,
          RecordType.advanceIncome,
        ];
        for (final nextType in expectedOrder) {
          await tester.drag(zone2, const Offset(-120, 0));
          await _settle(tester, 3);
          expect(
            _isTypeSelected(tester, nextType),
            isTrue,
            reason: 'Expected swipe left to select type=$nextType',
          );
        }
        // Clamp at 预收 on extra swipe left:
        await tester.drag(zone2, const Offset(-120, 0));
        await _settle(tester, 3);
        expect(_isTypeSelected(tester, RecordType.advanceIncome), isTrue);

        // Swipe right steps backward cleanly: 预收 -> 预支 -> 报销!
        await tester.fling(zone2, const Offset(100, 0), 800);
        await _settle(tester, 3);
        expect(_isTypeSelected(tester, RecordType.advanceExpense), isTrue);

        await tester.drag(zone2, const Offset(120, 0));
        await _settle(tester, 3);
        expect(_isTypeSelected(tester, RecordType.reimbursable), isTrue);

        // 5. Edit mode (`editing == true`): horizontal swipe on middle zone NEVER switches type!
        pageNotifier.value = RecordEditorPage(
          key: const ValueKey('swipe-edit'),
          recordId: existingId,
        );
        await _settle(tester);
        expect(_isTypeSelected(tester, RecordType.expense), isTrue);
        await tester.drag(
          find.byKey(const Key('editor-zone2-scroll')),
          const Offset(-150, 0),
        );
        await _settle(tester, 3);
        expect(_isTypeSelected(tester, RecordType.expense), isTrue);

        await cleanUp();
      },
    );
  });
}
