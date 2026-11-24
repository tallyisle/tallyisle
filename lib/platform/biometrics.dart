import 'dart:ui' show Locale, PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'files.dart';

bool _isChineseLocale([Locale? locale]) {
  final effective = locale ?? PlatformDispatcher.instance.locale;
  return effective.languageCode.toLowerCase() == 'zh';
}

/// Locale-aware default biometric prompt title (`BRAND-001`).
String defaultBiometricPromptTitle([Locale? locale]) => _isChineseLocale(locale)
    ? '验证身份以解锁帐屿'
    : 'Verify identity to unlock TallyIsle';

/// Locale-aware default biometric prompt subtitle (`BRAND-001`).
String defaultBiometricPromptSubtitle([Locale? locale]) =>
    _isChineseLocale(locale)
    ? '请验证指纹或面容，或使用数字密码解锁'
    : 'Verify with fingerprint or face, or unlock with PIN';

/// Locale-aware default biometric negative button text (`BRAND-001`).
String defaultBiometricNegativeButtonText([Locale? locale]) =>
    _isChineseLocale(locale) ? '使用数字密码' : 'Use PIN';

/// Locale-aware default unsupported-platform biometric reason (`BRAND-001`).
String defaultBiometricUnsupportedReason([Locale? locale]) =>
    _isChineseLocale(locale)
    ? '当前平台暂不支持系统生物识别，请使用数字密码解锁'
    : 'Biometric authentication is not supported on this platform; please unlock with PIN';

/// Availability status of OS biometric authentication (`F-024`, `ADR-008`).
enum BiometricAvailabilityStatus {
  available,
  notEnrolled,
  noHardware,
  temporarilyUnavailable,
  unsupportedPlatform,
}

/// Snapshot of system biometric capability returned by [BiometricAuthenticator].
final class BiometricAvailability {
  const BiometricAvailability({
    required this.status,
    required this.reason,
    this.deviceSecure = false,
  });

  final BiometricAvailabilityStatus status;
  final String reason;
  final bool deviceSecure;

  bool get canAuthenticate => status == BiometricAvailabilityStatus.available;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BiometricAvailability &&
          status == other.status &&
          reason == other.reason &&
          deviceSecure == other.deviceSecure;

  @override
  int get hashCode => Object.hash(status, reason, deviceSecure);
}

/// Outcome of a single OS biometric prompt invocation.
enum BiometricAuthOutcome {
  authenticated,
  cancelled,
  lockout,
  unavailable,
  unsupportedPlatform,
  failed,
}

/// Structured result of [BiometricAuthenticator.authenticate].
final class BiometricAuthResult {
  const BiometricAuthResult({required this.outcome, required this.message});

  final BiometricAuthOutcome outcome;
  final String message;

  bool get isAuthenticated => outcome == BiometricAuthOutcome.authenticated;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BiometricAuthResult &&
          outcome == other.outcome &&
          message == other.message;

  @override
  int get hashCode => Object.hash(outcome, message);
}

const String biometricChannelName = 'dev.tallyisle/biometrics';

/// Platform boundary for OS biometric authentication (`ADR-008`, `F-024`).
///
/// Android native delegates to `BiometricBridge.kt` (`android.hardware.biometrics.BiometricPrompt`),
/// and HarmonyOS native delegates to `BiometricBridge.ets` (`@ohos.userIAM.userAuth`).
/// Other hosts (Linux, Web, desktop) degrade cleanly to `unsupportedPlatform`
/// so PIN unlock always works without throwing plugin errors.
abstract interface class BiometricAuthenticator {
  Capability get capability;

  Future<BiometricAvailability> checkAvailability();

  Future<BiometricAuthResult> authenticate({
    String? title,
    String? subtitle,
    String? negativeButtonText,
  });

  Future<void> cancelAuthentication();
}

