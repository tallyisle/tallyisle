/// Single in-code source of the TallyIsle release version (ADR-019).
///
/// MUST stay identical to `pubspec.yaml` `version: <appVersionName>+<appBuildNumber>`.
/// Never edit by hand: run `bash tool/bump_version.sh <X.Y.Z> [build]`, which
/// rewrites both files atomically. `test/unit/app_version_test.dart` fails the
/// build whenever they drift apart.
library;

/// Semantic version `MAJOR.MINOR.PATCH` (Android `versionName`, iOS/macOS
/// `CFBundleShortVersionString`, Windows `FileVersion`).
const String appVersionName = '0.7.0';

/// Strictly increasing integer build number (Android `versionCode`, iOS/macOS
/// `CFBundleVersion`). Must never decrease, otherwise Android refuses
/// overwrite-install of a newer package.
const int appBuildNumber = 10;

/// Full human-readable label, e.g. `0.2.0 (Build 2)`.
const String appVersionLabel = '$appVersionName (Build $appBuildNumber)';
