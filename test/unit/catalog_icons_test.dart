import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tallyisle/app/providers.dart';
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

void main() {
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
