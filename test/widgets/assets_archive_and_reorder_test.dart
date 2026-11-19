import 'dart:async';
import 'dart:ui' show PointerDeviceKind;

import 'package:drift/drift.dart' show OrderingTerm, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart'
    show kLongPressTimeout, kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tallyisle/app/adaptive.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/debt/debt_service.dart';
import 'package:tallyisle/data/installment/installment_service.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/data/periodic/periodic_service.dart';
import 'package:tallyisle/data/savings/savings_service.dart';
import 'package:tallyisle/data/tools/bill_attachment_service.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/periodic_records.dart';
import 'package:tallyisle/domain/rules/savings_plan.dart';
import 'package:tallyisle/features/assets/archived_assets_sheet.dart';
import 'package:tallyisle/features/assets/asset_detail_page.dart';
import 'package:tallyisle/features/assets/asset_editor_page.dart';
import 'package:tallyisle/features/assets/assets_page.dart';
import 'package:tallyisle/features/common/desktop_modal_page.dart';
import 'package:tallyisle/features/debt/debt_detail_page.dart';
import 'package:tallyisle/features/deposit/fixed_deposit_page.dart';
import 'package:tallyisle/features/installment/installment_detail_page.dart';
import 'package:tallyisle/features/installment/installment_page.dart';
import 'package:tallyisle/features/notes/notes_page.dart';
import 'package:tallyisle/features/periodic/periodic_page.dart';
import 'package:tallyisle/features/periodic/periodic_providers.dart';
import 'package:tallyisle/features/receipt/diy_toolbar_settings_page.dart';
import 'package:tallyisle/features/receipt/receipt_diy_providers.dart';
import 'package:tallyisle/features/savings/savings_detail_page.dart';
import 'package:tallyisle/features/savings/savings_page.dart';
import 'package:tallyisle/features/settings/stat_stories_page.dart';
import 'package:tallyisle/features/wishes/wishes_page.dart';

Future<void> _settle(WidgetTester tester, [int ticks = 12]) async {
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
    await _settle(tester, 8);
    await tester.pump(const Duration(seconds: 1));
    unawaited(db.close());
    await tester.pump(Duration.zero);
  }

  addTearDown(() async {
    if (!closed) {
      closed = true;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      unawaited(db.close());
      await tester.pump(Duration.zero);
    }
  });
  return (db, closeCleanly);
}

