import 'package:drift/drift.dart' show driftRuntimeOptions;
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
    '4x4 RecordCustomKeypad, 一羽 2-Row Bottom Dock, 3-State OS Keyboard Handoff & A2 Frequent Remarks',
    () {
      testWidgets(
        '4x4 RecordCustomKeypad opens by default (>=52dp rows, no keypad-hide/mul/div keys), supports short-tap +/− & long-press ×/÷, backspace/clear, smart =, and shows 再记 in create & edit modes',
        (tester) async {
          tester.view.devicePixelRatio = 1.0;
          tester.view.physicalSize = const Size(390, 844);
          await tester.binding.setSurfaceSize(const Size(390, 844));
          addTearDown(() async {
            tester.view.reset();
            await tester.binding.setSurfaceSize(null);
          });

          final (db, closeCleanly) = _openTestDb(tester);
          late String existingRecordId;
          await tester.runAsync(() async {
            await db.select(db.accountBooks).get();
            final cats = await (db.select(
              db.recordCategories,
            )..where((t) => t.accountBookId.equals(defaultBookId))).get();
            final foodCat = cats.firstWhere((c) => c.name == '餐饮');
            existingRecordId = await LedgerService(db).saveRecord(
              commandId: 'seed-edit-mode-check',
              draft: RecordDraft(
                type: RecordType.expense,
                money: Money.parse('42.00'),
                bookId: defaultBookId,
                recordTime: DateTime(2026, 11, 13, 12).millisecondsSinceEpoch,
                categoryId: foodCat.id,
                remark: '已有账单',
              ),
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

          // 1. 4x4 keypad opens by default; legacy 5th-row / collapse / 00 keys do NOT exist!
          expect(find.byKey(const Key('record-custom-keypad')), findsOneWidget);
          expect(find.byKey(const Key('keypad-hide')), findsNothing);
          expect(find.byKey(const Key('editor-op-mul')), findsNothing);
          expect(find.byKey(const Key('editor-op-div')), findsNothing);
          expect(find.byKey(const Key('keypad-00')), findsNothing);
          expect(find.text('再记一笔'), findsNothing);

          const rows = <List<Key>>[
            [
              Key('keypad-7'),
              Key('keypad-8'),
              Key('keypad-9'),
              Key('keypad-backspace'),
            ],
            [
              Key('keypad-4'),
              Key('keypad-5'),
              Key('keypad-6'),
              Key('editor-op-add'),
            ],
            [
              Key('keypad-1'),
              Key('keypad-2'),
              Key('keypad-3'),
              Key('editor-op-sub'),
            ],
            [
              Key('save-and-new'),
              Key('keypad-0'),
              Key('keypad-dot'),
              Key('save'),
            ],
          ];

          for (final row in rows) {
            final rects = [for (final k in row) tester.getRect(find.byKey(k))];
            for (var i = 0; i < rects.length; i++) {
              expect(
                rects[i].height,
                greaterThanOrEqualTo(52.0),
                reason: '${row[i]} height must be >= 52dp',
              );
              if (i > 0) {
                expect(
                  (rects[i].center.dy - rects[0].center.dy).abs(),
                  lessThan(0.5),
                  reason: '${row[i]} must align on same row as ${row[0]}',
                );
                expect(
                  (rects[i].width - rects[0].width).abs(),
                  lessThan(0.5),
                  reason: '${row[i]} must share equal 4-col width',
                );
                expect(rects[i].left, greaterThan(rects[i - 1].right));
              }
            }
          }

          expect(find.byKey(const Key('editor-save-btn')), findsOneWidget);
          expect(
            find.descendant(
              of: find.byKey(const Key('save-and-new')),
              matching: find.text('再记'),
            ),
            findsOneWidget,
          );
          expect(find.text('保存'), findsOneWidget);

          // Operator corner hints ('×' on '+', '÷' on '−') are rendered cleanly.
          expect(
            find.descendant(
              of: find.byKey(const Key('editor-op-add')),
              matching: find.text('×'),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: find.byKey(const Key('editor-op-sub')),
              matching: find.text('÷'),
            ),
            findsOneWidget,
          );

          // 2. Amount TextField uses TextInputType.none & readOnly: false.
          final amountField = tester.widget<TextField>(
            find.byKey(const Key('amount')),
          );
          expect(amountField.keyboardType, TextInputType.none);
          expect(amountField.readOnly, isFalse);
          expect(amountField.showCursor, isTrue);

          // 3. Short-tap '+' / '−' and long-press '×' / '÷' + smart '=' BigRational evaluation:
          // '6' -> long-press '+' ('×') -> '3.5' -> short-tap '−' ('-') -> '1' -> long-press '−' ('÷') -> '4'
          // Left-to-right: ((6 * 3.5) - 1) / 4 = (21 - 1) / 4 = 5.00!
          await tester.tap(find.byKey(const Key('keypad-6')));
          await tester.pump();
          await tester.longPress(find.byKey(const Key('editor-op-add')));
          await tester.pump();
          expect(amountField.controller!.text, '6×');

          await _tapKeys(tester, ['3', '.', '5']);
          await tester.tap(find.byKey(const Key('editor-op-sub')));
          await tester.pump();
          expect(amountField.controller!.text, '6×3.5-');

          await tester.tap(find.byKey(const Key('keypad-1')));
          await tester.pump();
          await tester.longPress(find.byKey(const Key('editor-op-sub')));
          await tester.pump();
          expect(amountField.controller!.text, '6×3.5-1÷');

          await tester.tap(find.byKey(const Key('keypad-4')));
          await tester.pump();
          expect(amountField.controller!.text, '6×3.5-1÷4');
          expect(find.text('= 5.00'), findsOneWidget);
          expect(find.text('='), findsOneWidget);

          // Tap '+' as well: '+15.5' -> 20.50!
          await tester.tap(find.byKey(const Key('editor-op-add')));
          await tester.pump();
          await _tapKeys(tester, ['1', '5', '.', '5']);
          expect(amountField.controller!.text, '6×3.5-1÷4+15.5');
          expect(find.text('= 20.50'), findsOneWidget);

          await tester.tap(find.byKey(const Key('editor-save-btn')));
          await tester.pump();
          expect(amountField.controller!.text, '20.50');
          expect(amountField.focusNode!.hasFocus, isTrue);
          expect(find.byKey(const Key('record-custom-keypad')), findsOneWidget);
          expect(find.text('保存'), findsOneWidget);

          // 4. Short-tap backspace deletes 1 char; long-press backspace clears all!
          await tester.tap(find.byKey(const Key('keypad-backspace')));
          await tester.pump();
          expect(amountField.controller!.text, '20.5');

          await tester.longPress(find.byKey(const Key('keypad-backspace')));
          await tester.pump();
          expect(amountField.controller!.text, isEmpty);

          // 5. Leading dot, leading-zero, 2-decimal limit, operator replacement, and maxAmount:
          await _tapKeys(tester, ['.', '.']);
          expect(amountField.controller!.text, '0.');

          await tester.longPress(find.byKey(const Key('keypad-backspace')));
          await tester.pump();
          await _tapKeys(tester, ['0', '0', '5', '.', '3', '4', '9']);
          expect(amountField.controller!.text, '5.34');

          await _tapKeys(tester, ['+', '−', '×', '÷', '+', '.', '5', '.']);
          expect(amountField.controller!.text, '5.34+0.5');

          await tester.longPress(find.byKey(const Key('keypad-backspace')));
          await tester.pump();
          await _tapKeys(tester, List.filled(12, '8'));
          expect(amountField.controller!.text, '88888888888');
          await _tapKeys(tester, ['.', '0', '1']);
          expect(amountField.controller!.text, '88888888888.0');
          await _tapKeys(tester, ['0']);
          expect(amountField.controller!.text, '88888888888.00');

          // 6. Edit mode (`RecordEditorPage(recordId: existingRecordId)`) ALSO displays '再记' on Key('save-and-new')!
          await tester.pumpWidget(
            ProviderScope(
              retry: (_, _) => null,
              overrides: [databaseProvider.overrideWith((ref) async => db)],
              child: MaterialApp(
                home: RecordEditorPage(recordId: existingRecordId),
              ),
            ),
          );
          await _settle(tester);
          expect(tester.takeException(), isNull);
          expect(find.byKey(const Key('save-and-new')), findsOneWidget);
          expect(
            find.descendant(
              of: find.byKey(const Key('save-and-new')),
              matching: find.text('再记'),
            ),
            findsOneWidget,
          );

          await closeCleanly();
        },
      );

      testWidgets(
        '一羽 2-row bottom dock orders summary-amount -> remark -> pill-toolbar -> custom-keypad with zero vertical divider, hides CNY by default, and shows foreign currency code',
        (tester) async {
          tester.view.devicePixelRatio = 1.0;
          tester.view.physicalSize = const Size(390, 844);
          await tester.binding.setSurfaceSize(const Size(390, 844));
          addTearDown(() async {
            tester.view.reset();
            await tester.binding.setSurfaceSize(null);
          });

          final (db, closeCleanly) = _openTestDb(tester);
          await tester.runAsync(() async {
            await db.select(db.accountBooks).get();
            final foodCat =
                await (db.select(db.recordCategories)
                      ..where((t) => t.accountBookId.equals(defaultBookId)))
                    .get()
                    .then((rows) => rows.firstWhere((c) => c.name == '餐饮'));
            await CatalogService(db).createCategory(
              commandId: 'seed-subcat-pour-over',
              accountBookId: defaultBookId,
              name: '手冲咖啡',
              type: RecordType.expense,
              parentCatId: foodCat.id,
            );
            await CurrencyService(db).saveCurrency(
              commandId: 'seed-usd',
              code: 'USD',
              name: '美元',
              symbol: r'$',
              price: '7.20',
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

          final summaryRow = find.byKey(const Key('editor-summary-amount-row'));
          final remarkRow = find.byKey(const Key('editor-remark-row'));
          final pillToolbar = find.byKey(const Key('editor-pill-toolbar'));
          final customKeypad = find.byKey(const Key('record-custom-keypad'));

          expect(summaryRow, findsOneWidget);
          expect(remarkRow, findsOneWidget);
          expect(pillToolbar, findsOneWidget);
          expect(customKeypad, findsOneWidget);

          // 1. Strict top-to-bottom vertical order in _buildBottomDock:
          final rSummary = tester.getRect(summaryRow);
          final rRemark = tester.getRect(remarkRow);
          final rPill = tester.getRect(pillToolbar);
          final rKeypad = tester.getRect(customKeypad);

          expect(rSummary.bottom, lessThanOrEqualTo(rRemark.top + 0.5));
          expect(rRemark.bottom, lessThanOrEqualTo(rPill.top + 0.5));
          expect(rPill.bottom, lessThanOrEqualTo(rKeypad.top + 0.5));

          // Zero vertical divider inside bottom dock!
          expect(
            find.descendant(
              of: find.byKey(const Key('editor-bottom-dock')),
              matching: find.byType(VerticalDivider),
            ),
            findsNothing,
          );

          // 2. Placeholder before selection -> parent category icon & name -> parent · subcategory:
          expect(
            find.descendant(of: summaryRow, matching: find.text('请选择分类')),
            findsOneWidget,
          );

          await tester.tap(find.byKey(const Key('cat-餐饮')));
          await _settle(tester, 4);
          expect(
            find.descendant(
              of: summaryRow,
              matching: find.byType(CategoryIconAvatar),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(of: summaryRow, matching: find.text('餐饮')),
            findsOneWidget,
          );

          await tester.tap(find.byKey(const Key('cat-手冲咖啡')));
          await tester.pump();
          expect(
            find.descendant(of: summaryRow, matching: find.text('餐饮 · 手冲咖啡')),
            findsOneWidget,
          );

          // 3. Default CNY: NO 'CNY' label in summary-amount-row and NO currency badge!
          expect(find.byKey(const Key('amount-currency-badge')), findsNothing);
          expect(
            find.descendant(of: summaryRow, matching: find.text('CNY')),
            findsNothing,
          );

          // 4. Switch to foreign currency 'USD' via editor-currency-pill -> 'USD' badge appears in summary-amount-row!
          await tester.scrollUntilVisible(
            find.byKey(const Key('editor-currency-pill')),
            120,
            scrollable: find
                .descendant(of: pillToolbar, matching: find.byType(Scrollable))
                .first,
          );
          await tester.tap(find.byKey(const Key('editor-currency-pill')));
          await _settle(tester, 4);
          await tester.tap(find.byKey(const Key('currency-option-USD')));
          await _settle(tester, 4);

          expect(
            find.byKey(const Key('amount-currency-badge')),
            findsOneWidget,
          );
          expect(
            find.descendant(of: summaryRow, matching: find.text('USD')),
            findsOneWidget,
          );
          expect(find.byKey(const Key('converted')), findsOneWidget);

          await closeCleanly();
        },
      );

      testWidgets(
        '3-state closed-loop keyboard handoff on 360x640 (viewInsets.bottom=280): State 1 custom keypad -> State 2 remark OS keyboard with zero save bar & zero overflow -> State 3 Done / Back restores custom keypad to save',
        (tester) async {
          tester.view.devicePixelRatio = 1.0;
          tester.view.physicalSize = const Size(360, 640);
          await tester.binding.setSurfaceSize(const Size(360, 640));
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
              child: const TallyIsleApp(),
            ),
          );
          await _settle(tester);

          await tester.tap(find.byKey(const Key('add-record')));
          await _settle(tester);
          expect(tester.takeException(), isNull);

          // State 1 (open): RecordCustomKeypad & editor-pill-toolbar are visible.
          expect(find.byKey(const Key('record-custom-keypad')), findsOneWidget);
          expect(find.byKey(const Key('editor-pill-toolbar')), findsOneWidget);
          expect(find.byKey(const Key('save')), findsOneWidget);
          expect(find.byKey(const Key('save-and-new')), findsOneWidget);

          await tester.tap(find.byKey(const Key('cat-餐饮')));
          await tester.pump();

          // State 2: tap Key('remark') + OS keyboard (viewInsets.bottom = 280):
          // RecordCustomKeypad is gone, pill toolbar is gone, save & save-and-new are gone,
          // and editor-bottom-dock sits cleanly above y = 360 with zero overflow!
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
          expect(find.byKey(const Key('editor-pill-toolbar')), findsNothing);
          expect(find.byKey(const Key('save')), findsNothing);
          expect(find.byKey(const Key('save-and-new')), findsNothing);
          expect(find.byKey(const Key('editor-save-btn')), findsNothing);

          const osKeyboardTop = 640.0 - 280.0; // 360.0
          final dockRect = tester.getRect(
            find.byKey(const Key('editor-bottom-dock')),
          );
          expect(dockRect.bottom, closeTo(osKeyboardTop, 0.5));
          expect(
            tester.getRect(find.byKey(const Key('editor-remark-row'))).bottom,
            lessThanOrEqualTo(osKeyboardTop),
          );

          await tester.enterText(find.byKey(const Key('remark')), '工作午餐');
          await tester.pump();

          // State 3a: press OS keyboard confirm (TextInputAction.done) + viewInsets = zero:
          // remark unfocuses, and RecordCustomKeypad + editor-pill-toolbar automatically reappear!
          await tester.testTextInput.receiveAction(TextInputAction.done);
          tester.view.viewInsets = FakeViewPadding.zero;
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);

          final remarkField = tester.widget<TextField>(
            find.byKey(const Key('remark')),
          );
          final amountField = tester.widget<TextField>(
            find.byKey(const Key('amount')),
          );
          expect(remarkField.focusNode!.hasFocus, isFalse);
          expect(amountField.focusNode!.hasFocus, isTrue);
          expect(find.byKey(const Key('record-custom-keypad')), findsOneWidget);
          expect(find.byKey(const Key('editor-pill-toolbar')), findsOneWidget);
          expect(find.byKey(const Key('save')), findsOneWidget);
          expect(find.byKey(const Key('save-and-new')), findsOneWidget);

          // State 3b: also verify dismissing OS keyboard via unfocus (system Back) restores RecordCustomKeypad!
          await tester.tap(find.byKey(const Key('remark')));
          tester.view.viewInsets = const FakeViewPadding(
            left: 0,
            top: 0,
            right: 0,
            bottom: 280,
          );
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('record-custom-keypad')), findsNothing);

          remarkField.focusNode!.unfocus();
          tester.view.viewInsets = FakeViewPadding.zero;
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.byKey(const Key('record-custom-keypad')), findsOneWidget);
          expect(find.byKey(const Key('editor-pill-toolbar')), findsOneWidget);

          // Immediately type digits on custom keypad and tap '保存'!
          await _tapKeys(tester, ['2', '6', '.', '5']);
          await tester.tap(find.byKey(const Key('save')));
          await _settle(tester);

          final saved = await tester.runAsync(
            () => db.select(db.records).get(),
          );
          expect(saved, hasLength(1));
          expect(saved!.single.moneyMinor, BigInt.from(2650));
          expect(saved.single.remark, '工作午餐');

          await closeCleanly();
        },
      );

      testWidgets(
        'smart = handles 10÷0 with error snackbar without blocking keypad, 再记 / AppBar ✓ evaluate+save in 1 step, and tester.enterText compatibility works seamlessly',
        (tester) async {
          await tester.binding.setSurfaceSize(const Size(390, 844));
          addTearDown(() => tester.binding.setSurfaceSize(null));

          final (db, closeCleanly) = _openTestDb(tester);
          await tester.runAsync(() async {
            await db.select(db.accountBooks).get();
            await LedgerService(db).createAsset(
              commandId: 'seed-calc-wallet',
              name: '算式钱包',
              type: AssetType.normal,
              initial: Money.parse('500.00'),
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

          final amountField = tester.widget<TextField>(
            find.byKey(const Key('amount')),
          );

          // 1. Division by zero '10÷0' via custom keypad (long-press '−') -> tap '=' -> snackbar!
          await _tapKeys(tester, ['1', '0', '÷', '0']);
          expect(amountField.controller!.text, '10÷0');
          expect(find.text('='), findsOneWidget);
          expect(find.byKey(const Key('amount-live-preview')), findsNothing);

          await tester.tap(find.byKey(const Key('editor-save-btn')));
          await tester.pump();
          expect(find.text('算式无效或除数不能为 0'), findsOneWidget);
          expect(amountField.controller!.text, '10÷0');

          // 2. Fix via custom keypad (BS -> '2' -> '10÷2') and tap '再记' -> evaluates & saves 5.00 in 1 step!
          await _tapKeys(tester, ['BS', '2']);
          expect(amountField.controller!.text, '10÷2');
          expect(find.text('= 5.00'), findsOneWidget);
          await tester.tap(find.byKey(const Key('save-and-new')));
          await _settle(tester);

          expect(find.byKey(const Key('save-and-new-banner')), findsOneWidget);
          final afterFirst = await tester.runAsync(
            () => db.select(db.records).get(),
          );
          expect(afterFirst, hasLength(1));
          expect(afterFirst!.single.moneyMinor, BigInt.from(500));

          // 3. tester.enterText(Key('amount'), '35.00') + tapping Key('save') still works 100%!
          await tester.enterText(find.byKey(const Key('amount')), '35.00');
          await tester.pump();
          expect(find.text('保存'), findsOneWidget);
          await tester.tap(find.byKey(const Key('save')));
          await _settle(tester);

          final afterSecond = await tester.runAsync(
            () => db.select(db.records).get(),
          );
          expect(afterSecond, hasLength(2));

          // 4. Re-open and verify top-right AppBar '✓' evaluates '15×2' (long-press '+') and saves 30.00!
          await tester.tap(find.byKey(const Key('add-record')));
          await _settle(tester);
          await tester.tap(find.byKey(const Key('cat-餐饮')));
          await tester.pump();
          await _tapKeys(tester, ['1', '5', '×', '2']);
          expect(find.text('='), findsOneWidget);
          await tester.tap(find.byKey(const Key('editor-quick-save-btn')));
          await _settle(tester);

          final afterThird = await tester.runAsync(
            () => db.select(db.records).get(),
          );
          expect(afterThird, hasLength(3));
          expect(afterThird!.map((r) => r.moneyMinor).toSet(), {
            BigInt.from(500),
            BigInt.from(3500),
            BigInt.from(3000),
          });

          await closeCleanly();
        },
      );

      testWidgets(
        'A2 Frequent Remarks: default OFF hides toggle/chips/manage & skips usage; ON is 0px collapsed in custom keypad, expands via ▾ & auto-collapses on chip pick, and auto-floats on remark focus',
        (tester) async {
          await tester.binding.setSurfaceSize(const Size(390, 844));
          addTearDown(() => tester.binding.setSurfaceSize(null));

          final (db, closeCleanly) = _openTestDb(tester);
          late int foodCatId;

          await tester.runAsync(() async {
            await db.select(db.accountBooks).get();
            final cats = await (db.select(
              db.recordCategories,
            )..where((t) => t.accountBookId.equals(defaultBookId))).get();
            foodCatId = cats.firstWhere((c) => c.name == '餐饮').id;
            await TemplateRemarkService(db).createRemark(
              commandId: 'seed-preset-remark',
              content: '预设拿铁',
              recordCatId: foodCatId,
              usedTimes: 5,
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

          // 1. Default OFF: open RecordEditorPage and select '餐饮'.
          await tester.tap(find.byKey(const Key('add-record')));
          await _settle(tester);
          await tester.tap(find.byKey(const Key('cat-餐饮')));
          await _settle(tester, 4);

          expect(
            find.byKey(const Key('editor-remarks-toggle-btn')),
            findsNothing,
          );
          expect(find.byKey(const Key('frequent_remark_chips')), findsNothing);
          expect(find.byKey(const Key('editor-remarks-btn')), findsNothing);

          TextField remarkField() =>
              tester.widget<TextField>(find.byKey(const Key('remark')));
          expect(remarkField().decoration!.suffixIcon, isNull);

          await tester.enterText(find.byKey(const Key('remark')), '临时草稿');
          await tester.pump();
          expect(
            find.byKey(const Key('editor-remark-clear-btn')),
            findsOneWidget,
          );
          expect(
            find.byKey(const Key('editor-remarks-toggle-btn')),
            findsNothing,
          );
          expect(find.byKey(const Key('frequent_remark_chips')), findsNothing);
          expect(find.byKey(const Key('editor-remarks-btn')), findsNothing);

          await tester.tap(find.byKey(const Key('editor-remark-clear-btn')));
          await tester.pump();
          expect(remarkField().controller!.text, isEmpty);

          // Save a bill with remark '默认关闭不统计' -> recordRemarkUsage MUST NOT be called!
          await tester.testTextInput.receiveAction(TextInputAction.done);
          await tester.pump();
          await _tapKeys(tester, ['1', '8']);
          await tester.enterText(find.byKey(const Key('remark')), '默认关闭不统计');
          await tester.testTextInput.receiveAction(TextInputAction.done);
          await tester.pump();
          await tester.tap(find.byKey(const Key('save')));
          await _settle(tester);

          final remarksWhenOff = await tester.runAsync(
            () => db.select(db.remarks).get(),
          );
          expect(remarksWhenOff!.map((r) => r.content).toList(), ['预设拿铁']);

          // 2. Turn frequentRemarks ON via BillAttachmentService and re-open RecordEditorPage!
          await tester.runAsync(() async {
            final attSvc = BillAttachmentService(db);
            final cfg = await attSvc.getDiyToolbarConfig();
            await attSvc.saveDiyToolbarConfig(
              commandId: 'enable-frequent-remarks',
              config: cfg.setEnabled(DiyToolbarAction.frequentRemarks, true),
            );
          });
          await _settle(tester, 4);

          await tester.tap(find.byKey(const Key('add-record')));
          await _settle(tester);
          await tester.tap(find.byKey(const Key('cat-餐饮')));
          await _settle(tester, 4);

          // 2a. In default custom-keypad state: toggle button ('▾') is visible,
          // while frequent_remark_chips is collapsed (0 extra row height!).
          expect(find.byKey(const Key('record-custom-keypad')), findsOneWidget);
          expect(
            find.byKey(const Key('editor-remarks-toggle-btn')),
            findsOneWidget,
          );
          expect(find.byKey(const Key('frequent_remark_chips')), findsNothing);
          expect(find.byKey(const Key('editor-remarks-btn')), findsNothing);

          // 2b. Tapping '▾' expands frequent_remark_chips + editor-remarks-btn;
          // tapping preset chip '预设拿铁' fills remark and auto-collapses panel while keeping custom keypad open!
          await tester.tap(find.byKey(const Key('editor-remarks-toggle-btn')));
          await _settle(tester, 4);
          expect(
            find.byKey(const Key('frequent_remark_chips')),
            findsOneWidget,
          );
          expect(find.byKey(const Key('editor-remarks-btn')), findsOneWidget);
          expect(find.text('预设拿铁'), findsOneWidget);
          expect(find.byKey(const Key('record-custom-keypad')), findsOneWidget);

          await tester.tap(find.text('预设拿铁'));
          await tester.pump();
          expect(remarkField().controller!.text, '预设拿铁');
          expect(find.byKey(const Key('frequent_remark_chips')), findsNothing);
          expect(find.byKey(const Key('record-custom-keypad')), findsOneWidget);

          // 2c. Focusing Key('remark') (OS keyboard state) automatically reveals
          // frequent_remark_chips + editor-remarks-btn without needing to tap '▾'!
          await tester.tap(find.byKey(const Key('remark')));
          await _settle(tester, 4);
          expect(find.byKey(const Key('record-custom-keypad')), findsNothing);
          expect(
            find.byKey(const Key('frequent_remark_chips')),
            findsOneWidget,
          );
          expect(find.byKey(const Key('editor-remarks-btn')), findsOneWidget);

          // Type new remark & confirm via TextInputAction.done -> returns to custom keypad with panel collapsed!
          await tester.enterText(find.byKey(const Key('remark')), '开启后自动统计');
          await tester.testTextInput.receiveAction(TextInputAction.done);
          await tester.pump();
          expect(find.byKey(const Key('record-custom-keypad')), findsOneWidget);
          expect(find.byKey(const Key('frequent_remark_chips')), findsNothing);

          await _tapKeys(tester, ['2', '2']);
          await tester.tap(find.byKey(const Key('save')));
          await _settle(tester);

          final remarksWhenOn = await tester.runAsync(
            () => db.select(db.remarks).get(),
          );
          expect(
            remarksWhenOn!.any(
              (r) => r.content == '开启后自动统计' && r.usedTimes == 1,
            ),
            isTrue,
          );

          await closeCleanly();
        },
      );

      testWidgets(
        'edit-mode 再记 (RecordEditorPage(recordId: existingId)) updates existingId and transitions to a fresh blank RecordEditorPage so saving a 2nd bill creates a 2nd record without overwriting existingId',
        (tester) async {
          await tester.binding.setSurfaceSize(const Size(390, 844));
          addTearDown(() => tester.binding.setSurfaceSize(null));

          final (db, closeCleanly) = _openTestDb(tester);
          late String existingId;
          late int walletId;

          await tester.runAsync(() async {
            await db.select(db.accountBooks).get();
            final ledger = LedgerService(db);
            walletId = await ledger.createAsset(
              commandId: 'seed-edit-wallet',
              name: '日常卡',
              type: AssetType.normal,
              initial: Money.parse('200.00'),
            );
            final cats = await (db.select(
              db.recordCategories,
            )..where((t) => t.accountBookId.equals(defaultBookId))).get();
            final foodCat = cats.firstWhere((c) => c.name == '餐饮');
            existingId = await ledger.saveRecord(
              commandId: 'seed-existing-bill',
              draft: RecordDraft(
                type: RecordType.expense,
                money: Money.parse('25.00'),
                bookId: defaultBookId,
                recordTime: DateTime(2026, 11, 13, 9).millisecondsSinceEpoch,
                categoryId: foodCat.id,
                assetId: walletId,
                remark: '原早餐账单',
              ),
            );
          });

          // Test via full GoRouter TallyIsleApp: Home -> tap bill -> RecordDetailPage -> edit -> 再记!
          await tester.pumpWidget(
            ProviderScope(
              retry: (_, _) => null,
              overrides: [databaseProvider.overrideWith((ref) async => db)],
              child: const TallyIsleApp(),
            ),
          );
          await _settle(tester);

          await tester.tap(find.byKey(Key('record-$existingId')));
          await _settle(tester);
          expect(find.text('账单详情'), findsOneWidget);

          await tester.ensureVisible(find.byKey(const Key('edit')));
          await tester.tap(find.byKey(const Key('edit')));
          await _settle(tester);
          expect(find.text('编辑账单'), findsOneWidget);

          // Edit amount from 25.00 to 38.00 and tap '再记' (Key('save-and-new')).
          await tester.longPress(find.byKey(const Key('keypad-backspace')));
          await tester.pump();
          await _tapKeys(tester, ['3', '8']);
          await tester.tap(find.byKey(const Key('save-and-new')));
          await _settle(tester);

          // 1. existingId in DB is updated to 38.00 (3800 minor).
          final updatedExisting = await tester.runAsync(
            () => (db.select(
              db.records,
            )..where((t) => t.recordId.equals(existingId))).getSingle(),
          );
          expect(updatedExisting!.moneyMinor, BigInt.from(3800));
          expect(updatedExisting.remark, '原早餐账单');

          // 2. Editor transitioned to a fresh blank new-record editor ('记一笔')!
          expect(find.text('记一笔'), findsOneWidget);
          expect(find.text('编辑账单'), findsNothing);
          expect(find.byKey(const Key('record-custom-keypad')), findsOneWidget);
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

          // 3. Record a 2nd bill (16.00) and tap '保存' -> creates a 2nd record without overwriting existingId!
          await tester.tap(find.byKey(const Key('cat-交通')));
          await tester.pump();
          await _tapKeys(tester, ['1', '6']);
          await tester.tap(find.byKey(const Key('save')));
          await _settle(tester);

          final allRecords = await tester.runAsync(
            () => db.select(db.records).get(),
          );
          expect(allRecords, hasLength(2));
          final byId = {for (final r in allRecords!) r.recordId: r};
          expect(byId.containsKey(existingId), isTrue);
          expect(byId[existingId]!.moneyMinor, BigInt.from(3800));
          final secondRecord = allRecords.firstWhere(
            (r) => r.recordId != existingId,
          );
          expect(secondRecord.moneyMinor, BigInt.from(1600));

          // Also verify standalone Navigator (no GoRouter) RecordEditorPage(recordId: existingId) -> 再记!
          await tester.pumpWidget(
            ProviderScope(
              retry: (_, _) => null,
              overrides: [databaseProvider.overrideWith((ref) async => db)],
              child: MaterialApp(home: RecordEditorPage(recordId: existingId)),
            ),
          );
          await _settle(tester);
          expect(find.text('编辑账单'), findsOneWidget);

          await tester.longPress(find.byKey(const Key('keypad-backspace')));
          await tester.pump();
          await _tapKeys(tester, ['4', '0']);
          await tester.tap(find.byKey(const Key('save-and-new')));
          await _settle(tester, 12);
          await tester.pumpAndSettle();

          expect(find.text('记一笔'), findsOneWidget);
          await tester.tap(find.byKey(const Key('cat-餐饮')));
          await tester.pump();
          await _tapKeys(tester, ['9']);
          await tester.tap(find.byKey(const Key('save')));
          await _settle(tester);

          final finalRecords = await tester.runAsync(
            () => db.select(db.records).get(),
          );
          expect(finalRecords, hasLength(3));
          expect(
            finalRecords!
                .firstWhere((r) => r.recordId == existingId)
                .moneyMinor,
            BigInt.from(4000),
          );

          await closeCleanly();
        },
      );
    },
  );
}
