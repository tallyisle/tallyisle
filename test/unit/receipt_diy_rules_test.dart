import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/domain/rules/receipt_diy_rules.dart';

void main() {
  group(
    'DiyToolbarConfig & DiyToolbarAction (frequentRemarks + keypadMultiplyDivide + autoSelectFirstCategory + picker styles)',
    () {
      test(
        'frequentRemarks, keypadMultiplyDivide, and autoSelectFirstCategory default to disabled while the other 8 actions default to enabled',
        () {
          expect(DiyToolbarAction.values, hasLength(11));
          expect(DiyToolbarAction.frequentRemarks.key, 'frequent_remarks');
          expect(DiyToolbarAction.frequentRemarks.label, '常用备注');
          expect(
            DiyToolbarAction.frequentRemarks.description,
            '展示分类常用备注候选条并自动统计备注词频',
          );
          expect(DiyToolbarAction.frequentRemarks.defaultEnabled, isFalse);

          expect(DiyToolbarAction.keypadMultiplyDivide.key, 'keypad_mul_div');
          expect(DiyToolbarAction.keypadMultiplyDivide.label, '乘除运算');
          expect(
            DiyToolbarAction.keypadMultiplyDivide.description,
            '开启后在记账数字键盘长按 + / − 可输入 × / ÷',
          );
          expect(DiyToolbarAction.keypadMultiplyDivide.defaultEnabled, isFalse);

          expect(
            DiyToolbarAction.autoSelectFirstCategory.key,
            'auto_select_first_cat',
          );
          expect(DiyToolbarAction.autoSelectFirstCategory.label, '默认选中首个分类');
          expect(
            DiyToolbarAction.autoSelectFirstCategory.description,
            '每次进入记一笔或切换类型时，自动选中排在第一位的分类',
          );
          expect(
            DiyToolbarAction.autoSelectFirstCategory.defaultEnabled,
            isFalse,
          );

          for (final action in DiyToolbarAction.values) {
            if (action == DiyToolbarAction.frequentRemarks ||
                action == DiyToolbarAction.keypadMultiplyDivide ||
                action == DiyToolbarAction.autoSelectFirstCategory) {
              expect(
                action.defaultEnabled,
                isFalse,
                reason: '${action.key} should default OFF',
              );
            } else {
              expect(
                action.defaultEnabled,
                isTrue,
                reason: '${action.key} should default ON',
              );
            }
          }

          final defaults = DiyToolbarConfig.defaults();
          expect(defaults.items, hasLength(11));
          expect(defaults.datePickerStyle, RecordDatePickerStyle.calendar);
          expect(defaults.timePickerStyle, RecordTimePickerStyle.wheel);
          expect(defaults.isEnabled(DiyToolbarAction.frequentRemarks), isFalse);
          expect(
            defaults.isEnabled(DiyToolbarAction.keypadMultiplyDivide),
            isFalse,
          );
          expect(
            defaults.isEnabled(DiyToolbarAction.autoSelectFirstCategory),
            isFalse,
          );
          expect(defaults.visibleActions, hasLength(8));
          expect(
            defaults.visibleActions.contains(DiyToolbarAction.frequentRemarks),
            isFalse,
          );
          expect(
            defaults.visibleActions.contains(
              DiyToolbarAction.keypadMultiplyDivide,
            ),
            isFalse,
          );
          expect(
            defaults.visibleActions.contains(
              DiyToolbarAction.autoSelectFirstCategory,
            ),
            isFalse,
          );
        },
      );

      test(
        'decode(null/empty/corrupt) and legacy 8/10-item or list JSON normalize all 11 actions & default styles safely',
        () {
          for (final raw in <String?>[null, '', '   ', '{corrupt-json', '42']) {
            final cfg = DiyToolbarConfig.decode(raw);
            expect(cfg.items, hasLength(11));
            expect(cfg.datePickerStyle, RecordDatePickerStyle.calendar);
            expect(cfg.timePickerStyle, RecordTimePickerStyle.wheel);
            expect(cfg.isEnabled(DiyToolbarAction.frequentRemarks), isFalse);
            expect(
              cfg.isEnabled(DiyToolbarAction.keypadMultiplyDivide),
              isFalse,
            );
            expect(
              cfg.isEnabled(DiyToolbarAction.autoSelectFirstCategory),
              isFalse,
            );
          }

          // Simulate an upgraded user whose saved preference JSON only had the original 8 actions.
          final legacyEightItemsJson = jsonEncode({
            'version': 1,
            'items': [
              {'key': 'location', 'enabled': true},
              {'key': 'tags', 'enabled': false},
              {'key': 'images', 'enabled': true},
              {'key': 'discount', 'enabled': true},
              {'key': 'exclude_budget', 'enabled': true},
              {'key': 'exclude_ex_in', 'enabled': false},
              {'key': 'currency', 'enabled': true},
              {'key': 'templates', 'enabled': true},
            ],
          });
          final migrated = DiyToolbarConfig.decode(legacyEightItemsJson);
          expect(migrated.items, hasLength(11));
          expect(migrated.items.first.action, DiyToolbarAction.location);
          expect(migrated.isEnabled(DiyToolbarAction.tags), isFalse);
          expect(migrated.isEnabled(DiyToolbarAction.excludeExIn), isFalse);
          expect(migrated.isEnabled(DiyToolbarAction.frequentRemarks), isFalse);
          expect(
            migrated.isEnabled(DiyToolbarAction.keypadMultiplyDivide),
            isFalse,
          );
          expect(
            migrated.isEnabled(DiyToolbarAction.autoSelectFirstCategory),
            isFalse,
          );
          expect(migrated.datePickerStyle, RecordDatePickerStyle.calendar);
          expect(migrated.timePickerStyle, RecordTimePickerStyle.wheel);

          // Simulate a 10-item upgraded user with frequent_remarks & keypad_mul_div ON, omitting auto_select_first_cat & styles.
          final legacyTenItemsJson = jsonEncode({
            'version': 1,
            'items': [
              for (final a in DiyToolbarAction.values)
                if (a != DiyToolbarAction.autoSelectFirstCategory)
                  {'key': a.key, 'enabled': true},
            ],
          });
          final migratedTen = DiyToolbarConfig.decode(legacyTenItemsJson);
          expect(migratedTen.items, hasLength(11));
          expect(
            migratedTen.isEnabled(DiyToolbarAction.frequentRemarks),
            isTrue,
          );
          expect(
            migratedTen.isEnabled(DiyToolbarAction.keypadMultiplyDivide),
            isTrue,
          );
          expect(
            migratedTen.isEnabled(DiyToolbarAction.autoSelectFirstCategory),
            isFalse,
          );
          expect(migratedTen.datePickerStyle, RecordDatePickerStyle.calendar);
          expect(migratedTen.timePickerStyle, RecordTimePickerStyle.wheel);

          // Legacy raw List JSON safely defaults picker styles and normalizes missing items.
          final legacyListJson = jsonEncode(['location', 'tags']);
          final legacyListDecoded = DiyToolbarConfig.decode(legacyListJson);
          expect(legacyListDecoded.items, hasLength(11));
          expect(
            legacyListDecoded.items.first.action,
            DiyToolbarAction.location,
          );
          expect(
            legacyListDecoded.isEnabled(
              DiyToolbarAction.autoSelectFirstCategory,
            ),
            isFalse,
          );
          expect(
            legacyListDecoded.datePickerStyle,
            RecordDatePickerStyle.calendar,
          );
          expect(
            legacyListDecoded.timePickerStyle,
            RecordTimePickerStyle.wheel,
          );

          // Missing boolean `enabled` field in map entry falls back to action.defaultEnabled.
          final missingBoolFieldJson = jsonEncode({
            'items': [
              {'key': 'frequent_remarks'},
              {'key': 'keypad_mul_div'},
              {'key': 'auto_select_first_cat'},
              {'key': 'tags'},
            ],
          });
          final missingBoolDecoded = DiyToolbarConfig.decode(
            missingBoolFieldJson,
          );
          expect(
            missingBoolDecoded.isEnabled(DiyToolbarAction.frequentRemarks),
            isFalse,
          );
          expect(
            missingBoolDecoded.isEnabled(DiyToolbarAction.keypadMultiplyDivide),
            isFalse,
          );
          expect(
            missingBoolDecoded.isEnabled(
              DiyToolbarAction.autoSelectFirstCategory,
            ),
            isFalse,
          );
          expect(missingBoolDecoded.isEnabled(DiyToolbarAction.tags), isTrue);
        },
      );

      test(
        'toggling frequentRemarks, keypadMultiplyDivide, and autoSelectFirstCategory ON and OFF round-trips cleanly through JSON',
        () {
          final enabledCfg = DiyToolbarConfig.defaults()
              .setEnabled(DiyToolbarAction.frequentRemarks, true)
              .setEnabled(DiyToolbarAction.keypadMultiplyDivide, true)
              .setEnabled(DiyToolbarAction.autoSelectFirstCategory, true);
          expect(
            enabledCfg.isEnabled(DiyToolbarAction.frequentRemarks),
            isTrue,
          );
          expect(
            enabledCfg.isEnabled(DiyToolbarAction.keypadMultiplyDivide),
            isTrue,
          );
          expect(
            enabledCfg.isEnabled(DiyToolbarAction.autoSelectFirstCategory),
            isTrue,
          );
          expect(enabledCfg.visibleActions, hasLength(11));

          final decodedOn = DiyToolbarConfig.decode(enabledCfg.encode());
          expect(decodedOn, equals(enabledCfg));
          expect(decodedOn.isEnabled(DiyToolbarAction.frequentRemarks), isTrue);
          expect(
            decodedOn.isEnabled(DiyToolbarAction.keypadMultiplyDivide),
            isTrue,
          );
          expect(
            decodedOn.isEnabled(DiyToolbarAction.autoSelectFirstCategory),
            isTrue,
          );
          expect(decodedOn.items, enabledCfg.items);

          final disabledAgain = decodedOn
              .setEnabled(DiyToolbarAction.frequentRemarks, false)
              .setEnabled(DiyToolbarAction.keypadMultiplyDivide, false)
              .setEnabled(DiyToolbarAction.autoSelectFirstCategory, false);
          final decodedOff = DiyToolbarConfig.decode(disabledAgain.encode());
          expect(
            decodedOff.isEnabled(DiyToolbarAction.frequentRemarks),
            isFalse,
          );
          expect(
            decodedOff.isEnabled(DiyToolbarAction.keypadMultiplyDivide),
            isFalse,
          );
          expect(
            decodedOff.isEnabled(DiyToolbarAction.autoSelectFirstCategory),
            isFalse,
          );
          expect(decodedOff.visibleActions, hasLength(8));
        },
      );

      test(
        'RecordDatePickerStyle & RecordTimePickerStyle round-trip in JSON, survive setEnabled/moveItem/reorderForListView/normalize, and reset on defaults()',
        () {
          expect(
            RecordDatePickerStyle.fromKey('wheel'),
            RecordDatePickerStyle.wheel,
          );
          expect(
            RecordDatePickerStyle.fromKey('calendar'),
            RecordDatePickerStyle.calendar,
          );
          expect(
            RecordDatePickerStyle.fromKey(null),
            RecordDatePickerStyle.calendar,
          );
          expect(
            RecordDatePickerStyle.fromKey('unknown'),
            RecordDatePickerStyle.calendar,
          );

          expect(
            RecordTimePickerStyle.fromKey('dial'),
            RecordTimePickerStyle.dial,
          );
          expect(
            RecordTimePickerStyle.fromKey('wheel'),
            RecordTimePickerStyle.wheel,
          );
          expect(
            RecordTimePickerStyle.fromKey(null),
            RecordTimePickerStyle.wheel,
          );
          expect(
            RecordTimePickerStyle.fromKey(123),
            RecordTimePickerStyle.wheel,
          );

          final base = DiyToolbarConfig.defaults();
          final styled = base.copyWithStyles(
            datePickerStyle: RecordDatePickerStyle.wheel,
            timePickerStyle: RecordTimePickerStyle.dial,
          );
          expect(styled.datePickerStyle, RecordDatePickerStyle.wheel);
          expect(styled.timePickerStyle, RecordTimePickerStyle.dial);
          expect(styled.items, base.items);
          expect(styled == base, isFalse);

          // Partial copyWithStyles preserves the other style field.
          final partialDate = styled.copyWithStyles(
            datePickerStyle: RecordDatePickerStyle.calendar,
          );
          expect(partialDate.datePickerStyle, RecordDatePickerStyle.calendar);
          expect(partialDate.timePickerStyle, RecordTimePickerStyle.dial);

          final jsonMap = styled.toJson();
          expect(jsonMap['version'], 1);
          expect(jsonMap['datePickerStyle'], 'wheel');
          expect(jsonMap['timePickerStyle'], 'dial');
          expect(jsonMap['items'], isA<List<Object?>>());

          final roundTripped = DiyToolbarConfig.decode(styled.encode());
          expect(roundTripped, equals(styled));
          expect(roundTripped.hashCode, styled.hashCode);
          expect(roundTripped.datePickerStyle, RecordDatePickerStyle.wheel);
          expect(roundTripped.timePickerStyle, RecordTimePickerStyle.dial);

          // setEnabled, moveItem, reorderForListView, and normalize preserve styles.
          final afterSetEnabled = roundTripped.setEnabled(
            DiyToolbarAction.autoSelectFirstCategory,
            true,
          );
          expect(afterSetEnabled.datePickerStyle, RecordDatePickerStyle.wheel);
          expect(afterSetEnabled.timePickerStyle, RecordTimePickerStyle.dial);

          final afterMoveSame = afterSetEnabled.moveItem(2, 2);
          expect(afterMoveSame.datePickerStyle, RecordDatePickerStyle.wheel);
          expect(afterMoveSame.timePickerStyle, RecordTimePickerStyle.dial);

          final afterMove = afterSetEnabled.moveItem(10, 0);
          expect(
            afterMove.items.first.action,
            DiyToolbarAction.autoSelectFirstCategory,
          );
          expect(afterMove.datePickerStyle, RecordDatePickerStyle.wheel);
          expect(afterMove.timePickerStyle, RecordTimePickerStyle.dial);

          final afterReorder = afterMove.reorderForListView(0, 3);
          expect(afterReorder.datePickerStyle, RecordDatePickerStyle.wheel);
          expect(afterReorder.timePickerStyle, RecordTimePickerStyle.dial);

          final afterNormalize = DiyToolbarConfig.normalize(
            afterReorder.items.take(4),
            datePickerStyle: afterReorder.datePickerStyle,
            timePickerStyle: afterReorder.timePickerStyle,
          );
          expect(afterNormalize.items, hasLength(11));
          expect(afterNormalize.datePickerStyle, RecordDatePickerStyle.wheel);
          expect(afterNormalize.timePickerStyle, RecordTimePickerStyle.dial);

          // Reset via defaults() restores calendar + wheel.
          final reset = DiyToolbarConfig.defaults();
          expect(reset.datePickerStyle, RecordDatePickerStyle.calendar);
          expect(reset.timePickerStyle, RecordTimePickerStyle.wheel);
          expect(
            reset.isEnabled(DiyToolbarAction.autoSelectFirstCategory),
            isFalse,
          );
        },
      );
    },
  );
}