Future<void> _longPressDrag(
  WidgetTester tester,
  Finder from,
  Offset offset,
) async {
  final start = tester.getCenter(from);
  final gesture = await tester.startGesture(start);
  await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
  const steps = 12;
  for (var i = 0; i < steps; i++) {
    await gesture.moveBy(offset / steps.toDouble());
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  await _settle(tester);
}

Future<void> _mouseDrag(WidgetTester tester, Finder from, Offset offset) async {
  final start = tester.getCenter(from);
  final gesture = await tester.startGesture(
    start,
    kind: PointerDeviceKind.mouse,
  );
  await tester.pump(const Duration(milliseconds: 16));
  const steps = 12;
  for (var i = 0; i < steps; i++) {
    await gesture.moveBy(offset / steps.toDouble());
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  await _settle(tester);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets(
    '1) LedgerService.reorderAssets deduplicates, validates IDs, preserves non-target slots, normalizes sort 0..N-1, and enforces commandId idempotency',
    (tester) async {
      final (db, closeCleanly) = await _openTestDb(tester);
      final ledger = LedgerService(db);

      late int n1, c1, n2, h1, n3;
      await tester.runAsync(() async {
        // createAsset prepends with minSort - 1, so creation order n1..n3 -> initial sort order [n3, h1, n2, c1, n1]
        n1 = await ledger.createAsset(
          commandId: 'r-n1',
          name: '现金A',
          initial: Money.parse('100.00'),
        );
        c1 = await ledger.createAsset(
          commandId: 'r-c1',
          name: '信用卡C',
          type: AssetType.credit,
          initial: Money.zero(),
          limit: Money.parse('5000.00'),
        );
        n2 = await ledger.createAsset(
          commandId: 'r-n2',
          name: '储蓄B',
          initial: Money.parse('200.00'),
        );
        h1 = await ledger.createAsset(
          commandId: 'r-h1',
          name: '隐藏卡H',
          initial: Money.parse('50.00'),
        );
        await ledger.setAssetStatus(
          commandId: 'r-hide-h1',
          assetId: h1,
          status: AssetStatus.hidden,
        );
        n3 = await ledger.createAsset(
          commandId: 'r-n3',
          name: '支付宝D',
          initial: Money.parse('300.00'),
        );
      });

      // Reorder ONLY active normal accounts [n3, n2, n1] -> [n1, n3, n2] (with duplicate n1 to test deduplication!)
      await tester.runAsync(() async {
        await ledger.reorderAssets(
          commandId: 'cmd-reorder-1',
          orderedAssetIds: <int>[n1, n1, n3, n2],
        );
        // Same commandId + same payload -> idempotent no-op
        await ledger.reorderAssets(
          commandId: 'cmd-reorder-1',
          orderedAssetIds: <int>[n1, n1, n3, n2],
        );
        // Same commandId + different payload -> conflict!
        await expectLater(
          () => ledger.reorderAssets(
            commandId: 'cmd-reorder-1',
            orderedAssetIds: <int>[n2, n1, n3],
          ),
          throwsA(
            isA<Failure>().having((f) => f.code, 'code', FailureCode.conflict),
          ),
        );
        // Non-existent asset ID -> validation failure!
        await expectLater(
          () => ledger.reorderAssets(
            commandId: 'cmd-reorder-bad',
            orderedAssetIds: <int>[n1, 99999],
          ),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.validation,
            ),
          ),
        );
      });

      final allOrdered = await tester.runAsync(
        () =>
            (db.select(db.assets)..orderBy([
                  (t) => OrderingTerm.asc(t.sort),
                  (t) => OrderingTerm.asc(t.id),
                ]))
                .get(),
      );
      // Initial global order was [n3(0), h1(1), n2(2), c1(3), n1(4)].
      // Replacing slots {0, 2, 4} with [n1, n3, n2] yields [n1, h1, n3, c1, n2] with sorts [0, 1, 2, 3, 4]!
      expect(allOrdered!.map((a) => a.id).toList(), <int>[n1, h1, n3, c1, n2]);
      expect(allOrdered.map((a) => a.sort).toList(), <int>[0, 1, 2, 3, 4]);

      await closeCleanly();
    },
  );

  testWidgets(
    '2) AssetsPage hides hidden & settled accounts, opens 2-tab ArchivedAssetsSheet (swipe, default tab, hidden amounts, modal-safe detail, and reopenDebt principal recompute)',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final (db, closeCleanly) = await _openTestDb(tester);
      final ledger = LedgerService(db);
      final debtSvc = DebtService(db);

      late int activeNormalId;
      late int hiddenCreditId;
      late int settledNormalId;
      late int settledDebtId;

      await tester.runAsync(() async {
        activeNormalId = await ledger.createAsset(
          commandId: 'arc-act',
          name: '主力储蓄卡',
          initial: Money.parse('1000.00'),
        );
        hiddenCreditId = await ledger.createAsset(
          commandId: 'arc-hid-crd',
          name: '旧白金信用卡',
          type: AssetType.credit,
          initial: Money.parse('-260.00'),
          limit: Money.parse('10000.00'),
        );
        await ledger.setAssetStatus(
          commandId: 'do-hid-crd',
          assetId: hiddenCreditId,
          status: AssetStatus.hidden,
        );
        settledNormalId = await ledger.createAsset(
          commandId: 'arc-set-norm',
          name: '已销户工资卡',
          initial: Money.zero(),
        );
        await ledger.setAssetStatus(
          commandId: 'do-set-norm',
          assetId: settledNormalId,
          status: AssetStatus.settled,
        );
        // Create a 400.00 lending debt and manually settle it (so balanceMinor becomes 0 while principal history is 400.00!)
        settledDebtId = await debtSvc.createDebt(
          commandId: 'arc-debt',
          subType: AssetType.debtLend,
          name: '王五借款',
          principal: Money.parse('400.00'),
          bookId: 1,
          startDate: DateTime(2026, 5, 1).millisecondsSinceEpoch,
        );
        await debtSvc.settleDebt(
          commandId: 'do-settle-debt',
          debtId: settledDebtId,
        );
      });

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: MaterialApp(
            builder: (ctx, child) => MediaQuery(
              data: MediaQuery.of(
                ctx,
              ).copyWith(textScaler: const TextScaler.linear(1.2)),
              child: child!,
            ),
            home: const AssetsPage(),
          ),
        ),
      );
      await _settle(tester);
      expect(tester.takeException(), isNull);

      // Main list shows ONLY active accounts; hidden & settled are both excluded!
      expect(activeNormalId, greaterThan(0));
      expect(find.text('主力储蓄卡'), findsOneWidget);
      expect(find.text('旧白金信用卡'), findsNothing);
      expect(find.text('已销户工资卡'), findsNothing);
      expect(find.text('王五借款'), findsNothing);

      final archiveBtn = find.byKey(const Key('toggle-hidden-assets'));
      await tester.scrollUntilVisible(
        archiveBtn,
        120,
        scrollable: find.byType(Scrollable).first,
      );
      await _settle(tester, 4);
      expect(find.text('已归档账户（3） ›'), findsOneWidget);

      // Toggle hide amounts on AssetsPage -> ArchivedAssetsSheet respects hiddenAmounts ('***')!
      await tester.tap(find.byTooltip('隐藏金额'));
      await _settle(tester, 4);
      await tester.tap(archiveBtn);
      await _settle(tester);
      expect(tester.takeException(), isNull);

      expect(find.byType(ArchivedAssetsSheet), findsOneWidget);
      expect(find.text('已隐藏 (1)'), findsOneWidget);
      expect(find.text('已结清 (2)'), findsOneWidget);
      // Defaults to 已隐藏 because hiddenCount (1) > 0
      expect(find.text('旧白金信用卡'), findsOneWidget);
      expect(find.text('信用账户'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('archived-assets-sheet')),
          matching: find.text('***'),
        ),
        findsWidgets,
      );

      // Tap archived credit account -> opens AssetDetailPage modal-safely without GoRouter!
      await tester.tap(find.byKey(Key('archived-asset-$hiddenCreditId')));
      await _settle(tester);
      expect(find.byType(AssetDetailPage), findsOneWidget);
      await tester.pageBack();
      await _settle(tester);

      // Restore hidden credit account -> hiddenCount becomes 0; sheet stays open because 2 settled remain!
      await tester.tap(
        find.byKey(Key('restore-archived-asset-$hiddenCreditId')),
      );
      await _settle(tester);
      expect(find.text('已隐藏 (0)'), findsOneWidget);
      expect(find.text('暂无已隐藏账户'), findsOneWidget);

      // Close sheet, unhide amounts, and re-open sheet -> now hiddenCount == 0 && settledCount == 2 so it defaults directly to 已结清!
      Navigator.of(tester.element(find.byType(ArchivedAssetsSheet))).pop();
      await _settle(tester);
      await tester.tap(find.byTooltip('显示金额'));
      await _settle(tester, 4);
      expect(find.text('旧白金信用卡'), findsOneWidget);
      expect(find.text('已归档账户（2） ›'), findsOneWidget);

      await tester.tap(find.byKey(const Key('toggle-hidden-assets')));
      await _settle(tester);
      final tabsAfterReopen = tester.widget<SegmentedButton<int>>(
        find.byKey(const Key('archived-assets-tabs')),
      );
      expect(tabsAfterReopen.selected, <int>{AssetStatus.settled});
      expect(find.text('已销户工资卡'), findsOneWidget);
      expect(find.text('王五借款'), findsOneWidget);

      // Swipe right to 已隐藏 (0), then swipe left back to 已结清 (2)!
      await tester.fling(
        find.byKey(const Key('archived-assets-page-view')),
        const Offset(300, 0),
        1200,
      );
      await _settle(tester);
      expect(
        tester
            .widget<SegmentedButton<int>>(
              find.byKey(const Key('archived-assets-tabs')),
            )
            .selected,
        <int>{AssetStatus.hidden},
      );

      await tester.fling(
        find.byKey(const Key('archived-assets-page-view')),
        const Offset(-300, 0),
        1200,
      );
      await _settle(tester);
      expect(
        tester
            .widget<SegmentedButton<int>>(
              find.byKey(const Key('archived-assets-tabs')),
            )
            .selected,
        <int>{AssetStatus.settled},
      );

      // Tap settled debt -> opens DebtDetailPage modal-safely!
      await tester.tap(find.byKey(Key('archived-asset-$settledDebtId')));
      await _settle(tester);
      expect(find.byType(DebtDetailPage), findsOneWidget);
      await tester.pageBack();
      await _settle(tester);

      // Restore settled debt -> calls DebtService.reopenDebt so principal recomputes back to 400.00!
      await tester.tap(
        find.byKey(Key('restore-archived-asset-$settledDebtId')),
      );
      await _settle(tester);
      final reopenedDebt = await tester.runAsync(
        () => (db.select(
          db.assets,
        )..where((a) => a.id.equals(settledDebtId))).getSingle(),
      );
      expect(reopenedDebt!.status, AssetStatus.active);
      expect(reopenedDebt.balanceMinor, BigInt.from(40000));

      // Restore the final archived account -> sheet auto-closes and toggle-hidden-assets disappears!
      await tester.tap(
        find.byKey(Key('restore-archived-asset-$settledNormalId')),
      );
      await _settle(tester);
      expect(find.byType(ArchivedAssetsSheet), findsNothing);
      expect(find.byKey(const Key('toggle-hidden-assets')), findsNothing);
      expect(find.text('王五借款'), findsOneWidget);
      expect(find.text('400.00'), findsWidgets);

      await closeCleanly();
    },
  );

  testWidgets(
    '3) Dual-platform drag-and-drop reordering on AssetsPage (mobile long-press & desktop 1280x800 380px pane handle) + B-13 local context menu + B-15 ValueKey reset',
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
    (tester) async {
      final (db, closeCleanly) = await _openTestDb(tester);
      final ledger = LedgerService(db);

      late int a1, a2, c1, c2;
      await tester.runAsync(() async {
        a1 = await ledger.createAsset(
          commandId: 'drag-a1',
          name: '现金袋',
          initial: Money.parse('100.00'),
        );
        a2 = await ledger.createAsset(
          commandId: 'drag-a2',
          name: '工资储蓄卡',
          initial: Money.parse('2000.00'),
        );
        c1 = await ledger.createAsset(
          commandId: 'drag-c1',
          name: '花呗账户',
          type: AssetType.credit,
          initial: Money.parse('-50.00'),
          limit: Money.parse('5000.00'),
        );
        c2 = await ledger.createAsset(
          commandId: 'drag-c2',
          name: '招行白金卡',
          type: AssetType.credit,
          initial: Money.parse('-120.00'),
          limit: Money.parse('30000.00'),
        );
        await ledger.reorderAssets(
          commandId: 'drag-init-order',
          orderedAssetIds: <int>[a1, a2, c1, c2],
        );
      });

      // Part A: Mobile (!isDesktop) long-press drag reorder on normal group [a1, a2] -> [a2, a1]
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: DesktopAdaptiveScope(
            isDesktop: false,
            child: const MaterialApp(home: AssetsPage()),
          ),
        ),
      );
      await _settle(tester);

      final mobileItemA2 = find.byKey(ValueKey('asset-item-$a2'));
      final mobileItemA1 = find.byKey(ValueKey('asset-item-$a1'));
      expect(
        tester.getCenter(mobileItemA1).dy,
        lessThan(tester.getCenter(mobileItemA2).dy),
      );

      await _longPressDrag(
        tester,
        mobileItemA2,
        tester.getCenter(mobileItemA1) -
            tester.getCenter(mobileItemA2) -
            const Offset(0, 20),
      );

      expect(
        tester.getCenter(mobileItemA2).dy,
        lessThan(tester.getCenter(mobileItemA1).dy),
      );

      // Part B: Desktop 1280x800 (380px assets-master-pane @ 1.2x text scale) handle drag + B-15 ValueKey + B-13 offset Overlay!
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      await tester.pumpWidget(
        ProviderScope(
          key: const ValueKey('desk-assets-scope'),
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: DesktopAdaptiveScope(
            isDesktop: true,
            child: MaterialApp(
              builder: (ctx, child) => MediaQuery(
                data: MediaQuery.of(
                  ctx,
                ).copyWith(textScaler: const TextScaler.linear(1.2)),
                child: child!,
              ),
              home: const AssetsPage(),
            ),
          ),
        ),
      );
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byKey(const Key('assets-master-pane'))).width,
        380.0,
      );

      // B-15: Turn reconciliation switch ON for currently selected '工资储蓄卡' (a2), then click '现金袋' (a1) ->
      // ValueKey('pane-asset-$effectiveSelectedAssetId') resets reconciliation switch to OFF for the new account!
      final detailPane = find.byKey(const Key('assets-detail-pane'));
      await tester.tap(
        find.descendant(
          of: detailPane,
          matching: find.byKey(const Key('reconciliation-switch')),
        ),
      );
      await _settle(tester, 4);
      expect(
        tester
            .widget<Switch>(
              find.descendant(
                of: detailPane,
                matching: find.byKey(const Key('reconciliation-switch')),
              ),
            )
            .value,
        isTrue,
      );

      await tester.tap(find.byKey(const Key('asset-现金袋')));
      await _settle(tester, 6);
      expect(
        tester
            .widget<Switch>(
              find.descendant(
                of: detailPane,
                matching: find.byKey(const Key('reconciliation-switch')),
              ),
            )
            .value,
        isFalse,
      );

      // Desktop instant drag on credit handle Key('asset-drag-handle-$c2') above c1!
      final handleC2 = find.byKey(Key('asset-drag-handle-$c2'));
      final itemC1 = find.byKey(ValueKey('asset-item-$c1'));
      await _mouseDrag(
        tester,
        handleC2,
        tester.getCenter(itemC1) -
            tester.getCenter(handleC2) -
            const Offset(0, 20),
      );
      expect(tester.takeException(), isNull);

      final orderedAfterDesk = await tester.runAsync(
        () =>
            (db.select(db.assets)..orderBy([
                  (t) => OrderingTerm.asc(t.sort),
                  (t) => OrderingTerm.asc(t.id),
                ]))
                .get(),
      );
      expect(orderedAfterDesk!.map((a) => a.id).toList(), <int>[
        a2,
        a1,
        c2,
        c1,
      ]);

      // B-13: Mount AssetsPage inside an offset 300px padded Overlay and verify right-click menu positions near local coords!
      await tester.pumpWidget(
        ProviderScope(
          key: const ValueKey('offset-overlay-scope'),
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: DesktopAdaptiveScope(
            isDesktop: true,
            child: MaterialApp(
              home: Padding(
                padding: const EdgeInsets.only(left: 320, top: 120),
                child: ClipRect(
                  child: Navigator(
                    onDidRemovePage: (_) {},
                    pages: const <Page<void>>[
                      MaterialPage<void>(
                        child: AssetsPage(standaloneManagement: true),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await _settle(tester);

      final tileInOffsetOverlay = find.byKey(const Key('asset-工资储蓄卡'));
      final tapGlobal = tester.getCenter(tileInOffsetOverlay);
      await tester.tapAt(tapGlobal, buttons: kSecondaryMouseButton);
      await _settle(tester, 6);
      final menuItemBox = tester.getRect(find.text('查看账户流水'));
      // With globalToLocal conversion inside the +320px offset overlay, menu x stays near tapGlobal.dx (not shifted +320px further right!).
      expect((menuItemBox.left - tapGlobal.dx).abs(), lessThan(220));

      await closeCleanly();
    },
  );

  testWidgets(
    '4) B-27 preserves manually chosen generic bank_card/credit_card on rename, and B-02/B-10 closes imperative AssetEditorPage modal without popping GoRouter underneath',
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final (db, closeCleanly) = await _openTestDb(tester);
      final ledger = LedgerService(db);

      late int manualGenericBankId;
      late int autoFallbackId;
      await tester.runAsync(() async {
        // '招行储蓄卡' normally auto-resolves to 'builtin:bank.cmb', so 'bank_card' (#1565C0) was manually picked!
        manualGenericBankId = await ledger.createAsset(
          commandId: 'b27-manual',
          name: '招行储蓄卡',
          icon: 'bank_card',
          color: '#1565C0',
          initial: Money.parse('500.00'),
        );
        // '我的零花袋' auto-resolves to 'bank_card' (#1565C0), so renaming to '微信零钱' SHOULD auto-switch!
        autoFallbackId = await ledger.createAsset(
          commandId: 'b27-auto',
          name: '我的零花袋',
          icon: 'bank_card',
          color: '#1565C0',
          initial: Money.parse('100.00'),
        );
      });

      final router = GoRouter(
        initialLocation: '/base',
        routes: [
          GoRoute(
            path: '/base',
            builder: (_, _) => const Scaffold(body: Text('BASE_PAGE')),
          ),
          GoRoute(
            path: '/pushed',
            builder: (ctx, _) => Scaffold(
              body: Column(
                children: [
                  const Text('PUSHED_GOROUTER_PAGE'),
                  ElevatedButton(
                    key: const Key('open-imp-editor-manual'),
                    onPressed: () => pushDesktopModalOrMaterialRoute<void>(
                      ctx,
                      child: AssetEditorPage(assetId: manualGenericBankId),
                    ),
                    child: const Text('打开手动图标账户'),
                  ),
                  ElevatedButton(
                    key: const Key('open-imp-editor-auto'),
                    onPressed: () => pushDesktopModalOrMaterialRoute<void>(
                      ctx,
                      child: AssetEditorPage(assetId: autoFallbackId),
                    ),
                    child: const Text('打开自动图标账户'),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: DesktopAdaptiveScope(
            isDesktop: true,
            child: MaterialApp.router(routerConfig: router),
          ),
        ),
      );
      await _settle(tester);

      // Push '/pushed' on GoRouter so GoRouter.canPop() == true!
      unawaited(router.push('/pushed'));
      await _settle(tester);
      expect(find.text('PUSHED_GOROUTER_PAGE'), findsOneWidget);

      // Open imperative desktop modal AssetEditorPage on top of '/pushed', rename '招行储蓄卡' -> '招行工资卡', and save!
      await tester.tap(find.byKey(const Key('open-imp-editor-manual')));
      await _settle(tester);
      await tester.enterText(find.byKey(const Key('asset-name')), '招行工资卡');
      await tester.tap(find.byKey(const Key('asset-save')));
      await _settle(tester);

      // B-02/B-10: Modal closed AND '/pushed' GoRouter route underneath was NOT popped!
      expect(find.byType(AssetEditorPage), findsNothing);
      expect(find.text('PUSHED_GOROUTER_PAGE'), findsOneWidget);

      // B-27: Manually chosen 'bank_card' (#1565C0) was preserved!
      final manualAfter = await tester.runAsync(
        () => (db.select(
          db.assets,
        )..where((a) => a.id.equals(manualGenericBankId))).getSingle(),
      );
      expect(manualAfter!.name, '招行工资卡');
      expect(manualAfter.icon, 'bank_card');
      expect(manualAfter.color, '#1565C0');

      // Rename auto-assigned '我的零花袋' -> '微信零钱' -> smartly updates to 'wechat_pay'!
      await tester.tap(find.byKey(const Key('open-imp-editor-auto')));
      await _settle(tester);
      await tester.enterText(find.byKey(const Key('asset-name')), '微信零钱');
      await tester.tap(find.byKey(const Key('asset-save')));
      await _settle(tester);

      final autoAfter = await tester.runAsync(
        () => (db.select(
          db.assets,
        )..where((a) => a.id.equals(autoFallbackId))).getSingle(),
      );
      expect(autoAfter!.icon, 'wechat_pay');

      await closeCleanly();
    },
  );

  testWidgets(
    '5) DiyToolbarSettingsPage desktop drag reorder & B-09 loading disable, PeriodicPage 3-tab swipe, B-02 Savings/Installment maybePop, and B-17 unique FAB heroTags',
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
    (tester) async {
      final (db, closeCleanly) = await _openTestDb(tester);
      final attSvc = BillAttachmentService(db);

      late int planId;
      late int instId;
      await tester.runAsync(() async {
        final pausedId = await PeriodicService(db).savePeriod(
          commandId: 'per-paused',
          draft: PeriodicDraft(
            recordType: RecordType.expense,
            money: Money.parse('15.00'),
            bookId: 1,
            categoryId: 1,
            assetId: noRef,
            periodType: PeriodType.daily,
            periodStartDate: const CalendarDate(2026, 12, 1).startOfDayMs,
            remark: '停用订阅',
          ),
        );
        await PeriodicService(
          db,
        ).pausePeriod(commandId: 'do-per-pause', periodId: pausedId);
        final creditId = await LedgerService(db).createAsset(
          commandId: 'inst-crd',
          name: '分期卡',
          type: AssetType.credit,
          initial: Money.zero(),
          limit: Money.parse('10000.00'),
        );
        planId = await SavingsService(db).savePlan(
          commandId: 'sav-root',
          draft: SavingsPlanDraft(
            name: '根路由存钱计划',
            planType: SavingsPlanType.free,
            startDateMs: DateTime(2026, 6, 1).millisecondsSinceEpoch,
            customPlanMoneyMinor: BigInt.from(100000),
          ),
        );
        instId = await InstallmentService(db).createInstallment(
          commandId: 'inst-root',
          draft: InstallmentDraft(
            name: '根路由分期',
            principal: Money.parse('600.00'),
            periods: 3,
            charge: Money.zero(),
            startDateMs: DateTime(2026, 12, 1).millisecondsSinceEpoch,
            assetId: creditId,
            bookId: 1,
            catId: 1,
          ),
        );
      });

      // 5a. B-09: While diyToolbarConfigProvider is still loading, diy-toolbar-reset-btn is disabled!
      final neverConfig = Completer<DiyToolbarConfig>();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            diyToolbarConfigProvider.overrideWith(
              (ref) => Stream<DiyToolbarConfig>.fromFuture(neverConfig.future),
            ),
          ],
          child: const MaterialApp(home: DiyToolbarSettingsPage()),
        ),
      );
      await tester.pump();
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('diy-toolbar-reset-btn')))
            .onPressed,
        isNull,
      );
      neverConfig.complete(DiyToolbarConfig.defaults());
      await tester.pump();

      // 5b. Desktop DiyToolbarSettingsPage drag reorder via leading drag handle!
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        ProviderScope(
          key: const ValueKey('desk-diy-scope'),
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: DesktopAdaptiveScope(
            isDesktop: true,
            child: const MaterialApp(home: DiyToolbarSettingsPage()),
          ),
        ),
      );
      await _settle(tester);
      expect(find.byKey(const Key('diy-drag-handle-tags')), findsOneWidget);

      final handleImages = find.byKey(const Key('diy-drag-handle-images'));
      final rowTags = find.byKey(const ValueKey('diy-row-tags'));
      await _mouseDrag(
        tester,
        handleImages,
        Offset(
          0,
          tester.getCenter(rowTags).dy - tester.getCenter(handleImages).dy - 20,
        ),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester, 4);

      final cfgAfterDrag = await tester.runAsync(attSvc.getDiyToolbarConfig);
      expect(cfgAfterDrag!.items.first.action, DiyToolbarAction.images);

      // 5c. PeriodicPage 3-tab PageView swipe (进行中 ⇄ 已结束 ⇄ 已停用)!
      await tester.binding.setSurfaceSize(const Size(390, 844));
      late ProviderContainer perContainer;
      await tester.pumpWidget(
        ProviderScope(
          key: const ValueKey('periodic-swipe-scope'),
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: DesktopAdaptiveScope(
            isDesktop: false,
            child: Builder(
              builder: (ctx) {
                perContainer = ProviderScope.containerOf(ctx, listen: false);
                return const MaterialApp(home: PeriodicPage());
              },
            ),
          ),
        ),
      );
      await _settle(tester);
      expect(perContainer.read(periodicTabProvider), PeriodState.active);

      // Swipe left -> 已结束 (1), swipe left again -> 已停用 (2)!
      await tester.fling(
        find.byKey(const Key('periodic_page_view')),
        const Offset(-300, 0),
        1200,
      );
      await _settle(tester);
      expect(perContainer.read(periodicTabProvider), PeriodState.ended);

      await tester.fling(
        find.byKey(const Key('periodic_page_view')),
        const Offset(-300, 0),
        1200,
      );
      await _settle(tester);
      expect(perContainer.read(periodicTabProvider), PeriodState.paused);
      expect(find.textContaining('停用订阅'), findsOneWidget);

      // 5d. B-02 safe maybePop when SavingsDetailPage & InstallmentDetailPage are deleted!

      await tester.pumpWidget(
        ProviderScope(
          key: const ValueKey('sav-root-scope'),
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: DesktopAdaptiveScope(
            isDesktop: false,
            child: MaterialApp(home: SavingsDetailPage(planId: planId)),
          ),
        ),
      );
      await _settle(tester);
      await tester.tap(find.byKey(const Key('delete_savings_plan_button')));
      await _settle(tester, 4);
      await tester.tap(find.byKey(const Key('confirm_delete_plan_button')));
      await _settle(tester);
      expect(tester.takeException(), isNull);

      // InstallmentDetailPage both pushed (verifies PopScope + maybePop actually pops!) and standalone root!
      await tester.pumpWidget(
        ProviderScope(
          key: const ValueKey('inst-pushed-scope'),
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: DesktopAdaptiveScope(
            isDesktop: false,
            child: MaterialApp(
              home: Builder(
                builder: (ctx) => Scaffold(
                  body: ElevatedButton(
                    key: const Key('push-inst-detail'),
                    onPressed: () => Navigator.of(ctx).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            InstallmentDetailPage(installmentId: instId),
                      ),
                    ),
                    child: const Text('OPEN_INST'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await _settle(tester);
      await tester.tap(find.byKey(const Key('push-inst-detail')));
      await _settle(tester);
      expect(find.byType(InstallmentDetailPage), findsOneWidget);
      await tester.tap(find.byKey(const Key('delete_installment_button')));
      await _settle(tester, 4);
      await tester.tap(
        find.byKey(const Key('confirm_delete_installment_button')),
      );
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(InstallmentDetailPage), findsNothing);
      expect(find.text('OPEN_INST'), findsOneWidget);

      // 5e. B-17: Verify every one of the 7 mobile pages sets an explicit unique non-default heroTag on its FAB!
      final pagesToCheck = <(Widget, Key, String)>[
        (
          const PeriodicPage(),
          const Key('add_periodic_button'),
          'fab-periodic',
        ),
        (
          const InstallmentPage(autoCatchUpOnOpen: false),
          const Key('add_installment_fab'),
          'fab-installment',
        ),
        (const SavingsPage(), const Key('add_savings_plan_fab'), 'fab-savings'),
        (
          const FixedDepositPage(),
          const Key('add_deposit_fab'),
          'fab-fixed-deposit',
        ),
        (const WishesPage(), const Key('add_wish_fab'), 'fab-wishes'),
        (const NotesPage(), const Key('add_note_fab'), 'fab-notes'),
        (
          const StatStoriesPage(),
          const Key('stat_story_add_fab'),
          'fab-stat-stories',
        ),
      ];
      final seenHeroTags = <Object>{};
      for (final (idx, (page, fabKey, expectedTag)) in pagesToCheck.indexed) {
        await tester.pumpWidget(
          ProviderScope(
            key: ValueKey('hero-check-$idx'),
            retry: (_, _) => null,
            overrides: [databaseProvider.overrideWith((ref) async => db)],
            child: DesktopAdaptiveScope(
              isDesktop: false,
              child: MaterialApp(home: page),
            ),
          ),
        );
        await _settle(tester, 6);
        final fab = tester.widget<FloatingActionButton>(find.byKey(fabKey));
        expect(fab.heroTag, expectedTag);
        expect(seenHeroTags.add(fab.heroTag!), isTrue);
      }
      expect(seenHeroTags, hasLength(7));

      await closeCleanly();
    },
  );
}
