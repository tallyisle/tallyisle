import 'dart:convert';
import 'dart:io' show ZLibCodec;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/csv_excel_codec.dart';
import 'package:tallyisle/domain/rules/csv_excel_rules.dart';
import 'package:tallyisle/domain/rules/haohao_import_rules.dart';
import 'package:tallyisle/domain/rules/qianji_import_rules.dart';

Uint8List _buildZipArchive(
  Map<String, Uint8List> files, {
  bool useGbkNames = false,
  int? forgedDeclaredUncompSize,
}) {
  final localBuf = BytesBuilder(copy: false);
  final cdBuf = BytesBuilder(copy: false);
  final rawDeflate = ZLibCodec(raw: true);
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

  for (final entry in files.entries) {
    final nameBytes = useGbkNames
        ? GbkCodec.encode(entry.key)
        : Uint8List.fromList(utf8.encode(entry.key));
    final flags = useGbkNames ? 0x0000 : 0x0800;
    final rawData = entry.value;
    final compData = Uint8List.fromList(rawDeflate.encode(rawData));
    final localOffset = localBuf.length;
    final uncompLen = forgedDeclaredUncompSize ?? rawData.length;

    // Local file header
    writeU32(localBuf, 0x04034b50);
    writeU16(localBuf, 20);
    writeU16(localBuf, flags);
    writeU16(localBuf, 8); // deflate
    writeU16(localBuf, 0);
    writeU16(localBuf, 0);
    writeU32(localBuf, 0); // crc32 (unused by reader)
    writeU32(localBuf, compData.length);
    writeU32(localBuf, uncompLen);
    writeU16(localBuf, nameBytes.length);
    writeU16(localBuf, 0);
    localBuf.add(nameBytes);
    localBuf.add(compData);

    // Central directory header
    writeU32(cdBuf, 0x02014b50);
    writeU16(cdBuf, 20);
    writeU16(cdBuf, 20);
    writeU16(cdBuf, flags);
    writeU16(cdBuf, 8);
    writeU16(cdBuf, 0);
    writeU16(cdBuf, 0);
    writeU32(cdBuf, 0);
    writeU32(cdBuf, compData.length);
    writeU32(cdBuf, uncompLen);
    writeU16(cdBuf, nameBytes.length);
    writeU16(cdBuf, 0);
    writeU16(cdBuf, 0);
    writeU16(cdBuf, 0);
    writeU16(cdBuf, 0);
    writeU32(cdBuf, 0);
    writeU32(cdBuf, localOffset);
    cdBuf.add(nameBytes);
    count++;
  }

  final cdOffset = localBuf.length;
  final cdBytes = cdBuf.takeBytes();
  localBuf.add(cdBytes);

  // EOCD
  writeU32(localBuf, 0x06054b50);
  writeU16(localBuf, 0);
  writeU16(localBuf, 0);
  writeU16(localBuf, count);
  writeU16(localBuf, count);
  writeU32(localBuf, cdBytes.length);
  writeU32(localBuf, cdOffset);
  writeU16(localBuf, 0);

  return localBuf.takeBytes();
}

Uint8List _fakePngBytes(int tag) => Uint8List.fromList([
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  tag & 0xFF,
  (tag >> 8) & 0xFF,
]);

