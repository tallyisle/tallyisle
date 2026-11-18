import 'dart:async' show unawaited;

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tallyisle/app/app.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/catalog/catalog_queries.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/db/seed.dart' show defaultBookId;
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/features/assets/asset_editor_page.dart';
import 'package:tallyisle/features/assets/assets_page.dart';
import 'package:tallyisle/features/records/record_editor_page.dart';
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

Future<(AppDatabase, Future<void> Function())> _openTestDb(
  WidgetTester tester,
) async {
  late final AppDatabase db;
  await tester.runAsync(() async {
    db = AppDatabase(NativeDatabase.memory());
  });
  var closed = false;
  Future<void> closeCleanly() async {
    if (closed) return;
    closed = true;
    await tester.pumpWidget(const SizedBox.shrink());
    await _settle(tester, 5);
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(db.close);
  }

  addTearDown(() async {
    if (!closed) {
      await closeCleanly();
    }
  });
  return (db, closeCleanly);
}

Future<void> _tapKeypadDigits(WidgetTester tester, List<String> keys) async {
  for (final k in keys) {
    await tester.tap(find.byKey(Key('keypad-$k')));
    await tester.pump();
  }
}

String _fieldText(WidgetTester tester, Key fieldKey) {
  return tester.widget<TextField>(find.byKey(fieldKey)).controller!.text;
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

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets(
    'Mobile 390x844: /record/new -> account capsule -> 管理账户 opens non-blank 账户管理 (even when /assets shell branch was already visited), supports adding account, and Back preserves draft while keeping shell /assets tab unchanged',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final (db, closeCleanly) = await _openTestDb(tester);
      await tester.runAsync(() async {
        final svc = LedgerService(db);
        await svc.createAsset(
          commandId: 'seed-mobile-asset-1',
          name: '招商储蓄卡',
          type: AssetType.normal,
          initial: Money.parse('1234.00'),
        );
      });

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            reminderSchedulerProvider.overrideWithValue(
              InMemoryReminderScheduler(),
            ),
          ],
          child: const TallyIsleApp(),
        ),
      );
      await _settle(tester);

      // 1. Visit bottom-bar '/assets' tab first so branch 2 stays mounted in
      // StatefulShellRoute.indexedStack (verifying zero Hero or pageKey collisions!).
      await tester.tap(find.byKey(const Key('nav-slot-assets')));
      await _settle(tester);
      expect(
        find.descendant(of: find.byType(AppBar), matching: find.text('资产')),
        findsOneWidget,
      );
      expect(find.byType(BackButton), findsNothing);
      expect(find.text('招商储蓄卡').hitTestable(), findsOneWidget);

      // Switch back to Home ('明细') and tap '+' ('记一笔').
      await tester.tap(find.byKey(const Key('nav-slot-home')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('add-record')));
      await _settle(tester);
      expect(find.byType(RecordEditorPage).hitTestable(), findsOneWidget);

      // 2. Build an in-progress bill draft: select '餐饮', enter 88.50, enter remark.
      await tester.tap(find.text('餐饮').hitTestable().first);
      await tester.pump();
      await _tapKeypadDigits(tester, const ['8', '8', 'dot', '5']);
      await tester.enterText(find.byKey(const Key('remark')), '工作午餐');
      await _settle(tester, 4);
      expect(_fieldText(tester, const Key('amount')), '88.5');
      expect(_fieldText(tester, const Key('remark')), '工作午餐');

      // 3. Tap account capsule -> tap '管理账户'.
      await tester.tap(find.byKey(const Key('asset')));
      await _settle(tester);
      expect(find.byKey(const Key('manage-assets-sheet-btn')), findsOneWidget);

      await tester.tap(find.byKey(const Key('manage-assets-sheet-btn')));
      await _settle(tester);
      expect(tester.takeException(), isNull);

      // 4. Verify standalone Account Management view renders cleanly (not blank!).
      expect(find.byType(AssetsPage).hitTestable(), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AppBar).hitTestable(),
          matching: find.text('账户管理'),
        ),
        findsOneWidget,
      );
      expect(find.byType(BackButton).hitTestable(), findsOneWidget);
      expect(find.text('招商储蓄卡').hitTestable(), findsOneWidget);

      // 5. Add a new account inside '账户管理' and confirm it appears immediately.
      await tester.tap(find.byKey(const Key('add-asset')).hitTestable());
      await _settle(tester);
      expect(find.byType(AssetEditorPage).hitTestable(), findsOneWidget);
      await tester.enterText(find.byKey(const Key('asset-name')), '旅行备用金');
      await tester.enterText(find.byKey(const Key('asset-balance')), '500');
      await tester.tap(find.byKey(const Key('asset-save')));
      await _settle(tester);

      expect(find.text('旅行备用金').hitTestable(), findsOneWidget);
      expect(find.text('招商储蓄卡').hitTestable(), findsOneWidget);

      // 6. Tap Back on '账户管理' -> returns to in-progress bill without losing draft!
      await tester.tap(find.byType(BackButton).hitTestable().first);
      await _settle(tester);
      expect(find.byType(RecordEditorPage).hitTestable(), findsOneWidget);
      expect(_fieldText(tester, const Key('amount')), '88.5');
      expect(_fieldText(tester, const Key('remark')), '工作午餐');

      // 7. Select newly added '旅行备用金' from account capsule and save the bill.
      await tester.tap(find.byKey(const Key('asset')));
      await _settle(tester);
      await tester.tap(find.text('旅行备用金').hitTestable().last);
      await _settle(tester);
      expect(find.text('旅行备用金'), findsWidgets);

      await tester.tap(find.byKey(const Key('editor-quick-save-btn')));
      await _settle(tester);

      // 8. Back on Home shell: verify '/assets' bottom-bar tab works 100% unchanged.
      await tester.tap(find.byKey(const Key('nav-slot-assets')));
      await _settle(tester);
      expect(
        find.descendant(
          of: find.byType(AppBar).hitTestable(),
          matching: find.text('资产'),
        ),
        findsOneWidget,
      );
      expect(find.byType(BackButton).hitTestable(), findsNothing);
      expect(find.text('旅行备用金').hitTestable(), findsOneWidget);

      await closeCleanly();
    },
  );

  testWidgets(
    'Mobile 360x640 narrow: /record/:id/edit and Transfer mode -> 管理账户 -> Back preserves draft without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final (db, closeCleanly) = await _openTestDb(tester);
      late final String seededRecordId;
      await tester.runAsync(() async {
        final svc = LedgerService(db);
        final queries = CatalogQueries(db);
        final a1 = await svc.createAsset(
          commandId: 'seed-narrow-a1',
          name: '建设银行卡',
          type: AssetType.normal,
          initial: Money.parse('2000.00'),
        );
        await svc.createAsset(
          commandId: 'seed-narrow-a2',
          name: '零钱通',
          type: AssetType.normal,
          initial: Money.parse('300.00'),
        );
        final cats = await queries.watchCategories(defaultBookId).first;
        final cat = cats.firstWhere((c) => c.type == RecordType.expense);
        seededRecordId = await svc.saveRecord(
          commandId: 'seed-narrow-rec-1',
          draft: RecordDraft(
            type: RecordType.expense,
            money: Money.parse('42.60'),
            recordTime: DateTime(2026, 11, 18, 12, 30).millisecondsSinceEpoch,
            bookId: defaultBookId,
            categoryId: cat.id,
            assetId: a1,
            remark: '便利店早餐',
          ),
        );
      });

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            reminderSchedulerProvider.overrideWithValue(
              InMemoryReminderScheduler(),
            ),
          ],
          child: const TallyIsleApp(),
        ),
      );
      await _settle(tester);

      // 1. Push /record/:id/edit directly via GoRouter.
      final rootCtx = tester.element(find.byType(Scaffold).first);
      unawaited(GoRouter.of(rootCtx).push('/record/$seededRecordId/edit'));
      await _settle(tester);

      expect(find.byType(RecordEditorPage).hitTestable(), findsOneWidget);
      expect(_fieldText(tester, const Key('remark')), '便利店早餐');

      await tester.tap(find.byKey(const Key('asset')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('manage-assets-sheet-btn')));
      await _settle(tester);
      expect(tester.takeException(), isNull);

      expect(find.text('账户管理').hitTestable(), findsOneWidget);
      expect(find.text('建设银行卡').hitTestable(), findsOneWidget);
      expect(find.text('零钱通').hitTestable(), findsOneWidget);

      await tester.tap(find.byType(BackButton).hitTestable().first);
      await _settle(tester);
      expect(_fieldText(tester, const Key('remark')), '便利店早餐');

      // 2. Switch to Transfer mode in /record/new and open 管理账户 from 'from' slot.
      GoRouter.of(rootCtx).pop();
      await _settle(tester);
      unawaited(
        GoRouter.of(rootCtx).push('/record/new?type=${RecordType.transfer}'),
      );
      await _settle(tester);

      await _tapKeypadDigits(tester, const ['1', '5', '0']);
      await tester.tap(find.byKey(const Key('from')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('manage-assets-sheet-btn')));
      await _settle(tester);
      expect(tester.takeException(), isNull);

      expect(find.text('账户管理').hitTestable(), findsOneWidget);
      await tester.tap(find.byType(BackButton).hitTestable().first);
      await _settle(tester);
      expect(_fieldText(tester, const Key('amount')), '150');

      await closeCleanly();
    },
  );

  testWidgets(
    'Desktop 1280x800 & 900x700: both + 记一笔 modal and /record/new route open centered 账户管理 modal with add/edit, CloseButton & Esc return cleanly with draft & focus preserved, and sidebar /assets Master-Detail stays intact',
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final (db, closeCleanly) = await _openTestDb(tester);
      late final int creditId;
      await tester.runAsync(() async {
        final svc = LedgerService(db);
        creditId = await svc.createAsset(
          commandId: 'seed-desk-credit-1',
          name: '工商信用卡',
          type: AssetType.credit,
          initial: Money.zero(),
        );
      });

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            reminderSchedulerProvider.overrideWithValue(
              InMemoryReminderScheduler(),
            ),
          ],
          child: const TallyIsleApp(),
        ),
      );
      await _settle(tester);

      // 1. Open '+ 记一笔' from desktop sidebar (imperative DialogRoute).
      await tester.tap(find.text('记一笔').first);
      await _settle(tester);
      expect(find.byType(RecordEditorPage).hitTestable(), findsOneWidget);

      await tester.enterText(find.byKey(const Key('amount')), '126.40');
      await tester.enterText(find.byKey(const Key('remark')), '高铁票');
      await _settle(tester, 4);

      // 2. Click account capsule -> click '管理账户'.
      await tester.tap(find.byKey(const Key('asset')));
      await _settle(tester);
      expect(
        find.byKey(const Key('desktop-account-picker-dialog')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('manage-assets-sheet-btn')));
      await _settle(tester);
      expect(tester.takeException(), isNull);

      // 3. Verify centered modal '账户管理' renders single-column list cleanly with CloseButton.
      expect(find.byType(AssetsPage).hitTestable(), findsOneWidget);
      expect(find.text('账户管理').hitTestable(), findsOneWidget);
      expect(find.byKey(const Key('assets-master-pane')), findsNothing);
      expect(find.text('工商信用卡').hitTestable(), findsOneWidget);

      // 4. Inline-edit '工商信用卡' -> '工商白金卡' directly from '账户管理'.
      await tester.tap(find.byKey(Key('manage-edit-asset-$creditId')));
      await _settle(tester);
      expect(find.byType(AssetEditorPage).hitTestable(), findsOneWidget);
      await tester.enterText(find.byKey(const Key('asset-name')), '工商白金卡');
      await tester.tap(find.byKey(const Key('asset-save')));
      await _settle(tester);
      expect(find.text('工商白金卡').hitTestable(), findsOneWidget);

      // 5. Add a brand-new account '微信零钱' inside desktop '账户管理'.
      await tester.tap(find.byKey(const Key('add-asset')).hitTestable());
      await _settle(tester);
      expect(find.byType(AssetEditorPage).hitTestable(), findsOneWidget);
      await tester.enterText(find.byKey(const Key('asset-name')), '微信零钱');
      await tester.enterText(find.byKey(const Key('asset-balance')), '600');
      await tester.tap(find.byKey(const Key('asset-save')));
      await _settle(tester);
      expect(find.text('微信零钱').hitTestable(), findsOneWidget);

      // 6. Close '账户管理' modal via CloseButton -> back in RecordEditorPage with draft & focus!
      final assetsAppBar = find.descendant(
        of: find.byType(AssetsPage),
        matching: find.byType(AppBar),
      );
      await tester.tap(
        find.descendant(of: assetsAppBar, matching: find.byType(CloseButton)),
      );
      await _settle(tester);

      expect(find.byType(AssetsPage), findsNothing);
      expect(find.byType(RecordEditorPage).hitTestable(), findsOneWidget);
      expect(_fieldText(tester, const Key('amount')), '126.40');
      expect(_fieldText(tester, const Key('remark')), '高铁票');
      expect(_hasFieldFocus(tester, const Key('amount')), isTrue);

      // Close imperative RecordEditorPage modal.
      await tester.tap(find.byKey(const Key('desktop-editor-close-btn')));
      await _settle(tester);
      expect(find.byType(RecordEditorPage), findsNothing);

      // 7. Verify 1280x800 sidebar '/assets' tab still renders full Master-Detail!
      final shellCtx = tester.element(find.byType(Scaffold).first);
      GoRouter.of(shellCtx).go('/assets');
      await _settle(tester);
      expect(
        find.descendant(
          of: find.byType(AppBar).hitTestable().first,
          matching: find.text('资产'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('assets-master-pane')), findsOneWidget);
      expect(find.byKey(const Key('assets-detail-pane')), findsOneWidget);
      expect(find.text('工商白金卡'), findsWidgets);
      expect(find.text('微信零钱'), findsWidgets);

      // 8. Resize to 900x700 compact desktop and test declarative '/record/new' + Escape close.
      tester.view.physicalSize = const Size(900, 700);
      await _settle(tester, 4);
      GoRouter.of(shellCtx).go('/');
      await _settle(tester, 4);
      unawaited(GoRouter.of(shellCtx).push('/record/new'));
      await _settle(tester);

      await tester.enterText(find.byKey(const Key('amount')), '55.00');
      await tester.enterText(find.byKey(const Key('remark')), '地铁通勤');
      await _settle(tester, 3);

      await tester.tap(find.byKey(const Key('asset')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('manage-assets-sheet-btn')));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('账户管理').hitTestable(), findsOneWidget);
      expect(find.text('微信零钱').hitTestable(), findsOneWidget);

      // Press Escape -> dismisses '账户管理' modal only, preserving '/record/new' draft!
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
      expect(find.text('账户管理'), findsNothing);
      expect(find.byType(RecordEditorPage).hitTestable(), findsOneWidget);
      expect(_fieldText(tester, const Key('amount')), '55.00');
      expect(_fieldText(tester, const Key('remark')), '地铁通勤');

      await closeCleanly();
    },
  );
}
