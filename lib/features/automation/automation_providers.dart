import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/automation/auto_bill_service.dart';
import '../../data/automation/mcp_server_service.dart';
import '../../data/automation/ocr_service.dart';
import '../../data/automation/url_scheme_service.dart';
import '../../data/automation/widget_snapshot_service.dart';
import '../../domain/rules/auto_map_rules.dart';
import '../../domain/rules/mcp_rules.dart';
import '../../domain/rules/ocr_bill_rules.dart';
import '../../domain/rules/smart_bill_nlp_rules.dart';
import '../../platform/app_widgets.dart';
import '../../platform/auto_bill_bridge.dart';
import '../../platform/files.dart';

final appWidgetBridgeProvider = Provider<AppWidgetBridge>((ref) {
  final bridge = createAppWidgetBridge();
  ref.onDispose(() => unawaited(bridge.dispose()));
  return bridge;
});

final autoBillBridgeProvider = Provider<AutoBillBridge>((ref) {
  final bridge = createAutoBillBridge();
  ref.onDispose(() => unawaited(bridge.dispose()));
  return bridge;
});

final ocrFileAccessProvider = Provider<FileAccess>((ref) => const FileAccess());

final ocrHttpClientFactoryProvider = Provider<HttpClient Function()?>(
  (ref) => null,
);

/// Optional user-enabled OpenAI-compatible client (never called unless the
/// user enables `AiBillParserConfig`).
final aiBillParserClientProvider = Provider<AiBillParserClient>((ref) {
  final clientFactory = ref.watch(ocrHttpClientFactoryProvider);
  return OpenAiCompatibleBillParserClient(httpClientFactory: clientFactory);
});

final urlSchemeServiceProvider = FutureProvider<UrlSchemeService>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  final ledger = await ref.watch(ledgerServiceProvider.future);
  final bridge = ref.watch(autoBillBridgeProvider);
  final autoBill = await ref.watch(autoBillServiceProvider.future);
  return UrlSchemeService(
    db,
    ledgerService: ledger,
    bridge: bridge,
    autoBillService: autoBill,
  );
});

final widgetSnapshotServiceProvider = FutureProvider<WidgetSnapshotService>((
  ref,
) async {
  final db = await ref.watch(databaseProvider.future);
  final bridge = ref.watch(appWidgetBridgeProvider);
  return WidgetSnapshotService(db, bridge: bridge);
});

final autoBillServiceProvider = FutureProvider<AutoBillService>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  final ledger = await ref.watch(ledgerServiceProvider.future);
  final bridge = ref.watch(autoBillBridgeProvider);
  final aiClient = ref.watch(aiBillParserClientProvider);
  final widgets = await ref.watch(widgetSnapshotServiceProvider.future);
  return AutoBillService(
    db,
    ledgerService: ledger,
    bridge: bridge,
    aiClient: aiClient,
    afterChange: () async {
      if (widgets.capability.state == CapabilityState.available) {
        await widgets.syncToPlatform();
      }
    },
  );
});

final ocrServiceProvider = FutureProvider<OcrService>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  final ledger = await ref.watch(ledgerServiceProvider.future);
  final clientFactory = ref.watch(ocrHttpClientFactoryProvider);
  final bridge = ref.watch(autoBillBridgeProvider);
  final aiClient = ref.watch(aiBillParserClientProvider);
  return OcrService(
    db,
    ledgerService: ledger,
    httpClientFactory: clientFactory,
    bridge: bridge,
    aiClient: aiClient,
  );
});

/// Live widget snapshot reactive to current book & period record changes (`F-034`).
final widgetSnapshotProvider = FutureProvider<WidgetSnapshotPayload>((
  ref,
) async {
  // Watch reactive book & period record streams so edits auto-recompute the preview.
  ref.watch(currentBookProvider);
  ref.watch(periodRecordsProvider);
  final service = await ref.watch(widgetSnapshotServiceProvider.future);
  return service.computeCurrentSnapshot();
});

final activeWidgetCountsProvider = FutureProvider<Map<DesktopWidgetKind, int>>((
  ref,
) async {
  final service = await ref.watch(widgetSnapshotServiceProvider.future);
  return service.getActiveWidgetCounts();
});

final accessibilityStatusProvider = FutureProvider<AccessibilityBridgeStatus>((
  ref,
) async {
  final bridge = ref.watch(autoBillBridgeProvider);
  return bridge.getAccessibilityStatus();
});

final notificationListenerStatusProvider =
    FutureProvider<AutoBillPermissionStatus>((ref) async {
      final bridge = ref.watch(autoBillBridgeProvider);
      return bridge.getNotificationListenerStatus();
    });

final overlayPermissionStatusProvider =
    FutureProvider<AutoBillPermissionStatus>((ref) async {
      final bridge = ref.watch(autoBillBridgeProvider);
      return bridge.getOverlayPermissionStatus();
    });

final autoBillSettingsProvider = StreamProvider<AutoBillSettings>((ref) async* {
  final service = await ref.watch(autoBillServiceProvider.future);
  yield* service.watchSettings();
});

final aiBillParserConfigProvider = StreamProvider<AiBillParserConfig>((
  ref,
) async* {
  final service = await ref.watch(autoBillServiceProvider.future);
  yield* service.watchAiParserConfig();
});

final autoMapRulesProvider = StreamProvider<List<AutoMapRule>>((ref) async* {
  final service = await ref.watch(autoBillServiceProvider.future);
  yield* service.watchRules();
});

final autoBillDraftsProvider = StreamProvider<List<AutoBillDraft>>((
  ref,
) async* {
  final service = await ref.watch(autoBillServiceProvider.future);
  yield* service.watchDrafts();
});

final autoBillDraftCountProvider = Provider<int>((ref) {
  final drafts = ref.watch(autoBillDraftsProvider).value;
  return drafts?.length ?? 0;
});

final ocrConfigProvider = StreamProvider<OcrEndpointConfig>((ref) async* {
  final service = await ref.watch(ocrServiceProvider.future);
  yield* service.watchConfig();
});

final ocrProviderInstanceProvider = StreamProvider<OcrProvider>((ref) async* {
  final service = await ref.watch(ocrServiceProvider.future);
  yield* service.watchProvider();
});

final mcpServerServiceProvider = FutureProvider<McpServerService>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  final service = McpServerService(db);
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});

final mcpServerConfigProvider = StreamProvider<McpServerConfig>((ref) async* {
  final service = await ref.watch(mcpServerServiceProvider.future);
  yield* service.watchConfig();
});

final mcpRuntimeStatusProvider = StreamProvider<McpRuntimeStatus>((ref) async* {
  final service = await ref.watch(mcpServerServiceProvider.future);
  yield* service.watchRuntimeStatus();
});
