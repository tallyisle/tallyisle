import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/failure.dart';
import 'app_widgets.dart' show automationChannelName;
import 'files.dart';

const String accessibilityEnabledLabel = '已开启';
const String accessibilityDisabledLabel = '未开启';
const String accessibilityUnsupportedLabel = '当前平台不支持';

/// Notification-listener labels (`已开启` / `未开启` / `当前平台不支持`).
const String notificationListenerEnabledLabel = '已开启';
const String notificationListenerDisabledLabel = '未开启';

/// Overlay permission labels (`已授权` / `未授权` / `当前平台不支持`).
const String overlayGrantedLabel = '已授权';
const String overlayDeniedLabel = '未授权';

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

/// Generic honest native permission status used by the Android notification
/// listener (`已开启`/`未开启`) and overlay permission (`已授权`/`未授权`).
final class AutoBillPermissionStatus {
  const AutoBillPermissionStatus({
    required this.supported,
    required this.enabled,
    required this.statusLabel,
  });

  const AutoBillPermissionStatus.notificationListener({required bool enabled})
    : supported = true,
      enabled = enabled,
      statusLabel = enabled
          ? notificationListenerEnabledLabel
          : notificationListenerDisabledLabel;

  const AutoBillPermissionStatus.overlay({required bool granted})
    : supported = true,
      enabled = granted,
      statusLabel = granted ? overlayGrantedLabel : overlayDeniedLabel;

  const AutoBillPermissionStatus.unsupported()
    : supported = false,
      enabled = false,
      statusLabel = accessibilityUnsupportedLabel;

  factory AutoBillPermissionStatus.fromMap(
    Map<Object?, Object?> map, {
    required String enabledLabel,
    required String disabledLabel,
  }) {
    if (map['supported'] != true) {
      return const AutoBillPermissionStatus.unsupported();
    }
    final enabled = map['enabled'] == true;
    final rawLabel = (map['statusLabel'] as String?)?.trim();
    return AutoBillPermissionStatus(
      supported: true,
      enabled: enabled,
      statusLabel: rawLabel != null && rawLabel.isNotEmpty
          ? rawLabel
          : (enabled ? enabledLabel : disabledLabel),
    );
  }

  final bool supported;
  final bool enabled;
  final String statusLabel;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AutoBillPermissionStatus &&
          supported == other.supported &&
          enabled == other.enabled &&
          statusLabel == other.statusLabel;

  @override
  int get hashCode => Object.hash(supported, enabled, statusLabel);
}

/// Capture channel tags sent by native (`channel` key).
const String captureChannelNotification = 'notification';
const String captureChannelAccessibility = 'accessibility';

/// Raw payment notification/window text captured natively (`F-020`).
final class CapturedPaymentEvent {
  const CapturedPaymentEvent({
    required this.packageName,
    required this.rawText,
    required this.capturedAtMs,
    this.channel,
  });

  factory CapturedPaymentEvent.fromMap(Map<Object?, Object?> map) {
    final channel = (map['channel'] as String?)?.trim();
    return CapturedPaymentEvent(
      packageName: (map['packageName'] as String?)?.trim() ?? '',
      rawText: (map['rawText'] as String?)?.trim() ?? '',
      capturedAtMs: (map['capturedAtMs'] as num?)?.toInt() ?? 0,
      channel: channel == null || channel.isEmpty ? null : channel,
    );
  }

  final String packageName;
  final String rawText;
  final int capturedAtMs;

  /// `'notification'` | `'accessibility'` | `null` (legacy / unknown).
  final String? channel;

  Map<String, Object> toMap() => {
    'packageName': packageName,
    'rawText': rawText,
    'capturedAtMs': capturedAtMs,
    'channel': ?channel,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CapturedPaymentEvent &&
          packageName == other.packageName &&
          rawText == other.rawText &&
          capturedAtMs == other.capturedAtMs &&
          channel == other.channel;

  @override
  int get hashCode => Object.hash(packageName, rawText, capturedAtMs, channel);
}

/// Kind of an externally shared payload (system share / shortcut / card).
enum AutoBillSharedPayloadKind {
  text('text'),
  image('image'),
  shortcut('shortcut');