/// Creates the platform-appropriate [BiometricAuthenticator].
BiometricAuthenticator createBiometricAuthenticator({bool? isOhosOverride}) {
  if (!kIsWeb) {
    final isOhos = isOhosOverride ?? (defaultTargetPlatform.name == 'ohos');
    if (defaultTargetPlatform == TargetPlatform.android || isOhos) {
      return MethodChannelBiometricAuthenticator(
        isOhosOverride: isOhosOverride,
      );
    }
  }
  return const UnsupportedBiometricAuthenticator();
}

/// Explicit fallback for Linux, Web, and non-Android hosts (`ADR-008`).
final class UnsupportedBiometricAuthenticator
    implements BiometricAuthenticator {
  const UnsupportedBiometricAuthenticator({String? reason}) : _reason = reason;

  final String? _reason;

  String get reason => _reason ?? defaultBiometricUnsupportedReason();

  @override
  Capability get capability => Capability(CapabilityState.unsupported, reason);

  @override
  Future<BiometricAvailability> checkAvailability() async =>
      BiometricAvailability(
        status: BiometricAvailabilityStatus.unsupportedPlatform,
        reason: reason,
        deviceSecure: false,
      );

  @override
  Future<BiometricAuthResult> authenticate({
    String? title,
    String? subtitle,
    String? negativeButtonText,
  }) async => BiometricAuthResult(
    outcome: BiometricAuthOutcome.unsupportedPlatform,
    message: reason,
  );

  @override
  Future<void> cancelAuthentication() async {}
}

/// Native implementation backed by `MethodChannel('dev.tallyisle/biometrics')`
/// on Android (`BiometricPrompt`) and HarmonyOS (`@ohos.userIAM.userAuth`).
final class MethodChannelBiometricAuthenticator
    implements BiometricAuthenticator {
  MethodChannelBiometricAuthenticator({
    MethodChannel? channel,
    bool? isOhosOverride,
  }) : _channel = channel ?? const MethodChannel(biometricChannelName),
       _isOhosOverride = isOhosOverride;

  final MethodChannel _channel;
  final bool? _isOhosOverride;

  bool get _isOhos =>
      !kIsWeb && (_isOhosOverride ?? (defaultTargetPlatform.name == 'ohos'));

  @override
  Capability get capability => Capability(
    CapabilityState.available,
    _isOhos
        ? 'HarmonyOS 原生生物识别通道（UserAuth）已接入'
        : 'Android 原生生物识别通道（BiometricPrompt）已接入',
  );

  @override
  Future<BiometricAvailability> checkAvailability() async {
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>(
        'checkAvailability',
      );
      if (raw == null) {
        return const BiometricAvailability(
          status: BiometricAvailabilityStatus.unsupportedPlatform,
          reason: '未获取到系统生物识别状态，请使用数字密码解锁',
        );
      }
      final statusCode = (raw['status'] as String?) ?? 'unsupported';
      final reason = (raw['reason'] as String?) ?? '请使用数字密码解锁';
      final deviceSecure = (raw['deviceSecure'] as bool?) ?? false;
      return BiometricAvailability(
        status: _parseAvailabilityStatus(statusCode),
        reason: reason,
        deviceSecure: deviceSecure,
      );
    } on MissingPluginException {
      return const BiometricAvailability(
        status: BiometricAvailabilityStatus.unsupportedPlatform,
        reason: '当前运行环境未挂载原生生物识别通道，请使用数字密码解锁',
      );
    } on PlatformException catch (e) {
      return BiometricAvailability(
        status: BiometricAvailabilityStatus.temporarilyUnavailable,
        reason: e.message ?? '生物识别服务暂不可用，请使用数字密码解锁',
      );
    }
  }

  @override
  Future<BiometricAuthResult> authenticate({
    String? title,
    String? subtitle,
    String? negativeButtonText,
  }) async {
    final effectiveTitle = (title != null && title.trim().isNotEmpty)
        ? title
        : defaultBiometricPromptTitle();
    final effectiveSubtitle = (subtitle != null && subtitle.trim().isNotEmpty)
        ? subtitle
        : defaultBiometricPromptSubtitle();
    final effectiveNegative =
        (negativeButtonText != null && negativeButtonText.trim().isNotEmpty)
        ? negativeButtonText
        : defaultBiometricNegativeButtonText();
    try {
      final raw = await _channel
          .invokeMapMethod<String, Object?>('authenticate', <String, Object>{
            'title': effectiveTitle,
            'subtitle': effectiveSubtitle,
            'negativeButtonText': effectiveNegative,
          });
      if (raw == null) {
        return const BiometricAuthResult(
          outcome: BiometricAuthOutcome.failed,
          message: '生物识别未返回结果，请使用数字密码解锁',
        );
      }
      final outcomeCode = (raw['outcome'] as String?) ?? 'failed';
      final message = (raw['message'] as String?) ?? '生物识别未通过，请使用数字密码解锁';
      return BiometricAuthResult(
        outcome: _parseAuthOutcome(outcomeCode),
        message: message,
      );
    } on MissingPluginException {
      return const BiometricAuthResult(
        outcome: BiometricAuthOutcome.unsupportedPlatform,
        message: '当前运行环境不支持系统生物识别，请使用数字密码解锁',
      );
    } on PlatformException catch (e) {
      return BiometricAuthResult(
        outcome: BiometricAuthOutcome.unavailable,
        message: e.message ?? '无法调起系统生物识别，请使用数字密码解锁',
      );
    }
  }

  @override
  Future<void> cancelAuthentication() async {
    try {
      await _channel.invokeMethod<void>('cancelAuthentication');
    } on MissingPluginException {
      // No-op in headless environments.
    } on PlatformException {
      // Ignore cancellation errors when prompt has already closed.
    }
  }

  static BiometricAvailabilityStatus _parseAvailabilityStatus(String code) =>
      switch (code) {
        'available' => BiometricAvailabilityStatus.available,
        'notEnrolled' => BiometricAvailabilityStatus.notEnrolled,
        'noHardware' => BiometricAvailabilityStatus.noHardware,
        'temporarilyUnavailable' =>
          BiometricAvailabilityStatus.temporarilyUnavailable,
        _ => BiometricAvailabilityStatus.unsupportedPlatform,
      };

  static BiometricAuthOutcome _parseAuthOutcome(String code) => switch (code) {
    'authenticated' => BiometricAuthOutcome.authenticated,
    'cancelled' => BiometricAuthOutcome.cancelled,
    'lockout' => BiometricAuthOutcome.lockout,
    'unavailable' => BiometricAuthOutcome.unavailable,
    'unsupported' => BiometricAuthOutcome.unsupportedPlatform,
    _ => BiometricAuthOutcome.failed,
  };
}

