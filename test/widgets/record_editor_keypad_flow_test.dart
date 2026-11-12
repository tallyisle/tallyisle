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

Future<void> _tapKeys(WidgetTester tester, Iterable<String> keys) async {
  for (final k in keys) {
    final finder = switch (k) {
      '.' => find.byKey(const Key('keypad-dot')),
      '+' => find.byKey(const Key('editor-op-add')),
      '-' || '−' => find.byKey(const Key('editor-op-sub')),
      '×' || '*' => find.byKey(const Key('editor-op-mul')),
      '÷' || '/' => find.byKey(const Key('editor-op-div')),
      'BS' => find.byKey(const Key('keypad-backspace')),
      _ => find.byKey(Key('keypad-$k')),
    };
    await tester.tap(finder);
    await tester.pump();
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group(
    'RecordEditorPage Dual-Mode Custom Keypad & OS Keyboard Auto-Push Dock (SCR-002)',
    () {
      testWidgets(
        'opens with taller custom keypad (TextInputType.none) and auto-collapses custom keypad to push bottom dock above OS keyboard when typing remark or discount',
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

          // 1. Scaffold.resizeToAvoidBottomInset == true, amount uses TextInputType.none,
          // and RecordCustomKeypad is open by default flush at bottom of 800x600 screen.
          final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
          expect(scaffold.resizeToAvoidBottomInset, isTrue);

          final amountField = tester.widget<TextField>(
            find.byKey(const Key('amount')),
          );
          expect(amountField.keyboardType, TextInputType.none);
          expect(amountField.textInputAction, TextInputAction.done);

          expect(find.byKey(const Key('record-custom-keypad')), findsOneWidget);
          expect(find.byKey(const Key('save-and-new')), findsOneWidget);
          expect(find.byKey(const Key('save')), findsOneWidget);

          const screenHeight = 600.0;
          final initialDockRect = tester.getRect(
            find.byKey(const Key('editor-bottom-dock')),
          );
          expect(initialDockRect.bottom, closeTo(screenHeight, 0.5));

          // 2. Enter amount via custom keypad ('25.8'), then tap Key('remark') with 280px OS keyboard:
          // custom keypad collapses immediately and bottom dock rides smoothly right above keyboard!
          await _tapKeys(tester, ['2', '5', '.', '8']);
          expect(amountField.controller!.text, '25.8');

          await tester.tap(find.byKey(const Key('remark')));
          tester.view.viewInsets = const FakeViewPadding(
            left: 0,
            top: 0,
            right: 0,
            bottom: 280,
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);

          expect(find.byKey(const Key('record-custom-keypad')), findsNothing);
          final remarkKbDockRect = tester.getRect(
            find.byKey(const Key('editor-bottom-dock')),
          );
          expect(remarkKbDockRect.bottom, closeTo(screenHeight - 280, 0.5));
          expect(
            tester.getRect(find.byKey(const Key('editor-pill-toolbar'))).bottom,
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

          // 3. Torture test: tall 300px OS keyboard on 800x600 with attachment strip expanded -> zero overflow!
          await tester.tap(find.byKey(const Key('editor-images-pill')));
          tester.view.viewInsets = const FakeViewPadding(
            left: 0,
            top: 0,
            right: 0,
            bottom: 300,
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.byKey(const Key('record-custom-keypad')), findsNothing);
          expect(
            tester.getRect(find.byKey(const Key('editor-bottom-dock'))).bottom,
            lessThanOrEqualTo(screenHeight - 300),
          );

          // 4. Tap CNY / amount area -> unfocuses remark, dismisses OS keyboard, re-opens custom keypad!
          await tester.tap(find.text('CNY'));
          tester.view.viewInsets = FakeViewPadding.zero;
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(amountField.focusNode!.hasFocus, isTrue);
          expect(find.byKey(const Key('record-custom-keypad')), findsOneWidget);

          // 5. Focusing inline secondary OS-IME input (discount) also hides custom keypad cleanly!
          await tester.tap(find.byKey(const Key('discount')));
          tester.view.viewInsets = const FakeViewPadding(
            left: 0,
            top: 0,
            right: 0,
            bottom: 260,
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.byKey(const Key('record-custom-keypad')), findsNothing);

          tester.view.viewInsets = FakeViewPadding.zero;
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);

          await closeCleanly();
        },
      );

      testWidgets(
        'custom keypad expression entry, IME Done submit, and 1-tap save above OS keyboard work end-to-end with category grid, subcategory strip, account pill, and tag pill',
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

          await tester.tap(find.byKey(const Key('add-record')));
          await _settle(tester);
          expect(tester.takeException(), isNull);
          expect(find.byKey(const Key('record-custom-keypad')), findsOneWidget);

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

          // 4a. Test IME Done submit compatibility: enter '15+5*2' -> '= 40.00', Done -> '40.00'.
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

          // 4b. Clear via long-press backspace, enter '12.5+7.5' via custom keypad,
          // evaluate with '=', then type remark and hit '保存' right above OS keyboard!
          await tester.longPress(find.byKey(const Key('keypad-backspace')));
          await tester.pump();
          await _tapKeys(tester, ['1', '2', '.', '5', '+', '7', '.', '5']);
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

          // Type remark (hides custom keypad, shows compact '保存' row) and save in 1 tap!
          await tester.enterText(find.byKey(const Key('remark')), '旅途手冲');
          await tester.pump();
          expect(find.byKey(const Key('record-custom-keypad')), findsNothing);
          expect(find.byKey(const Key('save')), findsOneWidget);

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
          expect(saved.remark, '旅途手冲');

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
        'save-and-new (再记一笔) books first bill with auto-evaluated expression, restores custom keypad while keeping account/category, and books second bill',
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

          await tester.tap(find.byKey(const Key('cat-餐饮')));
          await tester.pump();
          await tester.tap(find.byKey(const Key('asset')));
          await _settle(tester, 4);
          await tester.tap(find.text('极速现金').last);
          await _settle(tester, 4);

          // Enter expression 10+2×3 (= 36.00 left-to-right!) via custom keypad + remark, then tap '再记一笔'.
          await _tapKeys(tester, ['1', '0', '+', '2', '×', '3']);
          expect(find.text('= 36.00'), findsOneWidget);
          await tester.enterText(find.byKey(const Key('remark')), '第一笔早餐');
          await tester.pump();
          expect(find.byKey(const Key('record-custom-keypad')), findsNothing);

          await tester.tap(find.byKey(const Key('save-and-new')));
          await _settle(tester);

          // Still on RecordEditorPage: custom keypad restored for next bill, amount & remark cleared, account preserved!
          expect(find.byKey(const Key('record-custom-keypad')), findsOneWidget);
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

          // Immediately enter second bill (14.00) via custom keypad and tap '保存'.
          await _tapKeys(tester, ['1', '4']);
          expect(find.byKey(const Key('save-and-new-banner')), findsNothing);
          await tester.tap(find.byKey(const Key('save')));
          await _settle(tester);

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
        'transfer dual-account card swaps accounts in 1 tap, hides custom keypad on fee focus, and cold-start edit hides save-and-new cleanly',
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

          await tester.tap(find.byKey(const Key('type-2')));
          await _settle(tester, 4);

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

          // Enter 100 via custom keypad, then enter fee 1.50 (auto-hides custom keypad!).
          await _tapKeys(tester, ['1', '0', '0']);
          await tester.enterText(find.byKey(const Key('fee')), '1.50');
          await tester.pump();
          expect(find.byKey(const Key('record-custom-keypad')), findsNothing);

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
          expect(aAfter!.balanceMinor, BigInt.from(89850));
          expect(bAfter!.balanceMinor, BigInt.from(30000));

          // Mount cold-start edit mode directly on `createdTransferId`:
          // custom keypad opens with '00' in place of hidden 'save-and-new'!
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
          expect(find.byKey(const Key('record-custom-keypad')), findsOneWidget);
          expect(find.byKey(const Key('save-and-new')), findsNothing);
          expect(find.byKey(const Key('keypad-00')), findsOneWidget);
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

          await _tapKeys(tester, ['5', '8']);
          await tester.tap(find.byKey(const Key('save')));
          await _settle(tester);

          expect(find.byType(RecordTypeIconAvatar), findsOneWidget);
          expect(find.byIcon(Icons.pets_rounded), findsOneWidget);

          await tester.tap(find.text('猫咪零食'));
          await _settle(tester);
          expect(find.text('账单详情'), findsOneWidget);
          expect(find.byType(RecordTypeIconAvatar), findsWidgets);
          expect(find.byType(AssetIconAvatar), findsOneWidget);
          expect(find.text('花呗生活号'), findsOneWidget);

          await closeCleanly();
        },
      );
    },
  );
}