  const AutoBillSharedPayloadKind(this.wireKey);
  final String wireKey;

  static AutoBillSharedPayloadKind? fromWireKey(Object? raw) {
    final key = raw?.toString().trim().toLowerCase();
    for (final k in AutoBillSharedPayloadKind.values) {
      if (k.wireKey == key) return k;
    }
    return null;
  }
}

/// Launcher shortcut / service-card actions (`shortcutAction`).
abstract final class AutoBillShortcutAction {
  static const newRecord = 'new_record';
  static const smartBill = 'smart_bill';
  static const ocrBill = 'ocr_bill';
  static const drafts = 'drafts';
  static const values = {newRecord, smartBill, ocrBill, drafts};
}

/// Text / images / shortcut action handed to TallyIsle from outside
/// (Android `ACTION_SEND` / `PROCESS_TEXT` / tile, iOS AppIntents / open-in,
/// HarmonyOS share / shortcuts / Form card).
final class AutoBillSharedPayload {
  const AutoBillSharedPayload({
    required this.kind,
    this.text,
    this.imagePaths = const [],
    this.shortcutAction,
    this.source,
    required this.receivedAtMs,
  });

  static AutoBillSharedPayload? fromMap(Map<Object?, Object?> map) {
    final kind = AutoBillSharedPayloadKind.fromWireKey(map['kind']);
    if (kind == null) return null;
    final text = (map['text'] as String?)?.trim();
    final rawPaths = map['imagePaths'];
    final paths = <String>[
      if (rawPaths is List)
        for (final p in rawPaths)
          if (p is String && p.trim().isNotEmpty) p.trim(),
    ];
    final action = (map['shortcutAction'] as String?)?.trim();
    final source = (map['source'] as String?)?.trim();
    final payload = AutoBillSharedPayload(
      kind: kind,
      text: text == null || text.isEmpty ? null : text,
      imagePaths: List.unmodifiable(paths),
      shortcutAction:
          action != null && AutoBillShortcutAction.values.contains(action)
          ? action
          : null,
      source: source == null || source.isEmpty ? null : source,
      receivedAtMs: (map['receivedAtMs'] as num?)?.toInt() ?? 0,
    );
    return payload.isValid ? payload : null;
  }

  final AutoBillSharedPayloadKind kind;
  final String? text;
  final List<String> imagePaths;

  /// `'new_record'` | `'smart_bill'` | `'ocr_bill'` | `'drafts'`.
  final String? shortcutAction;

  /// Free-form origin (`share`, `process_text`, `tile`, `shortcut`, `card`,
  /// `intent` …).
  final String? source;
  final int receivedAtMs;

  bool get isValid => switch (kind) {
    AutoBillSharedPayloadKind.text => text != null && text!.isNotEmpty,
    AutoBillSharedPayloadKind.image => imagePaths.isNotEmpty,
    AutoBillSharedPayloadKind.shortcut => shortcutAction != null,
  };

  Map<String, Object?> toMap() => {
    'kind': kind.wireKey,
    'text': text,
    'imagePaths': imagePaths,
    'shortcutAction': shortcutAction,
    'source': source,
    'receivedAtMs': receivedAtMs,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AutoBillSharedPayload &&
          kind == other.kind &&
          text == other.text &&
          listEquals(imagePaths, other.imagePaths) &&
          shortcutAction == other.shortcutAction &&
          source == other.source &&
          receivedAtMs == other.receivedAtMs;

  @override
  int get hashCode => Object.hash(
    kind,
    text,
    Object.hashAll(imagePaths),
    shortcutAction,
    source,
    receivedAtMs,
  );
}

/// Prompt (notification button / overlay) actions (`action`).
abstract final class AutoBillPromptActionKind {
  static const confirmDraft = 'confirm_draft';
  static const ignoreDraft = 'ignore_draft';
  static const editDraft = 'edit_draft';
  static const undoRecord = 'undo_record';
  static const editRecord = 'edit_record';
  static const values = {
    confirmDraft,
    ignoreDraft,
    editDraft,
    undoRecord,
    editRecord,
  };
}

/// A user tap on an Android prompt notification button or overlay card.
final class AutoBillPromptActionEvent {
  const AutoBillPromptActionEvent({
    required this.action,
    this.draftId,
    this.recordId,
    this.categoryId,
    this.assetId,
    this.remark,
    required this.actionAtMs,
  });

