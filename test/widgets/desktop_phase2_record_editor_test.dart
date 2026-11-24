import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:tallyisle/data/tools/bill_attachment_service.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/features/backup/backup_providers.dart';
import 'package:tallyisle/features/records/desktop_record_editor_dialog.dart';
import 'package:tallyisle/features/records/record_editor_page.dart';
import 'package:tallyisle/features/records/record_keypad.dart';
import 'package:tallyisle/features/reminder/reminder_providers.dart';
import 'package:tallyisle/platform/notifications.dart';

Future<void> _settle(WidgetTester tester, [int ticks = 10]) async {
  await tester.pump();
  for (var i = 0; i < ticks; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

bool _hasFieldFocus(WidgetTester tester, Key fieldKey) {
  final editable = tester.widget<EditableText>(
    find.descendant(
      of: find.byKey(fieldKey),
      matching: find.byType(EditableText),
    ),
  );
  return editable.focusNode.hasFocus;
}

String _fieldText(WidgetTester tester, Key fieldKey) {
  return tester.widget<TextField>(find.byKey(fieldKey)).controller!.text;
}

Rect _dialogSurfaceRect(WidgetTester tester, Finder dialogFinder) {
  return tester.getRect(
    find.descendant(of: dialogFinder, matching: find.byType(Material)).first,
  );
}

Future<void> _sendShiftedKey(
  WidgetTester tester,
  LogicalKeyboardKey key,
) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
}

Future<void> _sendCtrlEnter(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
}

Future<void> _sendMetaEnter(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
}

Future<void> _sendShiftTab(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.tab);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets(
    'Desktop modal dialog opens from sidebar & Ctrl+N (600px borderless, barrierDismissible:false), collapses 4x4 keypad by default, toggles desktop-toggle-keypad without overflow, and closes on Esc',
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final db = AppDatabase(NativeDatabase.memory());
      final reminderScheduler = InMemoryReminderScheduler();
      final tempRoot = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('desk_p2_modal_'),
      ))!;

      await tester.runAsync(() async {
        final attSvc = BillAttachmentService(db);
        final cfg = await attSvc.getDiyToolbarConfig();
        await attSvc.saveDiyToolbarConfig(
          commandId: 'enable-freq-remarks-p2',
          config: cfg.setEnabled(DiyToolbarAction.frequentRemarks, true),
        );
      });

      var closed = false;
      Future<void> cleanUp() async {
        if (closed) return;
        closed = true;
        await tester.pumpWidget(const SizedBox.shrink());
        await _settle(tester, 4);
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(reminderScheduler.dispose);
        await tester.runAsync(db.close);
        await tester.runAsync(() async {
          if (await tempRoot.exists()) {
            await tempRoot.delete(recursive: true);
          }
        });
      }

      addTearDown(cleanUp);

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            reminderSchedulerProvider.overrideWithValue(reminderScheduler),
            backupLocalDirectoryOverrideProvider.overrideWithValue(
              () async => Directory(p.join(tempRoot.path, 'local')),
            ),
            backupAttachmentsDirectoryOverrideProvider.overrideWithValue(
              () async => Directory(p.join(tempRoot.path, 'att')),
            ),
          ],
          child: const TallyIsleApp(),
        ),
      );
      await _settle(tester);
      expect(tester.takeException(), isNull);

      // 1. Click sidebar "记一笔" -> opens 600px centered borderless modal dialog
      await tester.tap(find.byKey(const Key('add-record')));
      await _settle(tester);
      expect(tester.takeException(), isNull);

      final dialogFinder = find.byKey(
        const Key('desktop-record-editor-dialog'),
      );
      expect(dialogFinder, findsOneWidget);
      final dialogWidget = tester.widget<Dialog>(dialogFinder);
      expect(
        dialogWidget.shape,
        const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(20)),
          side: BorderSide.none,
        ),
      );
      final dialogRect = _dialogSurfaceRect(tester, dialogFinder);
      expect(dialogRect.width, closeTo(600.0, 1.0));
      expect(
        dialogRect.height,
        lessThanOrEqualTo(kDesktopRecordDialogMaxHeight),
      );
      expect(dialogRect.center.dx, closeTo(640.0, 1.0));

      // barrierDismissible: false -> tapping outside scrim must NOT dismiss dialog
      await tester.tapAt(const Offset(24, 24));
      await _settle(tester, 4);
      expect(dialogFinder, findsOneWidget);

      // 2. Virtual 4x4 keypad is collapsed by default; compact action bar is shown;
      // amount field is auto-focused immediately!
      expect(find.byKey(const Key('record-custom-keypad')), findsNothing);
      expect(
        find.byKey(const Key('desktop-editor-action-bar')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('desktop-toggle-remarks')), findsOneWidget);
      expect(find.byKey(const Key('desktop-toggle-keypad')), findsOneWidget);
      expect(find.byKey(const Key('desktop-save-and-again')), findsOneWidget);
      expect(find.byKey(const Key('desktop-save-button')), findsOneWidget);
      expect(find.text('再记 (Ctrl+Enter)'), findsOneWidget);
      expect(find.text('保存 (Enter)'), findsOneWidget);
      expect(_hasFieldFocus(tester, const Key('amount')), isTrue);

      // 3. Toggle virtual 4x4 keypad open and closed via desktop-toggle-keypad
      await tester.tap(find.byKey(const Key('desktop-toggle-keypad')));
      await _settle(tester, 4);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('record-custom-keypad')), findsOneWidget);

      // Verify zero overflow across medium (900x700), short (1280x600), and narrow (520x600) viewports
      for (final size in const <Size>[
        Size(900, 700),
        Size(1280, 600),
        Size(520, 600),
        Size(1280, 800),
      ]) {
        tester.view.physicalSize = size;
        await _settle(tester, 3);
        expect(tester.takeException(), isNull, reason: 'No overflow at $size');
      }

      // Collapse virtual keypad again
      await tester.tap(find.byKey(const Key('desktop-toggle-keypad')));
      await _settle(tester, 4);
      expect(find.byKey(const Key('record-custom-keypad')), findsNothing);

      // Toggle frequent remarks panel on desktop action bar
      await tester.tap(find.byKey(const Key('desktop-toggle-remarks')));
      await _settle(tester, 4);
      expect(
        find.byKey(const Key('editor-frequent-remarks-panel')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('desktop-toggle-remarks')));
      await _settle(tester, 4);
      expect(
        find.byKey(const Key('editor-frequent-remarks-panel')),
        findsNothing,
      );

      // 4. Esc closes modal dialog when no child popup is open
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester, 6);
      expect(dialogFinder, findsNothing);

      // 5. Global Ctrl+N also opens the centered desktop modal dialog
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await _settle(tester);
      expect(dialogFinder, findsOneWidget);
      expect(_hasFieldFocus(tester, const Key('amount')), isTrue);

      await cleanUp();
    },
  );

  testWidgets(
    'Physical keyboard blind-typing arithmetic flow: two-stage Enter evaluates expression in-place (60.00 & DR-002 sequential 35+12.5*2 -> 95.00) before saving to DB, plus =, Backspace, and Delete',
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final db = AppDatabase(NativeDatabase.memory());
      final reminderScheduler = InMemoryReminderScheduler();
      final tempRoot = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('desk_p2_calc_'),
      ))!;

      var closed = false;
      Future<void> cleanUp() async {
        if (closed) return;
        closed = true;
        await tester.pumpWidget(const SizedBox.shrink());
        await _settle(tester, 4);
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(reminderScheduler.dispose);
        await tester.runAsync(db.close);
        await tester.runAsync(() async {
          if (await tempRoot.exists()) {
            await tempRoot.delete(recursive: true);
          }
        });
      }

      addTearDown(cleanUp);

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            reminderSchedulerProvider.overrideWithValue(reminderScheduler),
            backupLocalDirectoryOverrideProvider.overrideWithValue(
              () async => Directory(p.join(tempRoot.path, 'local')),
            ),
            backupAttachmentsDirectoryOverrideProvider.overrideWithValue(
              () async => Directory(p.join(tempRoot.path, 'att')),
            ),
          ],
          child: const TallyIsleApp(),
        ),
      );
      await _settle(tester);

      // Open desktop editor dialog and select category '餐饮'
      await tester.tap(find.byKey(const Key('add-record')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('cat-餐饮')));
      await tester.pump();
      expect(_hasFieldFocus(tester, const Key('amount')), isTrue);

      // 1. Type `12.5*2+35` using mix of main keyboard and numpad keys -> evaluates to 60.00!
      for (final key in const <LogicalKeyboardKey>[
        LogicalKeyboardKey.digit1,
        LogicalKeyboardKey.numpad2,
        LogicalKeyboardKey.period,
        LogicalKeyboardKey.numpad5,
        LogicalKeyboardKey.numpadMultiply,
        LogicalKeyboardKey.digit2,
        LogicalKeyboardKey.numpadAdd,
        LogicalKeyboardKey.digit3,
        LogicalKeyboardKey.numpad5,
      ]) {
        await tester.sendKeyEvent(key);
      }
      await tester.pump();

      expect(_fieldText(tester, const Key('amount')), '12.5×2+35');
      expect(find.byKey(const Key('amount-live-preview')), findsOneWidget);
      expect(find.text('= 60.00'), findsOneWidget);
      // Primary button switches from '保存 (Enter)' to '= (Enter)' while hasOperator is true
      expect(
        find.descendant(
          of: find.byKey(const Key('desktop-save-button')),
          matching: find.text('= (Enter)'),
        ),
        findsOneWidget,
      );

      // First Enter: evaluates in-place to '60.00' WITHOUT closing the dialog!
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _settle(tester, 4);
      expect(
        find.byKey(const Key('desktop-record-editor-dialog')),
        findsOneWidget,
      );
      expect(_fieldText(tester, const Key('amount')), '60.00');
      expect(find.byKey(const Key('amount-live-preview')), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const Key('desktop-save-button')),
          matching: find.text('保存 (Enter)'),
        ),
        findsOneWidget,
      );

      // Second Enter (numpadEnter): saves 60.00 to DB and closes the dialog!
      await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);
      await _settle(tester, 8);
      expect(
        find.byKey(const Key('desktop-record-editor-dialog')),
        findsNothing,
      );

      final savedAfterFirst = await tester.runAsync(
        () => db.select(db.records).get(),
      );
      expect(savedAfterFirst, hasLength(1));
      expect(savedAfterFirst!.single.moneyMinor, BigInt.from(6000));

      // 2. Re-open dialog: test Delete (clear), Backspace, `=`, `/` -> `÷`, and `35+12.5*2` (DR-002 left-to-right -> 95.00)
      await tester.tap(find.byKey(const Key('add-record')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('cat-餐饮')));
      await tester.pump();

      // Type '99/3', press '=' -> '33.00', then press Delete -> ''
      for (final key in const <LogicalKeyboardKey>[
        LogicalKeyboardKey.digit9,
        LogicalKeyboardKey.digit9,
        LogicalKeyboardKey.slash,
        LogicalKeyboardKey.digit3,
      ]) {
        await tester.sendKeyEvent(key);
      }
      await tester.pump();
      expect(_fieldText(tester, const Key('amount')), '99÷3');

      await tester.sendKeyEvent(LogicalKeyboardKey.equal);
      await tester.pump();
      expect(_fieldText(tester, const Key('amount')), '33.00');

      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();
      expect(_fieldText(tester, const Key('amount')), isEmpty);

      // Type `35+12.5*29` using laptop Shift+= ('+') and Shift+8 ('*'), then Backspace -> `35+12.5×2`
      await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit5);
      await _sendShiftedKey(tester, LogicalKeyboardKey.equal); // '+'
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.sendKeyEvent(LogicalKeyboardKey.numpadDecimal);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit5);
      await _sendShiftedKey(tester, LogicalKeyboardKey.digit8); // '*' -> '×'
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit9);
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      expect(_fieldText(tester, const Key('amount')), '35+12.5×2');
      expect(find.text('= 95.00'), findsOneWidget);

      // Stage 1 Enter -> '95.00' (dialog stays open)
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _settle(tester, 4);
      expect(
        find.byKey(const Key('desktop-record-editor-dialog')),
        findsOneWidget,
      );
      expect(_fieldText(tester, const Key('amount')), '95.00');

      // Stage 2 Enter -> saves 95.00 and closes
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _settle(tester, 8);
      expect(
        find.byKey(const Key('desktop-record-editor-dialog')),
        findsNothing,
      );

      final allRecords = await tester.runAsync(
        () => db.select(db.records).get(),
      );
      expect(allRecords, hasLength(2));
      expect(
        allRecords!.map((r) => r.moneyMinor).toSet(),
        equals(<BigInt>{BigInt.from(6000), BigInt.from(9500)}),
      );

      await cleanUp();
    },
  );

  testWidgets(
    'Ctrl/Cmd+Enter saves and resets with auto-refocus on amount, while Tab / Shift+Tab cycles Amount <-> (Fee) <-> Remark cleanly',
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final db = AppDatabase(NativeDatabase.memory());
      final reminderScheduler = InMemoryReminderScheduler();
      final tempRoot = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('desk_p2_tab_'),
      ))!;

      var closed = false;
      Future<void> cleanUp() async {
        if (closed) return;
        closed = true;
        await tester.pumpWidget(const SizedBox.shrink());
        await _settle(tester, 4);
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(reminderScheduler.dispose);
        await tester.runAsync(db.close);
        await tester.runAsync(() async {
          if (await tempRoot.exists()) {
            await tempRoot.delete(recursive: true);
          }
        });
      }

      addTearDown(cleanUp);

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            reminderSchedulerProvider.overrideWithValue(reminderScheduler),
            backupLocalDirectoryOverrideProvider.overrideWithValue(
              () async => Directory(p.join(tempRoot.path, 'local')),
            ),
            backupAttachmentsDirectoryOverrideProvider.overrideWithValue(
              () async => Directory(p.join(tempRoot.path, 'att')),
            ),
          ],
          child: const TallyIsleApp(),
        ),
      );
      await _settle(tester);

      await tester.tap(find.byKey(const Key('add-record')));
      await _settle(tester);
      expect(find.text('再记 (⌘+Enter)'), findsOneWidget);

      await tester.tap(find.byKey(const Key('cat-餐饮')));
      await tester.pump();

      // 1. Type `40+15` and press Cmd+Enter -> auto-evaluates 55.00, saves, clears & re-focuses amount!
      for (final key in const <LogicalKeyboardKey>[
        LogicalKeyboardKey.digit4,
        LogicalKeyboardKey.digit0,
        LogicalKeyboardKey.numpadAdd,
        LogicalKeyboardKey.digit1,
        LogicalKeyboardKey.digit5,
      ]) {
        await tester.sendKeyEvent(key);
      }
      await tester.pump();
      expect(_fieldText(tester, const Key('amount')), '40+15');

      await _sendMetaEnter(tester);
      await _settle(tester, 8);

      // Dialog stays open, amount cleared, confirmation banner shown, keypad still collapsed, amount focused!
      expect(
        find.byKey(const Key('desktop-record-editor-dialog')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('save-and-new-banner')), findsOneWidget);
      expect(find.byKey(const Key('record-custom-keypad')), findsNothing);
      expect(_fieldText(tester, const Key('amount')), isEmpty);
      expect(_hasFieldFocus(tester, const Key('amount')), isTrue);

      // 2. Immediately blind-type `28` without clicking, then press Tab -> moves focus to Remark!
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit8);
      await tester.pump();
      expect(_fieldText(tester, const Key('amount')), '28');

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_hasFieldFocus(tester, const Key('remark')), isTrue);
      expect(_hasFieldFocus(tester, const Key('amount')), isFalse);

      // While focused in Remark, hardware digits / '+' must NOT hijack or mutate Amount!
      await tester.sendKeyEvent(LogicalKeyboardKey.digit9);
      await tester.sendKeyEvent(LogicalKeyboardKey.numpadAdd);
      await tester.pump();
      expect(_fieldText(tester, const Key('amount')), '28');

      await tester.enterText(find.byKey(const Key('remark')), '咖啡2杯+甜点');
      await tester.pump();
      expect(_fieldText(tester, const Key('remark')), '咖啡2杯+甜点');

      // Ctrl+Enter while STILL focused in Remark saves & resets and re-focuses Amount!
      await _sendCtrlEnter(tester);
      await _settle(tester, 8);
      expect(_fieldText(tester, const Key('amount')), isEmpty);
      expect(_fieldText(tester, const Key('remark')), isEmpty);
      expect(_hasFieldFocus(tester, const Key('amount')), isTrue);

      final savedTwo = await tester.runAsync(() => db.select(db.records).get());
      expect(savedTwo, hasLength(2));
      expect(
        savedTwo!.map((r) => (r.moneyMinor, r.remark)).toSet(),
        equals(<(BigInt, String)>{
          (BigInt.from(5500), ''),
          (BigInt.from(2800), '咖啡2杯+甜点'),
        }),
      );

      // 3. Switch to Transfer mode -> Tab cycles Amount -> Fee -> Remark -> Amount, Shift+Tab reverses!
      await tester.tap(find.byKey(const Key('type-2')));
      await _settle(tester, 3);
      expect(_hasFieldFocus(tester, const Key('amount')), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_hasFieldFocus(tester, const Key('fee')), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_hasFieldFocus(tester, const Key('remark')), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_hasFieldFocus(tester, const Key('amount')), isTrue);

      await _sendShiftTab(tester);
      await tester.pump();
      expect(_hasFieldFocus(tester, const Key('remark')), isTrue);

      await _sendShiftTab(tester);
      await tester.pump();
      expect(_hasFieldFocus(tester, const Key('fee')), isTrue);

      await cleanUp();
    },
  );

  testWidgets(
    'Desktop centered 420px Dialog pickers (Account, Tags, Currency — zero BottomSheet), child Esc isolation, DesktopRecordDialogPage & initialRecordTimeMs, and direct 620px route',
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final db = AppDatabase(NativeDatabase.memory());
      late int cashAssetId;
      final customDate = DateTime(2026, 5, 20, 12, 30);

      await tester.runAsync(() async {
        final catalog = CatalogService(db);
        cashAssetId = await LedgerService(db).createAsset(
          commandId: 'seed-cash-p2',
          name: '日常钱包',
          type: AssetType.normal,
          currency: 'CNY',
          initial: Money.parse('1000.00'),
        );
        await catalog.createTag(commandId: 'seed-tag-p2', name: '差旅');
        await CurrencyService(db).saveCurrency(
          commandId: 'seed-usd-p2',
          code: 'USD',
          name: '美元',
          symbol: r'$',
          price: '7.20',
        );
        final attSvc = BillAttachmentService(db);
        final cfg = await attSvc.getDiyToolbarConfig();
        await attSvc.saveDiyToolbarConfig(
          commandId: 'enable-curr-tags-p2',
          config: cfg
              .setEnabled(DiyToolbarAction.currency, true)
              .setEnabled(DiyToolbarAction.tags, true),
        );
      });

      var closed = false;
      Future<void> cleanUp() async {
        if (closed) return;
        closed = true;
        await tester.pumpWidget(const SizedBox.shrink());
        await _settle(tester, 4);
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(db.close);
      }

      addTearDown(cleanUp);

      final testRouter = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(
            path: '/',
            builder: (context, _) => Scaffold(
              body: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FilledButton(
                      key: const Key('open-page-dialog'),
                      onPressed: () => context.push(
                        '/record/new?time=${customDate.millisecondsSinceEpoch}',
                      ),
                      child: const Text('Open Modal Route'),
                    ),
                    OutlinedButton(
                      key: const Key('open-direct-route'),
                      onPressed: () => context.push('/record/direct'),
                      child: const Text('Open Direct Route'),
                    ),
                  ],
                ),
              ),
            ),
          ),
          GoRoute(
            path: '/record/new',
            pageBuilder: (_, state) => DesktopRecordDialogPage<String>(
              key: state.pageKey,
              initialRecordTimeMs: int.tryParse(
                state.uri.queryParameters['time'] ?? '',
              ),
            ),
          ),
          GoRoute(
            path: '/record/direct',
            builder: (_, _) => const RecordEditorPage(),
          ),
        ],
      );
      addTearDown(testRouter.dispose);

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: MaterialApp.router(
            theme: ThemeData(
              useMaterial3: true,
              brightness: Brightness.dark,
              colorSchemeSeed: const Color(0xFF0F766E),
            ),
            routerConfig: testRouter,
          ),
        ),
      );
      await _settle(tester);

      // 1. Direct route renders centered 620px desktop layout with full keyboard support
      await tester.tap(find.byKey(const Key('open-direct-route')));
      await _settle(tester);
      expect(
        find.byKey(const Key('desktop-editor-action-bar')),
        findsOneWidget,
      );
      final actionBarWidth = tester
          .getSize(find.byKey(const Key('desktop-editor-action-bar')))
          .width;
      expect(actionBarWidth, closeTo(620.0, 1.0));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester, 4);

      // 2. Open DesktopRecordDialogPage with initialRecordTimeMs
      await tester.tap(find.byKey(const Key('open-page-dialog')));
      await _settle(tester);
      expect(
        find.byKey(const Key('desktop-record-editor-dialog')),
        findsOneWidget,
      );
      expect(find.textContaining('05-20 12:30'), findsOneWidget);

      await tester.tap(find.byKey(const Key('cat-餐饮')));
      await tester.pump();

      // 3. Account picker -> centered compact Dialog (maxWidth <= 420), zero BottomSheet!
      await tester.tap(find.byKey(const Key('asset')));
      await _settle(tester, 4);
      expect(find.byType(BottomSheet), findsNothing);
      final acctDialog = find.byKey(const Key('desktop-account-picker-dialog'));
      expect(acctDialog, findsOneWidget);
      expect(
        _dialogSurfaceRect(tester, acctDialog).width,
        lessThanOrEqualTo(420.0),
      );

      // Pressing Esc while child Account Dialog is open closes ONLY the child dialog!
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester, 4);
      expect(acctDialog, findsNothing);
      expect(
        find.byKey(const Key('desktop-record-editor-dialog')),
        findsOneWidget,
      );

      // Re-open Account Dialog and pick '日常钱包'
      await tester.tap(find.byKey(const Key('asset')));
      await _settle(tester, 4);
      await tester.tap(find.text('日常钱包'));
      await _settle(tester, 4);
      expect(find.text('日常钱包'), findsOneWidget);
      expect(_hasFieldFocus(tester, const Key('amount')), isTrue);

      // 4. Tag picker -> centered compact Dialog (maxWidth <= 420), zero BottomSheet!
      await tester.tap(find.byKey(const Key('editor-tags-pill')));
      await _settle(tester, 4);
      expect(find.byType(BottomSheet), findsNothing);
      final tagDialog = find.byKey(const Key('desktop-tag-picker-dialog'));
      expect(tagDialog, findsOneWidget);
      expect(
        _dialogSurfaceRect(tester, tagDialog).width,
        lessThanOrEqualTo(420.0),
      );
      await tester.tap(find.byKey(const Key('tag-差旅')));
      await tester.pump();
      await tester.tap(find.text('完成'));
      await _settle(tester, 4);

      // 5. Currency picker -> centered compact Dialog (maxWidth <= 420), zero BottomSheet!
      await tester.tap(find.byKey(const Key('editor-currency-pill')));
      await _settle(tester, 4);
      expect(find.byType(BottomSheet), findsNothing);
      final currDialog = find.byKey(
        const Key('desktop-currency-picker-dialog'),
      );
      expect(currDialog, findsOneWidget);
      expect(
        _dialogSurfaceRect(tester, currDialog).width,
        lessThanOrEqualTo(420.0),
      );
      await tester.tap(find.byKey(const Key('currency-option-USD')));
      await _settle(tester, 4);

      // Type 10 USD via physical keyboard -> live CNY conversion preview (10 * 7.20 = 72.00)
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
      await tester.pump();
      expect(find.textContaining('72.00'), findsOneWidget);

      // Enter saves directly (no pending operator) and closes modal dialog route
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _settle(tester, 8);
      expect(
        find.byKey(const Key('desktop-record-editor-dialog')),
        findsNothing,
      );

      final saved = await tester.runAsync(() async {
        final rows = await db.select(db.records).get();
        final tagLinks = await db.select(db.tagRecords).get();
        return (rows, tagLinks);
      });
      final (rows, tagLinks) = saved!;
      expect(rows, hasLength(1));
      expect(rows.single.assetId, cashAssetId);
      expect(rows.single.moneyMinor, BigInt.from(7200));
      expect(rows.single.recordTime, customDate.millisecondsSinceEpoch);
      expect(rows.single.accountBookId, defaultBookId);
      expect(tagLinks, hasLength(1));

      await cleanUp();
    },
  );

  testWidgets(
    'App router wires /record/new (?time & ?assetId) and /record/:id/edit to 600px DesktopRecordDialogPage across Calendar, Assets, and Home',
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final db = AppDatabase(NativeDatabase.memory());
      final reminderScheduler = InMemoryReminderScheduler();
      final tempRoot = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('desk_p2_router_'),
      ))!;

      late int bankAssetId;
      await tester.runAsync(() async {
        bankAssetId = await LedgerService(db).createAsset(
          commandId: 'seed-bank-router',
          name: '测试储蓄卡',
          type: AssetType.normal,
          currency: 'CNY',
          initial: Money.parse('2000.00'),
        );
      });

      var closed = false;
      Future<void> cleanUp() async {
        if (closed) return;
        closed = true;
        await tester.pumpWidget(const SizedBox.shrink());
        await _settle(tester, 4);
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(reminderScheduler.dispose);
        await tester.runAsync(db.close);
        await tester.runAsync(() async {
          if (await tempRoot.exists()) {
            await tempRoot.delete(recursive: true);
          }
        });
      }

      addTearDown(cleanUp);

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            reminderSchedulerProvider.overrideWithValue(reminderScheduler),
            backupLocalDirectoryOverrideProvider.overrideWithValue(
              () async => Directory(p.join(tempRoot.path, 'local')),
            ),
            backupAttachmentsDirectoryOverrideProvider.overrideWithValue(
              () async => Directory(p.join(tempRoot.path, 'att')),
            ),
          ],
          child: const TallyIsleApp(),
        ),
      );
      await _settle(tester);

      // 1. Open Calendar from sidebar -> click "+ 补记该日账单" -> opens 600px modal dialog
      await tester.tap(find.byKey(const Key('desktop-nav-calendar')));
      await _settle(tester);
      expect(find.byKey(const Key('calendar-add-for-day')), findsOneWidget);
      await tester.tap(find.byKey(const Key('calendar-add-for-day')));
      await _settle(tester);

      final dialogFinder = find.byKey(
        const Key('desktop-record-editor-dialog'),
      );
      expect(dialogFinder, findsOneWidget);
      expect(
        _dialogSurfaceRect(tester, dialogFinder).width,
        closeTo(600.0, 1.0),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester, 6);
      expect(dialogFinder, findsNothing);

      // 2. Navigate via router to `/record/new?assetId=<bankAssetId>` -> pre-selects account in 600px modal
      final router = GoRouter.of(
        tester.element(find.byKey(const Key('calendar-desktop-split'))),
      );
      router.go('/');
      await _settle(tester);

      unawaited(router.push('/record/new?assetId=$bankAssetId'));
      await _settle(tester);
      expect(dialogFinder, findsOneWidget);
      expect(find.text('测试储蓄卡'), findsOneWidget);

      await tester.tap(find.byKey(const Key('cat-餐饮')));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.digit4);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _settle(tester, 8);
      expect(dialogFinder, findsNothing);

      final records = await tester.runAsync(() => db.select(db.records).get());
      expect(records, hasLength(1));
      final savedId = records!.single.recordId;
      expect(records.single.assetId, bankAssetId);
      expect(records.single.moneyMinor, BigInt.from(4200));

      // 3. Edit existing record via `/record/:id/edit` -> opens 600px modal dialog and updates amount
      unawaited(router.push('/record/$savedId/edit'));
      await _settle(tester);
      expect(dialogFinder, findsOneWidget);
      expect(
        _dialogSurfaceRect(tester, dialogFinder).width,
        closeTo(600.0, 1.0),
      );
      expect(_fieldText(tester, const Key('amount')), '42.00');

      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit8);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit8);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _settle(tester, 8);
      expect(dialogFinder, findsNothing);

      final updated = await tester.runAsync(() => db.select(db.records).get());
      expect(updated!.single.moneyMinor, BigInt.from(8800));

      await cleanUp();
    },
  );

  testWidgets(
    'Desktop remark row vertically centers left icon, EditableText, and clear button (dy diff <= 1.5px), and expanded keypad with all 8+ wrapped pills keeps summary-amount-row, amount, remark, keypad, and action-bar 100% visible without overlap at 1280x800 and 520x600',
    variant: const TargetPlatformVariant(<TargetPlatform>{
      TargetPlatform.linux,
      TargetPlatform.windows,
      TargetPlatform.macOS,
    }),
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final db = AppDatabase(NativeDatabase.memory());
      final reminderScheduler = InMemoryReminderScheduler();
      final tempRoot = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('desk_p2_geom_fix_'),
      ))!;

      await tester.runAsync(() async {
        await CurrencyService(db).saveCurrency(
          commandId: 'seed-usd-geom-fix',
          code: 'USD',
          name: '美元',
          symbol: r'$',
          price: '7.20',
        );
        final attSvc = BillAttachmentService(db);
        final baseCfg = await attSvc.getDiyToolbarConfig();
        // Enable all toolbar actions (except autoSelectFirstCategory so we also
        // verify the "请选择分类  ¥ 14" summary state explicitly).
        final allPillsConfig = DiyToolbarConfig.normalize([
          for (final item in baseCfg.items)
            item.copyWith(
              enabled: item.action != DiyToolbarAction.autoSelectFirstCategory,
            ),
        ]);
        await attSvc.saveDiyToolbarConfig(
          commandId: 'enable-all-8-pills-geom',
          config: allPillsConfig,
        );
      });

      var closed = false;
      Future<void> cleanUp() async {
        if (closed) return;
        closed = true;
        await tester.pumpWidget(const SizedBox.shrink());
        await _settle(tester, 4);
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(reminderScheduler.dispose);
        await tester.runAsync(db.close);
        await tester.runAsync(() async {
          if (await tempRoot.exists()) {
            await tempRoot.delete(recursive: true);
          }
        });
      }

      addTearDown(cleanUp);

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            reminderSchedulerProvider.overrideWithValue(reminderScheduler),
            backupLocalDirectoryOverrideProvider.overrideWithValue(
              () async => Directory(p.join(tempRoot.path, 'local')),
            ),
            backupAttachmentsDirectoryOverrideProvider.overrideWithValue(
              () async => Directory(p.join(tempRoot.path, 'att')),
            ),
          ],
          child: const TallyIsleApp(),
        ),
      );
      await _settle(tester);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const Key('add-record')));
      await _settle(tester);
      expect(tester.takeException(), isNull);

      // ---------------------------------------------------------------------
      // Regression 1: Remark row left icon, EditableText, and right clear
      // button share horizontal center (pairwise dy diff <= 1.5px).
      // ---------------------------------------------------------------------
      final remarkRowFinder = find.byKey(const Key('editor-remark-row'));
      final leftNoteIconFinder = find.descendant(
        of: remarkRowFinder,
        matching: find.byIcon(Icons.edit_note_rounded),
      );
      final remarkEditableFinder = find.descendant(
        of: find.byKey(const Key('remark')),
        matching: find.byType(EditableText),
      );

      // Check empty hint state alignment first
      final emptyIconDy = tester.getCenter(leftNoteIconFinder).dy;
      final emptyEditableDy = tester.getCenter(remarkEditableFinder).dy;
      expect((emptyIconDy - emptyEditableDy).abs(), lessThanOrEqualTo(1.5));

      // Enter '午饭' so the right clear button ('editor-remark-clear-btn') appears
      await tester.enterText(find.byKey(const Key('remark')), '午饭');
      await tester.pump();
      expect(tester.takeException(), isNull);

      final clearBtnFinder = find.byKey(const Key('editor-remark-clear-btn'));
      expect(clearBtnFinder, findsOneWidget);

      final iconDy = tester.getCenter(leftNoteIconFinder).dy;
      final editableDy = tester.getCenter(remarkEditableFinder).dy;
      final clearBtnDy = tester.getCenter(clearBtnFinder).dy;

      expect(
        (iconDy - editableDy).abs(),
        lessThanOrEqualTo(1.5),
        reason: 'Left icon dy ($iconDy) vs EditableText dy ($editableDy)',
      );
      expect(
        (editableDy - clearBtnDy).abs(),
        lessThanOrEqualTo(1.5),
        reason:
            'EditableText dy ($editableDy) vs Clear button dy ($clearBtnDy)',
      );
      expect(
        (iconDy - clearBtnDy).abs(),
        lessThanOrEqualTo(1.5),
        reason: 'Left icon dy ($iconDy) vs Clear button dy ($clearBtnDy)',
      );

      // ---------------------------------------------------------------------
      // Regression 2: With all 8+ pills enabled (wrapped to >= 2 rows including
      // '不计收支'), enter amount '14' and expand 'desktop-toggle-keypad' across
      // both 1280x800 and compact 520x600 viewports.
      // ---------------------------------------------------------------------
      expect(find.byKey(const Key('editor-exclude-exin-pill')), findsOneWidget);
      final firstPillDy = tester.getCenter(find.byKey(const Key('asset'))).dy;
      final lastPillDy = tester
          .getCenter(find.byKey(const Key('editor-exclude-exin-pill')))
          .dy;
      expect(
        lastPillDy - firstPillDy,
        greaterThan(16.0),
        reason: 'All 8+ toolbar pills should wrap onto at least 2 rows',
      );

      // Focus amount, input '14', and expand virtual keypad
      await tester.tap(find.byKey(const Key('amount')));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit4);
      await tester.pump();
      expect(_fieldText(tester, const Key('amount')), '14');
      expect(find.text('请选择分类'), findsOneWidget);

      await tester.tap(find.byKey(const Key('desktop-toggle-keypad')));
      await _settle(tester, 4);
      expect(tester.takeException(), isNull);
      expect(find.byType(RecordCustomKeypad), findsOneWidget);

      void expectInsideRect(Rect inner, Rect outer, String name, Size vp) {
        expect(
          inner.left,
          greaterThanOrEqualTo(outer.left - 0.5),
          reason: '$name.left outside dialog at $vp',
        );
        expect(
          inner.right,
          lessThanOrEqualTo(outer.right + 0.5),
          reason: '$name.right outside dialog at $vp',
        );
        expect(
          inner.top,
          greaterThanOrEqualTo(outer.top - 0.5),
          reason: '$name.top outside dialog at $vp',
        );
        expect(
          inner.bottom,
          lessThanOrEqualTo(outer.bottom + 0.5),
          reason: '$name.bottom outside dialog at $vp',
        );
      }

      for (final viewport in const <Size>[Size(1280, 800), Size(520, 600)]) {
        tester.view.physicalSize = viewport;
        await _settle(tester, 4);
        expect(
          tester.takeException(),
          isNull,
          reason: 'No overflow at $viewport',
        );

        final dialogRect = _dialogSurfaceRect(
          tester,
          find.byKey(const Key('desktop-record-editor-dialog')),
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
        final amountRect = tester.getRect(find.byKey(const Key('amount')));
        final remarkRect = tester.getRect(
          find.byKey(const Key('editor-remark-row')),
        );
        final pillRect = tester.getRect(
          find.byKey(const Key('editor-pill-toolbar')),
        );
        final slotRect = tester.getRect(
          find.byKey(const Key('editor-bottom-panel-slot')),
        );
        final keypadRect = tester.getRect(find.byType(RecordCustomKeypad));
        final actionBarRect = tester.getRect(
          find.byKey(const Key('desktop-editor-action-bar')),
        );

        // Middle category grid retains >= 120px visible scroll height
        expect(
          zone2Rect.height,
          greaterThanOrEqualTo(120.0),
          reason:
              'Category grid height (${zone2Rect.height}) < 120px at $viewport',
        );

        // Every critical section is 100% inside the visible dialog surface
        expectInsideRect(
          summaryRect,
          dialogRect,
          'summary-amount-row',
          viewport,
        );
        expectInsideRect(amountRect, dialogRect, 'amount', viewport);
        expectInsideRect(remarkRect, dialogRect, 'remark-row', viewport);
        expectInsideRect(pillRect, dialogRect, 'pill-toolbar', viewport);
        expectInsideRect(
          keypadRect,
          dialogRect,
          'RecordCustomKeypad',
          viewport,
        );
        expectInsideRect(actionBarRect, dialogRect, 'action-bar', viewport);

        // Summary row is NOT clipped above bottom-dock top edge, and keypad is NOT cropped inside slot
        expect(summaryRect.top, greaterThanOrEqualTo(dockRect.top - 0.5));
        expect(amountRect.top, greaterThanOrEqualTo(summaryRect.top - 0.5));
        expect(amountRect.bottom, lessThanOrEqualTo(summaryRect.bottom + 0.5));
        expect(keypadRect.height, lessThanOrEqualTo(slotRect.height + 0.5));

        // Strict top-to-bottom non-overlapping vertical order
        expect(zone2Rect.bottom, lessThanOrEqualTo(summaryRect.top + 0.5));
        expect(summaryRect.bottom, lessThanOrEqualTo(remarkRect.top + 0.5));
        expect(remarkRect.bottom, lessThanOrEqualTo(pillRect.top + 0.5));
        expect(pillRect.bottom, lessThanOrEqualTo(keypadRect.top + 0.5));
        expect(keypadRect.bottom, lessThanOrEqualTo(actionBarRect.top + 0.5));

        // Hit-test confirm summary & amount & keypad keys are genuinely unoccluded
        expect(find.text('请选择分类').hitTestable(), findsOneWidget);
        expect(find.byKey(const Key('amount')).hitTestable(), findsOneWidget);
        expect(find.byKey(const Key('keypad-7')).hitTestable(), findsOneWidget);
        expect(find.byKey(const Key('save')).hitTestable(), findsOneWidget);
      }

      await cleanUp();
    },
  );
}
