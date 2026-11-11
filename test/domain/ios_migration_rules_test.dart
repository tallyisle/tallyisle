import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/domain/ledger/asset_json.dart';
import 'package:tallyisle/domain/ledger/record_extra.dart';
import 'package:tallyisle/domain/ledger/record_relations.dart';
import 'package:tallyisle/domain/rules/debt_rules.dart';
import 'package:tallyisle/domain/rules/fixed_deposit.dart';
import 'package:tallyisle/domain/rules/ios_migration_rules.dart';

void main() {
  group('validateYi2aFileName (EX-20)', () {
    test('accepts lowercase .yi2a and empty/blank extensions', () {
      expect(() => validateYi2aFileName('backup.yi2a'), returnsNormally);
      expect(
        () => validateYi2aFileName('/storage/emulated/0/Download/ios.yi2a'),
        returnsNormally,
      );
      expect(
        () => validateYi2aFileName(r'C:\Users\demo\export.yi2a'),
        returnsNormally,
      );
      expect(() => validateYi2aFileName('shared_payload'), returnsNormally);
      expect(() => validateYi2aFileName('shared_payload.'), returnsNormally);
      expect(() => validateYi2aFileName('shared_payload.   '), returnsNormally);
    });

    test('rejects uppercase .YI2A and non-yi2a extensions', () {
      for (final bad in [
        'backup.YI2A',
        'backup.Yi2a',
        'export.ya2i',
        'data.json',
        'ServerBackup.zip',
      ]) {
        expect(
          () => validateYi2aFileName(bad),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.validation,
            ),
          ),
          reason: 'Expected $bad to be rejected',
        );
      }
    });
  });

  group('R1 non-empty preflight disaster guard', () {
    test('rejects empty bytes, empty JSON {}, and all-empty 19 lists', () {
      expect(
        () => parseYi2aBytes(Uint8List(0)),
        throwsA(
          isA<Failure>().having((f) => f.code, 'code', FailureCode.validation),
        ),
      );

      expect(
        () => parseYi2aJsonText('{}'),
        throwsA(
          isA<Failure>().having((f) => f.code, 'code', FailureCode.validation),
        ),
      );

      final allEmpty = jsonEncode({
        for (final key in iosMigrationListKeys) key: const <Object>[],
      });
      expect(
        () => parseYi2aJsonText(allEmpty),
        throwsA(
          isA<Failure>().having((f) => f.code, 'code', FailureCode.validation),
        ),
      );
    });

    test('rejects file where all entities are sstatus == 4 tombstones', () {
      final tombstonesOnly = jsonEncode({
        'books': [
          {
            'id': 1,
            'name': '已删除账本',
            'cdate': 1700000000000,
            'sstatus': 4,
            'uid': 'u1',
          },
        ],
        'records': [
          {
            'id': 'rec-del-1',
            'type': 0,
            'money': 88.50,
            'time': 1700000000000,
            'book': 1,
            'sstatus': 4,
            'uid': '',
          },
        ],
      });

      expect(
        () => parseYi2aJsonText(tombstonesOnly),
        throwsA(
          isA<Failure>().having((f) => f.code, 'code', FailureCode.validation),
        ),
      );
    });
  });

  group('R2/R3/DEC-005 guest uid="" stripping & id=1 book deduplication', () {
    test(
      'strips uid/sync_time/sstatus, drops sstatus=4, and deduplicates id=1 book',
      () {
        final yi2aText = jsonEncode({
          'books': [
            {
              '_id': 1,
              'id': 1,
              'name': '日常账本',
              'cdate': 1700000000000,
              'uid': 'logged-in-user',
              'sync_time': 1700000001000,
              'sstatus': 0,
            },
            {
              '_id': 2,
              'id': 1,
              'name': '我的主账本',
              'cdate': 1700000002000,
              'uid': '',
              'sync_time': 0,
              'sstatus': 1,
            },
          ],
          'records': [
            {
              'id': 'guest-rec-1',
              'type': 0,
              'money': 36.8,
              'remark': '游客午餐',
              'time': 1700010000000,
              'cat': 1,
              'asset': -1,
              'book': 1,
              'plat': -1,
              'uid': '',
              'sync_time': 0,
              'sstatus': 1,
            },
            {
              'id': 'tombstone-rec-2',
              'type': 0,
              'money': 99.0,
              'remark': '已删账单',
              'time': 1700020000000,
              'cat': 1,
              'asset': -1,
              'book': 1,
              'plat': -1,
              'uid': '',
              'sync_time': 10,
              'sstatus': 4,
            },
          ],
        });

        final payload = parseYi2aJsonText(yi2aText);
        expect(payload.books, hasLength(1));
        expect(payload.books.single.id, 1);
        // Custom name wins over auto-seeded '日常账本' on id=1 collision
        expect(payload.books.single.name, '我的主账本');
        expect(payload.resolveActiveBookId(), 1);

        expect(payload.records, hasLength(1));
        expect(payload.records.single.recordId, 'guest-rec-1');
        expect(payload.records.single.moneyMinor, BigInt.from(3680));
        expect(payload.records.single.remark, '游客午餐');
      },
    );
  });

  group('R4 / EX-19 full 19-list round-trip & short-key fidelity', () {
    test('canonical list keys equal exact 19 keys with singular statStory', () {
      expect(iosMigrationListKeys, hasLength(19));
      expect(iosMigrationListKeys, contains('assetBookRefs'));
      expect(iosMigrationListKeys, contains('statStory'));
      expect(iosMigrationListKeys, isNot(contains('statStories')));
    });

    test(
      'parses all 19 lists from .yi2a and re-encodes .ya2i with exact 2-decimal unquoted numbers and extraNotes',
      () {
        final rawYi2a = jsonEncode({
          'books': [
            {
              'id': 1,
              'type': 1,
              'name': '旅行账本',
              'cover': 'cover_1',
              'sort': 2,
              'status': 0,
              'dstart': 5,
              'cdate': 1710000000000,
              'dway': 1,
            },
          ],
          'categories': [
            {
              'id': 10,
              'name': '机票',
              'icon': 'ic_flight',
              'type': 0,
              'sort': 1,
              'parent': -1,
              'color': '#FF5722',
              'platform_id': -1,
              'book': 1,
              'hide': false,
            },
          ],
          'assets': [
            {
              'id': 20,
              'name': '招商储蓄卡',
              'bal': 1234.56,
              'type': 0,
              'subt': 2,
              'cdate': 1710000000000,
              'sort': 1,
              'icon': 'ic_cmb',
              'remark': '工资卡',
              'initm': 500.05,
              'default': true,
              'effect': true,
              'usetime': 8,
              'color': '#1E88E5',
              'status': 0,
              'groupname': '常用卡',
              'currency': 'CNY',
            },
          ],
          'records': [
            {
              'id': 'rec-1001',
              'type': 0,
              'subt': -1,
              'money': 688.90,
              'remark': '直飞航班',
              'time': 1710050000000,
              'cat': 10,
              'asset': 20,
              'froma': -1,
              'toa': -1,
              'book': 1,
              'exbud': true,
              'exexin': false,
              'plat': 30,
              'period': 40,
              'instal': 'inst_ref',
              'img': [
                {'fname': 'ticket_a.jpg'},
                {'fname': 'ticket_b.png'},
              ],
              'discount': 11.10,
              'cdt': 1710050001000,
            },
          ],
          'budgets': [
            {
              'id': 50,
              'type': 0,
              'cat': -1,
              'amount': 5000.00,
              'book': 1,
              'sect': '2026-11',
              'sort': 0,
              'cdate': 1710000000000,
              'extra_info': '{"base":4500.25,"acopy":1}',
            },
          ],
          'importPlatforms': [
            {
              'id': 30,
              'plat': '微信账单',
              'recordc': 12,
              'catc': 3,
              'time': 1710005000000,
              'hidden': true,
            },
          ],
          'installments': [
            {
              'id': 60,
              'name': '相机分期',
              'cat': 10,
              'prin': 6000.00,
              'periods': 12,
              'charge': 120.60,
              'chargeway': 1,
              'remin': 0,
              'calway': 2,
              'sdate': 1710000000000,
              'asset': 20,
              'np': 2,
              'npdate': 1712600000000,
              'credited': [1],
              'book': 1,
              'exbud': false,
              'exexin': false,
              'cdate': 1710000000000,
              'tags': ['tag-1', 'tag-2'],
              'img': [
                {'fname': 'cam.jpg'},
              ],
            },
          ],
          'periods': [
            {
              'id': 40,
              'type': 0,
              'money': 25.50,
              'fee': 0.50,
              'remark': '云盘订阅',
              'cat': 10,
              'asset': 20,
              'asset2': -1,
              'book': 1,
              'state': 0,
              'time': '09:00',
              'exbud': false,
              'exexin': false,
              'ptype': 2,
              'ptypedate': ['15'],
              'startdate': 1710000000000,
              'enddate': -1,
              'freq': 1,
              'lastadd': -1,
              'addtimes': 1,
              'ctime': 1710000000000,
              'tags': ['tag-1'],
            },
          ],
          'reminders': [
            {
              'id': 70,
              'time': DateTime(2020, 12, 19, 21, 30).millisecondsSinceEpoch,
              'tip': '',
            },
          ],
          'tags': [
            {
              'id': 'tag-parent',
              'name': '出行',
              'sort': 0,
              'hidden': false,
              'parent': null,
              'isparent': true,
              'color': '#009688',
            },
            {
              'id': 'tag-1',
              'name': '航空',
              'sort': 1,
              'hidden': false,
              'parent': 'tag-parent',
              'isparent': false,
              'color': '#009688',
            },
          ],
          'tagRefs': [
            {'tid': 'tag-1', 'rid': 'rec-1001'},
          ],
          'templates': [
            {
              'id': 80,
              'type': 0,
              'remark': '地铁通勤',
              'money': 4.00,
              'fee': 0.00,
              'cat': 10,
              'asset': 20,
              'asset2': -1,
              'sort': 1,
              'autosave': true,
              'book': 1,
              'exbud': false,
              'exexin': false,
              'cdate': 1710000000000,
              'tags': ['tag-1'],
            },
          ],
          'bankCards': [
            {
              'id': 90,
              'type': 0,
              'name': '招商银行',
              'no': '622588001234',
              'owner': '张三',
              'remark': '主卡',
              'color': '#D32F2F',
              'sort': 1,
              'cdate': 1710000000000,
              'card_asset_id': 20,
            },
          ],
          'wishes': [
            {
              'id': 'wish-1',
              'content': '冰岛极光之旅',
              'value': 29999.99,
              'cdate': 1710000000000,
              'realized': false,
              'rdate': 0,
              'sort': 1,
              'icon': 'ic_star',
              'tdate': 1750000000000,
            },
          ],
          'remarks': [
            {
              'id': 100,
              'content': '机场快线',
              'record_cat_id': 10,
              'used_times': 5,
            },
          ],
          'moneySavePlans': [
            {
              'id': 110,
              'name': '旅行基金',
              'remark': '每月定存',
              'plan_type': 1,
              'cycle_type': 2,
              'start_date': 1710000000000,
              'end_date': 1740000000000,
              'plan_money': 12000.00,
              'saved_money': 2000.50,
              'auto_plan': false,
              'from_asset_id': 20,
              'to_asset_id': -1,
              'book_id': 1,
              'start_money': 1000.00,
              'incremental': 100.00,
              'status': 0,
              'create_date': 1710000000000,
              'sort': 0,
              'next_save_date': 1712600000000,
              'bbz_daily_times': 0,
            },
          ],
          'moneySavePlanRecords': [
            {
              'id': 120,
              'plan_id': 110,
              'remark': '首期存入',
              'from_asset_id': 20,
              'to_asset_id': -1,
              'record_date': 1710000000000,
              'record_money': 2000.50,
              'record_id': 'rec-1001',
            },
          ],
          'assetBookRefs': [
            {'aid': 20, 'bid': 1},
          ],
          'statStory': [
            {
              'id': 'story-2026-11',
              'story': '十一月出行消费平稳',
              'book_id': 1,
              'sdate': 1710000000000,
              'edate': 1712600000000,
              'dsection': '2026-11',
            },
          ],
        });

        final parsed = parseYi2aJsonText(rawYi2a);
        expect(parsed.books.single.startDay, 5);
        expect(parsed.assets.single.balanceMinor, BigInt.from(123456));
        expect(parsed.assets.single.initMoneyMinor, BigInt.from(50005));
        expect(parsed.assets.single.isEffectiveAsset, 1);
        expect(parsed.records.single.moneyMinor, BigInt.from(68890));
        expect(parsed.records.single.discountMinor, BigInt.from(1110));
        expect(parsed.records.single.images, 'ticket_a.jpg,ticket_b.png');
        expect(parsed.importPlatforms.single.hidden, isTrue);
        expect(parsed.reminders.single.reminderTime, 21 * 60 + 30);
        expect(parsed.reminders.single.reminderTip, '');
        expect(parsed.tags[0].parent, 1);
        expect(parsed.tags[1].parentTagId, 'tag-parent');
        expect(parsed.tags[1].parent, 0);
        expect(parsed.tagRefs.single.tagId, 'tag-1');
        expect(parsed.tagRefs.single.recordId, 'rec-1001');
        expect(parsed.assetBookRefs.single.assetId, 20);
        expect(parsed.assetBookRefs.single.bookId, 1);
        expect(parsed.statStory.single.id, 'story-2026-11');
        expect(parsed.statStory.single.story, '十一月出行消费平稳');

        // Attach local note for `.ya2i` export §6.2 `extraNotes`
        final withNote = MigrationPayload(
          books: parsed.books,
          categories: parsed.categories,
          assets: parsed.assets,
          records: parsed.records,
          budgets: parsed.budgets,
          importPlatforms: parsed.importPlatforms,
          installments: parsed.installments,
          periods: parsed.periods,
          reminders: parsed.reminders,
          tags: parsed.tags,
          tagRefs: parsed.tagRefs,
          templates: parsed.templates,
          bankCards: parsed.bankCards,
          wishes: parsed.wishes,
          remarks: parsed.remarks,
          moneySavePlans: parsed.moneySavePlans,
          moneySavePlanRecords: parsed.moneySavePlanRecords,
          assetBookRefs: parsed.assetBookRefs,
          statStory: parsed.statStory,
          extraNotes: const [
            MigrationNoteRow(
              id: 1,
              title: '登机备忘',
              content: '提前两小时值机',
              createTime: 1710000000000,
              updateTime: 1710000000000,
            ),
          ],
        );

        final exportedText = encodeYa2iJsonText(withNote);
        // Exact unquoted 2-decimal JSON numbers (zero float drift)
        expect(exportedText, contains('"bal":1234.56'));
        expect(exportedText, contains('"money":688.90'));
        expect(exportedText, contains('"value":29999.99'));
        expect(exportedText, contains('"extraNotes":['));

        // Round-trip re-parse
        final reparsed = parseYi2aJsonText(exportedText);
        expect(reparsed.totalCrossEntityCount, parsed.totalCrossEntityCount);
        expect(reparsed.assetBookRefs.single.assetId, 20);
        expect(reparsed.statStory.single.id, 'story-2026-11');
        expect(reparsed.assets.single.balanceMinor, BigInt.from(123456));
        expect(reparsed.wishes.single.valueMinor, BigInt.from(2999999));
      },
    );

    test('rejects non-boolean importPlatforms.hidden in .yi2a', () {
      final invalidPlatformJson = jsonEncode({
        'importPlatforms': [
          {
            'id': 1,
            'plat': '支付宝',
            'recordc': 5,
            'catc': 2,
            'time': 1700000000000,
            'hidden': 1, // integer instead of boolean must fail in .yi2a
          },
        ],
      });
      expect(
        () => parseYi2aJsonText(invalidPlatformJson),
        throwsA(
          isA<Failure>().having((f) => f.code, 'code', FailureCode.corruptData),
        ),
      );
    });
  });

  group('Decimal HALF_UP & embedded JSON bidirectional converters', () {
    test('parseMajorToMinor handles HALF_UP, scientific notation, and int64', () {
      expect(parseMajorToMinor('1234.56'), BigInt.from(123456));
      expect(parseMajorToMinor('12.345'), BigInt.from(1235));
      expect(parseMajorToMinor('-12.345'), BigInt.from(-1235));
      expect(parseMajorToMinor('1.2345e2'), BigInt.from(12345));
      expect(
        parseMajorToMinor('999999999999.99'),
        BigInt.parse('99999999999999'),
      );

      // 16+ significant-digit raw JSON number literal (> IEEE-754 2^53/100)
      // round-trips through parseYi2aJsonText & encodeYa2iJsonText with 0 cent drift!
      const rawHighPrecisionJson =
          '{"assets":[{"id":1,"name":"高精账户","bal":90071992547409.93,"initm":90071992547409.97,"type":0,"cdate":1710000000000,"effect":true}]}';
      final hpPayload = parseYi2aJsonText(rawHighPrecisionJson);
      expect(
        hpPayload.assets.single.balanceMinor,
        BigInt.parse('9007199254740993'),
      );
      expect(
        hpPayload.assets.single.initMoneyMinor,
        BigInt.parse('9007199254740997'),
      );
      final reExported = encodeYa2iJsonText(hpPayload);
      expect(reExported, contains('"bal":90071992547409.93'));
      expect(reExported, contains('"initm":90071992547409.97'));
    });

    test('converts record.extra_info, rel_info, and asset JSONs losslessly', () {
      // 1. record.extra_info
      final importedExtra = convertRecordExtraInfoOnImport(
        '{"curr":{"sc":"USD","sm":10.5,"r":"7.20","ac":"CNY","am":75.6,"bc":"CNY","bm":75.6,"dam":1.25,"dbm":1.25},"adbi":{"advanceIncomeDate":1710000000000,"advanceMoney":50.05,"advanceDiffMoney":10.05,"partialInclude":1}}',
      );
      final decodedExtra = RecordExtra.parse(importedExtra);
      expect(Money.minor(decodedExtra.currency!.sourceGross).decimal, '10.50');
      expect(decodedExtra.currency!.assetNet, BigInt.from(7560));
      expect(decodedExtra.advance!.advanceMoney, BigInt.from(5005));
      expect(decodedExtra.advance!.partialInclude, isTrue);

      final exportedExtra = convertRecordExtraInfoOnExport(importedExtra)!;
      expect(exportedExtra, contains('"sm":10.50'));
      expect(exportedExtra, contains('"advanceMoney":50.05'));

      // 2. record.rel_info
      final importedRel = convertRecordRelInfoOnImport(
        '{"lrefundi":{"rfbinfo":[{"lbid":"r1","lbm":20.5,"am":20.5,"bm":20.5}]},"ltfeei":{"tff":true,"tfrepay":0,"tfobid":"p1","tfbinfo":{"lbid":"f1","lbm":1.5,"am":1.5,"bm":1.5}}}',
      );
      final decodedRel = RecordRelations.parse(importedRel);
      expect(decodedRel.refunds!.children, hasLength(1));
      expect(decodedRel.refunds!.children.single.amount, BigInt.from(2050));
      expect(decodedRel.transferFee!.feeFromTarget, isTrue);
      expect(decodedRel.transferFee!.repay, isFalse);

      final exportedRel = convertRecordRelInfoOnExport(importedRel)!;
      expect(exportedRel, contains('"lbm":20.50'));
      expect(exportedRel, contains('"lbm":1.50'));

      // 3. asset.credit_info, extra_info, loan_info, fixed_deposit_info
      final importedCredit = convertAssetCreditInfoOnImport(
        '{"limit":50000,"bill_day":5,"repayment_day":25,"inst":[{"iid":"i1","b":1200.5,"i":800.25,"cb":1,"ci":0}],"installment":800.25}',
      );
      final decodedCredit = CreditInfo.parse(importedCredit);
      expect(decodedCredit.installments!.single.principal, BigInt.from(120050));
      expect(decodedCredit.installments!.single.interest, BigInt.from(80025));
      expect(decodedCredit.raw['installment'], '80025');
      expect(
        convertAssetCreditInfoOnExport(importedCredit),
        contains('"b":1200.50'),
      );

      final importedAssetExtra = convertAssetExtraInfoOnImport(
        '{"temp_amt":[{"m":3000.5,"ddl":1750000000000}],"ann_fee":{"t":1,"amt":20000,"fee":680}}',
      );
      final decodedAssetExtra = AssetExtra.parse(importedAssetExtra);
      expect(decodedAssetExtra.tempAmounts.single.amount, BigInt.from(300050));
      final annFee = decodedAssetExtra.raw['ann_fee'] as Map<String, Object?>;
      expect(annFee['fee'], '68000');

      final importedLoan = convertAssetLoanInfoOnImport(
        '{"totalDebtMoney":10000.5,"sb":2000.25,"s":0,"cp":[{"cc":"CNY","pb":500,"tp":1000}]}',
      );
      final decodedLoan = LoanInfo.parse(importedLoan);
      expect(decodedLoan.totalDebtMoneyMinor, BigInt.from(1000050));
      expect(decodedLoan.settledSnapshotMinor, BigInt.from(200025));
      expect(
        decodedLoan.currencyPositions.single.totalPrincipalMinor,
        BigInt.from(100000),
      );

      final importedDeposit = convertAssetFixedDepositInfoOnImport(
        '[{"money":50000,"from_asset_id":1,"update_asset_balance":1,"annual_rate":0.0275,"period_unit":2,"period_count":1,"deposit_date":1700000000000,"due_date":1731536000000,"expected_income":1375.0,"c":"CNY","ac":"CNY","am":50000,"bc":"CNY","bm":50000,"remark":"三年定存","status":0}]',
      )!;
      final decodedDeposits = [
        for (final item in jsonDecode(importedDeposit) as List<Object?>)
          FixedDepositItem.fromJson(item),
      ];
      expect(decodedDeposits.single.moneyMinor, BigInt.from(5000000));
      expect(decodedDeposits.single.expectedIncomeMinor, BigInt.from(137500));
      expect(
        formatDecimalValue(
          decodedDeposits.single.annualRate,
          trimTrailingZeros: true,
        ),
        '0.0275',
      );

      final exportedDeposit = convertAssetFixedDepositInfoOnExport(
        importedDeposit,
      )!;
      expect(exportedDeposit, contains('"money":50000.00'));
      expect(exportedDeposit, contains('"expected_income":1375.00'));
      expect(exportedDeposit, contains('"annual_rate":0.0275'));
    });
  });
}