  static AutoBillPromptActionEvent? fromMap(Map<Object?, Object?> map) {
    final action = (map['action'] as String?)?.trim();
    if (action == null || !AutoBillPromptActionKind.values.contains(action)) {
      return null;
    }
    int? optInt(Object? v) {
      final n = v is num ? v.toInt() : int.tryParse('${v ?? ''}'.trim());
      return n == null || n <= 0 ? null : n;
    }

    final recordId = (map['recordId'] as String?)?.trim();
    final remark = (map['remark'] as String?)?.trim();
    final event = AutoBillPromptActionEvent(
      action: action,
      draftId: optInt(map['draftId']),
      recordId: recordId == null || recordId.isEmpty ? null : recordId,
      categoryId: optInt(map['categoryId']),
      assetId: optInt(map['assetId']),
      remark: remark == null || remark.isEmpty ? null : remark,
      actionAtMs: (map['actionAtMs'] as num?)?.toInt() ?? 0,
    );
    return event.isValid ? event : null;
  }

  final String action;
  final int? draftId;
  final String? recordId;
  final int? categoryId;
  final int? assetId;
  final String? remark;
  final int actionAtMs;

  bool get targetsDraft =>
      action == AutoBillPromptActionKind.confirmDraft ||
      action == AutoBillPromptActionKind.ignoreDraft ||
      action == AutoBillPromptActionKind.editDraft;

  bool get isValid => targetsDraft ? draftId != null : recordId != null;

  Map<String, Object?> toMap() => {
    'action': action,
    'draftId': draftId,
    'recordId': recordId,
    'categoryId': categoryId,
    'assetId': assetId,
    'remark': remark,
    'actionAtMs': actionAtMs,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AutoBillPromptActionEvent &&
          action == other.action &&
          draftId == other.draftId &&
          recordId == other.recordId &&
          categoryId == other.categoryId &&
          assetId == other.assetId &&
          remark == other.remark &&
          actionAtMs == other.actionAtMs;

  @override
  int get hashCode => Object.hash(
    action,
    draftId,
    recordId,
    categoryId,
    assetId,
    remark,
    actionAtMs,
  );
}

/// `showAutoBillPrompt` payload (`promptKind`: `draft` | `auto_confirmed`).
final class AutoBillPromptRequest {
  const AutoBillPromptRequest({
    required this.promptKind,
    required this.promptMode,
    this.draftId,
    this.recordId,
    required this.recordType,
    required this.amountFormatted,
    this.currencySymbol = '¥',
    required this.merchant,
    this.categoryId,
    this.categoryName,
    this.assetId,
    this.assetName,
  });

  static const String kindDraft = 'draft';
  static const String kindAutoConfirmed = 'auto_confirmed';

  final String promptKind;

  /// `'notification'` | `'overlay'` | `'silent'`.
  final String promptMode;
  final int? draftId;
  final String? recordId;
  final int recordType;

  /// Exact decimal text from `Money.decimal` (zero `double`).
  final String amountFormatted;
  final String currencySymbol;
  final String merchant;
  final int? categoryId;
  final String? categoryName;
  final int? assetId;
  final String? assetName;

