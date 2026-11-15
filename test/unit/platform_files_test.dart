import 'dart:io';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/platform/files.dart';

class _FakeFileSelectorPlatform extends FileSelectorPlatform {
  List<XTypeGroup>? lastOpenTypeGroups;
  SaveDialogOptions? lastSaveOptions;

  Future<XFile?> Function(List<XTypeGroup>? groups)? onOpenFile;
  Future<FileSaveLocation?> Function(SaveDialogOptions options)?
  onGetSaveLocation;

  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    lastOpenTypeGroups = acceptedTypeGroups;
    if (onOpenFile != null) {
      return onOpenFile!(acceptedTypeGroups);
    }
    return null;
  }

  @override
  Future<FileSaveLocation?> getSaveLocation({
    List<XTypeGroup>? acceptedTypeGroups,
    SaveDialogOptions options = const SaveDialogOptions(),
  }) async {
    lastSaveOptions = options;
    if (onGetSaveLocation != null) {
      return onGetSaveLocation!(options);
    }
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FileSelectorPlatform originalFileSelector;
  late _FakeFileSelectorPlatform fakeFileSelector;

  setUp(() {
    originalFileSelector = FileSelectorPlatform.instance;
    fakeFileSelector = _FakeFileSelectorPlatform();
    FileSelectorPlatform.instance = fakeFileSelector;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    FileSelectorPlatform.instance = originalFileSelector;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(fileBridgeChannelName),
          null,
        );
  });

  group('FileAccess capability matrix across 6 targets', () {
    test(
      'Android and iOS expose native save and system share capabilities',
      () {
        for (final mobile in <TargetPlatform>[
          TargetPlatform.android,
          TargetPlatform.iOS,
        ]) {
          debugDefaultTargetPlatformOverride = mobile;
          const access = FileAccess();
          expect(
            access.saveLocationCapability.state,
            CapabilityState.available,
            reason: '$mobile saveLocationCapability should be available',
          );
          expect(
            access.shareCapability.state,
            CapabilityState.available,
            reason: '$mobile shareCapability should be available',
          );
        }
      },
    );

    test(
      'Windows, Linux, and macOS expose desktop save location while disabling native share',
      () {
        for (final desktop in <TargetPlatform>[
          TargetPlatform.windows,
          TargetPlatform.linux,
          TargetPlatform.macOS,
        ]) {
          debugDefaultTargetPlatformOverride = desktop;
          const access = FileAccess();
          expect(
            access.saveLocationCapability.state,
            CapabilityState.available,
            reason: '$desktop saveLocationCapability should be available',
          );
          expect(
            access.shareCapability.state,
            CapabilityState.unsupported,
            reason: '$desktop shareCapability should be unsupported',
          );
        }
      },
    );

    test(
      'Web reports unsupported for saveLocation and share unless custom handlers are injected',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        const webAccess = FileAccess(isWebOverride: true);
        expect(
          webAccess.saveLocationCapability.state,
          CapabilityState.unsupported,
        );
        expect(webAccess.shareCapability.state, CapabilityState.unsupported);

        final payload = Uint8List.fromList(<int>[7, 8, 9]);
        await expectLater(
          webAccess.saveBytes('export.tally', payload),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.unsupportedCapability,
            ),
          ),
        );
        await expectLater(
          webAccess.shareBytes('export.tally', payload),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.unsupportedCapability,
            ),
          ),
        );

        var customSaved = false;
        var customShared = false;
        final injectedWeb = FileAccess(
          isWebOverride: true,
          onSaveBytes: (_, _, _) async => customSaved = true,
          onShareBytes: (_, _, _, _) async => customShared = true,
        );
        expect(
          injectedWeb.saveLocationCapability.state,
          CapabilityState.available,
        );
        expect(injectedWeb.shareCapability.state, CapabilityState.available);
        await injectedWeb.saveBytes('export.tally', payload);
        await injectedWeb.shareBytes('export.tally', payload);
        expect(customSaved, isTrue);
        expect(customShared, isTrue);
      },
    );
  });

  group('Mobile MethodChannel bridge (Android & iOS)', () {
    for (final platform in <TargetPlatform>[
      TargetPlatform.android,
      TargetPlatform.iOS,
    ]) {
      test(
        'saveBytes and shareBytes succeed, infer MIME types, and map CANCELLED / IO_ERROR / MissingPluginException on $platform',
        () async {
          debugDefaultTargetPlatformOverride = platform;
          const channel = MethodChannel(fileBridgeChannelName);
          final recordedCalls = <MethodCall>[];
          String? throwCode;

          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, (call) async {
                recordedCalls.add(call);
                final code = throwCode;
                if (code != null) {
                  throw PlatformException(
                    code: code,
                    message: 'mock error $code',
                  );
                }
                return null;
              });

          const access = FileAccess(channel: channel);
          final bytes = Uint8List.fromList(<int>[0x50, 0x4B, 0x03, 0x04]);

          await access.saveBytes('ledger_2026.csv', bytes);
          await access.shareBytes('receipt.png', bytes, subject: '帐屿票据');

          expect(recordedCalls, hasLength(2));
          expect(recordedCalls[0].method, 'saveBytes');
          final saveArgs = recordedCalls[0].arguments as Map<Object?, Object?>;
          expect(saveArgs['suggestedName'], 'ledger_2026.csv');
          expect(saveArgs['mimeType'], 'text/csv');
          expect(saveArgs['bytes'], bytes);

          expect(recordedCalls[1].method, 'shareBytes');
          final shareArgs = recordedCalls[1].arguments as Map<Object?, Object?>;
          expect(shareArgs['fileName'], 'receipt.png');
          expect(shareArgs['mimeType'], 'image/png');
          expect(shareArgs['subject'], '帐屿票据');
          expect(shareArgs['bytes'], bytes);

          // Cancel paths -> FailureCode.cancelled
          throwCode = 'CANCELLED';
          await expectLater(
            access.saveBytes('cancel.tally', bytes),
            throwsA(
              isA<Failure>().having(
                (f) => f.code,
                'code',
                FailureCode.cancelled,
              ),
            ),
          );
          await expectLater(
            access.shareBytes('cancel.tally', bytes),
            throwsA(
              isA<Failure>().having(
                (f) => f.code,
                'code',
                FailureCode.cancelled,
              ),
            ),
          );

          // Native IO failure -> FailureCode.storageUnavailable
          throwCode = 'IO_ERROR';
          await expectLater(
            access.saveBytes('fail.tally', bytes),
            throwsA(
              isA<Failure>().having(
                (f) => f.code,
                'code',
                FailureCode.storageUnavailable,
              ),
            ),
          );
          await expectLater(
            access.shareBytes('fail.tally', bytes),
            throwsA(
              isA<Failure>().having(
                (f) => f.code,
                'code',
                FailureCode.storageUnavailable,
              ),
            ),
          );

          // Unmounted channel -> MissingPluginException -> FailureCode.unsupportedCapability
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
          await expectLater(
            access.saveBytes('missing.tally', bytes),
            throwsA(
              isA<Failure>().having(
                (f) => f.code,
                'code',
                FailureCode.unsupportedCapability,
              ),
            ),
          );
          await expectLater(
            access.shareBytes('missing.tally', bytes),
            throwsA(
              isA<Failure>().having(
                (f) => f.code,
                'code',
                FailureCode.unsupportedCapability,
              ),
            ),
          );
        },
      );
    }
  });

  group('Desktop file_selector integration (Windows, Linux, macOS)', () {
    for (final desktop in <TargetPlatform>[
      TargetPlatform.windows,
      TargetPlatform.linux,
      TargetPlatform.macOS,
    ]) {
      test(
        'saveBytes writes file via getSaveLocation, handles cancel/error, and rejects shareBytes on $desktop',
        () async {
          debugDefaultTargetPlatformOverride = desktop;
          final tempDir = await Directory.systemTemp.createTemp(
            'tallyisle_files_test_',
          );
          addTearDown(() async {
            if (await tempDir.exists()) {
              await tempDir.delete(recursive: true);
            }
          });

          const access = FileAccess();
          final payload = Uint8List.fromList(<int>[10, 20, 30, 40, 50]);
          final destPath = '${tempDir.path}/exported.ya2i';

          fakeFileSelector.onGetSaveLocation = (options) async {
            expect(options.suggestedName, 'exported.ya2i');
            return FileSaveLocation(destPath);
          };

          await access.saveBytes('exported.ya2i', payload);
          expect(await File(destPath).readAsBytes(), payload);

          // User cancels save dialog -> FailureCode.cancelled
          fakeFileSelector.onGetSaveLocation = (_) async => null;
          await expectLater(
            access.saveBytes('cancelled.ya2i', payload),
            throwsA(
              isA<Failure>().having(
                (f) => f.code,
                'code',
                FailureCode.cancelled,
              ),
            ),
          );

          // Dialog throws error -> FailureCode.storageUnavailable
          fakeFileSelector.onGetSaveLocation = (_) async {
            throw const FileSystemException('disk full');
          };
          await expectLater(
            access.saveBytes('error.ya2i', payload),
            throwsA(
              isA<Failure>().having(
                (f) => f.code,
                'code',
                FailureCode.storageUnavailable,
              ),
            ),
          );

          // shareBytes is unsupported on desktop without custom handler
          await expectLater(
            access.shareBytes('exported.ya2i', payload),
            throwsA(
              isA<Failure>().having(
                (f) => f.code,
                'code',
                FailureCode.unsupportedCapability,
              ),
            ),
          );
        },
      );
    }
  });

  group('pickBytes across mobile, desktop, and Web', () {
    test(
      'passes empty acceptedTypeGroups on Android and iOS so custom extensions (.tally/.penny/.yi2a) never fail UTI/MIME filtering',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'tallyisle_pick_mobile_',
        );
        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });
        final expectedBytes = Uint8List.fromList(<int>[1, 3, 5, 7]);
        final sampleFile = File('${tempDir.path}/backup.tally');
        await sampleFile.writeAsBytes(expectedBytes);
        fakeFileSelector.onOpenFile = (_) async => XFile(sampleFile.path);

        for (final mobile in <TargetPlatform>[
          TargetPlatform.android,
          TargetPlatform.iOS,
        ]) {
          debugDefaultTargetPlatformOverride = mobile;
          const access = FileAccess();
          final picked = await access.pickBytes(
            allowedExtensions: const <String>['tally', 'penny'],
          );
          expect(picked.name, 'backup.tally');
          expect(picked.bytes, expectedBytes);
          expect(fakeFileSelector.lastOpenTypeGroups, isEmpty);
        }
      },
    );

    test(
      'passes extension XTypeGroup on Windows, Linux, macOS, and Web, and maps cancel/error cleanly',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'tallyisle_pick_desktop_',
        );
        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });
        final expectedBytes = Uint8List.fromList(<int>[9, 8, 7]);
        final sampleFile = File('${tempDir.path}/bills.csv');
        await sampleFile.writeAsBytes(expectedBytes);
        fakeFileSelector.onOpenFile = (_) async => XFile(sampleFile.path);

        for (final desktop in <TargetPlatform>[
          TargetPlatform.windows,
          TargetPlatform.linux,
          TargetPlatform.macOS,
        ]) {
          debugDefaultTargetPlatformOverride = desktop;
          const access = FileAccess();
          final picked = await access.pickBytes(
            allowedExtensions: const <String>['csv', 'zip'],
          );
          expect(picked.name, 'bills.csv');
          expect(picked.bytes, expectedBytes);
          expect(fakeFileSelector.lastOpenTypeGroups, hasLength(1));
          expect(
            fakeFileSelector.lastOpenTypeGroups!.single.extensions,
            const <String>['csv', 'zip'],
          );
        }

        // Web pickBytes also forwards extension filter cleanly
        const webAccess = FileAccess(isWebOverride: true);
        final webPicked = await webAccess.pickBytes(
          allowedExtensions: const <String>['tally'],
        );
        expect(webPicked.name, 'bills.csv');
        expect(webPicked.bytes, expectedBytes);
        expect(
          fakeFileSelector.lastOpenTypeGroups!.single.extensions,
          const <String>['tally'],
        );

        // Cancel -> FailureCode.cancelled
        fakeFileSelector.onOpenFile = (_) async => null;
        await expectLater(
          webAccess.pickBytes(),
          throwsA(
            isA<Failure>().having((f) => f.code, 'code', FailureCode.cancelled),
          ),
        );

        // Read/open error -> FailureCode.permissionDenied
        fakeFileSelector.onOpenFile = (_) async {
          throw StateError('unreadable');
        };
        await expectLater(
          webAccess.pickBytes(),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.permissionDenied,
            ),
          ),
        );
      },
    );
  });

  group('openExternalUrl across validation, overrides, Web, and Mobile', () {
    test(
      'rejects empty, javascript:, file:, custom scheme, and hostless URLs before invoking handler',
      () async {
        final opened = <String>[];
        final access = FileAccess(
          onOpenExternalUrl: (url) async => opened.add(url),
        );

        for (final invalid in <String>[
          '',
          '   ',
          'javascript:alert(1)',
          'file:///etc/passwd',
          'tallyisle://add?money=10',
          'https://',
          'http:///missing-host',
        ]) {
          await expectLater(
            access.openExternalUrl(invalid),
            throwsA(
              isA<Failure>()
                  .having((f) => f.code, 'code', FailureCode.validation)
                  .having((f) => f.message, 'message', '仅支持打开 HTTP/HTTPS 网页链接'),
            ),
            reason: 'Expected validation failure for "$invalid"',
          );
        }
        expect(opened, isEmpty);

        // Valid trimmed HTTP/HTTPS URLs invoke onOpenExternalUrl override
        await access.openExternalUrl(
          '  https://github.com/tallyisle/tallyisle  ',
        );
        await access.openExternalUrl('http://example.com/issues');
        expect(opened, const <String>[
          'https://github.com/tallyisle/tallyisle',
          'http://example.com/issues',
        ]);
      },
    );

    test(
      'Web throws unsupportedCapability unless onOpenExternalUrl override is supplied',
      () async {
        const webAccess = FileAccess(isWebOverride: true);
        await expectLater(
          webAccess.openExternalUrl('https://github.com/tallyisle/tallyisle'),
          throwsA(
            isA<Failure>()
                .having(
                  (f) => f.code,
                  'code',
                  FailureCode.unsupportedCapability,
                )
                .having((f) => f.message, 'message', '当前环境不支持直接打开外部浏览器'),
          ),
        );

        String? captured;
        final overriddenWeb = FileAccess(
          isWebOverride: true,
          onOpenExternalUrl: (url) async => captured = url,
        );
        await overriddenWeb.openExternalUrl(
          'https://github.com/tallyisle/tallyisle/issues',
        );
        expect(captured, 'https://github.com/tallyisle/tallyisle/issues');
      },
    );

    for (final platform in <TargetPlatform>[
      TargetPlatform.android,
      TargetPlatform.iOS,
    ]) {
      test(
        'invokes native openExternalUrl MethodChannel and maps PlatformException / MissingPluginException on $platform',
        () async {
          debugDefaultTargetPlatformOverride = platform;
          const channel = MethodChannel(fileBridgeChannelName);
          final recordedCalls = <MethodCall>[];
          var shouldFail = false;

          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, (call) async {
                recordedCalls.add(call);
                if (shouldFail) {
                  throw PlatformException(
                    code: 'UNAVAILABLE',
                    message: '无法调起系统浏览器',
                  );
                }
                return null;
              });

          const access = FileAccess(channel: channel);
          await access.openExternalUrl(
            'https://github.com/tallyisle/tallyisle',
          );

          expect(recordedCalls, hasLength(1));
          expect(recordedCalls.single.method, 'openExternalUrl');
          expect(recordedCalls.single.arguments, <Object?, Object?>{
            'url': 'https://github.com/tallyisle/tallyisle',
          });

          shouldFail = true;
          await expectLater(
            access.openExternalUrl(
              'https://github.com/tallyisle/tallyisle/issues',
            ),
            throwsA(
              isA<Failure>()
                  .having(
                    (f) => f.code,
                    'code',
                    FailureCode.unsupportedCapability,
                  )
                  .having((f) => f.message, 'message', '无法调起系统浏览器'),
            ),
          );

          // Unmounted channel -> MissingPluginException -> unsupportedCapability
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
          await expectLater(
            access.openExternalUrl('https://github.com/tallyisle/tallyisle'),
            throwsA(
              isA<Failure>().having(
                (f) => f.code,
                'code',
                FailureCode.unsupportedCapability,
              ),
            ),
          );
        },
      );
    }
  });

  group('HarmonyOS (ohos) MethodChannel bridge & capabilities', () {
    test(
      'exposes native save/share capabilities, passes empty pickBytes groups, and maps MethodChannel outcomes',
      () async {
        const channel = MethodChannel(fileBridgeChannelName);
        final recordedCalls = <MethodCall>[];
        String? throwCode;

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              recordedCalls.add(call);
              final code = throwCode;
              if (code != null) {
                throw PlatformException(code: code, message: 'ohos mock $code');
              }
              return null;
            });

        // Also verify dynamic TargetPlatform.ohos detection when running under CPF-Flutter.
        final ohosTargets = TargetPlatform.values
            .where((p) => p.name == 'ohos')
            .toList();
        for (final target in ohosTargets) {
          debugDefaultTargetPlatformOverride = target;
          const nativeDetected = FileAccess(channel: channel);
          expect(
            nativeDetected.saveLocationCapability.state,
            CapabilityState.available,
          );
          expect(
            nativeDetected.shareCapability.state,
            CapabilityState.available,
          );
        }
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;

        const access = FileAccess(channel: channel, isOhosOverride: true);
        expect(access.saveLocationCapability.state, CapabilityState.available);
        expect(access.saveLocationCapability.reason, contains('HarmonyOS'));
        expect(access.shareCapability.state, CapabilityState.available);
        expect(access.shareCapability.reason, contains('HarmonyOS'));

        // pickBytes uses empty acceptedTypeGroups so .tally/.penny files are selectable
        final tempDir = await Directory.systemTemp.createTemp(
          'tallyisle_pick_ohos_',
        );
        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });
        final sampleBytes = Uint8List.fromList(<int>[0x50, 0x4B, 0x03, 0x04]);
        final sampleFile = File('${tempDir.path}/backup_ohos.tally');
        await sampleFile.writeAsBytes(sampleBytes);
        fakeFileSelector.onOpenFile = (_) async => XFile(sampleFile.path);

        final picked = await access.pickBytes(
          allowedExtensions: const <String>['tally', 'penny', 'yi2a'],
        );
        expect(picked.name, 'backup_ohos.tally');
        expect(picked.bytes, sampleBytes);
        expect(fakeFileSelector.lastOpenTypeGroups, isEmpty);

        // saveBytes, shareBytes, openExternalUrl succeed over dev.tallyisle/files
        await access.saveBytes('ohos_backup.tally', sampleBytes);
        await access.shareBytes(
          'ohos_backup.zip',
          sampleBytes,
          subject: '帐屿备份',
        );
        await access.openExternalUrl('https://github.com/tallyisle/tallyisle');

        expect(recordedCalls, hasLength(3));
        expect(recordedCalls[0].method, 'saveBytes');
        expect(recordedCalls[1].method, 'shareBytes');
        expect(recordedCalls[2].method, 'openExternalUrl');

        // Cancel -> FailureCode.cancelled
        throwCode = 'CANCELLED';
        await expectLater(
          access.saveBytes('cancel.tally', sampleBytes),
          throwsA(
            isA<Failure>().having((f) => f.code, 'code', FailureCode.cancelled),
          ),
        );
        await expectLater(
          access.shareBytes('cancel.tally', sampleBytes),
          throwsA(
            isA<Failure>().having((f) => f.code, 'code', FailureCode.cancelled),
          ),
        );

        // IO_ERROR -> FailureCode.storageUnavailable
        throwCode = 'IO_ERROR';
        await expectLater(
          access.saveBytes('fail.tally', sampleBytes),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.storageUnavailable,
            ),
          ),
        );

        // MissingPluginException -> HarmonyOS-specific unsupportedCapability reason
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        await expectLater(
          access.saveBytes('missing.tally', sampleBytes),
          throwsA(
            isA<Failure>()
                .having(
                  (f) => f.code,
                  'code',
                  FailureCode.unsupportedCapability,
                )
                .having((f) => f.message, 'message', contains('HarmonyOS')),
          ),
        );
        await expectLater(
          access.shareBytes('missing.tally', sampleBytes),
          throwsA(
            isA<Failure>()
                .having(
                  (f) => f.code,
                  'code',
                  FailureCode.unsupportedCapability,
                )
                .having((f) => f.message, 'message', contains('HarmonyOS')),
          ),
        );
        await expectLater(
          access.openExternalUrl('https://github.com/tallyisle/tallyisle'),
          throwsA(
            isA<Failure>()
                .having(
                  (f) => f.code,
                  'code',
                  FailureCode.unsupportedCapability,
                )
                .having((f) => f.message, 'message', contains('HarmonyOS')),
          ),
        );
      },
    );
  });
}
