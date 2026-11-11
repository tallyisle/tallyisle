import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/db/seed.dart';
import 'package:tallyisle/data/settings/app_lock_service.dart';
import 'package:tallyisle/data/settings/app_settings_service.dart';
import 'package:tallyisle/data/settings/data_health_service.dart';
import 'package:tallyisle/data/settings/stat_story_service.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/app_lock_rules.dart';
import 'package:tallyisle/domain/rules/app_settings_rules.dart';
import 'package:tallyisle/domain/rules/data_health_rules.dart';
import 'package:tallyisle/platform/biometrics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late int fakeNowMs;
  var seq = 0;
  String nextCmd() => 'sec-svc-cmd-${seq++}';

  setUp(() {
    fakeNowMs = 1730000000000;
    db = AppDatabase(NativeDatabase.memory(), nowMs: () => fakeNowMs);
  });

  tearDown(() async {
    await db.close();
  });

  group('AppLockService & BiometricAuthenticator (F-024, ADR-008, ADR-009)', () {
    test(
      'stores salted PBKDF2 hash without plaintext PIN, enforces persistent 5-failure 30s cooldown, and supports ADR-009 idempotency',
      () async {
        final bio = InMemoryBiometricAuthenticator();
        final svc = AppLockService(db, authenticator: bio);

        final enabledCmd = nextCmd();
        final cfg = await svc.enableAppLock(
          commandId: enabledCmd,
          pin: '2580',
          biometricEnabled: true,
          timeoutSeconds: 30,
        );
        expect(cfg.isConfigured, isTrue);
        expect(cfg.pinLength, 4);
        expect(cfg.biometricEnabled, isTrue);
        expect(cfg.timeoutSeconds, 30);

        final replayCfg = await svc.enableAppLock(
          commandId: enabledCmd,
          pin: '2580',
          biometricEnabled: true,
          timeoutSeconds: 30,
        );
        expect(replayCfg, cfg);
        await expectLater(
          svc.enableAppLock(
            commandId: enabledCmd,
            pin: '9999',
            biometricEnabled: true,
            timeoutSeconds: 30,
          ),
          throwsA(
            isA<Failure>().having((f) => f.code, 'code', FailureCode.conflict),
          ),
        );

        final rawPref = await (db.select(
          db.preferences,
        )..where((t) => t.key.equals(appLockPreferenceKey))).getSingle();
        expect(rawPref.value.contains('2580'), isFalse);

        // 5 failed attempts via changePin / verifyPin persist cooldown even when changePin throws!
        for (var i = 0; i < 4; i++) {
          await expectLater(
            svc.changePin(
              commandId: nextCmd(),
              currentPin: '0000',
              newPin: '123456',
            ),
            throwsA(
              isA<Failure>().having(
                (f) => f.code,
                'code',
                FailureCode.authRequired,
              ),
            ),
          );
        }
        final fifth = await svc.verifyPin('1111');
        expect(fifth.lockedOut, isTrue);
        expect(fifth.remainingCooldownSeconds, 30);

        final reloaded = await svc.getConfig();
        expect(reloaded.isCoolingDownAt(fakeNowMs + 10000), isTrue);

        final blocked = await svc.verifyPin('2580');
        expect(blocked.matched, isFalse);
        expect(blocked.lockedOut, isTrue);

        fakeNowMs += 31000;
        final changed = await svc.changePin(
          commandId: nextCmd(),
          currentPin: '2580',
          newPin: '654321',
        );
        expect(changed.pinLength, 6);
        expect((await svc.verifyPin('654321')).matched, isTrue);

        await svc.verifyPin('000000');
        expect((await svc.getConfig()).failedAttempts, 1);
        final bioRes = await svc.authenticateWithBiometrics();
        expect(bioRes.isAuthenticated, isTrue);
        expect((await svc.getConfig()).failedAttempts, 0);

        await svc.disableAppLock(commandId: nextCmd(), currentPin: '654321');
        expect((await svc.getConfig()).isConfigured, isFalse);
      },
    );

    test(
      'MethodChannelBiometricAuthenticator wire protocol & UnsupportedBiometricAuthenticator fallback (ADR-008)',
      () async {
        const channel = MethodChannel('dev.tallyisle/biometrics_test');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'checkAvailability') {
            return <String, Object?>{
              'status': 'available',
              'reason': '已就绪',
              'deviceSecure': true,
            };
          }
          if (call.method == 'authenticate') {
            final args = call.arguments as Map<Object?, Object?>;
            expect(args['title'], isNotEmpty);
            return <String, Object?>{
              'outcome': 'authenticated',
              'message': '验证通过',
            };
          }
          return null;
        });

        final mcAuth = MethodChannelBiometricAuthenticator(channel: channel);
        final avail = await mcAuth.checkAvailability();
        expect(avail.canAuthenticate, isTrue);
        expect(avail.deviceSecure, isTrue);
        final res = await mcAuth.authenticate();
        expect(res.isAuthenticated, isTrue);

        const unsupported = UnsupportedBiometricAuthenticator();
        expect(
          (await unsupported.checkAvailability()).canAuthenticate,
          isFalse,
        );
        expect(
          (await unsupported.authenticate()).outcome,
          BiometricAuthOutcome.unsupportedPlatform,
        );
      },
    );
  });

  group('DataHealthService atomic check & repair (ADR-012, ADR-009)', () {
    test(
      'repairs ordinary cached balance, debt principal/status, and orphan tag_record while preserving credit card balance & init_money',
      () async {
        // 1. Ordinary account: init 10,000 + income 5,000 - lent 3,000 = expected 12,000; seed drifted 99,999
        final cashId = await db
            .into(db.assets)
            .insert(
              AssetsCompanion.insert(
                name: '工行储蓄卡',
                type: AssetType.normal,
                balanceMinor: BigInt.from(99999),
                initMoneyMinor: BigInt.from(10000),
                createDate: fakeNowMs,
                currency: const Value('CNY'),
              ),
            );

        // 2. Debt account (lend-out): lent 3,000 -> expected 3,000 & active(0); seed drifted 500 & active(0)
        final debtId = await db
            .into(db.assets)
            .insert(
              AssetsCompanion.insert(
                name: '借给同事',
                type: AssetType.debt,
                subType: const Value(AssetType.debtLend),
                status: const Value(AssetStatus.active),
                balanceMinor: BigInt.from(500),
                initMoneyMinor: BigInt.zero,
                createDate: fakeNowMs,
                currency: const Value('CNY'),
              ),
            );

        // 3. Credit card (type=6): credit limit initMoneyMinor = 3,000,000 (¥30,000),
        //    initial debt + expense -> balanceMinor = -88,000. Must NEVER be altered by repair!
        final creditId = await db
            .into(db.assets)
            .insert(
              AssetsCompanion.insert(
                name: '平安信用卡',
                type: AssetType.credit,
                balanceMinor: BigInt.from(-88000),
                initMoneyMinor: BigInt.from(3000000),
                creditInfo: const Value('{"bill_day":12,"repayment_day":1}'),
                createDate: fakeNowMs,
                currency: const Value('CNY'),
              ),
            );

        await db
            .into(db.records)
            .insert(
              RecordsCompanion.insert(
                recordId: 'rec-inc-1',
                type: RecordType.income,
                moneyMinor: BigInt.from(5000),
                recordTime: fakeNowMs,
                recordCatId: const Value(13),
                assetId: Value(cashId),
                accountBookId: defaultBookId,
              ),
            );
        await db
            .into(db.records)
            .insert(
              RecordsCompanion.insert(
                recordId: 'rec-debt-1',
                type: RecordType.lendOut,
                moneyMinor: BigInt.from(3000),
                recordTime: fakeNowMs + 100,
                fromAssetId: Value(cashId),
                toAssetId: Value(debtId),
                accountBookId: defaultBookId,
              ),
            );
        await db
            .into(db.records)
            .insert(
              RecordsCompanion.insert(
                recordId: 'rec-cc-1',
                type: RecordType.expense,
                moneyMinor: BigInt.from(18000),
                recordTime: fakeNowMs + 200,
                recordCatId: const Value(1),
                assetId: Value(creditId),
                accountBookId: defaultBookId,
              ),
            );

        await db
            .into(db.tags)
            .insert(TagsCompanion.insert(tagId: 'tag-valid', name: '日常'));
        await db
            .into(db.tagRecords)
            .insert(
              TagRecordsCompanion.insert(
                tagId: 'tag-valid',
                recordId: 'rec-inc-1',
              ),
            );
        await db
            .into(db.tagRecords)
            .insert(
              TagRecordsCompanion.insert(
                tagId: 'tag-valid',
                recordId: 'ghost-record-id',
              ),
            );

        final svc = DataHealthService(db);
        final before = await svc.checkHealth();
        expect(before.isHealthy, isFalse);
        expect(before.ordinaryRepairs.length, 1);
        expect(before.debtRepairs.length, 1);
        expect(before.orphanTagRepairs.length, 1);
        expect(
          before.issues.any(
            (i) =>
                i.assetId == creditId &&
                i.kind == DataHealthIssueKind.creditInitialOffsetInfo,
          ),
          isTrue,
        );

        final repairCmd = nextCmd();
        final repaired = await svc.repairDataHealth(commandId: repairCmd);
        expect(repaired.repairedOrdinaryCount, 1);
        expect(repaired.repairedDebtCount, 1);
        expect(repaired.removedOrphanTagCount, 1);
        expect(repaired.remainingManualIssueCount, 0);

        final replay = await svc.repairDataHealth(commandId: repairCmd);
        expect(replay.totalRepairedCount, 3);

        final cashAfter = await (db.select(
          db.assets,
        )..where((t) => t.id.equals(cashId))).getSingle();
        expect(cashAfter.balanceMinor, BigInt.from(12000));

        final debtAfter = await (db.select(
          db.assets,
        )..where((t) => t.id.equals(debtId))).getSingle();
        expect(debtAfter.balanceMinor, BigInt.from(3000));
        expect(debtAfter.status, AssetStatus.active);

        final creditAfter = await (db.select(
          db.assets,
        )..where((t) => t.id.equals(creditId))).getSingle();
        expect(creditAfter.balanceMinor, BigInt.from(-88000));
        expect(creditAfter.initMoneyMinor, BigInt.from(3000000));

        final remainingTags = await db.select(db.tagRecords).get();
        expect(remainingTags.length, 1);
        expect(remainingTags.single.recordId, 'rec-inc-1');

        final after = await svc.checkHealth();
        expect(after.isHealthy, isTrue);
        expect(after.repairableCount, 0);
      },
    );
  });

  group('AppSettingsService & StatStoryService (F-038, ADR-009)', () {
    test('persists, watches, and resets AppSettings idempotently', () async {
      final svc = AppSettingsService(db);
      expect(await svc.getSettings(), AppSettings.defaults);

      const custom = AppSettings(
        showBalanceChangeRecordOnHome: true,
        showHomeAssetSummaryBanner: false,
        showHomeBudgetCard: true,
        defaultRecordType: RecordType.income,
        themeMode: AppThemeModePreference.dark,
        themeSeedHex: '1565C0',
      );
      final saveCmd = nextCmd();
      await svc.saveSettings(commandId: saveCmd, settings: custom);
      expect(await svc.getSettings(), custom);

      expect(
        await svc.saveSettings(commandId: saveCmd, settings: custom),
        custom,
      );

      await svc.resetSettings(commandId: nextCmd());
      expect(await svc.getSettings(), AppSettings.defaults);
    });

    test(
      'StatStoryService CRUD and generatePeriodNarrative with exact Money math (excludes balance adjustments)',
      () async {
        final svc = StatStoryService(db);

        await db
            .into(db.records)
            .insert(
              RecordsCompanion.insert(
                recordId: 'st-inc',
                type: RecordType.income,
                moneyMinor: BigInt.from(50000),
                recordTime: 1730000100000,
                recordCatId: const Value(13),
                accountBookId: defaultBookId,
              ),
            );
        await db
            .into(db.records)
            .insert(
              RecordsCompanion.insert(
                recordId: 'st-exp',
                type: RecordType.expense,
                moneyMinor: BigInt.from(8850),
                recordTime: 1730000200000,
                recordCatId: const Value(1),
                accountBookId: defaultBookId,
              ),
            );
        await db
            .into(db.records)
            .insert(
              RecordsCompanion.insert(
                recordId: 'st-exp-standalone-neg',
                type: RecordType.expense,
                moneyMinor: BigInt.from(-2000),
                recordTime: 1730000250000,
                recordCatId: const Value(1),
                accountBookId: defaultBookId,
              ),
            );
        await db
            .into(db.records)
            .insert(
              RecordsCompanion.insert(
                recordId: 'st-bal-adj',
                type: RecordType.balanceAdjust,
                moneyMinor: BigInt.from(99900),
                recordTime: 1730000300000,
                accountBookId: defaultBookId,
              ),
            );

        final generated = await svc.generatePeriodNarrative(
          bookId: defaultBookId,
          startMs: 1730000000000,
          endMs: 1730009999000,
          sectionLabel: '2026年11月',
        );
        expect(generated, contains('共记录 3 笔账单'));
        expect(generated, contains('总收入 500.00 元'));
        expect(generated, contains('总支出 68.50 元'));
        expect(generated, contains('结余 431.50 元'));
        expect(generated, contains('「餐饮」（68.50 元）'));

        final id = await svc.saveStory(
          commandId: nextCmd(),
          draft: StatStoryDraft(
            story: generated,
            bookId: defaultBookId,
            sdate: 1730000000000,
            edate: 1730009999000,
            dsection: '2026年11月',
          ),
        );

        var rows = await svc.getStories(bookId: defaultBookId);
        expect(rows.length, 1);
        expect(rows.single.id, id);

        await svc.saveStory(
          commandId: nextCmd(),
          id: id,
          draft: const StatStoryDraft(
            story: '手动编辑后的月度总结',
            bookId: defaultBookId,
            sdate: 1730000000000,
            edate: 1730009999000,
            dsection: '2026年11月（修订）',
          ),
        );
        rows = await svc.getStories();
        expect(rows.single.story, '手动编辑后的月度总结');
        expect(rows.single.dsection, '2026年11月（修订）');

        await svc.deleteStory(commandId: nextCmd(), id: id);
        expect(await svc.getStories(), isEmpty);
      },
    );
  });
}
