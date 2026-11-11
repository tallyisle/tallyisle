import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/failure.dart';
import '../core/money.dart';
import 'files.dart';

const String automationChannelName = 'dev.tallyisle/automation';

/// Supported Android home-screen desktop widgets (`F-034`).
enum DesktopWidgetKind {
  quickAdd('quick_add', '快捷记账', '1×1'),
  monthSummary('month_summary', '月度收支概览', '2×2'),
  monthBar('month_bar', '月度横条', '4×1');

  const DesktopWidgetKind(this.wireKey, this.title, this.gridLabel);

  final String wireKey;
  final String title;
  final String gridLabel;

  static DesktopWidgetKind? fromWireKey(String? key) {
    for (final item in DesktopWidgetKind.values) {
      if (item.wireKey == key) return item;
    }
    return null;
  }
}

/// Exact integer-minor snapshot rendered by Android desktop `AppWidgetProvider`s (`F-034`).
///
/// Uses `BigInt` minor units and `Money.minor(...).decimal` exclusively — zero `double` (`ADR-011`).
final class WidgetSnapshotPayload {
  const WidgetSnapshotPayload({
    required this.bookName,
    required this.periodLabel,
    this.currencySymbol = '¥',
    required this.expenseMinor,
    required this.incomeMinor,
    required this.balanceMinor,
    required this.todayExpenseMinor,
    this.budgetRemainingMinor,
    required this.updatedAtMs,
  });

  factory WidgetSnapshotPayload.empty({
    String bookName = '日常账本',
    String periodLabel = '本期',
    int updatedAtMs = 0,
  }) => WidgetSnapshotPayload(
    bookName: bookName,
    periodLabel: periodLabel,
    expenseMinor: BigInt.zero,
    incomeMinor: BigInt.zero,
    balanceMinor: BigInt.zero,
    todayExpenseMinor: BigInt.zero,
    updatedAtMs: updatedAtMs,
  );

  factory WidgetSnapshotPayload.fromMap(Map<Object?, Object?> map) {
    BigInt parseMinor(Object? v) =>
        BigInt.tryParse('${v ?? '0'}'.trim()) ?? BigInt.zero;
    final budgetRaw = map['budgetRemainingMinor'];
    final budgetText = budgetRaw?.toString().trim();
    return WidgetSnapshotPayload(
      bookName: (map['bookName'] as String?) ?? '日常账本',
      periodLabel: (map['periodLabel'] as String?) ?? '本期',
      currencySymbol: (map['currencySymbol'] as String?) ?? '¥',
      expenseMinor: parseMinor(map['expenseMinor']),
      incomeMinor: parseMinor(map['incomeMinor']),
      balanceMinor: parseMinor(map['balanceMinor']),
      todayExpenseMinor: parseMinor(map['todayExpenseMinor']),
      budgetRemainingMinor: budgetText == null || budgetText.isEmpty
          ? null
          : BigInt.tryParse(budgetText),
      updatedAtMs: (map['updatedAtMs'] as num?)?.toInt() ?? 0,
    );
  }

  final String bookName;
  final String periodLabel;
  final String currencySymbol;
  final BigInt expenseMinor;
  final BigInt incomeMinor;
  final BigInt balanceMinor;
  final BigInt todayExpenseMinor;
  final BigInt? budgetRemainingMinor;
  final int updatedAtMs;

  String get expenseFormatted => Money.minor(expenseMinor).decimal;
  String get incomeFormatted => Money.minor(incomeMinor).decimal;
  String get balanceFormatted => Money.minor(balanceMinor).decimal;
  String get todayExpenseFormatted => Money.minor(todayExpenseMinor).decimal;
  String? get budgetRemainingFormatted => budgetRemainingMinor == null
      ? null
      : Money.minor(budgetRemainingMinor!).decimal;

  Map<String, Object?> toMap() => {
    'bookName': bookName,
    'periodLabel': periodLabel,
    'currencySymbol': currencySymbol,
    'expenseMinor': expenseMinor.toString(),
    'incomeMinor': incomeMinor.toString(),
    'balanceMinor': balanceMinor.toString(),
    'todayExpenseMinor': todayExpenseMinor.toString(),
    'budgetRemainingMinor': budgetRemainingMinor?.toString(),
    'expenseFormatted': expenseFormatted,
    'incomeFormatted': incomeFormatted,
    'balanceFormatted': balanceFormatted,
    'todayExpenseFormatted': todayExpenseFormatted,
    'budgetRemainingFormatted': budgetRemainingFormatted,
    'updatedAtMs': updatedAtMs,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WidgetSnapshotPayload &&
          bookName == other.bookName &&
          periodLabel == other.periodLabel &&
          currencySymbol == other.currencySymbol &&
          expenseMinor == other.expenseMinor &&
          incomeMinor == other.incomeMinor &&
          balanceMinor == other.balanceMinor &&
          todayExpenseMinor == other.todayExpenseMinor &&
          budgetRemainingMinor == other.budgetRemainingMinor &&
          updatedAtMs == other.updatedAtMs;

  @override
  int get hashCode => Object.hash(
    bookName,
    periodLabel,
    currencySymbol,
    expenseMinor,
    incomeMinor,
    balanceMinor,
    todayExpenseMinor,
    budgetRemainingMinor,
    updatedAtMs,
  );
}

/// Platform boundary for Android home-screen `AppWidget` rendering & pinning (`ADR-008`, `F-034`).
abstract interface class AppWidgetBridge {
  Capability get capability;

