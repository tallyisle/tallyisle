import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/failure.dart';
import 'app_widgets.dart' show automationChannelName;
import 'files.dart';

const String accessibilityEnabledLabel = '已开启';
const String accessibilityDisabledLabel = '未开启';
const String accessibilityUnsupportedLabel = '当前平台不支持';

/// Honest Android `AccessibilityService` status snapshot (`ADR-008`, `F-020`).
final class AccessibilityBridgeStatus {
  const AccessibilityBridgeStatus({
    required this.supported,
    required this.enabled,
    required this.statusLabel,
  });

  const AccessibilityBridgeStatus.android({required bool enabled})
    : supported = true,
      enabled = enabled,
      statusLabel = enabled
          ? accessibilityEnabledLabel
          : accessibilityDisabledLabel;

  const AccessibilityBridgeStatus.unsupported()
    : supported = false,
      enabled = false,
      statusLabel = accessibilityUnsupportedLabel;

  factory AccessibilityBridgeStatus.fromMap(Map<Object?, Object?> map) {
    final supported = map['supported'] == true;
    if (!supported) {
      return const AccessibilityBridgeStatus.unsupported();
    }
    final enabled = map['enabled'] == true;
    final rawLabel = (map['statusLabel'] as String?)?.trim();
    return AccessibilityBridgeStatus(
      supported: true,
      enabled: enabled,
      statusLabel: rawLabel != null && rawLabel.isNotEmpty
          ? rawLabel
          : (enabled ? accessibilityEnabledLabel : accessibilityDisabledLabel),
    );
  }

  final bool supported;
  final bool enabled;

  /// Guaranteed to be one of `'已开启'`, `'未开启'`, or `'当前平台不支持'`.
  final String statusLabel;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AccessibilityBridgeStatus &&
          supported == other.supported &&
          enabled == other.enabled &&
          statusLabel == other.statusLabel;

  @override
  int get hashCode => Object.hash(supported, enabled, statusLabel);
}

/// Raw payment notification/window text captured by `AutoBillAccessibilityService` (`F-020`).
final class CapturedPaymentEvent {
  const CapturedPaymentEvent({
    required this.packageName,
    required this.rawText,
    required this.capturedAtMs,
  });

  factory CapturedPaymentEvent.fromMap(Map<Object?, Object?> map) =>
      CapturedPaymentEvent(
        packageName: (map['packageName'] as String?)?.trim() ?? '',
        rawText: (map['rawText'] as String?)?.trim() ?? '',
        capturedAtMs: (map['capturedAtMs'] as num?)?.toInt() ?? 0,
      );

  final String packageName;
  final String rawText;
  final int capturedAtMs;

  Map<String, Object> toMap() => {
    'packageName': packageName,
    'rawText': rawText,
    'capturedAtMs': capturedAtMs,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CapturedPaymentEvent &&
          packageName == other.packageName &&
          rawText == other.rawText &&
          capturedAtMs == other.capturedAtMs;

  @override
  int get hashCode => Object.hash(packageName, rawText, capturedAtMs);
}

/// Platform boundary for external URL Scheme deep links (`F-033`) and Android
/// `AutoBillAccessibilityService` status/events (`F-020`, `ADR-008`).
abstract interface class AutoBillBridge {
  Capability get capability;

  /// Returns honest permission status (`已开启` / `未开启` / `当前平台不支持`).
  Future<AccessibilityBridgeStatus> getAccessibilityStatus();

  /// Opens Android `Settings.ACTION_ACCESSIBILITY_SETTINGS`.
  Future<bool> openAccessibilitySettings();

  /// Consumes and clears any pending cold-start `tallyisle://` or `yyjz://` URI.
  Future<String?> consumePendingDeepLink();

  /// Emits incoming `tallyisle://` or `yyjz://` URIs received while the app is running.
  Stream<String> get onDeepLink;

  /// Consumes and clears persisted background accessibility payment events.
  Future<List<CapturedPaymentEvent>> consumeCapturedEvents();

  /// Emits payment events captured while the Flutter engine is attached.
  Stream<CapturedPaymentEvent> get onCapturedEvent;

  Future<void> dispose();
}

/// Creates the platform-appropriate [AutoBillBridge].
AutoBillBridge createAutoBillBridge() {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    return MethodChannelAutoBillBridge();
  }
  return InMemoryAutoBillBridge(
    capability: const Capability(
      CapabilityState.unsupported,
      '当前平台不支持系统无障碍自动抓取，可使用粘贴支付文本或草稿箱手动入账',
    ),
    status: const AccessibilityBridgeStatus.unsupported(),
  );
}

