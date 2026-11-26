import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Strips `//` line comments and nested `/* ... */` block comments from Dart
/// source while preserving string literals and line breaks for accurate line
/// reporting.
String _stripDartComments(String source) {
  final out = StringBuffer();
  final n = source.length;
  var i = 0;

  while (i < n) {
    final c = source.codeUnitAt(i);

    // Line comment: // ...
    if (c == 0x2F /* / */ && i + 1 < n && source.codeUnitAt(i + 1) == 0x2F) {
      i += 2;
      while (i < n && source.codeUnitAt(i) != 0x0A) {
        i++;
      }
      continue;
    }

    // Block comment (supports Dart nesting): /* ... */
    if (c == 0x2F /* / */ && i + 1 < n && source.codeUnitAt(i + 1) == 0x2A) {
      var depth = 1;
      i += 2;
      while (i < n && depth > 0) {
        final cur = source.codeUnitAt(i);
        if (cur == 0x0A) {
          out.write('\n');
          i++;
        } else if (cur == 0x2F &&
            i + 1 < n &&
            source.codeUnitAt(i + 1) == 0x2A) {
          depth++;
          i += 2;
        } else if (cur == 0x2A &&
            i + 1 < n &&
            source.codeUnitAt(i + 1) == 0x2F) {
          depth--;
          i += 2;
        } else {
          i++;
        }
      }
      continue;
    }

    // Raw string literal: r'...', r"...", r'''...''', r"""..."""
    final isRawString =
        c == 0x72 /* r */ &&
        i + 1 < n &&
        (source.codeUnitAt(i + 1) == 0x27 || source.codeUnitAt(i + 1) == 0x22);
    if (isRawString || c == 0x27 /* ' */ || c == 0x22 /* " */ ) {
      final raw = isRawString;
      if (raw) {
        out.writeCharCode(c);
        i++;
      }
      final quote = source.codeUnitAt(i);
      final isTriple =
          i + 2 < n &&
          source.codeUnitAt(i + 1) == quote &&
          source.codeUnitAt(i + 2) == quote;
      if (isTriple) {
        out.write(source.substring(i, i + 3));
        i += 3;
        while (i < n) {
          final cur = source.codeUnitAt(i);
          if (!raw && cur == 0x5C /* \ */ && i + 1 < n) {
            out.write(source.substring(i, i + 2));
            i += 2;
            continue;
          }
          if (cur == quote &&
              i + 2 < n &&
              source.codeUnitAt(i + 1) == quote &&
              source.codeUnitAt(i + 2) == quote) {
            out.write(source.substring(i, i + 3));
            i += 3;
            break;
          }
          out.writeCharCode(cur);
          i++;
        }
      } else {
        out.writeCharCode(quote);
        i++;
        while (i < n) {
          final cur = source.codeUnitAt(i);
          if (!raw && cur == 0x5C /* \ */ && i + 1 < n) {
            out.write(source.substring(i, i + 2));
            i += 2;
            continue;
          }
          out.writeCharCode(cur);
          i++;
          if (cur == quote || cur == 0x0A) {
            break;
          }
        }
      }
      continue;
    }

    out.writeCharCode(c);
    i++;
  }

  return out.toString();
}

List<File> _listDartFiles(String dirPath) {
  final dir = Directory(dirPath);
  if (!dir.existsSync()) return const [];
  final files =
      dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return files;
}

String _normalizePath(String path) => path.replaceAll('\\', '/');

void main() {
  group('Schema snapshot & preference key invariants', () {
    const expectedTables = <String>{
      'account_book',
      'asset',
      'bank_card',
      'budget',
      'import_platform',
      'record',
      'record_category',
      'remark',
      'record_template',
      'wish',
      'record_period',
      'reminder_event',
      'installment',
      'note',
      'tag',
      'tag_record',
      'money_save_plan',
      'money_save_plan_record',
      'asset_book',
      'stat_story',
      'auto_map',
      'currency',
      'ti_write_command',
      'ti_preference',
    };

    test(
      'drift_schemas/drift_schema_v1.json contains exactly the 24 production tables',
      () {
        final file = File('drift_schemas/drift_schema_v1.json');
        expect(file.existsSync(), isTrue);

        final decoded =
            jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
        final entities = (decoded['entities'] as List<Object?>)
            .cast<Map<String, Object?>>();
        final tableNames = <String>[
          for (final entity in entities)
            if (entity['type'] == 'table')
              (entity['data'] as Map<String, Object?>)['name'] as String,
        ];

        expect(tableNames.length, expectedTables.length);
        expect(tableNames.toSet(), equals(expectedTables));
      },
    );

    test(
      "current_book_id literal only exists in lib/domain/model/codes.dart and month_start_day is absent from lib/",
      () {
        final currentBookViolations = <String>[];
        final monthStartDayViolations = <String>[];

        for (final file in _listDartFiles('lib')) {
          final normalized = _normalizePath(file.path);
          final stripped = _stripDartComments(file.readAsStringSync());
          final lines = stripped.split('\n');

          for (var idx = 0; idx < lines.length; idx++) {
            final line = lines[idx];
            if (line.contains("'current_book_id'") ||
                line.contains('"current_book_id"')) {
              if (normalized != 'lib/domain/model/codes.dart') {
                currentBookViolations.add(
                  '$normalized:${idx + 1}: ${line.trim()}',
                );
              }
            }
            if (line.contains("'month_start_day'") ||
                line.contains('"month_start_day"')) {
              monthStartDayViolations.add(
                '$normalized:${idx + 1}: ${line.trim()}',
              );
            }
          }
        }

        expect(
          currentBookViolations,
          isEmpty,
          reason:
              'Use prefKeyCurrentBookId from lib/domain/model/codes.dart instead of string literals:\n'
              '${currentBookViolations.join('\n')}',
        );
        expect(
          monthStartDayViolations,
          isEmpty,
          reason:
              'Obsolete month_start_day preference key must not appear in lib/:\n'
              '${monthStartDayViolations.join('\n')}',
        );
      },
    );
  });

  group('UI copy guard (UI_GUIDE §6)', () {
    const forbiddenTerms = <String>[
      '六端',
      '零丢数',
      '100%',
      '（note）',
      '（currency）',
      '（默认关闭）',
      '离线绝不',
      '秒开',
    ];

    test('lib/features/ non-comment code contains no forbidden UI terms', () {
      final violations = <String>[];

      for (final file in _listDartFiles('lib/features')) {
        final normalized = _normalizePath(file.path);
        final stripped = _stripDartComments(file.readAsStringSync());
        final lines = stripped.split('\n');

        for (var idx = 0; idx < lines.length; idx++) {
          final line = lines[idx];
          for (final term in forbiddenTerms) {
            if (line.contains(term)) {
              violations.add('$normalized:${idx + 1} [$term]: ${line.trim()}');
            }
          }
        }
      }

      expect(
        violations,
        isEmpty,
        reason:
            'Forbidden engineering/marketing terms found in lib/features/:\n'
            '${violations.join('\n')}',
      );
    });
  });
}