  Map<String, Object?> toMap() => {
    'promptKind': promptKind,
    'promptMode': promptMode,
    'draftId': draftId,
    'recordId': recordId,
    'recordType': recordType,
    'amountFormatted': amountFormatted,
    'currencySymbol': currencySymbol,
    'merchant': merchant,
    'categoryId': categoryId,
    'categoryName': categoryName,
    'assetId': assetId,
    'assetName': assetName,
  };
}

/// `syncAndroidAutoBillConfig` payload.
///
/// `categories`: `[{id:int, name:String, type:int, parentId:int}]`,
/// `assets`: `[{id:int, name:String}]`.
final class AutoBillNativeConfig {
  const AutoBillNativeConfig({
    required this.enableNotificationCapture,
    required this.enableAccessibilityCapture,
    required this.promptMode,
    this.categories = const [],
    this.assets = const [],
  });

  final bool enableNotificationCapture;
  final bool enableAccessibilityCapture;
  final String promptMode;
  final List<Map<String, Object>> categories;
  final List<Map<String, Object>> assets;

  Map<String, Object?> toMap() => {
    'enableNotificationCapture': enableNotificationCapture,
    'enableAccessibilityCapture': enableAccessibilityCapture,
    'promptMode': promptMode,
    'categories': categories,
    'assets': assets,
  };
}

/// Result of `recognizeImageOffline` (`{supported: bool, text: String}`).
final class OfflineOcrResult {
  const OfflineOcrResult({required this.supported, this.text = ''});

  const OfflineOcrResult.unsupported() : supported = false, text = '';

  factory OfflineOcrResult.fromMap(Map<Object?, Object?>? map) {
    if (map == null || map['supported'] != true) {
      return const OfflineOcrResult.unsupported();
    }
    return OfflineOcrResult(
      supported: true,
      text: (map['text'] as String?)?.trim() ?? '',
    );
  }

  final bool supported;
  final String text;
}

/// Platform boundary for external deep links (`F-033`), Android capture
/// services (`F-020`), shares/shortcuts, prompt actions and offline OCR.
abstract interface class AutoBillBridge {
  Capability get capability;

  /// Returns honest permission status (`已开启` / `未开启` / `当前平台不支持`).
  Future<AccessibilityBridgeStatus> getAccessibilityStatus();

  /// Opens Android `Settings.ACTION_ACCESSIBILITY_SETTINGS`.
  Future<bool> openAccessibilitySettings();

  /// Android notification-listener access (`已开启` / `未开启` / `当前平台不支持`).
  Future<AutoBillPermissionStatus> getNotificationListenerStatus();

  Future<bool> openNotificationListenerSettings();

  /// Android overlay permission (`已授权` / `未授权` / `当前平台不支持`).
  Future<AutoBillPermissionStatus> getOverlayPermissionStatus();

  Future<bool> openOverlaySettings();

  /// Pushes capture switches, prompt mode and category/asset pick lists to
  /// native (overlay card quick chips).
  Future<bool> syncAndroidAutoBillConfig(AutoBillNativeConfig config);

  /// Shows a native draft / auto-confirmed prompt (notification or overlay).
  Future<bool> showAutoBillPrompt(AutoBillPromptRequest request);

  /// Consumes and clears any pending cold-start `tallyisle://` URI.
  Future<String?> consumePendingDeepLink();

  /// Emits incoming `tallyisle://` URIs received while the app is running.
  Stream<String> get onDeepLink;

  /// Consumes and clears persisted background payment events.
  Future<List<CapturedPaymentEvent>> consumeCapturedEvents();

  /// Emits payment events captured while the Flutter engine is attached.
  Stream<CapturedPaymentEvent> get onCapturedEvent;

  /// Consumes queued shares / shortcut / card launches.
  Future<List<AutoBillSharedPayload>> consumePendingSharedPayloads();

  Stream<AutoBillSharedPayload> get onSharedPayload;

  /// Consumes queued prompt actions tapped while Flutter was detached.
  Future<List<AutoBillPromptActionEvent>> consumePendingPromptActions();

  Stream<AutoBillPromptActionEvent> get onPromptAction;

