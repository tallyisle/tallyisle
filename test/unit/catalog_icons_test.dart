import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/db/seed.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/features/assets/asset_detail_page.dart';
import 'package:tallyisle/features/assets/asset_editor_page.dart';
import 'package:tallyisle/features/assets/assets_page.dart';
import 'package:tallyisle/features/calendar/calendar_page.dart';
import 'package:tallyisle/features/categories/categories_page.dart';
import 'package:tallyisle/features/common/catalog_icons.dart';

GoRouter _buildTestRouter(String initialLocation) => GoRouter(
  initialLocation: initialLocation,
  routes: [
    GoRoute(path: '/assets', builder: (_, _) => const AssetsPage()),
    GoRoute(
      path: '/assets/new',
      builder: (_, state) => AssetEditorPage(
        initialType: int.tryParse(state.uri.queryParameters['type'] ?? ''),
      ),
    ),
    GoRoute(
      path: '/assets/:id',
      builder: (_, state) =>
          AssetDetailPage(assetId: int.parse(state.pathParameters['id']!)),
    ),
    GoRoute(
      path: '/assets/:id/edit',
      builder: (_, state) =>
          AssetEditorPage(assetId: int.parse(state.pathParameters['id']!)),
    ),
    GoRoute(path: '/categories', builder: (_, _) => const CategoriesPage()),
    GoRoute(path: '/calendar', builder: (_, _) => const CalendarPage()),
  ],
);

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
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

