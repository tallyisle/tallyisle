import 'dart:async';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tallyisle/app/adaptive.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/data/backup/s3_client.dart';
import 'package:tallyisle/data/backup/webdav_client.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/migration/cross_migration_service.dart';
import 'package:tallyisle/data/penny/penny_import_service.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/cloud_sync_rules.dart';
import 'package:tallyisle/domain/rules/ios_migration_rules.dart';
import 'package:tallyisle/domain/rules/penny_backup.dart';
import 'package:tallyisle/domain/rules/receipt_diy_rules.dart';
import 'package:tallyisle/features/backup/backup_providers.dart';
import 'package:tallyisle/features/backup/mobile_sync_backup_quick_sheet.dart';
import 'package:tallyisle/features/common/catalog_icons.dart';
import 'package:tallyisle/features/common/desktop_modal_page.dart';
import 'package:tallyisle/features/csv_transfer/csv_export_page.dart';
import 'package:tallyisle/features/csv_transfer/csv_import_page.dart';
import 'package:tallyisle/features/csv_transfer/import_batches_page.dart';
import 'package:tallyisle/features/me/me_page.dart';
import 'package:tallyisle/features/migration/migration_page.dart';
import 'package:tallyisle/platform/files.dart';

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Future<void> _disposeApp(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await _settle(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('B-07: Mobile Quick Sync Sheet target scoping & sync-in-progress lock', () {
    testWidgets(
      'scopes cursor to active targetFingerprint and blocks barrier/drag dismissal while syncing',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);

        const davA = WebDavConfig(
          serverUrl: 'https://dav-a.example.com/dav',
          username: 'alice',
          password: 'pw',
          remoteDirectory: '/TallyIsle',
        );
        const s3New = S3Config(
          endpoint: 'https://s3.example.com',
          region: 'auto',
          bucket: 'new-bucket',
          accessKeyId: 'AKIA123',
          secretAccessKey: 'SECRET456',
          remotePrefix: 'TallyIsle',
        );
        final syncedOnDavACursor = LocalSyncCursor(
          lastSyncedRevision: 7,
          lastSyncedDataSha256: 'a' * 64,
          lastSyncedAtMs: DateTime(2026, 11, 18, 9, 30).millisecondsSinceEpoch,
          targetFingerprint: davA.targetFingerprint,
        );

        final inProgressCtrl = StreamController<bool>.broadcast();
        addTearDown(inProgressCtrl.close);

        // 1. Verify cursor.scopedToTarget prevents stale "已同步 r7" when switching to S3!
        await tester.pumpWidget(
          ProviderScope(
            retry: (_, _) => null,
            overrides: [
              databaseProvider.overrideWith((ref) async => db),
              webDavConfigProvider.overrideWith(
                (ref) => Stream<WebDavConfig>.value(davA),
              ),
              s3ConfigProvider.overrideWith(
                (ref) => Stream<S3Config>.value(s3New),
              ),
              cloudSyncSettingsProvider.overrideWith(
                (ref) => Stream<CloudSyncSettings>.value(
                  const CloudSyncSettings(
                    backend: CloudBackendType.s3,
                    explicitBackend: true,
                    deviceId: 'dev-1',
                  ),
                ),
              ),
              cloudSyncCursorProvider.overrideWith(
                (ref) => Stream<LocalSyncCursor>.value(syncedOnDavACursor),
              ),
              cloudSyncInProgressProvider.overrideWith((ref) async* {
                yield false;
                yield* inProgressCtrl.stream;
              }),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: Consumer(
                  builder: (ctx, ref, _) {
                    ref.watch(databaseProvider);
                    return Column(
                      children: [
                        const MobileMeSyncQuickCard(cardColor: Colors.white),
                        FilledButton(
                          key: const Key('open_sheet_btn'),
                          onPressed: () => showMobileSyncBackupQuickSheet(ctx),
                          child: const Text('打开面板'),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await _settle(tester);

        // S3 has a different targetFingerprint than davA -> never shows stale "已同步 r7"!
        expect(find.textContaining('已同步 r7'), findsNothing);
        expect(find.text('S3 对象存储 已就绪 · 换设备前请先同步'), findsOneWidget);

        // 2. Broadcast syncInProgress = true -> MobileMeSyncQuickCard shows busy state
        inProgressCtrl.add(true);
        await _settle(tester);
        expect(
          find.byKey(const Key('me-mobile-sync-quick-status')),
          findsOneWidget,
        );
        expect(find.text('正在执行多端云同步…'), findsOneWidget);
        final cardActionBtn = tester.widget<FilledButton>(
          find.byKey(const Key('me-mobile-sync-quick-action')),
        );
        expect(cardActionBtn.onPressed, isNull);

        // 3. Open bottom sheet while syncing -> barrier tap & downward drag MUST NOT dismiss!
        await tester.tap(find.byKey(const Key('open_sheet_btn')));
        await _settle(tester);
        expect(
          find.byKey(const Key('mobile_sync_backup_quick_sheet')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('quick_sheet_busy_indicator')),
          findsOneWidget,
        );

        // Attempt barrier tap at top-left (10, 10) and downward fling on sheet:
        await tester.tapAt(const Offset(10, 10));
        await _settle(tester);
        expect(
          find.byKey(const Key('mobile_sync_backup_quick_sheet')),
          findsOneWidget,
        );

        await tester.fling(
          find.byKey(const Key('mobile_sync_backup_quick_sheet')),
          const Offset(0, 320),
          1200,
        );
        await _settle(tester);
        expect(
          find.byKey(const Key('mobile_sync_backup_quick_sheet')),
          findsOneWidget,
        );

        // 4. Finish sync -> barrier tap / downward fling now dismisses cleanly!
        inProgressCtrl.add(false);
        await _settle(tester);
        expect(
          find.byKey(const Key('quick_sheet_busy_indicator')),
          findsNothing,
        );
        await tester.tapAt(const Offset(10, 10));
        await _settle(tester);
        expect(
          find.byKey(const Key('mobile_sync_backup_quick_sheet')),
          findsNothing,
        );

        await _disposeApp(tester);
      },
    );
  });

  group('B-08: Reset stale defaultAccountId on full-overwrite migrations', () {
    test(
      'PennyImportService and CrossMigrationService clear defaultAccountId while preserving toolbar style preferences',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        await db.select(db.accountBooks).get();

        // 1. Seed a non-default DiyToolbarConfig with defaultAccountId = 42
        final seededConfig = DiyToolbarConfig.defaults()
            .copyWithStyles(datePickerStyle: RecordDatePickerStyle.wheel)
            .copyWithDefaultAccount(
              autoSelectDefaultAccount: true,
              defaultAccountId: 42,
            );
        await db
            .into(db.preferences)
            .insertOnConflictUpdate(
              PreferencesCompanion.insert(
                key: prefKeyRecordDiyToolbar,
                value: seededConfig.encode(),
              ),
            );

        // Run CrossMigrationService.applyMigrationPayload
        final migrationSvc = CrossMigrationService(db);
        await migrationSvc.applyMigrationPayload(
          commandId: 'b08-yi2a-1',
          payload: const MigrationPayload(
            books: <MigrationBookRow>[
              MigrationBookRow(id: 1, name: '迁入账本', createDate: 1700000000000),
            ],
            categories: <MigrationCategoryRow>[],
            assets: <MigrationAssetRow>[],
            records: <MigrationRecordRow>[],
            budgets: <MigrationBudgetRow>[],
            importPlatforms: <MigrationImportPlatformRow>[],
            installments: <MigrationInstallmentRow>[],
            periods: <MigrationPeriodRow>[],
            reminders: <MigrationReminderRow>[],
            tags: <MigrationTagRow>[],
            tagRefs: <MigrationTagRefRow>[],
            templates: <MigrationTemplateRow>[],
            bankCards: <MigrationBankCardRow>[],
            wishes: <MigrationWishRow>[],
            remarks: <MigrationRemarkRow>[],
            moneySavePlans: <MigrationSavingsPlanRow>[],
            moneySavePlanRecords: <MigrationSavingsRecordRow>[],
            assetBookRefs: <MigrationAssetBookRow>[],
            statStory: <MigrationStatStoryRow>[],
          ),
        );

        var row = await (db.select(
          db.preferences,
        )..where((t) => t.key.equals(prefKeyRecordDiyToolbar))).getSingle();
        var afterCross = DiyToolbarConfig.decode(row.value);
        expect(afterCross.defaultAccountId, noRef);
        expect(afterCross.autoSelectDefaultAccount, isFalse);
        expect(afterCross.datePickerStyle, RecordDatePickerStyle.wheel);

        // 2. Re-seed defaultAccountId = 88 and run PennyImportService.importPenny
        await db
            .into(db.preferences)
            .insertOnConflictUpdate(
              PreferencesCompanion.insert(
                key: prefKeyRecordDiyToolbar,
                value: afterCross
                    .copyWithDefaultAccount(
                      autoSelectDefaultAccount: true,
                      defaultAccountId: 88,
                    )
                    .encode(),
              ),
            );

        final pennyBytes = encodePennyForTest({
          'books': [
            {'id': 1, 'name': '一羽账本', 'sort': 1, 'cdate': 1700000000000},
          ],
        });
        final pennySvc = PennyImportService(db);
        await pennySvc.importPenny(
          commandId: 'b08-penny-1',
          fileName: 'backup.penny',
          bytes: pennyBytes,
        );

        row = await (db.select(
          db.preferences,
        )..where((t) => t.key.equals(prefKeyRecordDiyToolbar))).getSingle();
        final afterPenny = DiyToolbarConfig.decode(row.value);
        expect(afterPenny.defaultAccountId, noRef);
        expect(afterPenny.autoSelectDefaultAccount, isFalse);
        expect(afterPenny.datePickerStyle, RecordDatePickerStyle.wheel);
      },
    );
  });

  group('B-12: Embedded /me scope vs desktop PopupRoute modal navigation', () {
    testWidgets(
      'switches MeEmbeddedNavigationScope when embedded, but pushes desktop modal without mutating /me when inside PopupRoute',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);

        final router = GoRouter(
          initialLocation: '/me?section=%2Fmigration',
          routes: [
            GoRoute(path: '/me', builder: (_, _) => const MePage()),
            GoRoute(
              path: '/import/csv',
              builder: (_, _) => const CsvImportPage(),
            ),
            GoRoute(
              path: '/import/batches',
              builder: (_, _) => const ImportBatchesPage(),
            ),
            GoRoute(
              path: '/export/csv',
              builder: (_, _) => const CsvExportPage(),
            ),
          ],
        );

        await tester.pumpWidget(
          ProviderScope(
            retry: (_, _) => null,
            overrides: [
              databaseProvider.overrideWith((ref) async => db),
              desktopModeOverrideProvider.overrideWithValue(true),
            ],
            child: DesktopAdaptiveScope(
              isDesktop: true,
              child: MaterialApp.router(routerConfig: router),
            ),
          ),
        );
        await _settle(tester);

        // 1. Inside genuine MePage dual-pane: tapping `go_csv_import_button` switches section to `/import/csv`
        expect(find.byKey(const Key('migration_page')), findsOneWidget);
        await tester.scrollUntilVisible(
          find.byKey(const Key('go_csv_import_button')),
          180,
          scrollable: find.descendant(
            of: find.byKey(const Key('migration_page')),
            matching: find.byType(Scrollable),
          ),
        );
        await _settle(tester);
        await tester.tap(find.byKey(const Key('go_csv_import_button')));
        await _settle(tester);
        expect(
          router
              .routerDelegate
              .currentConfiguration
              .uri
              .queryParameters['section'],
          '/import/csv',
        );
        expect(find.byKey(const Key('csv_import_page')), findsOneWidget);

        // 2. Now open MigrationPage inside a desktop PopupRoute modal over `/me?section=%2Fimport%2Fcsv`!
        final meCtx = tester.element(find.byType(MePage));
        unawaited(
          pushDesktopModalOrMaterialRoute<void>(
            meCtx,
            maxWidth: 780,
            maxHeight: 740,
            child: const MigrationPage(),
          ),
        );
        await _settle(tester);

        final modalSurface = find.byKey(
          const Key('desktop-modal-dialog-surface'),
        );
        expect(modalSurface, findsOneWidget);

        final modalBatchesBtn = find.descendant(
          of: modalSurface,
          matching: find.byKey(const Key('go_import_batches_button')),
        );
        await tester.scrollUntilVisible(
          modalBatchesBtn,
          180,
          scrollable: find.descendant(
            of: modalSurface,
            matching: find.byType(Scrollable),
          ),
        );
        await _settle(tester);
        await tester.tap(modalBatchesBtn);
        await _settle(tester);

        // Underlying `/me` section MUST still be `/import/csv` (NOT mutated behind modal!),
        // and ImportBatchesPage opened in a new modal dialog on top!
        expect(
          router
              .routerDelegate
              .currentConfiguration
              .uri
              .queryParameters['section'],
          '/import/csv',
        );
        expect(find.byType(ImportBatchesPage), findsOneWidget);

        // Close the two desktop modals (`ImportBatchesPage` + `MigrationPage`)
        Navigator.of(tester.element(find.byType(ImportBatchesPage))).pop();
        await _settle(tester);
        Navigator.of(
          tester.element(
            find.descendant(
              of: modalSurface,
              matching: find.byType(MigrationPage),
            ),
          ),
        ).pop();
        await _settle(tester);

        // 3. Push `MigrationPage` via imperative `MaterialPageRoute` (`settings is! Page`)
        // on mobile inside a `GoRouter` app: tapping `go_import_batches_button`
        // pushes `ImportBatchesPage` on top of the imperative route instead of
        // calling `router.push('/import/batches')` underneath!
        tester.view.physicalSize = const Size(390, 760);
        await tester.pumpWidget(
          ProviderScope(
            retry: (_, _) => null,
            overrides: [
              databaseProvider.overrideWith((ref) async => db),
              desktopModeOverrideProvider.overrideWithValue(false),
            ],
            child: DesktopAdaptiveScope(
              isDesktop: false,
              child: MaterialApp.router(routerConfig: router),
            ),
          ),
        );
        await _settle(tester);

        final mobileMeCtx = tester.element(find.byType(MePage));
        unawaited(
          Navigator.of(mobileMeCtx).push(
            MaterialPageRoute<void>(builder: (_) => const MigrationPage()),
          ),
        );
        await _settle(tester);

        await tester.scrollUntilVisible(
          find.byKey(const Key('go_import_batches_button')),
          180,
          scrollable: find.descendant(
            of: find.byKey(const Key('migration_page')),
            matching: find.byType(Scrollable),
          ),
        );
        await _settle(tester);
        await tester.tap(find.byKey(const Key('go_import_batches_button')));
        await _settle(tester);

        expect(router.routerDelegate.currentConfiguration.uri.path, '/me');
        expect(find.byType(ImportBatchesPage), findsOneWidget);

        await _disposeApp(tester);
      },
    );
  });

  group(
    'B-19, B-21, B-22 & B-26: Visual picker | guard, circular clip & Windows URL channel',
    () {
      testWidgets(
        'blocks `|` in BankCard/Asset visual picker text input, searches 5 corrected bank names, and clips csrcbank.svg cleanly',
        (tester) async {
          ({String icon, String colorHex})? pickedResult;
          ({String icon, String colorHex})? pickedAssetResult;
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Column(
                  children: [
                    const AssetIconAvatar(
                      key: Key('csrc_avatar'),
                      iconKey: 'builtin:bank-icon.csrcbank',
                      name: '常熟农商',
                      assetType: AssetType.normal,
                      size: 40,
                    ),
                    Builder(
                      builder: (ctx) => FilledButton(
                        key: const Key('open_card_picker'),
                        onPressed: () async {
                          pickedResult = await showBankCardVisualPicker(
                            ctx,
                            initialColor: '#1565C0',
                            initialIcon: 'text:招|行',
                            cardType: 0,
                            previewName: '测试储蓄卡',
                          );
                        },
                        child: const Text('选卡图标'),
                      ),
                    ),
                    Builder(
                      builder: (ctx) => FilledButton(
                        key: const Key('open_asset_picker'),
                        onPressed: () async {
                          pickedAssetResult = await showAssetVisualPicker(
                            ctx,
                            initialIcon: 'text:工|商',
                            assetType: AssetType.normal,
                            previewName: '测试储蓄账户',
                          );
                        },
                        child: const Text('选账户图标'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
          await _settle(tester);

          // B-22: AnimatedContainer inside AssetIconAvatar uses Clip.antiAlias
          final avatarContainer = tester.widget<AnimatedContainer>(
            find.descendant(
              of: find.byKey(const Key('csrc_avatar')),
              matching: find.byType(AnimatedContainer),
            ),
          );
          expect(avatarContainer.clipBehavior, Clip.antiAlias);

          // B-19: Opening showBankCardVisualPicker with `text:招|行` does not crash,
          // and typing `A|B` strips `|` immediately!
          await tester.tap(find.byKey(const Key('open_card_picker')));
          await _settle(tester);
          expect(tester.takeException(), isNull);

          await tester.enterText(
            find.byKey(const Key('asset-picker-custom-text-input')),
            'A|B',
          );
          await _settle(tester);
          await tester.tap(find.byKey(const Key('visual-picker-confirm')));
          await _settle(tester);
          expect(pickedResult?.icon, 'text:AB');

          // B-19 + B-21: Asset visual picker strips `|` and searches corrected bank names
          await tester.tap(find.byKey(const Key('open_asset_picker')));
          await _settle(tester);
          expect(tester.takeException(), isNull);

          await tester.enterText(
            find.byKey(const Key('asset-picker-custom-text-input')),
            '中|银',
          );
          await _settle(tester);

          // Switch to icon search tab and verify Standard Chartered / 渣打银行 & 兵器财务
          await tester.tap(find.byKey(const Key('asset-picker-mode-preset')));
          await _settle(tester);
          await tester.enterText(
            find.byKey(const Key('asset-picker-search-input')),
            'Standard Chartered',
          );
          await _settle(tester);
          expect(find.text('渣打银行'), findsWidgets);

          await tester.enterText(
            find.byKey(const Key('asset-picker-search-input')),
            '兵器财务',
          );
          await _settle(tester);
          expect(find.text('兵器财务'), findsWidgets);

          await tester.tap(find.byKey(const Key('asset-picker-mode-text')));
          await _settle(tester);
          await tester.tap(find.byKey(const Key('visual-picker-confirm')));
          await _settle(tester);
          expect(pickedAssetResult?.icon, 'text:中银');

          await _disposeApp(tester);
        },
      );

      test(
        'B-26: Windows openExternalUrl invokes MethodChannel(dev.tallyisle/files) and handles bool return values',
        () async {
          const channel = MethodChannel(fileBridgeChannelName);
          final calls = <MethodCall>[];
          var nextBoolResult = true;
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, (call) async {
                calls.add(call);
                return nextBoolResult;
              });
          try {
            debugDefaultTargetPlatformOverride = TargetPlatform.windows;

            const access = FileAccess(channel: channel);
            await access.openExternalUrl(
              'https://github.com/tallyisle/tallyisle',
            );
            expect(calls, hasLength(1));
            expect(calls.single.method, 'openExternalUrl');
            expect(calls.single.arguments, <Object?, Object?>{
              'url': 'https://github.com/tallyisle/tallyisle',
            });

            nextBoolResult = false;
            await expectLater(
              access.openExternalUrl(
                'https://github.com/tallyisle/tallyisle/issues',
              ),
              throwsA(
                isA<Failure>().having(
                  (f) => f.code,
                  'code',
                  FailureCode.unsupportedCapability,
                ),
              ),
            );
          } finally {
            debugDefaultTargetPlatformOverride = null;
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(channel, null);
          }
        },
      );
    },
  );
}