  /// Offline on-device OCR (Android ML Kit Chinese / iOS Vision / HarmonyOS
  /// CoreVisionKit). Returns `supported: false` where unavailable.
  Future<OfflineOcrResult> recognizeImageOffline(
    Uint8List bytes, {
    String? fileName,
  });

  Future<void> dispose();
}

bool _isOhosPlatform(bool? override) =>
    !kIsWeb && (override ?? (defaultTargetPlatform.name == 'ohos'));

/// Creates the platform-appropriate [AutoBillBridge]: native channel on
/// Android, iOS and HarmonyOS; honest in-memory fallback elsewhere.
AutoBillBridge createAutoBillBridge({bool? isOhosOverride}) {
  if (!kIsWeb) {
    final isOhos = _isOhosPlatform(isOhosOverride);
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        isOhos) {
      return MethodChannelAutoBillBridge(isOhosOverride: isOhosOverride);
    }
  }
  return InMemoryAutoBillBridge(
    capability: const Capability(
      CapabilityState.unsupported,
      '当前平台不支持系统无障碍自动抓取，可使用粘贴支付文本或草稿箱手动入账',
    ),
    status: const AccessibilityBridgeStatus.unsupported(),
  );
}

/// Native implementation bridged via `MethodChannel('com.tallyisle/automation')`
/// on Android, iOS and HarmonyOS.
final class MethodChannelAutoBillBridge implements AutoBillBridge {
  MethodChannelAutoBillBridge({MethodChannel? channel, bool? isOhosOverride})
    : _channel = channel ?? const MethodChannel(automationChannelName),
      _isOhosOverride = isOhosOverride {
    _fallback = InMemoryAutoBillBridge(
      status: _defaultStatus,
      notificationListenerStatus: _defaultPermission,
      overlayStatus: _defaultPermission,
    );
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  final MethodChannel _channel;
  final bool? _isOhosOverride;
  late final InMemoryAutoBillBridge _fallback;
  final StreamController<String> _deepLinkController =
      StreamController<String>.broadcast();
  final StreamController<CapturedPaymentEvent> _eventController =
      StreamController<CapturedPaymentEvent>.broadcast();
  final StreamController<AutoBillSharedPayload> _sharedController =
      StreamController<AutoBillSharedPayload>.broadcast();
  final StreamController<AutoBillPromptActionEvent> _promptController =
      StreamController<AutoBillPromptActionEvent>.broadcast();

  bool get _isOhos => _isOhosPlatform(_isOhosOverride);

  bool get _isIos =>
      !kIsWeb && !_isOhos && defaultTargetPlatform == TargetPlatform.iOS;

  /// Android-only capture services; iOS & HarmonyOS are honestly unsupported.
  bool get _androidCapture => !_isOhos && !_isIos;

  AccessibilityBridgeStatus get _defaultStatus => _androidCapture
      ? const AccessibilityBridgeStatus.android(enabled: false)
      : const AccessibilityBridgeStatus.unsupported();

  AutoBillPermissionStatus get _defaultPermission => _androidCapture
      ? const AutoBillPermissionStatus(
          supported: true,
          enabled: false,
          statusLabel: notificationListenerDisabledLabel,
        )
      : const AutoBillPermissionStatus.unsupported();

  @override
  Capability get capability => Capability(
    CapabilityState.available,
    _isOhos
        ? 'HarmonyOS 外部链接（tallyisle://）、系统分享与本机离线识图桥接已接入'
        : _isIos
        ? 'iOS 外部链接（tallyisle://）、快捷指令与本机离线识图桥接已接入'
        : 'Android 原生自动记账与外部链接桥接已接入',
  );

  @override
  Stream<String> get onDeepLink => _deepLinkController.stream;

  @override
  Stream<CapturedPaymentEvent> get onCapturedEvent => _eventController.stream;

  @override
  Stream<AutoBillSharedPayload> get onSharedPayload => _sharedController.stream;

  @override
  Stream<AutoBillPromptActionEvent> get onPromptAction =>
      _promptController.stream;

  bool _emit<T>(StreamController<T> controller, T? value) {
    if (value == null || controller.isClosed || !controller.hasListener) {
      return false;
    }
    controller.add(value);
    return true;
  }

  Future<Object?> _handleNativeCall(MethodCall call) async {
    final args = call.arguments;
    switch (call.method) {
      case 'onDeepLink':
        final uri = (args as String?)?.trim();
        return _emit(
          _deepLinkController,
          uri == null || uri.isEmpty ? null : uri,
        );
      case 'onCapturedEvent':
        if (args is! Map) return false;
        final event = CapturedPaymentEvent.fromMap(args);
        return _emit(_eventController, event.rawText.isEmpty ? null : event);
      case 'onSharedPayload':
        if (args is! Map) return false;
        return _emit(_sharedController, AutoBillSharedPayload.fromMap(args));
      case 'onPromptAction':
        if (args is! Map) return false;
        return _emit(
          _promptController,
          AutoBillPromptActionEvent.fromMap(args),
        );
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
        return _defaultStatus;
      }
      return AccessibilityBridgeStatus.fromMap(raw);
    } on MissingPluginException {
      return _fallback.getAccessibilityStatus();
    } on PlatformException {
      return _defaultStatus;
    }
  }

