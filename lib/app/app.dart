import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/backup/backup_providers.dart';
import '../features/deposit/fixed_deposit_providers.dart';
import '../features/installment/installment_providers.dart';
import '../features/periodic/periodic_providers.dart';
import '../features/reminder/reminder_providers.dart';
import '../features/savings/savings_providers.dart';
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
  }

  void _handleLaunchRoute(String? route) {
    if (_disposed || !mounted || route == null || route.isEmpty) return;
    final current = router.routeInformationProvider.value.uri.toString();
    if (current == route) return;
    unawaited(router.push(route));
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
    router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    onGenerateTitle: (context) => brandName(Localizations.localeOf(context)),
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    supportedLocales: const [Locale('zh'), Locale('en')],
    locale: const Locale('zh'),
    theme: ThemeData(
      fontFamilyFallback: const ['NotoSansSC'],
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff138eaa)),
      useMaterial3: true,
    ),
    routerConfig: router,
  );
}
