import 'dart:async' show unawaited;
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/bank_icon_catalog.dart';
import 'package:tallyisle/domain/rules/ios_migration_rules.dart';
import 'package:tallyisle/domain/rules/template_card_rules.dart';
import 'package:tallyisle/features/assets/asset_editor_page.dart';
import 'package:tallyisle/features/assets/assets_page.dart';
import 'package:tallyisle/features/bank_cards/bank_cards_page.dart';
import 'package:tallyisle/features/common/catalog_icons.dart';
import 'package:tallyisle/features/common/svg_vector_icon.dart';
import 'package:tallyisle/main.dart' show registerBundledIconLicenses;

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 14; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _disposeApp(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await _settle(tester);
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final projectRoot = Directory.current;
  final iconsDir = Directory(p.join(projectRoot.path, 'assets', 'icons'));
  final banksDir = Directory(
    p.join(projectRoot.path, 'assets', 'icons', 'banks'),
  );

  String relativeAssetPath(File f) =>
      p.relative(f.path, from: projectRoot.path).replaceAll(r'\', '/');

  List<File> allSvgFiles(Directory dir) =>
      dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => p.extension(f.path).toLowerCase() == '.svg')
          .toList()
        ..sort((a, b) => relativeAssetPath(a).compareTo(relativeAssetPath(b)));

  group('BankIconCatalog & MIT license contract', () {
    test(
      'BankIconCatalog.bundled matches catalog.json 1:1 (18 reviewed + 194 library) and validates boundaries',
      () async {
        final catalogFile = File(
          p.join(projectRoot.path, 'assets', 'icons', 'banks', 'catalog.json'),
        );
        expect(catalogFile.existsSync(), isTrue);

        final fromJson = BankIconCatalog.fromJson(
          catalogFile.readAsStringSync(),
        );
        expect(fromJson.entries.length, 212);
        expect(fromJson.reviewedEntries.length, 18);
        expect(fromJson.libraryEntries.length, 194);
        expect(BankIconCatalog.bundled.entries, equals(fromJson.entries));

        final bankFiles = allSvgFiles(banksDir).map(relativeAssetPath).toSet();
        expect(
          fromJson.entries.map((e) => e.assetPath).toSet(),
          equals(bankFiles),
        );

        final verified = await loadVerifiedBankIconCatalog();
        expect(verified.entries.length, 212);
        expect(
          verified.pathFor('builtin:bank.cmb'),
          'assets/icons/banks/cmb.svg',
        );
        expect(
          verified.pathFor('builtin:bank-icon.bosc'),
          'assets/icons/banks/library/bosc.svg',
        );

        // Rejects malformed / path-traversal / wrong-namespace references:
        for (final invalid in const <String?>[
          null,
          '',
          'bank.icbc',
          'builtin:bank.',
          'builtin:bank-icon.',
          'builtin:bank.ICBC',
          'builtin:bank../secret',
          'builtin:bank.foo/bar',
          r'builtin:bank.foo\bar',
          'builtin:bank.foo.svg',
        ]) {
          expect(BankIconCatalog.isReference(invalid), isFalse);
          expect(BankIconCatalog.assetPathFor(invalid), isNull);
        }

        // Rejects reviewed icon in library namespace or source_label_only with entity code:
        expect(
          () => BankIconCatalog.fromJson(
            jsonEncode({
              'schemaVersion': 1,
              'icons': [
                {
                  'ref': 'builtin:bank-icon.boc',
                  'relatedEntityCode': 'bank.boc',
                  'displayName': '中国银行',
                  'aliases': const <String>[],
                  'assetPath': 'assets/icons/banks/library/boc.svg',
                  'reviewStatus': 'reviewed',
                },
              ],
            }),
          ),
          throwsFormatException,
        );
        expect(
          () => BankIconCatalog.fromJson(
            jsonEncode({
              'schemaVersion': 1,
              'icons': [
                {
                  'ref': 'builtin:bank-icon.boc',
                  'relatedEntityCode': 'bank.boc',
                  'displayName': '中国银行',
                  'aliases': const <String>[],
                  'assetPath': 'assets/icons/banks/library/boc.svg',
                  'reviewStatus': 'source_label_only',
                },
              ],
            }),
          ),
          throwsFormatException,
        );
      },
    );

    test(
      'bundled MIT license file exists and registers cleanly in Flutter LicenseRegistry',
      () async {
        final licenseFile = File(
          p.join(
            projectRoot.path,
            'assets',
            'icons',
            'banks',
            'LICENSE.icongo-bank-logos.txt',
          ),
        );
        expect(licenseFile.existsSync(), isTrue);
        expect(licenseFile.readAsStringSync(), contains('MIT License'));

        registerBundledIconLicenses();
        final entries = await LicenseRegistry.licenses.toList();
        expect(
          entries.any((e) => e.packages.contains('icongo/bank-logos')),
          isTrue,
        );
      },
    );
  });

  group('Zero-dependency SvgVectorDocument parser & Canvas renderer', () {
    test(
      'parses, security-validates, and paints all 229 bundled SVG files cleanly',
      () {
        final files = allSvgFiles(iconsDir);
        expect(files.length, 229);

        for (final file in files) {
          final rel = relativeAssetPath(file);
          final raw = file.readAsStringSync();
          final doc = SvgVectorDocument.parse(raw, sourceLabel: rel);
          expect(doc.viewBox.width, greaterThan(0), reason: rel);
          expect(doc.viewBox.height, greaterThan(0), reason: rel);
          expect(doc.ops, isNotEmpty, reason: rel);

          // Paint onto a real PictureRecorder canvas at 48x48 without throwing.
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, 48, 48));
          doc.paint(canvas, const Size(48, 48));
          final pic = recorder.endRecording();
          pic.dispose();
        }

        // Rejects unsafe active SVG constructs:
        expect(
          () => SvgVectorDocument.parse(
            '<svg viewBox="0 0 24 24"><script>alert(1)</script></svg>',
          ),
          throwsFormatException,
        );
        expect(
          () => SvgVectorDocument.parse(
            '<svg viewBox="0 0 24 24"><path d="M0 0L10 10" onclick="x()"/></svg>',
          ),
          throwsFormatException,
        );
      },
    );
  });

  group('Smart institution auto-matching & anti-false-positive guards', () {
    test(
      'auto-matches all 18 reviewed commercial banks and payment/social brands while guarding against false positives',
      () {
        const expectedBankCases = <(String, String)>[
          ('中国银行储蓄卡', 'builtin:bank.boc'),
          ('中行外币卡', 'builtin:bank.boc'),
          ('BOC信用卡', 'builtin:bank.boc'),
          ('中国工商银行', 'builtin:bank.icbc'),
          ('工行牡丹卡', 'builtin:bank.icbc'),
          ('工商工资卡', 'builtin:bank.icbc'),
          ('ICBC储蓄卡', 'builtin:bank.icbc'),
          ('农业银行卡', 'builtin:bank.abc'),
          ('农行储蓄卡', 'builtin:bank.abc'),
          ('ABC信用卡', 'builtin:bank.abc'),
          ('中国建设银行', 'builtin:bank.ccb'),
          ('建行龙卡', 'builtin:bank.ccb'),
          ('交通银行信用卡', 'builtin:bank.bocom'),
          ('交行沃尔玛卡', 'builtin:bank.bocom'),
          ('中信银行白金卡', 'builtin:bank.citic'),
          ('招商银行一卡通', 'builtin:bank.cmb'),
          ('招行掌上生活', 'builtin:bank.cmb'),
          ('CMB信用卡', 'builtin:bank.cmb'),
          ('邮政储蓄工资卡', 'builtin:bank.psbc'),
          ('邮储银行', 'builtin:bank.psbc'),
          ('广发银行信用卡', 'builtin:bank.cgb'),
          ('光大银行阳光卡', 'builtin:bank.ceb'),
          ('民生银行储蓄卡', 'builtin:bank.cmbc'),
          ('平安银行白金卡', 'builtin:bank.pingan'),
          ('华夏银行储蓄卡', 'builtin:bank.hxb'),
          ('浦发银行信用卡', 'builtin:bank.spdb'),
          ('兴业银行寰宇卡', 'builtin:bank.cib'),
          ('渤海银行储蓄卡', 'builtin:bank.bohai'),
          ('恒丰银行卡', 'builtin:bank.hengfeng'),
          ('浙商银行储蓄卡', 'builtin:bank.czbank'),
          ('微信零钱通', 'wechat_pay'),
          ('支付宝钱包', 'alipay'),
          ('抖音零钱', 'builtin:social.douyin'),
          ('小红书钱包', 'builtin:social.xiaohongshu'),
        ];

        for (final (name, expectedKey) in expectedBankCases) {
          final v = resolveAssetVisual(name: name, assetType: AssetType.normal);
          expect(v.iconKey, expectedKey, reason: 'Failed for "$name"');
          expect(v.svgAssetPath, isNotNull, reason: 'Missing SVG for "$name"');
        }

        // Non-reviewed source_label_only banks NEVER auto-match by name:
        for (final unreviewed in const <String>[
          '上海银行储蓄卡',
          '宁波银行信用卡',
          '北京银行工资卡',
          '微众银行',
        ]) {
          expect(
            matchReviewedInstitution(unreviewed, assetType: AssetType.normal),
            isNull,
            reason: 'source_label_only must not auto-match "$unreviewed"',
          );
        }

        // Anti-false-positive disambiguation checks:
        expect(
          resolveAssetVisual(
            name: '市政交通卡',
            assetType: AssetType.normal,
          ).iconKey,
          'stored_card',
        );
        expect(
          resolveAssetVisual(
            name: '平安保险重疾险',
            assetType: AssetType.normal,
          ).iconKey,
          'insurance',
        );
        expect(
          resolveAssetVisual(
            name: '华夏基金定投',
            assetType: AssetType.normal,
          ).iconKey,
          'fund',
        );
        expect(
          resolveAssetVisual(
            name: '广发基金账户',
            assetType: AssetType.normal,
          ).iconKey,
          'stock',
        );
        expect(
          resolveAssetVisual(
            name: '招商证券股票户',
            assetType: AssetType.normal,
          ).iconKey,
          'stock',
        );
        expect(
          resolveAssetVisual(
            name: '支付宝花呗',
            assetType: AssetType.credit,
          ).iconKey,
          'huabei',
        );
        expect(
          resolveAssetVisual(name: '京东白条', assetType: AssetType.credit).iconKey,
          'baitiao',
        );
        expect(
          resolveAssetVisual(name: '余额宝', assetType: AssetType.normal).iconKey,
          'wealth',
        );
        // Debt accounts never auto-match bank logos:
        expect(
          resolveAssetVisual(
            name: '借给小李(招行转账)',
            assetType: AssetType.debt,
            subType: AssetType.debtLend,
          ).iconKey,
          'lend',
        );
        // Substring ASCII words never false-match bank codes:
        for (final word in const <String>['abcde', 'MacBook', 'cibcCard']) {
          expect(
            matchReviewedInstitution(word, assetType: AssetType.normal),
            isNull,
            reason: 'Substring "$word" must not match ASCII bank code',
          );
        }
      },
    );

    test(
      'BankCardVisualMeta encodes/decodes [#RRGGBB]|icon:<key> and strips icon metadata on .ya2i export',
      () {
        expect(normalizeCardColorHex(null), isNull);
        expect(normalizeCardColorHex('#1565c0'), '#1565C0');
        expect(
          normalizeCardColorHex('#1565c0|icon:builtin:bank-icon.bosc'),
          '#1565C0|icon:builtin:bank-icon.bosc',
        );
        expect(
          normalizeCardColorHex('|icon:builtin:bank-icon.bosc'),
          '|icon:builtin:bank-icon.bosc',
        );

        final parsed = parseBankCardVisualMeta(
          '#E50113|icon:builtin:bank-icon.bosc',
        );
        expect(parsed.colorHex, '#E50113');
        expect(parsed.iconKey, 'builtin:bank-icon.bosc');

        // Verify .ya2i export strips '|icon:...' to pure hex color for iOS schema parity:
        const payload = MigrationPayload(
          books: <MigrationBookRow>[],
          categories: <MigrationCategoryRow>[],
          assets: <MigrationAssetRow>[],
          records: <MigrationRecordRow>[],
          budgets: <MigrationBudgetRow>[],
          importPlatforms: <MigrationImportPlatformRow>[],
          installments: <MigrationInstallmentRow>[],
          periods: <MigrationPeriodRow>[],
          reminders: <MigrationReminderRow>[],
          tags: <MigrationTagRow>[],
          tagRefs: <MigrationTagRefRow>[],
          templates: <MigrationTemplateRow>[],
          bankCards: <MigrationBankCardRow>[
            MigrationBankCardRow(
              id: 1,
              cardType: BankCardType.debit,
              cardName: '上海银行储蓄卡',
              cardNo: '6228920000111122',
              cardOwner: '张三',
              remark: '',
              cardColor: '#1565C0|icon:builtin:bank-icon.bosc',
              sort: 0,
              createDate: 1700000000000,
              cardAssetId: -1,
            ),
            MigrationBankCardRow(
              id: 2,
              cardType: BankCardType.credit,
              cardName: '宁波银行白金卡',
              cardNo: '6228920000333344',
              cardOwner: '',
              remark: '',
              cardColor: '|icon:builtin:bank-icon.nbcb',
              sort: 1,
              createDate: 1700000000000,
              cardAssetId: -1,
            ),
          ],
          wishes: <MigrationWishRow>[],
          remarks: <MigrationRemarkRow>[],
          moneySavePlans: <MigrationSavingsPlanRow>[],
          moneySavePlanRecords: <MigrationSavingsRecordRow>[],
          assetBookRefs: <MigrationAssetBookRow>[],
          statStory: <MigrationStatStoryRow>[],
        );
        final exportedJson =
            jsonDecode(encodeYa2iJsonText(payload)) as Map<String, Object?>;
        final cards = exportedJson['bankCards'] as List<Object?>;
        expect((cards[0] as Map<String, Object?>)['color'], '#1565C0');
        expect((cards[1] as Map<String, Object?>)['color'], isNull);
      },
    );
  });

  group(
    'UI flows: instant icon search, smart auto-match & manual override protection',
    () {
      testWidgets(
        'AssetEditorPage auto-matches reviewed bank SVG, searches library banks in picker, and never overwrites manual icon on rename',
        (tester) async {
          final db = AppDatabase(NativeDatabase.memory());
          final router = GoRouter(
            initialLocation: '/assets',
            routes: [
              GoRoute(path: '/assets', builder: (_, _) => const AssetsPage()),
              GoRoute(
                path: '/assets/new',
                builder: (_, _) => const AssetEditorPage(),
              ),
              GoRoute(
                path: '/assets/:id/edit',
                builder: (_, s) => AssetEditorPage(
                  assetId: int.parse(s.pathParameters['id']!),
                ),
              ),
            ],
          );

          await tester.pumpWidget(
            ProviderScope(
              retry: (_, _) => null,
              overrides: [databaseProvider.overrideWith((ref) async => db)],
              child: MaterialApp.router(routerConfig: router),
            ),
          );
          await _settle(tester);

          // 1. Create account named '招行工资卡' without opening picker -> auto-saves builtin:bank.cmb
          await tester.tap(find.byKey(const Key('add-asset')));
          await _settle(tester);
          await tester.enterText(find.byKey(const Key('asset-name')), '招行工资卡');
          await _settle(tester);
          expect(find.textContaining('招商银行（已按名称智能关联）'), findsOneWidget);

          await tester.enterText(
            find.byKey(const Key('asset-balance')),
            '5000',
          );
          await tester.tap(find.byKey(const Key('asset-save')));
          await _settle(tester);

          var row = await (db.select(
            db.assets,
          )..where((a) => a.name.equals('招行工资卡'))).getSingle();
          expect(row.icon, 'builtin:bank.cmb');
          expect(row.color, '#E50113');

          // 2. Edit '招行工资卡' -> rename to '工行工资卡' without touching picker -> updates to builtin:bank.icbc
          unawaited(router.push('/assets/${row.id}/edit'));
          await _settle(tester);
          await tester.enterText(find.byKey(const Key('asset-name')), '工行工资卡');
          await _settle(tester);
          await tester.tap(find.byKey(const Key('asset-save')));
          await _settle(tester);

          row = await (db.select(
            db.assets,
          )..where((a) => a.id.equals(row.id))).getSingle();
          expect(row.name, '工行工资卡');
          expect(row.icon, 'builtin:bank.icbc');

          // 3. Edit '工行工资卡' -> search '上海银行' in picker -> pick 'builtin:bank-icon.bosc' manually -> rename to '建行备用卡' -> manual icon preserved!
          unawaited(router.push('/assets/${row.id}/edit'));
          await _settle(tester);
          await tester.tap(
            find.byKey(const Key('asset-visual-picker-trigger')),
          );
          await _settle(tester);

          await tester.enterText(
            find.byKey(const Key('asset-picker-search-input')),
            '上海银行',
          );
          await _settle(tester);
          expect(
            find.byKey(const Key('visual-icon-builtin:bank-icon.bosc')),
            findsOneWidget,
          );
          await tester.tap(
            find.byKey(const Key('visual-icon-builtin:bank-icon.bosc')),
          );
          await tester.pump();
          await tester.tap(find.byKey(const Key('visual-picker-confirm')));
          await _settle(tester);

          // Now rename to '建行备用卡' after manual pick -> must NOT overwrite 'builtin:bank-icon.bosc'
          await tester.enterText(find.byKey(const Key('asset-name')), '建行备用卡');
          await _settle(tester);
          await tester.tap(find.byKey(const Key('asset-save')));
          await _settle(tester);

          row = await (db.select(
            db.assets,
          )..where((a) => a.id.equals(row.id))).getSingle();
          expect(row.name, '建行备用卡');
          expect(row.icon, 'builtin:bank-icon.bosc');

          // Re-open edit on '建行备用卡' and rename again to '农行日常卡' -> saved manual icon STILL preserved!
          unawaited(router.push('/assets/${row.id}/edit'));
          await _settle(tester);
          await tester.enterText(find.byKey(const Key('asset-name')), '农行日常卡');
          await _settle(tester);
          await tester.tap(find.byKey(const Key('asset-save')));
          await _settle(tester);

          row = await (db.select(
            db.assets,
          )..where((a) => a.id.equals(row.id))).getSingle();
          expect(row.name, '农行日常卡');
          expect(row.icon, 'builtin:bank-icon.bosc');

          await _disposeApp(tester);
          router.dispose();
          await db.close();
        },
      );

      testWidgets(
        'BankCardsPage & BankCardEditorPage auto-match bank SVG logo and preserve manual icon override across edits',
        (tester) async {
          final db = AppDatabase(NativeDatabase.memory());
          await tester.pumpWidget(
            ProviderScope(
              retry: (_, _) => null,
              overrides: [databaseProvider.overrideWith((ref) async => db)],
              child: const MaterialApp(home: BankCardsPage()),
            ),
          );
          await _settle(tester);

          // Add '招商银行储蓄卡' -> live auto-matches builtin:bank.cmb while keeping card_color null
          await tester.tap(find.byKey(const Key('add_bank_card_fab')));
          await _settle(tester);
          await tester.enterText(
            find.byKey(const Key('bank_card_name_input')),
            '招商银行储蓄卡',
          );
          await _settle(tester);
          expect(find.textContaining('招商银行（按名称智能关联）'), findsOneWidget);

          await tester.enterText(
            find.byKey(const Key('bank_card_no_input')),
            '6225 8810 1234 5678',
          );
          await tester.tap(find.byKey(const Key('save_bank_card_button')));
          await _settle(tester);

          var savedCard = await (db.select(db.bankCards)).getSingle();
          expect(savedCard.cardColor, isNull);
          expect(find.byType(BankCardIconAvatar), findsOneWidget);

          // Edit card -> manually pick 'builtin:bank-icon.bosc' + '#1565C0' -> rename to '工行卡' -> manual icon preserved!
          await tester.tap(find.byKey(Key('edit_bank_card_${savedCard.id}')));
          await _settle(tester);
          await tester.tap(
            find.byKey(const Key('bank_card_icon_picker_trigger')),
          );
          await _settle(tester);
          await tester.enterText(
            find.byKey(const Key('asset-picker-search-input')),
            '上海银行',
          );
          await _settle(tester);
          await tester.tap(
            find.byKey(const Key('visual-icon-builtin:bank-icon.bosc')),
          );
          await tester.pump();
          await tester.tap(find.byKey(const Key('visual-picker-confirm')));
          await _settle(tester);

          expect(find.textContaining('上海银行（手动指定）'), findsOneWidget);
          await tester.enterText(
            find.byKey(const Key('bank_card_name_input')),
            '工行工资卡',
          );
          await _settle(tester);
          // Manual override must NOT be overwritten by typing '工行工资卡'!
          expect(find.textContaining('上海银行（手动指定）'), findsOneWidget);

          await tester.scrollUntilVisible(
            find.byKey(const Key('card_color_#1565C0')),
            160,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.tap(find.byKey(const Key('card_color_#1565C0')));
          await tester.pump();
          await tester.tap(find.byKey(const Key('save_bank_card_button')));
          await _settle(tester);

          savedCard = await (db.select(db.bankCards)).getSingle();
          expect(savedCard.cardColor, '#1565C0|icon:builtin:bank-icon.bosc');

          // Edit again -> tap '自动匹配' chip -> resets back to pure '#1565C0' & ICBC auto-match!
          await tester.tap(find.byKey(Key('edit_bank_card_${savedCard.id}')));
          await _settle(tester);
          await tester.tap(
            find.byKey(const Key('bank_card_icon_picker_trigger')),
          );
          await _settle(tester);
          await tester.tap(
            find.byKey(const Key('bank-card-picker-reset-auto')),
          );
          await _settle(tester);
          expect(find.textContaining('中国工商银行（按名称智能关联）'), findsOneWidget);
          await tester.tap(find.byKey(const Key('save_bank_card_button')));
          await _settle(tester);

          savedCard = await (db.select(db.bankCards)).getSingle();
          expect(savedCard.cardColor, '#1565C0');

          await _disposeApp(tester);
          await db.close();
        },
      );
    },
  );
}