Future<Uint8List> _makeTestPng({
  required int width,
  required int height,
  Color outerColor = const Color(0xFF1565C0),
  Color innerColor = const Color(0xFFFF7043),
}) async {
  final recorder = ui.PictureRecorder();
  final rect = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
  final canvas = Canvas(recorder, rect);
  canvas.drawRect(rect, Paint()..color = outerColor);
  final innerRect = Rect.fromCenter(
    center: rect.center,
    width: width * 0.4,
    height: height * 0.4,
  );
  canvas.drawRect(innerRect, Paint()..color = innerColor);
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  try {
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return Uint8List.fromList(
      byteData!.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      ),
    );
  } finally {
    image.dispose();
    picture.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('Hex color parsing & Material 3 palette presets', () {
    test('provides at least 16 harmonious color presets', () {
      expect(catalogColorHexPresets.length, greaterThanOrEqualTo(16));
      expect(catalogColorPresets.length, catalogColorHexPresets.length);
      for (var i = 0; i < catalogColorHexPresets.length; i++) {
        final parsed = tryParseCatalogColor(catalogColorHexPresets[i]);
        expect(parsed, catalogColorPresets[i]);
        expect(
          formatCatalogColorHex(parsed!),
          catalogColorHexPresets[i].toUpperCase(),
        );
      }
    });

    test(
      'parses #RRGGBB, RRGGBB, 0xAARRGGBB, #RGB and rejects invalid input',
      () {
        expect(tryParseCatalogColor('#FF7043'), const Color(0xFFFF7043));
        expect(tryParseCatalogColor('ff7043'), const Color(0xFFFF7043));
        expect(tryParseCatalogColor('0xFFFF7043'), const Color(0xFFFF7043));
        expect(tryParseCatalogColor('0XFF1677FF'), const Color(0xFF1677FF));
        expect(tryParseCatalogColor('#F74'), const Color(0xFFFF7744));
        expect(tryParseCatalogColor('001677FF'), const Color(0xFF1677FF));

        expect(tryParseCatalogColor(null), isNull);
        expect(tryParseCatalogColor(''), isNull);
        expect(tryParseCatalogColor('   '), isNull);
        expect(tryParseCatalogColor('#12345'), isNull);
        expect(tryParseCatalogColor('not-a-color'), isNull);

        const fallback = Color(0xFF123456);
        expect(parseCatalogColor('invalid', fallback: fallback), fallback);
        expect(formatCatalogColorHex(const Color(0xFF07C160)), '#07C160');
      },
    );
  });

  group('Category & RecordType visual resolution', () {
    test(
      'catalog contains 40+ curated semantic keys including camelCase aliases',
      () {
        expect(categoryIconCatalog.length, greaterThanOrEqualTo(40));

        const requiredKeys = <String>[
          'restaurant',
          'breakfast',
          'coffee',
          'shopping_bag',
          'subway',
          'directions_car',
          'local_gas_station',
          'flight',
          'hotel',
          'sports_esports',
          'movie',
          'home',
          'water_drop',
          'phone_android',
          'checkroom',
          'spa',
          'medical_services',
          'MenuBook',
          'school',
          'child_care',
          'pets',
          'card_giftcard',
          'fitness_center',
          'build',
          'payments',
          'work',
          'trending_up',
          'redeem',
          'account_balance_wallet',
          'SwapHoriz',
          'receipt_long',
        ];

        for (final key in requiredKeys) {
          final v = resolveCategoryVisual(iconKey: key, name: '自定义');
          expect(
            v.iconKey,
            isNot('category'),
            reason: 'Key $key should resolve',
          );
        }
        expect(
          resolveCategoryVisual(iconKey: 'MenuBook', name: '读物').iconKey,
          'menu_book',
        );
        expect(
          resolveCategoryVisual(iconKey: 'SwapHoriz', name: '往来').iconKey,
          'swap_horiz',
        );
      },
    );

    test(
      'all 16 seeded categories resolve to distinct icons out of the box',
      () {
        final allSeeded = <(int, String)>[
          for (final name in presetExpenseCategories)
            (RecordType.expense, name),
          for (final name in presetIncomeCategories) (RecordType.income, name),
        ];
        expect(allSeeded.length, 16);

        final seenIconKeys = <String>{};
        final seenIconData = <IconData>{};
        for (final (type, name) in allSeeded) {
          final visual = resolveCategoryVisual(
            iconKey: '',
            colorHex: null,
            name: name,
            type: type,
          );
          expect(
            seenIconKeys.add(visual.iconKey),
            isTrue,
            reason:
                'Seeded category "$name" duplicated iconKey ${visual.iconKey}',
          );
          expect(
            seenIconData.add(visual.icon),
            isTrue,
            reason:
                'Seeded category "$name" duplicated IconData ${visual.icon}',
          );
          expect(visual.colorHex, matches(RegExp(r'^#[0-9A-F]{6}$')));
        }
      },
    );

    test(
      'resolves secondary categories and non-category record types cleanly',
      () {
        final breakfast = resolveCategoryVisual(
          name: '餐饮 · 早餐',
          type: RecordType.expense,
        );
        expect(breakfast.iconKey, 'breakfast');

        final inheritedSub = resolveCategoryVisual(
          name: '兴趣收藏 · 手办展示盒',
          parentIconKey: 'palette',
          colorHex: '#7E57C2',
          type: RecordType.expense,
        );
        expect(inheritedSub.iconKey, 'palette');
        expect(inheritedSub.colorHex, '#7E57C2');

        expect(
          resolveRecordTypeVisual(recordType: RecordType.transfer).iconKey,
          'transfer',
        );
        expect(
          resolveRecordTypeVisual(recordType: RecordType.balanceAdjust).iconKey,
          'balance_adjust',
        );
        expect(
          resolveRecordTypeVisual(
            recordType: RecordType.expense,
            categoryName: '退款 · 餐饮',
            isRefund: true,
          ).iconKey,
          'refund',
        );
        expect(
          resolveRecordTypeVisual(recordType: RecordType.borrowIn).iconKey,
          'borrow_in',
        );
        expect(
          resolveRecordTypeVisual(recordType: RecordType.lendOut).iconKey,
          'lend_out',
        );
        expect(
          resolveRecordTypeVisual(recordType: RecordType.repay).iconKey,
          'repay',
        );
        expect(
          resolveRecordTypeVisual(
            recordType: RecordType.reimbursable,
            categoryName: '未分类',
          ).iconKey,
          'reimbursable',
        );
      },
    );
  });

  group('Asset account visual resolution', () {
    test('matches brand/account keywords and type/subType fallbacks', () {
      expect(
        resolveAssetVisual(name: '微信钱包', assetType: AssetType.normal).iconKey,
        'wechat_pay',
      );
      expect(
        resolveAssetVisual(name: '支付宝', assetType: AssetType.normal).iconKey,
        'alipay',
      );
      expect(
        resolveAssetVisual(name: '支付宝花呗', assetType: AssetType.credit).iconKey,
        'huabei',
      );
      expect(
        resolveAssetVisual(name: '京东白条', assetType: AssetType.credit).iconKey,
        'baitiao',
      );
      expect(
        resolveAssetVisual(name: '招行信用卡', assetType: AssetType.credit).iconKey,
        'credit_card',
      );
      expect(
        resolveAssetVisual(name: '现金', assetType: AssetType.normal).iconKey,
        'cash',
      );
      expect(
        resolveAssetVisual(name: '招行储蓄卡', assetType: AssetType.normal).iconKey,
        'bank_card',
      );

      // Pure fallbacks when name has no specific brand keyword:
      expect(
        resolveAssetVisual(name: '主卡A', assetType: AssetType.credit).iconKey,
        'credit_card',
      );
      expect(
        resolveAssetVisual(name: '日常账户A', assetType: AssetType.normal).iconKey,
        'bank_card',
      );
      expect(
        resolveAssetVisual(
          name: '往来甲',
          assetType: AssetType.debt,
          subType: AssetType.debtBorrow,
        ).iconKey,
        'borrow',
      );
      expect(
        resolveAssetVisual(
          name: '往来乙',
          assetType: AssetType.debt,
          subType: AssetType.debtLend,
        ).iconKey,
        'lend',
      );

      // Explicit iconKey & colorHex take top priority:
      final custom = resolveAssetVisual(
        iconKey: 'wealth',
        colorHex: '#7E57C2',
        name: '现金',
        assetType: AssetType.normal,
      );
      expect(custom.iconKey, 'wealth');
      expect(custom.colorHex, '#7E57C2');
    });

    test(
      'preserves all 16 original keys, adds 16 practical financial presets, and resolves cat:<key> general icons',
      () {
        const original16Keys = <String>[
          'cash',
          'bank_card',
          'wechat_pay',
          'alipay',
          'wealth',
          'stored_card',
          'provident',
          'stock',
          'currency_exchange',
          'savings',
          'credit_card',
          'huabei',
          'baitiao',
          'credit_line',
          'borrow',
          'lend',
        ];
        const expandedNewKeys = <String>[
          'unionpay',
          'gold',
          'fund',
          'insurance',
          'meal_card',
          'gift_card',
          'property',
          'car_asset',
          'crypto',
          'safe_box',
          'reimburse_acc',
          'piggy_bank',
          'paypal_intl',
          'medical_card',
          'virtual_credit',
          'iou_note',
        ];

        for (final key in <String>[...original16Keys, ...expandedNewKeys]) {
          final v = resolveAssetVisual(
            iconKey: key,
            name: '测试账户',
            assetType: AssetType.normal,
          );
          expect(v.iconKey, key, reason: 'Preset key $key must resolve');
          expect(v.label, isNotEmpty);
          expect(v.customText, isNull);
          expect(v.customImageBytes, isNull);
        }

        // Smart keyword matches for newly added account presets:
        expect(
          resolveAssetVisual(name: '云闪付', assetType: AssetType.normal).iconKey,
          'unionpay',
        );
        expect(
          resolveAssetVisual(
            name: '积存金账户',
            assetType: AssetType.normal,
          ).iconKey,
          'gold',
        );
        expect(
          resolveAssetVisual(
            name: '大学校园卡',
            assetType: AssetType.normal,
          ).iconKey,
          'meal_card',
        );
        expect(
          resolveAssetVisual(
            name: '超市购物卡',
            assetType: AssetType.normal,
          ).iconKey,
          'gift_card',
        );
        expect(
          resolveAssetVisual(
            name: '租房押金',
            assetType: AssetType.debt,
            subType: AssetType.debtLend,
          ).iconKey,
          'iou_note',
        );

        // General category icons via 'cat:<key>' and direct fallback:
        final catCoffee = resolveAssetVisual(
          iconKey: 'cat:coffee',
          colorHex: '#8D6E63',
          name: '咖啡储值卡',
          assetType: AssetType.normal,
        );
        expect(catCoffee.iconKey, 'cat:coffee');
        expect(catCoffee.icon, Icons.coffee_rounded);
        expect(catCoffee.colorHex, '#8D6E63');

        final catCamel = resolveAssetVisual(
          iconKey: 'cat:MenuBook',
          name: '读书卡',
          assetType: AssetType.normal,
        );
        expect(catCamel.iconKey, 'cat:menu_book');
        expect(catCamel.icon, Icons.menu_book_rounded);

        // Legacy numeric .penny asset.icon ('1') must NOT hijack keyword match to 'restaurant':
        expect(
          resolveAssetVisual(
            iconKey: '1',
            name: '支付宝',
            assetType: AssetType.normal,
          ).iconKey,
          'alipay',
        );
      },
    );

    test(
      'custom text/Emoji monogram (text:<1~2 graphemes>) enforces grapheme safety and color pairing',
      () {
        expect(normalizeAssetCustomText('招商银行'), '招商');
        expect(normalizeAssetCustomText('  招行\n\t '), '招行');
        expect(normalizeAssetCustomText('💳'), '💳');
        expect(normalizeAssetCustomText('💳🏦💰'), '💳🏦');
        // Complex multi-codepoint ZWJ family emoji stays intact as 1 grapheme:
        expect(normalizeAssetCustomText('👨‍👩‍👧'), '👨‍👩‍👧');
        expect(normalizeAssetCustomText('👨‍👩‍👧🏦🎉'), '👨‍👩‍👧🏦');
        expect(normalizeAssetCustomText('🇨🇳🧧✨'), '🇨🇳🧧');
        expect(normalizeAssetCustomText('   '), '');

        final zhaohang = resolveAssetVisual(
          iconKey: 'text:招商银行',
          colorHex: '#E53935',
          name: '招商银行储蓄卡',
          assetType: AssetType.normal,
        );
        expect(zhaohang.iconKey, 'text:招商');
        expect(zhaohang.customText, '招商');
        expect(zhaohang.colorHex, '#E53935');
        expect(zhaohang.customImageBytes, isNull);

        final zwj = resolveAssetVisual(
          iconKey: 'text:👨‍👩‍👧',
          colorHex: '#26A69A',
          name: '家庭备用金',
          assetType: AssetType.normal,
        );
        expect(zwj.iconKey, 'text:👨‍👩‍👧');
        expect(zwj.customText, '👨‍👩‍👧');

        // Blank 'text:   ' falls back cleanly to keyword/type preset:
        final blankText = resolveAssetVisual(
          iconKey: 'text:   ',
          name: '微信钱包',
          assetType: AssetType.normal,
        );
        expect(blankText.iconKey, 'wechat_pay');
        expect(blankText.customText, isNull);
      },
    );

    test(
      'custom local image crops/scales to 96x96 PNG, validates limits, caches boundedly, and falls back on corrupt data',
      () async {
        debugClearDecodedAssetImageCache();

        // 1. Center-crop 160x100 rectangular PNG -> 96x96 PNG
        final rectPng = await _makeTestPng(
          width: 160,
          height: 100,
          outerColor: const Color(0xFF1565C0),
          innerColor: const Color(0xFFFF7043),
        );
        final dataUri = await encodeCustomAssetIconImage(rectPng);
        expect(dataUri, startsWith('data:image/png;base64,'));

        final resolved1 = resolveAssetVisual(
          iconKey: dataUri,
          colorHex: '#1677FF',
          name: '专属银行卡',
          assetType: AssetType.normal,
        );
        expect(resolved1.iconKey, dataUri);
        expect(resolved1.customImageBytes, isNotNull);
        expect(resolved1.customText, isNull);
        expect(resolved1.colorHex, '#1677FF');

        // Verify decoded PNG dimensions are 96x96
        final codec = await ui.instantiateImageCodec(
          resolved1.customImageBytes!,
        );
        final frame = await codec.getNextFrame();
        expect(frame.image.width, 96);
        expect(frame.image.height, 96);
        frame.image.dispose();
        codec.dispose();

        // 2. Bounded cache returns identical Uint8List and caps at 128 entries
        final resolved2 = resolveAssetVisual(
          iconKey: dataUri,
          name: '专属银行卡',
          assetType: AssetType.normal,
        );
        expect(
          identical(resolved1.customImageBytes, resolved2.customImageBytes),
          isTrue,
        );

        for (var i = 0; i < 140; i++) {
          // Valid JPEG 3-byte SOI+FF header + unique index payload
          final fakeJpeg = Uint8List.fromList(<int>[
            0xFF,
            0xD8,
            0xFF,
            0xE0,
            i & 0xFF,
          ]);
          final uri = 'data:image/jpeg;base64,${base64Encode(fakeJpeg)}';
          final v = resolveAssetVisual(
            iconKey: uri,
            name: '卡$i',
            assetType: AssetType.normal,
          );
          expect(v.customImageBytes, isNotNull);
        }
        expect(
          debugDecodedAssetImageCacheSize,
          lessThanOrEqualTo(maxCustomAssetImageCacheEntries),
        );
        expect(debugDecodedAssetImageCacheSize, 128);

        // Also accepts valid WebP header
        final fakeWebp = Uint8List.fromList(<int>[
          0x52,
          0x49,
          0x46,
          0x46,
          0x04,
          0x00,
          0x00,
          0x00,
          0x57,
          0x45,
          0x42,
          0x50,
        ]);
        final webpVisual = resolveAssetVisual(
          iconKey: 'data:image/webp;base64,${base64Encode(fakeWebp)}',
          name: 'WebP卡',
          assetType: AssetType.normal,
        );
        expect(webpVisual.customImageBytes, isNotNull);

        // 3. Rejects empty, >15MB, and corrupt non-image bytes in encodeCustomAssetIconImage
        await expectLater(
          encodeCustomAssetIconImage(Uint8List(0)),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.validation,
            ),
          ),
        );
        await expectLater(
          encodeCustomAssetIconImage(Uint8List(15 * 1024 * 1024 + 1)),
          throwsA(
            isA<Failure>()
                .having((f) => f.code, 'code', FailureCode.validation)
                .having((f) => f.message, 'message', '图片文件过大，请选择 15MB 以内的图片'),
          ),
        );
        await expectLater(
          encodeCustomAssetIconImage(Uint8List.fromList(<int>[1, 2, 3, 4])),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.validation,
            ),
          ),
        );

        // 4. Corrupt base64 / non-image base64 in resolveAssetVisual falls back gracefully
        final corrupt1 = resolveAssetVisual(
          iconKey: 'data:image/png;base64,!!!invalid-base64!!!',
          name: '支付宝',
          assetType: AssetType.normal,
        );
        expect(corrupt1.customImageBytes, isNull);
        expect(corrupt1.iconKey, 'alipay');

        final corrupt2 = resolveAssetVisual(
          iconKey: 'data:image/png;base64,${base64Encode(<int>[97, 98, 99])}',
          name: '现金',
          assetType: AssetType.normal,
        );
        expect(corrupt2.customImageBytes, isNull);
        expect(corrupt2.iconKey, 'cash');
      },
    );
  });

  group('LedgerService createAsset / updateAsset icon & color persistence', () {
    late AppDatabase db;
    late LedgerService ledger;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      ledger = LedgerService(db);
    });

    tearDown(() => db.close());

    test(
      'persists icon, color, subType and preserves existing values when omitted',
      () async {
        final defaultId = await ledger.createAsset(
          commandId: 'cmd-asset-default',
          name: '备用现金',
          initial: Money.parse('200.00'),
        );
        final defaultRow = await (db.select(
          db.assets,
        )..where((a) => a.id.equals(defaultId))).getSingle();
        expect(defaultRow.icon, '');
        expect(defaultRow.color, isNull);
        expect(defaultRow.subType, -1);

        final customId = await ledger.createAsset(
          commandId: 'cmd-asset-custom',
          name: '我的花呗',
          initial: -Money.parse('300.00'),
          type: AssetType.credit,
          limit: Money.parse('15000.00'),
          icon: 'huabei',
          color: '#29B6F6',
          subType: 2,
        );
        final created = await (db.select(
          db.assets,
        )..where((a) => a.id.equals(customId))).getSingle();
        expect(created.icon, 'huabei');
        expect(created.color, '#29B6F6');
        expect(created.subType, 2);

        // Omitting icon/color/subType in updateAsset preserves existing fields.
        await ledger.updateAsset(
          commandId: 'cmd-asset-update-preserve',
          assetId: customId,
          name: '蚂蚁花呗',
          countedInNetWorth: true,
          limit: Money.parse('18000.00'),
        );
        final preserved = await (db.select(
          db.assets,
        )..where((a) => a.id.equals(customId))).getSingle();
        expect(preserved.name, '蚂蚁花呗');
        expect(preserved.icon, 'huabei');
        expect(preserved.color, '#29B6F6');
        expect(preserved.subType, 2);

        // Explicitly passing new icon & color updates them cleanly.
        await ledger.updateAsset(
          commandId: 'cmd-asset-update-visual',
          assetId: customId,
          name: '京东白条',
          icon: 'baitiao',
          color: '#EF5350',
          countedInNetWorth: true,
          limit: Money.parse('18000.00'),
        );
        final updated = await (db.select(
          db.assets,
        )..where((a) => a.id.equals(customId))).getSingle();
        expect(updated.name, '京东白条');
        expect(updated.icon, 'baitiao');
        expect(updated.color, '#EF5350');
      },
    );
  });

  group('UI flows: 信用账户 labels, pickers, cold-start edit & avatars', () {
    testWidgets(
      'AssetsPage, AssetEditorPage, and AssetDetailPage render 信用账户 and AssetIconAvatar cleanly',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        final router = _buildTestRouter('/assets');
        await tester.pumpWidget(
          ProviderScope(
            retry: (_, _) => null,
            overrides: [databaseProvider.overrideWith((ref) async => db)],
            child: MaterialApp.router(routerConfig: router),
          ),
        );
        await _settle(tester);

        // On AssetsPage -> empty state shows 新建信用账户
        expect(find.byType(AssetsPage), findsOneWidget);
        expect(find.text('新建信用账户'), findsOneWidget);

        // Open AssetEditorPage via 新建信用账户 quick button
        await tester.tap(find.byKey(const Key('empty-add-credit-asset')));
        await _settle(tester);
        expect(find.byType(AssetEditorPage), findsOneWidget);
        expect(find.text('新建信用账户'), findsOneWidget);
        expect(find.text('信用账户'), findsOneWidget);
        expect(find.text('如：招行信用卡、花呗、白条'), findsOneWidget);

        // Enter name and pick custom visual via showAssetVisualPicker
        await tester.enterText(find.byKey(const Key('asset-name')), '花呗');
        await tester.pump();
        await tester.tap(find.byKey(const Key('asset-visual-picker-trigger')));
        await _settle(tester);
        await tester.tap(find.byKey(const Key('visual-color-#7E57C2')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('visual-icon-huabei')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('visual-picker-confirm')));
        await _settle(tester);

        await tester.enterText(find.byKey(const Key('credit-limit')), '12000');
        await tester.tap(find.byKey(const Key('asset-save')));
        await _settle(tester);

        // Back on AssetsPage: group header is '信用账户' and AssetIconAvatar is rendered
        expect(find.text('信用账户'), findsOneWidget);
        expect(find.text('信用卡'), findsNothing);
        expect(find.byType(AssetIconAvatar), findsOneWidget);

        final savedRow = await (db.select(
          db.assets,
        )..where((a) => a.name.equals('花呗'))).getSingle();
        expect(savedRow.icon, 'huabei');
        expect(savedRow.color, '#7E57C2');

        // Open AssetDetailPage -> renders AssetIconAvatar + '信用账户' + cold-start adjust/edit
        await tester.tap(find.text('花呗'));
        await _settle(tester);
        expect(find.byType(AssetDetailPage), findsOneWidget);
        expect(find.text('信用账户'), findsOneWidget);
        expect(find.byType(AssetIconAvatar), findsWidgets);

        // Adjust balance from AssetDetailPage without pre-watching currentBookIdProvider
        await tester.tap(find.byKey(const Key('asset-menu')));
        await _settle(tester);
        await tester.tap(find.byKey(const Key('menu-adjust')));
        await _settle(tester);
        await tester.enterText(find.byKey(const Key('adjust-amount')), '260');
        await tester.tap(find.byKey(const Key('adjust-save')));
        await _settle(tester);
        expect(find.text('欠款 260.00'), findsWidgets);

        // Open Edit from AssetDetailPage -> shows '编辑信用账户' without hanging
        await tester.tap(find.byKey(const Key('asset-menu')));
        await _settle(tester);
        await tester.tap(find.text('编辑账户'));
        await _settle(tester);
        expect(find.text('编辑信用账户'), findsOneWidget);

        await _disposeApp(tester);
        router.dispose();
        await db.close();
      },
    );

    testWidgets(
      'CategoriesPage and CalendarPage render CategoryIconAvatar and RecordTypeIconAvatar',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        final ledger = LedgerService(db);
        final now = DateTime.now();
        final catRouter = _buildTestRouter('/categories');

        await tester.pumpWidget(
          ProviderScope(
            retry: (_, _) => null,
            overrides: [databaseProvider.overrideWith((ref) async => db)],
            child: MaterialApp.router(routerConfig: catRouter),
          ),
        );
        await _settle(tester);

        // Record a bill today so CalendarPage has a daily bill row to render.
        final foodCat = await (db.select(
          db.recordCategories,
        )..where((c) => c.name.equals('餐饮'))).getSingle();
        await ledger.saveRecord(
          commandId: 'cmd-cal-food',
          draft: RecordDraft(
            bookId: 1,
            type: RecordType.expense,
            money: Money.parse('36.50'),
            categoryId: foodCat.id,
            recordTime: now.millisecondsSinceEpoch,
            remark: '午饭',
          ),
        );
        await _settle(tester);

        expect(find.byType(CategoriesPage), findsOneWidget);
        expect(find.byType(CategoryIconAvatar), findsWidgets);

        // Create a new category with showCategoryVisualPicker
        await tester.tap(find.byKey(const Key('add-category')));
        await _settle(tester);
        await tester.enterText(find.byKey(const Key('category-name')), '咖啡下午茶');
        await tester.pump();
        await tester.tap(
          find.byKey(const Key('category-visual-picker-trigger')),
        );
        await _settle(tester);
        await tester.tap(find.byKey(const Key('visual-icon-coffee')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('visual-color-#8D6E63')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('visual-picker-confirm')));
        await _settle(tester);
        await tester.tap(find.byKey(const Key('category-save')));
        await _settle(tester);

        final createdCat = await (db.select(
          db.recordCategories,
        )..where((c) => c.name.equals('咖啡下午茶'))).getSingle();
        expect(createdCat.icon, 'coffee');
        expect(createdCat.colorFill, '#8D6E63');

        await _disposeApp(tester);
        catRouter.dispose();

        // Mount CalendarPage directly to verify RecordTypeIconAvatar in daily list
        final calRouter = _buildTestRouter('/calendar');
        await tester.pumpWidget(
          ProviderScope(
            retry: (_, _) => null,
            overrides: [databaseProvider.overrideWith((ref) async => db)],
            child: MaterialApp.router(routerConfig: calRouter),
          ),
        );
        await _settle(tester);
        expect(find.byType(RecordTypeIconAvatar), findsOneWidget);
        expect(find.text('餐饮'), findsOneWidget);

        await _disposeApp(tester);
        calRouter.dispose();
        await db.close();
      },
    );
  });
}
