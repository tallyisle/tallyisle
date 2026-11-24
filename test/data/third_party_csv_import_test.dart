import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/data/csv_import/csv_excel_service.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/tools/bill_attachment_service.dart';
import 'package:tallyisle/domain/ledger/record_extra.dart';
import 'package:tallyisle/domain/ledger/record_relations.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/csv_excel_codec.dart';
import 'package:tallyisle/domain/rules/csv_excel_rules.dart';
import 'package:tallyisle/domain/rules/debt_rules.dart';
import 'package:tallyisle/domain/rules/haohao_import_rules.dart';
import 'package:tallyisle/domain/rules/qianji_import_rules.dart';
import 'package:tallyisle/features/csv_transfer/csv_import_page.dart';
import 'package:tallyisle/platform/files.dart';

Uint8List _buildZipArchive(Map<String, Uint8List> files) {
  final localBuf = BytesBuilder(copy: false);
  final cdBuf = BytesBuilder(copy: false);
  final rawDeflate = ZLibCodec(raw: true);
  var count = 0;

  void u16(BytesBuilder b, int v) {
    b.addByte(v & 0xFF);
    b.addByte((v >> 8) & 0xFF);
  }

  void u32(BytesBuilder b, int v) {
    b.addByte(v & 0xFF);
    b.addByte((v >> 8) & 0xFF);
    b.addByte((v >> 16) & 0xFF);
    b.addByte((v >> 24) & 0xFF);
  }

  for (final entry in files.entries) {
    final nameBytes = Uint8List.fromList(utf8.encode(entry.key));
    final raw = entry.value;
    final comp = Uint8List.fromList(rawDeflate.encode(raw));
    final localOff = localBuf.length;

    u32(localBuf, 0x04034b50);
    u16(localBuf, 20);
    u16(localBuf, 0x0800);
    u16(localBuf, 8);
    u16(localBuf, 0);
    u16(localBuf, 0);
    u32(localBuf, 0);
    u32(localBuf, comp.length);
    u32(localBuf, raw.length);
    u16(localBuf, nameBytes.length);
    u16(localBuf, 0);
    localBuf.add(nameBytes);
    localBuf.add(comp);

    u32(cdBuf, 0x02014b50);
    u16(cdBuf, 20);
    u16(cdBuf, 20);
    u16(cdBuf, 0x0800);
    u16(cdBuf, 8);
    u16(cdBuf, 0);
    u16(cdBuf, 0);
    u32(cdBuf, 0);
    u32(cdBuf, comp.length);
    u32(cdBuf, raw.length);
    u16(cdBuf, nameBytes.length);
    u16(cdBuf, 0);
    u16(cdBuf, 0);
    u16(cdBuf, 0);
    u16(cdBuf, 0);
    u32(cdBuf, 0);
    u32(cdBuf, localOff);
    cdBuf.add(nameBytes);
    count++;
  }

  final cdOff = localBuf.length;
  final cdBytes = cdBuf.takeBytes();
  localBuf.add(cdBytes);

  u32(localBuf, 0x06054b50);
  u16(localBuf, 0);
  u16(localBuf, 0);
  u16(localBuf, count);
  u16(localBuf, count);
  u32(localBuf, cdBytes.length);
  u32(localBuf, cdOff);
  u16(localBuf, 0);
  return localBuf.takeBytes();
}

Uint8List _pngBytes(int seed) => Uint8List.fromList([
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  seed & 0xFF,
  (seed >> 8) & 0xFF,
]);

