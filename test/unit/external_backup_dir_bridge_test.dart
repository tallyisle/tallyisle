import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/platform/files.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ExternalBackupDirBinding & ExternalBackupFileEntry models', () {
    test('JSON encode/decode round-trip and tryDecode resilience', () {
      const binding = ExternalBackupDirBinding(
        mode: ExternalBackupDirMode.androidSafTree,
        locator:
            'content://com.android.externalstorage.documents/tree/primary%3ADownload%2FTallyIsle',
        displayPath: '内部存储/Download/TallyIsle',
        boundAtMs: 1764000000123,
      );
      final encoded = binding.encode();
      final decoded = ExternalBackupDirBinding.tryDecode(encoded);
      expect(decoded, equals(binding));
      expect(decoded.hashCode, equals(binding.hashCode));

      expect(ExternalBackupDirBinding.tryDecode(null), isNull);
      expect(ExternalBackupDirBinding.tryDecode(''), isNull);
      expect(ExternalBackupDirBinding.tryDecode('not-json'), isNull);
      expect(
        ExternalBackupDirBinding.tryDecode('{"mode":"unknown","locator":"x"}'),
        isNull,
      );
      expect(
        ExternalBackupDirBinding.tryDecode('{"mode":"path","locator":"   "}'),
        isNull,
      );

      final entry =
          ExternalBackupFileEntry.tryFromChannelMap(<Object?, Object?>{
            'fileName': 'backup_20261124_120000.tally',
            'sizeBytes': 4096,
            'modifiedAtMs': 1764000000000,
          });
      expect(entry, isNotNull);
      expect(entry!.fileName, 'backup_20261124_120000.tally');
      expect(entry.sizeBytes, 4096);
      expect(entry.modifiedAtMs, 1764000000000);
      expect(
        ExternalBackupFileEntry.tryFromChannelMap(<Object?, Object?>{
          'fileName': '   ',
        }),
        isNull,
      );
    });
  });

  group('Six-platform capabilities & MethodChannel directory bridges', () {
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });

    test(
      'externalBackupDirCapability and openDirectoryCapability match all 6 platforms + Web',
      () {
        for (final platform in <TargetPlatform>[
          TargetPlatform.android,
          TargetPlatform.iOS,
          TargetPlatform.macOS,
          TargetPlatform.windows,
          TargetPlatform.linux,
        ]) {
          debugDefaultTargetPlatformOverride = platform;
          const access = FileAccess();
          expect(
            access.externalBackupDirCapability.state,
            CapabilityState.available,
            reason:
                'Expected externalBackupDirCapability available on $platform',
          );
          final isDesktop =
              platform == TargetPlatform.macOS ||
              platform == TargetPlatform.windows ||
              platform == TargetPlatform.linux;
          expect(
            access.openDirectoryCapability.state,
            isDesktop ? CapabilityState.available : CapabilityState.unsupported,
            reason: 'Unexpected openDirectoryCapability on $platform',
          );
        }

        // HarmonyOS NEXT
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        const ohosAccess = FileAccess(isOhosOverride: true);
        expect(
          ohosAccess.externalBackupDirCapability.state,
          CapabilityState.available,
        );
        expect(
          ohosAccess.openDirectoryCapability.state,
          CapabilityState.unsupported,
        );

        // Web
        const webAccess = FileAccess(isWebOverride: true);
        expect(
          webAccess.externalBackupDirCapability.state,
          CapabilityState.unsupported,
        );
        expect(
          webAccess.openDirectoryCapability.state,
          CapabilityState.unsupported,
        );
      },
    );

    test(
      'Android SAF tree, iOS Bookmark, HarmonyOS Download, and macOS Bookmark channel operations & cancel handling',
      () async {
        const channel = MethodChannel('com.tallyisle/test_ext_dir');
        final recordedCalls = <MethodCall>[];
        final virtualFiles = <String, Uint8List>{};
        var simulateCancel = false;
        var accessible = true;

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              recordedCalls.add(call);
              switch (call.method) {
                case 'pickBackupDirectory':
                  if (simulateCancel) {
                    throw PlatformException(
                      code: 'CANCELLED',
                      message: '已取消选择备份目录',
                    );
                  }
                  if (defaultTargetPlatform == TargetPlatform.iOS) {
                    return <String, Object?>{
                      'mode': 'appleBookmark',
                      'locator': 'aW9zLWJvb2ttYXJrLWJhc2U2NA==',
                      'displayPath': 'iCloud 云盘 / TallyBackups',
                    };
                  }
                  if (defaultTargetPlatform == TargetPlatform.macOS) {
                    return <String, Object?>{
                      'mode': 'appleBookmark',
                      'locator': 'bWFjb3MtYm9va21hcmstYmFzZTY0',
                      'displayPath': '/Users/alice/Documents/TallyBackups',
                    };
                  }
                  return <String, Object?>{
                    'mode': 'androidSafTree',
                    'locator': 'content://tree/primary%3ADownload%2FTallyIsle',
                    'displayPath': '内部存储/Download/TallyIsle',
                  };
                case 'checkDirectoryAccessible':
                  return accessible;
                case 'listDirectoryBackups':
                  return <Map<String, Object?>>[
                    for (final e in virtualFiles.entries)
                      <String, Object?>{
                        'fileName': e.key,
                        'sizeBytes': e.value.length,
                        'modifiedAtMs': 1764000001000,
                      },
                    <String, Object?>{
                      'fileName': 'partial.tally.tmp',
                      'sizeBytes': 12,
                      'modifiedAtMs': 1764000002000,
                    },
                  ];
                case 'writeDirectoryBackup':
                  final args = call.arguments as Map<Object?, Object?>;
                  final name = args['fileName'] as String;
                  final bytes = args['bytes'] as Uint8List;
                  virtualFiles[name] = bytes;
                  return null;
                case 'readDirectoryBackup':
                  final args = call.arguments as Map<Object?, Object?>;
                  final name = args['fileName'] as String;
                  final found = virtualFiles[name];
                  if (found == null) {
                    throw PlatformException(code: 'IO_ERROR', message: '文件不存在');
                  }
                  return found;
                case 'deleteDirectoryBackup':
                  final args = call.arguments as Map<Object?, Object?>;
                  virtualFiles.remove(args['fileName'] as String);
                  return null;
                case 'openBackupDirectory':
                  return null;
                default:
                  return null;
              }
            });
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
        });

        // 1. Android SAF pick, write, list (filters .tmp), read, delete, cancel
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        const access = FileAccess(channel: channel);
        final safBinding = await access.pickExternalBackupDirectory(
          nowMs: 12345,
        );
        expect(safBinding.mode, ExternalBackupDirMode.androidSafTree);
        expect(safBinding.displayPath, '内部存储/Download/TallyIsle');
        expect(
          await access.checkExternalDirectoryAccessible(safBinding),
          isTrue,
        );

        final sampleBytes = Uint8List.fromList(<int>[80, 75, 3, 4, 99]);
        await access.writeExternalDirectoryFile(
          safBinding,
          'backup_20261124_090000.tally',
          sampleBytes,
        );
        final listed = await access.listExternalDirectoryFiles(safBinding);
        expect(listed.map((e) => e.fileName).toList(), <String>[
          'backup_20261124_090000.tally',
        ]);
        expect(
          await access.readExternalDirectoryFile(
            safBinding,
            'backup_20261124_090000.tally',
          ),
          equals(sampleBytes),
        );
        await access.deleteExternalDirectoryFile(
          safBinding,
          'backup_20261124_090000.tally',
        );
        expect(await access.listExternalDirectoryFiles(safBinding), isEmpty);

        // Cancel must throw FailureCode.cancelled (ADR-009)
        simulateCancel = true;
        await expectLater(
          access.pickExternalBackupDirectory(),
          throwsA(
            isA<Failure>().having((f) => f.code, 'code', FailureCode.cancelled),
          ),
        );
        simulateCancel = false;

        // Path traversal rejected before hitting native channel
        await expectLater(
          access.writeExternalDirectoryFile(
            safBinding,
            '../escape.tally',
            sampleBytes,
          ),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.validation,
            ),
          ),
        );

        // 2. iOS Bookmark & macOS Bookmark + openBackupDirectory
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        final iosBinding = await access.pickExternalBackupDirectory(
          nowMs: 22222,
        );
        expect(iosBinding.mode, ExternalBackupDirMode.appleBookmark);
        expect(iosBinding.displayPath, 'iCloud 云盘 / TallyBackups');

        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        recordedCalls.clear();
        final macBinding = await access.pickExternalBackupDirectory(
          nowMs: 33333,
        );
        expect(macBinding.mode, ExternalBackupDirMode.appleBookmark);
        await access.openBackupDirectory(macBinding);
        expect(
          recordedCalls.map((c) => c.method).toList(),
          contains('openBackupDirectory'),
        );

        accessible = false;
        expect(
          await access.checkExternalDirectoryAccessible(macBinding),
          isFalse,
        );
      },
    );

    test(
      'Filesystem path mode writes atomically via .tmp and detects unplugged/deleted folder',
      () async {
        final tempRoot = await Directory.systemTemp.createTemp(
          'tally_ext_path_bridge_',
        );
        addTearDown(() async {
          if (await tempRoot.exists()) {
            await tempRoot.delete(recursive: true);
          }
        });

        final extDir = Directory(p.join(tempRoot.path, 'TallyBackups'));
        await extDir.create(recursive: true);
        await File(
          p.join(extDir.path, 'dangling.tally.tmp'),
        ).writeAsBytes(const <int>[1, 2]);

        final binding = ExternalBackupDirBinding(
          mode: ExternalBackupDirMode.path,
          locator: extDir.path,
          displayPath: extDir.path,
          boundAtMs: 1764000000000,
        );

        const access = FileAccess();
        expect(await access.checkExternalDirectoryAccessible(binding), isTrue);

        final payload = Uint8List.fromList(<int>[10, 20, 30, 40, 50]);
        await access.writeExternalDirectoryFile(
          binding,
          'backup_20261124_150000.tally',
          payload,
        );
        expect(
          await File(
            p.join(extDir.path, 'backup_20261124_150000.tally.tmp'),
          ).exists(),
          isFalse,
        );
        final files = await access.listExternalDirectoryFiles(binding);
        expect(files.map((f) => f.fileName).toList(), <String>[
          'backup_20261124_150000.tally',
        ]);
        expect(
          await access.readExternalDirectoryFile(
            binding,
            'backup_20261124_150000.tally',
          ),
          equals(payload),
        );

        // Simulate unplugging USB drive / deleting external directory: must NOT silently re-create!
        await extDir.delete(recursive: true);
        expect(await access.checkExternalDirectoryAccessible(binding), isFalse);
        await expectLater(
          access.writeExternalDirectoryFile(
            binding,
            'after_unplug.tally',
            payload,
          ),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.storageUnavailable,
            ),
          ),
        );
        expect(await extDir.exists(), isFalse);
      },
    );

    test(
      'Native bridge sources wire SAF tree, iOS UIDocumentPicker Save-to-Files, HarmonyOS DOWNLOAD, and macOS app-scope bookmarks',
      () {
        final androidKt = File(
          'android/app/src/main/kotlin/com/tallyisle/app/FileBridge.kt',
        ).readAsStringSync();
        expect(androidKt, contains('ACTION_OPEN_DOCUMENT_TREE'));
        expect(androidKt, contains('takePersistableUriPermission'));
        expect(androidKt, contains('REQUEST_CODE_PICK_DIRECTORY = 4036'));
        expect(androidKt, contains('pickBackupDirectory'));
        expect(androidKt, contains('writeDirectoryBackup'));

        final iosSwift = File(
          'ios/Runner/AppDelegate.swift',
        ).readAsStringSync();
        expect(
          iosSwift,
          contains(
            'UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)',
          ),
        );
        expect(iosSwift, contains('UIActivityViewController'));
        expect(iosSwift, contains('pickBackupDirectory'));
        expect(iosSwift, contains('startAccessingSecurityScopedResource'));
        expect(iosSwift, contains('stopAccessingSecurityScopedResource'));

        final ohosEts = File(
          'ohos/entry/src/main/ets/plugins/FileBridge.ets',
        ).readAsStringSync();
        expect(ohosEts, contains('picker.DocumentPickerMode.DOWNLOAD'));
        expect(ohosEts, isNot(contains('DocumentSaveMode')));
        expect(ohosEts, contains("'ohosDownload'"));
        expect(ohosEts, contains('文件管理 / 下载 / 帐屿'));
        expect(ohosEts, contains('fsyncSync'));
        expect(ohosEts, contains('renameSync'));

        final macSwift = File(
          'macos/Runner/AppDelegate.swift',
        ).readAsStringSync();
        expect(macSwift, contains('NSOpenPanel'));
        expect(macSwift, contains('withSecurityScope'));
        expect(macSwift, contains('openBackupDirectory'));
        expect(macSwift, contains('inFileViewerRootedAtPath'));

        for (final entPath in <String>[
          'macos/Runner/Release.entitlements',
          'macos/Runner/DebugProfile.entitlements',
        ]) {
          final plist = File(entPath).readAsStringSync();
          expect(
            plist,
            contains('com.apple.security.files.bookmarks.app-scope'),
          );
        }
      },
    );
  });
}
