import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as raw_sqlite;
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/migration/cross_migration_service.dart';
import 'package:tallyisle/data/migration/lan_zip_crypto.dart';
import 'package:tallyisle/domain/rules/ios_migration_rules.dart';
import 'package:tallyisle/platform/notifications.dart';

Uint8List _hexToBytes(String hex) {
  final clean = hex.replaceAll(' ', '');
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _bytesToHex(Uint8List bytes) =>
    [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();

/// Builds a genuine Room v42 SQLite `.db` binary using `docs/reference/original-schema-room-v42.sql`
/// conventions (`REAL` money columns, `_id` + `id` on `account_book`, `uid`/`sstatus`/`sync_time`).
Uint8List _buildRoomV42DatabaseBytes(Directory workDir) {
  final file = File('${workDir.path}/build_room_v42.db');
  if (file.existsSync()) file.deleteSync();
  final raw = raw_sqlite.sqlite3.open(file.path);
  try {
    raw.execute('''
      CREATE TABLE account_book (
        _id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
        id INTEGER NOT NULL,
        type INTEGER NOT NULL DEFAULT 1,
        name TEXT NOT NULL,
        cover TEXT NOT NULL,
        sort INTEGER NOT NULL DEFAULT 1,
        status INTEGER NOT NULL,
        start_day INTEGER NOT NULL,
        create_date INTEGER NOT NULL,
        display_way INTEGER NOT NULL,
        extra_info TEXT,
        sync_time INTEGER NOT NULL,
        sstatus INTEGER NOT NULL,
        uid TEXT NOT NULL
      );
      CREATE TABLE asset (
        id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
        name TEXT NOT NULL,
        balance REAL NOT NULL,
        type INTEGER NOT NULL,
        sub_type INTEGER NOT NULL DEFAULT -1,
        create_date INTEGER NOT NULL,
        sort INTEGER NOT NULL,
        icon TEXT NOT NULL,
        remark TEXT,
        init_money REAL NOT NULL,
        is_default INTEGER NOT NULL,
        is_effective_asset INTEGER NOT NULL,
        used_times INTEGER NOT NULL,
        color TEXT,
        status INTEGER NOT NULL,
        extra_info TEXT,
        loan_info TEXT,
        credit_info TEXT,
        fixed_deposit_info TEXT,
        group_name TEXT,
        currency TEXT,
        sync_time INTEGER NOT NULL,
        sstatus INTEGER NOT NULL,
        uid TEXT NOT NULL
      );
      CREATE TABLE record_category (
        id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
        name TEXT NOT NULL,
        icon TEXT NOT NULL,
        type INTEGER NOT NULL,
        sort INTEGER NOT NULL,
        parent_cat_id INTEGER NOT NULL,
        color_fill TEXT,
        platform_id INTEGER NOT NULL,
        account_book_id INTEGER NOT NULL,
        is_hide INTEGER NOT NULL DEFAULT 0,
        extra_info TEXT,
        sync_time INTEGER NOT NULL,
        sstatus INTEGER NOT NULL,
        uid TEXT NOT NULL
      );
      CREATE TABLE record (
        record_id TEXT NOT NULL PRIMARY KEY,
        type INTEGER NOT NULL,
        sub_type INTEGER NOT NULL DEFAULT -1,
        money REAL NOT NULL,
        remark TEXT NOT NULL,
        record_time INTEGER NOT NULL,
        record_cat_id INTEGER NOT NULL,
        asset_id INTEGER NOT NULL,
        from_asset_id INTEGER NOT NULL,
        to_asset_id INTEGER NOT NULL,
        account_book_id INTEGER NOT NULL,
        exclude_budget INTEGER NOT NULL,
        exclude_ex_in INTEGER NOT NULL,
        platform_id INTEGER NOT NULL,
        period_id INTEGER NOT NULL,
        installment TEXT,
        images TEXT,
        rel_info TEXT,
        discount REAL,
        extra_info TEXT,
        create_date INTEGER,
        sync_time INTEGER NOT NULL,
        sstatus INTEGER NOT NULL,
        uid TEXT NOT NULL
      );
      CREATE TABLE asset_book (
        asset_id INTEGER NOT NULL,
        book_id INTEGER NOT NULL,
        sync_time INTEGER NOT NULL,
        sstatus INTEGER NOT NULL,
        uid TEXT NOT NULL,
        PRIMARY KEY(asset_id, book_id)
      );
      CREATE TABLE stat_story (
        id TEXT NOT NULL PRIMARY KEY,
        story TEXT NOT NULL,
        book_id INTEGER NOT NULL,
        sdate INTEGER NOT NULL,
        edate INTEGER NOT NULL,
        dsection TEXT,
        sync_time INTEGER NOT NULL,
        sstatus INTEGER NOT NULL,
        uid TEXT NOT NULL
      );
      CREATE TABLE reminder_event (
        id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
        reminder_time INTEGER NOT NULL,
        reminder_tip TEXT,
        sync_time INTEGER NOT NULL,
        sstatus INTEGER NOT NULL,
        uid TEXT NOT NULL
      );
    ''');

    // Duplicate id=1 books across uid="" and uid="user1" + a tombstone book (sstatus=4)
    raw.execute('''
      INSERT INTO account_book (id, type, name, cover, sort, status, start_day, create_date, display_way, sync_time, sstatus, uid)
      VALUES
        (1, 1, '日常账本', '', 1, 0, 1, 1700000000000, 0, 0, 0, 'user1'),
        (1, 1, '局域网家庭账本', 'c2', 1, 0, 10, 1700000005000, 0, 0, 1, ''),
        (2, 1, '已删除账本', '', 2, 0, 1, 1700000006000, 0, 0, 4, '');
    ''');

    raw.execute('''
      INSERT INTO record_category (id, name, icon, type, sort, parent_cat_id, platform_id, account_book_id, is_hide, sync_time, sstatus, uid)
      VALUES (101, '超市采购', 'ic_shop', 0, 0, -1, -1, 1, 0, 0, 0, '');
    ''');

    raw.execute('''
      INSERT INTO asset (id, name, balance, type, sub_type, create_date, sort, icon, init_money, is_default, is_effective_asset, used_times, status, credit_info, sync_time, sstatus, uid)
      VALUES
        (301, '工商银行卡', 8765.43, 0, 2, 1700000000000, 0, 'ic_icbc', 1000.00, 1, 1, 3, 0, '{"limit":30000,"inst":[{"p":"202611","b":500.25,"i":100.50}]}', 0, 0, ''),
        (302, '已删账户', 999.99, 0, 0, 1700000000000, 1, '', 0.0, 0, 1, 0, 0, NULL, 0, 4, '');
    ''');

    raw.execute('''
      INSERT INTO record (record_id, type, sub_type, money, remark, record_time, record_cat_id, asset_id, from_asset_id, to_asset_id, account_book_id, exclude_budget, exclude_ex_in, platform_id, period_id, discount, extra_info, sync_time, sstatus, uid)
      VALUES
        ('lan-rec-1', 0, -1, 128.65, '周末生鲜', 1715000000000, 101, 301, -1, -1, 1, 0, 0, -1, -1, 5.35, '{"curr":{"sc":"USD","sm":18.0,"r":"7.15","ac":"CNY","am":128.65,"bc":"CNY","bm":128.65}}', 0, 1, ''),
        ('lan-rec-del', 0, -1, 500.00, '墓碑账单', 1715000001000, 101, 301, -1, -1, 1, 0, 0, -1, -1, NULL, NULL, 0, 4, '');
    ''');

    raw.execute('''
      INSERT INTO asset_book (asset_id, book_id, sync_time, sstatus, uid)
      VALUES (301, 1, 0, 0, '');
    ''');

    raw.execute('''
      INSERT INTO stat_story (id, story, book_id, sdate, edate, dsection, sync_time, sstatus, uid)
      VALUES ('lan-story-1', '家庭采购月度总结', 1, 1714500000000, 1717000000000, '2026-05', 0, 0, '');
    ''');

    raw.execute('''
      INSERT INTO reminder_event (id, reminder_time, reminder_tip, sync_time, sstatus, uid)
      VALUES (1, 1230, '晚间对账', 0, 0, '');
    ''');
  } finally {
    raw.close();
  }

  final bytes = file.readAsBytesSync();
  file.deleteSync();
  return bytes;
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('lan_zip_crypto FIPS-197 AES, PBKDF2-HMAC-SHA1 & WinZip AE-2', () {
    test(
      'matches official NIST FIPS-197 Appendix C.1 (AES-128) & C.3 (AES-256)',
      () {
        final plain = _hexToBytes('00112233445566778899aabbccddeeff');

        final key128 = _hexToBytes('000102030405060708090a0b0c0d0e0f');
        final enc128 = AesBlockCipher(key128).encryptBlock(plain);
        expect(_bytesToHex(enc128), '69c4e0d86a7b0430d8cdb78070b4c55a');

        final key256 = _hexToBytes(
          '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f',
        );
        final enc256 = AesBlockCipher(key256).encryptBlock(plain);
        expect(_bytesToHex(enc256), '8ea2b7ca516745bfeafc49904b496089');
      },
    );

    test('matches RFC 6070 PBKDF2-HMAC-SHA1 vector', () {
      final dk = pbkdf2HmacSha1(
        passwordBytes: Uint8List.fromList(utf8.encode('password')),
        salt: Uint8List.fromList(utf8.encode('salt')),
        iterations: 2,
        derivedKeyLength: 20,
      );
      expect(_bytesToHex(dk), 'ea6c014dc72d6f8ccd1ed92ace1d41f0d8de8957');
    });

    test(
      'verifies WinZip AE-2 2-byte password check AND 10-byte HMAC-SHA1-80 MAC tamper detection + zip-slip guard',
      () async {
        final workDir = await Directory.systemTemp.createTemp('ti_ae2_unit_');
        addTearDown(() async {
          if (await workDir.exists()) await workDir.delete(recursive: true);
        });
        final dbBytes = _buildRoomV42DatabaseBytes(workDir);

        final ae2Zip = buildLanZipArchive(
          [LanZipInputEntry(name: 'yiyujizhang.db', bytes: dbBytes)],
          password: 'CustomPassword!99',
          deterministicSalt16: Uint8List.fromList(
            List<int>.generate(16, (i) => i + 1),
          ),
        );

        // 1. Missing password -> PasswordRequired
        final noPwd = extractLanSqliteBytes(bytes: ae2Zip);
        expect(noPwd, isA<LanExtractionPasswordRequired>());

        // 2. Wrong password -> WrongPassword (2-byte verifier mismatch)
        final wrongPwd = extractLanSqliteBytes(
          bytes: ae2Zip,
          password: 'WrongPassword!00',
        );
        expect(
          wrongPwd,
          isA<LanExtractionWrongPassword>().having(
            (r) => r.verifierMatched,
            'verifierMatched',
            isFalse,
          ),
        );

        // 3. Correct password -> Success
        final ok = extractLanSqliteBytes(
          bytes: ae2Zip,
          password: 'CustomPassword!99',
        );
        expect(ok, isA<LanExtractionSuccess>());
        expect((ok as LanExtractionSuccess).dbBytes, dbBytes);

        // 4. Tamper 1 ciphertext byte after salt[16] + pwdVerifier[2]:
        //    2-byte password verifier STILL matches, 10-byte HMAC-SHA1-80 rejects!
        final tampered = Uint8List.fromList(ae2Zip);
        final localNameLen = 'yiyujizhang.db'.length;
        // Local header (30) + name + extra (11) + salt (16) + verifier (2) = first ciphertext byte
        final cipherOffset = 30 + localNameLen + 11 + 16 + 2;
        tampered[cipherOffset] ^= 0xff;
        final macRejected = extractLanSqliteBytes(
          bytes: tampered,
          password: 'CustomPassword!99',
        );
        expect(
          macRejected,
          isA<LanExtractionWrongPassword>().having(
            (r) => r.verifierMatched,
            'verifierMatched',
            isTrue,
          ),
        );

        // 5. Zip-slip path traversal rejection
        final evilZip = buildLanZipArchive([
          LanZipInputEntry(name: '../outside/yiyujizhang.db', bytes: dbBytes),
        ]);
        expect(
          () => extractLanSqliteBytes(bytes: evilZip),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.corruptData,
            ),
          ),
        );
      },
    );
  });

  group('CrossMigrationService .ya2i export & .yi2a single-transaction import', () {
    test(
      'exports all 19 tables + extraNotes to .ya2i and imports .yi2a while strictly preserving local note, auto_map, and currency (CE-IOS-01/02)',
      () async {
        final sourceDb = AppDatabase(NativeDatabase.memory());
        final targetDb = AppDatabase(NativeDatabase.memory());
        final targetScheduler = InMemoryReminderScheduler();
        addTearDown(() async {
          await targetScheduler.dispose();
          await sourceDb.close();
          await targetDb.close();
        });

        // Populate all remaining tables in sourceDb on top of seeded book 1 + categories
        await sourceDb.batch((b) {
          b.insert(
            sourceDb.accountBooks,
            AccountBooksCompanion.insert(
              id: const Value(2),
              name: '装修账本',
              createDate: 1710000000000,
              startDay: const Value(15),
            ),
          );
          b.insert(
            sourceDb.assets,
            AssetsCompanion.insert(
              id: const Value(10),
              name: '建设银行储蓄卡',
              balanceMinor: BigInt.from(256789),
              type: 0,
              createDate: 1710000000000,
              initMoneyMinor: BigInt.from(100000),
              isEffectiveAsset: const Value(1),
            ),
          );
          b.insert(
            sourceDb.records,
            RecordsCompanion.insert(
              recordId: 'src-rec-1',
              type: 0,
              moneyMinor: BigInt.from(43210),
              remark: const Value('乳胶漆'),
              recordTime: 1710100000000,
              recordCatId: const Value(1),
              assetId: const Value(10),
              accountBookId: 2,
              images: const Value('paint1.jpg,paint2.jpg'),
            ),
          );
          b.insert(
            sourceDb.budgets,
            BudgetsCompanion.insert(
              id: const Value(1),
              budgetType: 0,
              recordCatId: -1,
              amountMinor: BigInt.from(3000000),
              bookId: 2,
              section: '2026-11',
              createDate: 1710000000000,
            ),
          );
          b.insert(
            sourceDb.importPlatforms,
            ImportPlatformsCompanion.insert(
              id: const Value(1),
              platform: '支付宝账单',
              importRecordCount: 8,
              importCategoryCount: 2,
              importTime: 1710000000000,
              hidden: const Value(true),
            ),
          );
          b.insert(
            sourceDb.installments,
            InstallmentsCompanion.insert(
              id: const Value(1),
              name: '洗碗机分期',
              principalMinor: BigInt.from(480000),
              periods: 6,
              chargeMinor: BigInt.from(12000),
              chargeWay: 1,
              remainderIn: 0,
              calWay: 2,
              startDate: 1710000000000,
              assetId: 10,
              nextPeriod: 2,
              nextPeriodDate: 1712600000000,
              credited: const Value('[1]'),
              bookId: 2,
              createDate: 1710000000000,
              tags: const Value('t-home'),
            ),
          );
          b.insert(
            sourceDb.recordPeriods,
            RecordPeriodsCompanion.insert(
              id: const Value(1),
              recordType: 0,
              moneyMinor: BigInt.from(19900),
              bookId: 2,
              periodType: 2,
              periodTypeDate: '["1"]',
              periodStartDate: 1710000000000,
              periodEndDate: -1,
              createTime: 1710000000000,
            ),
          );
          b.insert(
            sourceDb.reminderEvents,
            ReminderEventsCompanion.insert(
              id: const Value(5),
              reminderTime: 20 * 60 + 45,
              reminderTip: const Value('记录今日开支'),
            ),
          );
          b.insert(
            sourceDb.tags,
            TagsCompanion.insert(
              tagId: 't-home',
              name: '硬装',
              parent: const Value(0),
            ),
          );
          b.insert(
            sourceDb.tagRecords,
            TagRecordsCompanion.insert(tagId: 't-home', recordId: 'src-rec-1'),
          );
          b.insert(
            sourceDb.recordTemplates,
            RecordTemplatesCompanion.insert(
              id: const Value(1),
              type: 0,
              remark: const Value('五金辅料'),
              moneyMinor: BigInt.from(5800),
              bookId: 2,
              createDate: 1710000000000,
            ),
          );
          b.insert(
            sourceDb.bankCards,
            BankCardsCompanion.insert(
              id: const Value(1),
              cardType: 0,
              cardName: '建行龙卡',
              cardNo: '6217009988',
              cardOwner: '王五',
              createDate: 1710000000000,
              cardAssetId: const Value(10),
            ),
          );
          b.insert(
            sourceDb.wishes,
            WishesCompanion.insert(
              id: 'wish-sofa',
              content: '真皮沙发',
              valueMinor: BigInt.from(899900),
              createDate: 1710000000000,
            ),
          );
          b.insert(
            sourceDb.remarks,
            RemarksCompanion.insert(
              id: const Value(1),
              content: '建材城',
              recordCatId: 1,
              usedTimes: const Value(3),
            ),
          );
          b.insert(
            sourceDb.moneySavePlans,
            MoneySavePlansCompanion.insert(
              id: const Value(1),
              name: '软装基金',
              planType: 1,
              cycleType: 2,
              startDate: 1710000000000,
              endDate: 1740000000000,
              planMoneyMinor: BigInt.from(2000000),
              savedMoneyMinor: BigInt.from(500000),
              startMoneyMinor: BigInt.from(500000),
              incrementalMinor: BigInt.zero,
              createDate: 1710000000000,
              nextSaveDate: 1712600000000,
            ),
          );
          b.insert(
            sourceDb.moneySavePlanRecords,
            MoneySavePlanRecordsCompanion.insert(
              id: const Value(1),
              planId: 1,
              recordDate: 1710000000000,
              recordMoneyMinor: BigInt.from(500000),
            ),
          );
          b.insert(
            sourceDb.assetBooks,
            AssetBooksCompanion.insert(assetId: 10, bookId: 2),
          );
          b.insert(
            sourceDb.statStories,
            StatStoriesCompanion.insert(
              id: 'story-reno-1',
              story: '硬装阶段预算执行良好',
              bookId: 2,
              sdate: 1710000000000,
              edate: 1712600000000,
            ),
          );
          b.insert(
            sourceDb.notes,
            NotesCompanion.insert(
              id: const Value(1),
              title: const Value('源库便签'),
              content: '导出到 extraNotes',
              createTime: 1710000000000,
              updateTime: 1710000000000,
            ),
          );
        });

        final sourceService = CrossMigrationService(
          sourceDb,
          reminderScheduler: InMemoryReminderScheduler(),
        );
        final ya2iBytes = await sourceService.exportYa2iBytes();
        final ya2iJson =
            jsonDecode(utf8.decode(ya2iBytes)) as Map<String, Object?>;
        expect(
          ya2iJson['extraNotes'],
          isA<List>().having((l) => l.length, 'len', 1),
        );
        expect(
          ya2iJson['assetBookRefs'],
          isA<List>().having((l) => l.length, 'len', 1),
        );
        expect(
          ya2iJson['statStory'],
          isA<List>().having((l) => l.length, 'len', 1),
        );

        // Seed targetDb with local note, auto_map, and custom USD currency (`CE-IOS-02`)
        await targetDb.batch((b) {
          b.insert(
            targetDb.notes,
            NotesCompanion.insert(
              id: const Value(99),
              title: const Value('本地重要便签'),
              content: '跨端导入严禁清空我',
              createTime: 1711000000000,
              updateTime: 1711000000000,
            ),
          );
          b.insert(
            targetDb.autoMaps,
            AutoMapsCompanion.insert(
              id: const Value(77),
              key: 'merchant_starbucks',
              mapInfo: const Value('{"catId":1}'),
            ),
          );
          b.insert(
            targetDb.currencies,
            CurrenciesCompanion.insert(
              code: 'USD',
              name: '美元',
              symbol: r'$',
              rateToAnchor: '7.28',
              anchorCode: 'CNY',
            ),
          );
        });

        final targetService = CrossMigrationService(
          targetDb,
          reminderScheduler: targetScheduler,
        );

        final result = await targetService.importYi2aBytes(
          commandId: 'cmd-yi2a-roundtrip-1',
          fileName: 'TallyIsle-iOS2Android.yi2a',
          bytes: ya2iBytes,
        );

        expect(result.bookCount, 2);
        expect(result.assetCount, 1);
        expect(result.recordCount, 1);
        expect(result.assetBookRefCount, 1);
        expect(result.statStoryCount, 1);
        expect(result.activeBookId, 1);

        // Verify EX-19 tables (`asset_book` & `stat_story`) were fully written
        final targetAssetBooks = await targetDb
            .select(targetDb.assetBooks)
            .get();
        expect(targetAssetBooks, hasLength(1));
        expect(targetAssetBooks.single.assetId, 10);
        expect(targetAssetBooks.single.bookId, 2);

        final targetStories = await targetDb.select(targetDb.statStories).get();
        expect(targetStories, hasLength(1));
        expect(targetStories.single.story, '硬装阶段预算执行良好');

        // Verify CE-IOS-02: local note, auto_map, and currency survived 100% intact!
        final targetNotes = await targetDb.select(targetDb.notes).get();
        expect(targetNotes, hasLength(1));
        expect(targetNotes.single.id, 99);
        expect(targetNotes.single.content, '跨端导入严禁清空我');

        final targetAutoMaps = await targetDb.select(targetDb.autoMaps).get();
        expect(targetAutoMaps, hasLength(1));
        expect(targetAutoMaps.single.key, 'merchant_starbucks');

        final usd = await (targetDb.select(
          targetDb.currencies,
        )..where((t) => t.code.equals('USD'))).getSingleOrNull();
        expect(usd, isNotNull);
        expect(usd!.rateToAnchor, '7.28');

        // Verify reminder scheduler resynced automatically
        expect(targetScheduler.scheduledList, hasLength(1));
        expect(targetScheduler.scheduledList.single.hour, 20);
        expect(targetScheduler.scheduledList.single.minute, 45);
      },
    );

    test(
      'R1 & R5: rejects empty {} without touching DB and rolls back entire transaction on mid-import failure',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        final scheduler = InMemoryReminderScheduler();
        addTearDown(() async {
          await scheduler.dispose();
          await db.close();
        });

        await db
            .into(db.records)
            .insert(
              RecordsCompanion.insert(
                recordId: 'existing-rec-1',
                type: 0,
                moneyMinor: BigInt.from(9900),
                recordTime: 1700000000000,
                accountBookId: 1,
              ),
            );
        await db
            .into(db.notes)
            .insert(
              NotesCompanion.insert(
                content: '本地既有便签',
                createTime: 1700000000000,
                updateTime: 1700000000000,
              ),
            );

        final service = CrossMigrationService(db, reminderScheduler: scheduler);

        // 1. Empty `{}` rejected before DB touch
        await expectLater(
          service.importYi2aBytes(
            commandId: 'cmd-empty-yi2a',
            fileName: 'empty.yi2a',
            bytes: Uint8List.fromList(utf8.encode('{}')),
          ),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.validation,
            ),
          ),
        );

        expect(await db.select(db.records).get(), hasLength(1));

        // 2. Mid-transaction failure AFTER clearing the 19 tables rolls back 100%!
        final preview = service.preflightYi2a(
          fileName: 'valid.yi2a',
          bytes: Uint8List.fromList(
            utf8.encode(
              jsonEncode({
                'books': [
                  {'id': 5, 'name': '新账本', 'cdate': 1710000000000},
                ],
              }),
            ),
          ),
        );

        await expectLater(
          service.applyMigrationPayload(
            commandId: 'cmd-rollback-test',
            payload: preview.payload,
            debugFailAfterClear: () =>
                throw const Failure(FailureCode.corruptData, '模拟写库中途异常触发事务回滚'),
          ),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.corruptData,
            ),
          ),
        );

        // Existing book 1, 16 preset categories, existing-rec-1, and note are ALL intact!
        final booksAfterRollback = await db.select(db.accountBooks).get();
        expect(booksAfterRollback.single.id, 1);
        expect(await db.select(db.recordCategories).get(), hasLength(16));
        final recsAfterRollback = await db.select(db.records).get();
        expect(recsAfterRollback.single.recordId, 'existing-rec-1');
        expect(await db.select(db.notes).get(), hasLength(1));

        // 3. Idempotent commandId replay & conflict check (ADR-009)
        final ok1 = await service.applyMigrationPayload(
          commandId: 'cmd-idem-1',
          payload: preview.payload,
        );
        final ok2 = await service.applyMigrationPayload(
          commandId: 'cmd-idem-1',
          payload: preview.payload,
        );
        expect(ok2.activeBookId, ok1.activeBookId);
        expect(ok1.activeBookId, 5);

        final otherPreview = service.preflightYi2a(
          fileName: 'other.yi2a',
          bytes: Uint8List.fromList(
            utf8.encode(
              jsonEncode({
                'books': [
                  {'id': 8, 'name': '不同账本', 'cdate': 1710000000000},
                ],
              }),
            ),
          ),
        );
        await expectLater(
          service.applyMigrationPayload(
            commandId: 'cmd-idem-1',
            payload: otherPreview.payload,
          ),
          throwsA(
            isA<Failure>().having((f) => f.code, 'code', FailureCode.conflict),
          ),
        );
      },
    );
  });

  group(
    'LAN ServerBackup.zip (AE-2 "YYjz@23!" & custom password) and bare .db restore',
    () {
      test(
        'DR-IMP-09 & CE-IOS-03: auto-decrypts historical "YYjz@23!" AE-2 ZIP, prompts/validates custom password AE-2 ZIP, restores bare .db, preserves local note/currency, and cleans temp dir',
        () async {
          final tempRoot = await Directory.systemTemp.createTemp(
            'ti_lan_root_',
          );
          final buildDir = await Directory.systemTemp.createTemp(
            'ti_lan_build_',
          );
          final db = AppDatabase(NativeDatabase.memory());
          final scheduler = InMemoryReminderScheduler();
          addTearDown(() async {
            await scheduler.dispose();
            await db.close();
            if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
            if (await buildDir.exists()) await buildDir.delete(recursive: true);
          });

          // Seed local note & custom EUR currency in target DB (absent in Room v42 source .db)
          await db
              .into(db.notes)
              .insert(
                NotesCompanion.insert(
                  content: '局域网恢复需保留本地便签',
                  createTime: 1710000000000,
                  updateTime: 1710000000000,
                ),
              );
          await db
              .into(db.currencies)
              .insert(
                CurrenciesCompanion.insert(
                  code: 'EUR',
                  name: '欧元',
                  symbol: '€',
                  rateToAnchor: '7.85',
                  anchorCode: 'CNY',
                ),
              );

          final roomDbBytes = _buildRoomV42DatabaseBytes(buildDir);
          final service = CrossMigrationService(
            db,
            reminderScheduler: scheduler,
            tempRootDir: tempRoot,
          );

          // 1. Historical `"YYjz@23!"` AE-2 ZIP with nested `Server/yiyujizhang.db` + `MMKV/`
          final historicalZip = buildLanZipArchive([
            LanZipInputEntry(
              name: 'MMKV/mmkv.default',
              bytes: Uint8List.fromList([1, 2, 3, 4]),
            ),
            LanZipInputEntry(name: 'Server/yiyujizhang.db', bytes: roomDbBytes),
          ], password: historicalLanZipPassword);

          final histOutcome = await service.inspectLanBackup(
            fileName: 'ServerBackup.zip',
            bytes: historicalZip,
          );
          expect(histOutcome, isA<LanInspectReady>());
          final histPreview = (histOutcome as LanInspectReady).preview;
          expect(histPreview.usedHistoricalPassword, isTrue);
          expect(histPreview.entryName, 'Server/yiyujizhang.db');
          expect(
            histPreview.bookCount,
            1,
          ); // deduplicated id=1 & filtered sstatus=4
          expect(histPreview.assetCount, 1); // filtered sstatus=4
          expect(histPreview.recordCount, 1); // filtered sstatus=4
          expect(tempRoot.listSync(), isEmpty); // temp dir cleaned!

          // Apply restore
          final applied = await service.applyMigrationPayload(
            commandId: 'cmd-lan-hist-1',
            payload: histPreview.payload,
          );
          expect(applied.activeBookId, 1);

          final restoredBook = await db.select(db.accountBooks).getSingle();
          expect(restoredBook.name, '局域网家庭账本');
          expect(restoredBook.startDay, 10);

          final restoredAsset = await db.select(db.assets).getSingle();
          expect(restoredAsset.balanceMinor, BigInt.from(876543));
          expect(restoredAsset.creditInfo, contains('"50025"'));

          final restoredRec = await db.select(db.records).getSingle();
          expect(restoredRec.recordId, 'lan-rec-1');
          expect(restoredRec.moneyMinor, BigInt.from(12865));
          expect(restoredRec.discountMinor, BigInt.from(535));
          expect(restoredRec.extraInfo, contains('"12865"'));

          // Local note & EUR currency preserved because source .db had none!
          expect(await db.select(db.notes).get(), hasLength(1));
          final eur = await (db.select(
            db.currencies,
          )..where((t) => t.code.equals('EUR'))).getSingleOrNull();
          expect(eur, isNotNull);
          expect(eur!.rateToAnchor, '7.85');

          // Reminder scheduler resynced
          expect(scheduler.scheduledList, hasLength(1));
          expect(scheduler.scheduledList.single.hour, 20);
          expect(scheduler.scheduledList.single.minute, 30);

          // 2. Custom-password AE-2 ZIP (`CE-IOS-03`)
          final customZip = buildLanZipArchive([
            LanZipInputEntry(name: 'yiyujizhang.db', bytes: roomDbBytes),
          ], password: 'UserSecret#888');

          final needPwd = await service.inspectLanBackup(
            fileName: 'ServerBackup.zip',
            bytes: customZip,
          );
          expect(needPwd, isA<LanInspectPasswordRequired>());

          final wrongPwd = await service.inspectLanBackup(
            fileName: 'ServerBackup.zip',
            bytes: customZip,
            password: 'BadPassword',
          );
          expect(wrongPwd, isA<LanInspectWrongPassword>());

          final unlocked = await service.inspectLanBackup(
            fileName: 'ServerBackup.zip',
            bytes: customZip,
            password: 'UserSecret#888',
          );
          expect(unlocked, isA<LanInspectReady>());
          expect(
            (unlocked as LanInspectReady).preview.usedHistoricalPassword,
            isFalse,
          );
          expect(tempRoot.listSync(), isEmpty);

          // 3. Bare `.db` direct inspection + corrupt `.db` temp cleanup
          final bareOk = await service.inspectLanBackup(
            fileName: 'yiyujizhang.db',
            bytes: roomDbBytes,
          );
          expect(bareOk, isA<LanInspectReady>());

          final fakeCorruptSqlite = Uint8List.fromList([
            ...sqlite3HeaderMagic,
            ...List<int>.filled(128, 0xff),
          ]);
          await expectLater(
            service.inspectLanBackup(
              fileName: 'corrupt.db',
              bytes: fakeCorruptSqlite,
            ),
            throwsA(isA<Failure>()),
          );
          expect(tempRoot.listSync(), isEmpty);
        },
      );
    },
  );
}
