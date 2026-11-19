import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/catalog/catalog_service.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/db/seed.dart' show defaultBookId;
import 'package:tallyisle/data/debt/debt_service.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/data/tools/bill_attachment_service.dart';
import 'package:tallyisle/data/tools/template_remark_service.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/app_settings_rules.dart';
import 'package:tallyisle/features/assets/asset_editor_page.dart';
import 'package:tallyisle/features/receipt/diy_toolbar_settings_page.dart';
import 'package:tallyisle/features/records/desktop_record_editor_dialog.dart';
import 'package:tallyisle/features/records/record_editor_page.dart';
import 'package:tallyisle/features/settings/settings_page.dart';

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

Future<void> _tapKeypadDigits(WidgetTester tester, List<String> keys) async {
  for (final k in keys) {
    await tester.tap(find.byKey(Key('keypad-$k')));
    await tester.pump();
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('Pure-Dart Domain: DiyToolbarConfig & resolveEffectiveDefaultAccountId', () {
    test(
      'DiyToolbarConfig preserves autoSelectDefaultAccount & defaultAccountId across all transformations and decodes legacy JSON safely',
      () {
        final defaults = DiyToolbarConfig.defaults();
        expect(defaults.autoSelectDefaultAccount, isFalse);
        expect(defaults.defaultAccountId, noRef);

        // <= 0 normalizes to noRef (-1)
        final zeroNorm = defaults.copyWithDefaultAccount(
          autoSelectDefaultAccount: true,
          defaultAccountId: 0,
        );
        expect(zeroNorm.autoSelectDefaultAccount, isTrue);
        expect(zeroNorm.defaultAccountId, noRef);

        final negNorm = defaults.copyWithDefaultAccount(
          autoSelectDefaultAccount: true,
          defaultAccountId: -42,
        );
        expect(negNorm.defaultAccountId, noRef);

        // Set valid positive defaultAccountId and verify preservation across all copy/mutate methods
        final configured = defaults.copyWithDefaultAccount(
          autoSelectDefaultAccount: true,
          defaultAccountId: 12,
        );
        expect(configured.autoSelectDefaultAccount, isTrue);
        expect(configured.defaultAccountId, 12);

        final styled = configured.copyWithStyles(
          datePickerStyle: RecordDatePickerStyle.wheel,
          timePickerStyle: RecordTimePickerStyle.dial,
        );
        expect(styled.autoSelectDefaultAccount, isTrue);
        expect(styled.defaultAccountId, 12);

        final toggledAction = styled.setEnabled(DiyToolbarAction.tags, false);
        expect(toggledAction.autoSelectDefaultAccount, isTrue);
        expect(toggledAction.defaultAccountId, 12);
        expect(toggledAction.isEnabled(DiyToolbarAction.tags), isFalse);

        final moved = toggledAction.moveItem(0, 2);
        expect(moved.autoSelectDefaultAccount, isTrue);
        expect(moved.defaultAccountId, 12);

        final reordered = moved.reorderForListView(2, 0);
        expect(reordered.autoSelectDefaultAccount, isTrue);
        expect(reordered.defaultAccountId, 12);

        // JSON encode/decode round-trip + equality & hashCode
        final encoded = reordered.encode();
        final decoded = DiyToolbarConfig.decode(encoded);
        expect(decoded, equals(reordered));
        expect(decoded.hashCode, equals(reordered.hashCode));
        expect(decoded.autoSelectDefaultAccount, isTrue);
        expect(decoded.defaultAccountId, 12);
        expect(
          decoded,
          isNot(equals(reordered.copyWithDefaultAccount(defaultAccountId: 99))),
        );
        expect(
          decoded,
          isNot(
            equals(
              reordered.copyWithDefaultAccount(autoSelectDefaultAccount: false),
            ),
          ),
        );

        // Legacy JSON without default account fields -> safe defaults (false, noRef)
        final legacyObj = DiyToolbarConfig.decode(
          jsonEncode({
            'version': 1,
            'datePickerStyle': 'wheel',
            'timePickerStyle': 'dial',
            'items': [
              {'key': 'tags', 'enabled': false},
            ],
          }),
        );
        expect(legacyObj.autoSelectDefaultAccount, isFalse);
        expect(legacyObj.defaultAccountId, noRef);
        expect(legacyObj.datePickerStyle, RecordDatePickerStyle.wheel);
        expect(legacyObj.isEnabled(DiyToolbarAction.tags), isFalse);

        final legacyList = DiyToolbarConfig.decode(
          jsonEncode(['tags', 'images']),
        );
        expect(legacyList.autoSelectDefaultAccount, isFalse);
        expect(legacyList.defaultAccountId, noRef);

        // Partial map without 'items' + negative/zero defaultAccountId normalization
        final partial = DiyToolbarConfig.decode(
          jsonEncode({'autoSelectDefaultAccount': true, 'defaultAccountId': 7}),
        );
        expect(partial.autoSelectDefaultAccount, isTrue);
        expect(partial.defaultAccountId, 7);

        final partialZero = DiyToolbarConfig.decode(
          jsonEncode({'autoSelectDefaultAccount': true, 'defaultAccountId': 0}),
        );
        expect(partialZero.autoSelectDefaultAccount, isTrue);
        expect(partialZero.defaultAccountId, noRef);

        expect(DiyToolbarConfig.decode(null), equals(defaults));
        expect(DiyToolbarConfig.decode(''), equals(defaults));
        expect(DiyToolbarConfig.decode('{bad json'), equals(defaults));
      },
    );

    test(
      'resolveEffectiveDefaultAccountId validates toggle, active status, non-debt type, existence, and asset_book visibility',
      () {
        final assets = <({int id, int type, int status})>[
          (id: 1, type: AssetType.normal, status: AssetStatus.active),
          (id: 2, type: AssetType.credit, status: AssetStatus.active),
          (id: 3, type: AssetType.normal, status: AssetStatus.hidden),
          (id: 4, type: AssetType.normal, status: AssetStatus.settled),
          (id: 5, type: AssetType.debt, status: AssetStatus.active),
          (id: 6, type: AssetType.normal, status: AssetStatus.active),
          (id: 7, type: AssetType.normal, status: AssetStatus.active),
        ];
        final bindings = <int, Set<int>>{
          2: <int>{}, // empty binding -> visible in all books
          6: <int>{1, 2}, // bound to book 1 & 2
          7: <int>{2}, // bound only to book 2
        };

        DiyToolbarConfig cfg(bool enabled, int id) =>
            DiyToolbarConfig.defaults().copyWithDefaultAccount(
              autoSelectDefaultAccount: enabled,
              defaultAccountId: id,
            );

        // Disabled or noRef -> noRef
        expect(
          resolveEffectiveDefaultAccountId(
            config: cfg(false, 1),
            bookId: 1,
            assets: assets,
            assetBookBindings: bindings,
          ),
          noRef,
        );
        expect(
          resolveEffectiveDefaultAccountId(
            config: cfg(true, noRef),
            bookId: 1,
            assets: assets,
            assetBookBindings: bindings,
          ),
          noRef,
        );

        // Active normal (unbound) & active credit (empty bound set) -> valid
        expect(
          resolveEffectiveDefaultAccountId(
            config: cfg(true, 1),
            bookId: 1,
            assets: assets,
            assetBookBindings: bindings,
          ),
          1,
        );
        expect(
          resolveEffectiveDefaultAccountId(
            config: cfg(true, 2),
            bookId: 9,
            assets: assets,
            assetBookBindings: bindings,
          ),
          2,
        );

        // Hidden (status=1), settled (status=2), debt (type=4), deleted (999) -> noRef
        for (final invalidId in const <int>[3, 4, 5, 999]) {
          expect(
            resolveEffectiveDefaultAccountId(
              config: cfg(true, invalidId),
              bookId: 1,
              assets: assets,
              assetBookBindings: bindings,
            ),
            noRef,
            reason: 'Asset $invalidId must fall back to noRef',
          );
        }

        // Cross-book asset_book isolation
        expect(
          resolveEffectiveDefaultAccountId(
            config: cfg(true, 6),
            bookId: 1,
            assets: assets,
            assetBookBindings: bindings,
          ),
          6,
        );
        expect(
          resolveEffectiveDefaultAccountId(
            config: cfg(true, 6),
            bookId: 3,
            assets: assets,
            assetBookBindings: bindings,
          ),
          noRef,
        );
        expect(
          resolveEffectiveDefaultAccountId(
            config: cfg(true, 7),
            bookId: 1,
            assets: assets,
            assetBookBindings: bindings,
          ),
          noRef,
        );
        expect(
          resolveEffectiveDefaultAccountId(
            config: cfg(true, 7),
            bookId: 2,
            assets: assets,
            assetBookBindings: bindings,
          ),
          7,
        );
      },
    );
  });

  testWidgets(
    'Standalone SettingsPage without databaseProvider override settles cleanly via pumpAndSettle without cold-starting NativeDatabase',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appSettingsProvider.overrideWith(
              (ref) => Stream<AppSettings>.value(AppSettings.defaults),
            ),
          ],
          child: const MaterialApp(home: SettingsPage()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('系统与首页设置'), findsOneWidget);
      expect(find.text('默认选择指定账户'), findsNothing);
      expect(
        find.byKey(const Key('setting_default_account_switch')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('setting_default_account_selector')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'AssetEditorPage configures default account exclusively, DiyToolbarSettingsPage keeps only toolbar items & order, and both pass 360x640 @ 1.2x & 1280x800 layout audits',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final (db, closeCleanly) = await _openTestDb(tester);
      late int bankId;
      late int creditId;
      late int hiddenId;
      late int settledId;

      await tester.runAsync(() async {
        final ledger = LedgerService(db);
        bankId = await ledger.createAsset(
          commandId: 'sync-bank',
          name: '招行储蓄卡',
          initial: Money.parse('5200.00'),
        );
        creditId = await ledger.createAsset(
          commandId: 'sync-credit',
          name: '工行信用卡',
          type: AssetType.credit,
          initial: Money.parse('-300.00'),
          limit: Money.parse('20000.00'),
        );
        hiddenId = await ledger.createAsset(
          commandId: 'sync-hidden',
          name: '已隐藏旧卡',
          initial: Money.parse('10.00'),
        );
        await ledger.setAssetStatus(
          commandId: 'hide-sync-hidden',
          assetId: hiddenId,
          status: AssetStatus.hidden,
        );
        settledId = await ledger.createAsset(
          commandId: 'sync-settled',
          name: '已结清账户',
          initial: Money.zero(),
        );
        await ledger.setAssetStatus(
          commandId: 'settle-sync-settled',
          assetId: settledId,
          status: AssetStatus.settled,
        );
        await DebtService(db).createDebt(
          commandId: 'sync-debt',
          subType: AssetType.debtLend,
          name: '借出小李',
          principal: Money.parse('500.00'),
          bookId: defaultBookId,
          startDate: DateTime(2026, 6, 1).millisecondsSinceEpoch,
        );
      });

      final activePage = ValueNotifier<Widget>(
        AssetEditorPage(assetId: bankId),
      );
      addTearDown(activePage.dispose);

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: ValueListenableBuilder<Widget>(
            valueListenable: activePage,
            builder: (_, page, _) => MaterialApp(
              locale: const Locale('zh'),
              supportedLocales: const <Locale>[Locale('zh'), Locale('en')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              home: page,
            ),
          ),
        ),
      );
      await _settle(tester);

      // 1. Toggle ON in AssetEditorPage for bankId and save.
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
      await tester.tap(find.byKey(const Key('asset-default-account-switch')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('asset-save')));
      await _settle(tester);

      final cfgAfterBank = await tester.runAsync(
        () => BillAttachmentService(db).getDiyToolbarConfig(),
      );
      expect(cfgAfterBank!.autoSelectDefaultAccount, isTrue);
      expect(cfgAfterBank.defaultAccountId, bankId);

      // 2. DiyToolbarSettingsPage has no top section header or arrow buttons, and reset preserves both styles and default account (B-09).
      await tester.runAsync(() async {
        final svc = BillAttachmentService(db);
        final cur = await svc.getDiyToolbarConfig();
        await svc.saveDiyToolbarConfig(
          commandId: 'seed-styles-before-reset',
          config: cur.copyWithStyles(
            datePickerStyle: RecordDatePickerStyle.wheel,
            timePickerStyle: RecordTimePickerStyle.dial,
          ),
        );
      });
      activePage.value = const DiyToolbarSettingsPage();
      await _settle(tester);
      expect(find.text('工具栏项目与顺序'), findsNothing);
      expect(find.text('工具栏预览'), findsNothing);
      expect(find.text('默认账户'), findsNothing);
      expect(find.byKey(const Key('diy-default-account-switch')), findsNothing);
      expect(find.byKey(const Key('diy-up-tags')), findsNothing);
      expect(find.byKey(const Key('diy-down-tags')), findsNothing);
      await tester.tap(find.byKey(const Key('diy-toolbar-reset-btn')));
      await _settle(tester);
      final cfgAfterReset = await tester.runAsync(
        () => BillAttachmentService(db).getDiyToolbarConfig(),
      );
      expect(cfgAfterReset!.autoSelectDefaultAccount, isTrue);
      expect(cfgAfterReset.defaultAccountId, bankId);
      expect(cfgAfterReset.datePickerStyle, RecordDatePickerStyle.wheel);
      expect(cfgAfterReset.timePickerStyle, RecordTimePickerStyle.dial);

      // 3. Hidden & settled accounts disable the switch in AssetEditorPage.
      for (final inactiveId in <int>[hiddenId, settledId]) {
        activePage.value = AssetEditorPage(
          key: ValueKey<int>(inactiveId),
          assetId: inactiveId,
        );
        await _settle(tester);
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
        final sw = tester.widget<SwitchListTile>(
          find.byKey(const Key('asset-default-account-switch')),
        );
        expect(sw.value, isFalse);
        expect(sw.onChanged, isNull);
      }

      // 4. Verify zero overflow at 360x640 (Light & Dark @ 1.2x text scale) and desktop 1280x800!
      final pages = <Widget>[
        const SettingsPage(),
        const DiyToolbarSettingsPage(),
        AssetEditorPage(assetId: creditId),
      ];
      for (final page in pages) {
        for (final brightness in const <Brightness>[
          Brightness.light,
          Brightness.dark,
        ]) {
          await tester.binding.setSurfaceSize(const Size(360, 640));
          await tester.pumpWidget(
            ProviderScope(
              key: ValueKey<String>('narrow-${page.runtimeType}-$brightness'),
              retry: (_, _) => null,
              overrides: [databaseProvider.overrideWith((ref) async => db)],
              child: MaterialApp(
                theme: ThemeData(
                  colorScheme: ColorScheme.fromSeed(
                    seedColor: const Color(0xFF006972),
                    brightness: brightness,
                  ),
                  useMaterial3: true,
                ),
                builder: (ctx, child) => MediaQuery(
                  data: MediaQuery.of(
                    ctx,
                  ).copyWith(textScaler: const TextScaler.linear(1.2)),
                  child: child!,
                ),
                home: page,
              ),
            ),
          );
          await _settle(tester);
          expect(tester.takeException(), isNull);
        }

        await tester.binding.setSurfaceSize(const Size(1280, 800));
        await tester.pumpWidget(
          ProviderScope(
            key: ValueKey<String>('desktop-${page.runtimeType}'),
            retry: (_, _) => null,
            overrides: [databaseProvider.overrideWith((ref) async => db)],
            child: MaterialApp(
              theme: ThemeData(
                platform: TargetPlatform.linux,
                useMaterial3: true,
              ),
              home: page,
            ),
          ),
        );
        await _settle(tester);
        expect(tester.takeException(), isNull);
      }

      await closeCleanly();
    },
  );

  testWidgets(
    'RecordEditorPage mobile & desktop (DesktopRecordDialogPage) prefill expense/income/reimbursable/transfer, show 默认 badge, support live toggle, and reset to default account on 再记',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final (db, closeCleanly) = await _openTestDb(tester);
      late int defaultWalletId;
      late int secondCardId;
      late int hiddenAssetId;
      late int book2OnlyAssetId;

      await tester.runAsync(() async {
        final ledger = LedgerService(db);
        final catalog = CatalogService(db);
        final book2Id = await catalog.createBook(
          commandId: 'book-2-prefill',
          name: '副业账本',
        );
        defaultWalletId = await ledger.createAsset(
          commandId: 'prefill-wallet',
          name: '微信零钱',
          initial: Money.parse('1000.00'),
        );
        secondCardId = await ledger.createAsset(
          commandId: 'prefill-card',
          name: '招商信用卡',
          type: AssetType.credit,
          initial: Money.zero(),
          limit: Money.parse('10000.00'),
        );
        hiddenAssetId = await ledger.createAsset(
          commandId: 'prefill-hidden',
          name: '隐藏小金库',
          initial: Money.parse('50.00'),
        );
        await ledger.setAssetStatus(
          commandId: 'hide-prefill-hidden',
          assetId: hiddenAssetId,
          status: AssetStatus.hidden,
        );
        book2OnlyAssetId = await ledger.createAsset(
          commandId: 'prefill-book2-only',
          name: '副业专户',
          initial: Money.parse('200.00'),
        );
        await db
            .into(db.assetBooks)
            .insert(
              AssetBooksCompanion.insert(
                assetId: book2OnlyAssetId,
                bookId: book2Id,
              ),
            );
      });

      // 1. Mobile: start with default account OFF, then enable live via DiyToolbarSettingsPage!
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: MaterialApp(
            theme: ThemeData(
              platform: TargetPlatform.android,
              useMaterial3: true,
            ),
            home: const RecordEditorPage(key: ValueKey('mobile-live-1')),
          ),
        ),
      );
      await _settle(tester);
      expect(
        find.descendant(
          of: find.byKey(const Key('asset')),
          matching: find.text('不选账户'),
        ),
        findsOneWidget,
      );

      // Enable via AssetEditorPage -> live updates untouched RecordEditorPage!
      final nav = Navigator.of(tester.element(find.byType(RecordEditorPage)));
      nav.push(
        MaterialPageRoute<void>(
          builder: (_) => AssetEditorPage(assetId: defaultWalletId),
        ),
      );
      await _settle(tester);
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
      await tester.tap(find.byKey(const Key('asset-default-account-switch')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('asset-save')));
      await _settle(tester);

      expect(
        find.descendant(
          of: find.byKey(const Key('asset')),
          matching: find.text('微信零钱'),
        ),
        findsOneWidget,
      );

      // 2. Open mobile account picker sheet -> verify '默认' badge & selectable filter!
      await tester.tap(find.byKey(const Key('asset')));
      await _settle(tester, 4);
      expect(
        find.byKey(Key('account-default-badge-$defaultWalletId')),
        findsOneWidget,
      );
      expect(find.text('默认'), findsOneWidget);
      expect(find.text('隐藏小金库'), findsNothing);
      expect(find.text('副业专户'), findsNothing);
      // Dismiss sheet without selecting -> _userTouchedAsset remains false!
      Navigator.of(tester.element(find.text('选择账户'))).pop();
      await _settle(tester, 4);

      // 3. Switch tabs: 支出 -> 收入 -> 报销 -> 转账 -> 支出 while untouched!
      await tester.tap(find.byKey(const Key('type-1'))); // 收入
      await _settle(tester, 3);
      expect(
        find.descendant(
          of: find.byKey(const Key('asset')),
          matching: find.text('微信零钱'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('type-3'))); // 报销
      await _settle(tester, 3);
      expect(
        find.descendant(
          of: find.byKey(const Key('asset')),
          matching: find.text('微信零钱'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('type-2'))); // 转账
      await _settle(tester, 3);
      expect(
        find.descendant(
          of: find.byKey(const Key('from')),
          matching: find.text('微信零钱'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('to')),
          matching: find.text('选择账户'),
        ),
        findsOneWidget,
      );

      // Switch back to 支出, manually pick '不选账户' -> switching tabs must NOT re-apply default account!
      await tester.tap(find.byKey(const Key('type-0')));
      await _settle(tester, 3);
      await tester.tap(find.byKey(const Key('asset')));
      await _settle(tester, 4);
      await tester.tap(find.text('不选账户').last);
      await _settle(tester, 4);
      await tester.tap(find.byKey(const Key('type-1')));
      await _settle(tester, 3);
      expect(
        find.descendant(
          of: find.byKey(const Key('asset')),
          matching: find.text('不选账户'),
        ),
        findsOneWidget,
      );

      // Switch back to 支出, manually pick '招商信用卡' for 1st bill, then tap 再记!
      await tester.tap(find.byKey(const Key('type-0')));
      await _settle(tester, 3);
      await tester.tap(find.byKey(const Key('cat-餐饮')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('asset')));
      await _settle(tester, 4);
      await tester.tap(find.text('招商信用卡').last);
      await _settle(tester, 4);
      expect(
        find.descendant(
          of: find.byKey(const Key('asset')),
          matching: find.text('招商信用卡'),
        ),
        findsOneWidget,
      );

      await _tapKeypadDigits(tester, ['3', '5']);
      await tester.tap(find.byKey(const Key('save-and-new')));
      await _settle(tester);

      // After 再记: resets back to default account '微信零钱'!
      expect(find.byKey(const Key('save-and-new-banner')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('asset')),
          matching: find.text('微信零钱'),
        ),
        findsOneWidget,
      );

      // Book 2nd bill (20.00) on '微信零钱'
      await _tapKeypadDigits(tester, ['2', '0']);
      await tester.tap(find.byKey(const Key('save')));
      await _settle(tester);

      final mobileRecords = await tester.runAsync(
        () => (db.select(db.records)).get(),
      );
      expect(mobileRecords, hasLength(2));
      final r35 = mobileRecords!.firstWhere(
        (r) => r.moneyMinor == BigInt.from(3500),
      );
      final r20 = mobileRecords.firstWhere(
        (r) => r.moneyMinor == BigInt.from(2000),
      );
      expect(r35.assetId, secondCardId);
      expect(r20.assetId, defaultWalletId);

      // 4. Desktop (`DesktopRecordDialogPage` @ 1280x800 Linux): prefill + desktop dialog badge + transfer 再记!
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      await tester.pumpWidget(
        ProviderScope(
          key: const ValueKey('desktop-dialog-scope'),
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: MaterialApp(
            theme: ThemeData(
              platform: TargetPlatform.linux,
              useMaterial3: true,
            ),
            home: Navigator(
              onDidRemovePage: (_) {},
              pages: const <Page<Object?>>[
                MaterialPage<void>(child: Scaffold(body: SizedBox.expand())),
                DesktopRecordDialogPage<Object?>(
                  key: ValueKey('desk-transfer-page'),
                  initialType: RecordType.transfer,
                ),
              ],
            ),
          ),
        ),
      );
      await _settle(tester);
      expect(
        find.byKey(const Key('desktop-record-editor-dialog')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('from')),
          matching: find.text('微信零钱'),
        ),
        findsOneWidget,
      );

      // Open 'to' picker on desktop -> verify desktop-account-picker-dialog + '默认' badge, pick '招商信用卡'
      await tester.tap(find.byKey(const Key('to')));
      await _settle(tester, 4);
      expect(
        find.byKey(const Key('desktop-account-picker-dialog')),
        findsOneWidget,
      );
      expect(
        find.byKey(Key('account-default-badge-$defaultWalletId')),
        findsOneWidget,
      );
      await tester.tap(find.text('招商信用卡').last);
      await _settle(tester, 4);

      await tester.enterText(find.byKey(const Key('amount')), '100');
      await tester.pump();
      await tester.tap(find.byKey(const Key('desktop-save-and-again')));
      await _settle(tester);

      // Transfer 再记 resets 'from' to defaultWalletId and clears 'to' to '选择账户'!
      expect(find.byKey(const Key('save-and-new-banner')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('from')),
          matching: find.text('微信零钱'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('to')),
          matching: find.text('选择账户'),
        ),
        findsOneWidget,
      );

      await closeCleanly();
    },
  );

  testWidgets(
    'RecordEditorPage never overrides editing old bills, explicit initialAsset/From/To, or template account, and safely falls back when template has no account or default account is hidden/deleted/other-book',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final (db, closeCleanly) = await _openTestDb(tester);
      late int defaultWalletId;
      late int explicitCardId;
      late int templateAssetId;
      late int laterHiddenAssetId;
      late int book2Id;
      late int foodCatId;
      late String oldNoAccountRecordId;
      late String oldHiddenAccountRecordId;
      late int tplWithAccountId;
      late int tplWithoutAccountId;

      await tester.runAsync(() async {
        final ledger = LedgerService(db);
        final catalog = CatalogService(db);
        final attSvc = BillAttachmentService(db);
        final tplSvc = TemplateRemarkService(db);

        book2Id = await catalog.createBook(
          commandId: 'guard-book-2',
          name: '旅行账本',
        );
        final cats = await db.select(db.recordCategories).get();
        foodCatId = cats
            .firstWhere(
              (c) => c.accountBookId == defaultBookId && c.name == '餐饮',
            )
            .id;

        defaultWalletId = await ledger.createAsset(
          commandId: 'guard-default-wallet',
          name: '日常支付宝',
          initial: Money.parse('800.00'),
        );
        explicitCardId = await ledger.createAsset(
          commandId: 'guard-explicit-card',
          name: '显式指定卡',
          initial: Money.parse('500.00'),
        );
        templateAssetId = await ledger.createAsset(
          commandId: 'guard-tpl-asset',
          name: '模板专属卡',
          initial: Money.parse('600.00'),
        );
        laterHiddenAssetId = await ledger.createAsset(
          commandId: 'guard-later-hidden',
          name: '历史归档卡',
          initial: Money.parse('300.00'),
        );

        oldNoAccountRecordId = await ledger.saveRecord(
          commandId: 'seed-old-no-asset',
          draft: RecordDraft(
            type: RecordType.expense,
            money: Money.parse('42.00'),
            bookId: defaultBookId,
            recordTime: DateTime(2026, 6, 10, 12).millisecondsSinceEpoch,
            categoryId: foodCatId,
            assetId: noRef,
          ),
        );
        oldHiddenAccountRecordId = await ledger.saveRecord(
          commandId: 'seed-old-hidden-asset',
          draft: RecordDraft(
            type: RecordType.expense,
            money: Money.parse('66.00'),
            bookId: defaultBookId,
            recordTime: DateTime(2026, 6, 10, 13).millisecondsSinceEpoch,
            categoryId: foodCatId,
            assetId: laterHiddenAssetId,
          ),
        );
        await ledger.setAssetStatus(
          commandId: 'archive-later-hidden',
          assetId: laterHiddenAssetId,
          status: AssetStatus.hidden,
        );

        tplWithAccountId = await tplSvc.saveTemplate(
          commandId: 'seed-tpl-with-asset',
          draft: TemplateDraft(
            type: RecordType.expense,
            money: Money.parse('18.00'),
            bookId: defaultBookId,
            name: '带账户早餐',
            categoryId: foodCatId,
            assetId: templateAssetId,
          ),
        );
        tplWithoutAccountId = await tplSvc.saveTemplate(
          commandId: 'seed-tpl-no-asset',
          draft: TemplateDraft(
            type: RecordType.expense,
            money: Money.parse('25.00'),
            bookId: defaultBookId,
            name: '无账户咖啡',
            categoryId: foodCatId,
            assetId: noRef,
          ),
        );

        final cfg = await attSvc.getDiyToolbarConfig();
        await attSvc.saveDiyToolbarConfig(
          commandId: 'enable-guard-default',
          config: cfg.copyWithDefaultAccount(
            autoSelectDefaultAccount: true,
            defaultAccountId: defaultWalletId,
          ),
        );
      });

      final activeEditor = ValueNotifier<Widget>(
        RecordEditorPage(
          key: const ValueKey('edit-old-no-asset'),
          recordId: oldNoAccountRecordId,
        ),
      );
      addTearDown(activeEditor.dispose);

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: ValueListenableBuilder<Widget>(
            valueListenable: activeEditor,
            builder: (_, page, _) => MaterialApp(
              theme: ThemeData(
                platform: TargetPlatform.android,
                useMaterial3: true,
              ),
              home: page,
            ),
          ),
        ),
      );
      await _settle(tester);

      // 1a. Editing old bill with noRef -> stays '不选账户' (NEVER overridden by defaultWalletId!)
      expect(
        find.descendant(
          of: find.byKey(const Key('asset')),
          matching: find.text('不选账户'),
        ),
        findsOneWidget,
      );

      // 1b. Editing old bill whose original account was hidden -> preserves '历史归档卡' in pill & picker!
      activeEditor.value = RecordEditorPage(
        key: const ValueKey('edit-old-hidden-asset'),
        recordId: oldHiddenAccountRecordId,
      );
      await _settle(tester);
      expect(
        find.descendant(
          of: find.byKey(const Key('asset')),
          matching: find.text('历史归档卡'),
        ),
        findsOneWidget,
      );

      // 2. Explicit initialAsset & initialTo route params -> NEVER overridden!
      activeEditor.value = RecordEditorPage(
        key: const ValueKey('explicit-initial-asset'),
        initialAsset: explicitCardId,
      );
      await _settle(tester);
      expect(
        find.descendant(
          of: find.byKey(const Key('asset')),
          matching: find.text('显式指定卡'),
        ),
        findsOneWidget,
      );

      activeEditor.value = RecordEditorPage(
        key: const ValueKey('explicit-initial-to'),
        initialType: RecordType.transfer,
        initialTo: defaultWalletId,
      );
      await _settle(tester);
      expect(
        find.descendant(
          of: find.byKey(const Key('from')),
          matching: find.text('选择账户'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('to')),
          matching: find.text('日常支付宝'),
        ),
        findsOneWidget,
      );

      // 3. Template prefill (`initialTemplateId` + `TemplateQuickBar`):
      // (a) Template with account -> keeps '模板专属卡' (not overridden!)
      activeEditor.value = RecordEditorPage(
        key: const ValueKey('tpl-with-account'),
        initialTemplateId: tplWithAccountId,
      );
      await _settle(tester);
      expect(
        find.descendant(
          of: find.byKey(const Key('asset')),
          matching: find.text('模板专属卡'),
        ),
        findsOneWidget,
      );

      // Tap TemplateQuickBar chip for 无账户咖啡 -> falls back to default account '日常支付宝'!
      await tester.tap(find.byKey(Key('quick_template_$tplWithoutAccountId')));
      await _settle(tester);
      expect(
        find.descendant(
          of: find.byKey(const Key('asset')),
          matching: find.text('日常支付宝'),
        ),
        findsOneWidget,
      );

      // Tap TemplateQuickBar chip for 带账户早餐 -> switches back to '模板专属卡'!
      await tester.tap(find.byKey(Key('quick_template_$tplWithAccountId')));
      await _settle(tester);
      expect(
        find.descendant(
          of: find.byKey(const Key('asset')),
          matching: find.text('模板专属卡'),
        ),
        findsOneWidget,
      );

      // Also verify initialTemplateId with NO account directly on cold start:
      activeEditor.value = RecordEditorPage(
        key: const ValueKey('tpl-without-account-cold'),
        initialTemplateId: tplWithoutAccountId,
      );
      await _settle(tester);
      expect(
        find.descendant(
          of: find.byKey(const Key('asset')),
          matching: find.text('日常支付宝'),
        ),
        findsOneWidget,
      );

      // 4. Safe fallback to '不选账户' (noRef) when default account is bound ONLY to book 2, hidden, or deleted!
      // (a) Bound exclusively to book 2 while current book is book 1:
      await tester.runAsync(() async {
        await db
            .into(db.assetBooks)
            .insert(
              AssetBooksCompanion.insert(
                assetId: defaultWalletId,
                bookId: book2Id,
              ),
            );
      });
      activeEditor.value = const RecordEditorPage(
        key: ValueKey('fallback-cross-book'),
      );
      await _settle(tester);
      expect(
        find.descendant(
          of: find.byKey(const Key('asset')),
          matching: find.text('不选账户'),
        ),
        findsOneWidget,
      );

      // Unbind from book 2, then hide defaultWalletId -> still safely '不选账户'!
      await tester.runAsync(() async {
        await (db.delete(
          db.assetBooks,
        )..where((t) => t.assetId.equals(defaultWalletId))).go();
      });
      await _settle(tester, 2);
      await tester.runAsync(
        () => LedgerService(db).setAssetStatus(
          commandId: 'hide-default-wallet',
          assetId: defaultWalletId,
          status: AssetStatus.hidden,
        ),
      );
      activeEditor.value = const RecordEditorPage(
        key: ValueKey('fallback-hidden-default'),
      );
      await _settle(tester);
      expect(
        find.descendant(
          of: find.byKey(const Key('asset')),
          matching: find.text('不选账户'),
        ),
        findsOneWidget,
      );

      // Delete defaultWalletId (no records reference it) -> still safely '不选账户' and saves cleanly with noRef!
      await tester.runAsync(
        () => LedgerService(db).deleteAsset(
          commandId: 'delete-default-wallet',
          assetId: defaultWalletId,
        ),
      );
      activeEditor.value = const RecordEditorPage(
        key: ValueKey('fallback-deleted-default'),
      );
      await _settle(tester);
      expect(
        find.descendant(
          of: find.byKey(const Key('asset')),
          matching: find.text('不选账户'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('cat-餐饮')));
      await tester.pump();
      await _tapKeypadDigits(tester, ['1', '9']);
      await tester.tap(find.byKey(const Key('save')));
      await _settle(tester);

      final savedRows = await tester.runAsync(
        () => (db.select(
          db.records,
        )..where((t) => t.moneyMinor.equals(BigInt.from(1900)))).get(),
      );
      expect(savedRows, hasLength(1));
      expect(savedRows!.single.assetId, noRef);

      await closeCleanly();
    },
  );
}