  @override
  Future<bool> openAccessibilitySettings() =>
      _openSettings('openAccessibilitySettings', '无法打开系统无障碍设置页面');

  Future<bool> _openSettings(String method, String failureMessage) async {
    try {
      return (await _channel.invokeMethod<bool>(method)) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      throw Failure(
        FailureCode.unsupportedCapability,
        e.message ?? failureMessage,
      );
    }
  }

  Future<AutoBillPermissionStatus> _permission(
    String method, {
    required String enabledLabel,
    required String disabledLabel,
  }) async {
    final fallback = _androidCapture
        ? AutoBillPermissionStatus(
            supported: true,
            enabled: false,
            statusLabel: disabledLabel,
          )
        : const AutoBillPermissionStatus.unsupported();
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(method);
      if (raw == null) return fallback;
      return AutoBillPermissionStatus.fromMap(
        raw,
        enabledLabel: enabledLabel,
        disabledLabel: disabledLabel,
      );
    } on MissingPluginException {
      return fallback;
    } on PlatformException {
      return fallback;
    }
  }

  @override
  Future<AutoBillPermissionStatus> getNotificationListenerStatus() =>
      _permission(
        'getNotificationListenerStatus',
        enabledLabel: notificationListenerEnabledLabel,
        disabledLabel: notificationListenerDisabledLabel,
      );

  @override
  Future<bool> openNotificationListenerSettings() =>
      _openSettings('openNotificationListenerSettings', '无法打开系统通知使用权设置页面');

  @override
  Future<AutoBillPermissionStatus> getOverlayPermissionStatus() => _permission(
    'getOverlayPermissionStatus',
    enabledLabel: overlayGrantedLabel,
    disabledLabel: overlayDeniedLabel,
  );

  @override
  Future<bool> openOverlaySettings() =>
      _openSettings('openOverlaySettings', '无法打开系统悬浮窗权限设置页面');

