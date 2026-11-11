import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/catalog/currency_service.dart';
import '../../data/catalog/exchange_rate_provider.dart';
import '../../domain/rules/online_rate_rules.dart';

/// Optional injectable `HttpClient` factory for deterministic testing of
/// [HttpExchangeRateProvider] without touching real OS sockets.
final onlineRateHttpClientFactoryProvider = Provider<HttpClient Function()?>(
  (ref) => null,
);

/// Reactive stream of [OnlineRateSettings] from `ti_preference`
/// (`'online_rate_settings'`, strictly `enabled: false` by default).
final onlineRateSettingsProvider = StreamProvider<OnlineRateSettings>((
  ref,
) async* {
  final service = await ref.watch(currencyServiceProvider.future);
  yield* service.watchOnlineRateSettings();
});

/// Pluggable [ExchangeRateProvider] bound to the current [OnlineRateSettings] (`ADR-017`).
final exchangeRateProviderInstanceProvider =
    FutureProvider<ExchangeRateProvider>((ref) async {
      final settings = await ref.watch(onlineRateSettingsProvider.future);
      final db = await ref.watch(databaseProvider.future);
      final clientFactory = ref.watch(onlineRateHttpClientFactoryProvider);
      return HttpExchangeRateProvider(
        settings: settings,
        httpClientFactory: clientFactory,
        nowMs: db.nowMs,
      );
    });

/// One-shot launch auto-sync check: returns `null` immediately with zero
/// network I/O whenever `enabled == false`, `autoSyncOnLaunch == false`, or
/// within the 24-hour cooldown window.
final onlineRateLaunchAutoSyncProvider =
    FutureProvider.autoDispose<OnlineRateSyncResult?>((ref) async {
      final service = await ref.watch(currencyServiceProvider.future);
      final settings = await service.getOnlineRateSettings();
      if (!settings.shouldAutoSync(nowMs: service.db.nowMs())) {
        return null;
      }
      final provider = await ref.read(
        exchangeRateProviderInstanceProvider.future,
      );
      return service.runAutoSyncIfNeeded(provider: provider);
    });