  /// Persists [snapshot] to native widget storage and triggers `AppWidgetManager` refresh.
  Future<Map<DesktopWidgetKind, int>> updateSnapshot(
    WidgetSnapshotPayload snapshot,
  );

  /// Queries how many instances of each [DesktopWidgetKind] are currently placed on the launcher.
  Future<Map<DesktopWidgetKind, int>> getActiveWidgetCounts();

  /// Requests Android 8.0+ `AppWidgetManager.requestPinAppWidget` for [kind].
  /// Returns `false` when the current platform or launcher does not support direct pinning.
  Future<bool> requestPinWidget(DesktopWidgetKind kind);

  Future<void> dispose();
}

/// Creates the platform-appropriate [AppWidgetBridge].
AppWidgetBridge createAppWidgetBridge() {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    return MethodChannelAppWidgetBridge();
  }
  return InMemoryAppWidgetBridge(
    capability: const Capability(
      CapabilityState.unsupported,
      '桌面小组件仅在 Android 系统桌面生效，当前平台仅提供实时预览',
    ),
    pinSupported: false,
  );
}

Map<DesktopWidgetKind, int> _decodeCountsMap(Map<Object?, Object?>? raw) {
  final out = <DesktopWidgetKind, int>{
    for (final kind in DesktopWidgetKind.values) kind: 0,
  };
  if (raw == null) return out;
  for (final entry in raw.entries) {
    final kind = DesktopWidgetKind.fromWireKey('${entry.key}');
    final value = entry.value;
    if (kind != null && value is num) {
      out[kind] = value.toInt();
    }
  }
  return out;
}

/// Android native implementation bridged via `MethodChannel('dev.tallyisle/automation')`.
///
/// Never registers a method-call handler so it coexists cleanly with
/// `MethodChannelAutoBillBridge` on the shared channel.
final class MethodChannelAppWidgetBridge implements AppWidgetBridge {
  MethodChannelAppWidgetBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(automationChannelName);

  final MethodChannel _channel;
  final InMemoryAppWidgetBridge _fallback = InMemoryAppWidgetBridge();

  @override
  Capability get capability =>
      const Capability(CapabilityState.available, 'Android 原生桌面小组件已接入');

  @override
  Future<Map<DesktopWidgetKind, int>> updateSnapshot(
    WidgetSnapshotPayload snapshot,
  ) async {
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(
        'updateWidgetSnapshot',
        snapshot.toMap(),
      );
      return _decodeCountsMap(raw);
    } on MissingPluginException {
      return _fallback.updateSnapshot(snapshot);
    } on PlatformException catch (e) {
      throw Failure(
        FailureCode.storageUnavailable,
        e.message ?? '刷新桌面小组件失败，请稍后重试',
      );
    }
  }

  @override
  Future<Map<DesktopWidgetKind, int>> getActiveWidgetCounts() async {
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(
        'getActiveWidgetCounts',
      );
      return _decodeCountsMap(raw);
    } on MissingPluginException {
      return _fallback.getActiveWidgetCounts();
    } on PlatformException {
      return _decodeCountsMap(null);
    }
  }

  @override
  Future<bool> requestPinWidget(DesktopWidgetKind kind) async {
    try {
      return (await _channel.invokeMethod<bool>('requestPinWidget', {
            'kind': kind.wireKey,
          })) ??
          false;
    } on MissingPluginException {
      return _fallback.requestPinWidget(kind);
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> dispose() => _fallback.dispose();
}

/// Deterministic in-memory [AppWidgetBridge] for non-Android hosts and automated tests.
final class InMemoryAppWidgetBridge implements AppWidgetBridge {
  InMemoryAppWidgetBridge({
    this.capability = const Capability(CapabilityState.available, '内存桌面组件桥接器'),
    this.pinSupported = true,
    Map<DesktopWidgetKind, int>? initialCounts,
  }) : _counts = {
         for (final kind in DesktopWidgetKind.values)
           kind: initialCounts?[kind] ?? 0,
       };

  @override
  final Capability capability;

  bool pinSupported;
  final Map<DesktopWidgetKind, int> _counts;
  final List<WidgetSnapshotPayload> _history = <WidgetSnapshotPayload>[];
  final List<DesktopWidgetKind> _pinRequests = <DesktopWidgetKind>[];
  WidgetSnapshotPayload? lastSnapshot;

  List<WidgetSnapshotPayload> get snapshotHistory =>
      List<WidgetSnapshotPayload>.unmodifiable(_history);

  List<DesktopWidgetKind> get pinRequests =>
      List<DesktopWidgetKind>.unmodifiable(_pinRequests);

  void setActiveCount(DesktopWidgetKind kind, int count) {
    _counts[kind] = count < 0 ? 0 : count;
  }

  @override
  Future<Map<DesktopWidgetKind, int>> updateSnapshot(
    WidgetSnapshotPayload snapshot,
  ) async {
    lastSnapshot = snapshot;
    _history.add(snapshot);
    return Map<DesktopWidgetKind, int>.unmodifiable(_counts);
  }

  @override
  Future<Map<DesktopWidgetKind, int>> getActiveWidgetCounts() async =>
      Map<DesktopWidgetKind, int>.unmodifiable(_counts);

  @override
  Future<bool> requestPinWidget(DesktopWidgetKind kind) async {
    _pinRequests.add(kind);
    if (!pinSupported || capability.state != CapabilityState.available) {
      return false;
    }
    _counts[kind] = (_counts[kind] ?? 0) + 1;
    return true;
  }

  @override
  Future<void> dispose() async {}
}
