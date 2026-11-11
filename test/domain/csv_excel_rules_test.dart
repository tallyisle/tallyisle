import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/csv_excel_codec.dart';
import 'package:tallyisle/domain/rules/csv_excel_rules.dart';

void main() {
  const accounts = [
    ImportAccountRef(id: 1, name: '现金', currency: 'CNY'),
    ImportAccountRef(id: 2, name: '储蓄卡', currency: 'CNY'),
    ImportAccountRef(id: 3, name: '美元卡', currency: 'USD'),
  ];

  group('R1 & §6.1 File Guard and Smart Encoding Probe', () {
    test('enforces 6 MiB ceiling and rejects unsupported extensions', () {
      final overLimit = Uint8List(maxImportFileBytes + 1);
      expect(
        () => decodeSpreadsheetFile(fileName: 'huge.csv', bytes: overLimit),
        throwsA(
          isA<Failure>().having(
            (f) => f.message,
            'message',
            contains('文件大小不能超过6M'),
          ),
        ),
      );

      expect(
        () => decodeSpreadsheetFile(
          fileName: 'statement.pdf',
          bytes: Uint8List.fromList(utf8.encode('hello')),
        ),
        throwsA(isA<Failure>()),
      );
    });

    test(
      'detects HTML-disguised .xls and returns exact actionable guidance',
      () {
        final htmlBytes = Uint8List.fromList(
          utf8.encode(
            '<html><head><meta charset="utf-8"></head>'
            '<body><table><tr><td>日期</td><td>金额</td></tr></table></body></html>',
          ),
        );
        expect(
          () => decodeSpreadsheetFile(
            fileName: 'bank_export.xls',
            bytes: htmlBytes,
          ),
          throwsA(
            isA<Failure>().having(
              (f) => f.message,
              'message',
              '该文件为网页伪装表格，请用 Excel 打开后另存为标准 .xlsx 格式再导入',
            ),
          ),
        );
      },
    );

    test(
      'DR-IMP-01: BOM-less UTF-8 Chinese CSV is detected as UTF-8, never misread as GBK',
      () {
        const csvText =
            '日期,类型,分类,金额,账户,账户2,备注\n'
            '2026-03-15 12:30,支出,餐饮,28.50,现金,,工作午餐\n';
        final bomlessUtf8 = Uint8List.fromList(utf8.encode(csvText));

        final decoded = decodeSmartText(bomlessUtf8);
        expect(decoded.encoding, CsvTextEncoding.utf8);
        expect(decoded.text, csvText);

        final sheet = decodeSpreadsheetFile(
          fileName: 'bomless_utf8.csv',
          bytes: bomlessUtf8,
        );
        final analysis = analyzeSpreadsheetImport(
          spreadsheet: sheet,
          existingAccounts: accounts,
        );
        expect(analysis.platformName, '模板 v1');
        expect(analysis.validRows, hasLength(1));
        expect(analysis.validRows.single.parentCategoryName, '餐饮');
        expect(analysis.validRows.single.remark, '工作午餐');
      },
    );

    test('decodes UTF-8+BOM, real GBK, UTF-16LE, and TSV accurately', () {
      const csvText =
          '日期,类型,分类,金额,账户,账户2,备注\r\n'
          '2026-03-15 18:05,支出,交通,16.80,储蓄卡,,地铁通勤\r\n';

      // 1. UTF-8 with BOM
      final utf8BomBytes = Uint8List.fromList([
        0xEF,
        0xBB,
        0xBF,
        ...utf8.encode(csvText),
      ]);
      expect(decodeSmartText(utf8BomBytes).encoding, CsvTextEncoding.utf8Bom);

      // 2. Real offline GBK encode -> probe -> decode
      final gbkBytes = GbkCodec.encode(csvText);
      // Verify it is NOT valid UTF-8 so we prove real GBK bytes are tested:
      expect(
        () => utf8.decode(gbkBytes, allowMalformed: false),
        throwsFormatException,
      );
      final gbkDecoded = decodeSmartText(gbkBytes);
      expect(gbkDecoded.encoding, CsvTextEncoding.gbk);
      expect(gbkDecoded.text, csvText);

      // 3. UTF-16LE with BOM (FF FE) and TSV (\t)
      const tsvText =
          '日期\t类型\t分类\t金额\t账户\t账户2\t备注\n'
          '2026-03-16 09:00\t收入\t工资\t5000.00\t储蓄卡\t\t三月工资\n';
      final utf16LeBytes = _encodeUtf16LeWithBom(tsvText);
      final u16Decoded = decodeSmartText(utf16LeBytes);
      expect(u16Decoded.encoding, CsvTextEncoding.utf16le);

      final parsedSheet = decodeSpreadsheetFile(
        fileName: 'salary_no_ext', // extensionless defaults to .csv / delimited
        bytes: utf16LeBytes,
      );
      final analysis = analyzeSpreadsheetImport(
        spreadsheet: parsedSheet,
        existingAccounts: accounts,
      );
      expect(analysis.validRows, hasLength(1));
      expect(analysis.validRows.single.type, RecordType.income);
      expect(analysis.validRows.single.moneyMinor, BigInt.from(500000));
    });
  });

  group('DR-IMP-07 / EX-07 Binary .xlsx & .xls Readers', () {
    test(
      'DR-IMP-07: .xlsx trims whitespace around cell text (" 支出 ") and preserves exact decimals',
      () {
        final xlsxBytes = _buildSyntheticXlsx(
          sharedStrings: const [
            '日期',
            '类型',
            '分类',
            '金额',
            '账户',
            '账户2',
            '备注',
            ' 支出 ', // leading + trailing whitespace!
            ' 餐饮 ',
            ' 现金 ',
            ' 科学计数测试 ',
          ],
          sheetXml: '''
<?xml version="1.0" encoding="UTF-8"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <sheetData>
    <row r="1">
      <c r="A1" t="s"><v>0</v></c>
      <c r="B1" t="s"><v>1</v></c>
      <c r="C1" t="s"><v>2</v></c>
      <c r="D1" t="s"><v>3</v></c>
      <c r="E1" t="s"><v>4</v></c>
      <c r="F1" t="s"><v>5</v></c>
      <c r="G1" t="s"><v>6</v></c>
    </row>
    <row r="2">
      <c r="A2" s="1"><v>46096.5</v></c>
      <c r="B2" t="s"><v>7</v></c>
      <c r="C2" t="s"><v>8</v></c>
      <c r="D2"><v>12.345</v></c>
      <c r="E2" t="s"><v>9</v></c>
      <c r="G2" t="s"><v>10</v></c>
    </row>
    <row r="3">
      <c r="A3" s="1"><v>46097.25</v></c>
      <c r="B3" t="s"><v>7</v></c>
      <c r="C3" t="s"><v>8</v></c>
      <c r="D3"><v>1.5E2</v></c>
      <c r="E3" t="s"><v>9</v></c>
    </row>
  </sheetData>
</worksheet>''',
        );

        final sheet = decodeSpreadsheetFile(
          fileName: 'trimmed.xlsx',
          bytes: xlsxBytes,
        );
        final analysis = analyzeSpreadsheetImport(
          spreadsheet: sheet,
          existingAccounts: accounts,
        );

        expect(analysis.failRows, isEmpty);
        expect(analysis.validRows, hasLength(2));
        expect(analysis.validRows[0].type, RecordType.expense);
        expect(analysis.validRows[0].parentCategoryName, '餐饮');
        expect(analysis.validRows[0].assetId, 1);
        expect(analysis.validRows[0].moneyMinor, BigInt.from(1235)); // HALF_UP
        expect(
          analysis.validRows[1].moneyMinor,
          BigInt.from(15000),
        ); // 1.5E2 = 150.00
      },
    );

    test(
      r'BIFF8 .xls reader extracts SST, IEEE-754 NUMBER without #.### truncation, and $ amounts',
      () {
        final xlsBytes = _buildSyntheticBiff8Xls();
        final sheet = decodeSpreadsheetFile(
          fileName: 'legacy.xls',
          bytes: xlsBytes,
        );
        final analysis = analyzeSpreadsheetImport(
          spreadsheet: sheet,
          existingAccounts: accounts,
        );

        expect(analysis.failRows, isEmpty);
        expect(analysis.validRows, hasLength(2));
        expect(analysis.validRows[0].type, RecordType.expense);
        expect(
          analysis.validRows[0].moneyMinor,
          BigInt.from(1235),
        ); // 12.345 HALF_UP
        expect(analysis.validRows[1].moneyMinor, BigInt.from(8800)); // "$88.00"
      },
    );
  });

  group('R2..R4 Amount Parser, Date Format Lock, and Built-in Converters', () {
    test(
      'parseImportAmountMinor strips currency symbols/commas and rounds HALF_UP',
      () {
        expect(parseImportAmountMinor('¥1,234.56'), BigInt.from(123456));
        expect(parseImportAmountMinor('￥88.00元'), BigInt.from(8800));
        expect(parseImportAmountMinor(r'$19.995'), BigInt.from(2000));
        expect(parseImportAmountMinor('金额 0.014'), BigInt.from(1));
        expect(parseImportAmountMinor('+2.5E1'), BigInt.from(2500));
        expect(parseImportAmountMinor('abc'), isNull);
      },
    );

    test(
      'R3: locks date format on row 1, preserves :ss, and rejects mismatched separators',
      () {
        final parserSec = SheetDateParser();
        final t1 = parserSec.parseAndLock('2026-03-15 12:34:56');
        expect(t1, DateTime(2026, 3, 15, 12, 34, 56).millisecondsSinceEpoch);
        expect(parserSec.lockedPattern, ImportDatePattern.dashDateTimeSec);
        // Slash format rejected once dash format is locked:
        expect(parserSec.parseAndLock('2026/03/15 12:34:56'), isNull);

        // When HH:mm is locked, :ss is normalized to :00 per R3
        final parserMin = SheetDateParser();
        final m1 = parserMin.parseAndLock('2026/03/15 08:15');
        expect(m1, DateTime(2026, 3, 15, 8, 15).millisecondsSinceEpoch);
        final m2 = parserMin.parseAndLock('2026/03/16 09:20:45');
        expect(m2, DateTime(2026, 3, 16, 9, 20).millisecondsSinceEpoch);

        // Verify remaining patterns parse cleanly when first seen
        expect(
          SheetDateParser().parseAndLock('2026.05.01 10:20:30'),
          isNotNull,
        );
        expect(SheetDateParser().parseAndLock('2026.05.01 10:20'), isNotNull);
        expect(SheetDateParser().parseAndLock('2026.05.01'), isNotNull);
        expect(SheetDateParser().parseAndLock('2026-05-01'), isNotNull);
        expect(SheetDateParser().parseAndLock('2026/05/01'), isNotNull);
        expect(SheetDateParser().parseAndLock('05-21-2026'), isNotNull);
      },
    );

    test(
      '模板 v1 rejects 消费/还款 while 模板 v3 parses tags, fee, discount, and flags',
      () {
        const v1Csv =
            '日期,类型,分类,金额,账户,账户2,备注\n'
            '2026-03-15,支出,餐饮,20.00,现金,,正常行\n'
            '2026-03-15,消费,餐饮,30.00,现金,,v1不支持消费\n'
            '2026-03-15,还款,,50.00,现金,储蓄卡,v1不支持还款\n';
        final v1Res = analyzeSpreadsheetImport(
          spreadsheet: decodeSpreadsheetFile(
            fileName: 'v1.csv',
            bytes: Uint8List.fromList(utf8.encode(v1Csv)),
          ),
          existingAccounts: accounts,
        );
        expect(v1Res.platformName, '模板 v1');
        expect(v1Res.validRows, hasLength(1));
        expect(v1Res.failRows, hasLength(2));

        final longCat = '超长分类名称一二三四五六七八九十甲乙丙丁'; // > 16 runes
        final longRemark = '备' * 235; // > 200 runes
        final v3ProperCsv = encodeCsvBytes([
          officialTemplateV3Header,
          [
            '2026-03-15 10:00',
            '支出',
            longCat,
            '100.00',
            '未知钱包',
            '',
            longRemark,
            'a.jpg,b.jpg,c.jpg,d.jpg',
            '#出差, #报销, t3, t4, t5, t6, t7, t8, t9',
            '',
            '5.50',
            '是',
            '1',
          ],
          [
            '2026-03-15 11:00',
            '转账',
            '',
            '500.00',
            '储蓄卡',
            '现金',
            '提现',
            '',
            '',
            '2.50',
            '',
            '',
            '',
          ],
          [
            '2026-03-15 12:00',
            '转账',
            '',
            '100.00',
            '储蓄卡',
            '储蓄卡',
            '同账户转账失败',
            '',
            '',
            '',
            '',
            '',
            '',
          ],
          [
            '2026-03-15 13:00',
            '支出',
            '餐饮',
            '50.00',
            '现金',
            '',
            '负优惠失败',
            '',
            '',
            '',
            '-3.00',
            '',
            '',
          ],
        ]);

        final v3Res = analyzeSpreadsheetImport(
          spreadsheet: decodeSpreadsheetFile(
            fileName: 'v3.csv',
            bytes: v3ProperCsv,
          ),
          existingAccounts: accounts,
        );
        expect(v3Res.platformName, '模板 v3');
        expect(v3Res.validRows, hasLength(2));
        expect(v3Res.failRows, hasLength(2));
        expect(v3Res.unknownAssets, ['未知钱包']);

        final row0 = v3Res.validRows[0];
        expect(row0.assetId, noRef); // unknown account on non-transfer -> -1
        expect(row0.parentCategoryName.runes.length, 16);
        expect(row0.remark.runes.length, 200);
        expect(row0.images, ['a.jpg', 'b.jpg', 'c.jpg']); // capped at 3
        expect(row0.tags, hasLength(8)); // stripped # and capped at 8
        expect(row0.tags.first, '出差');
        expect(row0.discountMinor, BigInt.from(550));
        expect(row0.excludeBudget, isTrue);
        expect(row0.excludeExIn, isTrue);

        final row1 = v3Res.validRows[1];
        expect(row1.type, RecordType.transfer);
        expect(row1.fromAssetId, 2);
        expect(row1.toAssetId, 1);
        expect(row1.feeMinor, BigInt.from(250));
      },
    );

    test('parses WeChat (微信支付账单明细) and Alipay (支付宝交易明细) bills with preambles', () {
      final wechatCsv = [
        '微信支付账单明细,,,,,,,,',
        '微信昵称：[测试用户],,,,,,,,',
        '起始时间：[2026-03-01 00:00:00] 终止时间：[2026-03-31 23:59:59],,,,,,,,',
        '----------------------微信支付账单明细列表--------------------,,,,,,,,',
        '交易时间,交易类型,交易对方,商品,收/支,金额(元),支付方式,当前状态,交易单号,商户单号,备注',
        '2026-03-15 08:30:12,商户消费,瑞幸咖啡,拿铁,支出,¥18.50,储蓄卡,支付成功,1001,2001,早咖啡',
        '2026-03-15 12:00:00,微信红包,好友甲,/,收入,¥66.00,零钱,已存入零钱,1002,2002,/',
        '2026-03-15 15:00:00,零钱提现,银行,/,中性交易,¥100.00,零钱,提现已到账,1003,2003,/',
      ].join('\n');

      final wxRes = analyzeSpreadsheetImport(
        spreadsheet: decodeSpreadsheetFile(
          fileName: 'wechat.csv',
          bytes: Uint8List.fromList(utf8.encode(wechatCsv)),
        ),
        existingAccounts: accounts,
      );
      expect(wxRes.platformName, '微信账单');
      expect(wxRes.validRows, hasLength(2));
      expect(wxRes.failRows, hasLength(1)); // 中性交易
      expect(wxRes.validRows[0].moneyMinor, BigInt.from(1850));
      expect(wxRes.validRows[0].assetId, 2); // 储蓄卡 matched
      expect(wxRes.validRows[1].assetId, noRef); // 零钱 unknown -> -1
      expect(wxRes.unknownAssets, contains('零钱'));

      final alipayCsv = [
        '------------------------------------------------------------------------------------',
        '支付宝交易明细',
        '账号:[test@example.com]',
        '------------------------支付宝（中国）网络技术有限公司-------------------------------',
        '交易时间,交易分类,交易对方,对方账号,商品说明,收/支,金额,收/付款方式,交易状态,交易订单号,商家订单号,备注',
        '2026-03-16 19:20:00,餐饮美食,海底捞,hdl@test,双人套餐,支出,238.00,储蓄卡,交易成功,A1,M1,聚餐',
        '2026-03-16 20:00:00,,公司补贴,corp@test,餐补,收入,150.00,现金,交易成功,A2,M2,',
      ].join('\n');

      final aliRes = analyzeSpreadsheetImport(
        spreadsheet: decodeSpreadsheetFile(
          fileName: 'alipay.csv',
          bytes: GbkCodec.encode(alipayCsv),
        ),
        existingAccounts: accounts,
      );
      expect(aliRes.platformName, '支付宝账单');
      expect(aliRes.validRows, hasLength(2));
      expect(aliRes.validRows[0].parentCategoryName, '餐饮美食');
      expect(
        aliRes.validRows[1].parentCategoryName,
        '导入账单',
      ); // fallback category
    });
  });

  group('DR-IMP-08 RFC 4180 CSV Export & Multiline Round-Trip', () {
    test(
      'quotes multiline remarks, commas, and double-quotes and round-trips losslessly',
      () {
        final exportRows = buildCsvExportRows([
          CsvExportRowInput(
            recordTimeMs: DateTime(2026, 3, 20, 14, 35).millisecondsSinceEpoch,
            type: RecordType.expense,
            bookName: '家庭账本',
            parentCategoryName: '餐饮',
            subCategoryName: '堂食',
            moneyMinor: BigInt.from(12850),
            currencyCode: 'CNY',
            accountName: '储蓄卡',
            targetAccountName: '',
            remark: '第一行\n第二行, 含"双引号"测试',
            tags: const ['聚餐', '周末'],
            feeMinor: BigInt.zero,
            discountMinor: BigInt.from(1000),
            excludeBudget: true,
            excludeExIn: false,
          ),
        ]);

        final csvBytes = encodeCsvBytes(exportRows, utf8WithBom: true);
        final rawCsv = utf8.decode(csvBytes.sublist(3));
        expect(rawCsv, contains('"第一行\n第二行, 含""双引号""测试"'));

        final redecoded = decodeSpreadsheetFile(
          fileName: 'roundtrip.csv',
          bytes: csvBytes,
        );
        final reanalyzed = analyzeSpreadsheetImport(
          spreadsheet: redecoded,
          existingAccounts: accounts,
        );

        expect(reanalyzed.platformName, '标准账单 v2');
        expect(reanalyzed.hasBookColumn, isTrue);
        expect(reanalyzed.hasCurrencyColumn, isTrue);
        expect(reanalyzed.failRows, isEmpty);
        expect(reanalyzed.validRows, hasLength(1));

        final row = reanalyzed.validRows.single;
        expect(row.bookName, '家庭账本');
        expect(row.parentCategoryName, '餐饮');
        expect(row.subCategoryName, '堂食');
        expect(row.moneyMinor, BigInt.from(12850));
        expect(row.remark, '第一行\n第二行, 含"双引号"测试');
        expect(row.tags, ['聚餐', '周末']);
        expect(row.discountMinor, BigInt.from(1000));
        expect(row.excludeBudget, isTrue);
        expect(row.excludeExIn, isFalse);
      },
    );
  });
}