/// Android native implementation bridged via `MethodChannel('dev.tallyisle/automation')`.
final class MethodChannelAutoBillBridge implements AutoBillBridge {
  MethodChannelAutoBillBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(automationChannelName) {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  final MethodChannel _channel;
  final InMemoryAutoBillBridge _fallback = InMemoryAutoBillBridge(
    status: const AccessibilityBridgeStatus.android(enabled: false),
  );
  final StreamController<String> _deepLinkController =
      StreamController<String>.broadcast();
  final StreamController<CapturedPaymentEvent> _eventController =
      StreamController<CapturedPaymentEvent>.broadcast();

  @override
  Capability get capability =>
      const Capability(CapabilityState.available, 'Android 原生自动记账与外部链接桥接已接入');

  @override
  Stream<String> get onDeepLink => _deepLinkController.stream;

  @override
  Stream<CapturedPaymentEvent> get onCapturedEvent => _eventController.stream;

  Future<Object?> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onDeepLink':
        final uri = (call.arguments as String?)?.trim();
        if (uri != null &&
            uri.isNotEmpty &&
            !_deepLinkController.isClosed &&
            _deepLinkController.hasListener) {
          _deepLinkController.add(uri);
          return true;
        }
        return false;
      case 'onCapturedEvent':
        final args = call.arguments;
        if (args is Map &&
            !_eventController.isClosed &&
            _eventController.hasListener) {
          final event = CapturedPaymentEvent.fromMap(args);
          if (event.rawText.isNotEmpty) {
            _eventController.add(event);
            return true;
          }
        }
        return false;
      default:
        return null;
    }
  }

  @override
  Future<AccessibilityBridgeStatus> getAccessibilityStatus() async {
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(
        'getAccessibilityStatus',
      );
      if (raw == null) {
        return const AccessibilityBridgeStatus.android(enabled: false);
      }
      return AccessibilityBridgeStatus.fromMap(raw);
    } on MissingPluginException {
      return _fallback.getAccessibilityStatus();
    } on PlatformException {
      return const AccessibilityBridgeStatus.android(enabled: false);
    }
  }

  @override
  Future<bool> openAccessibilitySettings() async {
    try {
      return (await _channel.invokeMethod<bool>('openAccessibilitySettings')) ??
          false;
    } on MissingPluginException {
      return _fallback.openAccessibilitySettings();
    } on PlatformException catch (e) {
      throw Failure(
        FailureCode.unsupportedCapability,
        e.message ?? '无法打开系统无障碍设置页面',
      );
    }
  }

  @override
  Future<String?> consumePendingDeepLink() async {
    try {
      final uri = await _channel.invokeMethod<String>('consumePendingDeepLink');
      final trimmed = uri?.trim();
      return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    } on MissingPluginException {
      return _fallback.consumePendingDeepLink();
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<List<CapturedPaymentEvent>> consumeCapturedEvents() async {
    try {
      final rawList = await _channel.invokeListMethod<Object?>(
        'consumeCapturedEvents',
      );
      if (rawList == null) return const [];
      return [
        for (final item in rawList)
          if (item is Map)
            CapturedPaymentEvent.fromMap(item)
          else if (item is CapturedPaymentEvent)
            item,
      ].where((e) => e.rawText.isNotEmpty).toList(growable: false);
    } on MissingPluginException {
      return _fallback.consumeCapturedEvents();
    } on PlatformException {
      return const [];
    }
  }

  @override
  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    await _fallback.dispose();
    await _deepLinkController.close();
    await _eventController.close();
  }
}

/// Deterministic in-memory [AutoBillBridge] for non-Android hosts and automated tests.
final class InMemoryAutoBillBridge implements AutoBillBridge {
  InMemoryAutoBillBridge({
    this.capability = const Capability(CapabilityState.available, '内存自动记账桥接器'),
    this.status = const AccessibilityBridgeStatus.unsupported(),
    String? initialPendingDeepLink,
    List<CapturedPaymentEvent>? initialCapturedEvents,
  }) : _pendingDeepLink = initialPendingDeepLink,
       _queuedEvents = [...?initialCapturedEvents];

  @override
  Capability capability;

  AccessibilityBridgeStatus status;
  String? _pendingDeepLink;
  final List<CapturedPaymentEvent> _queuedEvents;
  int openSettingsCount = 0;

  final StreamController<String> _deepLinkController =
      StreamController<String>.broadcast();
  final StreamController<CapturedPaymentEvent> _eventController =
      StreamController<CapturedPaymentEvent>.broadcast();

  @override
  Stream<String> get onDeepLink => _deepLinkController.stream;

  @override
  Stream<CapturedPaymentEvent> get onCapturedEvent => _eventController.stream;

  @override
  Future<AccessibilityBridgeStatus> getAccessibilityStatus() async => status;

  @override
  Future<bool> openAccessibilitySettings() async {
    if (!status.supported) return false;
    openSettingsCount++;
    return true;
  }

  @override
  Future<String?> consumePendingDeepLink() async {
    final uri = _pendingDeepLink;
    _pendingDeepLink = null;
    return uri;
  }

  @override
  Future<List<CapturedPaymentEvent>> consumeCapturedEvents() async {
    final copy = List<CapturedPaymentEvent>.unmodifiable(_queuedEvents);
    _queuedEvents.clear();
    return copy;
  }

  /// Simulates an incoming `tallyisle://` or `yyjz://` URI.
  void simulateDeepLink(String uri) {
    if (!_deepLinkController.isClosed && _deepLinkController.hasListener) {
      _deepLinkController.add(uri);
    } else {
      _pendingDeepLink = uri;
    }
  }

  /// Simulates an accessibility payment event arriving in foreground or background.
  void simulateCapturedEvent(CapturedPaymentEvent event) {
    if (!_eventController.isClosed && _eventController.hasListener) {
      _eventController.add(event);
    } else {
      _queuedEvents.add(event);
    }
  }

  @override
  Future<void> dispose() async {
    await _deepLinkController.close();
    await _eventController.close();
  }
}
