import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/aes_cipher.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/domain/ledger/asset_json.dart';
import 'package:tallyisle/domain/ledger/record_extra.dart';
import 'package:tallyisle/domain/ledger/record_relations.dart';
import 'package:tallyisle/domain/rules/budget_rules.dart';
import 'package:tallyisle/domain/rules/debt_rules.dart';
import 'package:tallyisle/domain/rules/fixed_deposit.dart';
import 'package:tallyisle/domain/rules/penny_backup.dart';

Uint8List _hex(String hex) {
  final clean = hex.replaceAll(RegExp(r'\s+'), '');
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

void main() {
  group('Pure-Dart AES & PBKDF2-HMAC-SHA1 official vectors', () {
    test(
      'NIST FIPS-197 Appendix C.1 / C.2 / C.3 (AES-128, AES-192, AES-256)',
      () {
        final plaintext = _hex('00112233445566778899aabbccddeeff');

        // C.1 AES-128
        final aes128 = AesBlockCipher(_hex('000102030405060708090a0b0c0d0e0f'));
        final c128 = aes128.encryptBlock(plaintext);
        expect(c128, _hex('69c4e0d86a7b0430d8cdb78070b4c55a'));
        expect(aes128.decryptBlock(c128), plaintext);

        // C.2 AES-192
        final aes192 = AesBlockCipher(
          _hex('000102030405060708090a0b0c0d0e0f1011121314151617'),
        );
        final c192 = aes192.encryptBlock(plaintext);
        expect(c192, _hex('dda97ca4864cdfe06eaf70a0ec0d7191'));
        expect(aes192.decryptBlock(c192), plaintext);

        // C.3 AES-256
        final aes256 = AesBlockCipher(
          _hex(
            '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f',
          ),
        );
        final c256 = aes256.encryptBlock(plaintext);
        expect(c256, _hex('8ea2b7ca516745bfeafc49904b496089'));
        expect(aes256.decryptBlock(c256), plaintext);
      },
    );

    test('AES-CBC-PKCS7 & AES-CTR (NIST SP 800-38A F.5.5 + WinZip LE)', () {
      final key = _hex(
        '603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4',
      );
      final iv = _hex('f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff');
      final pt = _hex(
        '6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51'
        '30c81c46a35ce411e5fbc1191a0a52ef',
      );
      final expectedCtr = _hex(
        '601ec313775789a5b7a7f504bbf3d228f443e3ca4d62b59aca84e990cacaf5c5'
        '2b0930daa23de94ce87017ba2d84988d',
      );

      final ctrEncrypted = aesCtrTransform(key: key, iv: iv, input: pt);
      expect(ctrEncrypted, expectedCtr);
      expect(aesCtrTransform(key: key, iv: iv, input: ctrEncrypted), pt);

      // Little-endian counter round-trip (WinZip AE-1/AE-2 convention)
      final leCipher = aesCtrTransform(
        key: key,
        input: pt,
        initialCounter: 1,
        littleEndianCounter: true,
      );
      expect(
        aesCtrTransform(
          key: key,
          input: leCipher,
          initialCounter: 1,
          littleEndianCounter: true,
        ),
        pt,
      );

      // CBC-PKCS7 round-trip across 0, 15, 16, and 33 bytes
      for (final len in const <int>[0, 15, 16, 33]) {
        final msg = Uint8List.fromList(
          List<int>.generate(len, (i) => i * 7 & 0xff),
        );
        final cbc = aesCbcEncryptPkcs7(key: key, iv: iv, plaintext: msg);
        expect(cbc.length % 16, 0);
        expect(aesCbcDecryptPkcs7(key: key, iv: iv, ciphertext: cbc), msg);
      }
    });

    test('RFC 6070 PBKDF2-HMAC-SHA1 test vectors', () {
      expect(
        pbkdf2HmacSha1(
          password: utf8.encode('password'),
          salt: utf8.encode('salt'),
          iterations: 1,
          derivedKeyLength: 20,
        ),
        _hex('0c60c80f961f0e71f3a9b524af6012062fe037a6'),
      );
      expect(
        pbkdf2HmacSha1(
          password: utf8.encode('password'),
          salt: utf8.encode('salt'),
          iterations: 2,
          derivedKeyLength: 20,
        ),
        _hex('ea6c014dc72d6f8ccd1ed92ace1d41f0d8de8957'),
      );
      expect(
        pbkdf2HmacSha1(
          password: utf8.encode('passwordPASSWORDpassword'),
          salt: utf8.encode('saltSALTsaltSALTsaltSALTsaltSALTsalt'),
          iterations: 4096,
          derivedKeyLength: 25,
        ),
        _hex('3d2eec4fe41c849b80c8d83662c0e44a8b291a964cf2f07038'),
      );
    });
  });

  group('.penny / .yy envelope codec (DR-BK-01, R1)', () {
    test('standard YYBK 7-byte header round-trip', () {
      final rawJson =
          '{"books":[{"id":1,"name":"日常账本","cdate":1700000000000}]}';
      final bytes = encodePennyForTest(rawJson);

      expect(bytes.sublist(0, 7), [0x59, 0x59, 0x42, 0x4B, 0x02, 0x01, 0x01]);
      final decoded = decodePennyBytes(bytes);
      expect(decoded.format, PennyEnvelopeFormat.standardYybk);
      expect(decoded.jsonText, rawJson);
    });

    test('legacy outer Base64 + GZIP and inner Base64 + GZIP fallbacks', () {
      final rawJson =
          '{"books":[{"id":1,"name":"历史账本","cdate":1700000000000}]}';

      final outerB64 = encodePennyForTest(rawJson, legacyBase64: true);
      expect(String.fromCharCodes(outerB64.take(4)), isNot('YYBK'));
      final decOuter = decodePennyBytes(outerB64);
      expect(decOuter.format, PennyEnvelopeFormat.legacyBase64Gzip);
      expect(decOuter.jsonText, rawJson);

      final innerB64 = encodePennyForTest(
        rawJson,
        legacyBase64: true,
        innerBase64: true,
      );
      final decInner = decodePennyBytes(innerB64);
      expect(decInner.format, PennyEnvelopeFormat.legacyBase64InnerBase64Gzip);
      expect(decInner.jsonText, rawJson);
    });

    test(
      'rejects empty, truncated, wrong header version, wrong AES key, or corrupt payload',
      () {
        expect(
          () => decodePennyBytes(Uint8List(0)),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.corruptData,
            ),
          ),
        );

        // Truncated YYBK header
        expect(
          () => decodePennyBytes(
            Uint8List.fromList([0x59, 0x59, 0x42, 0x4B, 0x02]),
          ),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.corruptData,
            ),
          ),
        );

        // Wrong version byte (0x02 0x01 0x09)
        final valid = encodePennyForTest('{"books":[{"id":1,"name":"A"}]}');
        final badVer = Uint8List.fromList(valid)..[6] = 0x09;
        expect(
          () => decodePennyBytes(badVer),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.corruptData,
            ),
          ),
        );

        // Wrong AES key
        final wrongKeyBytes = encodePennyForTest(
          '{"books":[{"id":1,"name":"A"}]}',
          keyOverride: Uint8List.fromList(
            utf8.encode('0123456789abcdef0123456789abcdef'),
          ),
        );
        expect(
          () => decodePennyBytes(wrongKeyBytes),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.corruptData,
            ),
          ),
        );

        // Truncated ciphertext (not multiple of 16)
        expect(
          () => decodePennyBytes(valid.sublist(0, valid.length - 3)),
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

  group('Staging rules: empty defense (R2), tombstones (R3), exact minor math', () {
    test(
      'DR-BK-07 rejects {} and all-empty-list payloads before touching DB',
      () {
        final emptyObj = encodePennyForTest('{}');
        expect(
          () => stagePennyBackup(bytes: emptyObj),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.validation,
            ),
          ),
        );

        final allEmptyLists = encodePennyForTest({
          for (final k in penny20RootListKeys) k: <Object?>[],
        });
        expect(
          () => stagePennyBackup(bytes: allEmptyLists),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.validation,
            ),
          ),
        );

        final allTombstones = encodePennyForTest({
          'books': [
            {'id': 1, 'name': '日常账本', 'cdate': 1000, 'sstatus': 4},
          ],
          'records': [
            {
              'id': 'rec-del',
              'type': 0,
              'money': 10.5,
              'time': 1000,
              'book': 1,
              'sstatus': 4,
            },
          ],
        });
        expect(
          () => stagePennyBackup(bytes: allTombstones),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.validation,
            ),
          ),
        );
      },
    );

    test(
      'DR-BK-08 filters sstatus == 4 tombstones, strips sync metadata, and converts HALF_UP minor units',
      () {
        // Raw JSON text exercises exact lexeme parsing including ultra-large decimal 90071992547409.93
        // (which would drift to .92 under IEEE-754 double * 100!).
        const rawJson = '''
{
  "books": [
    {"_id": 1, "id": 1, "name": "日常账本", "dstart": 5, "cdate": 1700000000000, "uid": "u1", "sstime": 999, "sstatus": 2},
    {"_id": 2, "id": 2, "name": "已删账本", "cdate": 1700000000000, "sstatus": 4}
  ],
  "records": [
    {"id": "rec-a", "type": 0, "money": 1234.56, "discount": 12.345, "remark": "午餐", "time": 1700000100000, "book": 1, "uid": "u1", "sync_time": 12345, "sstatus": 2},
    {"id": "rec-b", "type": 0, "money": 88.88, "time": 1700000200000, "book": 1, "sstatus": 4},
    {"id": "rec-huge", "type": 1, "money": 90071992547409.93, "discount": 0.004, "time": 1700000300000, "book": 1, "sstatus": 0}
  ],
  "remarks": [
    {"id": 10, "content": "早餐包子", "record_cat_id": 1, "used_times": 6, "sstatus": 0},
    {"id": 11, "content": "废弃备注", "record_cat_id": 1, "used_times": 1, "sstatus": 4}
  ]
}
''';
        final bytes = encodePennyForTest(rawJson);
        final staged = stagePennyBackup(
          bytes: bytes,
          fileName: '一羽记账_8.6.0_20261111.penny',
        );

        expect(staged.preview.appVersion, '8.6.0');
        expect(staged.preview.filteredTombstoneCount, 3);
        expect(staged.books.length, 1);
        expect(staged.books.single.id, 1);
        expect(staged.books.single.startDay, 5);

        expect(staged.records.length, 2);
        final recA = staged.records.firstWhere((r) => r.recordId == 'rec-a');
        expect(recA.moneyMinor, BigInt.from(123456));
        expect(recA.discountMinor, BigInt.from(1235));

        final recHuge = staged.records.firstWhere(
          (r) => r.recordId == 'rec-huge',
        );
        expect(recHuge.moneyMinor, BigInt.parse('9007199254740993'));
        expect(recHuge.discountMinor, BigInt.zero);

        // R6: active remarks unconditionally staged
        expect(staged.remarks.length, 1);
        expect(staged.remarks.single.content, '早餐包子');
        expect(staged.remarks.single.usedTimes, 6);
      },
    );

    test(
      'converts all embedded REAL JSON amounts so TallyIsle domain parsers read them cleanly',
      () {
        // 1. record.extra_info
        final recExtraOut = convertRecordExtraJson(
          '{"curr":{"sc":"USD","sm":100,"ac":"CNY","am":615.6,"bc":"CNY","bm":615.6,"dam":104.4,"dbm":104.4,"sd":14.5,"ad":104.4},'
          '"adbi":{"advanceIncomeDate":1700000000000,"advanceMoney":250.555,"advanceDiffMoney":0.015,"partialInclude":true},'
          '"adv":{"m":99.95,"money":50.25}}',
        );
        final parsedExtra = RecordExtra.parse(recExtraOut);
        expect(parsedExtra.currency!.sourceCode, 'USD');
        expect(parsedExtra.currency!.sourceGross, BigInt.from(10000));
        expect(parsedExtra.currency!.assetNet, BigInt.from(61560));
        expect(parsedExtra.currency!.baseAmount, BigInt.from(61560));
        expect(parsedExtra.currency!.assetDiscount, BigInt.from(10440));
        expect(parsedExtra.currency!.baseDiscount, BigInt.from(10440));
        expect((parsedExtra.raw['curr']! as Map)['sd'], '1450');
        expect((parsedExtra.raw['curr']! as Map)['ad'], '10440');
        expect(parsedExtra.advance!.advanceMoney, BigInt.from(25056));
        expect(parsedExtra.advance!.advanceDiffMoney, BigInt.from(2));
        expect((parsedExtra.raw['adv']! as Map)['m'], '9995');
        expect((parsedExtra.raw['adv']! as Map)['money'], '5025');

        // 2. record.rel_info
        final relOut = convertRecordRelJson(
          '{"lrefundi":{"rfbinfo":[{"lbid":"r1","lbm":35.5,"ac":"CNY","am":35.5,"bc":"CNY","bm":35.5}]},'
          '"lreimbursei":{"ribinfo":[{"lbid":"r2","lbm":120.05}]}}',
        );
        final parsedRel = RecordRelations.parse(relOut);
        expect(parsedRel.refunds!.children.single.amount, BigInt.from(3550));
        expect(
          parsedRel.refunds!.children.single.assetAmount,
          BigInt.from(3550),
        );
        expect(
          parsedRel.reimbursements!.children.single.amount,
          BigInt.from(12005),
        );

        // 3. asset.credit_info
        final creditOut = convertAssetCreditJson(
          '{"bill_day":15,"repayment_day":5,"inst":[{"iid":"1-2","b":333.33,"i":6.67,"cb":true,"ci":false}],"installment":999.99}',
        );
        final parsedCredit = CreditInfo.parse(creditOut);
        expect(parsedCredit.installments!.single.principal, BigInt.from(33333));
        expect(parsedCredit.installments!.single.interest, BigInt.from(667));
        expect(parsedCredit.raw['installment'], '99999');

        // 4. asset.extra_info
        final assetExtraOut = convertAssetExtraJson(
          '{"repay_asset":2,"temp_amt":[{"m":5000.5,"ddl":1800000000000,"upd":1700000000000}]}',
        );
        final parsedAssetExtra = AssetExtra.parse(assetExtraOut);
        expect(parsedAssetExtra.repayAssetId, 2);
        expect(parsedAssetExtra.tempAmounts.single.amount, BigInt.from(500050));

        // 5. asset.loan_info
        final loanOut = convertAssetLoanJson(
          '{"startDate":1700000000000,"endDate":-1,"totalDebtMoney":2000.5,"sb":500.25,"cp":[{"cc":"USD","pb":100.5,"tp":300.75}]}',
        );
        final parsedLoan = LoanInfo.parse(loanOut);
        expect(parsedLoan.totalDebtMoneyMinor, BigInt.from(200050));
        expect(parsedLoan.settledSnapshotMinor, BigInt.from(50025));
        expect(
          parsedLoan.currencyPositions.single.principalBalanceMinor,
          BigInt.from(10050),
        );
        expect(
          parsedLoan.currencyPositions.single.totalPrincipalMinor,
          BigInt.from(30075),
        );

        // 6. asset.fixed_deposit_info
        final fdOut = convertAssetFixedDepositJson(
          '[{"money":10000.5,"from_asset_id":1,"update_asset_balance":true,"annual_rate":0.0245,"period_unit":2,"period_count":1,"deposit_date":1700000000000,"due_date":1731536000000,"expected_income":245.01,"c":"CNY","ac":"CNY","am":10000.5,"bc":"CNY","bm":10000.5,"remark":"定存","status":0}]',
        );
        final fdJsonList = jsonDecode(fdOut!) as List<Object?>;
        final fdItem = FixedDepositItem.fromJson(fdJsonList.single);
        expect(fdItem.moneyMinor, BigInt.from(1000050));
        expect(fdItem.expectedIncomeMinor, BigInt.from(24501));
        expect(fdItem.assetMoneyMinor, BigInt.from(1000050));
        expect(fdItem.baseMoneyMinor, BigInt.from(1000050));
        expect(
          formatDecimalValue(fdItem.annualRate, trimTrailingZeros: true),
          '0.0245',
        );

        // 7. budget.extra_info
        final budgetExtraOut = convertBudgetExtraJson(
          '{"acopy":true,"forward":false,"base":3000.8}',
        );
        final parsedBudgetExtra = BudgetExtra.fromJson(budgetExtraOut);
        expect(parsedBudgetExtra.autoCopy, isTrue);
        expect(parsedBudgetExtra.baseMinor, BigInt.from(300080));
      },
    );

    test(
      '§6.2 target book selection prefers id=1, else first by (sort, id)',
      () {
        const booksWith1 = [
          StagedAccountBook(
            id: 5,
            type: 1,
            name: '旅行账本',
            cover: '',
            sort: 0,
            status: 0,
            startDay: 1,
            createDate: 0,
            displayWay: 0,
          ),
          StagedAccountBook(
            id: 1,
            type: 1,
            name: '日常账本',
            cover: '',
            sort: 2,
            status: 0,
            startDay: 1,
            createDate: 0,
            displayWay: 0,
          ),
        ];
        expect(resolvePennyTargetBookId(booksWith1), 1);

        const booksWithout1 = [
          StagedAccountBook(
            id: 9,
            type: 1,
            name: '装修账本',
            cover: '',
            sort: 1,
            status: 0,
            startDay: 1,
            createDate: 0,
            displayWay: 0,
          ),
          StagedAccountBook(
            id: 3,
            type: 1,
            name: '家庭账本',
            cover: '',
            sort: 1,
            status: 0,
            startDay: 1,
            createDate: 0,
            displayWay: 0,
          ),
        ];
        expect(resolvePennyTargetBookId(booksWithout1), 3);
      },
    );

    test(
      'extracts BillImage @SerializedName("fname") on records/periods/installments and skips null list elements (02zn §3)',
      () {
        final payload = encodePennyForTest({
          'books': [
            null,
            {'id': 1, 'name': '日常账本', 'cdate': 1700000000000},
          ],
          'records': [
            null,
            {
              'id': 'rec-img-1',
              'type': 0,
              'money': 58.00,
              'time': 1700000100000,
              'book': 1,
              'img': [
                {'fname': 'bill_1.jpg'},
                null,
                {'fname': 'bill_2.jpg'},
              ],
            },
          ],
          'periods': [
            null,
            {
              'id': 601,
              'type': 0,
              'money': 30.00,
              'book': 1,
              'ptype': 2,
              'ptypedate': ['1'],
              'startdate': 1700000000000,
              'enddate': -1,
              'ctime': 1700000000000,
              'img': [
                {'fname': 'period_1.jpg'},
                {'fname': 'period_2.jpg'},
              ],
            },
          ],
          'installments': [
            null,
            {
              'id': 501,
              'name': '相机分期',
              'prin': 3000.00,
              'periods': 3,
              'charge': 0,
              'sdate': 1700000000000,
              'asset': 10,
              'book': 1,
              'cdate': 1700000000000,
              'img': [
                {'fname': 'inst_1.jpg'},
                {'fname': 'inst_2.jpg'},
              ],
            },
          ],
        });

        final staged = stagePennyBackup(bytes: payload);
        expect(staged.books.length, 1);
        expect(staged.records.single.images, 'bill_1.jpg,bill_2.jpg');
        expect(staged.periods.single.images, 'period_1.jpg,period_2.jpg');
        expect(staged.installments.single.images, 'inst_1.jpg,inst_2.jpg');

        // All-null lists still trigger the R2 empty-backup preflight guard!
        final allNulls = encodePennyForTest({
          'books': [null],
          'records': [null, null],
        });
        expect(
          () => stagePennyBackup(bytes: allNulls),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.validation,
            ),
          ),
        );
      },
    );
  });
}
