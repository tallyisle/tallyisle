import 'package:drift/drift.dart'
    show BooleanExpressionOperators, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/app/app.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/catalog/catalog_service.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/db/seed.dart' show defaultBookId;
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/features/common/catalog_icons.dart';
import 'package:tallyisle/features/records/record_editor_page.dart';

Future<void> _settle(WidgetTester tester, [int ticks = 8]) async {
  for (var i = 0; i < ticks; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

(AppDatabase, Future<void> Function()) _openTestDb(WidgetTester tester) {
  final db = AppDatabase(NativeDatabase.memory());
  var closed = false;
  Future<void> closeCleanly() async {
    if (closed) return;
    closed = true;
    await tester.pumpWidget(const SizedBox.shrink());
    await _settle(tester, 4);
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(db.close);
  }

  addTearDown(() async {
    if (!closed) {
      closed = true;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(db.close);
    }
  });
  return (db, closeCleanly);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('RecordEditorPage Native Numeric Keyboard & Auto-Push Dock (SCR-002)', () {
    testWidgets(
      'uses native decimal keyboard with zero built-in keypad/operator buttons and auto-pushes bottom dock seamlessly on OS keyboard popup',
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(800, 600);
        await tester.binding.setSurfaceSize(const Size(800, 600));
        addTearDown(() async {
          tester.view.reset();
          await tester.binding.setSurfaceSize(null);
        });

        final (db, closeCleanly) = _openTestDb(tester);
        await tester.runAsync(() => db.select(db.accountBooks).get());

        await tester.pumpWidget(
          ProviderScope(
            retry: (_, _) => null,
            overrides: [databaseProvider.overrideWith((ref) async => db)],
            child: const MaterialApp(home: RecordEditorPage()),
          ),
        );
        await _settle(tester);
        expect(tester.takeException(), isNull);

        // 1. Verify Scaffold.resizeToAvoidBottomInset == true, native numeric keyboard,
        // and complete absence of built-in RecordKeyboard & extra operator buttons.
        final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
        expect(scaffold.resizeToAvoidBottomInset, isTrue);

        final amountField = tester.widget<TextField>(
          find.byKey(const Key('amount')),
        );
        expect(
          amountField.keyboardType,
          const TextInputType.numberWithOptions(decimal: true),
        );
        expect(amountField.textInputAction, TextInputAction.done);

        expect(find.byKey(const Key('record-keyboard')), findsNothing);
        expect(find.byKey(const Key('toggle-keypad-btn')), findsNothing);
        expect(find.byKey(const Key('keypad-add')), findsNothing);
        expect(find.byKey(const Key('keypad-sub')), findsNothing);
        expect(find.byKey(const Key('keypad-mul')), findsNothing);
        expect(find.byKey(const Key('keypad-div')), findsNothing);
        expect(find.byKey(const Key('save-and-new')), findsOneWidget);
        expect(find.byKey(const Key('save')), findsOneWidget);

        // Keyboard closed: bottom dock sits flush at bottom of 800x600 screen.
        const screenHeight = 600.0;
        final closedDockRect = tester.getRect(
          find.byKey(const Key('editor-bottom-dock')),
        );
        expect(closedDockRect.bottom, closeTo(screenHeight, 0.5));

        // 2. Tap currency/amount area -> focuses Key('amount'), simulate OS keyboard (280px).
        await tester.tap(find.text('CNY'));
        tester.view.viewInsets = const FakeViewPadding(
          left: 0,
          top: 0,
          right: 0,
          bottom: 280,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(amountField.focusNode!.hasFocus, isTrue);

        final amountKbDockRect = tester.getRect(
          find.byKey(const Key('editor-bottom-dock')),
        );
        expect(amountKbDockRect.bottom, lessThanOrEqualTo(screenHeight - 280));
        expect(amountKbDockRect.bottom, closeTo(screenHeight - 280, 0.5));
        expect(
          tester.getRect(find.byKey(const Key('amount'))).bottom,
          lessThanOrEqualTo(screenHeight - 280),
        );
        expect(
          tester.getRect(find.byKey(const Key('remark'))).bottom,
          lessThanOrEqualTo(screenHeight - 280),
        );
        expect(
          tester.getRect(find.byKey(const Key('save'))).bottom,
          lessThanOrEqualTo(screenHeight - 280),
        );

        // 3. Switch directly to Key('remark') while OS keyboard stays open (280px):
        // bottom dock stays smoothly docked right above keyboard with zero split or overflow!
        await tester.tap(find.byKey(const Key('remark')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        final remarkKbDockRect = tester.getRect(
          find.byKey(const Key('editor-bottom-dock')),
        );
        expect(remarkKbDockRect.bottom, lessThanOrEqualTo(screenHeight - 280));
        expect(remarkKbDockRect.bottom, closeTo(screenHeight - 280, 0.5));
        expect(
          tester.getRect(find.byKey(const Key('remark'))).bottom,
          lessThanOrEqualTo(screenHeight - 280),
        );
        expect(
          tester.getRect(find.byKey(const Key('save'))).bottom,
          lessThanOrEqualTo(screenHeight - 280),
        );

        // 4. Torture test: tall 300px keyboard on 800x600 with attachment strip expanded -> zero overflow!
        await tester.tap(find.byKey(const Key('editor-images-pill')));
        tester.view.viewInsets = const FakeViewPadding(
          left: 0,
          top: 0,
          right: 0,
          bottom: 300,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          tester.getRect(find.byKey(const Key('editor-bottom-dock'))).bottom,
          lessThanOrEqualTo(screenHeight - 300),
        );

        // Reset keyboard insets before teardown.
        tester.view.viewInsets = FakeViewPadding.zero;
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        await closeCleanly();
      },
    );

    testWidgets(
      'silent background expression evaluation supports IME Done submit and auto-evaluation on Save with category grid, subcategory strip, account pill, and tag pill',
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(390, 844);
        await tester.binding.setSurfaceSize(const Size(390, 844));
        addTearDown(() async {
          tester.view.reset();
          await tester.binding.setSurfaceSize(null);
        });

        final (db, closeCleanly) = _openTestDb(tester);
        late int walletId;
        late int coffeeSubId;
        late String travelTagId;

        await tester.runAsync(() async {
          await db.select(db.accountBooks).get();
          final ledger = LedgerService(db);
          final catalog = CatalogService(db);

          walletId = await ledger.createAsset(
            commandId: 'seed-wallet',
            name: '日常钱包',
            type: AssetType.normal,
            initial: Money.parse('500.00'),
          );
          final foodCat =
              await (db.select(db.recordCategories)..where(
                    (t) =>
                        t.accountBookId.equals(defaultBookId) &
                        t.name.equals('餐饮'),
                  ))
                  .getSingle();
          coffeeSubId = await catalog.createCategory(
            commandId: 'seed-sub-coffee',
            accountBookId: defaultBookId,
            name: '精品咖啡',
            type: RecordType.expense,
            parentCatId: foodCat.id,
          );
          travelTagId = await catalog.createTag(
            commandId: 'seed-tag-travel',
            name: '旅行',
          );
        });

        await tester.pumpWidget(
          ProviderScope(
            retry: (_, _) => null,
            overrides: [databaseProvider.overrideWith((ref) async => db)],
            child: const TallyIsleApp(),
          ),
        );
        await _settle(tester);

        // Open RecordEditorPage via Home FAB on 390x844 phone viewport.
        await tester.tap(find.byKey(const Key('add-record')));
        await _settle(tester);
        expect(tester.takeException(), isNull);

        // 1. Tap visual category grid '餐饮' -> inline subcategory strip appears.
        await tester.tap(find.byKey(const Key('cat-餐饮')));
        await _settle(tester, 4);
        expect(find.byKey(const Key('subcat-all')), findsOneWidget);
        expect(find.byKey(const Key('cat-精品咖啡')), findsOneWidget);
        await tester.tap(find.byKey(const Key('cat-精品咖啡')));
        await tester.pump();

        // 2. Select account via compact Account Pill (Key('asset')).
        await tester.tap(find.byKey(const Key('asset')));
        await _settle(tester, 4);
        await tester.tap(find.text('日常钱包').last);
        await _settle(tester, 4);
        expect(find.text('日常钱包'), findsOneWidget);

        // 3. Select tag via compact Tag Pill (Key('editor-tags-pill')).
        await tester.tap(find.byKey(const Key('editor-tags-pill')));
        await _settle(tester, 4);
        await tester.tap(find.byKey(const Key('tag-旅行')));
        await _settle(tester, 4);
        await tester.tap(find.text('完成'));
        await _settle(tester, 4);
        expect(find.text('#旅行'), findsOneWidget);

        // 4a. Test IME Done submit: enter '15+5*2' -> normalized to '15+5×2', preview '= 40.00', Done -> '40.00'.
        await tester.enterText(find.byKey(const Key('amount')), '15+5*2');
        await tester.pump();
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('amount')))
              .controller!
              .text,
          '15+5×2',
        );
        expect(find.byKey(const Key('amount-live-preview')), findsOneWidget);
        expect(find.text('= 40.00'), findsOneWidget);

        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('amount')))
              .controller!
              .text,
          '40.00',
        );
        expect(find.byKey(const Key('amount-live-preview')), findsNothing);

        // 4b. Test smart '=' in-place evaluation followed by Save:
        // enter '12.5+7.5' -> preview '= 20.00' & button '=' -> tap '=' -> '20.00' -> tap '保存'!
        await tester.enterText(find.byKey(const Key('amount')), '12.5+7.5');
        await tester.pump();
        expect(find.byKey(const Key('amount-live-preview')), findsOneWidget);
        expect(find.text('= 20.00'), findsOneWidget);
        expect(find.text('='), findsOneWidget);

        await tester.tap(find.byKey(const Key('save')));
        await tester.pump();
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('amount')))
              .controller!
              .text,
          '20.00',
        );
        expect(find.text('保存'), findsOneWidget);

        await tester.tap(find.byKey(const Key('save')));
        await _settle(tester);

        final savedRows = await tester.runAsync(
          () => db.select(db.records).get(),
        );
        expect(savedRows, hasLength(1));
        final saved = savedRows!.single;
        expect(saved.moneyMinor, BigInt.from(2000));
        expect(saved.recordCatId, coffeeSubId);
        expect(saved.assetId, walletId);

        final savedTagLinks = await tester.runAsync(
          () => (db.select(
            db.tagRecords,
          )..where((t) => t.recordId.equals(saved.recordId))).get(),
        );
        expect(savedTagLinks!.map((e) => e.tagId).toList(), [travelTagId]);

        final updatedWallet = await tester.runAsync(
          () => (db.select(
            db.assets,
          )..where((t) => t.id.equals(walletId))).getSingle(),
        );
        expect(
          updatedWallet!.balanceMinor,
          BigInt.from(48000),
        ); // 500 - 20 = 480

        await closeCleanly();
      },
    );

    testWidgets(
      'save-and-new (再记一笔) books first bill with auto-evaluated expression, clears amount/remark while keeping account/category, and books second bill',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 600));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final (db, closeCleanly) = _openTestDb(tester);
        late int walletId;

        await tester.runAsync(() async {
          await db.select(db.accountBooks).get();
          walletId = await LedgerService(db).createAsset(
            commandId: 'seed-fast-wallet',
            name: '极速现金',
            type: AssetType.normal,
            initial: Money.parse('300.00'),
          );
        });

        await tester.pumpWidget(
          ProviderScope(
            retry: (_, _) => null,
            overrides: [databaseProvider.overrideWith((ref) async => db)],
            child: const TallyIsleApp(),
          ),
        );
        await _settle(tester);

        await tester.tap(find.byKey(const Key('add-record')));
        await _settle(tester);

        // Select category '餐饮' and account '极速现金'.
        await tester.tap(find.byKey(const Key('cat-餐饮')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('asset')));
        await _settle(tester, 4);
        await tester.tap(find.text('极速现金').last);
        await _settle(tester, 4);

        // Enter expression 10+2*3 (= 36.00 left-to-right!) + remark, then tap '再记一笔'.
        await tester.enterText(find.byKey(const Key('amount')), '10+2*3');
        await tester.enterText(find.byKey(const Key('remark')), '第一笔早餐');
        await tester.pump();
        expect(find.text('= 36.00'), findsOneWidget);

        await tester.tap(find.byKey(const Key('save-and-new')));
        await _settle(tester);

        // Still on RecordEditorPage: amount & remark cleared, account '极速现金' preserved!
        expect(find.byKey(const Key('record-keyboard')), findsNothing);
        expect(find.byKey(const Key('save-and-new')), findsOneWidget);
        expect(find.byKey(const Key('save-and-new-banner')), findsOneWidget);
        expect(find.text('已保存，可继续记下一笔'), findsOneWidget);
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('amount')))
              .controller!
              .text,
          isEmpty,
        );
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('remark')))
              .controller!
              .text,
          isEmpty,
        );
        expect(find.text('极速现金'), findsOneWidget);

        // Immediately enter second bill (14.00) and tap '保存'.
        await tester.enterText(find.byKey(const Key('amount')), '14');
        await tester.enterText(find.byKey(const Key('remark')), '第二笔豆浆');
        await tester.pump();
        expect(find.byKey(const Key('save-and-new-banner')), findsNothing);
        await tester.tap(find.byKey(const Key('save')));
        await _settle(tester);

        // Back on HomePage: both bills recorded, balance = 300 - 36 - 14 = 250.00!
        final allRecords = await tester.runAsync(
          () => db.select(db.records).get(),
        );
        expect(allRecords, hasLength(2));
        expect(allRecords!.map((r) => r.moneyMinor).toSet(), {
          BigInt.from(3600),
          BigInt.from(1400),
        });

        final walletAfter = await tester.runAsync(
          () => (db.select(
            db.assets,
          )..where((t) => t.id.equals(walletId))).getSingle(),
        );
        expect(walletAfter!.balanceMinor, BigInt.from(25000));

        await closeCleanly();
      },
    );

    testWidgets(
      'transfer dual-account card swaps accounts in 1 tap and cold-start edit loads record cleanly',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 600));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final (db, closeCleanly) = _openTestDb(tester);
        late int cardA;
        late int cardB;

        await tester.runAsync(() async {
          await db.select(db.accountBooks).get();
          final ledger = LedgerService(db);
          cardA = await ledger.createAsset(
            commandId: 'seed-card-a',
            name: '招商储蓄',
            type: AssetType.normal,
            initial: Money.parse('1000.00'),
          );
          cardB = await ledger.createAsset(
            commandId: 'seed-card-b',
            name: '零钱通',
            type: AssetType.normal,
            initial: Money.parse('200.00'),
          );
        });

        // Mount RecordEditorPage directly on a cold ProviderScope (tests cold-start DB queries!).
        String? createdTransferId;
        await tester.pumpWidget(
          ProviderScope(
            retry: (_, _) => null,
            overrides: [databaseProvider.overrideWith((ref) async => db)],
            child: MaterialApp(
              home: Builder(
                builder: (ctx) => Scaffold(
                  body: Center(
                    child: FilledButton(
                      key: const Key('open-cold-editor'),
                      onPressed: () async {
                        createdTransferId = await Navigator.of(ctx)
                            .push<String>(
                              MaterialPageRoute(
                                builder: (_) => const RecordEditorPage(),
                              ),
                            );
                      },
                      child: const Text('打开'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await _settle(tester);
        await tester.tap(find.byKey(const Key('open-cold-editor')));
        await _settle(tester);

        // Switch to Transfer (Key('type-2')).
        await tester.tap(find.byKey(const Key('type-2')));
        await _settle(tester, 4);

        // Pick from = 零钱通, to = 招商储蓄, then tap 1-tap swap button -> from = 招商储蓄, to = 零钱通!
        await tester.tap(find.byKey(const Key('from')));
        await _settle(tester, 4);
        await tester.tap(find.text('零钱通').last);
        await _settle(tester, 4);

        await tester.tap(find.byKey(const Key('to')));
        await _settle(tester, 4);
        await tester.tap(find.text('招商储蓄').last);
        await _settle(tester, 4);

        await tester.tap(find.byKey(const Key('transfer-swap-btn')));
        await tester.pump();

        // Enter 100 via native amount field and fee 1.50, then save.
        await tester.enterText(find.byKey(const Key('amount')), '100');
        await tester.enterText(find.byKey(const Key('fee')), '1.50');
        await tester.pump();

        await tester.tap(find.byKey(const Key('save')));
        await _settle(tester);

        expect(createdTransferId, isNotNull);
        final aAfter = await tester.runAsync(
          () => (db.select(
            db.assets,
          )..where((t) => t.id.equals(cardA))).getSingle(),
        );
        final bAfter = await tester.runAsync(
          () => (db.select(
            db.assets,
          )..where((t) => t.id.equals(cardB))).getSingle(),
        );
        // Swapped so from = 招商储蓄 (1000 - 100 - 1.50 = 898.50), to = 零钱通 (200 + 100 = 300.00)!
        expect(aAfter!.balanceMinor, BigInt.from(89850));
        expect(bAfter!.balanceMinor, BigInt.from(30000));

        // Now mount cold-start edit mode directly on `createdTransferId`!
        await tester.pumpWidget(
          ProviderScope(
            retry: (_, _) => null,
            overrides: [databaseProvider.overrideWith((ref) async => db)],
            child: MaterialApp(
              home: RecordEditorPage(recordId: createdTransferId),
            ),
          ),
        );
        await _settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('save-and-new')), findsNothing);
        expect(find.byKey(const Key('save')), findsOneWidget);
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('amount')))
              .controller!
              .text,
          '100.00',
        );
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('fee')))
              .controller!
              .text,
          '1.50',
        );

        await closeCleanly();
      },
    );

    testWidgets(
      'custom category and account icons/colors propagate across RecordEditorPage, HomePage, and RecordDetailPage',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 600));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final (db, closeCleanly) = _openTestDb(tester);

        await tester.runAsync(() async {
          await db.select(db.accountBooks).get();
          await CatalogService(db).createCategory(
            commandId: 'seed-custom-pet-cat',
            accountBookId: defaultBookId,
            name: '猫咪零食',
            type: RecordType.expense,
            icon: 'pets',
            colorFill: '#7E57C2',
          );
          await LedgerService(db).createAsset(
            commandId: 'seed-custom-credit-acct',
            name: '花呗生活号',
            type: AssetType.credit,
            initial: Money.zero(),
            icon: 'huabei',
            color: '#29B6F6',
          );
        });

        await tester.pumpWidget(
          ProviderScope(
            retry: (_, _) => null,
            overrides: [databaseProvider.overrideWith((ref) async => db)],
            child: const TallyIsleApp(),
          ),
        );
        await _settle(tester);

        await tester.tap(find.byKey(const Key('add-record')));
        await _settle(tester);

        // Scroll category grid until custom category '猫咪零食' is visible and verify custom icon!
        await tester.scrollUntilVisible(
          find.byKey(const Key('cat-猫咪零食')),
          120,
          scrollable: find.descendant(
            of: find.byKey(const Key('editor-zone2-scroll')),
            matching: find.byType(Scrollable),
          ),
        );
        await tester.pump();
        expect(
          find.descendant(
            of: find.byKey(const Key('cat-猫咪零食')),
            matching: find.byIcon(Icons.pets_rounded),
          ),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('cat-猫咪零食')));
        await tester.pump();

        // Pick custom account '花呗生活号' and verify custom icon in picker & account pill!
        await tester.tap(find.byKey(const Key('asset')));
        await _settle(tester, 4);
        expect(find.byIcon(Icons.auto_awesome_rounded), findsOneWidget);
        await tester.tap(find.text('花呗生活号').last);
        await _settle(tester, 4);
        expect(
          find.descendant(
            of: find.byKey(const Key('asset')),
            matching: find.byType(AssetIconAvatar),
          ),
          findsOneWidget,
        );

        // Save bill 58.00 -> returns to HomePage where RecordTypeIconAvatar renders!
        await tester.enterText(find.byKey(const Key('amount')), '58');
        await tester.pump();
        await tester.tap(find.byKey(const Key('save')));
        await _settle(tester);

        expect(find.byType(RecordTypeIconAvatar), findsOneWidget);
        expect(find.byIcon(Icons.pets_rounded), findsOneWidget);

        // Tap bill -> opens RecordDetailPage with RecordTypeIconAvatar & AssetIconAvatar!
        await tester.tap(find.text('猫咪零食'));
        await _settle(tester);
        expect(find.text('账单详情'), findsOneWidget);
        expect(find.byType(RecordTypeIconAvatar), findsWidgets);
        expect(find.byType(AssetIconAvatar), findsOneWidget);
        expect(find.text('花呗生活号'), findsOneWidget);

        await closeCleanly();
      },
    );
  });
}
