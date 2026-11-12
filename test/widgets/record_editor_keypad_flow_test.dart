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

Future<void> _tapKeypadSequence(WidgetTester tester, List<String> keys) async {
  for (final k in keys) {
    final keyFinder = switch (k) {
      '.' => find.byKey(const Key('keypad-dot')),
      '+' => find.byKey(const Key('keypad-add')),
      '-' => find.byKey(const Key('keypad-sub')),
      '×' || '*' => find.byKey(const Key('keypad-mul')),
      '÷' || '/' => find.byKey(const Key('keypad-div')),
      '⌫' => find.byKey(const Key('keypad-backspace')),
      'C' => find.byKey(const Key('keypad-clear')),
      '=' => find.byKey(const Key('save')),
      _ => find.byKey(Key('keypad-$k')),
    };
    await tester.tap(keyFinder);
    await tester.pump();
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('RecordEditorPage 3-Zone UX & RecordKeyboard flows (SCR-002)', () {
    testWidgets(
      'keypad evaluates 12.5 + 7.5 = -> 20.00 and saves expense with category grid, subcategory strip, account pill, and tag pill on 800x600 viewport',
      (tester) async {
        // Explicit 800x600 surface check — zero RenderFlex overflow allowed.
        await tester.binding.setSurfaceSize(const Size(800, 600));
        addTearDown(() => tester.binding.setSurfaceSize(null));

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

        // Open RecordEditorPage via Home FAB.
        await tester.tap(find.byKey(const Key('add-record')));
        await _settle(tester);
        expect(tester.takeException(), isNull);

        // 1. Tap visual category grid '餐饮' -> inline subcategory strip appears!
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

        // 4. Tap keypad digits & operators: 12.5 + 7.5 -> live preview = 20.00, primary button shows '='!
        await _tapKeypadSequence(tester, [
          '1',
          '2',
          '.',
          '5',
          '+',
          '7',
          '.',
          '5',
        ]);
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('amount')))
              .controller!
              .text,
          '12.5+7.5',
        );
        expect(find.byKey(const Key('amount-live-preview')), findsOneWidget);
        expect(find.text('= 20.00'), findsOneWidget);
        expect(find.text('='), findsOneWidget);

        // Tap '=' (on primary keypad button) -> evaluates in-place to '20.00' and switches to '保存'!
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

        // Tap '保存' (Key('save')) -> saves bill and returns to HomePage!
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

        // Enter expression 10 + 2 × 3 (= 36.00 left-to-right!) + remark, then tap '再记一笔' directly without '='!
        await _tapKeypadSequence(tester, ['1', '0', '+', '2', '×', '3']);
        await tester.enterText(find.byKey(const Key('remark')), '第一笔早餐');
        await tester.pump();

        await tester.tap(find.byKey(const Key('save-and-new')));
        await _settle(tester);

        // Still on RecordEditorPage: amount & remark cleared, account '极速现金' preserved!
        expect(find.byKey(const Key('record-keyboard')), findsOneWidget);
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
        await _tapKeypadSequence(tester, ['1', '4']);
        await tester.enterText(find.byKey(const Key('remark')), '第二笔豆浆');
        await tester.pump();
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

        // Enter 100 via keypad and fee 1.50, then save.
        await _tapKeypadSequence(tester, ['1', '0', '0']);
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
        await _tapKeypadSequence(tester, ['5', '8']);
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