Uint8List _encodeUtf16LeWithBom(String text) {
  final units = text.codeUnits;
  final out = BytesBuilder(copy: false)..add(const [0xFF, 0xFE]);
  for (final u in units) {
    out.addByte(u & 0xFF);
    out.addByte((u >> 8) & 0xFF);
  }
  return out.takeBytes();
}

Uint8List _buildSyntheticXlsx({
  required List<String> sharedStrings,
  required String sheetXml,
}) {
  final sstBuf = StringBuffer(
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">',
  );
  for (final s in sharedStrings) {
    sstBuf.write('<si><t xml:space="preserve">$s</t></si>');
  }
  sstBuf.write('</sst>');

  const workbookXml = '''
<?xml version="1.0" encoding="UTF-8"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
          xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets>
</workbook>''';

  const relsXml = '''
<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Target="worksheets/sheet1.xml"/>
</Relationships>''';

  const stylesXml = '''
<?xml version="1.0" encoding="UTF-8"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <cellXfs>
    <xf numFmtId="0"/>
    <xf numFmtId="22"/>
  </cellXfs>
</styleSheet>''';

  return _buildMinimalZip({
    'xl/workbook.xml': utf8.encode(workbookXml),
    'xl/_rels/workbook.xml.rels': utf8.encode(relsXml),
    'xl/styles.xml': utf8.encode(stylesXml),
    'xl/sharedStrings.xml': utf8.encode(sstBuf.toString()),
    'xl/worksheets/sheet1.xml': utf8.encode(sheetXml),
  });
}

