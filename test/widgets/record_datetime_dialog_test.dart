import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/features/records/record_datetime_dialog.dart';

Widget _buildTestHost({
  required ValueChanged<RecordDateTimeDialogResult?> onResult,
  required DateTime initialDateTime,
  DateTime? firstDate,
  DateTime? lastDate,
  bool initialDateWheelStyle = false,
  bool initialTimeDialStyle = false,
  void Function({required bool dateWheelStyle, required bool timeDialStyle})?
  onStyleChanged,
  ThemeMode themeMode = ThemeMode.light,
}) {
  return MaterialApp(
    themeMode: themeMode,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF2B6CB0),
        brightness: Brightness.light,
      ),
      useMaterial3: true,
    ),
    darkTheme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF2B6CB0),
        brightness: Brightness.dark,
      ),
      useMaterial3: true,
    ),
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: FilledButton(
            key: const Key('open-datetime-dialog'),
            onPressed: () async {
              final res = await showRecordDateTimeDialog(
                context: context,
                initialDateTime: initialDateTime,
                firstDate: firstDate,
                lastDate: lastDate,
                initialDateWheelStyle: initialDateWheelStyle,
                initialTimeDialStyle: initialTimeDialStyle,
                onStyleChanged: onStyleChanged,
              );
              onResult(res);
            },
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  );
}

Offset _dialPolarOffset(
  WidgetTester tester, {
  required double radiusFactor,
  required double angleRadiansFromTop,
}) {
  final rect = tester.getRect(find.byKey(const Key('datetime-clock-dial')));
  final r = rect.width / 2 * radiusFactor;
  return Offset(
    rect.center.dx + r * math.sin(angleRadiansFromTop),
    rect.center.dy - r * math.cos(angleRadiansFromTop),
  );
}

