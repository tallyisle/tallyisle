import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/penny/penny_import_service.dart';
import 'package:tallyisle/data/reminder/reminder_service.dart';
import 'package:tallyisle/data/repo/ledger_queries.dart';
import 'package:tallyisle/domain/ledger/asset_json.dart';
import 'package:tallyisle/domain/ledger/record_extra.dart';
import 'package:tallyisle/domain/ledger/record_relations.dart';
import 'package:tallyisle/domain/rules/debt_rules.dart';
import 'package:tallyisle/domain/rules/fixed_deposit.dart';
import 'package:tallyisle/domain/rules/penny_backup.dart';
import 'package:tallyisle/platform/notifications.dart';

Map<String, Object?> _buildFull20TablePayload() => <String, Object?>{
  'books': [
    {
      '_id': 1,
      'id': 1,
      'type': 1,
      'name': '原版日常账本',
      'cover': 'cover_1',
      'sort': 1,
      'status': 0,
      'dstart': 1,
      'cdate': 1700000000000,
      'dway': 0,
      'uid': 'u100',
      'sstime': 1700000001000,
      'sstatus': 2,
    },
    {
      '_id': 2,
      'id': 2,
      'type': 1,
      'name': '旅行账本',
      'sort': 2,
      'dstart': 10,
      'cdate': 1700000002000,
      'sstatus': 0,
    },
    {'_id': 3, 'id': 9, 'name': '墓碑账本', 'cdate': 1700000003000, 'sstatus': 4},
  ],
  'categories': [
    {
      'id': 101,
      'name': '餐饮美食',
      'icon': 'cat_food',
      'type': 0,
      'sort': 0,
      'parent': -1,
      'book': 1,
      'hide': false,
      'sstatus': 0,
    },
    {
      'id': 102,
      'name': '薪资收入',
      'icon': 'cat_salary',
      'type': 1,
      'sort': 1,
      'parent': -1,
      'book': 1,
      'hide': false,
      'sstatus': 2,
    },
    {'id': 103, 'name': '已删分类', 'type': 0, 'book': 1, 'sstatus': 4},
  ],
  'assets': [
    {
      'id': 10,
      'name': '招商储蓄卡',
      'bal': 5678.90,
      'type': 1,
      'subt': -1,
      'cdate': 1700000010000,
      'sort': 0,
      'icon': 'bank_cmb',
      'initm': 1000.00,
      'default': true,
      'effect': true,
      'usetime': 12,
      'status': 0,
      'extra':
          '{"temp_amt":[{"m":2000.5,"ddl":1800000000000,"upd":1700000000000}]}',
      'fixeddeposit':
          '[{"money":3000.25,"from_asset_id":10,"update_asset_balance":false,"annual_rate":0.0225,"period_unit":2,"period_count":1,"deposit_date":1700000000000,"due_date":1731536000000,"expected_income":67.51,"c":"CNY","ac":"CNY","am":3000.25,"bc":"CNY","bm":3000.25,"remark":"一年定存","status":0}]',
      'currency': 'CNY',
      'sstatus': 0,
    },
    {
      'id': 20,
      'name': '招行信用卡',
      'bal': -333.33,
      'type': 6,
      'subt': -1,
      'cdate': 1700000020000,
      'sort': 1,
      'initm': 20000,
      'effect': true,
      'credit':
          '{"bill_day":15,"repayment_day":5,"inst":[{"iid":"501-2","b":333.33,"i":6.67,"cb":true,"ci":false}],"installment":340.0}',
      'sstatus': 0,
    },
    {
      'id': 30,
      'name': '朋友借款',
      'bal': 800.50,
      'type': 4,
      'subt': 41,
      'cdate': 1700000030000,
      'initm': 0,
      'effect': false,
      'loan': '{"startDate":1700000030000,"endDate":-1,"totalDebtMoney":800.5}',
      'sstatus': 0,
    },
    {
      'id': 99,
      'name': '已删账户',
      'bal': 100,
      'type': 1,
      'cdate': 1700000030000,
      'initm': 0,
      'sstatus': 4,
    },
  ],
  'records': [
    {
      'id': 'rec-1001',
      'type': 0,
      'subt': -1,
      'money': 1234.56,
      'discount': 12.345,
      'remark': '聚餐消费',
      'time': 1700010000000,
      'cat': 101,
      'asset': 10,
      'book': 1,
      'exbud': false,
      'exexin': false,
      'img': [
        {'fname': 'bill_a.jpg'},
        {'fname': 'bill_b.jpg'},
      ],
      'extra':
          '{"curr":{"sc":"USD","sm":170,"ac":"CNY","am":1234.56,"bc":"CNY","bm":1234.56}}',
      'rel': '{"lrefundi":{"rfbinfo":[{"lbid":"rec-1002","lbm":50.25}]}}',
      'cdt': 1700010000100,
      'uid': 'u100',
      'sstatus': 2,
    },
    null,
    {
      'id': 'rec-tombstone',
      'type': 0,
      'money': 999.99,
      'time': 1700010005000,
      'book': 1,
      'sstatus': 4,
    },
  ],
  'budgets': [
    {
      'id': 301,
      'type': 0,
      'cat': -1,
      'amount': 5000.50,
      'book': 1,
      'sect': '2026-11',
      'sort': 0,
      'cdate': 1700000000000,
      'extra_info': '{"acopy":true,"forward":false,"base":5000.5}',
      'sstatus': 0,
    },
  ],
  'importPlatforms': [
    {
      'id': 401,
      'plat': 'WeChat',
      'recordc': 28,
      'catc': 4,
      'time': 1700005000000,
      'hidden': false,
      'sstatus': 0,
    },
  ],
  'installments': [
    {
      'id': 501,
      'name': '笔记本分期',
      'cat': 101,
      'prin': 6000.00,
      'periods': 6,
      'charge': 120.00,
      'chargeway': 1,
      'remin': 0,
      'calway': 2,
      'sdate': 1700000000000,
      'asset': 20,
      'np': 2,
      'npdate': 1702592000000,
      'credited': [1],
      'book': 1,
      'cdate': 1700000000000,
      'tags': ['tag-digital'],
      'img': [
        {'fname': 'inst_a.jpg'},
        {'fname': 'inst_b.jpg'},
      ],
      'sstatus': 0,
    },
  ],
  'periods': [
    null,
    {
      'id': 601,
      'type': 0,
      'money': 35.00,
      'fee': 0,
      'remark': '月度视频会员',
      'cat': 101,
      'asset': 10,
      'asset2': -1,
      'book': 1,
      'state': 0,
      'ptype': 2,
      'ptypedate': ['15'],
      'startdate': 1700000000000,
      'enddate': -1,
      'freq': 1,
      'lastadd': -1,
      'addtimes': 0,
      'ctime': 1700000000000,
      'tags': ['tag-digital'],
      'img': [
        {'fname': 'period_a.jpg'},
        {'fname': 'period_b.jpg'},
      ],
      'sstatus': 0,
    },
  ],
  'reminders': [
    {
      'id': 701,
      'time': 1230, // 20:30
      'tip': '记得记晚饭账单',
      'sstatus': 0,
    },
    {'id': 702, 'time': 540, 'tip': '已删提醒', 'sstatus': 4},
  ],
  'tags': [
    {
      'id': 'tag-group',
      'name': '数码消费组',
      'sort': 0,
      'hidden': false,
      'isparent': true,
      'sstatus': 0,
    },
    {
      'id': 'tag-digital',
      'name': '电子产品',
      'sort': 1,
      'hidden': false,
      'parent': 'tag-group',
      'isparent': false,
      'sstatus': 0,
    },
  ],
  'tagRefs': [
    {'tid': 'tag-digital', 'rid': 'rec-1001', 'sstatus': 0},
  ],
  'templates': [
    {
      'id': 801,
      'type': 0,
      'remark': '地铁通勤',
      'money': 4.00,
      'fee': 0,
      'cat': 101,
      'asset': 10,
      'asset2': -1,
      'sort': 0,
      'autosave': true,
      'book': 1,
      'cdate': 1700000000000,
      'sstatus': 0,
    },
  ],
  'bankCards': [
    {
      'id': 901,
      'type': 0,
      'name': '招商银行',
      'no': '622588001234',
      'owner': '张三',
      'remark': '工资卡',
      'sort': 0,
      'cdate': 1700000000000,
      'card_asset_id': 10,
      'sstatus': 0,
    },
  ],
  'wishes': [
    {
      'id': 'wish-1',
      'content': '新相机镜头',
      'value': 4599.90,
      'cdate': 1700000000000,
      'realized': false,
      'rdate': 0,
      'sort': 0,
      'tdate': 1750000000000,
      'sstatus': 0,
    },
  ],
  'remarks': [
    {
      'id': 1001,
      'content': '公司楼下咖啡',
      'record_cat_id': 101,
      'used_times': 9,
      'sstatus': 0,
    },
    {
      'id': 1002,
      'content': '软删备注',
      'record_cat_id': 101,
      'used_times': 1,
      'sstatus': 4,
    },
  ],
  'moneySavePlans': [
    {
      'id': 1101,
      'name': '年度旅行基金',
      'remark': '每月定存',
      'plan_type': 0,
      'cycle_type': 2,
      'start_date': 1700000000000,
      'end_date': 1731536000000,
      'plan_money': 12000.00,
      'saved_money': 2000.50,
      'auto_plan': false,
      'from_asset_id': 10,
      'to_asset_id': -1,
      'book_id': 1,
      'start_money': 1000.00,
      'incremental': 0,
      'status': 0,
      'create_date': 1700000000000,
      'sort': 0,
      'next_save_date': 1702592000000,
      'bbz_daily_times': 0,
      'extra_info': '{"curr":"CNY"}',
      'sstatus': 0,
    },
  ],
  'moneySavePlanRecords': [
    {
      'id': 1201,
      'plan_id': 1101,
      'remark': '首期存入',
      'from_asset_id': 10,
      'to_asset_id': -1,
      'record_date': 1700005000000,
      'record_money': 2000.50,
      'record_id': 'rec-1001',
      'sstatus': 0,
    },
  ],
  'assetBookRefs': [
    {'aid': 30, 'bid': 1, 'sstatus': 0},
  ],
  'statStory': [
    {
      'id': 'story-2026-10',
      'story': '{"headline":"十月支出平稳"}',
      'book_id': 1,
      'sdate': 1696118400000,
      'edate': 1698796799000,
      'dsection': '2026-10',
      'sstatus': 0,
    },
  ],
  'autoBillMaps': [
    {
      'id': 1301,
      'key': '美团外卖',
      'map_info': '{"catId":101,"assetId":10}',
      'draft': null,
      'sstatus': 0,
    },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late InMemoryReminderScheduler scheduler;
  late ReminderService reminderService;
  late PennyImportService service;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory(), nowMs: () => 1710000000000);
    scheduler = InMemoryReminderScheduler();
    reminderService = ReminderService(db, scheduler: scheduler);
    service = PennyImportService(db, reminderService: reminderService);
  });

  tearDown(() async {
    await scheduler.dispose();
    await db.close();
  });

  Future<void> seedLocalNotesCurrenciesAndOldRecord() async {
    // Seed 5 local notes (DR-BK-11 golden vector)
    for (var i = 1; i <= 5; i++) {
      await db
          .into(db.notes)
          .insert(
            NotesCompanion.insert(
              title: Value('便签标题 $i'),
              content: '本地重要便签内容 #$i',
              createTime: 1700000000000 + i,
              updateTime: 1700000000000 + i,
            ),
          );
    }

    // Seed custom foreign exchange rates (HR-01: must never be wiped!)
    await db
        .into(db.currencies)
        .insert(
          CurrenciesCompanion.insert(
            code: 'USD',
            name: '美元',
            symbol: r'$',
            rateToAnchor: '7.235',
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

    // Seed a pre-existing local record & non-default active book preference
    await db
        .into(db.records)
        .insert(
          RecordsCompanion.insert(
            recordId: 'local-old-1',
            type: 0,
            moneyMinor: BigInt.from(8800),
            recordTime: 1705000000000,
            accountBookId: 1,
          ),
        );
    await LedgerQueries(db).setCurrentBook(2);
  }

  group('PennyImportService (F-035)', () {
    test(
      'imports all 20 tables atomically, preserves 5 local notes & custom currencies (DR-BK-11), imports remarks (R6), resets currentBookId=1 (R7), and resyncs reminders',
      () async {
        await seedLocalNotesCurrenciesAndOldRecord();

        final pennyBytes = encodePennyForTest(_buildFull20TablePayload());

        // 1. Preview does not modify DB
        final preview = await service.previewPenny(
          fileName: '一羽记账_8.6.0_full.penny',
          bytes: pennyBytes,
        );
        expect(preview.appVersion, '8.6.0');
        expect(preview.bookCount, 2);
        expect(preview.assetCount, 3);
        expect(preview.recordCount, 1);
        expect(preview.remarkCount, 1);
        expect(preview.filteredTombstoneCount, 6);

        final beforeRecords = await db.select(db.records).get();
        expect(beforeRecords.map((r) => r.recordId), ['local-old-1']);

        // 2. Execute atomic restore
        final result = await service.importPenny(
          commandId: 'penny-import-cmd-1',
          fileName: '一羽记账_8.6.0_full.penny',
          bytes: pennyBytes,
        );
        expect(result.deduplicated, isFalse);
        expect(result.targetBookId, 1);

        // Verify HR-01 / DR-BK-11: 5 local notes and CNY/USD/JPY currencies 100% preserved!
        final notes = await db.select(db.notes).get();
        expect(notes.length, 5);
        expect(
          notes.map((n) => n.content).toList(),
          List<String>.generate(5, (i) => '本地重要便签内容 #${i + 1}'),
        );

        final currencies = await db.select(db.currencies).get();
        final byCode = {for (final c in currencies) c.code: c.rateToAnchor};
        expect(byCode['CNY'], '1');
        expect(byCode['USD'], '7.235');
        expect(byCode['JPY'], '0.0485');

        // Verify all 20 tables replaced & tombstones excluded
        final books = await db.select(db.accountBooks).get();
        expect(books.map((b) => b.id).toSet(), {1, 2});

        final cats = await db.select(db.recordCategories).get();
        expect(cats.map((c) => c.id).toSet(), {101, 102});

        final assets = await db.select(db.assets).get();
        expect(assets.map((a) => a.id).toSet(), {10, 20, 30});
        final cmb = assets.firstWhere((a) => a.id == 10);
        expect(cmb.balanceMinor, BigInt.from(567890));
        expect(cmb.initMoneyMinor, BigInt.from(100000));
        expect(
          AssetExtra.parse(cmb.extraInfo).tempAmounts.single.amount,
          BigInt.from(200050),
        );
        final fdItem = FixedDepositItem.fromJson(
          (jsonDecode(cmb.fixedDepositInfo!) as List).single,
        );
        expect(fdItem.moneyMinor, BigInt.from(300025));
        expect(fdItem.expectedIncomeMinor, BigInt.from(6751));

        final creditAsset = assets.firstWhere((a) => a.id == 20);
        expect(creditAsset.balanceMinor, BigInt.from(-33333));
        expect(
          CreditInfo.parse(
            creditAsset.creditInfo,
          ).installments!.single.principal,
          BigInt.from(33333),
        );

        final debtAsset = assets.firstWhere((a) => a.id == 30);
        expect(debtAsset.isEffectiveAsset, 0); // false -> 0
        expect(
          LoanInfo.parse(debtAsset.loanInfo).totalDebtMoneyMinor,
          BigInt.from(80050),
        );

        final records = await db.select(db.records).get();
        expect(records.length, 1);
        final rec = records.single;
        expect(rec.recordId, 'rec-1001');
        expect(rec.moneyMinor, BigInt.from(123456));
        expect(rec.discountMinor, BigInt.from(1235));
        expect(rec.images, 'bill_a.jpg,bill_b.jpg');
        expect(
          RecordExtra.parse(rec.extraInfo).currency!.sourceGross,
          BigInt.from(17000),
        );
        expect(
          RecordRelations.parse(rec.relInfo).refunds!.children.single.amount,
          BigInt.from(5025),
        );

        expect(
          (await db.select(db.budgets).get()).single.amountMinor,
          BigInt.from(500050),
        );
        expect(
          (await db.select(db.importPlatforms).get()).single.platform,
          'WeChat',
        );
        final instRow = (await db.select(db.installments).get()).single;
        expect(instRow.principalMinor, BigInt.from(600000));
        expect(instRow.images, 'inst_a.jpg,inst_b.jpg');

        final periodRow = (await db.select(db.recordPeriods).get()).single;
        expect(periodRow.moneyMinor, BigInt.from(3500));
        expect(periodRow.images, 'period_a.jpg,period_b.jpg');
        expect((await db.select(db.tags).get()).length, 2);
        expect((await db.select(db.tagRecords).get()).length, 1);
        expect(
          (await db.select(db.recordTemplates).get()).single.moneyMinor,
          BigInt.from(400),
        );
        expect(
          (await db.select(db.bankCards).get()).single.cardNo,
          '622588001234',
        );
        expect(
          (await db.select(db.wishes).get()).single.valueMinor,
          BigInt.from(459990),
        );
        expect((await db.select(db.remarks).get()).single.content, '公司楼下咖啡');
        expect(
          (await db.select(db.moneySavePlans).get()).single.savedMoneyMinor,
          BigInt.from(200050),
        );
        expect(
          (await db.select(db.moneySavePlanRecords).get())
              .single
              .recordMoneyMinor,
          BigInt.from(200050),
        );
        expect((await db.select(db.assetBooks).get()).length, 1);
        expect(
          (await db.select(db.statStories).get()).single.id,
          'story-2026-10',
        );
        expect((await db.select(db.autoMaps).get()).single.key, '美团外卖');

        // R7: current_book_id reset to 1
        final currentBookId = await LedgerQueries(
          db,
        ).watchCurrentBookId().first;
        expect(currentBookId, 1);

        // ReminderService.resyncAll() called with active reminder 20:30
        expect(scheduler.scheduledList.length, 1);
        expect(scheduler.scheduledList.single.hour, 20);
        expect(scheduler.scheduledList.single.minute, 30);
        expect(scheduler.scheduledList.single.title, '记得记晚饭账单');
        expect(scheduler.scheduledList.single.body, '每天 20:30 · 点击记一笔');
      },
    );

    test(
      '§6.2 selects smallest/first book ID when book id=1 is absent',
      () async {
        final bytes = encodePennyForTest({
          'books': [
            {'id': 7, 'name': '创业账本', 'sort': 2, 'cdate': 1700000000000},
            {'id': 3, 'name': '家庭账本', 'sort': 1, 'cdate': 1700000000000},
          ],
        });

        final res = await service.importPenny(
          commandId: 'penny-no-book1',
          fileName: 'multi_book.yy',
          bytes: bytes,
        );
        expect(res.targetBookId, 3);
        expect(await LedgerQueries(db).watchCurrentBookId().first, 3);
      },
    );

    test(
      'empty {} or corrupt payload leaves existing DB 100% untouched (DR-BK-07)',
      () async {
        await seedLocalNotesCurrenciesAndOldRecord();

        final emptyBytes = encodePennyForTest('{}');
        await expectLater(
          () => service.importPenny(
            commandId: 'penny-empty',
            fileName: 'empty.penny',
            bytes: emptyBytes,
          ),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.validation,
            ),
          ),
        );

        final corruptBytes = Uint8List.fromList([
          0x59,
          0x59,
          0x42,
          0x4B,
          0x02,
          0x01,
          0x01,
          0xAA,
          0xBB,
        ]);
        await expectLater(
          () => service.importPenny(
            commandId: 'penny-corrupt',
            fileName: 'corrupt.penny',
            bytes: corruptBytes,
          ),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.corruptData,
            ),
          ),
        );

        // Verify local record, 16 seeded categories, 5 notes, custom currencies, and book=2 remain intact
        expect((await db.select(db.records).get()).map((r) => r.recordId), [
          'local-old-1',
        ]);
        expect((await db.select(db.recordCategories).get()).length, 16);
        expect((await db.select(db.notes).get()).length, 5);
        expect((await db.select(db.currencies).get()).length, 3);
        expect(await LedgerQueries(db).watchCurrentBookId().first, 2);
      },
    );

    test(
      '100% atomic SQLite transaction rollback when mid-transaction insert fails after clear20 (R4, HR-03)',
      () async {
        await seedLocalNotesCurrenciesAndOldRecord();

        // Trigger an abort on the 20th table (`auto_map`) AFTER all 20 DELETEs and 19 table batch inserts run!
        await db.customStatement('''
        CREATE TEMP TRIGGER fail_on_auto_map_insert
        BEFORE INSERT ON auto_map
        BEGIN
          SELECT RAISE(ABORT, 'simulated mid-restore failure');
        END;
      ''');

        final pennyBytes = encodePennyForTest(_buildFull20TablePayload());
        await expectLater(
          () => service.importPenny(
            commandId: 'penny-rollback-trigger',
            fileName: 'rollback.penny',
            bytes: pennyBytes,
          ),
          throwsA(isA<Failure>()),
        );

        // Every single pre-existing row in SQLite must be rolled back intact!
        expect((await db.select(db.accountBooks).get()).map((b) => b.id), [1]);
        expect((await db.select(db.accountBooks).get()).single.name, '日常账本');
        expect((await db.select(db.recordCategories).get()).length, 16);
        expect((await db.select(db.records).get()).map((r) => r.recordId), [
          'local-old-1',
        ]);
        expect((await db.select(db.notes).get()).length, 5);
        expect((await db.select(db.currencies).get()).length, 3);
        expect(await LedgerQueries(db).watchCurrentBookId().first, 2);
      },
    );

    test(
      'enforces ADR-009 commandId idempotency and conflict detection',
      () async {
        final bytesA = encodePennyForTest(_buildFull20TablePayload());
        final first = await service.importPenny(
          commandId: 'idem-cmd-1',
          fileName: 'a.penny',
          bytes: bytesA,
        );
        expect(first.deduplicated, isFalse);

        final second = await service.importPenny(
          commandId: 'idem-cmd-1',
          fileName: 'a.penny',
          bytes: bytesA,
        );
        expect(second.deduplicated, isTrue);

        final bytesB = encodePennyForTest({
          'books': [
            {'id': 1, 'name': '不同内容', 'cdate': 1700000000000},
          ],
        });
        await expectLater(
          () => service.importPenny(
            commandId: 'idem-cmd-1',
            fileName: 'b.penny',
            bytes: bytesB,
          ),
          throwsA(
            isA<Failure>().having((f) => f.code, 'code', FailureCode.conflict),
          ),
        );
      },
    );
  });
}
