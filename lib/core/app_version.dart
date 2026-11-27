/// Single in-code source of the TallyIsle release version (ADR-019).
///
/// MUST stay identical to `pubspec.yaml` `version: <appVersionName>+<appBuildNumber>`.
/// Never edit by hand: run `bash tool/bump_version.sh <X.Y.Z> [build]`, which
/// rewrites both files atomically. `test/unit/app_version_test.dart` fails the
/// build whenever they drift apart.
library;

/// Semantic version `MAJOR.MINOR.PATCH` (Android `versionName`, iOS/macOS
/// `CFBundleShortVersionString`, Windows `FileVersion`).
const String appVersionName = '1.0.0';

/// Strictly increasing integer build number (Android `versionCode`, iOS/macOS
/// `CFBundleVersion`). Must never decrease, otherwise Android refuses
/// overwrite-install of a newer package.
const int appBuildNumber = 10000;

/// Full diagnostic label, e.g. `1.0.0 (Build 10000)`.
///
/// Reserved for internal diagnostics and unit tests only; user-facing UI must
/// use [appVersionName] (`appDisplayVersion`) without exposing `Build` numbers.
const String appVersionLabel = '$appVersionName (Build $appBuildNumber)';
