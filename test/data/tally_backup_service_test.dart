import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/core/zip_archive.dart';
import 'package:tallyisle/data/backup/tally_backup_service.dart';
import 'package:tallyisle/data/backup/webdav_client.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/reminder/reminder_service.dart';
import 'package:tallyisle/data/repo/ledger_queries.dart';
import 'package:tallyisle/domain/rules/tally_backup.dart';
import 'package:tallyisle/platform/files.dart';
import 'package:tallyisle/platform/notifications.dart';

/// Real loopback HTTP/WebDAV server for end-to-end WebDAV protocol verification.
final class _LoopbackWebDavServer {
  _LoopbackWebDavServer._(this._server);

  final HttpServer _server;
  final Map<String, Uint8List> files = <String, Uint8List>{};
  final Map<String, DateTime> modifiedTimes = <String, DateTime>{};
  final Set<String> collections = <String>{'/dav'};
  final List<String> requestLog = <String>[];
  int _clockTick = 0;

  String expectedUser = 'tally_user';
  String expectedPass = 'secret_token_123';
  bool rejectMoveWith405 = false;
  int? overrideHeadContentLength;

  String get baseUrl => 'http://127.0.0.1:${_server.port}/dav';

  static Future<_LoopbackWebDavServer> start() async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final dav = _LoopbackWebDavServer._(http);
    http.listen(dav._handleRequest);
    return dav;
  }

  Future<void> close() => _server.close(force: true);

  bool _checkBasicAuth(HttpRequest req) {
    final header = req.headers.value(HttpHeaders.authorizationHeader);
    if (header == null || !header.startsWith('Basic ')) return false;
    final expected = base64Encode(utf8.encode('$expectedUser:$expectedPass'));
    return header.substring('Basic '.length).trim() == expected;
  }

  static String _normPath(String rawPath) {
    final decoded = Uri.decodeFull(rawPath);
    if (decoded.length > 1 && decoded.endsWith('/')) {
      return decoded.substring(0, decoded.length - 1);
    }
    return decoded;
  }

  Future<void> _handleRequest(HttpRequest req) async {
    final path = _normPath(req.uri.path);
    requestLog.add('${req.method} $path');

    if (!_checkBasicAuth(req)) {
      req.response.statusCode = HttpStatus.unauthorized;
      req.response.headers.set(
        HttpHeaders.wwwAuthenticateHeader,
        'Basic realm="TallyIsleTest"',
      );
      await req.drain<void>();
      await req.response.close();
      return;
    }

    switch (req.method) {
      case 'MKCOL':
        await req.drain<void>();
        final parent = p.posix.dirname(path);
        if (!collections.contains(parent)) {
          req.response.statusCode = HttpStatus.conflict;
        } else if (collections.contains(path)) {
          req.response.statusCode = HttpStatus.methodNotAllowed;
        } else {
          collections.add(path);
          req.response.statusCode = HttpStatus.created;
        }
        await req.response.close();

      case 'PROPFIND':
        await req.drain<void>();
        final depth = req.headers.value('Depth') ?? '1';
        if (!collections.contains(path) && !files.containsKey(path)) {
          req.response.statusCode = HttpStatus.notFound;
          await req.response.close();
          return;
        }
        final buf = StringBuffer()
          ..write('<?xml version="1.0" encoding="utf-8"?>')
          ..write('<D:multistatus xmlns:D="DAV:">');
        if (collections.contains(path)) {
          buf.write(
            '<D:response>'
            '<D:href>${Uri.encodeFull('$path/')}</D:href>'
            '<D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>'
            '<D:status>HTTP/1.1 200 OK</D:status></D:propstat>'
            '</D:response>',
          );
          if (depth != '0') {
            final prefix = '$path/';
            for (final entry in files.entries) {
              if (!entry.key.startsWith(prefix)) continue;
              final rest = entry.key.substring(prefix.length);
              if (rest.contains('/')) continue;
              final modDate = HttpDate.format(
                modifiedTimes[entry.key] ?? DateTime.utc(2026, 11, 1, 0, 0, 0),
              );
              buf.write(
                '<D:response>'
                '<D:href>${Uri.encodeFull(entry.key)}</D:href>'
                '<D:propstat><D:prop>'
                '<D:displayname>$rest</D:displayname>'
                '<D:getcontentlength>${entry.value.length}</D:getcontentlength>'
                '<D:getlastmodified>$modDate</D:getlastmodified>'
                '<D:resourcetype/>'
                '</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>'
                '</D:response>',
              );
            }
          }
        }
        buf.write('</D:multistatus>');
        req.response.statusCode = 207;
        req.response.headers.contentType = ContentType('application', 'xml');
        req.response.write(buf.toString());
        await req.response.close();

      case 'PUT':
        final builder = BytesBuilder(copy: false);
        await for (final chunk in req) {
          builder.add(chunk);
        }
        final parent = p.posix.dirname(path);
        if (!collections.contains(parent)) {
          req.response.statusCode = HttpStatus.conflict;
        } else {
          final existed = files.containsKey(path);
          files[path] = builder.takeBytes();
          modifiedTimes[path] = DateTime.utc(2026, 11, 1, 0, 0, ++_clockTick);
          req.response.statusCode = existed
              ? HttpStatus.noContent
              : HttpStatus.created;
        }
        await req.response.close();

      case 'MOVE':
        await req.drain<void>();
        if (rejectMoveWith405) {
          req.response.statusCode = HttpStatus.methodNotAllowed;
          await req.response.close();
          return;
        }
        final destHeader = req.headers.value('Destination');
        if (destHeader == null || !files.containsKey(path)) {
          req.response.statusCode = HttpStatus.notFound;
          await req.response.close();
          return;
        }
        final destPath = _normPath(Uri.parse(destHeader).path);
        final existed = files.containsKey(destPath);
        files[destPath] = files.remove(path)!;
        modifiedTimes[destPath] =
            modifiedTimes.remove(path) ??
            DateTime.utc(2026, 11, 1, 0, 0, ++_clockTick);
        req.response.statusCode = existed
            ? HttpStatus.noContent
            : HttpStatus.created;
        await req.response.close();

      case 'HEAD':
        await req.drain<void>();
        final content = files[path];
        if (content == null) {
          req.response.statusCode = HttpStatus.notFound;
        } else {
          req.response.statusCode = HttpStatus.ok;
          req.response.headers.set(
            HttpHeaders.contentLengthHeader,
            '${overrideHeadContentLength ?? content.length}',
          );
        }
        await req.response.close();

      case 'GET':
        await req.drain<void>();
        final content = files[path];
        if (content == null) {
          req.response.statusCode = HttpStatus.notFound;
        } else {
          req.response.statusCode = HttpStatus.ok;
          req.response.contentLength = content.length;
          req.response.add(content);
        }
        await req.response.close();

      case 'DELETE':
        await req.drain<void>();
        modifiedTimes.remove(path);
        final removed = files.remove(path);
        req.response.statusCode = removed == null
            ? HttpStatus.notFound
            : HttpStatus.noContent;
        await req.response.close();

      default:
        await req.drain<void>();
        req.response.statusCode = HttpStatus.methodNotAllowed;
        await req.response.close();
    }
  }
}

