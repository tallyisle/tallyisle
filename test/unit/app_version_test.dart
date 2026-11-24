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
}
