import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/app/app.dart' show appDisplayVersion;
import 'package:tallyisle/core/app_version.dart';

/// ADR-019 version gate: `pubspec.yaml` and `lib/core/app_version.dart` must
/// describe the same release, using plain `MAJOR.MINOR.PATCH+BUILD`.
void main() {
  test('pubspec.yaml version equals appVersionName+appBuildNumber', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(
      r'^version:\s*(\S+)\s*$',
      multiLine: true,
    ).firstMatch(pubspec);
    expect(match, isNotNull, reason: 'pubspec.yaml is missing `version:`');
    expect(
      match!.group(1),
      '$appVersionName+$appBuildNumber',
      reason:
          'Run `bash tool/bump_version.sh <X.Y.Z>` instead of editing by hand',
    );
  });

  test('version follows plain semantic MAJOR.MINOR.PATCH with build >= 1', () {
    expect(appVersionName, matches(RegExp(r'^\d+\.\d+\.\d+$')));
    expect(appBuildNumber, greaterThanOrEqualTo(1));
    expect(appDisplayVersion, appVersionName);
    expect(appVersionLabel, '$appVersionName (Build $appBuildNumber)');
  });

  test(
    'ohos/AppScope/app.json5 matches appVersionName and appBuildNumber when present',
    () {
      final appJson5 = File('ohos/AppScope/app.json5');
      if (!appJson5.existsSync()) {
        return;
      }
      final content = appJson5.readAsStringSync();
      final nameMatch = RegExp(
        r'"versionName"\s*:\s*"([^"]+)"',
      ).firstMatch(content);
      final codeMatch = RegExp(
        r'"versionCode"\s*:\s*(\d+)',
      ).firstMatch(content);
      expect(
        nameMatch,
        isNotNull,
        reason: 'ohos/AppScope/app.json5 is missing `versionName`',
      );
      expect(
        codeMatch,
        isNotNull,
        reason: 'ohos/AppScope/app.json5 is missing `versionCode`',
      );
      expect(
        nameMatch!.group(1),
        appVersionName,
        reason:
            'Run `bash tool/bump_version.sh <X.Y.Z>` instead of editing by hand',
      );
      expect(
        int.parse(codeMatch!.group(1)!),
        appBuildNumber,
        reason:
            'Run `bash tool/bump_version.sh <X.Y.Z>` instead of editing by hand',
      );
    },
  );

  test(
    'tool/bump_version.sh computes default build formula, accepts explicit build, and rejects non-monotonic builds',
    () {
      final tempDir = Directory.systemTemp.createTempSync('tallyisle_bump_');
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });

      final toolDir = Directory('${tempDir.path}/tool')..createSync();
      final coreDir = Directory('${tempDir.path}/lib/core')
        ..createSync(recursive: true);
      final ohosDir = Directory('${tempDir.path}/ohos/AppScope')
        ..createSync(recursive: true);

      final scriptCopy = File('${toolDir.path}/bump_version.sh');
      File('tool/bump_version.sh').copySync(scriptCopy.path);

      final pubspecFile = File('${tempDir.path}/pubspec.yaml')
        ..writeAsStringSync('name: tallyisle\nversion: 1.0.0+10000\n');
      final dartFile = File('${coreDir.path}/app_version.dart')
        ..writeAsStringSync(
          "const String appVersionName = '1.0.0';\n"
          'const int appBuildNumber = 10000;\n',
        );
      final ohosFile = File('${ohosDir.path}/app.json5')
        ..writeAsStringSync(
          '{\n'
          '  "app": {\n'
          '    "versionCode": 10000,\n'
          '    "versionName": "1.0.0"\n'
          '  }\n'
          '}\n',
        );

      ProcessResult runBump(List<String> args) => Process.runSync(
        'bash',
        <String>[scriptCopy.path, ...args],
        workingDirectory: tempDir.path,
      );

      // (a) Default formula: 1.2.3 -> 1 * 10000 + 2 * 100 + 3 = 10203
      final defaultRes = runBump(<String>['1.2.3']);
      expect(defaultRes.exitCode, 0, reason: 'stderr: ${defaultRes.stderr}');
      expect(pubspecFile.readAsStringSync(), contains('version: 1.2.3+10203'));
      expect(
        dartFile.readAsStringSync(),
        allOf(
          contains("const String appVersionName = '1.2.3';"),
          contains('const int appBuildNumber = 10203;'),
        ),
      );
      expect(
        ohosFile.readAsStringSync(),
        allOf(
          contains('"versionCode": 10203'),
          contains('"versionName": "1.2.3"'),
        ),
      );

      // (b) Explicit 2nd arg: 1.2.4 10300 -> 10300
      final explicitRes = runBump(<String>['1.2.4', '10300']);
      expect(explicitRes.exitCode, 0, reason: 'stderr: ${explicitRes.stderr}');
      expect(pubspecFile.readAsStringSync(), contains('version: 1.2.4+10300'));
      expect(
        dartFile.readAsStringSync(),
        allOf(
          contains("const String appVersionName = '1.2.4';"),
          contains('const int appBuildNumber = 10300;'),
        ),
      );
      expect(
        ohosFile.readAsStringSync(),
        allOf(
          contains('"versionCode": 10300'),
          contains('"versionName": "1.2.4"'),
        ),
      );

      // (c) Monotonic rejection when new_build <= current_build
      final equalBuildRes = runBump(<String>['1.2.5', '10300']);
      expect(equalBuildRes.exitCode, isNonZero);
      final lowerBuildRes = runBump(<String>['1.2.5', '10299']);
      expect(lowerBuildRes.exitCode, isNonZero);
      final formulaLowerRes = runBump(<String>['1.2.5']);
      expect(formulaLowerRes.exitCode, isNonZero);
      final overflowMinorRes = runBump(<String>['1.100.0']);
      expect(overflowMinorRes.exitCode, isNonZero);
      expect(pubspecFile.readAsStringSync(), contains('version: 1.2.4+10300'));
    },
  );

  test('lib/features contains zero references to appVersionLabel', () {
    final featuresDir = Directory('lib/features');
    expect(featuresDir.existsSync(), isTrue);
    final offenders = <String>[];
    for (final entity in featuresDir.listSync(recursive: true)) {
      if (entity is File && entity.path.endsWith('.dart')) {
        if (entity.readAsStringSync().contains('appVersionLabel')) {
          offenders.add(entity.path);
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'User-facing UI must use appVersionName / appDisplayVersion instead of appVersionLabel',
    );
  });
}