void main() {
  group('RecordDateTimeDialog', () {
    testWidgets(
      'opens on Date calendar page, supports month navigation & boundary clamping, and confirms in 1 step without forcing Time page',
      (tester) async {
        RecordDateTimeDialogResult? captured;
        var resultCount = 0;

        await tester.pumpWidget(
          _buildTestHost(
            initialDateTime: DateTime(2026, 11, 13, 18, 14),
            firstDate: DateTime(2026, 10, 10),
            lastDate: DateTime(2026, 11, 25),
            onResult: (res) {
              captured = res;
              resultCount++;
            },
          ),
        );

        await tester.tap(find.byKey(const Key('open-datetime-dialog')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        // Starts on Date Calendar view
        expect(find.byKey(const Key('datetime-calendar-grid')), findsOneWidget);
        expect(find.byKey(const Key('datetime-date-wheel')), findsNothing);
        expect(find.byKey(const Key('datetime-time-wheel')), findsNothing);
        expect(find.byKey(const Key('datetime-clock-dial')), findsNothing);

        expect(find.text('2026年'), findsOneWidget);
        expect(find.text('11月13日 周五'), findsOneWidget);
        expect(find.text('2026年11月'), findsOneWidget);

        // Thumb-zone layout check: style toggle on left, HH:mm capsule on right
        final styleRect = tester.getRect(
          find.byKey(const Key('datetime-toggle-style-btn')),
        );
        final switchRect = tester.getRect(
          find.byKey(const Key('datetime-switch-mode-btn')),
        );
        expect(styleRect.right, lessThan(switchRect.left));
        expect(
          find.descendant(
            of: find.byKey(const Key('datetime-switch-mode-btn')),
            matching: find.text('18:14'),
          ),
          findsOneWidget,
        );

        // Next month disabled at lastDate month (2026-11); days > 25 disabled
        final nextBtn = tester.widget<IconButton>(
          find.byKey(const Key('datetime-next-month')),
        );
        expect(nextBtn.onPressed, isNull);
        await tester.tap(find.byKey(const Key('datetime-day-28')));
        await tester.pump();
        expect(find.text('11月13日 周五'), findsOneWidget);

        // Navigate to previous month (2026-10)
        await tester.tap(find.byKey(const Key('datetime-prev-month')));
        await tester.pumpAndSettle();
        expect(find.text('2026年10月'), findsOneWidget);

        // Prev month now disabled at firstDate month (2026-10); day 5 (< 10) disabled
        final prevBtn = tester.widget<IconButton>(
          find.byKey(const Key('datetime-prev-month')),
        );
        expect(prevBtn.onPressed, isNull);
        await tester.tap(find.byKey(const Key('datetime-day-5')));
        await tester.pump();
        expect(find.text('11月13日 周五'), findsOneWidget);

        // Select valid day 25 in Oct 2026 -> Sunday
        await tester.tap(find.byKey(const Key('datetime-day-25')));
        await tester.pump();
        expect(find.text('10月25日 周日'), findsOneWidget);

        // Confirm directly in 1 step from Date page!
        await tester.tap(find.byKey(const Key('datetime-confirm-btn')));
        await tester.pumpAndSettle();

        expect(resultCount, 1);
        expect(captured, isNotNull);
        expect(captured!.dateTime, DateTime(2026, 10, 25, 18, 14));
        expect(captured!.dateWheelStyle, isFalse);
        expect(captured!.timeDialStyle, isFalse);
      },
    );

    testWidgets(
      'preserves draft across Date ⇄ Time capsule switches, saves from Time page, and discards on Cancel',
      (tester) async {
        RecordDateTimeDialogResult? captured;
        var popCount = 0;

        await tester.pumpWidget(
          _buildTestHost(
            initialDateTime: DateTime(2026, 11, 13, 18, 14),
            onResult: (res) {
              captured = res;
              popCount++;
            },
          ),
        );

        await tester.tap(find.byKey(const Key('open-datetime-dialog')));
        await tester.pumpAndSettle();

        // 1. Pick day 20 on Date calendar
        await tester.tap(find.byKey(const Key('datetime-day-20')));
        await tester.pump();
        expect(find.text('11月20日 周五'), findsOneWidget);

        // 2. Tap bottom-right HH:mm capsule -> switches to Time 2-col wheel
        await tester.tap(find.byKey(const Key('datetime-switch-mode-btn')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('datetime-time-wheel')), findsOneWidget);
        expect(find.byKey(const Key('datetime-calendar-grid')), findsNothing);
        expect(
          find.descendant(
            of: find.byKey(const Key('datetime-switch-mode-btn')),
            matching: find.text('2026-11-20'),
          ),
          findsOneWidget,
        );

        // 3. Scroll Hour (18 -> 07) and Minute (14 -> 45) wheels
        final hourWheel = tester.widget<ListWheelScrollView>(
          find.byKey(const Key('datetime-wheel-hour')),
        );
        final minuteWheel = tester.widget<ListWheelScrollView>(
          find.byKey(const Key('datetime-wheel-minute')),
        );
        (hourWheel.controller! as FixedExtentScrollController).jumpToItem(7);
        (minuteWheel.controller! as FixedExtentScrollController).jumpToItem(45);
        await tester.pumpAndSettle();

        // 4. Switch Time -> Date via YYYY-MM-DD capsule: time capsule now shows 07:45 and Nov 20 stays selected
        await tester.tap(find.byKey(const Key('datetime-switch-mode-btn')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('datetime-calendar-grid')), findsOneWidget);
        expect(find.text('11月20日 周五'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const Key('datetime-switch-mode-btn')),
            matching: find.text('07:45'),
          ),
          findsOneWidget,
        );

        // 5. Pick day 21 on Calendar, switch Date -> Time again, and confirm right from Time page
        await tester.tap(find.byKey(const Key('datetime-day-21')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('datetime-switch-mode-btn')));
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byKey(const Key('datetime-switch-mode-btn')),
            matching: find.text('2026-11-21'),
          ),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const Key('datetime-confirm-btn')));
        await tester.pumpAndSettle();
        expect(popCount, 1);
        expect(captured!.dateTime, DateTime(2026, 11, 21, 7, 45));

        // 6. Reopen, mutate date & time, tap Cancel -> returns null
        await tester.tap(find.byKey(const Key('open-datetime-dialog')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('datetime-day-2')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('datetime-switch-mode-btn')));
        await tester.pumpAndSettle();
        final hourWheel2 = tester.widget<ListWheelScrollView>(
          find.byKey(const Key('datetime-wheel-hour')),
        );
        (hourWheel2.controller! as FixedExtentScrollController).jumpToItem(22);
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('datetime-cancel-btn')));
        await tester.pumpAndSettle();
        expect(popCount, 2);
        expect(captured, isNull);
      },
    );

    testWidgets(
      'toggles Date Calendar ⇄ 3-Column Wheel with onStyleChanged and clamps Jan 31 -> Feb (leap & non-leap) and 2024-02-29 -> 2025',
      (tester) async {
        RecordDateTimeDialogResult? captured;
        final styleEvents = <({bool dateWheel, bool timeDial})>[];

        await tester.pumpWidget(
          _buildTestHost(
            initialDateTime: DateTime(2024, 1, 31, 9, 30),
            firstDate: DateTime(2020),
            lastDate: DateTime(2030, 12, 31),
            onStyleChanged:
                ({required dateWheelStyle, required timeDialStyle}) {
                  styleEvents.add((
                    dateWheel: dateWheelStyle,
                    timeDial: timeDialStyle,
                  ));
                },
            onResult: (res) => captured = res,
          ),
        );

        await tester.tap(find.byKey(const Key('open-datetime-dialog')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('datetime-calendar-grid')), findsOneWidget);

        // Toggle Calendar -> 3-Column Date Wheel
        await tester.tap(find.byKey(const Key('datetime-toggle-style-btn')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(styleEvents, [(dateWheel: true, timeDial: false)]);
        expect(find.byKey(const Key('datetime-date-wheel')), findsOneWidget);
        expect(find.text('选择日期'), findsOneWidget);

        FixedExtentScrollController yearCtrl() =>
            tester
                    .widget<ListWheelScrollView>(
                      find.byKey(const Key('datetime-wheel-year')),
                    )
                    .controller!
                as FixedExtentScrollController;
        FixedExtentScrollController monthCtrl() =>
            tester
                    .widget<ListWheelScrollView>(
                      find.byKey(const Key('datetime-wheel-month')),
                    )
                    .controller!
                as FixedExtentScrollController;
        FixedExtentScrollController dayCtrl() =>
            tester
                    .widget<ListWheelScrollView>(
                      find.byKey(const Key('datetime-wheel-day')),
                    )
                    .controller!
                as FixedExtentScrollController;

        expect(yearCtrl().selectedItem, 2024 - 2020);
        expect(monthCtrl().selectedItem, 0); // Jan
        expect(dayCtrl().selectedItem, 30); // 31st

        // 1. Scroll Month Jan (0) -> Feb (1) in leap year 2024 -> Day clamps 31 -> 29!
        monthCtrl().jumpToItem(1);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(monthCtrl().selectedItem, 1);
        expect(dayCtrl().selectedItem, 28); // index 28 == day 29

        // 2. Scroll Year 2024 (index 4) -> 2025 (index 5) while on Feb 29 -> Day clamps 29 -> 28!
        yearCtrl().jumpToItem(2025 - 2020);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(yearCtrl().selectedItem, 2025 - 2020);
        expect(monthCtrl().selectedItem, 1);
        expect(dayCtrl().selectedItem, 27); // index 27 == day 28

        // 3. Toggle Wheel -> Calendar: reflects 2025-02-28 cleanly
        await tester.tap(find.byKey(const Key('datetime-toggle-style-btn')));
        await tester.pumpAndSettle();
        expect(styleEvents.last, (dateWheel: false, timeDial: false));
        expect(find.text('2025年'), findsOneWidget);
        expect(find.text('2月28日 周五'), findsOneWidget);

        // Toggle back to Wheel and confirm
        await tester.tap(find.byKey(const Key('datetime-toggle-style-btn')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('datetime-confirm-btn')));
        await tester.pumpAndSettle();

        expect(captured, isNotNull);
        expect(captured!.dateTime, DateTime(2025, 2, 28, 9, 30));
        expect(captured!.dateWheelStyle, isTrue);
        expect(captured!.timeDialStyle, isFalse);
      },
    );

    testWidgets(
      'toggles Time 2-Column Wheel ⇄ 24h Dual-Ring Clock Dial (outer/inner rings, auto-advance, 1-min snap) + inline keyboard input',
      (tester) async {
        RecordDateTimeDialogResult? captured;
        final styleEvents = <({bool dateWheel, bool timeDial})>[];

        await tester.pumpWidget(
          _buildTestHost(
            initialDateTime: DateTime(2026, 11, 13, 14, 20),
            onStyleChanged:
                ({required dateWheelStyle, required timeDialStyle}) {
                  styleEvents.add((
                    dateWheel: dateWheelStyle,
                    timeDial: timeDialStyle,
                  ));
                },
            onResult: (res) => captured = res,
          ),
        );

        await tester.tap(find.byKey(const Key('open-datetime-dialog')));
        await tester.pumpAndSettle();

        // Switch Date -> Time (starts on 2-column wheel)
        await tester.tap(find.byKey(const Key('datetime-switch-mode-btn')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('datetime-time-wheel')), findsOneWidget);

        // Toggle style -> 24h Clock Dial
        await tester.tap(find.byKey(const Key('datetime-toggle-style-btn')));
        await tester.pumpAndSettle();
        expect(styleEvents, [(dateWheel: false, timeDial: true)]);
        expect(find.byKey(const Key('datetime-dial-header')), findsOneWidget);
        expect(find.byKey(const Key('datetime-clock-dial')), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const Key('datetime-dial-hour-tab')),
            matching: find.text('14'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const Key('datetime-dial-minute-tab')),
            matching: find.text('20'),
          ),
          findsOneWidget,
        );

        // 1. Tap outer ring at 9 o'clock (angle = 3π/2, radiusFactor = 0.78) -> selects 09 & auto-advances to minute mode!
        await tester.tapAt(
          _dialPolarOffset(
            tester,
            radiusFactor: 0.78,
            angleRadiansFromTop: 1.5 * math.pi,
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byKey(const Key('datetime-dial-hour-tab')),
            matching: find.text('09'),
          ),
          findsOneWidget,
        );

        // 2. Now in Minute mode: tap exact 37-minute angle (37 / 60 * 2π) -> snaps to 37!
        await tester.tapAt(
          _dialPolarOffset(
            tester,
            radiusFactor: 0.78,
            angleRadiansFromTop: (37 / 60.0) * 2 * math.pi,
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byKey(const Key('datetime-dial-minute-tab')),
            matching: find.text('37'),
          ),
          findsOneWidget,
        );

        // 3. Tap hour tab -> tap inner ring at top (angle = 0, radiusFactor = 0.50) -> selects 00!
        await tester.tap(find.byKey(const Key('datetime-dial-hour-tab')));
        await tester.pump();
        await tester.tapAt(
          _dialPolarOffset(
            tester,
            radiusFactor: 0.50,
            angleRadiansFromTop: 0.0,
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byKey(const Key('datetime-dial-hour-tab')),
            matching: find.text('00'),
          ),
          findsOneWidget,
        );

        // 4. Tap hour tab -> drag inner ring from 3 o'clock (15) to 6 o'clock (18) -> selects 18 & advances!
        await tester.tap(find.byKey(const Key('datetime-dial-hour-tab')));
        await tester.pump();
        final start15 = _dialPolarOffset(
          tester,
          radiusFactor: 0.50,
          angleRadiansFromTop: 0.5 * math.pi,
        );
        final end18 = _dialPolarOffset(
          tester,
          radiusFactor: 0.50,
          angleRadiansFromTop: math.pi,
        );
        await tester.dragFrom(start15, end18 - start15);
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byKey(const Key('datetime-dial-hour-tab')),
            matching: find.text('18'),
          ),
          findsOneWidget,
        );

        // 5. Toggle inline keyboard input via datetime-dial-input-toggle
        await tester.tap(find.byKey(const Key('datetime-dial-input-toggle')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('datetime-hour-input')), findsOneWidget);
        expect(find.byKey(const Key('datetime-minute-input')), findsOneWidget);

        await tester.enterText(
          find.byKey(const Key('datetime-hour-input')),
          '23',
        );
        await tester.enterText(
          find.byKey(const Key('datetime-minute-input')),
          '08',
        );
        await tester.pump();

        // Toggle back to clock dial -> header reflects 23:08
        await tester.tap(find.byKey(const Key('datetime-dial-input-toggle')));
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byKey(const Key('datetime-dial-hour-tab')),
            matching: find.text('23'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const Key('datetime-dial-minute-tab')),
            matching: find.text('08'),
          ),
          findsOneWidget,
        );

        // Toggle to keyboard input again, enter 06:55, and confirm directly!
        await tester.tap(find.byKey(const Key('datetime-dial-input-toggle')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('datetime-hour-input')),
          '06',
        );
        await tester.enterText(
          find.byKey(const Key('datetime-minute-input')),
          '55',
        );
        await tester.tap(find.byKey(const Key('datetime-confirm-btn')));
        await tester.pumpAndSettle();

        expect(captured, isNotNull);
        expect(captured!.dateTime, DateTime(2026, 11, 13, 6, 55));
        expect(captured!.dateWheelStyle, isFalse);
        expect(captured!.timeDialStyle, isTrue);
      },
    );

    testWidgets(
      'renders borderlessly with zero overflow across all 4 styles + keyboard input on 360x640 and 800x600 in light & dark themes',
      (tester) async {
        addTearDown(() async {
          tester.view.reset();
          await tester.binding.setSurfaceSize(null);
        });

        const viewports = <Size>[Size(360, 640), Size(800, 600)];
        const themes = <ThemeMode>[ThemeMode.light, ThemeMode.dark];

        for (final size in viewports) {
          for (final themeMode in themes) {
            tester.view.devicePixelRatio = 1.0;
            tester.view.physicalSize = size;
            await tester.binding.setSurfaceSize(size);

            await tester.pumpWidget(
              _buildTestHost(
                initialDateTime: DateTime(2026, 11, 13, 21, 5),
                themeMode: themeMode,
                onResult: (_) {},
              ),
            );

            await tester.tap(find.byKey(const Key('open-datetime-dialog')));
            await tester.pumpAndSettle();
            expect(
              tester.takeException(),
              isNull,
              reason: 'Calendar overflow on $size / $themeMode',
            );

            // Borderless check: zero Divider / VerticalDivider and Dialog shape has BorderSide.none
            final dialog = tester.widget<Dialog>(find.byType(Dialog));
            final shape = dialog.shape! as RoundedRectangleBorder;
            expect(shape.side, BorderSide.none);
            expect(
              find.descendant(
                of: find.byType(Dialog),
                matching: find.byType(Divider),
              ),
              findsNothing,
            );

            // Style 2: Date 3-Col Wheel
            await tester.tap(
              find.byKey(const Key('datetime-toggle-style-btn')),
            );
            await tester.pumpAndSettle();
            expect(
              tester.takeException(),
              isNull,
              reason: 'Date wheel overflow on $size / $themeMode',
            );

            // Style 3: Time 2-Col Wheel
            await tester.tap(find.byKey(const Key('datetime-switch-mode-btn')));
            await tester.pumpAndSettle();
            expect(
              tester.takeException(),
              isNull,
              reason: 'Time wheel overflow on $size / $themeMode',
            );

            // Style 4a: Time 24h Clock Dial
            await tester.tap(
              find.byKey(const Key('datetime-toggle-style-btn')),
            );
            await tester.pumpAndSettle();
            expect(
              tester.takeException(),
              isNull,
              reason: 'Clock dial overflow on $size / $themeMode',
            );

            // Style 4b: Time Inline Keyboard Input with simulated OS keyboard inset
            await tester.tap(
              find.byKey(const Key('datetime-dial-input-toggle')),
            );
            tester.view.viewInsets = const FakeViewPadding(
              left: 0,
              top: 0,
              right: 0,
              bottom: 240,
            );
            await tester.pumpAndSettle();
            expect(
              tester.takeException(),
              isNull,
              reason: 'Dial keyboard input overflow on $size / $themeMode',
            );
            tester.view.viewInsets = FakeViewPadding.zero;
            await tester.pumpAndSettle();

            await tester.tap(find.byKey(const Key('datetime-cancel-btn')));
            await tester.pumpAndSettle();
          }
        }
      },
    );
  });
}