Future<void> _seedAll22Tables(AppDatabase db) async {
  // account_book (book 1 is already seeded by onCreate; add book 2)
  await db
      .into(db.accountBooks)
      .insert(
        AccountBooksCompanion.insert(
          id: const Value(2),
          name: '旅行账本',
          startDay: const Value(5),
          createDate: 1700000000000,
        ),
      );

  // currency (CNY seeded; add 2 foreign currencies per golden vector §4)
  await db
      .into(db.currencies)
      .insert(
        CurrenciesCompanion.insert(
          code: 'USD',
          name: '美元',
          symbol: r'$',
          rateToAnchor: '7.2345',
          anchorCode: 'CNY',
        ),
      );
  await db
      .into(db.currencies)
      .insert(
        CurrenciesCompanion.insert(
          code: 'JPY',
          name: '日元',
          symbol: '¥',
          rateToAnchor: '0.0485',
          anchorCode: 'CNY',
        ),
      );

  // asset
  await db
      .into(db.assets)
      .insert(
        AssetsCompanion.insert(
          id: const Value(10),
          name: '招商储蓄卡',
          balanceMinor: BigInt.parse(
            '9007199254740999',
          ), // > JS MAX_SAFE_INTEGER!
          type: 0,
          createDate: 1700000000000,
          initMoneyMinor: BigInt.from(500000),
        ),
      );

  // asset_book
  await db
      .into(db.assetBooks)
      .insert(AssetBooksCompanion.insert(assetId: 10, bookId: 1));

  // bank_card
  await db
      .into(db.bankCards)
      .insert(
        BankCardsCompanion.insert(
          id: const Value(1),
          cardType: 0,
          cardName: '招商银行',
          cardNo: '622588001234',
          cardOwner: '张三',
          createDate: 1700000000000,
          cardAssetId: const Value(10),
        ),
      );

  // budget
  await db
      .into(db.budgets)
      .insert(
        BudgetsCompanion.insert(
          id: const Value(1),
          budgetType: 0,
          recordCatId: -1,
          amountMinor: BigInt.from(300000),
          bookId: 1,
          section: '2026-11',
          createDate: 1700000000000,
        ),
      );

  // import_platform
  await db
      .into(db.importPlatforms)
      .insert(
        ImportPlatformsCompanion.insert(
          id: const Value(1),
          platform: 'WeChat',
          importRecordCount: 5,
          importCategoryCount: 2,
          importTime: 1700000000000,
        ),
      );

  // record (100.50 yuan -> 10050 minor units per golden vector §4)
  await db
      .into(db.records)
      .insert(
        RecordsCompanion.insert(
          recordId: 'rec_10050',
          type: 0,
          moneyMinor: BigInt.from(10050),
          remark: const Value('午餐便当'),
          recordTime: 1700000100000,
          recordCatId: const Value(1),
          assetId: const Value(10),
          accountBookId: 1,
          images: const Value('7a8b9c0d1e2f.jpg'),
          discountMinor: Value(BigInt.from(250)),
        ),
      );

  // tag & tag_record
  await db
      .into(db.tags)
      .insert(TagsCompanion.insert(tagId: 'tag_work', name: '工作餐'));
  await db
      .into(db.tagRecords)
      .insert(
        TagRecordsCompanion.insert(tagId: 'tag_work', recordId: 'rec_10050'),
      );

  // remark
  await db
      .into(db.remarks)
      .insert(
        RemarksCompanion.insert(
          id: const Value(1),
          content: '常点套餐',
          recordCatId: 1,
          usedTimes: const Value(3),
        ),
      );

  // record_template
  await db
      .into(db.recordTemplates)
      .insert(
        RecordTemplatesCompanion.insert(
          id: const Value(1),
          type: 0,
          remark: const Value('地铁通勤'),
          moneyMinor: BigInt.from(400),
          bookId: 1,
          createDate: 1700000000000,
        ),
      );

  // wish
  await db
      .into(db.wishes)
      .insert(
        WishesCompanion.insert(
          id: 'wish_1',
          content: '降噪耳机',
          valueMinor: BigInt.from(199900),
          createDate: 1700000000000,
        ),
      );

  // record_period
  await db
      .into(db.recordPeriods)
      .insert(
        RecordPeriodsCompanion.insert(
          id: const Value(1),
          recordType: 0,
          moneyMinor: BigInt.from(2500),
          bookId: 1,
          periodType: 2,
          periodTypeDate: '["1"]',
          periodStartDate: 1700000000000,
          periodEndDate: -1,
          createTime: 1700000000000,
        ),
      );

  // reminder_event
  await db
      .into(db.reminderEvents)
      .insert(
        ReminderEventsCompanion.insert(
          id: const Value(1),
          reminderTime: 20 * 60 + 30,
          reminderTip: const Value('晚上记一笔'),
        ),
      );

  // installment
  await db
      .into(db.installments)
      .insert(
        InstallmentsCompanion.insert(
          id: const Value(1),
          name: '笔记本分期',
          principalMinor: BigInt.from(600000),
          periods: 12,
          chargeMinor: BigInt.from(1200),
          chargeWay: 0,
          remainderIn: 0,
          calWay: 0,
          startDate: 1700000000000,
          assetId: 10,
          nextPeriod: 1,
          nextPeriodDate: 1702592000000,
          bookId: 1,
          createDate: 1700000000000,
        ),
      );

  // note (3 notes per golden vector §4)
  for (var i = 1; i <= 3; i++) {
    await db
        .into(db.notes)
        .insert(
          NotesCompanion.insert(
            id: Value(i),
            title: Value('便签标题 $i'),
            content: '便签正文内容 $i',
            createTime: 1700000000000 + i,
            updateTime: 1700000010000 + i,
          ),
        );
  }

  // money_save_plan & money_save_plan_record
  await db
      .into(db.moneySavePlans)
      .insert(
        MoneySavePlansCompanion.insert(
          id: const Value(1),
          name: '52周存钱',
          planType: 2,
          cycleType: 1,
          startDate: 1700000000000,
          endDate: 1731536000000,
          planMoneyMinor: BigInt.from(1378000),
          savedMoneyMinor: BigInt.from(1000),
          startMoneyMinor: BigInt.from(1000),
          incrementalMinor: BigInt.from(1000),
          createDate: 1700000000000,
          nextSaveDate: 1700604800000,
        ),
      );
  await db
      .into(db.moneySavePlanRecords)
      .insert(
        MoneySavePlanRecordsCompanion.insert(
          id: const Value(1),
          planId: 1,
          recordDate: 1700000000000,
          recordMoneyMinor: BigInt.from(1000),
        ),
      );

  // stat_story
  await db
      .into(db.statStories)
      .insert(
        StatStoriesCompanion.insert(
          id: 'story_2026',
          story: '年度账单故事',
          bookId: 1,
          sdate: 1700000000000,
          edate: 1730000000000,
        ),
      );

  // auto_map
  await db
      .into(db.autoMaps)
      .insert(
        AutoMapsCompanion.insert(
          id: const Value(1),
          key: '星巴克',
          mapInfo: const Value('{"catId":1}'),
        ),
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() {
    HttpOverrides.global = null;
  });

  group('TallyBackupService 22-table round-trip & 3-stage atomic restore', () {
    test(
      'exports all 22 tables + attachments and restores atomically with reminder resync',
      () async {
        final tempRoot = await Directory.systemTemp.createTemp(
          'tally_bk_test_',
        );
        addTearDown(() async {
          if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
        });

        var now = 1793952000000;
        final sourceDb = AppDatabase(NativeDatabase.memory(), nowMs: () => now);
        addTearDown(sourceDb.close);

        final targetDb = AppDatabase(NativeDatabase.memory(), nowMs: () => now);
        addTearDown(targetDb.close);

        await _seedAll22Tables(sourceDb);

        final srcAttDir = Directory(p.join(tempRoot.path, 'src_att'));
        await srcAttDir.create(recursive: true);
        final jpgBytes = Uint8List.fromList(<int>[
          0xFF,
          0xD8,
          0xFF,
          10,
          20,
          30,
        ]);
        final pngBytes = Uint8List.fromList(<int>[
          0x89,
          0x50,
          0x4E,
          0x47,
          40,
          50,
        ]);
        await File(
          p.join(srcAttDir.path, '7a8b9c0d1e2f.jpg'),
        ).writeAsBytes(jpgBytes);
        await File(p.join(srcAttDir.path, 'nested', 'e3f1a2b4c5d6.png'))
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(pngBytes);

        final srcScheduler = InMemoryReminderScheduler();
        final srcService = TallyBackupService(
          sourceDb,
          reminderService: ReminderService(sourceDb, scheduler: srcScheduler),
          localBackupsDirectoryProvider: () async =>
              Directory(p.join(tempRoot.path, 'local_bk')),
          attachmentsDirectoryProvider: () async => srcAttDir,
        );

        final createdMeta = await srcService.createLocalBackup();
        expect(createdMeta.manifest, isNotNull);
        expect(createdMeta.manifest!.noteCount, 3);
        expect(createdMeta.manifest!.currencyCount, 3); // CNY + USD + JPY
        expect(createdMeta.manifest!.attachmentCount, 2);

        // Verify exported JSON strips uid/sync_time/sstatus and preserves int64
        final archiveBytes = await srcService.localTarget.readBackup(
          createdMeta.fileName,
        );
        final zip = ZipArchive.decode(archiveBytes);
        final dbJsonText = utf8.decode(zip['database.json']!.bytes);
        expect(dbJsonText, isNot(contains('"uid"')));
        expect(dbJsonText, isNot(contains('"sync_time"')));
        expect(dbJsonText, isNot(contains('"sstatus"')));
        expect(dbJsonText, contains('"money_minor":10050'));
        expect(dbJsonText, contains('"9007199254740999"'));

        // Put stale current_book_id=999 and stale attachment in target before restore
        await LedgerQueries(targetDb).setCurrentBook(999);
        final dstAttDir = Directory(p.join(tempRoot.path, 'dst_att'));
        await dstAttDir.create(recursive: true);
        await File(
          p.join(dstAttDir.path, 'stale_old.jpg'),
        ).writeAsBytes(<int>[1]);

        final dstScheduler = InMemoryReminderScheduler();
        final dstService = TallyBackupService(
          targetDb,
          reminderService: ReminderService(targetDb, scheduler: dstScheduler),
          localBackupsDirectoryProvider: () async =>
              Directory(p.join(tempRoot.path, 'local_bk')),
          attachmentsDirectoryProvider: () async => dstAttDir,
        );

        final restoredManifest = await dstService.restoreLocalBackup(
          createdMeta.fileName,
        );
        expect(restoredManifest.totalRows, createdMeta.manifest!.totalRows);

        // Verify all key business tables & BigInt precision
        final notes = await targetDb.select(targetDb.notes).get();
        expect(notes, hasLength(3));
        final currencies = await targetDb.select(targetDb.currencies).get();
        expect(currencies.map((c) => c.code).toSet(), <String>{
          'CNY',
          'USD',
          'JPY',
        });

        final rec = await (targetDb.select(
          targetDb.records,
        )..where((r) => r.recordId.equals('rec_10050'))).getSingle();
        expect(rec.moneyMinor, BigInt.from(10050));
        expect(rec.discountMinor, BigInt.from(250));

        final asset = await (targetDb.select(
          targetDb.assets,
        )..where((a) => a.id.equals(10))).getSingle();
        expect(asset.balanceMinor, BigInt.parse('9007199254740999'));

        expect(await targetDb.select(targetDb.bankCards).get(), hasLength(1));
        expect(await targetDb.select(targetDb.budgets).get(), hasLength(1));
        expect(
          await targetDb.select(targetDb.importPlatforms).get(),
          hasLength(1),
        );
        expect(await targetDb.select(targetDb.tags).get(), hasLength(1));
        expect(await targetDb.select(targetDb.tagRecords).get(), hasLength(1));
        expect(await targetDb.select(targetDb.remarks).get(), hasLength(1));
        expect(
          await targetDb.select(targetDb.recordTemplates).get(),
          hasLength(1),
        );
        expect(await targetDb.select(targetDb.wishes).get(), hasLength(1));
        expect(
          await targetDb.select(targetDb.recordPeriods).get(),
          hasLength(1),
        );
        expect(
          await targetDb.select(targetDb.installments).get(),
          hasLength(1),
        );
        expect(
          await targetDb.select(targetDb.moneySavePlans).get(),
          hasLength(1),
        );
        expect(
          await targetDb.select(targetDb.moneySavePlanRecords).get(),
          hasLength(1),
        );
        expect(await targetDb.select(targetDb.assetBooks).get(), hasLength(1));
        expect(await targetDb.select(targetDb.statStories).get(), hasLength(1));
        expect(await targetDb.select(targetDb.autoMaps).get(), hasLength(1));

        // Verify current_book_id reset to valid book 1
        final activeBookId = await LedgerQueries(
          targetDb,
        ).watchCurrentBookId().first;
        expect(activeBookId, 1);

        // Verify attachments replaced cleanly
        expect(
          await File(p.join(dstAttDir.path, 'stale_old.jpg')).exists(),
          isFalse,
        );
        expect(
          await File(p.join(dstAttDir.path, '7a8b9c0d1e2f.jpg')).readAsBytes(),
          jpgBytes,
        );
        expect(
          await File(
            p.join(dstAttDir.path, 'nested', 'e3f1a2b4c5d6.png'),
          ).readAsBytes(),
          pngBytes,
        );

        // Verify ReminderService.resyncAll() ran
        expect(dstScheduler.scheduledList, hasLength(1));
        expect(dstScheduler.scheduledList.single.hour, 20);
        expect(dstScheduler.scheduledList.single.minute, 30);
      },
    );

    test(
      'resets current_book_id to first book when book 1 is absent in backup',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);

        await LedgerQueries(db).setCurrentBook(1);
        final service = TallyBackupService(
          db,
          reminderService: ReminderService(
            db,
            scheduler: InMemoryReminderScheduler(),
          ),
        );

        final customArchive = packTallyArchive(
          tables: <String, List<Map<String, Object?>>>{
            'account_book': <Map<String, Object?>>[
              <String, Object?>{
                'id': 42,
                'name': '专属账本',
                'sort': 1,
                'create_date': 1700000000000,
              },
            ],
          },
          createdAtMs: 1793952000000,
        );

        await service.restoreFromBytes(customArchive.bytes);
        expect(await LedgerQueries(db).watchCurrentBookId().first, 42);
      },
    );

    test(
      'tampered database/attachment OR mid-transaction failure leaves DB & attachments 100% untouched (R5)',
      () async {
        final tempRoot = await Directory.systemTemp.createTemp(
          'tally_rollback_',
        );
        addTearDown(() async {
          if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
        });

        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);

        // Seed sentinel note & attachment that MUST survive failed restores
        await db
            .into(db.notes)
            .insert(
              NotesCompanion.insert(
                id: const Value(77),
                title: const Value('原始便签'),
                content: '绝不能丢失的数据',
                createTime: 100,
                updateTime: 100,
              ),
            );
        final attDir = Directory(p.join(tempRoot.path, 'att'))
          ..createSync(recursive: true);
        final sentinelFile = File(p.join(attDir.path, 'keep_me.jpg'))
          ..writeAsBytesSync(<int>[9, 9, 9]);

        final service = TallyBackupService(
          db,
          reminderService: ReminderService(
            db,
            scheduler: InMemoryReminderScheduler(),
          ),
          attachmentsDirectoryProvider: () async => attDir,
        );

        final validBackup = packTallyArchive(
          tables: <String, List<Map<String, Object?>>>{
            'account_book': <Map<String, Object?>>[
              <String, Object?>{'id': 1, 'name': '新账本', 'create_date': 1000},
            ],
          },
          attachments: <String, Uint8List>{
            'new_pic.jpg': Uint8List.fromList(<int>[1, 2, 3]),
          },
          createdAtMs: 1793952000000,
        );
        final origZip = ZipArchive.decode(validBackup.bytes);

        // 1. Tamper database.json
        final badDbZip = ZipArchive.encode(<ZipEntry>[
          origZip['manifest.json']!,
          ZipEntry(
            name: 'database.json',
            bytes: utf8.encode(
              utf8
                  .decode(origZip['database.json']!.bytes)
                  .replaceFirst('新账本', '篡改本'),
            ),
          ),
          origZip['attachments/new_pic.jpg']!,
        ]);
        await expectLater(
          service.restoreFromBytes(badDbZip),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.corruptData,
            ),
          ),
        );

        // 2. Tamper attachment bytes
        final badAttZip = ZipArchive.encode(<ZipEntry>[
          origZip['manifest.json']!,
          origZip['database.json']!,
          ZipEntry(
            name: 'attachments/new_pic.jpg',
            bytes: Uint8List.fromList(<int>[1, 2, 99]),
          ),
        ]);
        await expectLater(
          service.restoreFromBytes(badAttZip),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.corruptData,
            ),
          ),
        );

        // 3. Simulate exception inside Stage-3 SQLite transaction AFTER tables were cleared
        await expectLater(
          service.restoreFromBytes(
            validBackup.bytes,
            beforeTransactionCommitForTest: () {
              throw const Failure(FailureCode.storageFull, '模拟磁盘满导致事务中断');
            },
          ),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.storageFull,
            ),
          ),
        );

        // Verify sentinel note and sentinel attachment survived all 3 failures untouched!
        final survivingNotes = await db.select(db.notes).get();
        expect(survivingNotes, hasLength(1));
        expect(survivingNotes.single.content, '绝不能丢失的数据');
        expect(await sentinelFile.readAsBytes(), <int>[9, 9, 9]);
        expect(
          await File(p.join(attDir.path, 'new_pic.jpg')).exists(),
          isFalse,
        );
      },
    );
  });

  group('WebDAV end-to-end against real loopback HttpServer (R4, R6, R7, ADR-017)', () {
    test('unconfigured WebDavConfig reports 未配置 capability', () {
      const cfg = WebDavConfig.unconfigured();
      expect(cfg.isConfigured, isFalse);
      expect(cfg.capability.state, CapabilityState.unconfigured);
      expect(cfg.capability.reason, '未配置');
    });

    test(
      'Basic Auth, MKCOL, two-phase .tmp -> MOVE, 405 fallback, pruning & R7 auto-backup',
      () async {
        final server = await _LoopbackWebDavServer.start();
        addTearDown(server.close);

        var now = 1793952000000;
        final db = AppDatabase(NativeDatabase.memory(), nowMs: () => now);
        addTearDown(db.close);

        final service = TallyBackupService(
          db,
          reminderService: ReminderService(
            db,
            scheduler: InMemoryReminderScheduler(),
          ),
        );

        // 1. Wrong password fails with authRequired and never leaks password
        final badCfg = WebDavConfig(
          serverUrl: server.baseUrl,
          username: server.expectedUser,
          password: 'wrong_secret_value',
          remoteDirectory: '/TallyIsle/backups',
        );
        await expectLater(
          service.testWebDavConnection(badCfg),
          throwsA(
            isA<Failure>()
                .having((f) => f.code, 'code', FailureCode.authRequired)
                .having(
                  (f) => f.message.contains('wrong_secret_value'),
                  'leaksPassword',
                  isFalse,
                ),
          ),
        );

        // 2. Valid configuration & testConnection (creates nested MKCOL + write probe)
        final validCfg = WebDavConfig(
          serverUrl: server.baseUrl,
          username: server.expectedUser,
          password: server.expectedPass,
          remoteDirectory: '/TallyIsle/backups',
          keepCount: 3,
          autoBackupEnabled: true,
        );
        await service.testWebDavConnection(validCfg);
        await service.saveWebDavConfig(validCfg);
        expect(server.collections, contains('/dav/TallyIsle/backups'));

        // 3. Golden Vector (§4): upload `YiYu_20261106.tally` uses PUT .tally.tmp -> MOVE
        server.requestLog.clear();
        final progressEvents = <(int, int)>[];
        final uploaded = await service.uploadBackupToWebDav(
          customFileName: 'YiYu_20261106.tally',
          onProgress: (sent, total) => progressEvents.add((sent, total)),
        );
        expect(uploaded.fileName, 'YiYu_20261106.tally');
        expect(progressEvents, isNotEmpty);
        expect(progressEvents.last.$1, progressEvents.last.$2);
        expect(
          server.requestLog,
          containsAllInOrder(<String>[
            'PUT /dav/TallyIsle/backups/YiYu_20261106.tally.tmp',
            'MOVE /dav/TallyIsle/backups/YiYu_20261106.tally.tmp',
          ]),
        );
        expect(
          server.files.containsKey(
            '/dav/TallyIsle/backups/YiYu_20261106.tally.tmp',
          ),
          isFalse,
        );
        expect(
          server.files.containsKey(
            '/dav/TallyIsle/backups/YiYu_20261106.tally',
          ),
          isTrue,
        );

        // 4. Fallback when server returns 405 on MOVE -> direct PUT + HEAD Content-Length check
        server.rejectMoveWith405 = true;
        server.requestLog.clear();
        await service.uploadBackupToWebDav(customFileName: 'Fallback_01.tally');
        expect(
          server.requestLog,
          containsAllInOrder(<String>[
            'PUT /dav/TallyIsle/backups/Fallback_01.tally.tmp',
            'MOVE /dav/TallyIsle/backups/Fallback_01.tally.tmp',
            'DELETE /dav/TallyIsle/backups/Fallback_01.tally.tmp',
            'PUT /dav/TallyIsle/backups/Fallback_01.tally',
            'HEAD /dav/TallyIsle/backups/Fallback_01.tally',
          ]),
        );

        // If HEAD Content-Length mismatches, upload fails with remoteUnavailable
        server.overrideHeadContentLength = 7;
        await expectLater(
          service.uploadBackupToWebDav(customFileName: 'Corrupt_Len.tally'),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.remoteUnavailable,
            ),
          ),
        );
        server.overrideHeadContentLength = null;
        server.rejectMoveWith405 = false;
        await service.deleteWebDavBackup('Corrupt_Len.tally');

        // 5. Retention pruning (keepCount = 3): upload 4 timestamped backups -> oldest pruned
        for (final name in <String>[
          'backup_20261101_120000.tally',
          'backup_20261102_120000.tally',
          'backup_20261103_120000.tally',
          'backup_20261104_120000.tally',
        ]) {
          await service.uploadBackupToWebDav(customFileName: name);
        }
        final listed = await service.listWebDavBackups();
        expect(listed.map((e) => e.fileName).toList(), <String>[
          'backup_20261104_120000.tally',
          'backup_20261103_120000.tally',
          'backup_20261102_120000.tally',
        ]);

        // 6. R7 Silent Auto-Backup:
        // Immediately after backup -> throttled (elapsed < 24h)
        expect(await service.runSilentAutoBackupIfNeeded(), isNull);

        // Advance 25 hours WITHOUT local data mutation -> skipped (localDataChanged == false)
        now += 25 * 60 * 60 * 1000;
        expect(await service.hasLocalDataChanged(), isFalse);
        expect(await service.runSilentAutoBackupIfNeeded(), isNull);

        // Mutate local DB (insert a Note) -> localDataChanged == true & >= 24h -> auto-uploads!
        await db
            .into(db.notes)
            .insert(
              NotesCompanion.insert(
                title: const Value('新增便签'),
                content: '触发静默备份',
                createTime: now,
                updateTime: now,
              ),
            );
        expect(await service.hasLocalDataChanged(), isTrue);
        final autoUploaded = await service.runSilentAutoBackupIfNeeded();
        expect(autoUploaded, isNotNull);

        // 7. Download & restore from WebDAV after wiping local notes
        await db.delete(db.notes).go();
        expect(await db.select(db.notes).get(), isEmpty);

        await service.restoreWebDavBackup(autoUploaded!.fileName);
        final restoredNotes = await db.select(db.notes).get();
        expect(restoredNotes, hasLength(1));
        expect(restoredNotes.single.content, '触发静默备份');
      },
    );
  });

  group('Android FileAccess native MethodChannel bridge', () {
    test(
      'routes saveBytes and shareBytes over dev.tallyisle/files on Android and maps CANCELLED',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);

        const channel = MethodChannel(fileBridgeChannelName);
        final calls = <MethodCall>[];
        var cancelNextSave = false;

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              calls.add(call);
              if (call.method == 'saveBytes' && cancelNextSave) {
                throw PlatformException(code: 'CANCELLED', message: '已取消保存');
              }
              return null;
            });
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
        });

        const access = FileAccess(channel: channel);
        expect(access.saveLocationCapability.state, CapabilityState.available);
        expect(access.shareCapability.state, CapabilityState.available);

        final sample = Uint8List.fromList(<int>[1, 2, 3, 4]);
        await access.saveBytes('backup_test.tally', sample);
        await access.shareBytes('backup_test.tally', sample, subject: '帐屿备份分享');

        expect(calls.map((c) => c.method).toList(), <String>[
          'saveBytes',
          'shareBytes',
        ]);

        cancelNextSave = true;
        await expectLater(
          access.saveBytes('backup_cancel.tally', sample),
          throwsA(
            isA<Failure>().having((f) => f.code, 'code', FailureCode.cancelled),
          ),
        );
      },
    );
  });
}
