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

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('RecordEditorPage Inline Operators, Smart = / 保存 & Frequent Remarks Toggle', () {
    testWidgets(
      'focus-aware operator pills (+ − × ÷) render in the same action row, keep focus via TextFieldTapRegion, and hide when typing remarks without pending ops',
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

        // 1. Initially unfocused & empty: operator buttons hidden, primary button shows '保存'.
        expect(find.byKey(const Key('editor-op-add')), findsNothing);
        expect(find.byKey(const Key('editor-op-sub')), findsNothing);
        expect(find.byKey(const Key('editor-op-mul')), findsNothing);
        expect(find.byKey(const Key('editor-op-div')), findsNothing);
        expect(find.byKey(const Key('editor-save-btn')), findsOneWidget);
        expect(find.text('保存'), findsOneWidget);

        // 2. Focus amount -> 4 operator pills appear inside the SAME bottom row (zero 4th row!).
        await tester.tap(find.byKey(const Key('amount-tap-area')));
        await tester.pump();

        final amountField = tester.widget<TextField>(
          find.byKey(const Key('amount')),
        );
        expect(amountField.focusNode!.hasFocus, isTrue);

        expect(find.byKey(const Key('editor-op-add')), findsOneWidget);
        expect(find.byKey(const Key('editor-op-sub')), findsOneWidget);
        expect(find.byKey(const Key('editor-op-mul')), findsOneWidget);
        expect(find.byKey(const Key('editor-op-div')), findsOneWidget);

        final addCenterY = tester
            .getCenter(find.byKey(const Key('editor-op-add')))
            .dy;
        final saveAndNewCenterY = tester
            .getCenter(find.byKey(const Key('save-and-new')))
            .dy;
        final saveCenterY = tester
            .getCenter(find.byKey(const Key('editor-save-btn')))
            .dy;
        expect(addCenterY, closeTo(saveAndNewCenterY, 1.0));
        expect(addCenterY, closeTo(saveCenterY, 1.0));

        // 3. Empty input + '+' -> '0+', replacing '+' with '−' -> '0-', keeping _amountFocus!
        await tester.tap(find.byKey(const Key('editor-op-add')));
        await tester.pump();
        expect(amountField.controller!.text, '0+');
        expect(amountField.focusNode!.hasFocus, isTrue);
        expect(find.text('='), findsOneWidget);

        await tester.tap(find.byKey(const Key('editor-op-sub')));
        await tester.pump();
        expect(amountField.controller!.text, '0-');
        expect(amountField.focusNode!.hasFocus, isTrue);

        // 4. Trailing dot '12.' + '+' -> '12+', then replace with '×' -> '12×', then '÷' -> '12÷'!
        await tester.enterText(find.byKey(const Key('amount')), '12.');
        await tester.pump();
        await tester.tap(find.byKey(const Key('editor-op-add')));
        await tester.pump();
        expect(amountField.controller!.text, '12+');
        expect(amountField.focusNode!.hasFocus, isTrue);

        await tester.tap(find.byKey(const Key('editor-op-mul')));
        await tester.pump();
        expect(amountField.controller!.text, '12×');
        expect(amountField.focusNode!.hasFocus, isTrue);

        await tester.tap(find.byKey(const Key('editor-op-div')));
        await tester.pump();
        expect(amountField.controller!.text, '12÷');
        expect(amountField.focusNode!.hasFocus, isTrue);

        // 5. Focus remark while '12÷' has a pending operator -> operators & '=' remain visible!
        await tester.tap(find.byKey(const Key('remark')));
        await tester.pump();
        expect(amountField.focusNode!.hasFocus, isFalse);
        expect(find.byKey(const Key('editor-op-add')), findsOneWidget);
        expect(find.text('='), findsOneWidget);

        // 6. Tap '=' -> evaluates '12÷' in-place to '12.00'; since remark has focus and
        // hasPendingOperator('12.00') is false, operators hide cleanly and button flips to '保存'!
        await tester.tap(find.byKey(const Key('editor-save-btn')));
        await tester.pump();
        expect(amountField.controller!.text, '12.00');
        expect(find.byKey(const Key('editor-op-add')), findsNothing);
        expect(find.text('保存'), findsOneWidget);

        await closeCleanly();
      },
    );

    testWidgets(
      'narrow 360dp phone screen renders [+ − × ÷] + [再记一笔] + [= / 保存] with zero RenderFlex overflow above OS keyboard',
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

        // Focus amount with simulated 260px OS keyboard on a narrow 360dp viewport.
        await tester.tap(find.byKey(const Key('amount-tap-area')));
        tester.view.viewInsets = const FakeViewPadding(
          left: 0,
          top: 0,
          right: 0,
          bottom: 260,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        await tester.enterText(find.byKey(const Key('amount')), '128.5+36.5');
        await tester.pump();
        expect(tester.takeException(), isNull);

        for (final key in const <Key>[
          Key('editor-op-add'),
          Key('editor-op-sub'),
          Key('editor-op-mul'),
          Key('editor-op-div'),
          Key('save-and-new'),
          Key('editor-save-btn'),
        ]) {
          final rect = tester.getRect(find.byKey(key));
          expect(rect.left, greaterThanOrEqualTo(0.0));
          expect(rect.right, lessThanOrEqualTo(360.0));
          expect(rect.width, greaterThan(0.0));
        }

        // Evaluate in-place on 360dp -> '165.00', flips to '保存', still zero overflow!
        await tester.tap(find.byKey(const Key('editor-save-btn')));
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.text('保存'), findsOneWidget);

        tester.view.viewInsets = FakeViewPadding.zero;
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        await closeCleanly();
      },
    );

    testWidgets(
      'smart = evaluates in-place without popping, handles 10÷0 with error snackbar, and 再记一笔 / AppBar ✓ evaluate+save in 1 step',
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

        // 1. Enter '12.5+8' -> primary button shows '=' -> tap '=' -> evaluates to '20.50' in-place!
        await tester.enterText(find.byKey(const Key('amount')), '12.5');
        await tester.pump();
        await tester.tap(find.byKey(const Key('editor-op-add')));
        await tester.pump();
        await tester.enterText(find.byKey(const Key('amount')), '12.5+8');
        await tester.pump();

        final amountField = tester.widget<TextField>(
          find.byKey(const Key('amount')),
        );
        expect(find.text('='), findsOneWidget);
        expect(find.text('= 20.50'), findsOneWidget);

        await tester.tap(find.byKey(const Key('editor-save-btn')));
        await tester.pump();
        expect(amountField.controller!.text, '20.50');
        expect(amountField.focusNode!.hasFocus, isTrue);
        expect(find.text('保存'), findsOneWidget);
        // Page did NOT pop or save yet!
        final recordsAfterEq = await tester.runAsync(
          () => db.select(db.records).get(),
        );
        expect(recordsAfterEq, isEmpty);

        // 2. Division by zero '10÷0' -> tap '=' -> shows snackbar '算式无效或除数不能为 0' and keeps editing!
        await tester.enterText(find.byKey(const Key('amount')), '10');
        await tester.pump();
        await tester.tap(find.byKey(const Key('editor-op-div')));
        await tester.pump();
        await tester.enterText(find.byKey(const Key('amount')), '10÷0');
        await tester.pump();

        expect(find.text('='), findsOneWidget);
        expect(find.byKey(const Key('amount-live-preview')), findsNothing);

        await tester.tap(find.byKey(const Key('editor-save-btn')));
        await tester.pump();
        expect(find.text('算式无效或除数不能为 0'), findsOneWidget);
        expect(amountField.controller!.text, '10÷0');

        // 3. Immediately fix expression to '12.5+8' (snackbar clears & never blocks dock!)
        // and tap '再记一笔' -> evaluates '12.5+8' and saves 20.50 in 1 step!
        await tester.enterText(find.byKey(const Key('amount')), '12.5+8');
        await tester.pump();
        expect(find.text('='), findsOneWidget);
        await tester.tap(find.byKey(const Key('save-and-new')));
        await _settle(tester);

        expect(find.byKey(const Key('save-and-new-banner')), findsOneWidget);
        final afterFirst = await tester.runAsync(
          () => db.select(db.records).get(),
        );
        expect(afterFirst, hasLength(1));
        expect(afterFirst!.single.moneyMinor, BigInt.from(2050));

        // 4. Top-right AppBar '✓' evaluates '15×2' and saves 30.00 in 1 step!
        await tester.enterText(find.byKey(const Key('amount')), '15*2');
        await tester.pump();
        expect(find.text('='), findsOneWidget);
        await tester.tap(find.byKey(const Key('editor-quick-save-btn')));
        await _settle(tester);

        final afterSecond = await tester.runAsync(
          () => db.select(db.records).get(),
        );
        expect(afterSecond, hasLength(2));
        expect(afterSecond!.map((r) => r.moneyMinor).toSet(), {
          BigInt.from(2050),
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

        // FrequentRemarkChips and Key('editor-remarks-btn') are BOTH hidden!
        expect(find.byKey(const Key('frequent_remark_chips')), findsNothing);
        expect(find.text('预设拿铁'), findsNothing);
        expect(find.byKey(const Key('editor-remarks-btn')), findsNothing);
        // No redundant capsule in horizontal toolbar either.
        expect(
          find.descendant(
            of: find.byKey(const Key('editor-pill-toolbar')),
            matching: find.text('常用备注'),
          ),
          findsNothing,
        );

        // Empty remark -> suffixIcon is null; non-empty -> clear Icons.cancel button only!
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

        // Now FrequentRemarkChips AND Key('editor-remarks-btn') ARE shown!
        expect(find.byKey(const Key('frequent_remark_chips')), findsOneWidget);
        expect(find.text('预设拿铁'), findsOneWidget);
        expect(find.byKey(const Key('editor-remarks-btn')), findsOneWidget);

        // Save a bill with remark '开启后自动统计' -> recordRemarkUsage IS called!
        await tester.enterText(find.byKey(const Key('amount')), '22');
        await tester.enterText(find.byKey(const Key('remark')), '开启后自动统计');
        await tester.pump();
        await tester.tap(find.byKey(const Key('save')));
        await _settle(tester);

        final remarksWhenOn = await tester.runAsync(
          () => db.select(db.remarks).get(),
        );
        expect(
          remarksWhenOn!.any((r) => r.content == '开启后自动统计' && r.usedTimes == 1),
          isTrue,
        );

        await closeCleanly();
      },
    );
  });
}
