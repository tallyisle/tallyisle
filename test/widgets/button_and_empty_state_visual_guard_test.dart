import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:tallyisle/app/adaptive.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/domain/ledger/asset_json.dart' show endOfMonthDay;
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/features/assets/asset_editor_page.dart';
import 'package:tallyisle/features/assets/assets_page.dart';
import 'package:tallyisle/features/backup/backup_page.dart';
import 'package:tallyisle/features/backup/backup_providers.dart';
import 'package:tallyisle/features/category_transfer/category_transfer_page.dart';
import 'package:tallyisle/features/category_transfer/category_transfer_providers.dart';
import 'package:tallyisle/features/common/tally_button.dart';
import 'package:tallyisle/features/common/tally_card.dart';
import 'package:tallyisle/features/common/tally_form_fields.dart';
import 'package:tallyisle/features/csv_transfer/csv_export_page.dart';
import 'package:tallyisle/features/csv_transfer/csv_import_page.dart';
import 'package:tallyisle/features/migration/migration_page.dart';
import 'package:tallyisle/features/migration/migration_providers.dart';
import 'package:tallyisle/features/reminder/reminder_providers.dart';
import 'package:tallyisle/platform/files.dart';
import 'package:tallyisle/platform/notifications.dart';

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 14; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

ThemeData _guardTheme(Brightness brightness, {required bool isDesktop}) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF2E7D6B),
    brightness: brightness,
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    cardTheme: tallyCardTheme(scheme),
    inputDecorationTheme: tallyInputDecorationTheme(
      scheme,
      isDesktop: isDesktop,
    ),
    chipTheme: tallyChipTheme(scheme, isDesktop: isDesktop),
    segmentedButtonTheme: tallySegmentedButtonTheme(
      scheme,
      isDesktop: isDesktop,
    ),
    filledButtonTheme: tallyPrimaryButtonTheme(scheme, isDesktop: isDesktop),
    outlinedButtonTheme: tallySoftOutlinedButtonTheme(
      scheme,
      isDesktop: isDesktop,
    ),
    textButtonTheme: tallyTextButtonTheme(scheme),
    floatingActionButtonTheme: tallyFabTheme(scheme),
  );
}

/// The [Material] painted by a [ButtonStyleButton] carries the resolved
/// shape (with the resolved side merged in) and background color.
Material _buttonMaterial(WidgetTester tester, Finder button) =>
    tester.widget<Material>(
      find.descendant(of: button, matching: find.byType(Material)).first,
    );

void _expectNestedRadius(ShapeBorder? shape, {required String label}) {
  expect(shape, isA<RoundedRectangleBorder>(), reason: label);
  final rr = shape! as RoundedRectangleBorder;
  expect(
    rr.borderRadius,
    BorderRadius.circular(kTallyNestedRadius),
    reason: '$label must use the 12dp nested radius',
  );
}

const _forbiddenEmptyHints = <String>['点右下角', '点击右下角', '点右上角', '点击右上角'];

void _expectNoForbiddenHints() {
  for (final hint in _forbiddenEmptyHints) {
    expect(find.textContaining(hint), findsNothing, reason: hint);
  }
}

/// Every enabled soft action button rendered on the page must share exactly
/// the same soft tonal fill, so sibling buttons inside one card never mix
/// solid / outlined / tonal looks.
int _expectUniformSoftButtons(WidgetTester tester, {required String label}) {
  final context = tester.element(find.byType(Scaffold).first);
  final expected = tallySoftButtonFillColor(Theme.of(context).colorScheme);
  var enabled = 0;
  final finder = find.byWidgetPredicate((w) => w is TallySoftButton);
  for (final element in finder.evaluate()) {
    final button = element.widget as TallySoftButton;
    if (!button.enabled) continue;
    enabled++;
    final material = _buttonMaterial(tester, find.byWidget(button));
    expect(
      material.color,
      expected,
      reason: '$label: ${button.key} must use tallySoftButtonFillColor',
    );
    _expectNestedRadius(material.shape, label: '$label ${button.key}');
    expect(
      (material.shape! as RoundedRectangleBorder).side,
      BorderSide.none,
      reason: '$label: ${button.key} must stay borderless',
    );
  }
  for (final element in find.byType(OutlinedButton).evaluate()) {
    final material = _buttonMaterial(tester, find.byWidget(element.widget));
    expect(
      (material.shape! as RoundedRectangleBorder).side,
      BorderSide.none,
      reason: '$label: fallback OutlinedButton must stay borderless',
    );
  }
  return enabled;
}

