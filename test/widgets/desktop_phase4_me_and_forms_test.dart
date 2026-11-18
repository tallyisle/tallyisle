import 'dart:async' show unawaited;
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
import 'package:tallyisle/data/automation/auto_bill_service.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/features/backup/backup_providers.dart';
import 'package:tallyisle/features/books/books_page.dart';
import 'package:tallyisle/features/categories/categories_page.dart';
import 'package:tallyisle/features/reminder/reminder_providers.dart';
import 'package:tallyisle/features/settings/about_help_page.dart';
import 'package:tallyisle/features/settings/settings_page.dart';
import 'package:tallyisle/platform/notifications.dart';

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets(
    'MePage renders 236px directory + in-place content stage at 1280x800, degrades to 2-column card grid at 900x700, and falls back to single column below 720px',
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
        () => Directory.systemTemp.createTemp('desk_p4_me_'),
      ))!;

      await tester.runAsync(() async {
        final autoSvc = AutoBillService(db);
        await autoSvc.ingestPaymentText(
          commandId: 'seed-draft-1',
          rawText: '微信支付收款 28.50 元 瑞幸咖啡',
          packageName: 'com.tencent.mm',
          capturedAtMs: DateTime(2026, 5, 10, 9, 30).millisecondsSinceEpoch,
        );
      });

      var closed = false;
      Future<void> cleanUp() async {
        if (closed) return;
        closed = true;
        await tester.pumpWidget(const SizedBox.shrink());
        await _settle(tester);
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

      // Open "更多" branch in expanded 1280x800 desktop shell
      await tester.tap(find.byKey(const Key('nav-slot-more')));
      await _settle(tester);
      expect(tester.takeException(), isNull);

      final dirFinder = find.byKey(const Key('me-desktop-directory'));
      final paneFinder = find.byKey(const Key('me-desktop-content-pane'));
      expect(dirFinder, findsOneWidget);
      expect(paneFinder, findsOneWidget);
      expect(find.byKey(const Key('me-desktop-card-grid')), findsNothing);
      expect(tester.getSize(dirFinder).width, 236);

      // Android-only desktop widget entry stays hidden on desktop; all 6 sections exist
      expect(find.byKey(const Key('me-widgets')), findsNothing);
      for (final sectionTitle in const <String>[
        '基础管理',
        '计划与提醒',
        '数据与备份',
        '常用工具',
        '智能与外部联动',
        '安全与系统设置',
      ]) {
        expect(
          find.descendant(of: dirFinder, matching: find.text(sectionTitle)),
          findsOneWidget,
        );
      }

      // Draft count badge renders on me-auto-bill tile
      expect(
        find.descendant(
          of: find.byKey(const Key('me-auto-bill')),
          matching: find.text('1'),
        ),
        findsOneWidget,
      );

      // Default selection is /books -> BooksPage rendered in-place in right stage
      expect(
        find.descendant(of: paneFinder, matching: find.byType(BooksPage)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: paneFinder, matching: find.byType(BackButton)),
        findsNothing,
      );

      // Click 分类管理 -> switches right pane in-place to CategoriesPage without pushing/back button
      await tester.tap(find.byKey(const Key('me-categories')));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(
        find.descendant(of: paneFinder, matching: find.byType(BooksPage)),
        findsNothing,
      );
      expect(
        find.descendant(of: paneFinder, matching: find.byType(CategoriesPage)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: paneFinder, matching: find.byType(BackButton)),
        findsNothing,
      );

      // Switch across FAB-bearing pages (Wishes -> Notes) to verify HeroMode isolation
      await tester.ensureVisible(find.byKey(const Key('me-wishes')));
      await tester.tap(find.byKey(const Key('me-wishes')));
      await _settle(tester);
      expect(tester.takeException(), isNull);

      await tester.ensureVisible(find.byKey(const Key('me-notes')));
      await tester.tap(find.byKey(const Key('me-notes')));
      await _settle(tester);
      expect(tester.takeException(), isNull);

      // Scroll directory to 系统与首页设置 -> SettingsPage in-place
      await tester.ensureVisible(find.byKey(const Key('me-settings')));
      await tester.tap(find.byKey(const Key('me-settings')));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(
        find.descendant(of: paneFinder, matching: find.byType(SettingsPage)),
        findsOneWidget,
      );

      // Scroll directory to 帮助与关于 -> AboutHelpPage in-place without back button
      await tester.ensureVisible(find.byKey(const Key('me-about')));
      await tester.tap(find.byKey(const Key('me-about')));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(
        find.descendant(of: paneFinder, matching: find.byType(AboutHelpPage)),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: paneFinder,
          matching: find.text('版本 $appDisplayVersion'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: paneFinder, matching: find.byType(BackButton)),
        findsNothing,
      );

      // Narrow to 900x700 -> automatically degrades to 2-column card grid
      tester.view.physicalSize = const Size(900, 700);
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('me-desktop-directory')), findsNothing);
      expect(find.byKey(const Key('me-desktop-content-pane')), findsNothing);
      expect(find.byKey(const Key('me-desktop-card-grid')), findsOneWidget);

      // Left column (me-books) and right column (me-wishes) are laid out side-by-side
      final booksLeft = tester.getTopLeft(find.byKey(const Key('me-books'))).dx;
      final wishesLeft = tester
          .getTopLeft(find.byKey(const Key('me-wishes')))
          .dx;
      expect(wishesLeft, greaterThan(booksLeft + 200));

      // Tapping an item in 900x700 grid pushes the route normally
      await tester.ensureVisible(find.byKey(const Key('me-about')));
      await tester.tap(find.byKey(const Key('me-about')));
      await _settle(tester);
      expect(find.byType(AboutHelpPage), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await _settle(tester);
      expect(find.byKey(const Key('me-desktop-card-grid')), findsOneWidget);

      // Narrow below 720px (520x600) -> falls back to single-column scroll layout
      tester.view.physicalSize = const Size(520, 600);
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('me-desktop-directory')), findsNothing);
      expect(find.byKey(const Key('me-desktop-card-grid')), findsNothing);
      expect(find.byKey(const Key('me-books')), findsOneWidget);

      await cleanUp();
    },
  );

  testWidgets(
    'Desktop small create/edit forms open as centered 560px modal dialogs, block accidental barrier taps, support Esc & CloseButton, and save + return results cleanly',
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
        () => Directory.systemTemp.createTemp('desk_p4_forms_'),
      ))!;

      var closed = false;
      Future<void> cleanUp() async {
        if (closed) return;
        closed = true;
        await tester.pumpWidget(const SizedBox.shrink());
        await _settle(tester);
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

      GoRouter router() =>
          GoRouter.of(tester.element(find.byKey(const Key('desktop-sidebar'))));

      void expectCentered560Dialog() {
        final dialogFinder = find.byType(Dialog);
        final surfaceFinder = find.byKey(
          const Key('desktop-modal-dialog-surface'),
        );
        expect(dialogFinder, findsOneWidget);
        expect(surfaceFinder, findsOneWidget);
        final size = tester.getSize(surfaceFinder);
        final center = tester.getCenter(surfaceFinder);
        expect(size.width, 560);
        expect(size.height, lessThanOrEqualTo(700));
        expect(center.dx, closeTo(640, 1.0));
        expect(center.dy, closeTo(400, 1.0));
        expect(
          find.descendant(of: dialogFinder, matching: find.byType(CloseButton)),
          findsOneWidget,
        );
      }

      // 1. /assets/new -> 560px centered Dialog, barrier tap does NOT dismiss, saves to DB
      unawaited(router().push('/assets/new'));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expectCentered560Dialog();

      await tester.enterText(find.byKey(const Key('asset-name')), '招行工资卡');
      await tester.enterText(find.byKey(const Key('asset-balance')), '5000.50');
      // Accidental click outside dialog barrier must NOT lose form state
      await tester.tapAt(const Offset(20, 20));
      await _settle(tester);
      expect(find.byType(Dialog), findsOneWidget);

      await tester.tap(find.byKey(const Key('asset-save')));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(Dialog), findsNothing);

      final createdAssets = await tester.runAsync(
        () => db.select(db.assets).get(),
      );
      final salaryCard = createdAssets!
          .where((a) => a.name == '招行工资卡')
          .singleOrNull;
      expect(salaryCard, isNotNull);
      expect(salaryCard!.balanceMinor, BigInt.from(500050));

      // 2. /debts/new -> 560px centered Dialog, saves and forwards Navigator.pop(true) result
      final debtResultFuture = router().push<Object?>('/debts/new');
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expectCentered560Dialog();

      await tester.enterText(find.byKey(const Key('debt_name_input')), '张三周转');
      await tester.enterText(
        find.byKey(const Key('debt_principal_input')),
        '1200.00',
      );
      await tester.tap(find.byKey(const Key('save_debt_button')));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(Dialog), findsNothing);
      expect(await debtResultFuture, isTrue);

      final allAssetsAfterDebt = await tester.runAsync(
        () => db.select(db.assets).get(),
      );
      final createdDebt = allAssetsAfterDebt!
          .where((a) => a.type == AssetType.debt && a.name == '张三周转')
          .singleOrNull;
      expect(createdDebt, isNotNull);

      // 3. /wishes/new -> 560px centered Dialog, saves to DB
      unawaited(router().push('/wishes/new'));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expectCentered560Dialog();

      await tester.enterText(
        find.byKey(const Key('wish_content_input')),
        '人体工学椅',
      );
      await tester.enterText(
        find.byKey(const Key('wish_amount_input')),
        '1999.00',
      );
      await tester.tap(find.byKey(const Key('save_wish_button')));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(Dialog), findsNothing);

      final wishes = await tester.runAsync(() => db.select(db.wishes).get());
      expect(
        wishes!.any(
          (w) => w.content == '人体工学椅' && w.valueMinor == BigInt.from(199900),
        ),
        isTrue,
      );

      // 4. /notes/new -> 560px centered Dialog, saves to DB
      unawaited(router().push('/notes/new'));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expectCentered560Dialog();

      await tester.enterText(find.byKey(const Key('note_title_input')), '月度复盘');
      await tester.enterText(
        find.byKey(const Key('note_content_input')),
        '核对信用卡账单与定存到期',
      );
      await tester.tap(find.byKey(const Key('save_note_button')));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(Dialog), findsNothing);

      final notes = await tester.runAsync(() => db.select(db.notes).get());
      expect(notes!.any((n) => n.title == '月度复盘'), isTrue);

      // 5. Verify remaining 6 form routes also render as 560px centered Dialogs and dismiss cleanly via Esc / CloseButton
      for (final (idx, routePath) in const <(int, String)>[
        (0, '/periodic/new'),
        (1, '/installments/new'),
        (2, '/savings/new'),
        (3, '/deposits/new'),
        (4, '/templates/new'),
        (5, '/bank-cards/new'),
      ]) {
        unawaited(router().push(routePath));
        await _settle(tester);
        expect(tester.takeException(), isNull);
        expectCentered560Dialog();

        if (idx.isEven) {
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        } else {
          await tester.tap(
            find.descendant(
              of: find.byType(Dialog),
              matching: find.byType(CloseButton),
            ),
          );
        }
        await _settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.byType(Dialog), findsNothing);
      }

      // 6. Opening an editor FAB from inside MePage's right-hand workspace pane
      // (e.g., DebtPage add_debt_button) also opens the 560px centered Dialog!
      await tester.tap(find.byKey(const Key('nav-slot-more')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('me-debts')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('add_debt_button')));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expectCentered560Dialog();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
      expect(find.byType(Dialog), findsNothing);

      await cleanUp();
    },
  );

  testWidgets(
    'Mobile 360x640 preserves single-column MePage with me-widgets and full-screen MaterialPage forms without Dialog',
    variant: TargetPlatformVariant.only(TargetPlatform.android),
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final db = AppDatabase(NativeDatabase.memory());
      final reminderScheduler = InMemoryReminderScheduler();
      final tempRoot = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('desk_p4_mob_'),
      ))!;

      var closed = false;
      Future<void> cleanUp() async {
        if (closed) return;
        closed = true;
        await tester.pumpWidget(const SizedBox.shrink());
        await _settle(tester);
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

      await tester.tap(find.byKey(const Key('nav-slot-more')));
      await _settle(tester);
      expect(tester.takeException(), isNull);

      expect(find.byKey(const Key('me-desktop-directory')), findsNothing);
      expect(find.byKey(const Key('me-desktop-content-pane')), findsNothing);
      expect(find.byKey(const Key('me-desktop-card-grid')), findsNothing);
      expect(find.byKey(const Key('me-widgets')), findsOneWidget);

      final router = GoRouter.of(
        tester.element(find.byKey(const Key('shell-bottom-bar'))),
      );
      unawaited(router.push('/assets/new'));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(CloseButton), findsNothing);
      expect(find.byKey(const Key('asset-name')), findsOneWidget);

      await cleanUp();
    },
  );
}