Uint8List _buildMinimalZip(Map<String, List<int>> entries) {
  final deflate = ZLibCodec(raw: true);
  final localOut = BytesBuilder(copy: false);
  final centralOut = BytesBuilder(copy: false);
  var offset = 0;
  var count = 0;

  void writeU16(BytesBuilder b, int v) {
    b.addByte(v & 0xFF);
    b.addByte((v >> 8) & 0xFF);
  }

  void writeU32(BytesBuilder b, int v) {
    b.addByte(v & 0xFF);
    b.addByte((v >> 8) & 0xFF);
    b.addByte((v >> 16) & 0xFF);
    b.addByte((v >> 24) & 0xFF);
  }

  for (final e in entries.entries) {
    final nameBytes = utf8.encode(e.key);
    final rawBytes = e.value;
    final compBytes = deflate.encode(rawBytes);

    final localHeader = BytesBuilder(copy: false);
    writeU32(localHeader, 0x04034B50);
    writeU16(localHeader, 20);
    writeU16(localHeader, 0);
    writeU16(localHeader, 8); // DEFLATE
    writeU16(localHeader, 0);
    writeU16(localHeader, 0);
    writeU32(localHeader, 0);
    writeU32(localHeader, compBytes.length);
    writeU32(localHeader, rawBytes.length);
    writeU16(localHeader, nameBytes.length);
    writeU16(localHeader, 0);
    localHeader.add(nameBytes);
    localHeader.add(compBytes);

    final localBytes = localHeader.takeBytes();
    localOut.add(localBytes);

    writeU32(centralOut, 0x02014B50);
    writeU16(centralOut, 20);
    writeU16(centralOut, 20);
    writeU16(centralOut, 0);
    writeU16(centralOut, 8);
    writeU16(centralOut, 0);
    writeU16(centralOut, 0);
    writeU32(centralOut, 0);
    writeU32(centralOut, compBytes.length);
    writeU32(centralOut, rawBytes.length);
    writeU16(centralOut, nameBytes.length);
    writeU16(centralOut, 0);
    writeU16(centralOut, 0);
    writeU16(centralOut, 0);
    writeU16(centralOut, 0);
    writeU32(centralOut, 0);
    writeU32(centralOut, offset);
    centralOut.add(nameBytes);

    offset += localBytes.length;
    count++;
  }

  final cdBytes = centralOut.takeBytes();
  localOut.add(cdBytes);

  writeU32(localOut, 0x06054B50);
  writeU16(localOut, 0);
  writeU16(localOut, 0);
  writeU16(localOut, count);
  writeU16(localOut, count);
  writeU32(localOut, cdBytes.length);
  writeU32(localOut, offset);
  writeU16(localOut, 0);

  return localOut.takeBytes();
}

