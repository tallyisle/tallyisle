import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/app/app.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/db/seed.dart' show defaultBookId;
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/data/tools/bill_attachment_service.dart';
import 'package:tallyisle/data/tools/template_remark_service.dart';
import 'package:tallyisle/domain/model/codes.dart';
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
    'RecordCustomKeypad, Dual-Mode Remark OS Keyboard Push-Up & Frequent Remarks',
    () {
      testWidgets(
        'taller RecordCustomKeypad opens by default with >=50dp digit rows, TextInputType.none, arithmetic ops, 2-decimal/maxAmount rules, backspace & long-press clear',
        (tester) async {
          tester.view.devicePixelRatio = 1.0;
          tester.view.physicalSize = const Size(390, 844);
          await tester.binding.setSurfaceSize(const Size(390, 844));
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

          // 1. Custom keypad opens by default with taller proportions & zero duplicate keys.
          expect(find.byKey(const Key('record-custom-keypad')), findsOneWidget);
          expect(find.byKey(const Key('editor-op-add')), findsOneWidget);
          expect(find.byKey(const Key('editor-op-sub')), findsOneWidget);
          expect(find.byKey(const Key('editor-op-mul')), findsOneWidget);
          expect(find.byKey(const Key('editor-op-div')), findsOneWidget);
          expect(find.byKey(const Key('keypad-hide')), findsOneWidget);
          expect(find.byKey(const Key('keypad-backspace')), findsOneWidget);
          expect(find.byKey(const Key('save-and-new')), findsOneWidget);
          expect(find.byKey(const Key('editor-save-btn')), findsOneWidget);
          expect(find.byKey(const Key('save')), findsOneWidget);
          expect(find.text('保存'), findsOneWidget);

          final keypadRect = tester.getRect(
            find.byKey(const Key('record-custom-keypad')),
          );
          expect(keypadRect.height, inInclusiveRange(280.0, 296.0));

          for (final key in const <Key>[
            Key('keypad-7'),
            Key('keypad-4'),
            Key('keypad-1'),
            Key('keypad-0'),
            Key('keypad-dot'),
            Key('keypad-hide'),
            Key('keypad-backspace'),
            Key('save-and-new'),
          ]) {
            expect(
              tester.getSize(find.byKey(key)).height,
              greaterThanOrEqualTo(50.0),
            );
          }
          // 2-row-tall giant primary button (113dp).
          expect(
            tester.getSize(find.byKey(const Key('save'))).height,
            greaterThanOrEqualTo(108.0),
          );

          // 2. Amount TextField uses TextInputType.none (suppresses OS keyboard) & readOnly: false.
          final amountField = tester.widget<TextField>(
            find.byKey(const Key('amount')),
          );
          expect(amountField.keyboardType, TextInputType.none);
          expect(amountField.readOnly, isFalse);
          expect(amountField.showCursor, isTrue);

          // 3. Tapping 1, 2, ., 5, +, 8 builds '12.5+8', shows '=', evaluates to '20.50' in-place!
          await _tapKeys(tester, ['1', '2', '.', '5', '+', '8']);
          expect(amountField.controller!.text, '12.5+8');
          expect(amountField.focusNode!.hasFocus, isTrue);
          expect(find.text('= 20.50'), findsOneWidget);
          expect(find.text('='), findsOneWidget);

          await tester.tap(find.byKey(const Key('editor-save-btn')));
          await tester.pump();
          expect(amountField.controller!.text, '20.50');
          expect(amountField.focusNode!.hasFocus, isTrue);
          expect(find.byKey(const Key('record-custom-keypad')), findsOneWidget);
          expect(find.text('保存'), findsOneWidget);

          // 4. Backspace deletes 1 char; long-press backspace clears entire expression!
          await _tapKeys(tester, ['BS']);
          expect(amountField.controller!.text, '20.5');

          await tester.longPress(find.byKey(const Key('keypad-backspace')));
          await tester.pump();
          expect(amountField.controller!.text, isEmpty);

          // 5. Leading dot & second-dot rules: '' + '.' -> '0.', second '.' ignored.
          await _tapKeys(tester, ['.', '.']);
          expect(amountField.controller!.text, '0.');

          // 6. Leading-zero normalization & max 2 decimals per segment:
          await tester.longPress(find.byKey(const Key('keypad-backspace')));
          await tester.pump();
          await _tapKeys(tester, ['0', '0']);
          expect(amountField.controller!.text, '0');
          await _tapKeys(tester, ['5']);
          expect(amountField.controller!.text, '5');

          // '5' -> '5.34', 3rd decimal '9' ignored -> '5.34', then '+' + '0' -> '5.34+0' -> '5' -> '5.34+5'!
          await _tapKeys(tester, ['.', '3', '4', '9']);
          expect(amountField.controller!.text, '5.34');
          await _tapKeys(tester, ['+', '0', '5']);
          expect(amountField.controller!.text, '5.34+5');

          // Operator replacement & dot right after operator ('12+' + '.' -> '12+0.'):
          await tester.longPress(find.byKey(const Key('keypad-backspace')));
          await tester.pump();
          await _tapKeys(tester, ['1', '2', '+', '−', '×', '÷', '+']);
          expect(amountField.controller!.text, '12+');
          await _tapKeys(tester, ['.', '5', '.']);
          expect(amountField.controller!.text, '12+0.5');

          // 7. Enforce maxAmount (88888888888.00) per operand segment cleanly:
          await tester.longPress(find.byKey(const Key('keypad-backspace')));
          await tester.pump();
          await _tapKeys(tester, List.filled(12, '8'));
          expect(amountField.controller!.text, '88888888888');
          await _tapKeys(tester, ['.', '0', '1']);
          expect(amountField.controller!.text, '88888888888.0');
          await _tapKeys(tester, ['0']);
          expect(amountField.controller!.text, '88888888888.00');

          await closeCleanly();
        },
      );

      testWidgets(
        'focusing remark on 360x640 immediately hides custom keypad and pushes bottom dock above OS keyboard (viewInsets.bottom=280) with zero overflow; tapping amount or keypad-hide toggles cleanly',
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
              child: const MaterialApp(home: RecordEditorPage()),
            ),
          );
          await _settle(tester);
          expect(tester.takeException(), isNull);
          expect(find.byKey(const Key('record-custom-keypad')), findsOneWidget);

          // Enter '12+8' via custom keypad on 360x640.
          await _tapKeys(tester, ['1', '2', '+', '8']);
          expect(tester.takeException(), isNull);

          // 1. Focus remark (Key('remark')) & simulate OS text keyboard (viewInsets.bottom = 280):
          // RecordCustomKeypad hides immediately and bottom dock pushes cleanly above y = 360!
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
          // Zero duplicate keys: compact action row owns save-and-new & save!
          expect(find.byKey(const Key('editor-pill-toolbar')), findsOneWidget);
          expect(find.byKey(const Key('remark')), findsOneWidget);
          expect(find.byKey(const Key('amount')), findsOneWidget);
          expect(find.byKey(const Key('save-and-new')), findsOneWidget);
          expect(find.byKey(const Key('editor-save-btn')), findsOneWidget);
          expect(find.byKey(const Key('save')), findsOneWidget);

          const osKeyboardTop = 640.0 - 280.0; // 360.0
          final dockRect = tester.getRect(
            find.byKey(const Key('editor-bottom-dock')),
          );
          expect(dockRect.bottom, closeTo(osKeyboardTop, 0.5));
          expect(
            tester.getRect(find.byKey(const Key('editor-pill-toolbar'))).bottom,
            lessThanOrEqualTo(osKeyboardTop),
          );
          expect(
            tester.getRect(find.byKey(const Key('remark'))).bottom,
            lessThanOrEqualTo(osKeyboardTop),
          );
          expect(
            tester.getRect(find.byKey(const Key('save'))).bottom,
            lessThanOrEqualTo(osKeyboardTop),
          );

          // Pending '12+8' can even be evaluated in-place right above the OS keyboard!
          expect(find.text('='), findsOneWidget);
          await tester.tap(find.byKey(const Key('editor-save-btn')));
          await tester.pump();
          expect(tester.takeException(), isNull);
          expect(
            tester
                .widget<TextField>(find.byKey(const Key('amount')))
                .controller!
                .text,
            '20.00',
          );
          expect(find.text('保存'), findsOneWidget);
          expect(find.byKey(const Key('record-custom-keypad')), findsNothing);

          // 2. Tap back on amount -> unfocuses remark, closes OS keyboard, re-opens custom keypad!
          await tester.tap(find.byKey(const Key('amount')));
          tester.view.viewInsets = FakeViewPadding.zero;
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);

          final remarkField = tester.widget<TextField>(
            find.byKey(const Key('remark')),
          );
          final amountField = tester.widget<TextField>(
            find.byKey(const Key('amount')),
          );
          expect(remarkField.focusNode?.hasFocus ?? false, isFalse);
          expect(amountField.focusNode!.hasFocus, isTrue);
          expect(find.byKey(const Key('record-custom-keypad')), findsOneWidget);

          // 3. Tap Key('keypad-hide') -> collapses custom keypad cleanly while keeping Key('save') reachable!
          await tester.tap(find.byKey(const Key('keypad-hide')));
          await tester.pump();
          expect(tester.takeException(), isNull);
          expect(find.byKey(const Key('record-custom-keypad')), findsNothing);
          expect(find.byKey(const Key('save')), findsOneWidget);
          expect(find.byKey(const Key('save-and-new')), findsOneWidget);

          // Tapping amount-tap-area re-opens custom keypad again!
          await tester.tap(find.byKey(const Key('amount-tap-area')));
          await tester.pump();
          expect(find.byKey(const Key('record-custom-keypad')), findsOneWidget);

          await closeCleanly();
        },
      );

      testWidgets(
        'smart = handles 10÷0 with error snackbar without blocking keypad, 再记一笔 / AppBar ✓ evaluate+save in 1 step, and tester.enterText compatibility works seamlessly',
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

          // 1. Division by zero '10÷0' via custom keypad -> tap '=' -> shows snackbar '算式无效或除数不能为 0'!
          await _tapKeys(tester, ['1', '0', '÷', '0']);
          expect(amountField.controller!.text, '10÷0');
          expect(find.text('='), findsOneWidget);
          expect(find.byKey(const Key('amount-live-preview')), findsNothing);

          await tester.tap(find.byKey(const Key('editor-save-btn')));
          await tester.pump();
          expect(find.text('算式无效或除数不能为 0'), findsOneWidget);
          expect(amountField.controller!.text, '10÷0');

          // 2. Immediately fix via custom keypad (BS -> '2' -> '10÷2') while snackbar was up,
          // then tap '再记一笔' -> evaluates '10÷2' and saves 5.00 in 1 step!
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

          // 4. Re-open and verify top-right AppBar '✓' evaluates '15×2' and saves 30.00 in 1 step!
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
        'frequentRemarks defaults OFF (hides chips & remarks button, shows clear button only when non-empty, skips recordRemarkUsage) and works when toggled ON',
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

          expect(find.byKey(const Key('frequent_remark_chips')), findsNothing);
          expect(find.text('预设拿铁'), findsNothing);
          expect(find.byKey(const Key('editor-remarks-btn')), findsNothing);
          expect(
            find.descendant(
              of: find.byKey(const Key('editor-pill-toolbar')),
              matching: find.text('常用备注'),
            ),
            findsNothing,
          );

          TextField remarkField() =>
              tester.widget<TextField>(find.byKey(const Key('remark')));
          expect(remarkField().decoration!.suffixIcon, isNull);

          await tester.enterText(find.byKey(const Key('remark')), '临时草稿');
          await tester.pump();
          expect(
            find.byKey(const Key('editor-remark-clear-btn')),
            findsOneWidget,
          );
          expect(find.byKey(const Key('editor-remarks-btn')), findsNothing);

          await tester.tap(find.byKey(const Key('editor-remark-clear-btn')));
          await tester.pump();
          expect(remarkField().controller!.text, isEmpty);
          expect(remarkField().decoration!.suffixIcon, isNull);

          // Save a bill with remark '默认关闭不统计' -> recordRemarkUsage MUST NOT be called!
          await tester.enterText(find.byKey(const Key('amount')), '18');
          await tester.enterText(find.byKey(const Key('remark')), '默认关闭不统计');
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

          expect(
            find.byKey(const Key('frequent_remark_chips')),
            findsOneWidget,
          );
          expect(find.text('预设拿铁'), findsOneWidget);
          expect(find.byKey(const Key('editor-remarks-btn')), findsOneWidget);

          await tester.enterText(find.byKey(const Key('amount')), '22');
          await tester.enterText(find.byKey(const Key('remark')), '开启后自动统计');
          await tester.pump();
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
    },
  );
}
