import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/app_version.dart';

const List<String> _packagingFiles = <String>[
  'tool/packaging/linux/dev.tallyisle.rebuild.desktop',
  'tool/packaging/linux/dev.tallyisle.rebuild.metainfo.xml',
  'tool/packaging/linux/dev.tallyisle.rebuild.mime.xml',
  'tool/packaging/linux/dev.tallyisle.rebuild.flatpak.json',
  'tool/packaging/linux/package_linux.sh',
  'tool/packaging/windows/tallyisle.iss',
  'tool/packaging/windows/package_windows.ps1',
  'tool/packaging/macos/package_macos.sh',
  '.github/workflows/build.yml',
  '.github/workflows/build-ohos.yml',
];

const List<String> _expectedBuildYmlAssets = <String>[
  'TallyIsle-Android-release.apk',
  'TallyIsle-Android-debug.apk',
  'TallyIsle-Windows-x64-setup.exe',
  'TallyIsle-Windows-x64.msi',
  'TallyIsle-Windows-x64-portable.zip',
  'TallyIsle-Linux-x64.deb',
  'TallyIsle-Linux-x64.rpm',
  'TallyIsle-Linux-x64.AppImage',
  'TallyIsle-Linux-x64.flatpak',
  'TallyIsle-Linux-x64-portable.tar.gz',
  'TallyIsle-macOS.dmg',
  'TallyIsle-macOS.pkg',
  'TallyIsle-macOS-portable.zip',
  'TallyIsle-iOS-unsigned.ipa',
  'SHA256SUMS.txt',
];

const List<String> _expectedOhosYmlAssets = <String>[
  'TallyIsle-HarmonyOS-*.hap',
  'TallyIsle-HarmonyOS-installer-kit.zip',
];

