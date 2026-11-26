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
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/features/assets/asset_editor_page.dart';
import 'package:tallyisle/features/assets/assets_page.dart';
import 'package:tallyisle/features/backup/backup_page.dart';
import 'package:tallyisle/features/backup/backup_providers.dart';
import 'package:tallyisle/features/category_transfer/category_transfer_page.dart';
import 'package:tallyisle/features/category_transfer/category_transfer_providers.dart';
import 'package:tallyisle/features/common/tally_button.dart';
import 'package:tallyisle/features/common/tally_card.dart';
import 'package:tallyisle/features/csv_transfer/csv_export_page.dart';
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

  group('Global button theme', () {
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
    }
  });

  group('Transfer / backup pages keep sibling buttons uniform', () {
    const sizes = <(String, Size, bool)>[
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
          ], label: 'csv export card');
          // The final export stays the single solid primary action.
          final confirm = find.byKey(const Key('confirm_csv_export_button'));
          final confirmButton = tester.widget<FilledButton>(confirm);
          expect(confirmButton, isNot(isA<TallySoftButton>()));
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
        expect(
          find.descendant(of: guide, matching: find.text('还没有资产账户')),
          findsOneWidget,
        );
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
