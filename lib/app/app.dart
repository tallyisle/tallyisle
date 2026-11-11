import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/rules/app_settings_rules.dart';
import '../features/automation/automation_providers.dart';
import '../features/backup/backup_providers.dart';
import '../features/deposit/fixed_deposit_providers.dart';
import '../features/installment/installment_providers.dart';
import '../features/periodic/periodic_providers.dart';
import '../features/reminder/reminder_providers.dart';
import '../features/savings/savings_providers.dart';
import '../features/security/app_lock_gate.dart';
import '../platform/auto_bill_bridge.dart';
import 'providers.dart';
import 'router.dart';

String brandName(Locale locale) =>
    locale.languageCode == 'zh' ? '帐屿' : 'TallyIsle';

class TallyIsleApp extends ConsumerStatefulWidget {
  const TallyIsleApp({super.key});
  @override
  ConsumerState<TallyIsleApp> createState() => _TallyIsleAppState();
}

class _TallyIsleAppState extends ConsumerState<TallyIsleApp>
    with WidgetsBindingObserver {
  late final router = buildRouter();
  StreamSubscription<String>? _launchRouteSub;
  StreamSubscription<String>? _deepLinkSub;
  StreamSubscription<CapturedPaymentEvent>? _capturedEventSub;
  int _deepLinkSeq = 0;
  int _capturedEventSeq = 0;
  bool _disposed = false;
  bool _syncRunning = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || !mounted) return;
      _attachLaunchRouteListener();
      unawaited(_runLifecycleSync(isInitial: true));
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_disposed && mounted) {
      unawaited(_runLifecycleSync(isInitial: false));
    }
  }

  void _attachLaunchRouteListener() {
    final scheduler = ref.read(reminderSchedulerProvider);
    _launchRouteSub ??= scheduler.onLaunchRoute.listen(_handleLaunchRoute);

    final autoBridge = ref.read(autoBillBridgeProvider);
    _deepLinkSub ??= autoBridge.onDeepLink.listen(
      (uri) => unawaited(_handleDeepLink(uri)),
    );
    _capturedEventSub ??= autoBridge.onCapturedEvent.listen(
      (event) => unawaited(_handleCapturedEvent(event)),
    );
  }

  void _handleLaunchRoute(String? route) {
    if (_disposed || !mounted || route == null || route.isEmpty) return;
    final current = router.routeInformationProvider.value.uri.toString();
    if (current == route) return;
    if (route == '/' ||
        route == '/stats' ||
        route.startsWith('/stats?') ||
        route == '/assets' ||
        route == '/me') {
      router.go(route);
      return;
    }
    unawaited(router.push(route));
  }

  Future<void> _handleDeepLink(String rawUri) async {
    if (_disposed || !mounted || rawUri.trim().isEmpty) return;
    try {
      final service = await ref.read(urlSchemeServiceProvider.future);
      if (_disposed || !mounted) return;
      final seq = _deepLinkSeq++;
      final result = await service.executeUri(
        rawUri,
        commandId:
            'live-deeplink:$seq:${DateTime.now().microsecondsSinceEpoch}',
      );
      if (_disposed || !mounted) return;
      if (result.targetRoute != null) {
        _handleLaunchRoute(result.targetRoute);
      }
      if (result.wroteRecord) {
        final widgetService = await ref.read(
          widgetSnapshotServiceProvider.future,
        );
        if (!_disposed && mounted) {
          await widgetService.syncToPlatform();
        }
      }
    } catch (_) {
      // Non-blocking external deep-link handling.
    }
  }

  Future<void> _handleCapturedEvent(CapturedPaymentEvent event) async {
    if (_disposed || !mounted) return;
    try {
      final service = await ref.read(autoBillServiceProvider.future);
      if (_disposed || !mounted) return;
      final seq = _capturedEventSeq++;
      await service.ingestPaymentText(
        commandId:
            'live-acc:$seq:${event.capturedAtMs}:${event.packageName.hashCode}',
        rawText: event.rawText,
        packageName: event.packageName,
        capturedAtMs: event.capturedAtMs,
        allowNonPaymentSkip: true,
      );
    } catch (_) {
      // Non-blocking accessibility event ingestion.
    }
  }

  Future<void> _runLifecycleSync({required bool isInitial}) async {
    if (_disposed || !mounted) return;
    try {
      final scheduler = ref.read(reminderSchedulerProvider);
      final pending = await scheduler.consumePendingLaunchRoute();
      _handleLaunchRoute(pending);
    } catch (_) {
      // Non-blocking launch-route check.
    }

    if (_syncRunning || _disposed || !mounted) return;
    _syncRunning = true;
    try {
      Future<void> safeStep(Future<void> Function() action) async {
        if (_disposed || !mounted) return;
        try {
          await action();
        } catch (_) {
          // Background catch-up errors must never disrupt foreground UI.
        }
      }

      await safeStep(() async {
        final service = await ref.read(urlSchemeServiceProvider.future);
        if (_disposed || !mounted) return;
        final res = await service.consumeAndExecutePendingDeepLink();
        if (_disposed || !mounted || res == null) return;
        if (res.targetRoute != null) {
          _handleLaunchRoute(res.targetRoute);
        }
      });
      await safeStep(() async {
        final service = await ref.read(autoBillServiceProvider.future);
        if (_disposed || !mounted) return;
        await service.ingestCapturedEvents();
      });
      await safeStep(() async {
        final service = await ref.read(periodicServiceProvider.future);
        if (_disposed || !mounted) return;
        await service.runCatchUp(force: isInitial);
      });
      await safeStep(() async {
        final service = await ref.read(installmentServiceProvider.future);
        if (_disposed || !mounted) return;
        await service.runCatchUp();
      });
      await safeStep(() async {
        final service = await ref.read(savingsServiceProvider.future);
        if (_disposed || !mounted) return;
        await service.runAutoSave();
      });
      await safeStep(() async {
        final service = await ref.read(fixedDepositServiceProvider.future);
        if (_disposed || !mounted) return;
        await service.settleDueDeposits();
      });
      await safeStep(() async {
        final service = await ref.read(reminderServiceProvider.future);
        if (_disposed || !mounted) return;
        await service.resyncAll();
      });
      await safeStep(() async {
        final service = await ref.read(tallyBackupServiceProvider.future);
        if (_disposed || !mounted) return;
        await service.runSilentAutoBackupIfNeeded();
      });
      await safeStep(() async {
        final service = await ref.read(widgetSnapshotServiceProvider.future);
        if (_disposed || !mounted) return;
        await service.syncToPlatform();
      });
    } finally {
      _syncRunning = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_launchRouteSub?.cancel());
    _launchRouteSub = null;
    unawaited(_deepLinkSub?.cancel());
    _deepLinkSub = null;
    unawaited(_capturedEventSub?.cancel());
    _capturedEventSub = null;
    router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings =
        ref.watch(appSettingsProvider).value ?? AppSettings.defaults;
    final seedColor = Color(settings.themeSeedArgb32);
    final themeMode = switch (settings.themeMode) {
      AppThemeModePreference.system => ThemeMode.system,
      AppThemeModePreference.light => ThemeMode.light,
      AppThemeModePreference.dark => ThemeMode.dark,
    };

    return MaterialApp.router(
      onGenerateTitle: (context) => brandName(Localizations.localeOf(context)),
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      supportedLocales: const [Locale('zh'), Locale('en')],
      locale: const Locale('zh'),
      themeMode: themeMode,
      theme: ThemeData(
        fontFamilyFallback: const ['NotoSansSC'],
        colorScheme: ColorScheme.fromSeed(
          seedColor: seedColor,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        fontFamilyFallback: const ['NotoSansSC'],
        colorScheme: ColorScheme.fromSeed(
          seedColor: seedColor,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      builder: (context, child) =>
          AppLockGate(child: child ?? const SizedBox.shrink()),
      routerConfig: router,
    );
  }
}