Uint8List _buildXlsxWithDrawings({
  required List<List<String>> rows,
  required List<({int row0, int col0, int colOff, bool oneCell, Uint8List img})>
  anchors,
}) {
  String esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  String colRef(int c) {
    var n = c + 1;
    var out = '';
    while (n > 0) {
      final rem = (n - 1) % 26;
      out = '${String.fromCharCode(0x41 + rem)}$out';
      n = (n - 1) ~/ 26;
    }
    return out;
  }

  final sheetSb = StringBuffer()
    ..write(
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
      '<sheetData>',
    );
  for (var r = 0; r < rows.length; r++) {
    final rowNum = r + 1;
    sheetSb.write('<row r="$rowNum">');
    for (var c = 0; c < rows[r].length; c++) {
      final v = rows[r][c];
      if (v.isEmpty) continue;
      sheetSb.write(
        '<c r="${colRef(c)}$rowNum" t="inlineStr"><is><t>${esc(v)}</t></is></c>',
      );
    }
    sheetSb.write('</row>');
  }
  sheetSb.write('</sheetData>');
  if (anchors.isNotEmpty) {
    sheetSb.write('<drawing r:id="rId1"/>');
  }
  sheetSb.write('</worksheet>');

  final files = <String, Uint8List>{
    '[Content_Types].xml': Uint8List.fromList(utf8.encode('<Types/>')),
    'xl/workbook.xml': Uint8List.fromList(
      utf8.encode(
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        '<sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets>'
        '</workbook>',
      ),
    ),
    'xl/_rels/workbook.xml.rels': Uint8List.fromList(
      utf8.encode(
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
        '</Relationships>',
      ),
    ),
    'xl/worksheets/sheet1.xml': Uint8List.fromList(
      utf8.encode(sheetSb.toString()),
    ),
  };

  if (anchors.isNotEmpty) {
    files['xl/worksheets/_rels/sheet1.xml.rels'] = Uint8List.fromList(
      utf8.encode(
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/drawing" Target="../drawings/drawing1.xml"/>'
        '</Relationships>',
      ),
    );

    final drawSb = StringBuffer()
      ..write(
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<xdr:wsDr xmlns:xdr="http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing" '
        'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
      );
    final relsSb = StringBuffer()
      ..write(
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">',
      );

    for (var i = 0; i < anchors.length; i++) {
      final a = anchors[i];
      final rId = 'rId${i + 1}';
      final mediaFile = 'image${i + 1}.png';
      files['xl/media/$mediaFile'] = a.img;
      relsSb.write(
        '<Relationship Id="$rId" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/$mediaFile"/>',
      );
      final tag = a.oneCell ? 'oneCellAnchor' : 'twoCellAnchor';
      drawSb.write(
        '<xdr:$tag>'
        '<xdr:from>'
        '<xdr:col>${a.col0}</xdr:col>'
        '<xdr:colOff>${a.colOff}</xdr:colOff>'
        '<xdr:row>${a.row0}</xdr:row>'
        '<xdr:rowOff>0</xdr:rowOff>'
        '</xdr:from>',
      );
      if (a.oneCell) {
        drawSb.write('<xdr:ext cx="952500" cy="952500"/>');
      } else {
        drawSb.write(
          '<xdr:to><xdr:col>${a.col0}</xdr:col><xdr:colOff>952500</xdr:colOff>'
          '<xdr:row>${a.row0}</xdr:row><xdr:rowOff>952500</xdr:rowOff></xdr:to>',
        );
      }
      drawSb.write(
        '<xdr:pic><xdr:blipFill><a:blip r:embed="$rId"/></xdr:blipFill></xdr:pic>'
        '<xdr:clientData/>'
        '</xdr:$tag>',
      );
    }
    drawSb.write('</xdr:wsDr>');
    relsSb.write('</Relationships>');

    files['xl/drawings/drawing1.xml'] = Uint8List.fromList(
      utf8.encode(drawSb.toString()),
    );
    files['xl/drawings/_rels/drawing1.xml.rels'] = Uint8List.fromList(
      utf8.encode(relsSb.toString()),
    );
  }

  return _buildZipArchive(files);
}

