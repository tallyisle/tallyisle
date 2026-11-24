import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/data/tools/bill_attachment_service.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/features/assets/asset_detail_page.dart';
import 'package:tallyisle/features/assets/asset_editor_page.dart';
import 'package:tallyisle/features/receipt/receipt_diy_providers.dart';
import 'package:tallyisle/features/records/record_editor_page.dart';

Future<void> _settle(WidgetTester tester, [int ticks = 12]) async {
  await tester.pump();
  for (var i = 0; i < ticks; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(Duration.zero);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump();
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
    await _settle(tester, 6);
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

Future<void> _scrollToDefaultSwitch(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.byKey(const Key('asset-default-account-switch')),
    120,
    scrollable: find
        .descendant(
          of: find.byType(AssetEditorPage),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await _settle(tester, 4);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets(
    '1) Global single default: setting A then B unsets A, editing non-default C preserves B, and RecordEditorPage preselects B',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final (db, closeCleanly) = await _openTestDb(tester);
      final ledger = LedgerService(db);
      final attSvc = BillAttachmentService(db);

      late int assetA;
      late int assetB;
      late int assetC;
      await tester.runAsync(() async {
        assetA = await ledger.createAsset(
          commandId: 'create-a',
          name: '招行储蓄卡',
          initial: Money.parse('2000.00'),
        );
        assetB = await ledger.createAsset(
          commandId: 'create-b',
          name: '工行信用卡',
          type: AssetType.credit,
          initial: Money.parse('-150.00'),
          limit: Money.parse('15000.00'),
        );
        assetC = await ledger.createAsset(
          commandId: 'create-c',
          name: '现金钱包',
          initial: Money.parse('300.00'),
        );
      });

      final activePage = ValueNotifier<Widget>(
        AssetEditorPage(key: ValueKey('edit-a-1'), assetId: assetA),
      );
      addTearDown(activePage.dispose);

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: ValueListenableBuilder<Widget>(
            valueListenable: activePage,
            builder: (_, page, _) => MaterialApp(home: page),
          ),
        ),
      );
      await _settle(tester);

      // Step 1: Set A as default.
      await _scrollToDefaultSwitch(tester);
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const Key('asset-default-account-switch')),
            )
            .value,
        isFalse,
      );
      await tester.tap(find.byKey(const Key('asset-default-account-switch')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('asset-save')));
      await _settle(tester);

      var cfg = await tester.runAsync(attSvc.getDiyToolbarConfig);
      expect(cfg!.autoSelectDefaultAccount, isTrue);
      expect(cfg.defaultAccountId, assetA);

      // AssetDetailPage shows '默认账户' chip for A.
      activePage.value = AssetDetailPage(
        key: const ValueKey('detail-a'),
        assetId: assetA,
      );
      await _settle(tester);
      expect(
        find.byKey(const Key('asset-detail-default-chip')),
        findsOneWidget,
      );

      // Step 2: Set B as default -> A is automatically unset!
      activePage.value = AssetEditorPage(
        key: const ValueKey('edit-b-1'),
        assetId: assetB,
      );
      await _settle(tester);
      await _scrollToDefaultSwitch(tester);
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const Key('asset-default-account-switch')),
            )
            .value,
        isFalse,
      );
      await tester.tap(find.byKey(const Key('asset-default-account-switch')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('asset-save')));
      await _settle(tester);

      cfg = await tester.runAsync(attSvc.getDiyToolbarConfig);
      expect(cfg!.autoSelectDefaultAccount, isTrue);
      expect(cfg.defaultAccountId, assetB);

      // Re-open A -> switch is now OFF!
      activePage.value = AssetEditorPage(
        key: const ValueKey('edit-a-2'),
        assetId: assetA,
      );
      await _settle(tester);
      await _scrollToDefaultSwitch(tester);
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const Key('asset-default-account-switch')),
            )
            .value,
        isFalse,
      );

      // Step 3: Edit non-default account C (even toggling ON then back OFF before saving) -> B stays default!
      activePage.value = AssetEditorPage(
        key: const ValueKey('edit-c-1'),
        assetId: assetC,
      );
      await _settle(tester);
      await tester.enterText(find.byKey(const Key('asset-name')), '日常现金');
      await _scrollToDefaultSwitch(tester);
      await tester.tap(find.byKey(const Key('asset-default-account-switch')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('asset-default-account-switch')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('asset-save')));
      await _settle(tester);

      cfg = await tester.runAsync(attSvc.getDiyToolbarConfig);
      expect(cfg!.autoSelectDefaultAccount, isTrue);
      expect(cfg.defaultAccountId, assetB);

      // Step 4: RecordEditorPage preselects B ('工行信用卡')!
      activePage.value = const RecordEditorPage(key: ValueKey('rec-b'));
      await _settle(tester);
      expect(
        find.descendant(
          of: find.byKey(const Key('asset')),
          matching: find.text('工行信用卡'),
        ),
        findsOneWidget,
      );

      await closeCleanly();
    },
  );

  testWidgets(
    '2) Cancel default: turning OFF 设为默认账户 on current default account clears default setting and RecordEditorPage uses no-default behavior',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final (db, closeCleanly) = await _openTestDb(tester);
      final ledger = LedgerService(db);
      final attSvc = BillAttachmentService(db);

      late int assetA;
      await tester.runAsync(() async {
        assetA = await ledger.createAsset(
          commandId: 'cancel-a',
          name: '微信零钱',
          initial: Money.parse('880.00'),
        );
        final initialCfg = await attSvc.getDiyToolbarConfig();
        await attSvc.saveDiyToolbarConfig(
          commandId: 'seed-cancel-default',
          config: initialCfg
              .copyWithStyles(
                datePickerStyle: RecordDatePickerStyle.wheel,
                timePickerStyle: RecordTimePickerStyle.dial,
              )
              .setEnabled(DiyToolbarAction.autoSelectFirstCategory, true)
              .copyWithDefaultAccount(
                autoSelectDefaultAccount: true,
                defaultAccountId: assetA,
              ),
        );
      });

      final activePage = ValueNotifier<Widget>(
        AssetEditorPage(key: const ValueKey('cancel-edit-a'), assetId: assetA),
      );
      addTearDown(activePage.dispose);

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: ValueListenableBuilder<Widget>(
            valueListenable: activePage,
            builder: (_, page, _) => MaterialApp(home: page),
          ),
        ),
      );
      await _settle(tester);

      await _scrollToDefaultSwitch(tester);
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const Key('asset-default-account-switch')),
            )
            .value,
        isTrue,
      );

      // Turn OFF and save.
      await tester.tap(find.byKey(const Key('asset-default-account-switch')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('asset-save')));
      await _settle(tester);

      final cfg = await tester.runAsync(attSvc.getDiyToolbarConfig);
      expect(cfg!.autoSelectDefaultAccount, isFalse);
      expect(cfg.defaultAccountId, noRef);
      // Other DIY toolbar settings in ti_preference ('record_diy_toolbar') remain intact!
      expect(cfg.datePickerStyle, RecordDatePickerStyle.wheel);
      expect(cfg.timePickerStyle, RecordTimePickerStyle.dial);
      expect(cfg.isEnabled(DiyToolbarAction.autoSelectFirstCategory), isTrue);

      // RecordEditorPage follows no-default-account behavior ('不选账户' / transfer '选择账户').
      activePage.value = const RecordEditorPage(key: ValueKey('rec-none'));
      await _settle(tester);
      expect(
        find.descendant(
          of: find.byKey(const Key('asset')),
          matching: find.text('不选账户'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('type-2'))); // 转账
      await _settle(tester, 3);
      expect(
        find.descendant(
          of: find.byKey(const Key('from')),
          matching: find.text('选择账户'),
        ),
        findsOneWidget,
      );

      await closeCleanly();
    },
  );

  testWidgets(
    '3) Create brand-new account with 设为默认账户 ON makes new account the default (and creating with OFF preserves existing default)',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final (db, closeCleanly) = await _openTestDb(tester);
      final ledger = LedgerService(db);
      final attSvc = BillAttachmentService(db);

      late int oldDefaultId;
      await tester.runAsync(() async {
        oldDefaultId = await ledger.createAsset(
          commandId: 'old-def',
          name: '旧默认卡',
          initial: Money.parse('100.00'),
        );
        final initialCfg = await attSvc.getDiyToolbarConfig();
        await attSvc.saveDiyToolbarConfig(
          commandId: 'seed-old-def',
          config: initialCfg.copyWithDefaultAccount(
            autoSelectDefaultAccount: true,
            defaultAccountId: oldDefaultId,
          ),
        );
      });

      final activePage = ValueNotifier<Widget>(
        const AssetEditorPage(key: ValueKey('create-new-default')),
      );
      addTearDown(activePage.dispose);

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: ValueListenableBuilder<Widget>(
            valueListenable: activePage,
            builder: (_, page, _) => MaterialApp(home: page),
          ),
        ),
      );
      await _settle(tester);

      // Create '新建工资卡' with '设为默认账户' ON!
      await tester.enterText(find.byKey(const Key('asset-name')), '新建工资卡');
      await tester.enterText(find.byKey(const Key('asset-balance')), '5000');
      await _scrollToDefaultSwitch(tester);
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const Key('asset-default-account-switch')),
            )
            .value,
        isFalse,
      );
      await tester.tap(find.byKey(const Key('asset-default-account-switch')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('asset-save')));
      await _settle(tester);

      final allAssets = await tester.runAsync(() => db.select(db.assets).get());
      final createdSalaryCard = allAssets!.singleWhere(
        (a) => a.name == '新建工资卡',
      );
      var cfg = await tester.runAsync(attSvc.getDiyToolbarConfig);
      expect(cfg!.autoSelectDefaultAccount, isTrue);
      expect(cfg.defaultAccountId, createdSalaryCard.id);

      // Create another account '普通备用金' with '设为默认账户' left OFF -> '新建工资卡' remains default!
      activePage.value = const AssetEditorPage(
        key: ValueKey('create-non-default'),
      );
      await _settle(tester);
      await tester.enterText(find.byKey(const Key('asset-name')), '普通备用金');
      await tester.tap(find.byKey(const Key('asset-save')));
      await _settle(tester);

      cfg = await tester.runAsync(attSvc.getDiyToolbarConfig);
      expect(cfg!.autoSelectDefaultAccount, isTrue);
      expect(cfg.defaultAccountId, createdSalaryCard.id);

      // Old default account switch is OFF; RecordEditorPage preselects '新建工资卡'!
      activePage.value = AssetEditorPage(
        key: const ValueKey('check-old-def'),
        assetId: oldDefaultId,
      );
      await _settle(tester);
      await _scrollToDefaultSwitch(tester);
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const Key('asset-default-account-switch')),
            )
            .value,
        isFalse,
      );

      activePage.value = const RecordEditorPage(key: ValueKey('rec-new-def'));
      await _settle(tester);
      expect(
        find.descendant(
          of: find.byKey(const Key('asset')),
          matching: find.text('新建工资卡'),
        ),
        findsOneWidget,
      );

      await closeCleanly();
    },
  );

  testWidgets(
    '4) Hidden/settled accounts cannot be set as default, and hiding/settling/deleting current default account auto-clears default setting & updates Riverpod provider',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final (db, closeCleanly) = await _openTestDb(tester);
      final ledger = LedgerService(db);
      final attSvc = BillAttachmentService(db);

      late int hiddenId;
      late int settledId;
      late int hideTargetId;
      late int settleTargetId;
      late int deleteTargetId;
      late int bystanderId;

      await tester.runAsync(() async {
        hiddenId = await ledger.createAsset(
          commandId: 'pre-hidden',
          name: '已隐藏卡',
          initial: Money.parse('20.00'),
        );
        await ledger.setAssetStatus(
          commandId: 'do-pre-hide',
          assetId: hiddenId,
          status: AssetStatus.hidden,
        );
        settledId = await ledger.createAsset(
          commandId: 'pre-settled',
          name: '已结清卡',
          initial: Money.zero(),
        );
        await ledger.setAssetStatus(
          commandId: 'do-pre-settle',
          assetId: settledId,
          status: AssetStatus.settled,
        );
        hideTargetId = await ledger.createAsset(
          commandId: 'target-hide',
          name: '待隐藏默认卡',
          initial: Money.parse('500.00'),
        );
        settleTargetId = await ledger.createAsset(
          commandId: 'target-settle',
          name: '待结清默认卡',
          initial: Money.zero(),
        );
        deleteTargetId = await ledger.createAsset(
          commandId: 'target-delete',
          name: '待删除默认卡',
          initial: Money.zero(),
        );
        bystanderId = await ledger.createAsset(
          commandId: 'bystander',
          name: '无关旁路卡',
          initial: Money.zero(),
        );
      });

      final activePage = ValueNotifier<Widget>(
        AssetEditorPage(key: const ValueKey('edit-hidden'), assetId: hiddenId),
      );
      addTearDown(activePage.dispose);

      DiyToolbarConfig? latestWatchedConfig;

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: ValueListenableBuilder<Widget>(
            valueListenable: activePage,
            builder: (_, page, _) => MaterialApp(
              builder: (context, child) => Consumer(
                builder: (context, ref, _) {
                  latestWatchedConfig = ref
                      .watch(diyToolbarConfigProvider)
                      .value;
                  return child!;
                },
              ),
              home: page,
            ),
          ),
        ),
      );
      await _settle(tester);

      // (a) Hidden account cannot be set as default (value=false, disabled, clear subtitle).
      await _scrollToDefaultSwitch(tester);
      final hiddenSwitch = tester.widget<SwitchListTile>(
        find.byKey(const Key('asset-default-account-switch')),
      );
      expect(hiddenSwitch.value, isFalse);
      expect(hiddenSwitch.onChanged, isNull);
      expect(find.text('该账户当前已隐藏，恢复为正常状态后才可设为默认账户'), findsOneWidget);

      // (b) Settled account cannot be set as default (value=false, disabled, clear subtitle).
      activePage.value = AssetEditorPage(
        key: const ValueKey('edit-settled'),
        assetId: settledId,
      );
      await _settle(tester);
      await _scrollToDefaultSwitch(tester);
      final settledSwitch = tester.widget<SwitchListTile>(
        find.byKey(const Key('asset-default-account-switch')),
      );
      expect(settledSwitch.value, isFalse);
      expect(settledSwitch.onChanged, isNull);
      expect(find.text('该账户当前已结清，恢复为正常状态后才可设为默认账户'), findsOneWidget);

      // (c) Set hideTargetId as default, then hide via AssetDetailPage menu -> auto-clears default & updates provider!
      final baseCfg = await tester.runAsync(attSvc.getDiyToolbarConfig);
      await tester.runAsync(
        () => attSvc.saveDiyToolbarConfig(
          commandId: 'set-hide-target-default',
          config: baseCfg!.copyWithDefaultAccount(
            autoSelectDefaultAccount: true,
            defaultAccountId: hideTargetId,
          ),
        ),
      );
      await _settle(tester);
      expect(latestWatchedConfig?.autoSelectDefaultAccount, isTrue);
      expect(latestWatchedConfig?.defaultAccountId, hideTargetId);

      // Hiding/deleting a NON-default bystander account must NOT clear hideTargetId!
      await tester.runAsync(
        () => ledger.setAssetStatus(
          commandId: 'hide-bystander',
          assetId: bystanderId,
          status: AssetStatus.hidden,
        ),
      );
      await _settle(tester, 4);
      await tester.runAsync(
        () => ledger.deleteAsset(
          commandId: 'delete-bystander',
          assetId: bystanderId,
        ),
      );
      await _settle(tester);
      expect(latestWatchedConfig?.autoSelectDefaultAccount, isTrue);
      expect(latestWatchedConfig?.defaultAccountId, hideTargetId);

      // Now hide hideTargetId from AssetDetailPage UI menu ('隐藏账户')!
      activePage.value = AssetDetailPage(
        key: const ValueKey('detail-hide-target'),
        assetId: hideTargetId,
      );
      await _settle(tester);
      expect(
        find.byKey(const Key('asset-detail-default-chip')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('asset-menu')));
      await _settle(tester, 8);
      await tester.tap(find.text('隐藏账户'));
      await _settle(tester, 14);

      var persisted = await tester.runAsync(attSvc.getDiyToolbarConfig);
      expect(persisted!.autoSelectDefaultAccount, isFalse);
      expect(persisted.defaultAccountId, noRef);
      expect(latestWatchedConfig?.autoSelectDefaultAccount, isFalse);
      expect(latestWatchedConfig?.defaultAccountId, noRef);
      expect(find.byKey(const Key('asset-detail-default-chip')), findsNothing);

      // Unhiding hideTargetId back to active must NOT silently re-enable it as default!
      await tester.tap(find.byKey(const Key('asset-menu')));
      await _settle(tester, 4);
      await tester.tap(find.text('取消隐藏'));
      await _settle(tester);
      persisted = await tester.runAsync(attSvc.getDiyToolbarConfig);
      expect(persisted!.autoSelectDefaultAccount, isFalse);
      expect(persisted.defaultAccountId, noRef);

      // (d) Set settleTargetId as default, then mark settled -> auto-clears default!
      final cfgBeforeSettle = await tester.runAsync(attSvc.getDiyToolbarConfig);
      await tester.runAsync(
        () => attSvc.saveDiyToolbarConfig(
          commandId: 'set-settle-target-default',
          config: cfgBeforeSettle!.copyWithDefaultAccount(
            autoSelectDefaultAccount: true,
            defaultAccountId: settleTargetId,
          ),
        ),
      );
      await _settle(tester);
      expect(latestWatchedConfig?.defaultAccountId, settleTargetId);

      await tester.runAsync(
        () => ledger.setAssetStatus(
          commandId: 'settle-default-target',
          assetId: settleTargetId,
          status: AssetStatus.settled,
        ),
      );
      await _settle(tester);
      persisted = await tester.runAsync(attSvc.getDiyToolbarConfig);
      expect(persisted!.autoSelectDefaultAccount, isFalse);
      expect(persisted.defaultAccountId, noRef);
      expect(latestWatchedConfig?.autoSelectDefaultAccount, isFalse);
      expect(latestWatchedConfig?.defaultAccountId, noRef);

      // (e) Set deleteTargetId as default, then delete via AssetDetailPage menu ('删除账户') -> auto-clears default!
      final cfgBeforeDelete = await tester.runAsync(attSvc.getDiyToolbarConfig);
      await tester.runAsync(
        () => attSvc.saveDiyToolbarConfig(
          commandId: 'set-delete-target-default',
          config: cfgBeforeDelete!.copyWithDefaultAccount(
            autoSelectDefaultAccount: true,
            defaultAccountId: deleteTargetId,
          ),
        ),
      );
      await _settle(tester);
      expect(latestWatchedConfig?.autoSelectDefaultAccount, isTrue);
      expect(latestWatchedConfig?.defaultAccountId, deleteTargetId);

      activePage.value = AssetDetailPage(
        key: const ValueKey('detail-delete-target'),
        assetId: deleteTargetId,
      );
      await _settle(tester);
      await tester.tap(find.byKey(const Key('asset-menu')));
      await _settle(tester, 8);
      await tester.tap(find.text('删除账户'));
      await _settle(tester, 10);
      await tester.tap(find.text('删除'));
      await _settle(tester, 14);

      persisted = await tester.runAsync(attSvc.getDiyToolbarConfig);
      expect(persisted!.autoSelectDefaultAccount, isFalse);
      expect(persisted.defaultAccountId, noRef);
      expect(latestWatchedConfig?.autoSelectDefaultAccount, isFalse);
      expect(latestWatchedConfig?.defaultAccountId, noRef);

      // RecordEditorPage cleanly shows '不选账户'!
      activePage.value = const RecordEditorPage(
        key: ValueKey('rec-after-delete'),
      );
      await _settle(tester);
      expect(
        find.descendant(
          of: find.byKey(const Key('asset')),
          matching: find.text('不选账户'),
        ),
        findsOneWidget,
      );

      await closeCleanly();
    },
  );

  testWidgets(
    '5) B-06 atomic setAsDefaultAccount in LedgerService.createAsset & updateAsset rolls back cleanly on validation failure',
    (tester) async {
      final (db, closeCleanly) = await _openTestDb(tester);
      final ledger = LedgerService(db);
      final attSvc = BillAttachmentService(db);

      late int createdDefaultId;
      late int secondId;
      await tester.runAsync(() async {
        createdDefaultId = await ledger.createAsset(
          commandId: 'atomic-create-def',
          name: '原子默认卡',
          initial: Money.parse('600.00'),
          setAsDefaultAccount: true,
        );
        secondId = await ledger.createAsset(
          commandId: 'atomic-create-2',
          name: '第二张卡',
          initial: Money.parse('200.00'),
          setAsDefaultAccount: false,
        );
      });

      var cfg = await tester.runAsync(attSvc.getDiyToolbarConfig);
      expect(cfg!.autoSelectDefaultAccount, isTrue);
      expect(cfg.defaultAccountId, createdDefaultId);

      // Failing updateAsset (negative credit limit) must roll back and NOT touch ti_preference!
      await tester.runAsync(() async {
        await expectLater(
          () => ledger.updateAsset(
            commandId: 'atomic-fail-upd',
            assetId: secondId,
            name: '第二张卡',
            countedInNetWorth: true,
            limit: Money.parse('-1.00'),
            setAsDefaultAccount: true,
          ),
          throwsA(anything),
        );
      });
      cfg = await tester.runAsync(attSvc.getDiyToolbarConfig);
      expect(cfg!.defaultAccountId, createdDefaultId);

      // Valid updateAsset switches default atomically to secondId, then unsets it atomically.
      await tester.runAsync(() async {
        await ledger.updateAsset(
          commandId: 'atomic-ok-upd-on',
          assetId: secondId,
          name: '第二张主力卡',
          countedInNetWorth: true,
          setAsDefaultAccount: true,
        );
      });
      cfg = await tester.runAsync(attSvc.getDiyToolbarConfig);
      expect(cfg!.autoSelectDefaultAccount, isTrue);
      expect(cfg.defaultAccountId, secondId);

      await tester.runAsync(() async {
        await ledger.updateAsset(
          commandId: 'atomic-ok-upd-off',
          assetId: secondId,
          name: '第二张主力卡',
          countedInNetWorth: true,
          setAsDefaultAccount: false,
        );
      });
      cfg = await tester.runAsync(attSvc.getDiyToolbarConfig);
      expect(cfg!.autoSelectDefaultAccount, isFalse);
      expect(cfg.defaultAccountId, noRef);

      await closeCleanly();
    },
  );
}