/// Builds a valid OLE2 Compound Document containing a BIFF8 `Workbook` stream
/// (>= 4096 bytes so it uses regular 512-byte sectors) with header + 2 data rows.
Uint8List _buildSyntheticBiff8Xls() {
  final biff = BytesBuilder(copy: false);

  void rec(int id, List<int> payload) {
    biff.addByte(id & 0xFF);
    biff.addByte((id >> 8) & 0xFF);
    biff.addByte(payload.length & 0xFF);
    biff.addByte((payload.length >> 8) & 0xFF);
    biff.add(payload);
  }

  List<int> u16(int v) => [v & 0xFF, (v >> 8) & 0xFF];
  List<int> u32(int v) => [
    v & 0xFF,
    (v >> 8) & 0xFF,
    (v >> 16) & 0xFF,
    (v >> 24) & 0xFF,
  ];
  List<int> f64(double v) {
    final bd = ByteData(8)..setFloat64(0, v, Endian.little);
    return bd.buffer.asUint8List();
  }

  List<int> xlUnicode16(String s) {
    final units = s.codeUnits;
    return [
      ...u16(units.length),
      0x01, // UTF-16LE flag
      for (final u in units) ...u16(u),
    ];
  }

  // Workbook globals: BOF (0x0809), XF x2 (0x00E0), SST (0x00FC), BOUNDSHEET (0x0085), EOF (0x000A)
  rec(0x0809, [
    ...u16(0x0600),
    ...u16(0x0005),
    ...u16(0),
    ...u16(0),
    ...u32(0),
    ...u32(0),
  ]);
  // XF 0: general (numFmt = 0)
  rec(0x00E0, [...u16(0), ...u16(0), ...List.filled(16, 0)]);
  // XF 1: date format (numFmt = 14 -> yyyy-MM-dd)
  rec(0x00E0, [...u16(0), ...u16(14), ...List.filled(16, 0)]);

  const sstStrings = [
    '日期',
    '类型',
    '分类',
    '金额',
    '账户',
    '账户2',
    '备注',
    ' 支出 ',
    '餐饮',
    '现金',
  ];
  final sstPayload = <int>[
    ...u32(sstStrings.length),
    ...u32(sstStrings.length),
    for (final s in sstStrings) ...xlUnicode16(s),
  ];
  rec(0x00FC, sstPayload);

  // Placeholder BOUNDSHEET pointing to sheet BOF offset (filled below)
  final boundsheetPos = biff.length;
  rec(0x0085, [...u32(0), 0x00, 0x00, 6, 0x00, ...'Sheet1'.codeUnits]);
  rec(0x000A, const []);

  final sheetBofOffset = biff.length;
  // Sheet 1: BOF (type = 0x0010 worksheet)
  rec(0x0809, [
    ...u16(0x0600),
    ...u16(0x0010),
    ...u16(0),
    ...u16(0),
    ...u32(0),
    ...u32(0),
  ]);

  // Row 0 headers (LABELSST = 0x00FD)
  for (var c = 0; c < 7; c++) {
    rec(0x00FD, [...u16(0), ...u16(c), ...u16(0), ...u32(c)]);
  }
  // Row 1: date serial 46096 (NUMBER 0x0203 with XF=1), " 支出 ", "餐饮", 12.345 (NUMBER XF=0), "现金"
  rec(0x0203, [...u16(1), ...u16(0), ...u16(1), ...f64(46096.0)]);
  rec(0x00FD, [...u16(1), ...u16(1), ...u16(0), ...u32(7)]);
  rec(0x00FD, [...u16(1), ...u16(2), ...u16(0), ...u32(8)]);
  rec(0x0203, [...u16(1), ...u16(3), ...u16(0), ...f64(12.345)]);
  rec(0x00FD, [...u16(1), ...u16(4), ...u16(0), ...u32(9)]);

  // Row 2: date serial 46097, " 支出 ", "餐饮", LABEL (0x0204) "$88.00", "现金"
  rec(0x0203, [...u16(2), ...u16(0), ...u16(1), ...f64(46097.0)]);
  rec(0x00FD, [...u16(2), ...u16(1), ...u16(0), ...u32(7)]);
  rec(0x00FD, [...u16(2), ...u16(2), ...u16(0), ...u32(8)]);
  rec(0x0204, [...u16(2), ...u16(3), ...u16(0), ...xlUnicode16(r'$88.00')]);
  rec(0x00FD, [...u16(2), ...u16(4), ...u16(0), ...u32(9)]);

  rec(0x000A, const []);

  final rawStream = biff.takeBytes();
  // Patch sheetBofOffset into BOUNDSHEET payload (after 4-byte record header)
  final patched = Uint8List(4608)..setRange(0, rawStream.length, rawStream);
  final bdPatch = ByteData.sublistView(patched);
  bdPatch.setUint32(boundsheetPos + 4, sheetBofOffset, Endian.little);

  // Wrap in minimal OLE2 Compound Document (sector size = 512 bytes):
  // Sector 0: FAT sector; Sector 1: Directory sector; Sectors 2..10: 9 sectors (4608 bytes) for Workbook stream.
  final totalBytes =
      512 *
      (1 + 1 + 1 + 9); // Header + Sec0(FAT) + Sec1(Dir) + Sec2..10(Stream)
  final ole = Uint8List(totalBytes);
  final bd = ByteData.sublistView(ole);

  // Header
  const sig = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];
  ole.setRange(0, 8, sig);
  bd.setUint16(24, 0x003E, Endian.little);
  bd.setUint16(26, 0x0003, Endian.little);
  bd.setUint16(28, 0xFFFE, Endian.little);
  bd.setUint16(30, 9, Endian.little); // 2^9 = 512
  bd.setUint16(32, 6, Endian.little); // 2^6 = 64
  bd.setUint32(44, 1, Endian.little); // 1 FAT sector
  bd.setUint32(48, 1, Endian.little); // First Dir sector = 1
  bd.setUint32(56, 4096, Endian.little); // miniStreamCutoff = 4096
  bd.setUint32(60, 0xFFFFFFFE, Endian.little); // no miniFAT
  bd.setUint32(68, 0xFFFFFFFE, Endian.little); // no DIFAT
  bd.setUint32(76, 0, Endian.little); // DIFAT[0] = sector 0
  for (var i = 1; i < 109; i++) {
    bd.setUint32(76 + i * 4, 0xFFFFFFFF, Endian.little);
  }

  // Sector 0 (offset 512): FAT
  const fatOffset = 512;
  for (var i = 0; i < 128; i++) {
    bd.setUint32(fatOffset + i * 4, 0xFFFFFFFF, Endian.little);
  }
  bd.setUint32(fatOffset + 0 * 4, 0xFFFFFFFD, Endian.little); // FAT sector
  bd.setUint32(fatOffset + 1 * 4, 0xFFFFFFFE, Endian.little); // Dir sector end
  for (var s = 2; s < 10; s++) {
    bd.setUint32(fatOffset + s * 4, s + 1, Endian.little);
  }
  bd.setUint32(fatOffset + 10 * 4, 0xFFFFFFFE, Endian.little); // Stream end

  // Sector 1 (offset 1024): Directory entries (4 x 128 bytes)
  void writeDirEntry(
    int entryIdx, {
    required String name,
    required int type,
    required int startSec,
    required int size,
  }) {
    final base = 1024 + entryIdx * 128;
    for (var i = 0; i < name.length; i++) {
      bd.setUint16(base + i * 2, name.codeUnitAt(i), Endian.little);
    }
    bd.setUint16(base + name.length * 2, 0, Endian.little);
    bd.setUint16(base + 64, (name.length + 1) * 2, Endian.little);
    ole[base + 66] = type;
    ole[base + 67] = 1;
    bd.setUint32(base + 68, 0xFFFFFFFF, Endian.little);
    bd.setUint32(base + 72, 0xFFFFFFFF, Endian.little);
    bd.setUint32(base + 76, entryIdx == 0 ? 1 : 0xFFFFFFFF, Endian.little);
    bd.setUint32(base + 116, startSec, Endian.little);
    bd.setUint32(base + 120, size, Endian.little);
  }

  writeDirEntry(0, name: 'Root Entry', type: 5, startSec: 0xFFFFFFFE, size: 0);
  writeDirEntry(
    1,
    name: 'Workbook',
    type: 2,
    startSec: 2,
    size: patched.length,
  );

  // Sectors 2..10 (offset 1536): BIFF8 Workbook stream
  ole.setRange(1536, 1536 + patched.length, patched);
  return ole;
}