/// Deterministic in-memory authenticator for automated tests.
final class InMemoryBiometricAuthenticator implements BiometricAuthenticator {
  InMemoryBiometricAuthenticator({
    this.availability = const BiometricAvailability(
      status: BiometricAvailabilityStatus.available,
      reason: '测试模拟生物识别可用',
      deviceSecure: true,
    ),
    this.nextResult = const BiometricAuthResult(
      outcome: BiometricAuthOutcome.authenticated,
      message: '验证通过',
    ),
  });

  BiometricAvailability availability;
  BiometricAuthResult nextResult;
  int checkCount = 0;
  int authenticateCount = 0;
  int cancelCount = 0;

  @override
  Capability get capability => availability.canAuthenticate
      ? Capability(CapabilityState.available, availability.reason)
      : Capability(CapabilityState.unsupported, availability.reason);

  @override
  Future<BiometricAvailability> checkAvailability() async {
    checkCount++;
    return availability;
  }

  @override
  Future<BiometricAuthResult> authenticate({
    String? title,
    String? subtitle,
    String? negativeButtonText,
  }) async {
    authenticateCount++;
    if (!availability.canAuthenticate) {
      return BiometricAuthResult(
        outcome:
            availability.status ==
                BiometricAvailabilityStatus.unsupportedPlatform
            ? BiometricAuthOutcome.unsupportedPlatform
            : BiometricAuthOutcome.unavailable,
        message: availability.reason,
      );
    }
    return nextResult;
  }

  @override
  Future<void> cancelAuthentication() async {
    cancelCount++;
  }
}
