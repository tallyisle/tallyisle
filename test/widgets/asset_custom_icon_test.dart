import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/features/assets/asset_detail_page.dart';
import 'package:tallyisle/features/assets/asset_editor_page.dart';
import 'package:tallyisle/features/assets/assets_page.dart';
import 'package:tallyisle/features/common/catalog_icons.dart';

Future<Uint8List> _createSyntheticPng({
  int width = 140,
  int height = 90,
  Color bg = const Color(0xFF1677FF),
  Color fg = const Color(0xFFFFCA28),
}) async {
  final recorder = ui.PictureRecorder();
  final rect = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
  final canvas = Canvas(recorder, rect);
  canvas.drawRect(rect, Paint()..color = bg);
  canvas.drawCircle(rect.center, height * 0.3, Paint()..color = fg);
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return Uint8List.fromList(
      data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  } finally {
    image.dispose();
    picture.dispose();
  }
}

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

GoRouter _buildAssetRouter({
  String initialLocation = '/assets',
  Future<Uint8List?> Function()? pickCustomImageBytes,
}) => GoRouter(
  initialLocation: initialLocation,
  routes: [
    GoRoute(
      path: '/assets',
      builder: (_, _) => AssetsPage(pickCustomImageBytes: pickCustomImageBytes),
    ),
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
  ],
);

