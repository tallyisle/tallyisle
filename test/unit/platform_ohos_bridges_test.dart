import 'dart:async';

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
          (await auth.authenticate()).outcome,
          BiometricAuthOutcome.cancelled,
        );

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
  });

  group('HarmonyOS AutoBillBridge & AppWidgetBridge (dev.tallyisle/automation)', () {
    test(
      'handles tallyisle:// & yyjz:// deep links while honestly reporting AccessibilityService & desktop widgets as unsupported (ADR-008)',
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

        // Cold-start deep link consumption
        expect(
          await bridge.consumePendingDeepLink(),
          'tallyisle://add?type=0&money=28.50&remark=早餐',
        );
        expect(await bridge.consumePendingDeepLink(), isNull);

        // Before listener attaches, native onDeepLink receives false so native keeps pendingDeepLinkUri
        final unhandledReply = await _sendNativeToFlutterCall(
          automationChannelName,
          const MethodCall('onDeepLink', 'yyjz://add?money=15'),
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
          const MethodCall('onDeepLink', 'yyjz://add?money=15'),
        );
        expect(
          const StandardMethodCodec().decodeEnvelope(handledReply!),
          isTrue,
        );
        await Future<void>.delayed(Duration.zero);
        expect(receivedLinks, const <String>['yyjz://add?money=15']);

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
}