  Future<bool> _invokeBool(String method, Object? args) async {
    try {
      return (await _channel.invokeMethod<bool>(method, args)) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<bool> syncAndroidAutoBillConfig(AutoBillNativeConfig config) =>
      _invokeBool('syncAndroidAutoBillConfig', config.toMap());

  @override
  Future<bool> showAutoBillPrompt(AutoBillPromptRequest request) =>
      _invokeBool('showAutoBillPrompt', request.toMap());

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

  Future<List<T>> _consumeList<T>(
    String method,
    T? Function(Map<Object?, Object?> map) decode,
  ) async {
    try {
      final rawList = await _channel.invokeListMethod<Object?>(method);
      if (rawList == null) return const [];
      return [
        for (final item in rawList)
          if (item is Map) ?decode(item),
      ];
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  @override
  Future<List<CapturedPaymentEvent>> consumeCapturedEvents() =>
      _consumeList('consumeCapturedEvents', (m) {
        final e = CapturedPaymentEvent.fromMap(m);
        return e.rawText.isEmpty ? null : e;
      });

  @override
  Future<List<AutoBillSharedPayload>> consumePendingSharedPayloads() =>
      _consumeList(
        'consumePendingSharedPayloads',
        AutoBillSharedPayload.fromMap,
      );

  @override
  Future<List<AutoBillPromptActionEvent>> consumePendingPromptActions() =>
      _consumeList(
        'consumePendingPromptActions',
        AutoBillPromptActionEvent.fromMap,
      );

  @override
  Future<OfflineOcrResult> recognizeImageOffline(
    Uint8List bytes, {
    String? fileName,
  }) async {
    if (bytes.isEmpty) {
      throw const Failure(FailureCode.validation, '所选图片内容为空');
    }
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(
        'recognizeImageOffline',
        {'bytes': bytes, 'fileName': fileName},
      );
      return OfflineOcrResult.fromMap(raw);
    } on MissingPluginException {
      return const OfflineOcrResult.unsupported();
    } on PlatformException catch (e) {
      final unsupported = e.code.toUpperCase().contains('UNSUPPORTED');
      throw Failure(
        unsupported
            ? FailureCode.unsupportedCapability
            : FailureCode.remoteUnavailable,
        e.message ?? (unsupported ? '当前设备不支持本机离线识图' : '本机离线识图失败，请重试'),
      );
    }
  }

  @override
  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    await _fallback.dispose();
    await _deepLinkController.close();
    await _eventController.close();
    await _sharedController.close();
    await _promptController.close();
  }
}

/// Deterministic in-memory [AutoBillBridge] for unsupported hosts and tests.
final class InMemoryAutoBillBridge implements AutoBillBridge {
  InMemoryAutoBillBridge({
    this.capability = const Capability(CapabilityState.available, '内存自动记账桥接器'),
    this.status = const AccessibilityBridgeStatus.unsupported(),
    this.notificationListenerStatus =
        const AutoBillPermissionStatus.unsupported(),
    this.overlayStatus = const AutoBillPermissionStatus.unsupported(),
    this.offlineOcrText,
    String? initialPendingDeepLink,
    List<CapturedPaymentEvent>? initialCapturedEvents,
    List<AutoBillSharedPayload>? initialSharedPayloads,
    List<AutoBillPromptActionEvent>? initialPromptActions,
  }) : _pendingDeepLink = initialPendingDeepLink,
       _queuedEvents = [...?initialCapturedEvents],
       _queuedShares = [...?initialSharedPayloads],
       _queuedActions = [...?initialPromptActions];

  @override
  Capability capability;

  AccessibilityBridgeStatus status;
  AutoBillPermissionStatus notificationListenerStatus;
  AutoBillPermissionStatus overlayStatus;

  /// When non-null, [recognizeImageOffline] reports `supported: true` with
  /// this text; `null` reports unsupported.
  String? offlineOcrText;

  String? _pendingDeepLink;
  final List<CapturedPaymentEvent> _queuedEvents;
  final List<AutoBillSharedPayload> _queuedShares;
  final List<AutoBillPromptActionEvent> _queuedActions;
  int openSettingsCount = 0;
  int openNotificationSettingsCount = 0;
  int openOverlaySettingsCount = 0;
  AutoBillNativeConfig? lastSyncedConfig;
  final List<AutoBillPromptRequest> prompts = <AutoBillPromptRequest>[];
  int offlineOcrCalls = 0;

  final StreamController<String> _deepLinkController =
      StreamController<String>.broadcast();
  final StreamController<CapturedPaymentEvent> _eventController =
      StreamController<CapturedPaymentEvent>.broadcast();
  final StreamController<AutoBillSharedPayload> _sharedController =
      StreamController<AutoBillSharedPayload>.broadcast();
  final StreamController<AutoBillPromptActionEvent> _promptController =
      StreamController<AutoBillPromptActionEvent>.broadcast();

  @override
  Stream<String> get onDeepLink => _deepLinkController.stream;

  @override
  Stream<CapturedPaymentEvent> get onCapturedEvent => _eventController.stream;

  @override
  Stream<AutoBillSharedPayload> get onSharedPayload => _sharedController.stream;

  @override
  Stream<AutoBillPromptActionEvent> get onPromptAction =>
      _promptController.stream;

  @override
  Future<AccessibilityBridgeStatus> getAccessibilityStatus() async => status;

  @override
  Future<bool> openAccessibilitySettings() async {
    if (!status.supported) return false;
    openSettingsCount++;
    return true;
  }

  @override
  Future<AutoBillPermissionStatus> getNotificationListenerStatus() async =>
      notificationListenerStatus;

  @override
  Future<bool> openNotificationListenerSettings() async {
    if (!notificationListenerStatus.supported) return false;
    openNotificationSettingsCount++;
    return true;
  }

  @override
  Future<AutoBillPermissionStatus> getOverlayPermissionStatus() async =>
      overlayStatus;

  @override
  Future<bool> openOverlaySettings() async {
    if (!overlayStatus.supported) return false;
    openOverlaySettingsCount++;
    return true;
  }

  @override
  Future<bool> syncAndroidAutoBillConfig(AutoBillNativeConfig config) async {
    lastSyncedConfig = config;
    return notificationListenerStatus.supported || status.supported;
  }

  @override
  Future<bool> showAutoBillPrompt(AutoBillPromptRequest request) async {
    prompts.add(request);
    return request.promptMode != 'silent' &&
        (notificationListenerStatus.supported || status.supported);
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

  @override
  Future<List<AutoBillSharedPayload>> consumePendingSharedPayloads() async {
    final copy = List<AutoBillSharedPayload>.unmodifiable(_queuedShares);
    _queuedShares.clear();
    return copy;
  }

  @override
  Future<List<AutoBillPromptActionEvent>> consumePendingPromptActions() async {
    final copy = List<AutoBillPromptActionEvent>.unmodifiable(_queuedActions);
    _queuedActions.clear();
    return copy;
  }

  @override
  Future<OfflineOcrResult> recognizeImageOffline(
    Uint8List bytes, {
    String? fileName,
  }) async {
    offlineOcrCalls++;
    final text = offlineOcrText;
    if (text == null) return const OfflineOcrResult.unsupported();
    if (bytes.isEmpty) {
      throw const Failure(FailureCode.validation, '所选图片内容为空');
    }
    return OfflineOcrResult(supported: true, text: text);
  }

  /// Simulates an incoming `tallyisle://` URI.
  void simulateDeepLink(String uri) {
    if (!_deepLinkController.isClosed && _deepLinkController.hasListener) {
      _deepLinkController.add(uri);
    } else {
      _pendingDeepLink = uri;
    }
  }

  /// Simulates a payment event arriving in foreground or background.
  void simulateCapturedEvent(CapturedPaymentEvent event) {
    if (!_eventController.isClosed && _eventController.hasListener) {
      _eventController.add(event);
    } else {
      _queuedEvents.add(event);
    }
  }

  /// Simulates a system share / shortcut / service card launch.
  void simulateSharedPayload(AutoBillSharedPayload payload) {
    if (!_sharedController.isClosed && _sharedController.hasListener) {
      _sharedController.add(payload);
    } else {
      _queuedShares.add(payload);
    }
  }

  /// Simulates a prompt notification / overlay button tap.
  void simulatePromptAction(AutoBillPromptActionEvent event) {
    if (!_promptController.isClosed && _promptController.hasListener) {
      _promptController.add(event);
    } else {
      _queuedActions.add(event);
    }
  }

  @override
  Future<void> dispose() async {
    await _deepLinkController.close();
    await _eventController.close();
    await _sharedController.close();
    await _promptController.close();
  }
}