void main() {
  group('AssetIconAvatar 3-in-1 custom visual rendering', () {
    testWidgets(
      'renders preset/cat icon, 1-2 grapheme monograms & ZWJ emojis, and circular image with corrupt fallback',
      (tester) async {
        final pngBytes = (await tester.runAsync(() => _createSyntheticPng()))!;
        final encodedUri = (await tester.runAsync(
          () => encodeCustomAssetIconImage(pngBytes),
        ))!;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  const AssetIconAvatar(
                    key: Key('avatar-cat-coffee'),
                    iconKey: 'cat:coffee',
                    colorHex: '#8D6E63',
                    name: '星巴克卡',
                    assetType: AssetType.normal,
                    size: 40,
                  ),
                  const AssetIconAvatar(
                    key: Key('avatar-one-emoji'),
                    iconKey: 'text:💳',
                    colorHex: '#1677FF',
                    name: '信用卡',
                    assetType: AssetType.credit,
                    size: 40,
                  ),
                  const AssetIconAvatar(
                    key: Key('avatar-two-chars'),
                    iconKey: 'text:招商银行',
                    colorHex: '#E53935',
                    name: '招商银行',
                    assetType: AssetType.normal,
                    size: 40,
                    selected: true,
                  ),
                  const AssetIconAvatar(
                    key: Key('avatar-zwj-family'),
                    iconKey: 'text:👨‍👩‍👧',
                    colorHex: '#26A69A',
                    name: '家庭公用金',
                    assetType: AssetType.normal,
                    size: 40,
                  ),
                  AssetIconAvatar(
                    key: const Key('avatar-custom-image'),
                    iconKey: encodedUri,
                    colorHex: '#1677FF',
                    name: '自定义卡面',
                    assetType: AssetType.normal,
                    size: 44,
                    selected: true,
                  ),
                  const AssetIconAvatar(
                    key: Key('avatar-corrupt-image'),
                    iconKey: 'data:image/png;base64,!!!corrupt-base64!!!',
                    colorHex: '#07C160',
                    name: '微信钱包',
                    assetType: AssetType.normal,
                    size: 40,
                  ),
                ],
              ),
            ),
          ),
        );
        await _settle(tester);

        // 1. General category icon cat:coffee
        final coffeeIcon = tester.widget<Icon>(
          find.descendant(
            of: find.byKey(const Key('avatar-cat-coffee')),
            matching: find.byType(Icon),
          ),
        );
        expect(coffeeIcon.icon, Icons.coffee_rounded);

        // 2. Single-grapheme emoji: fontSize = size * 0.46 = 18.4
        final oneEmojiText = tester.widget<Text>(
          find.descendant(
            of: find.byKey(const Key('avatar-one-emoji')),
            matching: find.byType(Text),
          ),
        );
        expect(oneEmojiText.data, '💳');
        expect(oneEmojiText.style?.fontSize, closeTo(40 * 0.46, 0.001));
        expect(oneEmojiText.style?.letterSpacing, isNull);

        // 3. Two-grapheme monogram ('招商银行' -> '招商'), selected=true -> white text, fontSize = 40 * 0.33
        final twoCharText = tester.widget<Text>(
          find.descendant(
            of: find.byKey(const Key('avatar-two-chars')),
            matching: find.byType(Text),
          ),
        );
        expect(twoCharText.data, '招商');
        expect(twoCharText.style?.fontSize, closeTo(40 * 0.33, 0.001));
        expect(twoCharText.style?.letterSpacing, -0.5);
        expect(twoCharText.style?.color, Colors.white);

        // 4. Multi-codepoint ZWJ family emoji stays intact as 1 grapheme cluster
        final zwjText = tester.widget<Text>(
          find.descendant(
            of: find.byKey(const Key('avatar-zwj-family')),
            matching: find.byType(Text),
          ),
        );
        expect(zwjText.data, '👨‍👩‍👧');
        expect(zwjText.style?.fontSize, closeTo(40 * 0.46, 0.001));

        // 5. Valid custom image renders ClipOval + Image.memory
        expect(
          find.descendant(
            of: find.byKey(const Key('avatar-custom-image')),
            matching: find.byType(ClipOval),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const Key('avatar-custom-image')),
            matching: find.byType(Image),
          ),
          findsOneWidget,
        );

        // 6. Corrupt base64 falls back cleanly to keyword preset ('wechat_pay')
        final fallbackIcon = tester.widget<Icon>(
          find.descendant(
            of: find.byKey(const Key('avatar-corrupt-image')),
            matching: find.byType(Icon),
          ),
        );
        expect(fallbackIcon.icon, Icons.chat_bubble_rounded);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('Custom Asset Visual Picker & AssetsPage end-to-end flows', () {
    testWidgets(
      'supports expanded presets, cat:<key> general icons, text/Emoji monograms, and custom image upload/reset',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        final validPng = (await tester.runAsync(() => _createSyntheticPng()))!;
        var pickAttempt = 0;

        final router = _buildAssetRouter(
          pickCustomImageBytes: () async {
            pickAttempt++;
            if (pickAttempt == 1) {
              // First attempt simulates corrupted / non-image file
              return Uint8List.fromList(<int>[1, 2, 3, 4, 5]);
            }
            return validPng;
          },
        );

        await tester.pumpWidget(
          ProviderScope(
            retry: (_, _) => null,
            overrides: [databaseProvider.overrideWith((ref) async => db)],
            child: MaterialApp.router(routerConfig: router),
          ),
        );
        await _settle(tester);

        // Create an account via AssetEditorPage picking a general icon ('cat:coffee')
        await tester.tap(find.byKey(const Key('add-asset')));
        await _settle(tester);
        await tester.enterText(find.byKey(const Key('asset-name')), '星巴克储值卡');
        await tester.pump();
        await tester.tap(find.byKey(const Key('asset-visual-picker-trigger')));
        await _settle(tester);

        // Verify 3 mode tabs exist
        expect(
          find.byKey(const Key('asset-picker-mode-preset')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('asset-picker-mode-text')), findsOneWidget);
        expect(
          find.byKey(const Key('asset-picker-mode-image')),
          findsOneWidget,
        );
        // Verify new financial preset exists in preset tab
        expect(find.byKey(const Key('visual-icon-unionpay')), findsOneWidget);

        // Scroll down in preset tab to '更多通用图标' and pick 'cat:coffee'
        await tester.scrollUntilVisible(
          find.byKey(const Key('visual-icon-cat-coffee')),
          240,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('visual-icon-cat-coffee')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('visual-color-#8D6E63')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('visual-picker-confirm')));
        await _settle(tester);

        await tester.enterText(find.byKey(const Key('asset-balance')), '300');
        await tester.tap(find.byKey(const Key('asset-save')));
        await _settle(tester);

        // Back on AssetsPage: discoverability helper & customize badge are visible
        expect(find.text('点击自定义图标'), findsOneWidget);
        expect(
          find.byKey(const Key('asset-customize-icon-星巴克储值卡')),
          findsOneWidget,
        );
        var row = await (db.select(
          db.assets,
        )..where((a) => a.name.equals('星巴克储值卡'))).getSingle();
        expect(row.icon, 'cat:coffee');
        expect(row.color, '#8D6E63');

        // Tap avatar customize badge directly on AssetsPage -> switch to '文字/Emoji'
        await tester.tap(find.byKey(const Key('asset-customize-icon-星巴克储值卡')));
        await _settle(tester);
        await tester.tap(find.byKey(const Key('asset-picker-mode-text')));
        await _settle(tester);

        // Auto-derived chip from previewName ('星巴') + common bank/Emoji chips exist
        expect(
          find.byKey(const Key('asset-picker-text-chip-星巴')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('asset-picker-text-chip-招行')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('asset-picker-text-chip-💳')),
          findsOneWidget,
        );

        // Enter >2 chars ('招商银行') -> truncated safely to 2 graphemes ('招商')
        await tester.enterText(
          find.byKey(const Key('asset-picker-custom-text-input')),
          '招商银行',
        );
        await tester.pump();
        final inputAfterTruncate = tester.widget<TextField>(
          find.byKey(const Key('asset-picker-custom-text-input')),
        );
        expect(inputAfterTruncate.controller?.text, '招商');

        // Enter ZWJ family emoji ('👨‍👩‍👧') -> kept intact as 1 grapheme
        await tester.enterText(
          find.byKey(const Key('asset-picker-custom-text-input')),
          '👨‍👩‍👧',
        );
        await tester.pump();
        expect(inputAfterTruncate.controller?.text, '👨‍👩‍👧');

        // Pick '招行' quick chip + festive red color '#E53935' and confirm
        await tester.tap(find.byKey(const Key('asset-picker-text-chip-招行')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('visual-color-#E53935')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('visual-picker-confirm')));
        await _settle(tester);

        row = await (db.select(
          db.assets,
        )..where((a) => a.name.equals('星巴克储值卡'))).getSingle();
        expect(row.icon, 'text:招行');
        expect(row.color, '#E53935');
        expect(find.text('招行'), findsOneWidget);

        // Re-open picker -> starts on '文字/Emoji' mode; switch to '自定义图片'
        await tester.tap(find.byKey(const Key('asset-customize-icon-星巴克储值卡')));
        await _settle(tester);
        expect(
          find.byKey(const Key('asset-picker-custom-text-input')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('asset-picker-mode-image')));
        await _settle(tester);

        expect(find.text('从相册 / 文件选择图片'), findsOneWidget);
        expect(
          find.byKey(const Key('asset-picker-reset-icon-btn')),
          findsNothing,
        );

        // 1st upload attempt returns corrupt bytes -> shows friendly SnackBar
        await tester.tap(
          find.byKey(const Key('asset-picker-upload-image-btn')),
        );
        await _settle(tester);
        expect(find.byType(SnackBar), findsOneWidget);
        expect(find.textContaining('无法解析所选图片'), findsOneWidget);

        // 2nd upload attempt returns valid 140x90 PNG -> crops to 96x96 circular PNG
        await tester.tap(
          find.byKey(const Key('asset-picker-upload-image-btn')),
        );
        await _settle(tester);
        expect(find.text('更换图片'), findsOneWidget);
        expect(
          find.byKey(const Key('asset-picker-reset-icon-btn')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const Key('asset-picker-image-preview')),
            matching: find.byType(Image),
          ),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const Key('visual-picker-confirm')));
        await _settle(tester);

        row = await (db.select(
          db.assets,
        )..where((a) => a.name.equals('星巴克储值卡'))).getSingle();
        expect(row.icon, startsWith('data:image/png;base64,'));
        // Balance and metadata untouched
        expect(row.balanceMinor, BigInt.from(30000));

        // Re-open picker -> opens in '自定义图片' mode -> tap '恢复预设图标' -> confirm
        await tester.tap(find.byKey(const Key('asset-customize-icon-星巴克储值卡')));
        await _settle(tester);
        expect(
          find.byKey(const Key('asset-picker-reset-icon-btn')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('asset-picker-reset-icon-btn')));
        await tester.pump();
        expect(find.text('从相册 / 文件选择图片'), findsOneWidget);
        await tester.tap(find.byKey(const Key('visual-picker-confirm')));
        await _settle(tester);

        row = await (db.select(
          db.assets,
        )..where((a) => a.name.equals('星巴克储值卡'))).getSingle();
        expect(row.icon, isNot(startsWith('data:image/')));
        expect(row.icon, isNotEmpty);

        await _disposeApp(tester);
        router.dispose();
        await db.close();
      },
    );

    testWidgets(
      'renders cleanly at narrow 360dp width across all 3 picker modes with zero overflow',
      (tester) async {
        tester.view.physicalSize = const Size(360, 640);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final db = AppDatabase(NativeDatabase.memory());
        final ledger = LedgerService(db);
        await ledger.createAsset(
          commandId: 'cmd-narrow-1',
          name: '招商银行工资卡',
          initial: Money.parse('5200.00'),
          icon: 'text:招行',
          color: '#E53935',
        );

        final router = _buildAssetRouter();
        await tester.pumpWidget(
          ProviderScope(
            retry: (_, _) => null,
            overrides: [databaseProvider.overrideWith((ref) async => db)],
            child: MaterialApp.router(routerConfig: router),
          ),
        );
        await _settle(tester);
        expect(tester.takeException(), isNull);

        await tester.tap(find.byKey(const Key('asset-customize-icon-招商银行工资卡')));
        await _settle(tester);
        expect(tester.takeException(), isNull);

        await tester.tap(find.byKey(const Key('asset-picker-mode-preset')));
        await _settle(tester);
        expect(tester.takeException(), isNull);

        await tester.tap(find.byKey(const Key('asset-picker-mode-image')));
        await _settle(tester);
        expect(tester.takeException(), isNull);

        await tester.tap(find.byKey(const Key('visual-picker-confirm')));
        await _settle(tester);
        expect(tester.takeException(), isNull);

        await _disposeApp(tester);
        router.dispose();
        await db.close();
      },
    );
  });
}
