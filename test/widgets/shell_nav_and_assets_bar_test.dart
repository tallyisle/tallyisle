import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tallyisle/app/app.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/features/assets/assets_page.dart';
import 'package:tallyisle/features/me/me_page.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
  }

  testWidgets(
    '5-slot bottom bar renders symmetric slots + center add-record, MePage shows 更多 & 报销管理 & 0.1.0.rc without 开发版本',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final db = AppDatabase(NativeDatabase.memory());
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: const TallyIsleApp(),
        ),
      );
      await settle(tester);

      // Debug banner must be hidden.
      final materialApp = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(materialApp.debugShowCheckedModeBanner, isFalse);

      // HomePage must not render a floating action button; Key('add-record') lives in the center slot.
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.byKey(const Key('shell-bottom-bar')), findsOneWidget);
      expect(find.byKey(const Key('add-record')), findsOneWidget);

      // Verify all 5 bottom-bar labels / slots and absence of legacy '我的'.
      expect(find.text('明细'), findsOneWidget);
      expect(find.text('统计'), findsOneWidget);
      expect(find.text('资产'), findsOneWidget);
      expect(find.text('更多'), findsOneWidget);
      expect(find.text('我的'), findsNothing);

      final bottomBar = find.byKey(const Key('shell-bottom-bar'));
      Finder barIcon(IconData icon) =>
          find.descendant(of: bottomBar, matching: find.byIcon(icon));

      // Check selected / unselected icons on initial branch 0 ('明细').
      expect(barIcon(Icons.receipt_long), findsOneWidget);
      expect(barIcon(Icons.pie_chart_outline), findsOneWidget);
      expect(barIcon(Icons.add_rounded), findsOneWidget);
      expect(barIcon(Icons.account_balance_wallet_outlined), findsOneWidget);
      expect(barIcon(Icons.grid_view_outlined), findsOneWidget);

      // Verify symmetric 5-slot geometry along the bottom bar.
      final slotHome = tester.getRect(find.byKey(const Key('nav-slot-home')));
      final slotStats = tester.getRect(find.byKey(const Key('nav-slot-stats')));
      final centerAdd = tester.getRect(find.byKey(const Key('add-record')));
      final slotAssets = tester.getRect(
        find.byKey(const Key('nav-slot-assets')),
      );
      final slotMore = tester.getRect(find.byKey(const Key('nav-slot-more')));

      expect((slotHome.width - slotStats.width).abs(), lessThan(0.01));
      expect((slotHome.width - slotAssets.width).abs(), lessThan(0.01));
      expect((slotHome.width - slotMore.width).abs(), lessThan(0.01));
      expect((slotHome.width - (390.0 / 5.0)).abs(), lessThan(0.01));
      expect((centerAdd.center.dx - 195.0).abs(), lessThan(0.01));
      expect((centerAdd.center.dy - slotHome.center.dy).abs(), lessThan(0.01));

      // Tap '统计' -> switches to branch 1 with selected pie_chart icon.
      await tester.tap(find.text('统计'));
      await settle(tester);
      expect(find.byKey(const Key('stats-hub-page')), findsOneWidget);
      expect(barIcon(Icons.pie_chart), findsOneWidget);
      expect(barIcon(Icons.receipt_long_outlined), findsOneWidget);

      // Tap '更多' -> switches to branch 3 (MePage).
      await tester.tap(find.text('更多'));
      await settle(tester);
      expect(barIcon(Icons.grid_view_rounded), findsOneWidget);
      expect(
        find.descendant(of: find.byType(AppBar), matching: find.text('更多')),
        findsOneWidget,
      );
      expect(find.text('我的'), findsNothing);

      // '报销管理' entry exists under '计划与提醒' and navigates to ReimbursePage via live /reimburse route.
      expect(find.byKey(const Key('me-reimburse')), findsOneWidget);
      expect(find.text('报销管理'), findsOneWidget);
      await tester.tap(find.byKey(const Key('me-reimburse')));
      await settle(tester);
      expect(find.byKey(const Key('reimburse-pending-total')), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await settle(tester);

      // Scroll down to verify version string '当前版本 · 0.1.0.rc' and zero '开发版本'.
      await tester.scrollUntilVisible(
        find.text('当前版本 · $appDisplayVersion'),
        240,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();
      expect(find.text('当前版本 · 0.1.0.rc'), findsOneWidget);
      expect(find.text('开发版本'), findsNothing);

      // Open AboutHelpPage and verify '版本 0.1.0.rc' badge.
      await tester.tap(find.byKey(const Key('me-about')));
      await settle(tester);
      expect(find.text('版本 0.1.0.rc'), findsOneWidget);
      expect(find.text('开发版本'), findsNothing);
      await tester.tap(find.byType(BackButton));
      await settle(tester);

      // Tap center '+' button (Key('add-record')) to open RecordEditorPage.
      await tester.tap(find.byKey(const Key('add-record')));
      await settle(tester);
      expect(find.byKey(const Key('amount')), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets(
    'AssetsPage (Scheme A2) renders 3 quick-entry items on a single symmetric 3-column row without 报销管理 across 320dp, 360dp, and 412dp widths',
    (tester) async {
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final db = AppDatabase(NativeDatabase.memory());

      for (final width in <double>[320, 360, 412]) {
        tester.view.physicalSize = Size(width, 640);
        tester.view.devicePixelRatio = 1.0;

        await tester.pumpWidget(
          ProviderScope(
            retry: (_, _) => null,
            overrides: [databaseProvider.overrideWith((ref) async => db)],
            child: const TallyIsleApp(),
          ),
        );
        await settle(tester);
        expect(tester.takeException(), isNull);

        // Navigate to '资产' via the 5-slot bottom bar (also verifies bottom bar at 320/360/412dp!).
        await tester.tap(find.byKey(const Key('nav-slot-assets')));
        await settle(tester);
        expect(tester.takeException(), isNull);

        final debtsFinder = find.byKey(const Key('assets-quick-debts'));
        final instFinder = find.byKey(const Key('assets-quick-installments'));
        final depFinder = find.byKey(const Key('assets-quick-deposits'));

        expect(debtsFinder, findsOneWidget);
        expect(instFinder, findsOneWidget);
        expect(depFinder, findsOneWidget);
        // Scheme A2: 报销管理 is NOT in AssetsPage quick bar (stays only in 更多 MePage).
        expect(find.byKey(const Key('assets-quick-reimburse')), findsNothing);
        expect(find.text('报销管理'), findsNothing);

        final debtsRect = tester.getRect(debtsFinder);
        final instRect = tester.getRect(instFinder);
        final depRect = tester.getRect(depFinder);

        // Identical vertical dy center proves all 3 items stay on 1 single row!
        expect(
          (instRect.center.dy - debtsRect.center.dy).abs(),
          lessThan(0.01),
          reason: 'installments must share row dy at width=$width',
        );
        expect(
          (depRect.center.dy - debtsRect.center.dy).abs(),
          lessThan(0.01),
          reason: 'deposits must share row dy at width=$width',
        );

        // Equal widths and strictly left-to-right ordering prove 3-column Expanded symmetry!
        expect((instRect.width - debtsRect.width).abs(), lessThan(0.01));
        expect((depRect.width - debtsRect.width).abs(), lessThan(0.01));
        expect(debtsRect.center.dx, lessThan(instRect.center.dx));
        expect(instRect.center.dx, lessThan(depRect.center.dx));

        await tester.pumpWidget(const SizedBox());
        await settle(tester);
      }

      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets(
    'tapping AssetsPage 3 quick items and MePage me-reimburse pushes expected routes',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final router = GoRouter(
        initialLocation: '/assets',
        routes: [
          GoRoute(path: '/assets', builder: (_, _) => const AssetsPage()),
          GoRoute(path: '/me', builder: (_, _) => const MePage()),
          GoRoute(
            path: '/debts',
            builder: (_, _) =>
                const Scaffold(body: Center(child: Text('DEBTS_DEST'))),
          ),
          GoRoute(
            path: '/installments',
            builder: (_, _) =>
                const Scaffold(body: Center(child: Text('INSTALLMENTS_DEST'))),
          ),
          GoRoute(
            path: '/deposits',
            builder: (_, _) =>
                const Scaffold(body: Center(child: Text('DEPOSITS_DEST'))),
          ),
          GoRoute(
            path: '/reimburse',
            builder: (_, _) =>
                const Scaffold(body: Center(child: Text('REIMBURSE_DEST'))),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await settle(tester);

      await tester.tap(find.byKey(const Key('assets-quick-debts')));
      await settle(tester);
      expect(find.text('DEBTS_DEST'), findsOneWidget);

      router.go('/assets');
      await settle(tester);
      await tester.tap(find.byKey(const Key('assets-quick-installments')));
      await settle(tester);
      expect(find.text('INSTALLMENTS_DEST'), findsOneWidget);

      router.go('/assets');
      await settle(tester);
      await tester.tap(find.byKey(const Key('assets-quick-deposits')));
      await settle(tester);
      expect(find.text('DEPOSITS_DEST'), findsOneWidget);

      router.go('/me');
      await settle(tester);
      await tester.tap(find.byKey(const Key('me-reimburse')));
      await settle(tester);
      expect(find.text('REIMBURSE_DEST'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
    },
  );
}
