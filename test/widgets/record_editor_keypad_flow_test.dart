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
import 'package:tallyisle/data/catalog/currency_service.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/db/seed.dart' show defaultBookId;
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/data/tools/bill_attachment_service.dart';
import 'package:tallyisle/data/tools/template_remark_service.dart';
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
    if (k == '×' || k == '*') {
      await tester.longPress(find.byKey(const Key('editor-op-add')));
      await tester.pump();
      continue;
    }
    if (k == '÷' || k == '/') {
      await tester.longPress(find.byKey(const Key('editor-op-sub')));
      await tester.pump();
      continue;
    }
    final finder = switch (k) {
      '.' => find.byKey(const Key('keypad-dot')),
      '+' => find.byKey(const Key('editor-op-add')),
      '-' || '−' => find.byKey(const Key('editor-op-sub')),
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
    'RecordEditorPage Unified Bottom Slot, Persistent Pill Toolbar & Auto-Return Keyboard Handoff (SCR-002)',
    () {
      testWidgets(
        'opens with 4x4 custom keypad, keeps pill toolbar persistent with zero jump on remark focus, auto-returns on Android IME hide, and edits discount via clean dialog',
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

          // 1. Scaffold uses resizeToAvoidBottomInset: false (unified bottom slot),
          // amount uses TextInputType.none, and RecordCustomKeypad sits flush at bottom.
          final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
          expect(scaffold.resizeToAvoidBottomInset, isFalse);

          final amountField = tester.widget<TextField>(
            find.byKey(const Key('amount')),
          );
          expect(amountField.keyboardType, TextInputType.none);
          expect(amountField.textInputAction, TextInputAction.done);

          expect(find.byKey(const Key('record-custom-keypad')), findsOneWidget);
          expect(find.byKey(const Key('editor-pill-toolbar')), findsOneWidget);
          expect(find.byKey(const Key('save-and-new')), findsOneWidget);
          expect(find.byKey(const Key('save')), findsOneWidget);

          const screenHeight = 600.0;
          final initialDockRect = tester.getRect(
            find.byKey(const Key('editor-bottom-dock')),
          );
          expect(initialDockRect.bottom, closeTo(screenHeight, 0.5));

          // 2. Enter amount via custom keypad ('25.8'), expand attachment strip,
          // then tap Key('remark'): on frame 0 (before OS IME rises), remark row & pill toolbar
          // stay at the EXACT same Y coordinate (0.0px vertical jump!).
          await _tapKeys(tester, ['2', '5', '.', '8']);
          expect(amountField.controller!.text, '25.8');

          await tester.tap(find.byKey(const Key('editor-images-pill')));
          await tester.pump();
          final pillTopBeforeFocus = tester
              .getRect(find.byKey(const Key('editor-pill-toolbar')))
              .top;

          await tester.tap(find.byKey(const Key('remark')));
          await tester.pump();
          expect(find.byKey(const Key('record-custom-keypad')), findsNothing);
          expect(find.byKey(const Key('editor-pill-toolbar')), findsOneWidget);
          final pillTopFrameZero = tester
              .getRect(find.byKey(const Key('editor-pill-toolbar')))
              .top;
          expect(pillTopFrameZero, closeTo(pillTopBeforeFocus, 0.5));

          // 3. OS keyboard rises to 280px (and torture-tested at 300px):
          // pill toolbar stays visible directly above OS keyboard with zero overflow!
          tester.view.viewInsets = const FakeViewPadding(
            left: 0,
            top: 0,
            right: 0,
            bottom: 280,
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);

          expect(find.byKey(const Key('record-custom-keypad')), findsNothing);
          expect(find.byKey(const Key('editor-pill-toolbar')), findsOneWidget);
          expect(find.byKey(const Key('save')), findsNothing);
          expect(find.byKey(const Key('save-and-new')), findsNothing);

          final remarkKbDockRect = tester.getRect(
            find.byKey(const Key('editor-bottom-dock')),
          );
          expect(remarkKbDockRect.bottom, closeTo(screenHeight - 280, 0.5));
          expect(
            tester.getRect(find.byKey(const Key('editor-pill-toolbar'))).bottom,
            lessThanOrEqualTo(screenHeight - 280 + 0.5),
          );

          // Torture test: tall 300px OS keyboard on 800x600 with attachment strip expanded -> zero overflow!
          tester.view.viewInsets = const FakeViewPadding(
            left: 0,
            top: 0,
            right: 0,
            bottom: 300,
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.byKey(const Key('record-custom-keypad')), findsNothing);
          expect(find.byKey(const Key('editor-pill-toolbar')), findsOneWidget);

          // 4. Simulate Android System Back / IME '⌄' hide button (viewInsets drops 300 -> 0
          // WITHOUT calling unfocus() or TextInputAction.done!):
          // WidgetsBindingObserver automatically unfocuses remark and restores RecordCustomKeypad!
          tester.view.viewInsets = FakeViewPadding.zero;
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(
            tester
                .widget<TextField>(find.byKey(const Key('remark')))
                .focusNode!
                .hasFocus,
            isFalse,
          );
          expect(amountField.focusNode!.hasFocus, isTrue);
          expect(find.byKey(const Key('editor-pill-toolbar')), findsOneWidget);
          expect(find.byKey(const Key('record-custom-keypad')), findsOneWidget);

          // 5. Tapping editor-discount-pill opens clean modal dialog (no cramped 54px inline field!),
          // sets active pill label '优惠 ¥3.50', supports clear, and keeps custom keypad active!
          await tester.tap(find.byKey(const Key('editor-discount-pill')));
          await _settle(tester, 4);
          expect(find.text('设置优惠金额'), findsOneWidget);
          await tester.enterText(find.byKey(const Key('discount')), '3.5');
          await tester.tap(find.byKey(const Key('discount-confirm-btn')));
          await _settle(tester, 4);
          expect(find.text('优惠 ¥3.50'), findsOneWidget);
          expect(find.byKey(const Key('record-custom-keypad')), findsOneWidget);

          await tester.tap(find.byKey(const Key('editor-discount-pill')));
          await _settle(tester, 4);
          await tester.tap(find.byKey(const Key('discount-clear-btn')));
          await _settle(tester, 4);
          expect(find.text('优惠'), findsOneWidget);
          expect(find.byKey(const Key('record-custom-keypad')), findsOneWidget);

          await closeCleanly();
        },
      );

      testWidgets(
        'custom keypad expression entry, IME Done submit, and remark Done -> custom keypad save work end-to-end with category grid, subcategory strip, account pill, and tag pill',
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
            await catalog.createTag(commandId: 'seed-tag-trip', name: '出差');
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

          // 1. Tap visual category grid '餐饮' -> inline subcategory strip appears; selecting '精品咖啡' updates summary row.
          await tester.tap(find.byKey(const Key('cat-餐饮')));
          await _settle(tester, 4);
          expect(find.byKey(const Key('subcat-all')), findsOneWidget);
          expect(find.byKey(const Key('cat-精品咖啡')), findsOneWidget);
          await tester.tap(find.byKey(const Key('cat-精品咖啡')));
          await tester.pump();
          expect(
            find.descendant(
              of: find.byKey(const Key('editor-summary-amount-row')),
              matching: find.text('餐饮 · 精品咖啡'),
            ),
            findsOneWidget,
          );

          // 2. Select account via compact Account Pill (Key('asset')).
          await tester.tap(find.byKey(const Key('asset')));
          await _settle(tester, 4);
          await tester.tap(find.text('日常钱包').last);
          await _settle(tester, 4);
          expect(find.text('日常钱包'), findsOneWidget);

          // 3. Select tag via compact Tag Pill (Key('editor-tags-pill')):
          //    empty shows '标签' (never '#标签'), selected shows '旅行' / '旅行 +1' without duplicate '#'.
          expect(find.text('标签'), findsOneWidget);
          expect(find.text('#标签'), findsNothing);
          await tester.tap(find.byKey(const Key('editor-tags-pill')));
          await _settle(tester, 4);
          await tester.tap(find.byKey(const Key('tag-旅行')));
          await tester.tap(find.byKey(const Key('tag-出差')));
          await _settle(tester, 4);
          await tester.tap(find.text('完成'));
          await _settle(tester, 4);
          expect(find.text('旅行 +1'), findsOneWidget);
          expect(find.text('#旅行 +1'), findsNothing);

          await tester.tap(find.byKey(const Key('editor-tags-pill')));
          await _settle(tester, 4);
          await tester.tap(find.byKey(const Key('tag-出差')));
          await _settle(tester, 4);
          await tester.tap(find.text('完成'));
          await _settle(tester, 4);
          expect(find.text('旅行'), findsOneWidget);
          expect(find.text('#旅行'), findsNothing);

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
          // evaluate with '=', then type remark -> pill toolbar stays mounted, Done restores custom keypad -> tap '保存'!
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

          // Type remark -> hides custom keypad while keeping pill toolbar persistent; OS keyboard confirm ('✓') restores custom keypad!
          await tester.enterText(find.byKey(const Key('remark')), '旅途手冲');
          await tester.pump();
          expect(find.byKey(const Key('record-custom-keypad')), findsNothing);
          expect(find.byKey(const Key('editor-pill-toolbar')), findsOneWidget);
          expect(find.byKey(const Key('save')), findsNothing);

          await tester.testTextInput.receiveAction(TextInputAction.done);
          await tester.pump();
          expect(find.byKey(const Key('record-custom-keypad')), findsOneWidget);
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
        'save-and-new (再记) books first bill with auto-evaluated expression (when keypadMultiplyDivide enabled), restores custom keypad while keeping account/category, and books second bill',
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
            final attSvc = BillAttachmentService(db);
            final cfg = await attSvc.getDiyToolbarConfig();
            await attSvc.saveDiyToolbarConfig(
              commandId: 'enable-mul-div-flow',
              config: cfg.setEnabled(
                DiyToolbarAction.keypadMultiplyDivide,
                true,
              ),
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

          // Enter expression 10+2×3 (= 36.00 left-to-right!) via custom keypad + remark, confirm remark, then tap '再记'.
          await _tapKeys(tester, ['1', '0', '+', '2', '×', '3']);
          expect(find.text('= 36.00'), findsOneWidget);
          await tester.enterText(find.byKey(const Key('remark')), '第一笔早餐');
          await tester.pump();
          expect(find.byKey(const Key('record-custom-keypad')), findsNothing);

          await tester.testTextInput.receiveAction(TextInputAction.done);
          await tester.pump();
          expect(find.byKey(const Key('record-custom-keypad')), findsOneWidget);
          expect(find.text('再记'), findsOneWidget);

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
        'transfer dual-account card swaps accounts in 1 tap, hides custom keypad on fee focus, Android IME hide restores keypad, and cold-start edit keeps 再记',
        (tester) async {
          tester.view.devicePixelRatio = 1.0;
          tester.view.physicalSize = const Size(800, 600);
          await tester.binding.setSurfaceSize(const Size(800, 600));
          addTearDown(() async {
            tester.view.reset();
            await tester.binding.setSurfaceSize(null);
          });

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
          expect(
            find.descendant(
              of: find.byKey(const Key('editor-summary-amount-row')),
              matching: find.text('招商储蓄 → 零钱通'),
            ),
            findsOneWidget,
          );

          // Enter 100 via custom keypad, then enter fee 1.50 with OS IME (260px -> 0px hide restores keypad!).
          await _tapKeys(tester, ['1', '0', '0']);
          await tester.ensureVisible(find.byKey(const Key('fee')));
          await tester.pump();
          await tester.tap(find.byKey(const Key('fee')));
          tester.view.viewInsets = const FakeViewPadding(
            left: 0,
            top: 0,
            right: 0,
            bottom: 260,
          );
          await tester.pumpAndSettle();
          await tester.enterText(find.byKey(const Key('fee')), '1.50');
          await tester.pump();
          expect(find.byKey(const Key('record-custom-keypad')), findsNothing);

          tester.view.viewInsets = FakeViewPadding.zero;
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('record-custom-keypad')), findsOneWidget);

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
          // 4x4 custom keypad opens with '再记' (Key('save-and-new')) and '保存' (Key('save'))!
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
          expect(find.byKey(const Key('save-and-new')), findsOneWidget);
          expect(find.text('再记'), findsOneWidget);
          expect(find.byKey(const Key('keypad-00')), findsNothing);
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

      testWidgets(
        'Issue 1 & Issue 4: single-digit CNY amount hugs ¥ tightly without reserved 0.00 gap, type bar keeps 预收 on row 1, and dock/remark/pills/remarks-panel are 100% borderless in dark & light themes',
        (tester) async {
          tester.view.devicePixelRatio = 1.0;
          tester.view.physicalSize = const Size(360, 640);
          await tester.binding.setSurfaceSize(const Size(360, 640));
          addTearDown(() async {
            tester.view.reset();
            await tester.binding.setSurfaceSize(null);
          });

          final (db, closeCleanly) = _openTestDb(tester);
          await tester.runAsync(() async {
            await db.select(db.accountBooks).get();
            await CurrencyService(db).saveCurrency(
              commandId: 'seed-usd-gap-check',
              code: 'USD',
              name: '美元',
              symbol: r'$',
              price: '7.20',
            );
            final cats = await (db.select(
              db.recordCategories,
            )..where((t) => t.accountBookId.equals(defaultBookId))).get();
            final foodCat = cats.firstWhere((c) => c.name == '餐饮');
            await TemplateRemarkService(db).createRemark(
              commandId: 'seed-borderless-chip-remark',
              content: '冰美式',
              recordCatId: foodCat.id,
              usedTimes: 3,
            );
            final attSvc = BillAttachmentService(db);
            final cfg = await attSvc.getDiyToolbarConfig();
            await attSvc.saveDiyToolbarConfig(
              commandId: 'enable-remarks-borderless-test',
              config: cfg.setEnabled(DiyToolbarAction.frequentRemarks, true),
            );
          });

          for (final brightness in [Brightness.dark, Brightness.light]) {
            final theme = ThemeData(
              colorScheme: ColorScheme.fromSeed(
                seedColor: const Color(0xFF006D77),
                brightness: brightness,
              ),
              useMaterial3: true,
            );
            final cs = theme.colorScheme;
            final isDark = brightness == Brightness.dark;
            final expectedTrayColor = isDark
                ? cs.surfaceContainerLowest
                : cs.surfaceContainerLow;

            await tester.pumpWidget(
              ProviderScope(
                retry: (_, _) => null,
                overrides: [databaseProvider.overrideWith((ref) async => db)],
                child: MaterialApp(
                  theme: theme,
                  home: RecordEditorPage(key: ValueKey(brightness)),
                ),
              ),
            );
            await _settle(tester);
            expect(tester.takeException(), isNull);

            // 1. Empty state renders '0.00' hint; typing '6' drops hintText to null
            //    so '¥' hugs '6' tightly ((amountRect.left - symbolRect.right) <= 6.0, width < 32.0)!
            TextField amountField() =>
                tester.widget<TextField>(find.byKey(const Key('amount')));
            expect(amountField().decoration!.hintText, '0.00');

            await _tapKeys(tester, ['6']);
            expect(amountField().controller!.text, '6');
            expect(amountField().decoration!.hintText, isNull);

            final symbolRect = tester.getRect(
              find.byKey(const Key('amount-currency-symbol')),
            );
            final amountRect = tester.getRect(find.byKey(const Key('amount')));
            expect(
              amountRect.left - symbolRect.right,
              lessThanOrEqualTo(6.0),
              reason: '¥ and single-digit 6 must hug tightly ($brightness)',
            );
            expect(
              amountRect.left - symbolRect.right,
              greaterThanOrEqualTo(0.0),
            );
            expect(
              amountRect.width,
              lessThan(32.0),
              reason:
                  'Single digit 6 must not reserve 0.00 hint width ($brightness)',
            );

            // Clearing restores '0.00' hint cleanly.
            await _tapKeys(tester, ['BS']);
            expect(amountField().controller!.text, isEmpty);
            expect(amountField().decoration!.hintText, '0.00');

            // 2. Single-row Type Switcher Bar: all 6 chips (including '预收' type-9)
            //    stay on row 1 on 360x640 and use StadiumBorder + BorderSide.none!
            final typeKeys = <Key>[
              const Key('type-0'),
              const Key('type-1'),
              const Key('type-2'),
              const Key('type-3'),
              const Key('type-16'),
              const Key('type-9'),
            ];
            final firstChipCenterY = tester
                .getRect(find.byKey(typeKeys.first))
                .center
                .dy;
            for (final tk in typeKeys) {
              final chip = tester.widget<ChoiceChip>(find.byKey(tk));
              expect(chip.side, BorderSide.none);
              expect(chip.shape, const StadiumBorder());
              expect(
                (tester.getRect(find.byKey(tk)).center.dy - firstChipCenterY)
                    .abs(),
                lessThan(0.5),
                reason: '$tk must stay on row 1 without wrapping ($brightness)',
              );
            }

            // 3. Bottom Dock: zero Divider widgets, border == null, top radius 18,
            //    remark container border == null, pill Materials use StadiumBorder(side: BorderSide.none).
            final dockFinder = find.byKey(const Key('editor-bottom-dock'));
            expect(
              find.descendant(of: dockFinder, matching: find.byType(Divider)),
              findsNothing,
            );
            final dockContainer = tester.widget<Container>(dockFinder);
            final dockDecoration = dockContainer.decoration! as BoxDecoration;
            expect(dockDecoration.border, isNull);
            expect(
              dockDecoration.color,
              isDark ? cs.surfaceContainerLow : cs.surface,
            );
            expect(
              dockDecoration.borderRadius,
              const BorderRadius.vertical(top: Radius.circular(18)),
            );

            final remarkContainer = tester.widget<Container>(
              find.byKey(const Key('editor-remark-row')),
            );
            final remarkDecoration =
                remarkContainer.decoration! as BoxDecoration;
            expect(remarkDecoration.border, isNull);

            final pillMaterials = tester.widgetList<Material>(
              find.descendant(
                of: find.byKey(const Key('editor-pill-toolbar')),
                matching: find.byType(Material),
              ),
            );
            expect(pillMaterials, isNotEmpty);
            for (final m in pillMaterials) {
              expect(m.shape, const StadiumBorder(side: BorderSide.none));
            }

            // 4. Frequent Remarks Panel & bottom slot share trayColor with zero Border
            //    and borderless StadiumBorder ActionChips.
            await tester.tap(
              find.byKey(const Key('editor-remarks-toggle-btn')),
            );
            await _settle(tester, 4);

            final slotContainer = tester.widget<Container>(
              find.byKey(const Key('editor-bottom-panel-slot')),
            );
            expect(slotContainer.color, expectedTrayColor);

            final remarksPanel = tester.widget<Container>(
              find.byKey(const Key('editor-frequent-remarks-panel')),
            );
            final remarksDecoration = remarksPanel.decoration! as BoxDecoration;
            expect(remarksDecoration.border, isNull);
            expect(remarksDecoration.color, expectedTrayColor);

            final chips = tester.widgetList<ActionChip>(
              find.descendant(
                of: find.byKey(const Key('frequent_remark_chips')),
                matching: find.byType(ActionChip),
              ),
            );
            expect(chips, isNotEmpty);
            for (final chip in chips) {
              expect(chip.side, BorderSide.none);
              expect(chip.shape, const StadiumBorder());
              expect(
                chip.backgroundColor,
                isDark ? cs.surfaceContainerHigh : cs.surface,
              );
            }
          }

          await closeCleanly();
        },
      );

      testWidgets(
        'Issue 3: Frequent Remarks panel shows catId>0 remarks when categoryId==null, auto-falls back to allUnique on empty category, prioritizes category family remarks, and toggles scope via editor-remarks-scope-toggle',
        (tester) async {
          await tester.binding.setSurfaceSize(const Size(390, 844));
          addTearDown(() => tester.binding.setSurfaceSize(null));

          final (db, closeCleanly) = _openTestDb(tester);
          late int foodCatId;
          late int coffeeSubCatId;
          late int transportCatId;

          await tester.runAsync(() async {
            await db.select(db.accountBooks).get();
            final cats = await (db.select(
              db.recordCategories,
            )..where((t) => t.accountBookId.equals(defaultBookId))).get();
            foodCatId = cats.firstWhere((c) => c.name == '餐饮').id;
            transportCatId = cats.firstWhere((c) => c.name == '交通').id;

            coffeeSubCatId = await CatalogService(db).createCategory(
              commandId: 'seed-subcat-coffee-remarks',
              accountBookId: defaultBookId,
              name: '精品手冲',
              type: RecordType.expense,
              parentCatId: foodCatId,
            );

            final remarkSvc = TemplateRemarkService(db);
            // Seed ONLY category-specific remarks first (no global -1 remarks yet)
            // so selecting an unrelated category ('购物') has familyUnique.isEmpty!
            await remarkSvc.createRemark(
              commandId: 'seed-rem-food',
              content: '工作午餐',
              recordCatId: foodCatId,
              usedTimes: 2,
            );
            await remarkSvc.createRemark(
              commandId: 'seed-rem-coffee-sub',
              content: '耶加雪菲',
              recordCatId: coffeeSubCatId,
              usedTimes: 5,
            );
            await remarkSvc.createRemark(
              commandId: 'seed-rem-transport',
              content: '地铁通勤',
              recordCatId: transportCatId,
              usedTimes: 9,
            );

            final attSvc = BillAttachmentService(db);
            final cfg = await attSvc.getDiyToolbarConfig();
            await attSvc.saveDiyToolbarConfig(
              commandId: 'enable-frequent-remarks-scope-test',
              config: cfg.setEnabled(DiyToolbarAction.frequentRemarks, true),
            );
          });

          await tester.pumpWidget(
            ProviderScope(
              retry: (_, _) => null,
              overrides: [databaseProvider.overrideWith((ref) async => db)],
              child: const MaterialApp(home: RecordEditorPage()),
            ),
          );
          await _settle(tester);
          expect(tester.takeException(), isNull);

          final panelFinder = find.byKey(
            const Key('editor-frequent-remarks-panel'),
          );

          // (1) categoryId == null: shows allUnique across catId > 0, badge '全部'!
          await tester.tap(find.byKey(const Key('editor-remarks-toggle-btn')));
          await _settle(tester, 4);
          expect(panelFinder, findsOneWidget);
          expect(
            find.descendant(of: panelFinder, matching: find.text('全部')),
            findsOneWidget,
          );
          expect(
            find.byKey(const Key('editor-remarks-scope-toggle')),
            findsNothing,
          );
          expect(find.text('地铁通勤'), findsOneWidget);
          expect(find.text('耶加雪菲'), findsOneWidget);
          expect(find.text('工作午餐'), findsOneWidget);

          // (2) Select an empty category ('购物'): familyUnique is empty, so it
          //     auto-falls back to allUnique with badge '全部' (never blank)!
          await tester.tap(find.byKey(const Key('cat-购物')));
          await _settle(tester, 4);
          expect(
            find.descendant(of: panelFinder, matching: find.text('全部')),
            findsOneWidget,
          );
          expect(
            find.byKey(const Key('editor-remarks-empty-add-btn')),
            findsNothing,
          );
          expect(find.text('地铁通勤'), findsOneWidget);
          expect(find.text('耶加雪菲'), findsOneWidget);
          expect(find.text('工作午餐'), findsOneWidget);

          // (3) Select '餐饮' (which has exact '工作午餐' + child subcategory '耶加雪菲'):
          //     prioritizes '工作午餐' ahead of '耶加雪菲', excludes '地铁通勤',
          //     shows badge '餐饮', and renders editor-remarks-scope-toggle!
          await tester.tap(find.byKey(const Key('cat-餐饮')));
          await _settle(tester, 4);
          expect(
            find.descendant(
              of: find.byKey(const Key('editor-remarks-scope-toggle')),
              matching: find.text('餐饮'),
            ),
            findsOneWidget,
          );
          expect(find.text('工作午餐'), findsOneWidget);
          expect(find.text('耶加雪菲'), findsOneWidget);
          expect(find.text('地铁通勤'), findsNothing);

          // Exact categoryId ('工作午餐', usedTimes=2) ranks BEFORE child subcategory ('耶加雪菲', usedTimes=5).
          final lunchLeft = tester.getRect(find.text('工作午餐')).left;
          final coffeeLeft = tester.getRect(find.text('耶加雪菲')).left;
          expect(lunchLeft, lessThan(coffeeLeft));

          // Tapping editor-remarks-scope-toggle switches scope to '全部' (revealing '地铁通勤')!
          await tester.tap(
            find.byKey(const Key('editor-remarks-scope-toggle')),
          );
          await tester.pump();
          expect(
            find.descendant(
              of: find.byKey(const Key('editor-remarks-scope-toggle')),
              matching: find.text('全部'),
            ),
            findsOneWidget,
          );
          expect(find.text('地铁通勤'), findsOneWidget);
          expect(find.text('耶加雪菲'), findsOneWidget);
          expect(find.text('工作午餐'), findsOneWidget);

          // Selecting another category ('交通') resets _remarksShowAllScope to false so '交通' is prioritized!
          await tester.tap(find.byKey(const Key('cat-交通')));
          await _settle(tester, 4);
          expect(
            find.descendant(
              of: find.byKey(const Key('editor-remarks-scope-toggle')),
              matching: find.text('交通'),
            ),
            findsOneWidget,
          );
          expect(find.text('地铁通勤'), findsOneWidget);
          expect(find.text('工作午餐'), findsNothing);

          await closeCleanly();
        },
      );
    },
  );
}