void main() {
  group('Release packaging manifests, scripts & CI workflows', () {
    test('all packaging scripts, manifests, and workflows exist', () {
      for (final path in _packagingFiles) {
        final file = File(path);
        expect(file.existsSync(), isTrue, reason: 'Missing $path');
        expect(file.lengthSync(), greaterThan(0), reason: 'Empty $path');
      }
    });

    test(
      'zero legacy yyjz references and zero hardcoded app versions in packaging files',
      () {
        for (final path in _packagingFiles) {
          final content = File(path).readAsStringSync();
          expect(
            content.toLowerCase(),
            isNot(contains('yyjz')),
            reason: 'Legacy scheme leaked into $path',
          );
          if (path.startsWith('tool/packaging/')) {
            expect(
              content,
              isNot(contains(appVersionName)),
              reason: 'Hardcoded appVersionName ($appVersionName) in $path',
            );
          }
        }
      },
    );

    test(
      'bash -n syntax validation passes on Linux & macOS packaging scripts',
      () {
        for (final script in const <String>[
          'tool/packaging/linux/package_linux.sh',
          'tool/packaging/macos/package_macos.sh',
        ]) {
          final result = Process.runSync('bash', <String>['-n', script]);
          expect(
            result.exitCode,
            0,
            reason: 'bash -n failed for $script:\n${result.stderr}',
          );
          if (!Platform.isWindows) {
            final mode = File(script).statSync().mode;
            expect(
              mode & 0x49,
              isNonZero,
              reason: '$script must be executable (chmod +x)',
            );
          }
        }
      },
    );

    test('Linux desktop, MIME, AppStream, and Flatpak manifests follow specs', () {
      final desktop = File(
        'tool/packaging/linux/dev.tallyisle.rebuild.desktop',
      ).readAsStringSync();
      expect(desktop, contains('Name=TallyIsle'));
      expect(desktop, contains('Name[zh_CN]=帐屿'));
      expect(desktop, contains('Exec=tallyisle %u'));
      expect(desktop, contains('Icon=dev.tallyisle.rebuild'));
      expect(desktop, contains('Categories=Office;Finance;'));
      expect(
        desktop,
        contains(
          'MimeType=x-scheme-handler/tallyisle;application/x-tallyisle-backup;',
        ),
      );
      expect(desktop, contains('StartupWMClass=tallyisle'));

      final mime = File(
        'tool/packaging/linux/dev.tallyisle.rebuild.mime.xml',
      ).readAsStringSync();
      expect(mime, contains('application/x-tallyisle-backup'));
      expect(mime, contains('*.tally'));

      final metainfo = File(
        'tool/packaging/linux/dev.tallyisle.rebuild.metainfo.xml',
      ).readAsStringSync();
      expect(metainfo, contains('<id>dev.tallyisle.rebuild</id>'));
      expect(metainfo, contains('dev.tallyisle.rebuild.desktop'));
      expect(metainfo, contains('x-scheme-handler/tallyisle'));

      final flatpak =
          jsonDecode(
                File(
                  'tool/packaging/linux/dev.tallyisle.rebuild.flatpak.json',
                ).readAsStringSync(),
              )
              as Map<String, Object?>;
      expect(flatpak['app-id'], 'dev.tallyisle.rebuild');
      expect(flatpak['runtime'], 'org.gnome.Platform');
      expect(flatpak['runtime-version'], '47');
      expect(flatpak['sdk'], 'org.gnome.Sdk');
      expect(flatpak['command'], 'tallyisle');
      final finishArgs = (flatpak['finish-args']! as List<Object?>)
          .cast<String>();
      expect(
        finishArgs,
        containsAll(const <String>[
          '--share=ipc',
          '--socket=fallback-x11',
          '--socket=wayland',
          '--share=network',
          '--filesystem=xdg-download',
          '--filesystem=xdg-documents',
        ]),
      );

      for (final size in const <int>[16, 32, 64, 128, 256, 512]) {
        expect(
          File(
            'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_$size.png',
          ).existsSync(),
          isTrue,
          reason: 'Missing multi-size PNG icon app_icon_$size.png',
        );
      }
    });

    test(
      'Windows Inno Setup and WiX v5 scripts avoid CI pitfalls & register tallyisle://',
      () {
        final iss = File(
          'tool/packaging/windows/tallyisle.iss',
        ).readAsStringSync();
        expect(
          iss,
          contains(
            '#if FileExists(AddBackslash(CompilerPath) + "Languages\\ChineseSimplified.isl")',
          ),
        );
        expect(iss, contains('PrivilegesRequired=lowest'));
        expect(iss, contains('PrivilegesRequiredOverridesAllowed=dialog'));
        expect(iss, contains('#if Ver >= EncodeVer(6, 3, 0, 0)'));
        expect(iss, contains('ArchitecturesAllowed=x64compatible'));
        expect(iss, contains(r'windows\runner\resources\app_icon.ico'));
        expect(iss, contains(r'Software\Classes\tallyisle'));
        expect(iss, contains(r'Software\Classes\.tally'));
        expect(iss, contains('OutputBaseFilename=TallyIsle-Windows-x64-setup'));

        final ps1 = File(
          'tool/packaging/windows/package_windows.ps1',
        ).readAsStringSync();
        expect(ps1, contains('pubspec.yaml'));
        expect(ps1, contains('TallyIsle-Windows-x64-portable.zip'));
        expect(ps1, contains('TallyIsle-Windows-x64-setup.exe'));
        expect(ps1, contains('TallyIsle-Windows-x64.msi'));
        expect(
          ps1,
          contains('dotnet tool update --global wix --version 5.0.2'),
        );
        expect(ps1, contains('http://wixtoolset.org/schemas/v4/wxs'));
        expect(
          ps1,
          contains('UpgradeCode="6D8A4E72-9F31-4C5B-8A10-2E7B9C4D5F61"'),
        );
        expect(ps1, contains('Scope="perUser"'));
        expect(ps1, contains('New-DeterministicGuid'));
        expect(ps1, contains('CompFile_'));
        expect(
          ps1,
          contains(
            'Component Id="ProtocolAndAssoc" Guid="A3B8F2C1-4D5E-4F6A-9B7C-8D9E0F1A2B3C"',
          ),
        );
        expect(
          ps1,
          contains(
            'Component Id="ApplicationShortcut" Guid="B4C9E3D2-5E6F-4A7B-8C9D-0E1F2A3B4C5D"',
          ),
        );
        expect(ps1, contains('AllowSameVersionUpgrades="yes"'));
        expect(ps1, contains('EmbedCab="yes"'));
        expect(ps1, contains('ARPPRODUCTICON'));
        expect(ps1, contains('wix build -arch x64'));

        final macSh = File(
          'tool/packaging/macos/package_macos.sh',
        ).readAsStringSync();
        expect(macSh, contains('macos/Runner/Release.entitlements'));
        expect(macSh, contains('codesign --force --entitlements'));
        expect(macSh, isNot(contains('--deep')));
      },
    );

    test(
      'all expected pure-English Release assets are wired in build.yml & build-ohos.yml',
      () {
        final buildYml = File('.github/workflows/build.yml').readAsStringSync();
        final ohosYml = File(
          '.github/workflows/build-ohos.yml',
        ).readAsStringSync();

        for (final asset in _expectedBuildYmlAssets) {
          expect(
            buildYml,
            contains(asset),
            reason: 'Missing $asset in build.yml',
          );
          expect(
            RegExp(r'^[\x20-\x7E]+$').hasMatch(asset),
            isTrue,
            reason: 'Non-ASCII release asset filename: $asset',
          );
        }
        expect(buildYml, contains('package_windows.ps1'));
        expect(buildYml, contains('package_linux.sh'));
        expect(buildYml, contains('package_macos.sh'));
        expect(
          buildYml,
          contains('rpm flatpak flatpak-builder file desktop-file-utils'),
        );
        expect(
          buildYml,
          contains(
            'sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0 || true',
          ),
        );
        expect(buildYml, contains('sha256sum * > SHA256SUMS.txt'));
        expect(buildYml, contains('softprops/action-gh-release@v2'));
        expect(buildYml, contains('ANDROID_KEYSTORE_BASE64'));
        expect(
          buildYml,
          contains(
            "github.repository == 'tallyisle/tallyisle' && github.event_name != 'pull_request'",
          ),
        );
        expect(
          buildYml,
          contains(
            '21:6E:EE:81:15:50:F8:7E:E3:0B:C1:88:C4:34:49:B4:67:75:5B:0A:EB:4E:3C:F6:03:EE:B4:BF:7E:ED:64:C3',
          ),
        );
        expect(buildYml, contains('apksigner'));

        for (final asset in _expectedOhosYmlAssets) {
          expect(
            ohosYml,
            contains(asset),
            reason: 'Missing $asset in build-ohos.yml',
          );
          expect(
            RegExp(r'^[\x20-\x7E]+$').hasMatch(asset),
            isTrue,
            reason: 'Non-ASCII release asset filename: $asset',
          );
        }
        expect(ohosYml, contains('TallyIsle-HarmonyOS-unsigned.hap'));
        expect(
          ohosYml,
          contains(
            'zip -j dist-ohos/TallyIsle-HarmonyOS-installer-kit.zip dist-ohos/TallyIsle-HarmonyOS-*.hap dist-ohos/install-hap-windows.bat dist-ohos/install-hap-unix.sh',
          ),
        );
      },
    );

    test(
      'dynamic version parsing matches pubspec.yaml and builds real Linux .deb + .tar.gz end-to-end',
      () {
        final pubspec = File('pubspec.yaml').readAsStringSync();
        final match = RegExp(
          r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)',
          multiLine: true,
        ).firstMatch(pubspec);
        expect(match, isNotNull);
        expect(match!.group(1), appVersionName);
        expect(int.parse(match.group(2)!), appBuildNumber);

        if (!Platform.isLinux) return;
        final whichDpkg = Process.runSync('which', const <String>['dpkg-deb']);
        if (whichDpkg.exitCode != 0) return;

        final tempRoot = Directory.systemTemp.createTempSync(
          'tallyisle_linux_pkg_test_',
        );
        addTearDown(() => tempRoot.deleteSync(recursive: true));

        final bundleDir = Directory('${tempRoot.path}/bundle')..createSync();
        final outDir = Directory('${tempRoot.path}/out')..createSync();

        final exe = File('${bundleDir.path}/tallyisle')
          ..writeAsStringSync('#!/bin/sh\necho TallyIsle\n');
        Process.runSync('chmod', <String>['+x', exe.path]);
        Directory('${bundleDir.path}/lib').createSync();
        File(
          '${bundleDir.path}/lib/libdummy.so',
        ).writeAsBytesSync(const <int>[0x7f, 0x45, 0x4c, 0x46]);
        Directory(
          '${bundleDir.path}/data/flutter_assets',
        ).createSync(recursive: true);
        File(
          '${bundleDir.path}/data/flutter_assets/placeholder.txt',
        ).writeAsStringSync('ok');

        final pkgRes = Process.runSync('bash', <String>[
          'tool/packaging/linux/package_linux.sh',
          '--bundle-dir',
          bundleDir.path,
          '--out-dir',
          outDir.path,
          '--formats',
          'tar.gz,deb',
        ]);
        expect(
          pkgRes.exitCode,
          0,
          reason:
              'package_linux.sh failed:\nstdout: ${pkgRes.stdout}\nstderr: ${pkgRes.stderr}',
        );

        final tarFile = File(
          '${outDir.path}/TallyIsle-Linux-x64-portable.tar.gz',
        );
        final debFile = File('${outDir.path}/TallyIsle-Linux-x64.deb');
        expect(tarFile.existsSync(), isTrue);
        expect(tarFile.lengthSync(), greaterThan(0));
        expect(debFile.existsSync(), isTrue);
        expect(debFile.lengthSync(), greaterThan(0));

        final controlRes = Process.runSync('dpkg-deb', <String>[
          '-f',
          debFile.path,
          'Package',
          'Version',
          'Architecture',
          'Depends',
        ]);
        expect(controlRes.exitCode, 0);
        final controlText = controlRes.stdout as String;
        expect(controlText, contains('Package: tallyisle'));
        expect(
          controlText,
          contains('Version: $appVersionName-$appBuildNumber'),
        );
        expect(controlText, contains('Architecture: amd64'));
        expect(
          controlText,
          contains(
            'Depends: libgtk-3-0 | libgtk-3-0t64, libglib2.0-0 | libglib2.0-0t64, xdg-utils',
          ),
        );

        final contentsRes = Process.runSync('dpkg-deb', <String>[
          '-c',
          debFile.path,
        ]);
        expect(contentsRes.exitCode, 0);
        final contentsText = contentsRes.stdout as String;
        expect(contentsText, contains('./opt/tallyisle/tallyisle'));
        expect(contentsText, contains('./usr/bin/tallyisle'));
        expect(
          contentsText,
          contains('./usr/share/applications/dev.tallyisle.rebuild.desktop'),
        );
        expect(
          contentsText,
          contains('./usr/share/metainfo/dev.tallyisle.rebuild.metainfo.xml'),
        );
        expect(
          contentsText,
          contains('./usr/share/mime/packages/dev.tallyisle.rebuild.mime.xml'),
        );
        for (final size in const <int>[16, 32, 64, 128, 256, 512]) {
          expect(
            contentsText,
            contains(
              './usr/share/icons/hicolor/${size}x$size/apps/dev.tallyisle.rebuild.png',
            ),
          );
        }
      },
    );
  });
}
