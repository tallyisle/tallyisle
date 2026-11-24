import 'dart:io';
import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/domain/rules/category_transfer_rules.dart';
import 'package:tallyisle/domain/rules/ios_migration_rules.dart';
import 'package:tallyisle/domain/rules/receipt_diy_rules.dart';
import 'package:tallyisle/domain/rules/tally_backup.dart';
import 'package:tallyisle/platform/biometrics.dart';

final RegExp _cjkPattern = RegExp(
  r'[\u3000-\u303F\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF\uFF00-\uFFEF]',
);
final RegExp _pureAsciiPattern = RegExp(r'^[\x20-\x7E]+$');

String _readRepoFile(String relativePath) {
  final file = File(relativePath);
  expect(
    file.existsSync(),
    isTrue,
    reason: 'Expected repository file to exist: $relativePath',
  );
  return file.readAsStringSync();
}

void main() {
  group('BRAND-001: Pure-English paths, build artifacts, and bilingual OS names', () {
    test(
      'windows/runner/Runner.rc has pure-English ProductName and FileDescription',
      () {
        final content = _readRepoFile('windows/runner/Runner.rc');
        expect(
          _cjkPattern.hasMatch(content),
          isFalse,
          reason: 'Runner.rc must not contain CJK characters',
        );
        expect(content, contains('VALUE "FileDescription", "TallyIsle"'));
        expect(content, contains('VALUE "ProductName", "TallyIsle"'));
      },
    );

    test('tool/build_android.sh outputs pure-ASCII APK filenames', () {
      final content = _readRepoFile('tool/build_android.sh');
      expect(
        _cjkPattern.hasMatch(content),
        isFalse,
        reason: 'tool/build_android.sh must not contain CJK filenames or paths',
      );
      expect(content, contains('release/TallyIsle-release.apk'));
      expect(content, contains('release/TallyIsle-debug.apk'));
    });

    test('.github/workflows/build.yml uses pure-ASCII artifact filenames', () {
      final content = _readRepoFile('.github/workflows/build.yml');
      expect(
        _cjkPattern.hasMatch(content),
        isFalse,
        reason: '.github/workflows/build.yml must not contain CJK characters',
      );
      for (final expectedArtifact in const <String>[
        'TallyIsle-Android-release.apk',
        'TallyIsle-Android-debug.apk',
        'TallyIsle-Windows-x64.zip',
        'TallyIsle-Linux-x64.tar.gz',
        'TallyIsle-macOS.zip',
        'TallyIsle-iOS-unsigned.ipa',
      ]) {
        expect(
          content,
          contains(expectedArtifact),
          reason: 'Missing expected CI artifact name: $expectedArtifact',
        );
      }
    });

    test(
      '.github/workflows/build-ohos.yml and tool/ohos installers use pure-ASCII .hap filenames',
      () {
        final ohosFiles = <String>[
          '.github/workflows/build-ohos.yml',
          'tool/ohos/install-hap-windows.bat',
          'tool/ohos/install-hap-unix.sh',
        ];
        final hapTokenPattern = RegExp(r'([^\s"\x27`「」()<>]+\.hap)');

        for (final path in ohosFiles) {
          final file = File(path);
          if (!file.existsSync()) {
            continue;
          }
          final content = file.readAsStringSync();
          expect(
            content,
            contains('TallyIsle-HarmonyOS-signed-debug.hap'),
            reason: '$path must reference TallyIsle-HarmonyOS-signed-debug.hap',
          );
          if (path == '.github/workflows/build-ohos.yml') {
            expect(
              content,
              contains('TallyIsle-HarmonyOS-unsigned.hap'),
              reason: '$path must reference TallyIsle-HarmonyOS-unsigned.hap',
            );
            expect(
              content,
              contains('TallyIsle-HarmonyOS-*.hap'),
              reason: '$path must stage TallyIsle-HarmonyOS-*.hap',
            );
          }
          for (final match in hapTokenPattern.allMatches(content)) {
            final token = match.group(1)!;
            expect(
              _pureAsciiPattern.hasMatch(token),
              isTrue,
              reason:
                  '.hap artifact path/filename in $path must be pure ASCII: $token',
            );
            expect(
              _cjkPattern.hasMatch(token),
              isFalse,
              reason:
                  '.hap artifact path/filename in $path must not contain CJK: $token',
            );
          }
        }
      },
    );

    test(
      'Android automation_strings.xml splits default English and values-zh Chinese',
      () {
        final defaultXml = _readRepoFile(
          'android/app/src/main/res/values/automation_strings.xml',
        );
        final zhXml = _readRepoFile(
          'android/app/src/main/res/values-zh/automation_strings.xml',
        );

        expect(
          _cjkPattern.hasMatch(defaultXml),
          isFalse,
          reason:
              'Default values/automation_strings.xml must contain zero CJK characters',
        );
        expect(defaultXml, contains('TallyIsle'));
        expect(zhXml, contains('帐屿'));

        for (final key in const <String>[
          'accessibility_service_label',
          'accessibility_service_description',
          'accessibility_service_summary',
          'widget_quick_add_label',
          'widget_quick_add_desc',
          'widget_month_summary_label',
          'widget_month_summary_desc',
          'widget_month_bar_label',
          'widget_month_bar_desc',
        ]) {
          expect(defaultXml, contains('name="$key"'));
          expect(zhXml, contains('name="$key"'));
        }
      },
    );

    test(
      'Apple Info.plist defaults to TallyIsle and lproj bundles cover en/zh-Hans/zh-Hant',
      () {
        for (final plistPath in const <String>[
          'ios/Runner/Info.plist',
          'macos/Runner/Info.plist',
        ]) {
          final content = _readRepoFile(plistPath);
          expect(
            _cjkPattern.hasMatch(content),
            isFalse,
            reason: '$plistPath must not contain CJK characters',
          );
          expect(
            content,
            contains(
              '<key>CFBundleDisplayName</key>\n\t<string>TallyIsle</string>',
            ),
          );
          expect(content, contains('<key>CFBundleLocalizations</key>'));
          expect(content, contains('<string>en</string>'));
          expect(content, contains('<string>zh-Hans</string>'));
          expect(content, contains('<string>zh-Hant</string>'));
        }

        for (final platformDir in const <String>[
          'ios/Runner',
          'macos/Runner',
        ]) {
          final enStrings = _readRepoFile(
            '$platformDir/en.lproj/InfoPlist.strings',
          );
          final zhHansStrings = _readRepoFile(
            '$platformDir/zh-Hans.lproj/InfoPlist.strings',
          );
          final zhHantStrings = _readRepoFile(
            '$platformDir/zh-Hant.lproj/InfoPlist.strings',
          );
          expect(_cjkPattern.hasMatch(enStrings), isFalse);
          expect(enStrings, contains('"TallyIsle"'));
          expect(zhHansStrings, contains('"帐屿"'));
          expect(zhHantStrings, contains('"帐屿"'));
        }

        for (final pbxPath in const <String>[
          'ios/Runner.xcodeproj/project.pbxproj',
          'macos/Runner.xcodeproj/project.pbxproj',
        ]) {
          final pbx = _readRepoFile(pbxPath);
          expect(pbx, contains('/* InfoPlist.strings in Resources */'));
          expect(
            pbx,
            contains(
              '/* InfoPlist.strings */ = {\n\t\t\tisa = PBXVariantGroup;',
            ),
          );
          expect(pbx, contains('path = en.lproj/InfoPlist.strings;'));
          expect(pbx, contains('path = "zh-Hans.lproj/InfoPlist.strings";'));
          expect(pbx, contains('path = "zh-Hant.lproj/InfoPlist.strings";'));
          expect(pbx, contains('lastKnownFileType = text.plist.strings;'));
          final regionsMatch = RegExp(
            r'knownRegions = \(([\s\S]*?)\);',
          ).firstMatch(pbx);
          expect(
            regionsMatch,
            isNotNull,
            reason: 'knownRegions block missing in $pbxPath',
          );
          final regionsBody = regionsMatch!.group(1)!;
          expect(regionsBody, contains('en,'));
          expect(regionsBody, contains('"zh-Hans",'));
          expect(regionsBody, contains('"zh-Hant",'));
        }
      },
    );

    test(
      'Native desktop/mobile entrypoints switch window/prompt brand by OS locale',
      () {
        final winMain = _readRepoFile('windows/runner/main.cpp');
        expect(winMain, contains('GetUserDefaultUILanguage'));
        expect(winMain, contains('LANG_CHINESE'));
        expect(winMain, contains('L"帐屿"'));
        expect(winMain, contains('L"TallyIsle"'));

        final linuxApp = _readRepoFile('linux/runner/my_application.cc');
        expect(linuxApp, contains('g_get_language_names'));
        expect(linuxApp, contains('"帐屿"'));
        expect(linuxApp, contains('"TallyIsle"'));

        final macWindow = _readRepoFile('macos/Runner/MainFlutterWindow.swift');
        expect(macWindow, contains('Locale.preferredLanguages'));
        expect(macWindow, contains('"帐屿"'));
        expect(macWindow, contains('"TallyIsle"'));

        final bioKt = _readRepoFile(
          'android/app/src/main/kotlin/dev/tallyisle/rebuild/BiometricBridge.kt',
        );
        expect(bioKt, contains('验证身份以解锁帐屿'));
        expect(bioKt, contains('Verify identity to unlock TallyIsle'));
      },
    );

    test('Dart biometric default prompt helpers switch cleanly by locale', () {
      expect(defaultBiometricPromptTitle(const Locale('zh')), '验证身份以解锁帐屿');
      expect(
        defaultBiometricPromptTitle(const Locale('zh', 'TW')),
        '验证身份以解锁帐屿',
      );
      expect(
        defaultBiometricPromptTitle(const Locale('en')),
        'Verify identity to unlock TallyIsle',
      );
      expect(
        defaultBiometricPromptTitle(const Locale('ja')),
        'Verify identity to unlock TallyIsle',
      );
      expect(
        _cjkPattern.hasMatch(
          defaultBiometricPromptSubtitle(const Locale('en')),
        ),
        isFalse,
      );
      expect(
        _cjkPattern.hasMatch(
          defaultBiometricNegativeButtonText(const Locale('en')),
        ),
        isFalse,
      );
      expect(
        _cjkPattern.hasMatch(
          defaultBiometricUnsupportedReason(const Locale('en')),
        ),
        isFalse,
      );
    });

    test('All export filename formatters emit pure ASCII filenames', () {
      final when = DateTime(2026, 11, 23, 8, 9, 10);

      final backupName = formatTallyBackupFileName(when);
      expect(backupName, 'backup_20261123_080910.tally');

      final categoryName = formatCategoryPackFileName('日常 账本/2026', when);
      expect(categoryName, 'TallyIsle_categories_20261123_080910.json');

      final receiptName = formatReceiptFileName('账单-abcdef1234', when);
      expect(receiptName, 'receipt_20261123_abcdef12.png');

      final csvServiceSrc = _readRepoFile(
        'lib/data/csv_import/csv_excel_service.dart',
      );
      expect(csvServiceSrc, contains("'TallyIsle_export_\$stamp.csv'"));

      for (final name in <String>[
        backupName,
        categoryName,
        receiptName,
        defaultYa2iExportFileName,
        'TallyIsle_export_20261123_080910.csv',
      ]) {
        expect(
          _pureAsciiPattern.hasMatch(name),
          isTrue,
          reason: 'Export filename must be pure ASCII: $name',
        );
        expect(
          _cjkPattern.hasMatch(name),
          isFalse,
          reason: 'Export filename must not contain CJK: $name',
        );
      }
    });
  });
}