Uint8List _buildQianjiXlsxWithEmbeddedImages({
  required List<List<String>> rows,
  required Map<int, List<Uint8List>> imagesByRow0,
}) {
  String esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  String colName(int c) {
    var n = c + 1;
    var out = '';
    while (n > 0) {
      out = '${String.fromCharCode(0x41 + (n - 1) % 26)}$out';
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
    sheetSb.write('<row r="${r + 1}">');
    for (var c = 0; c < rows[r].length; c++) {
      if (rows[r][c].isEmpty) continue;
      sheetSb.write(
        '<c r="${colName(c)}${r + 1}" t="inlineStr"><is><t>${esc(rows[r][c])}</t></is></c>',
      );
    }
    sheetSb.write('</row>');
  }
  sheetSb.write('</sheetData>');
  if (imagesByRow0.isNotEmpty) {
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
        '<sheets><sheet name="钱迹账单" sheetId="1" r:id="rId1"/></sheets>'
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

  if (imagesByRow0.isNotEmpty) {
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
    final relSb = StringBuffer()
      ..write(
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">',
      );
    var idx = 0;
    for (final entry in imagesByRow0.entries) {
      for (var k = 0; k < entry.value.length; k++) {
        idx++;
        final rId = 'rId$idx';
        final mediaName = 'image$idx.png';
        files['xl/media/$mediaName'] = entry.value[k];
        relSb.write(
          '<Relationship Id="$rId" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/$mediaName"/>',
        );
        drawSb.write(
          '<xdr:twoCellAnchor>'
          '<xdr:from><xdr:col>17</xdr:col><xdr:colOff>${k * 95250}</xdr:colOff><xdr:row>${entry.key}</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:from>'
          '<xdr:to><xdr:col>17</xdr:col><xdr:colOff>${(k + 1) * 95250}</xdr:colOff><xdr:row>${entry.key}</xdr:row><xdr:rowOff>95250</xdr:rowOff></xdr:to>'
          '<xdr:pic><xdr:blipFill><a:blip r:embed="$rId"/></xdr:blipFill></xdr:pic>'
          '<xdr:clientData/>'
          '</xdr:twoCellAnchor>',
        );
      }
    }
    drawSb.write('</xdr:wsDr>');
    relSb.write('</Relationships>');
    files['xl/drawings/drawing1.xml'] = Uint8List.fromList(
      utf8.encode(drawSb.toString()),
    );
    files['xl/drawings/_rels/drawing1.xml.rels'] = Uint8List.fromList(
      utf8.encode(relSb.toString()),
    );
  }

  return _buildZipArchive(files);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<(AppDatabase, Directory, CsvExcelService, BillAttachmentService)>
  openServiceEnv() async {
    final db = AppDatabase(NativeDatabase.memory());
    final tempDir = await Directory.systemTemp.createTemp('ti_3p_import_');
    final attachDir = Directory(p.join(tempDir.path, 'attachments'));
    addTearDown(() async {
      await db.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });
    Future<Directory> dirProvider() async => attachDir;
    return (
      db,
      attachDir,
      CsvExcelService(db, attachmentsDirectoryProvider: dirProvider),
      BillAttachmentService(db, attachmentsDirectoryProvider: dirProvider),
    );
  }

  test(
    'Qianji XLSX with embedded images: auto-creates bank/credit/debt accounts, links fee + reimburseReceipt + refund children, and symmetrically undoes batch & attachments',
    () async {
      final (db, attachDir, csvService, attachService) = await openServiceEnv();

      // Create one manual bill referencing `sharedImg` so we verify `undoBatch`
      // deletes batch-only attachments while preserving shared attachments!
      final sharedImg = _pngBytes(777);
      final batchOnlyImg = _pngBytes(888);
      final sharedFileName = await attachService.saveImageBytes(
        bytes: sharedImg,
      );
      final cats = await db.select(db.recordCategories).get();
      final expCatId = cats.firstWhere((c) => c.type == 0).id;
      await db
          .into(db.records)
          .insert(
            RecordsCompanion.insert(
              recordId: 'manual-rec-1',
              type: RecordType.expense,
              moneyMinor: BigInt.from(1500),
              recordTime: DateTime(2026, 3, 1, 9).millisecondsSinceEpoch,
              recordCatId: Value(expCatId),
              accountBookId: 1,
              images: Value(sharedFileName),
            ),
          );

      final xlsxBytes = _buildQianjiXlsxWithEmbeddedImages(
        rows: [
          qianjiHeader19,
          // Row 1 (0-based 1): Expense on 招商银行 with refund child & embedded images
          [
            'exp_1',
            '2026-03-10 12:00:00',
            '日常账本',
            '餐饮',
            '午餐',
            '支出',
            '100.00',
            '￥',
            '招商银行',
            '',
            '聚餐',
            '',
            '',
            '10.00',
            '',
            '',
            '#聚餐',
            '',
            '',
          ],
          // Row 2: Linked refund child (`sourceid == exp_1`)
          [
            'rf_1',
            '2026-03-11 12:00:00',
            '日常账本',
            '餐饮',
            '午餐',
            '退款',
            '30.00',
            '￥',
            '招商银行',
            '',
            '退菜退款',
            '',
            '',
            '',
            '',
            '',
            '',
            '',
            'exp_1',
          ],
          // Row 3: Reimbursable paid by 招行信用卡 + linked reimburseReceipt into 招商银行
          [
            'bx_1',
            '2026-03-12 09:00:00',
            '日常账本',
            '差旅',
            '',
            '报销',
            '400.00',
            'CNY',
            '招行信用卡',
            '',
            '机票垫付',
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
            'bx_rec_1',
            '2026-03-15 16:00:00',
            '日常账本',
            '差旅',
            '',
            '报销记录',
            '400.00',
            'CNY',
            '招商银行',
            '',
            '公司报销入账',
            '',
            '',
            '',
            '',
            '',
            '',
            '',
            'bx_1',
          ],
          // Row 5: Repayment transfer 招商银行 -> 招行信用卡 + fee 2.00
          [
            'tf_1',
            '2026-03-16 10:00:00',
            '日常账本',
            '',
            '',
            '还款',
            '200.00',
            'CNY',
            '招商银行->招行信用卡',
            '',
            '信用卡还款',
            '',
            '2.00',
            '',
            '',
            '',
            '',
            '',
            '',
          ],
          // Row 6 & 7: Debt borrow 1000 from 老张 into 招商银行, then repay 400 + interest 10
          [
            'debt_b1',
            '2026-03-17 10:00:00',
            '日常账本',
            '',
            '',
            '债务-借入',
            '1000.00',
            'CNY',
            '老张',
            '招商银行',
            '临时借款',
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
            'debt_r1',
            '2026-03-18 10:00:00',
            '日常账本',
            '',
            '',
            '债务-还款',
            '400.00',
            'CNY',
            '招商银行',
            '老张',
            '归还部分本金',
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
            'debt_i1',
            '2026-03-18 10:05:00',
            '日常账本',
            '',
            '',
            '债务-利息支出',
            '10.00',
            'CNY',
            '招商银行',
            '老张',
            '支付利息',
            '',
            '',
            '',
            '',
            '',
            '',
            '',
            '',
          ],
        ],
        imagesByRow0: {
          1: [sharedImg, batchOnlyImg],
        },
      );

      final preview = await csvService.previewImport(
        fileName: 'qianji_full.xlsx',
        bytes: xlsxBytes,
        targetBookId: 1,
      );
      expect(preview.platformName, '钱迹');
      expect(preview.defaultAutoCreateAccounts, isTrue);
      expect(preview.failRows, isEmpty);

      final commit = await csvService.commitImport(
        commandId: 'commit-qj-xlsx',
        preview: preview,
        selectedBookId: 1,
      );
      expect(commit.createdAccountCount, 3); // 招商银行, 招行信用卡, 老张(debt)

      final allAssets = await db.select(db.assets).get();
      final cmb = allAssets.singleWhere((a) => a.name == '招商银行');
      final cmbCredit = allAssets.singleWhere((a) => a.name == '招行信用卡');
      final debtZhang = allAssets.singleWhere((a) => a.name == '老张');

      // Verify smart bank icon & credit/debt account types!
      expect(cmb.type, AssetType.normal);
      expect(cmb.icon, 'builtin:bank.cmb');
      expect(cmbCredit.type, AssetType.credit);
      expect(cmbCredit.icon, 'builtin:bank.cmb');
      expect(debtZhang.type, AssetType.debt);
      expect(debtZhang.subType, AssetType.debtBorrow);
      expect(debtZhang.isEffectiveAsset, 0); // counted in net worth

      // Verify exact minor-unit balances:
      // 招商银行: -100.00 (exp) + 30.00 (refund) + 400.00 (bx_rec) - 200.00 (tf) - 2.00 (fee)
      //          + 1000.00 (borrowIn) - 400.00 (repay) - 10.00 (interest) = +718.00 (71800)
      expect(cmb.balanceMinor, BigInt.from(71800));
      // 招行信用卡: -400.00 (reimbursable fromAssetId!) + 200.00 (repay transfer) = -200.00 (-20000)
      expect(cmbCredit.balanceMinor, BigInt.from(-20000));
      // 老张 (debtBorrow): borrowed 1000.00 - repaid 400.00 = remaining 600.00 (60000); interest ignored in principal!
      expect(debtZhang.balanceMinor, BigInt.from(60000));
      expect(debtZhang.initMoneyMinor, BigInt.from(100000));
      final loanInfo = LoanInfo.parse(debtZhang.loanInfo);
      expect(loanInfo.totalDebtMoneyMinor, BigInt.from(100000));

      // Verify ALL batch records (parents + type=12 + type=15 + refund child) carry `platformId == commit.batchId`
      // and bidirectional `rel_info` links!
      final batchRecords = await (db.select(
        db.records,
      )..where((t) => t.platformId.equals(commit.batchId))).get();
      // 6 parents + 1 refund child + 1 reimburseReceipt child + 1 fee child = 9 DB records!
      expect(batchRecords, hasLength(9));

      final reimbParent = batchRecords.singleWhere(
        (r) => r.type == RecordType.reimbursable,
      );
      expect(reimbParent.fromAssetId, cmbCredit.id);
      expect(reimbParent.assetId, noRef);
      final reimbChild = batchRecords.singleWhere(
        (r) => r.type == RecordType.reimburseReceipt,
      );
      expect(reimbChild.assetId, cmb.id);
      expect(
        RecordRelations.parse(
          reimbParent.relInfo,
        ).reimbursements!.children.single.billId,
        reimbChild.recordId,
      );
      expect(
        RecordRelations.parse(reimbChild.relInfo).reimbursements!.originId,
        reimbParent.recordId,
      );

      final refundChild = batchRecords.singleWhere(
        (r) => r.type == RecordType.expense && r.moneyMinor < BigInt.zero,
      );
      expect(refundChild.moneyMinor, BigInt.from(-3000));
      final expParent = batchRecords.singleWhere(
        (r) => r.type == RecordType.expense && r.moneyMinor > BigInt.zero,
      );
      expect(
        RecordRelations.parse(
          expParent.relInfo,
        ).refunds!.children.single.billId,
        refundChild.recordId,
      );
      expect(
        RecordRelations.parse(refundChild.relInfo).refunds!.originId,
        expParent.recordId,
      );

      // Verify both attachments exist on disk before undo
      final expImgNames = expParent.images!.split(',');
      expect(expImgNames, hasLength(2));
      final batchOnlyFileName = expImgNames.firstWhere(
        (n) => n != sharedFileName,
      );
      expect(
        await File(p.join(attachDir.path, batchOnlyFileName)).exists(),
        isTrue,
      );
      expect(
        await File(p.join(attachDir.path, sharedFileName)).exists(),
        isTrue,
      );

      // Undo batch -> verify 100% symmetric restoration!
      await csvService.undoBatch(
        commandId: 'undo-qj-xlsx',
        batchId: commit.batchId,
      );

      final remainingBatchRecs = await (db.select(
        db.records,
      )..where((t) => t.platformId.equals(commit.batchId))).get();
      expect(remainingBatchRecs, isEmpty);

      final cmbAfter = await (db.select(
        db.assets,
      )..where((t) => t.id.equals(cmb.id))).getSingle();
      final cmbCreditAfter = await (db.select(
        db.assets,
      )..where((t) => t.id.equals(cmbCredit.id))).getSingle();
      final debtAfter = await (db.select(
        db.assets,
      )..where((t) => t.id.equals(debtZhang.id))).getSingle();

      expect(cmbAfter.balanceMinor, BigInt.zero);
      expect(cmbCreditAfter.balanceMinor, BigInt.zero);
      expect(debtAfter.balanceMinor, BigInt.zero);
      expect(
        LoanInfo.parse(debtAfter.loanInfo).totalDebtMoneyMinor,
        BigInt.zero,
      );

      // Unreferenced batch-only attachment was deleted, while shared manual attachment survived!
      expect(
        await File(p.join(attachDir.path, batchOnlyFileName)).exists(),
        isFalse,
      );
      expect(
        await File(p.join(attachDir.path, sharedFileName)).exists(),
        isTrue,
      );
    },
  );

  test(
    'Haohao ZIP bundle + Qianji JSON import: foreign currency account auto-creation, CurrencySnapshot, and symmetric undo',
    () async {
      final (db, attachDir, csvService, _) = await openServiceEnv();

      final imgBytes = _pngBytes(555);
      final csvBytes = encodeCsvBytes([
        haohaoHeader30,
        [
          '2026-04-01 10:00:00',
          '25.00',
          '日常账本',
          '支出',
          '餐饮',
          '',
          '海外午餐',
          '美国 出差',
          '美元Visa卡',
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
          'imgs/receipt_us.png',
          '25.00',
          'USD',
          'CNY',
          '7.20',
          '',
          '',
          '',
          '',
        ],
      ]);
      final zipBytes = _buildZipArchive({
        'haohao_bills.csv': csvBytes,
        'imgs/receipt_us.png': imgBytes,
      });

      final preview = await csvService.previewImport(
        fileName: 'haohao_bundle.zip',
        bytes: zipBytes,
        targetBookId: 1,
      );
      expect(preview.platformName, '好好记账');
      expect(preview.defaultAutoCreateAccounts, isTrue);

      final commit = await csvService.commitImport(
        commandId: 'commit-hh-zip',
        preview: preview,
        selectedBookId: 1,
      );
      expect(commit.importedBillCount, 1);
      expect(commit.createdAccountCount, 1);

      final visa = await (db.select(
        db.assets,
      )..where((t) => t.name.equals('美元Visa卡'))).getSingle();
      expect(visa.currency, 'USD');
      expect(visa.icon, 'builtin:pay.visa');
      expect(visa.balanceMinor, BigInt.from(-2500));

      final rec = await (db.select(
        db.records,
      )..where((t) => t.platformId.equals(commit.batchId))).getSingle();
      final snap = RecordExtra.parse(rec.extraInfo).currency;
      expect(snap, isNotNull);
      expect(snap!.sourceCode, 'USD');
      expect(snap.assetCode, 'USD');
      expect(snap.assetNet, BigInt.from(2500));
      expect(snap.baseCode, 'CNY');
      expect(snap.baseAmount, BigInt.from(18000)); // 25.00 * 7.20 = 180.00
      expect(rec.images, isNotNull);
      final savedImgName = rec.images!;
      expect(await File(p.join(attachDir.path, savedImgName)).exists(), isTrue);

      await csvService.undoBatch(
        commandId: 'undo-hh-zip',
        batchId: commit.batchId,
      );
      final visaAfter = await (db.select(
        db.assets,
      )..where((t) => t.id.equals(visa.id))).getSingle();
      expect(visaAfter.balanceMinor, BigInt.zero);
      expect(
        await File(p.join(attachDir.path, savedImgName)).exists(),
        isFalse,
      );

      // Also verify `.json` Qianji preview & commit through CsvExcelService!
      final jsonBytes = Uint8List.fromList(
        utf8.encode('''
[
  {
    "key": "j1",
    "date": "2026-04-05 08:00:00",
    "category": "工资",
    "type": "收入",
    "money": 15000,
    "currency": "￥",
    "asset": 901,
    "remark": "发薪"
  }
]
'''),
      );
      final jPreview = await csvService.previewImport(
        fileName: 'qianji.json',
        bytes: jsonBytes,
        targetBookId: 1,
      );
      expect(jPreview.platformName, '钱迹');
      final jCommit = await csvService.commitImport(
        commandId: 'commit-qj-json',
        preview: jPreview,
        selectedBookId: 1,
      );
      final qjAcc = await (db.select(
        db.assets,
      )..where((t) => t.name.equals('钱迹账户#901'))).getSingle();
      expect(qjAcc.balanceMinor, BigInt.from(1500000));

      await csvService.undoBatch(
        commandId: 'undo-qj-json',
        batchId: jCommit.batchId,
      );
      final qjAccAfter = await (db.select(
        db.assets,
      )..where((t) => t.id.equals(qjAcc.id))).getSingle();
      expect(qjAccAfter.balanceMinor, BigInt.zero);

      // Verify importing a foreign-currency (`USD`) Qianji bill + USD refund child
      // onto a `CNY` account (`asset.currency == null`, e.g. `招商银行`) converts to CNY
      // minor units (`ac: 'CNY'`) and reverses symmetrically on `undoBatch`!
      final cmbCnyId = await db
          .into(db.assets)
          .insert(
            AssetsCompanion.insert(
              name: '招商银行',
              balanceMinor: BigInt.from(100000), // 1000.00 CNY
              initMoneyMinor: BigInt.from(100000),
              type: AssetType.normal,
              createDate: 1700000000000,
              currency: const Value(null), // SQLite null == CNY base currency!
            ),
          );
      final usdOnCnyCsv = encodeCsvBytes([
        qianjiHeader19,
        [
          'usd_exp_1',
          '2026-04-06 12:00:00',
          '日常账本',
          '购物',
          '',
          '支出',
          '25.00', // 25.00 USD * 7.20 = 180.00 CNY
          'USD',
          '招商银行',
          '',
          '海淘扣人民币卡',
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
          'usd_rf_1',
          '2026-04-07 12:00:00',
          '日常账本',
          '购物',
          '',
          '退款',
          '5.00', // 5.00 USD * 7.20 = 36.00 CNY refund
          'USD',
          '招商银行',
          '',
          '海淘部分退税',
          '',
          '',
          '',
          '',
          '',
          '',
          '',
          'usd_exp_1',
        ],
      ]);
      final fxPreview = await csvService.previewImport(
        fileName: 'qianji_usd_on_cny.csv',
        bytes: usdOnCnyCsv,
        targetBookId: 1,
      );
      final fxCommit = await csvService.commitImport(
        commandId: 'commit-qj-usd-on-cny',
        preview: fxPreview,
        selectedBookId: 1,
      );

      final cmbDuring = await (db.select(
        db.assets,
      )..where((t) => t.id.equals(cmbCnyId))).getSingle();
      // 1000.00 - 180.00 + 36.00 = 856.00 CNY (85600 minor)
      expect(cmbDuring.balanceMinor, BigInt.from(85600));

      final fxBatchRows = await (db.select(
        db.records,
      )..where((t) => t.platformId.equals(fxCommit.batchId))).get();
      expect(fxBatchRows, hasLength(2));
      final fxMain = fxBatchRows.singleWhere((r) => r.moneyMinor > BigInt.zero);
      final fxMainSnap = RecordExtra.parse(fxMain.extraInfo).currency!;
      expect(fxMain.moneyMinor, BigInt.from(18000));
      expect(fxMainSnap.sourceCode, 'USD');
      expect(fxMainSnap.sourceGross, BigInt.from(2500));
      expect(fxMainSnap.assetCode, 'CNY');
      expect(fxMainSnap.assetNet, BigInt.from(18000));

      final fxRefund = fxBatchRows.singleWhere(
        (r) => r.moneyMinor < BigInt.zero,
      );
      final fxRefundSnap = RecordExtra.parse(fxRefund.extraInfo).currency!;
      expect(fxRefund.moneyMinor, BigInt.from(-3600));
      expect(fxRefundSnap.sourceCode, 'USD');
      expect(fxRefundSnap.assetCode, 'CNY');
      expect(fxRefundSnap.assetNet, BigInt.from(-3600));

      await csvService.undoBatch(
        commandId: 'undo-qj-usd-on-cny',
        batchId: fxCommit.batchId,
      );
      final cmbRestored = await (db.select(
        db.assets,
      )..where((t) => t.id.equals(cmbCnyId))).getSingle();
      expect(cmbRestored.balanceMinor, BigInt.from(100000));
    },
  );

  testWidgets(
    'CsvImportPage Key(auto_create_accounts_switch) defaults true for Qianji and false for legacy templates',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      var closed = false;
      addTearDown(() async {
        if (!closed) {
          closed = true;
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(db.close);
        }
      });

      Future<void> settle() async {
        for (var i = 0; i < 12; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 15)),
          );
          await tester.pump(const Duration(milliseconds: 60));
        }
      }

      final qianjiCsv = encodeCsvBytes([
        qianjiHeader19,
        [
          '1',
          '2026-04-10 12:00:00',
          '日常账本',
          '餐饮',
          '',
          '支出',
          '36.50',
          'CNY',
          '建设银行',
          '',
          '面条',
          '',
          '',
          '',
          '',
          '',
          '',
          '',
          '',
        ],
      ]);

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: MaterialApp(
            home: CsvImportPage(
              initialFile: SelectedBytes('qianji.csv', qianjiCsv),
            ),
          ),
        ),
      );
      await settle();

      final switchFinder = find.byKey(const Key('auto_create_accounts_switch'));
      expect(switchFinder, findsOneWidget);
      expect(tester.widget<SwitchListTile>(switchFinder).value, isTrue);

      // Confirm import and verify `建设银行` was auto-created with CCB icon!
      await tester.scrollUntilVisible(
        find.byKey(const Key('confirm_import_button')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('confirm_import_button')));
      await settle();

      final ccb = await tester.runAsync(
        () => (db.select(
          db.assets,
        )..where((t) => t.name.equals('建设银行'))).getSingleOrNull(),
      );
      expect(ccb, isNotNull);
      expect(ccb!.icon, 'builtin:bank.ccb');
      expect(ccb.balanceMinor, BigInt.from(-3650));

      // Now load legacy Template v3 and verify switch defaults to FALSE!
      final tplBytes = generateOfficialTemplateV3Bytes();
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: MaterialApp(
            home: CsvImportPage(
              key: const ValueKey('legacy_tpl'),
              initialFile: SelectedBytes('template3.csv', tplBytes),
            ),
          ),
        ),
      );
      await settle();

      final legacySwitch = tester.widget<SwitchListTile>(
        find.byKey(const Key('auto_create_accounts_switch')),
      );
      expect(legacySwitch.value, isFalse);

      closed = true;
      await tester.pumpWidget(const SizedBox());
      await settle();
      await tester.pump(const Duration(seconds: 5));
      await tester.runAsync(db.close);
    },
  );
}