void main() {
  group('64 MiB Cap, OOXML Embedded Images & ZIP Bundle Extractor', () {
    test('enforces 64 MiB ceiling with exact message', () {
      expect(maxImportFileBytes, 64 * 1024 * 1024);
      final overLimit = Uint8List(maxImportFileBytes + 1);
      expect(
        () => guardImportFileBytes(overLimit),
        throwsA(
          isA<Failure>().having((f) => f.message, 'message', '文件大小不能超过64M'),
        ),
      );
    });

    test(
      'extractXlsxEmbeddedImagesByRow parses twoCellAnchor & oneCellAnchor, orders by colOff, and caps at 9/row',
      () {
        final xlsxBytes = _buildXlsxWithDrawings(
          rows: [
            qianjiHeader19,
            ['1', '2026-03-15 12:00:00', '', '餐饮', '', '支出', '25.00'],
            ['2', '2026-03-16 12:00:00', '', '购物', '', '支出', '88.00'],
          ],
          anchors: [
            // Row 1: intentionally out-of-order colOff to verify deterministic sorting
            (
              row0: 1,
              col0: 17,
              colOff: 200,
              oneCell: false,
              img: _fakePngBytes(2),
            ),
            (
              row0: 1,
              col0: 17,
              colOff: 50,
              oneCell: true,
              img: _fakePngBytes(1),
            ),
            // Row 2: 11 images -> must cap at 9
            for (var k = 1; k <= 11; k++)
              (
                row0: 2,
                col0: 17,
                colOff: k * 10,
                oneCell: false,
                img: _fakePngBytes(100 + k),
              ),
          ],
        );

        final byRow = extractXlsxEmbeddedImagesByRow(xlsxBytes);
        expect(byRow.keys, containsAll([1, 2]));
        expect(byRow[1], hasLength(2));
        expect(byRow[1]![0], _fakePngBytes(1));
        expect(byRow[1]![1], _fakePngBytes(2));
        expect(byRow[2], hasLength(9));
        expect(byRow[2]!.first, _fakePngBytes(101));
        expect(byRow[2]!.last, _fakePngBytes(109));
      },
    );

    test(
      'extractZipSpreadsheetBundle unpacks GBK Chinese filenames, indexes images, and guards >128 MiB bombs',
      () {
        final csvBytes = encodeCsvBytes([
          haohaoHeader30,
          [
            '2026-03-15 09:30:00',
            '45.00',
            '日常账本',
            '支出',
            '餐饮',
            '早餐',
            '包子豆浆',
            '早餐 日常',
            '微信钱包',
            '',
            '',
            '',
            '否',
            '',
            '',
            '',
            '',
            '',
            '',
            '否',
            '否',
            '账单图片/小票A.png;./pic_b.png',
          ],
        ]);
        final imgA = _fakePngBytes(11);
        final imgB = _fakePngBytes(22);
        final zipBytes = _buildZipArchive({
          '好好记账导出/账单明细.csv': csvBytes,
          '好好记账导出/账单图片/小票A.png': imgA,
          '好好记账导出/pic_b.png': imgB,
        }, useGbkNames: true);

        final bundle = extractZipSpreadsheetBundle(zipBytes);
        expect(bundle.tableExtension, 'csv');
        expect(bundle.tableFileName, '好好记账导出/账单明细.csv');
        expect(bundle.resolveImage('账单图片/小票A.png'), imgA);
        expect(bundle.resolveImage('./pic_b.png'), imgB);
        expect(bundle.resolveImage('小票A.png'), imgA);

        // 1. Guard declared uncompressed > 128 MiB
        final bombZip = _buildZipArchive({
          'bills.csv': csvBytes,
        }, forgedDeclaredUncompSize: maxUncompressedArchiveBytes + 1024);
        expect(
          () => extractZipSpreadsheetBundle(bombZip),
          throwsA(
            isA<Failure>().having(
              (f) => f.message,
              'message',
              contains('解压体积超出安全上限'),
            ),
          ),
        );

        // 2. Guard streaming Deflate Zip Bomb with forged small central-directory
        //    `uncompSize = 10` whose actual deflated stream expands > 128 MiB!
        final actualBombPayload = Uint8List(
          maxUncompressedArchiveBytes + 2 * 1024 * 1024,
        );
        final streamingBombZip = _buildZipArchive({
          'bills.csv': actualBombPayload,
        }, forgedDeclaredUncompSize: 10);
        expect(streamingBombZip.length, lessThan(512 * 1024));
        expect(
          () => extractZipSpreadsheetBundle(streamingBombZip),
          throwsA(
            isA<Failure>().having(
              (f) => f.message,
              'message',
              contains('解压体积超出安全上限'),
            ),
          ),
        );
      },
    );
  });

  group('钱迹 Qianji v4.5.5 & Legacy CSV/XLSX/JSON Rules', () {
    test('normalizes currency symbols and Qianji bill flags & tags', () {
      expect(normalizeImportCurrencyCode('￥'), 'CNY');
      expect(normalizeImportCurrencyCode('¥'), 'CNY');
      expect(normalizeImportCurrencyCode(r'$'), 'USD');
      expect(normalizeImportCurrencyCode('€'), 'EUR');
      expect(normalizeImportCurrencyCode(r'HK$'), 'HKD');
      expect(normalizeImportCurrencyCode('JP¥'), 'JPY');
      expect(normalizeImportCurrencyCode('£'), 'GBP');
      expect(normalizeImportCurrencyCode(r'NT$'), 'TWD');

      expect(parseQianjiBillFlags('nc&nb'), (true, true));
      expect(parseQianjiBillFlags('不计收支&预算'), (true, true));
      expect(parseQianjiBillFlags('Not in statistics&budgets'), (true, true));
      expect(parseQianjiBillFlags('nc'), (true, false));
      expect(parseQianjiBillFlags('不计收支'), (true, false));
      expect(parseQianjiBillFlags('nb'), (false, true));
      expect(parseQianjiBillFlags('不计预算'), (false, true));

      expect(parseQianjiTags('#出差#餐饮, 团建，报销'), ['出差', '餐饮', '团建', '报销']);
    });

    test(
      'maps 19-col Qianji CSV including newest-first linked reimburseReceipt, auto-hasbx, linked/standalone refund, arrow transfer + fee, and all 6 debt types',
      () {
        final rows = <List<String>>[
          qianjiHeader19,
          // 1. Linked `报销记录` appearing BEFORE its parent `报销` row (newest-first export!)
          [
            'qj_reimb_rec_1',
            '2026-03-20 15:00:00',
            '差旅账本',
            '差旅',
            '高铁',
            '报销记录(1)',
            '350.00',
            '￥',
            '招商银行',
            '',
            '财务打款',
            '',
            '',
            '',
            'me',
            '',
            '#差旅',
            '',
            'qj_parent_bx_1',
          ],
          // 2. Parent `报销` row (`qj_parent_bx_1`)
          [
            'qj_parent_bx_1',
            '2026-03-18 09:00:00',
            '差旅账本',
            '差旅',
            '高铁',
            '报销',
            '350.00',
            '￥',
            '花呗',
            '',
            '高铁票垫付',
            '是',
            '',
            '10.00',
            'me',
            'nb',
            '#差旅,#高铁',
            '',
            '',
          ],
          // 3. Auto-reimbursed `报销` row (`已报销 == '是'`, no explicit `报销记录` row)
          [
            'qj_auto_bx_2',
            '2026-03-17 20:00',
            '差旅账本',
            '餐饮',
            '',
            '报销',
            '88.50',
            'CNY',
            '微信钱包',
            '',
            '客户晚餐',
            '是',
            '',
            '',
            'me',
            '',
            '',
            '',
            '',
          ],
          // 4. Linked `退款` row appearing BEFORE its parent `支出` row
          [
            'qj_refund_1',
            '2026-03-16 14:00:00',
            '日常账本',
            '购物',
            '数码',
            '退款',
            '50.00',
            '¥',
            '招商银行',
            '',
            '部分退差价',
            '',
            '',
            '',
            'me',
            '',
            '',
            '',
            'qj_spend_1',
          ],
          // 5. Parent `支出` row (`qj_spend_1`) with coupon & `nc&nb`
          [
            'qj_spend_1',
            '2026-03-15 10:30:00',
            '日常账本',
            '购物',
            '数码',
            '支出',
            '299.00',
            '¥',
            '招商银行',
            '',
            '蓝牙耳机',
            '',
            '',
            '20.00',
            'me',
            'nc&nb',
            '#数码,耳机',
            '',
            '',
          ],
          // 6. Standalone `退款·服饰` without matching parent
          [
            'qj_standalone_rf',
            '2026-03-14 11:00:00',
            '日常账本',
            '',
            '',
            '退款·服饰',
            '120.00',
            'CNY',
            '支付宝',
            '',
            '上月退货',
            '',
            '',
            '',
            'me',
            '',
            '',
            '',
            'missing_parent_id',
          ],
          // 7. Transfer with `'->'` in `账户1` and empty `账户2` + `手续费`
          [
            'qj_tf_1',
            '2026-03-13 09:00:00',
            '日常账本',
            '',
            '',
            '还款',
            '1000.00',
            'CNY',
            '招商银行->花呗',
            '',
            '还花呗',
            '',
            '1.50',
            '',
            'me',
            '',
            '',
            '',
            '',
          ],
          // 8–13. Debt types: 借入, 债务-还款, 债务-利息支出, 借出, 债务-收款, 债务-利息收入
          [
            'qj_d1',
            '2026-03-10 10:00:00',
            '日常账本',
            '',
            '',
            '债务-借入',
            '5000.00',
            'CNY',
            '老王',
            '招商银行',
            '周转借入',
            '',
            '',
            '',
            '',
            '',
            '',
            '',
            '',
          ],
          [
            'qj_d2',
            '2026-03-11 10:00:00',
            '日常账本',
            '',
            '',
            '债务-还款',
            '2000.00',
            'CNY',
            '招商银行',
            '老王',
            '部分归还',
            '',
            '',
            '',
            '',
            '',
            '',
            '',
            '',
          ],
          [
            'qj_d3',
            '2026-03-11 10:05:00',
            '日常账本',
            '',
            '',
            '债务-利息支出',
            '50.00',
            'CNY',
            '招商银行',
            '老王',
            '借款利息',
            '',
            '',
            '',
            '',
            '',
            '',
            '',
            '',
          ],
          [
            'qj_d4',
            '2026-03-12 10:00:00',
            '日常账本',
            '',
            '',
            '债务-借出',
            '3000.00',
            'CNY',
            '招商银行',
            '小李',
            '借给小李',
            '',
            '',
            '',
            '',
            '',
            '',
            '',
            '',
          ],
          [
            'qj_d5',
            '2026-03-12 18:00:00',
            '日常账本',
            '',
            '',
            '债务-收款',
            '1000.00',
            'CNY',
            '小李',
            '招商银行',
            '小李归还',
            '',
            '',
            '',
            '',
            '',
            '',
            '',
            '',
          ],
          [
            'qj_d6',
            '2026-03-12 18:05:00',
            '日常账本',
            '',
            '',
            '债务-利息收入',
            '30.00',
            'CNY',
            '小李',
            '招商银行',
            '小李付息',
            '',
            '',
            '',
            '',
            '',
            '',
            '',
            '',
          ],
        ];

        final sheet = decodeSpreadsheetFile(
          fileName: 'qianji_export.csv',
          bytes: encodeCsvBytes(rows),
        );
        final analysis = analyzeSpreadsheetImport(
          spreadsheet: sheet,
          existingAccounts: const [
            ImportAccountRef(id: 10, name: '招商银行', currency: 'CNY'),
          ],
        );

        expect(analysis.platformName, '钱迹');
        expect(analysis.defaultAutoCreateAccounts, isTrue);
        expect(analysis.failRows, isEmpty);
        expect(analysis.mergedChildRowCount, 2);
        // 13 non-empty data rows - 2 merged children = 11 parent ValidImportRows; totalRecordCount == 13!
        expect(analysis.validRows, hasLength(11));
        expect(analysis.totalRecordCount, 13);
        expect(
          analysis.unknownAssets,
          containsAll(['花呗', '微信钱包', '支付宝', '老王', '小李']),
        );

        // Check parent `报销` (`qj_parent_bx_1`): linked to explicit `qj_reimb_rec_1` (NOT double-created by `已报销==是`)!
        final bx1 = analysis.validRows.firstWhere(
          (r) => r.sourceRecordKey == 'qj_parent_bx_1',
        );
        expect(bx1.type, RecordType.reimbursable);
        expect(bx1.assetName, '花呗');
        // L-01: discount applies strictly to expense & income, clamped to null on reimbursable
        expect(bx1.discountMinor, isNull);
        expect(bx1.excludeBudget, isTrue);
        expect(bx1.excludeExIn, isFalse);
        expect(bx1.reimburseChildren, hasLength(1));
        expect(bx1.reimburseChildren.single.assetName, '招商银行');
        expect(bx1.reimburseChildren.single.moneyMinor, BigInt.from(35000));
        expect(bx1.reimburseChildren.single.remark, '财务打款');

        // Check auto-reimbursed `报销` (`qj_auto_bx_2`): `recordTime + 1` on same account
        final bx2 = analysis.validRows.firstWhere(
          (r) => r.sourceRecordKey == 'qj_auto_bx_2',
        );
        expect(bx2.type, RecordType.reimbursable);
        expect(bx2.reimburseChildren, hasLength(1));
        expect(bx2.reimburseChildren.single.recordTime, bx2.recordTime + 1);
        expect(bx2.reimburseChildren.single.assetName, '微信钱包');
        expect(bx2.reimburseChildren.single.moneyMinor, BigInt.from(8850));

        // Check `支出` (`qj_spend_1`) with linked refund child + coupon + `nc&nb`
        final spend1 = analysis.validRows.firstWhere(
          (r) => r.sourceRecordKey == 'qj_spend_1',
        );
        expect(spend1.type, RecordType.expense);
        expect(spend1.moneyMinor, BigInt.from(29900));
        expect(spend1.discountMinor, BigInt.from(2000));
        expect(spend1.excludeExIn, isTrue);
        expect(spend1.excludeBudget, isTrue);
        expect(spend1.tags, ['数码', '耳机']);
        expect(spend1.refundChildren, hasLength(1));
        expect(spend1.refundChildren.single.moneyMinor, BigInt.from(5000));

        // Check standalone `退款·服饰`
        final standaloneRf = analysis.validRows.firstWhere(
          (r) => r.sourceRecordKey == 'qj_standalone_rf',
        );
        expect(standaloneRf.type, RecordType.expense);
        expect(standaloneRf.moneyMinor, BigInt.from(-12000));
        expect(standaloneRf.parentCategoryName, '服饰');

        // Check `->` transfer + fee
        final tf = analysis.validRows.firstWhere(
          (r) => r.sourceRecordKey == 'qj_tf_1',
        );
        expect(tf.type, RecordType.transfer);
        expect(tf.assetName, '招商银行');
        expect(tf.toAssetName, '花呗');
        expect(tf.feeMinor, BigInt.from(150));

        // Check all 6 debt rows
        final d1 = analysis.validRows.firstWhere(
          (r) => r.sourceRecordKey == 'qj_d1',
        );
        expect(d1.type, RecordType.borrowIn);
        expect(d1.debtSubType, AssetType.debtBorrow);
        expect(d1.debtName, '老王');
        expect(d1.assetName, '招商银行');

        final d2 = analysis.validRows.firstWhere(
          (r) => r.sourceRecordKey == 'qj_d2',
        );
        expect(d2.type, RecordType.repay);
        expect(d2.debtSubType, AssetType.debtBorrow);
        expect(d2.debtName, '老王');
        expect(d2.assetName, '招商银行');

        final d3 = analysis.validRows.firstWhere(
          (r) => r.sourceRecordKey == 'qj_d3',
        );
        expect(d3.type, RecordType.debtInterest);
        expect(d3.subType, RecordDirection.expense);

        final d4 = analysis.validRows.firstWhere(
          (r) => r.sourceRecordKey == 'qj_d4',
        );
        expect(d4.type, RecordType.lendOut);
        expect(d4.debtSubType, AssetType.debtLend);
        expect(d4.debtName, '小李');
        expect(d4.assetName, '招商银行');

        final d5 = analysis.validRows.firstWhere(
          (r) => r.sourceRecordKey == 'qj_d5',
        );
        expect(d5.type, RecordType.collect);
        expect(d5.debtSubType, AssetType.debtLend);

        final d6 = analysis.validRows.firstWhere(
          (r) => r.sourceRecordKey == 'qj_d6',
        );
        expect(d6.type, RecordType.debtInterest);
        expect(d6.subType, RecordDirection.income);
      },
    );

    test(
      'parses Qianji Bill.toExportJson with exact decimal strings (no double drift) and 钱迹账户#<id> mapping',
      () {
        const jsonExport = '''
[
  {
    "key": "json_bx_1",
    "date": "2026-04-01 12:30:00",
    "category": "差旅 / 机票",
    "type": "Reimburse",
    "money": 12345678901.23,
    "currency": "\$",
    "asset": 1088,
    "from": 0,
    "target": -1,
    "remark": "国际航班",
    "hasbx": 1,
    "fee": 0,
    "coupon": 50.05,
    "username": "alice",
    "billflag": "Not in statistics",
    "images": ["https://oss.qianjiapp.com/remote.jpg"],
    "sourceid": ""
  },
  {
    "key": "json_tf_1",
    "date": "2026-04-02 09:15:00",
    "category": "",
    "type": "Transfer",
    "money": 500.10,
    "currency": "CNY",
    "asset": 0,
    "from": 2001,
    "target": 2002,
    "remark": "内部划转",
    "hasbx": 0,
    "fee": 2.35,
    "coupon": 0,
    "billflag": ""
  },
  {
    "key": "json_spend_1",
    "date": "2026-04-03 18:20:00",
    "category": "购物 / 图书",
    "type": "Spend",
    "money": 199.90,
    "currency": "￥",
    "asset": "招商银行",
    "remark": "技术书籍",
    "hasbx": 0,
    "fee": 0,
    "coupon": 50.05,
    "billflag": ""
  }
]
''';
        final analysis = analyzeQianjiJsonImport(
          jsonText: jsonExport,
          existingAccounts: const [],
        );
        expect(analysis.platformName, '钱迹');
        expect(analysis.defaultAutoCreateAccounts, isTrue);
        expect(analysis.failRows, isEmpty);
        expect(analysis.validRows, hasLength(3));

        final r0 = analysis.validRows[0];
        expect(r0.type, RecordType.reimbursable);
        expect(r0.moneyMinor, BigInt.parse('1234567890123'));
        expect(
          r0.discountMinor,
          isNull,
        ); // L-01: clamped to null on reimbursable
        expect(r0.currencyCode, 'USD');
        expect(r0.assetName, '钱迹账户#1088');
        expect(r0.parentCategoryName, '差旅');
        expect(r0.subCategoryName, '机票');
        expect(r0.excludeExIn, isTrue);
        expect(r0.excludeBudget, isFalse);
        expect(r0.images, isEmpty); // remote URL safely skipped
        expect(r0.reimburseChildren, hasLength(1));
        expect(
          r0.reimburseChildren.single.moneyMinor,
          BigInt.parse('1234567890123'),
        );

        final r1 = analysis.validRows[1];
        expect(r1.type, RecordType.transfer);
        expect(r1.assetName, '钱迹账户#2001');
        expect(r1.toAssetName, '钱迹账户#2002');
        expect(r1.feeMinor, BigInt.from(235));

        final r2 = analysis.validRows[2];
        expect(r2.type, RecordType.expense);
        expect(r2.moneyMinor, BigInt.from(19990));
        expect(r2.discountMinor, BigInt.from(5005));
      },
    );
  });

  group('好好记账 Haohaojizhang v1.22.5 30-Col & Custom Subset Rules', () {
    test(
      'maps 30-col Haohao sheet: whitespace/comma tags, 原价 discount, reimbursable + child, refund child, 取钱/存钱 transfer, debt, and multi-currency CurrencySnapshot',
      () {
        final rows = <List<String>>[
          haohaoHeader30,
          // 1. Expense with `原价 > 金额`, `退款金额` + `退款日期`, whitespace+comma tags, foreign currency settled in CNY
          [
            '2026-04-10 13:20:00', // 日期
            '72.00', // 金额 (settled CNY)
            '旅行账本', // 账本
            '支出', // 类型
            '餐饮', // 分类
            '咖啡', // 子分类
            '东京蓝瓶咖啡', // 备注
            '旅行 日本,咖啡 #探店', // 标签
            '招商银行', // 账户
            '', // 转入账户
            '', // 债务人
            '', // 转账手续费
            '否', // 是否为报销
            '', // 账单状态
            '', // 报销金额
            '', // 报销日期
            '12.00', // 退款金额
            '2026-04-11 10:00:00', // 退款日期
            '80.00', // 原价 -> discount = 8.00
            '是', // 不计入预算
            '否', // 不计入收支
            '', // 账单图片
            '10.00', // 原始金额
            'USD', // 币种
            'CNY', // 本位币
            '7.20', // 汇率
            '', // 转入金额
            '', // 转入币种
            '', // 转入本位币
            '', // 转入汇率
          ],
          // 2. Reimbursable (`是否为报销 == 是`) + `报销金额` & `报销日期`
          [
            '2026-04-12 09:00:00',
            '500.00',
            '工作账本',
            '支出',
            '办公',
            '耗材',
            '打印纸垫付',
            '办公 报销',
            '支付宝',
            '',
            '',
            '',
            '是',
            '已报销',
            '480.00',
            '2026-04-15 18:00:00',
            '',
            '',
            '',
            '否',
            '是',
            '',
            '',
            'CNY',
            'CNY',
            '1',
            '',
            '',
            '',
            '',
          ],
          // 3. Cross-currency Transfer (`存钱`) with `转账手续费`
          [
            '2026-04-13 10:00:00',
            '720.00',
            '旅行账本',
            '存钱',
            '转账',
            '',
            '购汇转入美元卡',
            '',
            '招商银行',
            '美元储蓄卡',
            '',
            '5.00',
            '否',
            '',
            '',
            '',
            '',
            '',
            '',
            '否',
            '否',
            '',
            '720.00',
            'CNY',
            'CNY',
            '1',
            '100.00',
            'USD',
            'CNY',
            '7.20',
          ],
          // 4. Debt `还款` with `债务人` non-empty -> `RecordType.repay (7)` (NOT ordinary transfer!)
          [
            '2026-04-14 11:00:00',
            '1500.00',
            '日常账本',
            '还款',
            '债务',
            '',
            '归还借款',
            '',
            '招商银行',
            '',
            '张伟',
            '',
            '否',
            '',
            '',
            '',
            '',
            '',
            '',
            '否',
            '否',
            '',
            '',
            'CNY',
            'CNY',
            '1',
            '',
            '',
            '',
            '',
          ],
        ];

        final sheet = decodeSpreadsheetFile(
          fileName: 'haohao_30col.csv',
          bytes: encodeCsvBytes(rows),
        );
        final analysis = analyzeSpreadsheetImport(
          spreadsheet: sheet,
          existingAccounts: const [],
        );

        expect(analysis.platformName, '好好记账');
        expect(analysis.defaultAutoCreateAccounts, isTrue);
        expect(analysis.failRows, isEmpty);
        expect(analysis.validRows, hasLength(4));

        final r0 = analysis.validRows[0];
        expect(r0.type, RecordType.expense);
        expect(r0.moneyMinor, BigInt.from(7200));
        // 800 CNY discount / 7.20 = 111 USD minor units in sourceCode ('USD')
        expect(r0.discountMinor, BigInt.from(111));
        expect(r0.tags, ['旅行', '日本', '咖啡', '探店']);
        expect(r0.excludeBudget, isTrue);
        expect(r0.excludeExIn, isFalse);
        expect(r0.explicitCurrencySnapshot, isNotNull);
        expect(r0.explicitCurrencySnapshot!.sourceCode, 'USD');
        expect(r0.explicitCurrencySnapshot!.sourceGross, BigInt.from(1111));
        expect(r0.explicitCurrencySnapshot!.assetCode, 'CNY');
        expect(r0.explicitCurrencySnapshot!.assetNet, BigInt.from(7200));
        expect(r0.explicitCurrencySnapshot!.assetDiscount, BigInt.from(800));
        expect(r0.explicitCurrencySnapshot!.baseDiscount, BigInt.from(800));
        expect(r0.refundChildren, hasLength(1));
        expect(r0.refundChildren.single.moneyMinor, BigInt.from(1200));

        final r1 = analysis.validRows[1];
        expect(r1.type, RecordType.reimbursable);
        expect(r1.excludeExIn, isTrue);
        expect(r1.reimburseChildren, hasLength(1));
        expect(r1.reimburseChildren.single.moneyMinor, BigInt.from(48000));

        final r2 = analysis.validRows[2];
        expect(r2.type, RecordType.transfer);
        expect(r2.feeMinor, BigInt.from(500));
        expect(r2.moneyMinor, BigInt.from(72000));
        expect(r2.targetMoneyMinor, BigInt.from(10000));
        expect(r2.explicitCurrencySnapshot, isNotNull);
        expect(r2.explicitCurrencySnapshot!.sourceCode, 'CNY');
        expect(r2.explicitCurrencySnapshot!.assetCode, 'USD');
        expect(r2.explicitCurrencySnapshot!.assetNet, BigInt.from(10000));

        final r3 = analysis.validRows[3];
        expect(r3.type, RecordType.repay);
        expect(r3.debtSubType, AssetType.debtBorrow);
        expect(r3.debtName, '张伟');
        expect(r3.assetName, '招商银行');
      },
    );

    test(
      'matches custom Haohao column subset without colliding with Template v1-v3',
      () {
        final subsetRows = <List<String>>[
          ['日期', '金额', '类型', '分类', '子分类', '账户', '原价'],
          ['2026-04-20 08:30', '18.00', '支出', '餐饮', '早餐', '现金', '22.00'],
        ];
        final sheet = decodeSpreadsheetFile(
          fileName: 'haohao_subset.csv',
          bytes: encodeCsvBytes(subsetRows),
        );
        final analysis = analyzeSpreadsheetImport(
          spreadsheet: sheet,
          existingAccounts: const [],
        );
        expect(analysis.platformName, '好好记账');
        expect(analysis.validRows, hasLength(1));
        expect(analysis.validRows.single.discountMinor, BigInt.from(400));

        // Verify matched existing CNY account (`currency == null`) resolves as `'CNY'` on USD bill
        final fxSubset = <List<String>>[
          ['日期', '金额', '类型', '分类', '账户', '原始金额', '币种', '本位币', '汇率'],
          [
            '2026-04-21 09:00',
            '25.00',
            '支出',
            '购物',
            '招商银行',
            '25.00',
            'USD',
            'CNY',
            '7.20',
          ],
        ];
        final fxAnalysis = analyzeSpreadsheetImport(
          spreadsheet: decodeSpreadsheetFile(
            fileName: 'haohao_fx_null_curr.csv',
            bytes: encodeCsvBytes(fxSubset),
          ),
          existingAccounts: const [ImportAccountRef(id: 1, name: '招商银行')],
        );
        final fxRow = fxAnalysis.validRows.single;
        expect(fxRow.moneyMinor, BigInt.from(18000));
        expect(fxRow.explicitCurrencySnapshot!.sourceCode, 'USD');
        expect(fxRow.explicitCurrencySnapshot!.assetCode, 'CNY');
        expect(fxRow.explicitCurrencySnapshot!.assetNet, BigInt.from(18000));
      },
    );
  });
}
