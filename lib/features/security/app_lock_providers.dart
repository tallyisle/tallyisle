import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/settings/app_lock_service.dart';
import '../../domain/rules/app_lock_rules.dart';
import '../../platform/biometrics.dart';

/// Platform biometric authenticator provider (`ADR-008`, overridable in tests).
final biometricAuthenticatorProvider = Provider<BiometricAuthenticator>(
  (ref) => createBiometricAuthenticator(),
);

/// Clock function used by [AppLockSessionController] for background timeout and
/// cooldown checks (defaults to `AppDatabase.nowMs` when loaded).
final appLockClockProvider = Provider<int Function()>((ref) {
  final dbAsync = ref.watch(databaseProvider);
  return () => dbAsync.value?.nowMs() ?? DateTime.now().millisecondsSinceEpoch;
});

/// Service provider for App Lock persistence and verification (`F-024`).
final appLockServiceProvider = FutureProvider<AppLockService>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  final auth = ref.watch(biometricAuthenticatorProvider);
  return AppLockService(db, authenticator: auth);
});

/// Reactive stream of persisted [AppLockConfig] from `ti_preference`.
final appLockConfigProvider = StreamProvider<AppLockConfig>((ref) async* {
  final service = await ref.watch(appLockServiceProvider.future);
  yield* service.watchConfig();
});

/// Snapshot of system biometric hardware/enrollment availability.
final biometricAvailabilityProvider = FutureProvider<BiometricAvailability>((
  ref,
) async {
  final auth = ref.watch(biometricAuthenticatorProvider);
  return auth.checkAvailability();
});

/// Ephemeral UI session state managed by [AppLockSessionController].
final class AppLockSessionState {
  const AppLockSessionState({
    this.initializedColdStart = false,
    this.isLocked = false,
    this.biometricInFlight = false,
    this.backgroundedAtMs,
    this.feedbackMessage,
  });

  final bool initializedColdStart;
  final bool isLocked;
  final bool biometricInFlight;
  final int? backgroundedAtMs;
  final String? feedbackMessage;

  AppLockSessionState copyWith({
    bool? initializedColdStart,
    bool? isLocked,
    bool? biometricInFlight,
    int? backgroundedAtMs,
    bool clearBackgroundedAt = false,
    String? feedbackMessage,
    bool clearFeedback = false,
  }) => AppLockSessionState(
    initializedColdStart: initializedColdStart ?? this.initializedColdStart,
    isLocked: isLocked ?? this.isLocked,
    biometricInFlight: biometricInFlight ?? this.biometricInFlight,
    backgroundedAtMs: clearBackgroundedAt
        ? null
        : (backgroundedAtMs ?? this.backgroundedAtMs),
    feedbackMessage: clearFeedback
        ? null
        : (feedbackMessage ?? this.feedbackMessage),
  );
}

/// Manages lock/unlock session transitions across cold start, background/resume,
/// manual locking, PIN verification, and biometric prompts (`F-024`).
final class AppLockSessionController extends Notifier<AppLockSessionState> {
  @override
  AppLockSessionState build() {
    ref.listen<AsyncValue<AppLockConfig>>(appLockConfigProvider, (prev, next) {
      next.whenData(_onConfigChanged);
    }, fireImmediately: true);
    return const AppLockSessionState();
  }

  void _onConfigChanged(AppLockConfig config) {
    if (!state.initializedColdStart) {
      state = state.copyWith(
        initializedColdStart: true,
        isLocked: config.isConfigured,
        clearFeedback: true,
      );
      return;
    }
    if (!config.isConfigured && state.isLocked) {
      state = state.copyWith(
        isLocked: false,
        clearBackgroundedAt: true,
        clearFeedback: true,
      );
    }
  }

  /// Manually locks the app immediately if App Lock is configured.
  void lockNow() {
    final config = ref.read(appLockConfigProvider).value;
    if (config == null || !config.isConfigured) return;
    state = state.copyWith(isLocked: true, clearFeedback: true);
  }

  /// Records timestamp when the app transitions to background (`paused`/`hidden`).
  void onAppBackgrounded() {
    if (state.biometricInFlight) return;
    final config = ref.read(appLockConfigProvider).value;
    if (config == null || !config.isConfigured) return;
    final now = ref.read(appLockClockProvider)();
    state = state.copyWith(backgroundedAtMs: state.backgroundedAtMs ?? now);
  }

  /// Evaluates background timeout when returning to foreground (`resumed`).
  void onAppResumed() {
    if (state.biometricInFlight) return;
    final config = ref.read(appLockConfigProvider).value;
    if (config == null || !config.isConfigured) {
      if (state.backgroundedAtMs != null) {
        state = state.copyWith(clearBackgroundedAt: true);
      }
      return;
    }
    final now = ref.read(appLockClockProvider)();
    final mustLock = shouldLockAfterBackground(
      config: config,
      backgroundedAtMs: state.backgroundedAtMs,
      nowMs: now,
    );
    state = state.copyWith(
      isLocked: state.isLocked || mustLock,
      clearBackgroundedAt: true,
      clearFeedback: mustLock ? true : false,
    );
  }

  /// Attempts to unlock the gate with [candidatePin].
  Future<PinAttemptEvaluation> unlockWithPin(String candidatePin) async {
    final service = await ref.read(appLockServiceProvider.future);
    final outcome = await service.verifyPin(candidatePin);
    if (outcome.matched) {
      state = state.copyWith(
        isLocked: false,
        clearBackgroundedAt: true,
        clearFeedback: true,
      );
    } else {
      state = state.copyWith(isLocked: true, feedbackMessage: outcome.message);
    }
    return outcome;
  }

  /// Attempts to unlock the gate using OS biometrics (`BiometricPrompt`).
  Future<BiometricAuthResult> unlockWithBiometrics() async {
    final service = await ref.read(appLockServiceProvider.future);
    state = state.copyWith(biometricInFlight: true, clearFeedback: true);
    try {
      final result = await service.authenticateWithBiometrics();
      if (result.isAuthenticated) {
        state = state.copyWith(
          isLocked: false,
          biometricInFlight: false,
          clearBackgroundedAt: true,
          clearFeedback: true,
        );
      } else {
        state = state.copyWith(
          isLocked: true,
          biometricInFlight: false,
          feedbackMessage: result.message,
        );
      }
      return result;
    } catch (_) {
      const fallback = BiometricAuthResult(
        outcome: BiometricAuthOutcome.unavailable,
        message: '生物识别暂不可用，请输入数字密码解锁',
      );
      state = state.copyWith(
        isLocked: true,
        biometricInFlight: false,
        feedbackMessage: fallback.message,
      );
      return fallback;
    }
  }
}

final appLockSessionProvider =
    NotifierProvider<AppLockSessionController, AppLockSessionState>(
      AppLockSessionController.new,
    );
