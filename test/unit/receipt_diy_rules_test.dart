import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/domain/rules/receipt_diy_rules.dart';

void main() {
  group(
    'DiyToolbarConfig & DiyToolbarAction (frequentRemarks + keypadMultiplyDivide)',
    () {
      test(
        'frequentRemarks and keypadMultiplyDivide default to disabled while the other 8 actions default to enabled',
        () {
          expect(DiyToolbarAction.values, hasLength(10));
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

          for (final action in DiyToolbarAction.values) {
            if (action == DiyToolbarAction.frequentRemarks ||
                action == DiyToolbarAction.keypadMultiplyDivide) {
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
          expect(defaults.items, hasLength(10));
          expect(defaults.isEnabled(DiyToolbarAction.frequentRemarks), isFalse);
          expect(
            defaults.isEnabled(DiyToolbarAction.keypadMultiplyDivide),
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
        },
      );

      test(
        'decode(null/empty/corrupt) and legacy 8/9-item JSON normalize frequentRemarks & keypadMultiplyDivide to false',
        () {
          for (final raw in <String?>[null, '', '   ', '{corrupt-json', '42']) {
            final cfg = DiyToolbarConfig.decode(raw);
            expect(cfg.items, hasLength(10));
            expect(cfg.isEnabled(DiyToolbarAction.frequentRemarks), isFalse);
            expect(
              cfg.isEnabled(DiyToolbarAction.keypadMultiplyDivide),
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
          expect(migrated.items, hasLength(10));
          expect(migrated.items.first.action, DiyToolbarAction.location);
          expect(migrated.isEnabled(DiyToolbarAction.tags), isFalse);
          expect(migrated.isEnabled(DiyToolbarAction.excludeExIn), isFalse);
          expect(migrated.isEnabled(DiyToolbarAction.frequentRemarks), isFalse);
          expect(
            migrated.isEnabled(DiyToolbarAction.keypadMultiplyDivide),
            isFalse,
          );

          // Missing boolean `enabled` field in map entry falls back to action.defaultEnabled.
          final missingBoolFieldJson = jsonEncode({
            'items': [
              {'key': 'frequent_remarks'},
              {'key': 'keypad_mul_div'},
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
          expect(missingBoolDecoded.isEnabled(DiyToolbarAction.tags), isTrue);
        },
      );

      test(
        'toggling frequentRemarks and keypadMultiplyDivide ON and OFF round-trips cleanly through JSON',
        () {
          final enabledCfg = DiyToolbarConfig.defaults()
              .setEnabled(DiyToolbarAction.frequentRemarks, true)
              .setEnabled(DiyToolbarAction.keypadMultiplyDivide, true);
          expect(
            enabledCfg.isEnabled(DiyToolbarAction.frequentRemarks),
            isTrue,
          );
          expect(
            enabledCfg.isEnabled(DiyToolbarAction.keypadMultiplyDivide),
            isTrue,
          );
          expect(enabledCfg.visibleActions, hasLength(10));

          final decodedOn = DiyToolbarConfig.decode(enabledCfg.encode());
          expect(decodedOn.isEnabled(DiyToolbarAction.frequentRemarks), isTrue);
          expect(
            decodedOn.isEnabled(DiyToolbarAction.keypadMultiplyDivide),
            isTrue,
          );
          expect(decodedOn.items, enabledCfg.items);

          final disabledAgain = decodedOn
              .setEnabled(DiyToolbarAction.frequentRemarks, false)
              .setEnabled(DiyToolbarAction.keypadMultiplyDivide, false);
          final decodedOff = DiyToolbarConfig.decode(disabledAgain.encode());
          expect(
            decodedOff.isEnabled(DiyToolbarAction.frequentRemarks),
            isFalse,
          );
          expect(
            decodedOff.isEnabled(DiyToolbarAction.keypadMultiplyDivide),
            isFalse,
          );
          expect(decodedOff.visibleActions, hasLength(8));
        },
      );
    },
  );
}
