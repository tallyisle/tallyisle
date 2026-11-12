import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/domain/rules/receipt_diy_rules.dart';

void main() {
  group('DiyToolbarConfig & DiyToolbarAction.frequentRemarks', () {
    test(
      'frequentRemarks defaults to disabled while the other 8 actions default to enabled',
      () {
        expect(DiyToolbarAction.values, hasLength(9));
        expect(DiyToolbarAction.frequentRemarks.key, 'frequent_remarks');
        expect(DiyToolbarAction.frequentRemarks.label, '常用备注');
        expect(
          DiyToolbarAction.frequentRemarks.description,
          '展示分类常用备注候选条并自动统计备注词频',
        );
        expect(
          DiyToolbarAction.frequentRemarks.description.contains('默认关闭'),
          isFalse,
        );
        expect(DiyToolbarAction.frequentRemarks.defaultEnabled, isFalse);

        for (final action in DiyToolbarAction.values) {
          if (action == DiyToolbarAction.frequentRemarks) {
            expect(action.defaultEnabled, isFalse);
          } else {
            expect(
              action.defaultEnabled,
              isTrue,
              reason: '${action.key} should default ON',
            );
          }
        }

        final defaults = DiyToolbarConfig.defaults();
        expect(defaults.items, hasLength(9));
        expect(defaults.isEnabled(DiyToolbarAction.frequentRemarks), isFalse);
        expect(defaults.visibleActions, hasLength(8));
        expect(
          defaults.visibleActions.contains(DiyToolbarAction.frequentRemarks),
          isFalse,
        );
      },
    );

    test(
      'decode(null/empty/corrupt) and legacy 8-item JSON normalize frequentRemarks to false',
      () {
        for (final raw in <String?>[null, '', '   ', '{corrupt-json', '42']) {
          final cfg = DiyToolbarConfig.decode(raw);
          expect(cfg.items, hasLength(9));
          expect(cfg.isEnabled(DiyToolbarAction.frequentRemarks), isFalse);
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
        expect(migrated.items, hasLength(9));
        expect(migrated.items.first.action, DiyToolbarAction.location);
        expect(migrated.isEnabled(DiyToolbarAction.tags), isFalse);
        expect(migrated.isEnabled(DiyToolbarAction.excludeExIn), isFalse);
        // Newly added frequent_remarks MUST migrate as enabled: false!
        expect(migrated.isEnabled(DiyToolbarAction.frequentRemarks), isFalse);

        // Missing boolean `enabled` field in map entry falls back to action.defaultEnabled.
        final missingBoolFieldJson = jsonEncode({
          'items': [
            {'key': 'frequent_remarks'},
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
        expect(missingBoolDecoded.isEnabled(DiyToolbarAction.tags), isTrue);
      },
    );

    test(
      'toggling frequentRemarks ON and OFF round-trips cleanly through JSON',
      () {
        final enabledCfg = DiyToolbarConfig.defaults().setEnabled(
          DiyToolbarAction.frequentRemarks,
          true,
        );
        expect(enabledCfg.isEnabled(DiyToolbarAction.frequentRemarks), isTrue);
        expect(enabledCfg.visibleActions, hasLength(9));
        expect(
          enabledCfg.visibleActions.contains(DiyToolbarAction.frequentRemarks),
          isTrue,
        );

        final decodedOn = DiyToolbarConfig.decode(enabledCfg.encode());
        expect(decodedOn.isEnabled(DiyToolbarAction.frequentRemarks), isTrue);
        expect(decodedOn.items, enabledCfg.items);

        final disabledAgain = decodedOn.setEnabled(
          DiyToolbarAction.frequentRemarks,
          false,
        );
        final decodedOff = DiyToolbarConfig.decode(disabledAgain.encode());
        expect(decodedOff.isEnabled(DiyToolbarAction.frequentRemarks), isFalse);
        expect(decodedOff.visibleActions, hasLength(8));
      },
    );
  });
}
