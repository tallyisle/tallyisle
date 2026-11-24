import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Locale;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/platform/app_widgets.dart';
import 'package:tallyisle/platform/auto_bill_bridge.dart';
import 'package:tallyisle/platform/biometrics.dart';
import 'package:tallyisle/platform/files.dart';
import 'package:tallyisle/platform/notifications.dart';

Future<ByteData?> _sendNativeToFlutterCall(
  String channelName,
  MethodCall call,
) {
  final encoded = const StandardMethodCodec().encodeMethodCall(call);
  final completer = Completer<ByteData?>();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(channelName, encoded, completer.complete);
  return completer.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel(biometricChannelName),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel(automationChannelName),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel(reminderChannelName),
      null,
    );
  });

  group('HarmonyOS BiometricAuthenticator (dev.tallyisle/biometrics)', () {
    test(
      'selects MethodChannelBiometricAuthenticator on TargetPlatform.ohos and maps UserAuth statuses & outcomes',
      () async {
        final ohosTargets = TargetPlatform.values
            .where((p) => p.name == 'ohos')
            .toList();
        for (final target in ohosTargets) {
          debugDefaultTargetPlatformOverride = target;
          final detected = createBiometricAuthenticator();
          expect(detected, isA<MethodChannelBiometricAuthenticator>());
          expect(detected.capability.state, CapabilityState.available);
          expect(detected.capability.reason, contains('HarmonyOS'));
        }
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;

        const channel = MethodChannel(biometricChannelName);
        final calls = <MethodCall>[];
        Map<String, Object?> availabilityReply = <String, Object?>{
          'status': 'available',
          'reason': '可使用系统指纹或面容解锁',
          'deviceSecure': true,
        };
        Map<String, Object?> authReply = <String, Object?>{
          'outcome': 'authenticated',
          'message': '生物识别验证通过',
        };

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              calls.add(call);
              return switch (call.method) {
                'checkAvailability' => availabilityReply,
                'authenticate' => authReply,
                'cancelAuthentication' => null,
                _ => null,
              };
            });

        final auth = createBiometricAuthenticator(isOhosOverride: true);
        expect(auth.capability.state, CapabilityState.available);
        expect(auth.capability.reason, contains('HarmonyOS'));

        // 1. Available + enrolled
        final avail = await auth.checkAvailability();
        expect(avail.status, BiometricAvailabilityStatus.available);
        expect(avail.canAuthenticate, isTrue);
        expect(avail.deviceSecure, isTrue);

        // 2. Not enrolled (UserAuth 12500010)
        availabilityReply = <String, Object?>{
          'status': 'notEnrolled',
          'reason': '系统尚未录入指纹或面容，请先在系统设置中录入',
          'deviceSecure': true,
        };
        expect(
          (await auth.checkAvailability()).status,
          BiometricAvailabilityStatus.notEnrolled,
        );

        // 3. No hardware (UserAuth 12500005 / 12500006)
        availabilityReply = <String, Object?>{
          'status': 'noHardware',
          'reason': '当前设备无指纹或面容识别硬件',
          'deviceSecure': false,
        };
        expect(
          (await auth.checkAvailability()).status,
          BiometricAvailabilityStatus.noHardware,
        );

        // 4. Authenticate outcomes: authenticated, cancelled (CANCELED_FROM_WIDGET), lockout, failed
        final okRes = await auth.authenticate(
          title: '解锁帐屿',
          subtitle: '请验证指纹',
          negativeButtonText: '使用数字密码',
        );
        expect(okRes.isAuthenticated, isTrue);
        final authArgs =
            calls.lastWhere((c) => c.method == 'authenticate').arguments
                as Map<Object?, Object?>;
        expect(authArgs['title'], '解锁帐屿');
        expect(authArgs['negativeButtonText'], '使用数字密码');

        authReply = <String, Object?>{
          'outcome': 'cancelled',
          'message': '已切换为数字密码验证',
        };
        expect(
          (await auth.authenticate(
            title: '   ',
            negativeButtonText: '',
          )).outcome,
          BiometricAuthOutcome.cancelled,
        );
        final fallbackArgs =
            calls.lastWhere((c) => c.method == 'authenticate').arguments
                as Map<Object?, Object?>;
        expect(
          fallbackArgs['title'],
          anyOf('验证身份以解锁帐屿', 'Verify identity to unlock TallyIsle'),
        );
        expect(fallbackArgs['negativeButtonText'], anyOf('使用数字密码', 'Use PIN'));

        authReply = <String, Object?>{
          'outcome': 'lockout',
          'message': '生物识别尝试次数过多，请使用数字密码解锁',
        };
        expect(
          (await auth.authenticate()).outcome,
          BiometricAuthOutcome.lockout,
        );

        await auth.cancelAuthentication();
        expect(calls.last.method, 'cancelAuthentication');
      },
    );

    test(
      'resolves bilingual biometric default copy for zh and non-zh locales',
      () {
        const zhCn = Locale('zh', 'CN');
        const zhTw = Locale('zh', 'TW');
        const enUs = Locale('en', 'US');

        expect(defaultBiometricPromptTitle(zhCn), '验证身份以解锁帐屿');
        expect(defaultBiometricPromptTitle(zhTw), '验证身份以解锁帐屿');
        expect(
          defaultBiometricPromptTitle(enUs),
          'Verify identity to unlock TallyIsle',
        );
        expect(defaultBiometricNegativeButtonText(zhCn), '使用数字密码');
        expect(defaultBiometricNegativeButtonText(enUs), 'Use PIN');
        expect(defaultBiometricPromptSubtitle(zhCn), contains('指纹或面容'));
        expect(defaultBiometricPromptSubtitle(enUs), contains('fingerprint'));
        expect(defaultBiometricUnsupportedReason(zhCn), contains('数字密码'));
        expect(defaultBiometricUnsupportedReason(enUs), contains('PIN'));
      },
    );
  });

  group('HarmonyOS AutoBillBridge & AppWidgetBridge (dev.tallyisle/automation)', () {
    test(
      'handles tallyisle:// deep links exclusively while honestly reporting AccessibilityService & desktop widgets as unsupported (ADR-008)',
      () async {
        final ohosTargets = TargetPlatform.values
            .where((p) => p.name == 'ohos')
            .toList();
        for (final target in ohosTargets) {
          debugDefaultTargetPlatformOverride = target;
          final widgetBridge = createAppWidgetBridge();
          expect(widgetBridge.capability.state, CapabilityState.unsupported);
          expect(
            await widgetBridge.requestPinWidget(DesktopWidgetKind.quickAdd),
            isFalse,
          );
          await widgetBridge.dispose();
        }
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;

        const channel = MethodChannel(automationChannelName);
        String? pendingUri = 'tallyisle://add?type=0&money=28.50&remark=早餐';
        var throwOnStatus = false;

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              switch (call.method) {
                case 'consumePendingDeepLink':
                  final out = pendingUri;
                  pendingUri = null;
                  return out;
                case 'getAccessibilityStatus':
                  if (throwOnStatus) {
                    throw PlatformException(code: 'ERR', message: 'unexpected');
                  }
                  return <String, Object?>{
                    'supported': false,
                    'enabled': false,
                    'statusLabel': '当前平台不支持',
                  };
                case 'openAccessibilitySettings':
                  return false;
                case 'consumeCapturedEvents':
                  return const <Object?>[];
                default:
                  return null;
              }
            });

        final bridge = createAutoBillBridge(isOhosOverride: true);
        addTearDown(bridge.dispose);

        expect(bridge.capability.state, CapabilityState.available);
        expect(bridge.capability.reason, contains('HarmonyOS'));
        expect(bridge.capability.reason, contains('tallyisle://'));
        expect(bridge.capability.reason.toLowerCase(), isNot(contains('yyjz')));

        // Cold-start deep link consumption
        expect(
          await bridge.consumePendingDeepLink(),
          'tallyisle://add?type=0&money=28.50&remark=早餐',
        );
        expect(await bridge.consumePendingDeepLink(), isNull);

        // Before listener attaches, native onDeepLink receives false so native keeps pendingDeepLinkUri
        final unhandledReply = await _sendNativeToFlutterCall(
          automationChannelName,
          const MethodCall('onDeepLink', 'tallyisle://add?money=15'),
        );
        expect(
          const StandardMethodCodec().decodeEnvelope(unhandledReply!),
          isFalse,
        );

        // Once listener attaches, native onDeepLink streams URI and receives true
        final receivedLinks = <String>[];
        final sub = bridge.onDeepLink.listen(receivedLinks.add);
        addTearDown(sub.cancel);

        final handledReply = await _sendNativeToFlutterCall(
          automationChannelName,
          const MethodCall('onDeepLink', 'tallyisle://add?money=15'),
        );
        expect(
          const StandardMethodCodec().decodeEnvelope(handledReply!),
          isTrue,
        );
        await Future<void>.delayed(Duration.zero);
        expect(receivedLinks, const <String>['tallyisle://add?money=15']);

        // Honest unsupported AccessibilityService status on HarmonyOS (both normal & error fallback)
        final status = await bridge.getAccessibilityStatus();
        expect(status, const AccessibilityBridgeStatus.unsupported());
        expect(status.statusLabel, accessibilityUnsupportedLabel);
        expect(await bridge.openAccessibilitySettings(), isFalse);
        expect(await bridge.consumeCapturedEvents(), isEmpty);

        throwOnStatus = true;
        expect(
          await bridge.getAccessibilityStatus(),
          const AccessibilityBridgeStatus.unsupported(),
        );

        // MissingPluginException fallback on OHOS also stays unsupported (never Android '未开启')
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        expect(
          await bridge.getAccessibilityStatus(),
          const AccessibilityBridgeStatus.unsupported(),
        );
      },
    );
  });

  group('HarmonyOS ReminderScheduler (dev.tallyisle/reminders)', () {
    test(
      'synchronizes daily reminders, checks/requests notification permission, and dispatches launch routes',
      () async {
        const channel = MethodChannel(reminderChannelName);
        final calls = <MethodCall>[];
        var notificationsEnabled = false;
        String? pendingRoute = '/record/new';
        var failOpenSettings = false;

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              calls.add(call);
              switch (call.method) {
                case 'areNotificationsEnabled':
                  return notificationsEnabled;
                case 'requestPermission':
                  notificationsEnabled = true;
                  return true;
                case 'openNotificationSettings':
                  if (failOpenSettings) {
                    throw PlatformException(
                      code: 'SETTINGS_UNAVAILABLE',
                      message: '无法打开系统通知设置',
                    );
                  }
                  return null;
                case 'syncReminders':
                case 'cancelReminder':
                case 'cancelAll':
                  return null;
                case 'consumePendingLaunchRoute':
                  final r = pendingRoute;
                  pendingRoute = null;
                  return r;
                default:
                  return null;
              }
            });

        final scheduler = createReminderScheduler(isOhosOverride: true);
        addTearDown(scheduler.dispose);

        expect(scheduler.capability.state, CapabilityState.available);
        expect(scheduler.capability.reason, contains('HarmonyOS'));

        expect(await scheduler.areNotificationsEnabled(), isFalse);
        expect(await scheduler.requestPermission(), isTrue);
        expect(await scheduler.areNotificationsEnabled(), isTrue);

        const sample = ScheduledReminder(
          id: 7,
          hour: 21,
          minute: 30,
          title: '晚间记账提醒',
          body: '今天花了多少？快来记一笔吧',
        );
        await scheduler.syncReminders(const <ScheduledReminder>[sample]);
        final syncCall = calls.lastWhere((c) => c.method == 'syncReminders');
        final syncArgs = syncCall.arguments as Map<Object?, Object?>;
        final list = syncArgs['reminders'] as List<Object?>;
        expect(list, hasLength(1));
        expect((list.single as Map<Object?, Object?>)['id'], 7);

        await scheduler.cancelReminder(7);
        expect(calls.last.method, 'cancelReminder');

        await scheduler.cancelAll();
        expect(calls.last.method, 'cancelAll');

        // Cold-start & warm-start launch routes
        expect(await scheduler.consumePendingLaunchRoute(), '/record/new');
        expect(await scheduler.consumePendingLaunchRoute(), isNull);

        final liveRoutes = <String>[];
        final sub = scheduler.onLaunchRoute.listen(liveRoutes.add);
        addTearDown(sub.cancel);

        final routeReply = await _sendNativeToFlutterCall(
          reminderChannelName,
          const MethodCall('onLaunchRoute', '/record/new'),
        );
        expect(const StandardMethodCodec().decodeEnvelope(routeReply!), isTrue);
        await Future<void>.delayed(Duration.zero);
        expect(liveRoutes, const <String>['/record/new']);

        // Settings jump & error mapping
        await scheduler.openNotificationSettings();
        failOpenSettings = true;
        await expectLater(
          scheduler.openNotificationSettings(),
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
  });

  group('HarmonyOS native manifest, bilingual resources, and import bridges', () {
    test(
      'app.json5 version matches 0.6.0+8 and module.json5 exposes exclusive tallyisle:// & permissions',
      () {
        final appJson =
            jsonDecode(File('ohos/AppScope/app.json5').readAsStringSync())
                as Map<String, Object?>;
        final app = appJson['app']! as Map<String, Object?>;
        expect(app['versionName'], '0.6.0');
        expect(app['versionCode'], 8);

        final moduleRaw = File(
          'ohos/entry/src/main/module.json5',
        ).readAsStringSync();
        expect(moduleRaw.toLowerCase(), isNot(contains('yyjz')));
        final moduleJson = jsonDecode(moduleRaw) as Map<String, Object?>;
        final module = moduleJson['module']! as Map<String, Object?>;
        final abilities = module['abilities']! as List<Object?>;
        final entryAbility = abilities.single! as Map<String, Object?>;
        final skills = entryAbility['skills']! as List<Object?>;
        final schemes = <String>[];
        for (final skill in skills) {
          final uris =
              (skill! as Map<String, Object?>)['uris'] as List<Object?>?;
          if (uris == null) continue;
          for (final uri in uris) {
            final scheme = (uri! as Map<String, Object?>)['scheme'] as String?;
            if (scheme != null) schemes.add(scheme);
          }
        }
        expect(schemes, const <String>['tallyisle']);

        final permissions = (module['requestPermissions']! as List<Object?>)
            .map((e) => (e! as Map<String, Object?>)['name'] as String)
            .toSet();
        expect(
          permissions,
          containsAll(const <String>[
            'ohos.permission.INTERNET',
            'ohos.permission.ACCESS_BIOMETRIC',
          ]),
        );
      },
    );

    test(
      'bilingual AppScope and entry string.json cover base, en_US, zh_CN, zh_TW, zh_HK',
      () {
        String readStringEntry(String path, String key) {
          final raw =
              jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;
          final entries = raw['string']! as List<Object?>;
          for (final item in entries) {
            final map = item! as Map<String, Object?>;
            if (map['name'] == key) {
              return map['value']! as String;
            }
          }
          fail('Missing key "$key" in $path');
        }

        const expectedLabels = <String, String>{
          'base': 'TallyIsle',
          'en_US': 'TallyIsle',
          'zh_CN': '帐屿',
          'zh_TW': '帐屿',
          'zh_HK': '帐屿',
        };
        for (final entry in expectedLabels.entries) {
          final qualifier = entry.key;
          final expectedLabel = entry.value;
          expect(
            readStringEntry(
              'ohos/AppScope/resources/$qualifier/element/string.json',
              'app_name',
            ),
            expectedLabel,
          );
          expect(
            readStringEntry(
              'ohos/entry/src/main/resources/$qualifier/element/string.json',
              'EntryAbility_label',
            ),
            expectedLabel,
          );
        }
      },
    );

    test(
      'AutomationBridge.ets, BiometricBridge.ets, and file_selector_ohos enforce scheme, bilingual fallback, and third-party import extensions',
      () {
        final automationEts = File(
          'ohos/entry/src/main/ets/plugins/AutomationBridge.ets',
        ).readAsStringSync();
        expect(automationEts, contains("tallyisle://"));
        expect(automationEts.toLowerCase(), isNot(contains('yyjz')));

        final biometricEts = File(
          'ohos/entry/src/main/ets/plugins/BiometricBridge.ets',
        ).readAsStringSync();
        expect(biometricEts, contains('i18n.System.getSystemLanguage()'));
        expect(biometricEts, contains('验证身份以解锁帐屿'));
        expect(biometricEts, contains('Verify identity to unlock TallyIsle'));
        expect(biometricEts, contains('使用数字密码'));
        expect(biometricEts, contains('Use PIN'));

        final fileSelectorUtilEts = File(
          'third_party/ohos_packages/file_selector_ohos/ohos/src/main/ets/file_selector/FileSelectorUtil.ets',
        ).readAsStringSync();
        for (final expectedExt in const <String>[
          'csv',
          'tsv',
          'xlsx',
          'xls',
          'json',
          'zip',
          'db',
          'sqlite',
          'sqlite3',
        ]) {
          expect(fileSelectorUtilEts, contains("'$expectedExt'"));
        }
        expect(fileSelectorUtilEts, contains('MAX_FILE_SUFFIX_FILTERS'));

        final fileSelectorApiEts = File(
          'third_party/ohos_packages/file_selector_ohos/ohos/src/main/ets/file_selector/FileSelectorApiImpl.ets',
        ).readAsStringSync();
        expect(fileSelectorApiEts, contains('decodeURIComponent'));
        expect(fileSelectorApiEts, contains('file_selector-XXXXXX'));
      },
    );
  });
}
