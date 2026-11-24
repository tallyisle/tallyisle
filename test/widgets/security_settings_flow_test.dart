import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/db/seed.dart';
import 'package:tallyisle/data/settings/app_lock_service.dart';
import 'package:tallyisle/data/settings/app_settings_service.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/features/security/app_lock_gate.dart';
import 'package:tallyisle/features/security/app_lock_providers.dart';
import 'package:tallyisle/features/security/app_lock_settings_page.dart';
import 'package:tallyisle/features/settings/about_help_page.dart';
import 'package:tallyisle/features/settings/data_health_page.dart';
import 'package:tallyisle/features/settings/settings_page.dart';
import 'package:tallyisle/features/settings/stat_stories_page.dart';
import 'package:tallyisle/platform/biometrics.dart';
import 'package:tallyisle/platform/files.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  (AppDatabase, Future<void> Function()) openTestDb(
    WidgetTester tester, {
    int Function()? nowMs,
  }) {
    final db = AppDatabase(NativeDatabase.memory(), nowMs: nowMs);
    var closed = false;
    Future<void> closeCleanly() async {
      if (closed) return;
      closed = true;
      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester);
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

  Future<void> tapPinDigits(WidgetTester tester, String digits) async {
    for (final ch in digits.split('')) {
      await tester.tap(find.byKey(Key('app_lock_key_$ch')));
      await settle(tester);
    }
  }

  testWidgets(
    'AppLockGate hides ledger UI on cold start, enforces 5-failure 30s cooldown, unlocks via PIN & biometrics, and re-locks after background timeout (F-024)',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      var nowMs = 1730000000000;
      final (db, closeCleanly) = openTestDb(tester, nowMs: () => nowMs);
      final bio = InMemoryBiometricAuthenticator();

      await tester.runAsync(() async {
        final svc = AppLockService(db, authenticator: bio);
        await svc.enableAppLock(
          commandId: 'gate-seed-1',
          pin: '2580',
          biometricEnabled: true,
          timeoutSeconds: 30,
        );
      });

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            biometricAuthenticatorProvider.overrideWithValue(bio),
            appLockClockProvider.overrideWithValue(() => nowMs),
          ],
          child: const MaterialApp(
            home: AppLockGate(
              child: Scaffold(body: Center(child: Text('敏感净资产 ¥88,888.00'))),
            ),
          ),
        ),
      );
      await settle(tester);

      // Cold start: overlay shown, sensitive ledger text hidden by Visibility(visible: false)
      expect(find.byKey(const Key('app_lock_overlay')), findsOneWidget);
      expect(find.text('敏感净资产 ¥88,888.00'), findsNothing);

      // Enter 5 wrong PINs -> triggers 30s cooldown
      for (var i = 0; i < 5; i++) {
        await tapPinDigits(tester, '0000');
      }
      expect(find.byKey(const Key('app_lock_message')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('app_lock_message'))).data,
        contains('30'),
      );

      // Advance clock past 30s cooldown -> right PIN unlocks and reveals ledger
      nowMs += 31000;
      await tapPinDigits(tester, '2580');
      expect(find.byKey(const Key('app_lock_overlay')), findsNothing);
      expect(find.text('敏感净资产 ¥88,888.00'), findsOneWidget);

      // Simulate backgrounding for 10s (< 30s timeout) -> stays unlocked
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      nowMs += 10000;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settle(tester);
      expect(find.byKey(const Key('app_lock_overlay')), findsNothing);

      // Simulate backgrounding for 35s (>= 30s timeout) -> re-locks and hides ledger
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      nowMs += 35000;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settle(tester);
      expect(find.byKey(const Key('app_lock_overlay')), findsOneWidget);
      expect(find.text('敏感净资产 ¥88,888.00'), findsNothing);

      // Unlock via biometric button
      await tester.tap(find.byKey(const Key('app_lock_biometric_button')));
      await settle(tester);
      expect(bio.authenticateCount, 1);
      expect(find.byKey(const Key('app_lock_overlay')), findsNothing);
      expect(find.text('敏感净资产 ¥88,888.00'), findsOneWidget);

      await closeCleanly();
    },
  );

  testWidgets(
    'AppLockSettingsPage enables/disables 6-digit PIN and cleanly disables biometric toggle on unsupported platforms (ADR-008)',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final (db, closeCleanly) = openTestDb(tester);
      const unsupportedBio = UnsupportedBiometricAuthenticator();

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            biometricAuthenticatorProvider.overrideWithValue(unsupportedBio),
          ],
          child: const MaterialApp(home: AppLockSettingsPage()),
        ),
      );
      await settle(tester);

      // Enable 6-digit PIN
      await tester.tap(find.byKey(const Key('app_lock_enable_switch')));
      await settle(tester);
      await tester.tap(find.text('6 位密码'));
      await settle(tester);
      await tester.enterText(find.byKey(const Key('new_pin_input')), '147258');
      await tester.enterText(
        find.byKey(const Key('confirm_pin_input')),
        '147258',
      );
      await tester.tap(find.byKey(const Key('confirm_set_pin_button')));
      await settle(tester);

      expect(find.textContaining('已启用 6 位加盐哈希密码保护'), findsOneWidget);

      // Biometric switch is disabled because platform reports unsupportedPlatform
      final bioSwitch = tester.widget<SwitchListTile>(
        find.byKey(const Key('app_lock_biometric_switch')),
      );
      expect(bioSwitch.onChanged, isNull);

      // Select 60s timeout
      await tester.tap(find.byKey(const Key('app_lock_timeout_60')));
      await settle(tester);

      // Disable App Lock with current PIN verification
      await tester.tap(find.byKey(const Key('app_lock_enable_switch')));
      await settle(tester);
      await tester.enterText(
        find.byKey(const Key('verify_current_pin_input')),
        '147258',
      );
      await tester.tap(find.byKey(const Key('confirm_verify_pin_button')));
      await settle(tester);

      expect(find.textContaining('开启后冷启动或从后台切回时需验证身份'), findsOneWidget);

      await closeCleanly();
    },
  );

  testWidgets(
    'SettingsPage persists toggles & custom hex theme, and navigates to AboutHelpPage verifying BRAND-001 & P-03',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final (db, closeCleanly) = openTestDb(tester);

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: const MaterialApp(home: SettingsPage()),
        ),
      );
      await settle(tester);

      // Toggle showBalanceChangeRecordOnHome ON
      await tester.tap(
        find.byKey(const Key('setting_show_balance_change_switch')),
      );
      await settle(tester);

      // Apply custom theme hex #6A1B9A
      await tester.tap(find.byKey(const Key('theme_custom_hex_chip')));
      await settle(tester);
      await tester.enterText(
        find.byKey(const Key('theme_custom_hex_input')),
        '#6a1b9a',
      );
      await tester.tap(
        find.byKey(const Key('theme_custom_hex_confirm_button')),
      );
      await settle(tester);

      final persisted = await tester.runAsync(
        () => AppSettingsService(db).getSettings(),
      );
      expect(persisted!.showBalanceChangeRecordOnHome, isTrue);
      expect(persisted.themeSeedHex, '6A1B9A');

      // Navigate to AboutHelpPage
      final aboutTile = find.byKey(const Key('nav_about_help_tile'));
      await tester.scrollUntilVisible(
        aboutTile,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(aboutTile);
      await settle(tester);
      await tester.tap(aboutTile);
      await settle(tester);

      expect(find.text('帐屿 · TallyIsle'), findsOneWidget);
      expect(find.text('项目与开源'), findsOneWidget);
      expect(find.text('开源代码仓库'), findsOneWidget);
      expect(find.text(tallyIsleRepoUrl), findsOneWidget);
      expect(find.text('问题反馈与建议'), findsOneWidget);
      expect(find.byKey(const Key('about_licenses_tile')), findsOneWidget);
      expect(find.text('全功能永久免费 · 无会员门控'), findsOneWidget);
      expect(find.textContaining('一羽记账'), findsNothing);
      expect(find.textContaining('账屿'), findsNothing);

      await closeCleanly();
    },
  );

  testWidgets(
    'AboutHelpPage opens GitHub repo & Issues URLs, supports one-tap copy buttons, and falls back to clipboard when browser launch fails',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      String clipboardText = '';
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              final args = call.arguments as Map<Object?, Object?>;
              clipboardText = (args['text'] as String?) ?? '';
            } else if (call.method == 'Clipboard.getData') {
              return <String, Object?>{'text': clipboardText};
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      final openedUrls = <String>[];
      var failBrowser = false;
      final fileAccess = FileAccess(
        onOpenExternalUrl: (url) async {
          if (failBrowser) {
            throw const Failure(FailureCode.unsupportedCapability, '无法调起系统浏览器');
          }
          openedUrls.add(url);
        },
      );

      await tester.pumpWidget(
        MaterialApp(home: AboutHelpPage(fileAccess: fileAccess)),
      );
      await settle(tester);

      expect(find.text('本地优先、精确到分的开源个人记账与资产管理工具'), findsOneWidget);
      expect(
        find.text(
          '基于 Flutter 构建 · 支持 Android / iOS / HarmonyOS / Windows / Linux / macOS 六端',
        ),
        findsOneWidget,
      );
      expect(find.text('项目与开源'), findsOneWidget);
      expect(find.text('开源代码仓库'), findsOneWidget);
      expect(
        find.text('https://github.com/tallyisle/tallyisle'),
        findsOneWidget,
      );
      expect(find.text('问题反馈与建议'), findsOneWidget);
      expect(find.byKey(const Key('about_licenses_tile')), findsOneWidget);
      expect(find.textContaining('一羽记账'), findsNothing);
      expect(find.textContaining('账屿'), findsNothing);

      // 1. Tap repo & issues tiles -> launches external browser with exact URLs
      await tester.tap(find.byKey(const Key('about_github_repo_tile')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('about_github_issues_tile')));
      await settle(tester);
      expect(openedUrls, const <String>[tallyIsleRepoUrl, tallyIsleIssuesUrl]);
      expect(clipboardText, isEmpty);

      // 2. Tap copy buttons -> copies to Clipboard + shows SnackBar without launching browser
      await tester.tap(find.byKey(const Key('about_copy_repo_url_button')));
      await settle(tester);
      expect(clipboardText, tallyIsleRepoUrl);
      expect(find.text('已复制开源仓库地址'), findsOneWidget);
      expect(openedUrls, hasLength(2));

      await tester.tap(find.byKey(const Key('about_copy_issues_url_button')));
      await settle(tester);
      expect(clipboardText, tallyIsleIssuesUrl);
      expect(find.text('已复制问题反馈地址'), findsOneWidget);
      expect(openedUrls, hasLength(2));

      // 3. Browser launch throws -> automatically copies URL to Clipboard + fallback SnackBar
      failBrowser = true;
      clipboardText = '';
      await tester.tap(find.byKey(const Key('about_github_repo_tile')));
      await settle(tester);
      expect(clipboardText, tallyIsleRepoUrl);
      expect(find.text('未检测到可用浏览器，已复制链接：$tallyIsleRepoUrl'), findsOneWidget);

      await tester.tap(find.byKey(const Key('about_github_issues_tile')));
      await settle(tester);
      expect(clipboardText, tallyIsleIssuesUrl);
      expect(find.text('未检测到可用浏览器，已复制链接：$tallyIsleIssuesUrl'), findsOneWidget);

      // 4. Verify zero RenderFlex overflow across 360x640, 390x844, 960x800 in Light & Dark @ 1.2x text scale
      for (final viewport in const <Size>[
        Size(360, 640),
        Size(390, 844),
        Size(960, 800),
      ]) {
        for (final brightness in const <Brightness>[
          Brightness.light,
          Brightness.dark,
        ]) {
          await tester.binding.setSurfaceSize(viewport);
          await tester.pumpWidget(
            MaterialApp(
              key: ValueKey<String>('$viewport-$brightness'),
              theme: ThemeData(
                colorScheme: ColorScheme.fromSeed(
                  seedColor: const Color(0xFF006972),
                  brightness: brightness,
                ),
                useMaterial3: true,
              ),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(1.2)),
                child: child!,
              ),
              home: const AboutHelpPage(),
            ),
          );
          await settle(tester);
          expect(tester.takeException(), isNull);
          expect(
            find.text('https://github.com/tallyisle/tallyisle'),
            findsOneWidget,
          );
          expect(find.text('问题反馈与建议'), findsOneWidget);

          final scrollable = tester.state<ScrollableState>(
            find.byType(Scrollable).first,
          );
          scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
          await tester.pump(const Duration(milliseconds: 50));
          expect(tester.takeException(), isNull);
        }
      }
    },
  );

  testWidgets(
    'DataHealthPage repairs drifted non-credit balance & orphan tags while preserving credit card balance, and StatStoriesPage supports narrative generation & CRUD',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final nowMs = DateTime(2026, 11, 10, 12).millisecondsSinceEpoch;
      final (db, closeCleanly) = openTestDb(tester, nowMs: () => nowMs);

      late int cashId;
      late int creditId;
      await tester.runAsync(() async {
        cashId = await db
            .into(db.assets)
            .insert(
              AssetsCompanion.insert(
                name: '日常钱包',
                type: AssetType.normal,
                balanceMinor: BigInt.from(77777), // drifted! expected 6000
                initMoneyMinor: BigInt.from(10000),
                createDate: nowMs,
                currency: const Value('CNY'),
              ),
            );
        creditId = await db
            .into(db.assets)
            .insert(
              AssetsCompanion.insert(
                name: '工行信用卡',
                type: AssetType.credit,
                balanceMinor: BigInt.from(-25000),
                initMoneyMinor: BigInt.from(2000000),
                creditInfo: const Value('{"bill_day":15,"repayment_day":5}'),
                createDate: nowMs,
                currency: const Value('CNY'),
              ),
            );
        await db
            .into(db.records)
            .insert(
              RecordsCompanion.insert(
                recordId: 'w-exp-1',
                type: RecordType.expense,
                moneyMinor: BigInt.from(4000),
                recordTime: nowMs,
                recordCatId: const Value(1),
                assetId: Value(cashId),
                accountBookId: defaultBookId,
              ),
            );
        await db
            .into(db.tagRecords)
            .insert(
              TagRecordsCompanion.insert(
                tagId: 'missing-tag',
                recordId: 'w-exp-1',
              ),
            );
      });

      // 1. Verify DataHealthPage detects & repairs
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: const MaterialApp(home: DataHealthPage()),
        ),
      );
      await settle(tester);

      expect(
        find.byKey(const Key('data_health_repair_button')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('data_health_repair_button')));
      await settle(tester);
      await tester.tap(
        find.byKey(const Key('data_health_confirm_repair_button')),
      );
      await settle(tester);

      expect(find.text('账本数据健康'), findsOneWidget);

      final assetsAfter = await tester.runAsync(
        () => db.select(db.assets).get(),
      );
      final cashRow = assetsAfter!.firstWhere((a) => a.id == cashId);
      final creditRow = assetsAfter.firstWhere((a) => a.id == creditId);
      expect(cashRow.balanceMinor, BigInt.from(6000));
      expect(creditRow.balanceMinor, BigInt.from(-25000));
      expect(creditRow.initMoneyMinor, BigInt.from(2000000));

      // 2. Verify StatStoriesPage generates period narrative, edits, and deletes
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: const MaterialApp(home: StatStoriesPage()),
        ),
      );
      await settle(tester);

      expect(find.text('暂无统计故事'), findsOneWidget);
      await tester.tap(find.byKey(const Key('stat_story_add_fab')));
      await settle(tester);

      await tester.enterText(
        find.byKey(const Key('stat_story_dsection_input')),
        '2026年11月回顾',
      );
      await tester.tap(find.byKey(const Key('stat_story_generate_button')));
      await settle(tester);

      final generatedStoryText = tester
          .widget<TextField>(find.byKey(const Key('stat_story_content_input')))
          .controller!
          .text;
      expect(generatedStoryText, contains('总支出 40.00 元'));
      expect(generatedStoryText, contains('「餐饮」（40.00 元）'));
      await tester.tap(find.byKey(const Key('stat_story_save_button')));
      await settle(tester);

      expect(find.text('2026年11月回顾'), findsOneWidget);
      expect(find.textContaining('总支出 40.00 元'), findsOneWidget);

      // Edit story
      await tester.tap(find.byIcon(Icons.edit_outlined).first);
      await settle(tester);
      await tester.enterText(
        find.byKey(const Key('stat_story_content_input')),
        '本月餐饮支出 40.00 元，整体控制在预算之内。',
      );
      await tester.tap(find.byKey(const Key('stat_story_save_button')));
      await settle(tester);
      expect(find.text('本月餐饮支出 40.00 元，整体控制在预算之内。'), findsOneWidget);

      // Delete story
      await tester.tap(find.byIcon(Icons.delete_outline).first);
      await settle(tester);
      await tester.tap(
        find.byKey(const Key('stat_story_confirm_delete_button')),
      );
      await settle(tester);
      expect(find.text('暂无统计故事'), findsOneWidget);

      await closeCleanly();
    },
  );
}