void _expectSameFill(
  WidgetTester tester,
  List<String> keys, {
  required String label,
}) {
  final colors = <Color?>{};
  for (final k in keys) {
    final f = find.byKey(Key(k));
    expect(f, findsOneWidget, reason: '$label: $k');
    final button = tester.widget<FilledButton>(f);
    expect(button, isA<TallySoftButton>(), reason: '$label: $k');
    if (!button.enabled) continue;
    colors.add(_buttonMaterial(tester, f).color);
  }
  expect(colors.length, lessThanOrEqualTo(1), reason: '$label: $keys');
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('Global button & borderless form themes', () {
    for (final brightness in Brightness.values) {
      testWidgets(
        'TallySoftButton / FilledButton / OutlinedButton share 12dp radius, soft ones stay borderless ($brightness)',
        (tester) async {
          for (final isDesktop in const [false, true]) {
            final theme = _guardTheme(brightness, isDesktop: isDesktop);
            await tester.pumpWidget(
              DesktopAdaptiveScope(
                isDesktop: isDesktop,
                child: MaterialApp(
                  theme: theme,
                  home: Scaffold(
                    body: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TallySoftButton(
                            key: const Key('g-soft'),
                            onPressed: () {},
                            child: const Text('功能'),
                          ),
                          TallySoftButton.icon(
                            key: const Key('g-soft-icon'),
                            compact: true,
                            onPressed: () {},
                            icon: const Icon(Icons.add),
                            label: const Text('新建'),
                          ),
                          FilledButton(
                            key: const Key('g-filled'),
                            onPressed: () {},
                            child: const Text('保存'),
                          ),
                          OutlinedButton(
                            key: const Key('g-outlined'),
                            onPressed: () {},
                            child: const Text('兜底'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pump();
            expect(tester.takeException(), isNull);

            final scheme = theme.colorScheme;
            final softFill = tallySoftButtonFillColor(scheme);
            final tag = '$brightness desktop=$isDesktop';

            // TallySoftButton must still be a FilledButton for legacy probes.
            expect(
              tester.widget<FilledButton>(find.byKey(const Key('g-soft'))),
              isA<TallySoftButton>(),
            );

            for (final k in const ['g-soft', 'g-soft-icon', 'g-outlined']) {
              final m = _buttonMaterial(tester, find.byKey(Key(k)));
              _expectNestedRadius(m.shape, label: '$tag $k');
              expect(
                (m.shape! as RoundedRectangleBorder).side,
                BorderSide.none,
                reason: '$tag $k must be borderless',
              );
              expect(m.color, softFill, reason: '$tag $k soft fill');
              expect(m.elevation, 0, reason: '$tag $k elevation');
            }

            final filled = _buttonMaterial(
              tester,
              find.byKey(const Key('g-filled')),
            );
            _expectNestedRadius(filled.shape, label: '$tag g-filled');
            expect(
              filled.color,
              scheme.primary,
              reason: '$tag primary FilledButton keeps solid primary fill',
            );
            expect(filled.color, isNot(softFill));

            // Theme data itself is wired with the 12dp shapes.
            for (final style in [
              theme.filledButtonTheme.style,
              theme.outlinedButtonTheme.style,
              theme.textButtonTheme.style,
            ]) {
              _expectNestedRadius(
                style!.shape!.resolve(<WidgetState>{}),
                label: '$tag theme',
              );
            }
            expect(
              theme.outlinedButtonTheme.style!.side!.resolve(<WidgetState>{}),
              BorderSide.none,
            );
            final fabShape = theme.floatingActionButtonTheme.shape;
            expect(fabShape, isA<RoundedRectangleBorder>());
            expect(
              (fabShape! as RoundedRectangleBorder).borderRadius,
              BorderRadius.circular(kTallyCardRadius),
            );

            // Disabled soft buttons fall back to the muted disabled fill.
            final soft = tester.widget<TallySoftButton>(
              find.byKey(const Key('g-soft')),
            );
            final disabledBg = soft
                .defaultStyleOf(tester.element(find.byKey(const Key('g-soft'))))
                .backgroundColor!
                .resolve({WidgetState.disabled});
            expect(disabledBg, scheme.onSurface.withValues(alpha: 0.06));
          }
          await tester.pumpWidget(const SizedBox());
        },
      );

      testWidgets(
        'InputDecorationTheme, ChipTheme, and SegmentedButtonTheme stay borderless ($brightness)',
        (tester) async {
          for (final isDesktop in const [false, true]) {
            final theme = _guardTheme(brightness, isDesktop: isDesktop);
            final scheme = theme.colorScheme;
            final nestedFill = tallyNestedSurfaceColor(scheme);
            final softFill = tallySoftButtonFillColor(scheme);

            await tester.pumpWidget(
              DesktopAdaptiveScope(
                isDesktop: isDesktop,
                child: MaterialApp(
                  theme: theme,
                  home: Scaffold(
                    body: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const TextField(
                            key: Key('g-textfield'),
                            decoration: InputDecoration(labelText: '名称'),
                          ),
                          const SizedBox(height: 12),
                          TallySelectField<int>(
                            key: const Key('g-select'),
                            label: '分类',
                            value: 1,
                            options: const [
                              TallySelectOption(value: 1, label: '餐饮'),
                            ],
                            onChanged: (_) {},
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            children: [
                              const Chip(key: Key('g-chip'), label: Text('标签')),
                              ChoiceChip(
                                key: const Key('g-choice-selected'),
                                label: const Text('已选'),
                                selected: true,
                                onSelected: (_) {},
                              ),
                              ChoiceChip(
                                key: const Key('g-choice-unselected'),
                                label: const Text('未选'),
                                selected: false,
                                onSelected: (_) {},
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          SegmentedButton<int>(
                            key: const Key('g-segmented'),
                            showSelectedIcon: false,
                            segments: const [
                              ButtonSegment(value: 0, label: Text('支出')),
                              ButtonSegment(value: 1, label: Text('收入')),
                            ],
                            selected: const {0},
                            onSelectionChanged: (_) {},
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pump();
            expect(tester.takeException(), isNull);

            // 1. InputDecorationTheme checks
            final inputTheme = theme.inputDecorationTheme;
            expect(inputTheme.filled, isTrue);
            expect(inputTheme.fillColor, nestedFill);
            expect(
              inputTheme.contentPadding,
              EdgeInsets.symmetric(horizontal: 14, vertical: isDesktop ? 8 : 7),
            );
            for (final b in [
              inputTheme.border,
              inputTheme.enabledBorder,
              inputTheme.disabledBorder,
            ]) {
              expect(b, isA<OutlineInputBorder>());
              final ob = b! as OutlineInputBorder;
              expect(ob.isOutline, isFalse);
              expect(ob.borderSide, BorderSide.none);
              expect(
                ob.borderRadius,
                BorderRadius.circular(kTallyNestedRadius),
              );
            }
            final focused = inputTheme.focusedBorder! as OutlineInputBorder;
            expect(focused.isOutline, isFalse);
            expect(focused.borderSide.width, 1.2);
            expect(
              focused.borderSide.color,
              scheme.primary.withValues(alpha: 0.65),
            );
            final errBorder = inputTheme.errorBorder! as OutlineInputBorder;
            expect(errBorder.isOutline, isFalse);
            expect(errBorder.borderSide.width, 1.2);
            expect(errBorder.borderSide.color, scheme.error);

            // Floating labelText stays strictly INSIDE the 12dp tonal fill box
            await tester.enterText(
              find.byKey(const Key('g-textfield')),
              '日常开销',
            );
            await tester.pumpAndSettle();
            final tfRect = tester.getRect(find.byKey(const Key('g-textfield')));
            final labelRect = tester.getRect(find.text('名称'));
            expect(labelRect.top, greaterThanOrEqualTo(tfRect.top + 4.0));
            expect(labelRect.bottom, lessThanOrEqualTo(tfRect.bottom - 16.0));

            // TextField & TallySelectField visual height parity
            final tfHeight = tfRect.height;
            final sfHeight = tester
                .getSize(find.byKey(const Key('g-select')))
                .height;
            expect((tfHeight - sfHeight).abs(), lessThanOrEqualTo(2.0));

            // 2. ChipTheme checks
            final chipTheme = theme.chipTheme;
            expect(chipTheme.side, BorderSide.none);
            expect(chipTheme.showCheckmark, isFalse);
            expect(chipTheme.backgroundColor, nestedFill);
            expect(chipTheme.selectedColor, softFill);
            expect(chipTheme.elevation, 0);
            expect(chipTheme.pressElevation, 0);
            expect(chipTheme.shape, isA<RoundedRectangleBorder>());
            expect(
              (chipTheme.shape! as RoundedRectangleBorder).borderRadius,
              BorderRadius.circular(10),
            );

            // 3. SegmentedButtonTheme checks
            final segStyle = theme.segmentedButtonTheme.style!;
            expect(segStyle.side!.resolve(<WidgetState>{}), BorderSide.none);
            expect(
              segStyle.side!.resolve({WidgetState.selected}),
              BorderSide.none,
            );
            _expectNestedRadius(
              segStyle.shape!.resolve(<WidgetState>{}),
              label: 'segmented shape',
            );
            expect(
              segStyle.backgroundColor!.resolve({WidgetState.selected}),
              softFill,
            );
            expect(
              segStyle.backgroundColor!.resolve(<WidgetState>{}),
              nestedFill,
            );
            expect(
              segStyle.backgroundColor!.resolve({WidgetState.disabled}),
              scheme.onSurface.withValues(alpha: 0.05),
            );
            expect(
              segStyle.foregroundColor!.resolve({WidgetState.selected}),
              scheme.onPrimaryContainer,
            );
            expect(
              segStyle.foregroundColor!.resolve(<WidgetState>{}),
              scheme.onSurfaceVariant,
            );
            expect(
              segStyle.minimumSize!.resolve(<WidgetState>{}),
              Size(0, isDesktop ? 38 : 36),
            );
          }
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  });

  group('TallySelectField, CreditDayPicker & TallyFormCard/Tile', () {
    testWidgets(
      'TallySelectField supports mobile sheet (<=35 non-lazy & >35 searchable), desktop dialog, nullable T?, and 96px narrow safety',
      (tester) async {
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        // 1. Mobile bottom sheet: <= 35 items rendered non-lazily + nullable int? round-trip
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;

        int? selectedNullable = 2;
        var customTapped = 0;

        await tester.pumpWidget(
          DesktopAdaptiveScope(
            isDesktop: false,
            child: MaterialApp(
              theme: _guardTheme(Brightness.light, isDesktop: false),
              home: StatefulBuilder(
                builder: (context, setState) => Scaffold(
                  body: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      TallyFormCard(
                        title: '筛选条件',
                        subtitle: '测试无边框表单卡片',
                        spacing: 10,
                        children: [
                          TallySelectField<int?>(
                            key: const Key('nullable-select'),
                            label: '关联账户',
                            value: selectedNullable,
                            helperText: '支持空值回传',
                            options: [
                              const TallySelectOption<int?>(
                                value: null,
                                label: '不限账户',
                              ),
                              for (var i = 1; i <= 30; i++)
                                TallySelectOption<int?>(
                                  value: i,
                                  label: '测试账户 $i',
                                  subtitle: i == 30 ? '第 30 个非懒加载项' : null,
                                ),
                            ],
                            onChanged: (v) =>
                                setState(() => selectedNullable = v),
                          ),
                          TallyFormTile(
                            tileKey: const Key('custom-form-tile'),
                            leading: const Icon(Icons.palette_outlined),
                            title: '图标与颜色',
                            subtitle: '点击更换',
                            onTap: () => setState(() => customTapped++),
                          ),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: SizedBox(
                              width: 96,
                              child: TallySelectField<int>(
                                key: const Key('narrow-96-select'),
                                label: '超窄标签防溢出测试',
                                value: 1,
                                leading: const CircleAvatar(
                                  radius: 16,
                                  child: Icon(Icons.wallet),
                                ),
                                options: const [
                                  TallySelectOption<int>(
                                    value: 1,
                                    label: '超长选项文案在96px下单行省略不溢出',
                                  ),
                                ],
                                onChanged: (_) {},
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          tester
              .widget<TallySelectField<int?>>(
                find.byKey(const Key('nullable-select')),
              )
              .value,
          2,
        );
        expect(find.text('测试账户 2'), findsOneWidget);

        // Tap tile inside TallyFormCard
        await tester.tap(find.byKey(const Key('custom-form-tile')));
        await tester.pump();
        expect(customTapped, 1);

        // Open mobile sheet: 31 options (<= 35) -> item 30 must already be in widget tree!
        await tester.tap(find.byKey(const Key('nullable-select')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const Key('tally-select-search-input')),
          findsOneWidget,
        );
        expect(find.text('测试账户 30'), findsOneWidget);
        expect(find.byType(CloseButton), findsNothing);

        // Select `null` option ('不限账户') and verify record wrapper delivers null!
        await tester.tap(find.text('不限账户'));
        await tester.pumpAndSettle();
        expect(selectedNullable, isNull);
        expect(
          tester
              .widget<TallySelectField<int?>>(
                find.byKey(const Key('nullable-select')),
              )
              .value,
          isNull,
        );
        expect(find.text('不限账户'), findsOneWidget);

        // 2. Desktop centered 18dp Dialog + > 35 options ListView.builder + search filtering
        tester.view.physicalSize = const Size(1280, 800);
        String selectedCurrency = 'CNY';
        final manyOptions = [
          const TallySelectOption<String>(
            value: 'CNY',
            label: '人民币 (CNY)',
            searchKeywords: 'rmb yuan',
          ),
          for (var i = 1; i <= 50; i++)
            TallySelectOption<String>(
              value: 'CUR$i',
              label: '外币选项 $i',
              searchKeywords: 'fx_$i',
            ),
        ];

        await tester.pumpWidget(
          DesktopAdaptiveScope(
            isDesktop: true,
            child: MaterialApp(
              theme: _guardTheme(Brightness.dark, isDesktop: true),
              home: StatefulBuilder(
                builder: (context, setState) => Scaffold(
                  body: Center(
                    child: SizedBox(
                      width: 320,
                      child: TallySelectField<String>(
                        key: const Key('desktop-currency-select'),
                        label: '结算币种',
                        value: selectedCurrency,
                        searchable: true,
                        options: manyOptions,
                        onChanged: (v) => setState(() => selectedCurrency = v),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        await tester.tap(find.byKey(const Key('desktop-currency-select')));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsOneWidget);
        expect(find.byType(CloseButton), findsOneWidget);
        expect(find.byType(ListView), findsOneWidget);

        final dialog = tester.widget<Dialog>(find.byType(Dialog));
        expect(
          (dialog.shape! as RoundedRectangleBorder).borderRadius,
          BorderRadius.circular(18),
        );

        // Search by keyword -> narrows filtered list to 1 (<= 35) and selects it
        await tester.enterText(
          find.byKey(const Key('tally-select-search-input')),
          'fx_42',
        );
        await tester.pumpAndSettle();
        expect(find.text('外币选项 42'), findsOneWidget);
        await tester.tap(find.text('外币选项 42'));
        await tester.pumpAndSettle();
        expect(selectedCurrency, 'CUR42');

        // 3. AlertDialog (IntrinsicWidth) compatibility without SizedBox wrapper
        final hostCtx = tester.element(find.byType(Scaffold));
        // ignore: unawaited_futures
        showDialog<void>(
          context: hostCtx,
          builder: (ctx) => AlertDialog(
            title: const Text('IntrinsicWidth 弹窗测试'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TallySelectField<String>(
                  key: const Key('alert-dialog-select'),
                  label: '账本',
                  value: 'default',
                  leading: const Icon(Icons.book_outlined),
                  options: const [
                    TallySelectOption(value: 'default', label: '默认账本'),
                  ],
                  onChanged: (_) {},
                ),
              ],
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('alert-dialog-select')), findsOneWidget);
        Navigator.of(hostCtx).pop();
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'showCreditDayPickerSheetOrDialog renders 1..28 grid + endOfMonthDay on mobile and desktop',
      (tester) async {
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        for (final (isDesktop, size) in const [
          (false, Size(390, 844)),
          (true, Size(1280, 800)),
        ]) {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;
          var day = 15;

          await tester.pumpWidget(
            DesktopAdaptiveScope(
              isDesktop: isDesktop,
              child: MaterialApp(
                theme: _guardTheme(Brightness.light, isDesktop: isDesktop),
                home: StatefulBuilder(
                  builder: (context, setState) => Scaffold(
                    body: Center(
                      child: TallySelectField<int>(
                        key: const Key('credit-day-trigger'),
                        label: '账单日',
                        value: day,
                        displayText: day == endOfMonthDay ? '月底' : '每月 $day 日',
                        onCustomTap: () async {
                          final picked = await showCreditDayPickerSheetOrDialog(
                            context,
                            title: '选择账单日',
                            currentDay: day,
                          );
                          if (picked != null) {
                            setState(() => day = picked);
                          }
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          // Pick day 28
          await tester.tap(find.byKey(const Key('credit-day-trigger')));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          if (isDesktop) {
            expect(find.byType(Dialog), findsOneWidget);
          }
          expect(find.byKey(const Key('credit-day-option-1')), findsOneWidget);
          expect(find.byKey(const Key('credit-day-option-28')), findsOneWidget);
          expect(find.text('28日'), findsOneWidget);
          expect(find.bySemanticsLabel('每月 28 日'), findsOneWidget);
          expect(
            find.byKey(const Key('credit-day-option-end')),
            findsOneWidget,
          );
          expect(find.text('月底（每月最后一天）'), findsOneWidget);

          await tester.tap(find.byKey(const Key('credit-day-option-28')));
          await tester.pumpAndSettle();
          expect(day, 28);
          expect(find.text('每月 28 日'), findsOneWidget);

          // Pick end of month
          await tester.tap(find.byKey(const Key('credit-day-trigger')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('credit-day-option-end')));
          await tester.pumpAndSettle();
          expect(day, endOfMonthDay);
          expect(find.text('月底'), findsOneWidget);
        }
      },
    );
  });

  group('Transfer / backup pages keep sibling buttons uniform', () {
    const sizes = <(String, Size, bool)>[
      ('phone-360', Size(360, 800), false),
      ('phone', Size(390, 844), false),
      ('desktop', Size(1280, 800), true),
    ];

    Future<void> runPageMatrix(
      WidgetTester tester, {
      required String label,
      required Widget Function() page,
      List<Override> Function(AppDatabase db, Directory root)? overrides,
      Future<void> Function(WidgetTester tester, bool isDesktop)? extraChecks,
    }) async {
      late final AppDatabase db;
      await tester.runAsync(() async {
        db = AppDatabase(NativeDatabase.memory());
      });
      final scheduler = InMemoryReminderScheduler();
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('btn_guard_'),
      ))!;
      var closed = false;
      Future<void> dispose() async {
        if (closed) return;
        closed = true;
        await tester.pumpWidget(const SizedBox());
        await _settle(tester);
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(scheduler.dispose);
        await tester.runAsync(db.close);
        await tester.runAsync(() async {
          if (await root.exists()) await root.delete(recursive: true);
        });
      }

      addTearDown(dispose);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      for (final brightness in Brightness.values) {
        for (final (sizeLabel, size, isDesktop) in sizes) {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;
          await tester.pumpWidget(
            ProviderScope(
              key: ValueKey('$label-$brightness-$sizeLabel'),
              retry: (_, _) => null,
              overrides: [
                databaseProvider.overrideWith((ref) async => db),
                reminderSchedulerProvider.overrideWithValue(scheduler),
                ...?overrides?.call(db, root),
              ],
              child: DesktopAdaptiveScope(
                isDesktop: isDesktop,
                child: MaterialApp(
                  theme: _guardTheme(brightness, isDesktop: isDesktop),
                  home: page(),
                ),
              ),
            ),
          );
          await _settle(tester);
          final tag = '$label $brightness $sizeLabel';
          expect(tester.takeException(), isNull, reason: '$tag overflow');
          final count = _expectUniformSoftButtons(tester, label: tag);
          expect(
            count,
            greaterThanOrEqualTo(1),
            reason: '$tag should render soft action buttons',
          );
          if (extraChecks != null) {
            await extraChecks(tester, isDesktop);
            expect(tester.takeException(), isNull, reason: '$tag extra');
            _expectUniformSoftButtons(tester, label: '$tag extra');
          }
        }
      }
      await dispose();
    }

    const fakeFiles = FileAccess(isWebOverride: false, isOhosOverride: false);

    testWidgets('MigrationPage', (tester) async {
      await runPageMatrix(
        tester,
        label: 'MigrationPage',
        page: () => const MigrationPage(),
        overrides: (_, _) => [
          migrationFileAccessProvider.overrideWithValue(fakeFiles),
        ],
        extraChecks: (tester, _) async {
          _expectSameFill(tester, const [
            'migration_open_yiyu_sheet_button',
            'migration_pick_yiyu_backup_button',
          ], label: 'yiyu card');
        },
      );
    });

    testWidgets('BackupPage', (tester) async {
      await runPageMatrix(
        tester,
        label: 'BackupPage',
        page: () => const BackupPage(),
        overrides: (_, root) => [
          backupFileAccessProvider.overrideWithValue(
            FileAccess(
              onSaveBytes: (_, _, _) async {},
              onShareBytes: (_, _, _, _) async {},
            ),
          ),
          backupLocalDirectoryOverrideProvider.overrideWithValue(
            () async => Directory(p.join(root.path, 'local')),
          ),
          backupAttachmentsDirectoryOverrideProvider.overrideWithValue(
            () async => Directory(p.join(root.path, 'att')),
          ),
        ],
        extraChecks: (tester, _) async {
          final create = find.byKey(const Key('local_backup_create_button'));
          await tester.scrollUntilVisible(
            create,
            200,
            scrollable: find.byType(Scrollable).first,
          );
          await _settle(tester);
          _expectSameFill(tester, const [
            'local_backup_create_button',
            'local_backup_import_button',
          ], label: 'local backup card');
        },
      );
    });

    testWidgets('CategoryTransferPage', (tester) async {
      await runPageMatrix(
        tester,
        label: 'CategoryTransferPage',
        page: () => const CategoryTransferPage(),
        overrides: (_, _) => [
          categoryTransferFileAccessProvider.overrideWithValue(fakeFiles),
        ],
        extraChecks: (tester, isDesktop) async {
          _expectSameFill(tester, [
            'cat-export-save-btn',
            if (!isDesktop) 'cat-export-share-btn',
            'cat-import-pick-btn',
          ], label: 'category JSON cards');
        },
      );
    });

    testWidgets('CsvExportPage', (tester) async {
      await runPageMatrix(
        tester,
        label: 'CsvExportPage',
        page: () => CsvExportPage(
          saveFile: (_, _) async {},
          shareFile: (_, _) async {},
        ),
        extraChecks: (tester, _) async {
          final dateSwitch = find.byKey(const Key('export_date_filter_switch'));
          if (!tester.widget<SwitchListTile>(dateSwitch).value) {
            await tester.tap(dateSwitch);
            await _settle(tester);
          }
          _expectSameFill(tester, const [
            'export_start_date_button',
            'export_end_date_button',
            'share_csv_export_button',
            'confirm_csv_export_button',
          ], label: 'csv export card');
          final bookField = tester.widget<TallySelectField<int>>(
            find.byKey(const Key('export_book_dropdown')),
          );
          expect(bookField.value, noRef);
        },
      );
    });

    testWidgets('CsvImportPage', (tester) async {
      await runPageMatrix(
        tester,
        label: 'CsvImportPage',
        page: () => const CsvImportPage(),
        extraChecks: (tester, _) async {
          _expectSameFill(tester, const [
            'open_csv_export_button',
            'open_import_batches_button',
            'pick_import_file_button',
            'export_template_v3_button',
          ], label: 'csv import appbar & card');
        },
      );
    });
  });

  group('AssetsPage empty guide card', () {
    const layouts = <(String, Size, bool, bool)>[
      // label, size, isDesktop, expect side-by-side scene cards
      ('phone 390x844', Size(390, 844), false, false),
      ('single column 800x700', Size(800, 700), true, true),
      ('master-detail 1280x800', Size(1280, 800), true, false),
    ];

    for (final (label, size, isDesktop, sideBySide) in layouts) {
      testWidgets('$label renders guide card and opens typed editors', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        late final AppDatabase db;
        await tester.runAsync(() async {
          db = AppDatabase(NativeDatabase.memory());
        });
        var closed = false;
        Future<void> dispose() async {
          if (closed) return;
          closed = true;
          await tester.pumpWidget(const SizedBox());
          await _settle(tester);
          await tester.pump(const Duration(seconds: 1));
          await tester.runAsync(db.close);
        }

        addTearDown(dispose);

        Future<GoRouter> pumpAssets() async {
          final router = GoRouter(
            initialLocation: '/assets',
            routes: [
              GoRoute(path: '/assets', builder: (_, _) => const AssetsPage()),
              GoRoute(
                path: '/assets/new',
                builder: (_, state) => AssetEditorPage(
                  initialType: int.tryParse(
                    state.uri.queryParameters['type'] ?? '',
                  ),
                ),
              ),
            ],
          );
          await tester.pumpWidget(
            ProviderScope(
              key: UniqueKey(),
              retry: (_, _) => null,
              overrides: [databaseProvider.overrideWith((ref) async => db)],
              child: DesktopAdaptiveScope(
                isDesktop: isDesktop,
                child: MaterialApp.router(
                  theme: _guardTheme(Brightness.light, isDesktop: isDesktop),
                  routerConfig: router,
                ),
              ),
            ),
          );
          await _settle(tester);
          return router;
        }

        await pumpAssets();
        expect(tester.takeException(), isNull);

        final guide = find.byKey(const Key('assets-empty-guide-card'));
        final normal = find.byKey(const Key('empty-add-normal-asset'));
        final credit = find.byKey(const Key('empty-add-credit-asset'));
        expect(guide, findsOneWidget);
        expect(normal, findsOneWidget);
        expect(credit, findsOneWidget);
        final titleFinder = find.descendant(
          of: guide,
          matching: find.text('还没有资产账户'),
        );
        expect(titleFinder, findsOneWidget);

        // No circular top wallet icon badge exists above '还没有资产账户':
        // only the icons inside the two scene sub-cards remain.
        expect(
          find.descendant(
            of: guide,
            matching: find.byIcon(Icons.account_balance_wallet_outlined),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: guide,
            matching: find.byIcon(Icons.credit_card_outlined),
          ),
          findsOneWidget,
        );
        final guideIcons = find.descendant(
          of: guide,
          matching: find.byType(Icon),
        );
        final normalIcons = find.descendant(
          of: normal,
          matching: find.byType(Icon),
        );
        final creditIcons = find.descendant(
          of: credit,
          matching: find.byType(Icon),
        );
        expect(
          guideIcons.evaluate().length,
          normalIcons.evaluate().length + creditIcons.evaluate().length,
        );
        final titleTop = tester.getRect(titleFinder).top;
        for (final iconEl in guideIcons.evaluate()) {
          expect(
            tester.getRect(find.byElementPredicate((e) => e == iconEl)).top,
            greaterThan(titleTop),
          );
        }
        final circularContainers = find.descendant(
          of: guide,
          matching: find.byWidgetPredicate(
            (w) =>
                w is Container &&
                w.decoration is BoxDecoration &&
                (w.decoration! as BoxDecoration).shape == BoxShape.circle,
          ),
        );
        expect(circularContainers, findsNothing);

        expect(
          find.descendant(of: normal, matching: find.text('新建资金账户')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: credit, matching: find.text('新建信用账户')),
          findsOneWidget,
        );
        _expectNoForbiddenHints();
        expect(find.textContaining('右下角'), findsNothing);

        // Guide card is a borderless 16dp card.
        final card = tester.widget<Card>(guide);
        expect(card.elevation, 0);
        final cardShape = card.shape;
        expect(cardShape, isA<RoundedRectangleBorder>());
        expect(
          (cardShape! as RoundedRectangleBorder).borderRadius,
          BorderRadius.circular(kTallyCardRadius),
        );
        expect((cardShape as RoundedRectangleBorder).side, BorderSide.none);

        // Scene sub-cards are 12dp soft tinted blocks with identical fill.
        final scheme = Theme.of(tester.element(guide)).colorScheme;
        for (final f in [normal, credit]) {
          final m = tester.widget<Material>(
            find.ancestor(of: f, matching: find.byType(Material)).first,
          );
          expect(m.color, tallySoftButtonFillColor(scheme));
          expect(m.borderRadius, BorderRadius.circular(kTallyNestedRadius));
        }

        // Responsive arrangement: side-by-side only when the card is wide.
        final normalRect = tester.getRect(normal);
        final creditRect = tester.getRect(credit);
        if (sideBySide) {
          expect(normalRect.top, creditRect.top);
          expect(creditRect.left, greaterThan(normalRect.right));
        } else {
          expect(creditRect.top, greaterThan(normalRect.bottom));
          expect(normalRect.width, creditRect.width);
        }
        // Guide card surface (inside the Card margin) keeps the 16px gutters.
        final guideRect = tester.getRect(
          find.descendant(of: guide, matching: find.byType(Material)).first,
        );
        final listColumn = isDesktop && size.width >= 1080
            ? tester.getRect(find.byKey(const Key('assets-master-pane')))
            : tester.getRect(
                find
                    .ancestor(of: guide, matching: find.byType(Scrollable))
                    .first,
              );
        expect(guideRect.left, listColumn.left + 16);
        expect(guideRect.right, listColumn.right - 16);

        // Normal scene card opens a fund-account editor (no initial type).
        await tester.ensureVisible(normal);
        await _settle(tester);
        await tester.tap(normal);
        await _settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.byType(AssetEditorPage), findsOneWidget);
        expect(
          tester
              .widget<AssetEditorPage>(find.byType(AssetEditorPage))
              .initialType,
          isNull,
        );

        // Credit scene card opens a credit-account editor.
        await pumpAssets();
        await tester.ensureVisible(credit);
        await _settle(tester);
        await tester.tap(credit);
        await _settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.byType(AssetEditorPage), findsOneWidget);
        expect(
          tester
              .widget<AssetEditorPage>(find.byType(AssetEditorPage))
              .initialType,
          AssetType.credit,
        );
        expect(find.text('信用账户'), findsWidgets);

        await dispose();
      });
    }
  });
}
