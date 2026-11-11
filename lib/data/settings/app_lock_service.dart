import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../core/failure.dart';
import '../../domain/rules/app_lock_rules.dart';
import '../../platform/biometrics.dart';
import '../db/database.dart';
import '../db/failures.dart';

/// Persistence, verification, and biometric-coordination service for App Lock
/// (`F-024`, `ADR-008`, `ADR-009`).
final class AppLockService {
  AppLockService(this.db, {BiometricAuthenticator? authenticator})
    : authenticator = authenticator ?? createBiometricAuthenticator();

  final AppDatabase db;
  final BiometricAuthenticator authenticator;

  int _now() => db.nowMs();

  String _digestText(String input) =>
      sha256.convert(utf8.encode(input)).toString();

  Future<AppLockConfig> _loadRawConfig() async {
    final pref = await (db.select(
      db.preferences,
    )..where((t) => t.key.equals(appLockPreferenceKey))).getSingleOrNull();
    return AppLockConfig.parse(pref?.value);
  }

  Future<void> _writeRawConfig(AppLockConfig config) => db
      .into(db.preferences)
      .insertOnConflictUpdate(
        PreferencesCompanion.insert(
          key: appLockPreferenceKey,
          value: config.encode(),
        ),
      );

  Future<T> _command<T>(
    String commandId,
    List<Object?> payload,
    Future<String> Function() body,
    T Function(String resultId) result,
  ) async {
    if (commandId.isEmpty || commandId.length > 128) {
      throw const Failure(FailureCode.validation, '提交标识无效');
    }
    final hash = sha256.convert(utf8.encode(jsonEncode(payload))).toString();
    return guardDatabase(
      () => db.transaction(() async {
        final previous = await (db.select(
          db.writeCommands,
        )..where((t) => t.commandId.equals(commandId))).getSingleOrNull();
        if (previous != null) {
          if (previous.payloadHash != hash) {
            throw const Failure(FailureCode.conflict, '同一提交标识的内容发生变化');
          }
          return result(previous.resultId);
        }
        final id = await body();
        await db
            .into(db.writeCommands)
            .insert(
              WriteCommandsCompanion.insert(
                commandId: commandId,
                payloadHash: hash,
                resultId: id,
                committedAt: _now(),
              ),
            );
        return result(id);
      }),
    );
  }

  Future<WriteCommand?> _lookupCommand(String commandId) {
    if (commandId.isEmpty || commandId.length > 128) {
      throw const Failure(FailureCode.validation, '提交标识无效');
    }
    return guardDatabase(
      () => (db.select(
        db.writeCommands,
      )..where((t) => t.commandId.equals(commandId))).getSingleOrNull(),
    );
  }

  /// Reactive stream of [AppLockConfig] stored in `ti_preference`.
  Stream<AppLockConfig> watchConfig() =>
      (db.select(db.preferences)
            ..where((t) => t.key.equals(appLockPreferenceKey)))
          .watchSingleOrNull()
          .map((row) {
            try {
              return AppLockConfig.parse(row?.value);
            } on Failure {
              return AppLockConfig.disabled;
            }
          });

  /// Reads current [AppLockConfig] snapshot.
  Future<AppLockConfig> getConfig() => guardDatabase(_loadRawConfig);

  /// Enables App Lock with a salted `>= 10,000`-round PBKDF2-HMAC-SHA256 PIN hash.
  Future<AppLockConfig> enableAppLock({
    required String commandId,
    required String pin,
    bool biometricEnabled = false,
    int timeoutSeconds = 0,
    List<int>? saltBytes,
  }) async {
    validatePinFormat(pin);
    validateLockTimeoutSeconds(timeoutSeconds);
    return _command(
      commandId,
      [
        'app-lock-enable-v1',
        _digestText(pin),
        pin.length,
        biometricEnabled,
        timeoutSeconds,
      ],
      () async {
        final next = createConfiguredAppLock(
          pin: pin,
          nowMs: _now(),
          saltBytes: saltBytes,
          biometricEnabled: biometricEnabled,
          timeoutSeconds: timeoutSeconds,
        );
        await _writeRawConfig(next);
        return next.encode();
      },
      AppLockConfig.parse,
    );
  }

  /// Evaluates [candidatePin] against the stored hash, atomically persisting
  /// `failedAttempts` and `cooldownUntilMs` into `ti_preference` (`R3`, `SEC-LK-02`).
  Future<PinAttemptEvaluation> verifyPin(String candidatePin) => guardDatabase(
    () => db.transaction(() async {
      final current = await _loadRawConfig();
      final outcome = evaluatePinAttempt(
        config: current,
        candidatePin: candidatePin,
        nowMs: _now(),
      );
      if (outcome.updatedConfig != current) {
        await _writeRawConfig(outcome.updatedConfig);
      }
      return outcome;
    }),
  );

  /// Changes the App Lock PIN after verifying [currentPin] (`ADR-009`).
  ///
  /// Failed verification attempts commit failure counters before throwing
  /// [Failure] so cooldown lockouts cannot be bypassed.
  Future<AppLockConfig> changePin({
    required String commandId,
    required String currentPin,
    required String newPin,
    List<int>? saltBytes,
  }) async {
    final payload = <Object?>[
      'app-lock-change-pin-v1',
      _digestText(currentPin),
      _digestText(newPin),
      newPin.length,
    ];
    final hash = sha256.convert(utf8.encode(jsonEncode(payload))).toString();

    final existingCmd = await _lookupCommand(commandId);
    if (existingCmd != null) {
      if (existingCmd.payloadHash != hash) {
        throw const Failure(FailureCode.conflict, '同一提交标识的内容发生变化');
      }
      return AppLockConfig.parse(existingCmd.resultId);
    }

    validatePinFormat(newPin);
    final verification = await verifyPin(currentPin);
    if (!verification.matched) {
      throw Failure(FailureCode.authRequired, verification.message);
    }

    return _command(commandId, payload, () async {
      final current = await _loadRawConfig();
      if (!current.isConfigured) {
        throw const Failure(FailureCode.validation, '应用安全锁尚未启用');
      }
      final next = createConfiguredAppLock(
        pin: newPin,
        nowMs: _now(),
        saltBytes: saltBytes,
        biometricEnabled: current.biometricEnabled,
        timeoutSeconds: current.timeoutSeconds,
      );
      await _writeRawConfig(next);
      return next.encode();
    }, AppLockConfig.parse);
  }

  /// Disables App Lock after verifying [currentPin] (`ADR-009`).
  Future<void> disableAppLock({
    required String commandId,
    required String currentPin,
  }) async {
    final payload = <Object?>['app-lock-disable-v1', _digestText(currentPin)];
    final hash = sha256.convert(utf8.encode(jsonEncode(payload))).toString();

    final existingCmd = await _lookupCommand(commandId);
    if (existingCmd != null) {
      if (existingCmd.payloadHash != hash) {
        throw const Failure(FailureCode.conflict, '同一提交标识的内容发生变化');
      }
      return;
    }

    final verification = await verifyPin(currentPin);
    if (!verification.matched) {
      throw Failure(FailureCode.authRequired, verification.message);
    }

    await _command(commandId, payload, () async {
      await _writeRawConfig(AppLockConfig.disabled);
      return 'disabled';
    }, (_) {});
  }

  /// Updates biometric unlock toggle and/or background timeout (`{0, 30, 60, 300}`).
  Future<AppLockConfig> updateLockOptions({
    required String commandId,
    bool? biometricEnabled,
    int? timeoutSeconds,
  }) async {
    if (timeoutSeconds != null) {
      validateLockTimeoutSeconds(timeoutSeconds);
    }
    return _command(
      commandId,
      ['app-lock-options-v1', biometricEnabled, timeoutSeconds],
      () async {
        final current = await _loadRawConfig();
        if (!current.isConfigured) {
          throw const Failure(FailureCode.validation, '请先启用数字密码应用锁');
        }
        final next = current.copyWith(
          biometricEnabled: biometricEnabled ?? current.biometricEnabled,
          timeoutSeconds: timeoutSeconds ?? current.timeoutSeconds,
          updatedAtMs: _now(),
        );
        await _writeRawConfig(next);
        return next.encode();
      },
      AppLockConfig.parse,
    );
  }

  /// Queries OS biometric hardware/enrollment status (`ADR-008`).
  Future<BiometricAvailability> checkBiometricAvailability() =>
      authenticator.checkAvailability();

  /// Invokes OS `BiometricPrompt` when biometric unlock is enabled; on success,
  /// clears any accumulated PIN failure count.
  Future<BiometricAuthResult> authenticateWithBiometrics() async {
    final current = await getConfig();
    if (!current.isConfigured || !current.biometricEnabled) {
      return const BiometricAuthResult(
        outcome: BiometricAuthOutcome.unavailable,
        message: '尚未开启生物识别解锁，请输入数字密码',
      );
    }
    final result = await authenticator.authenticate();
    if (result.isAuthenticated) {
      await guardDatabase(
        () => db.transaction(() async {
          final latest = await _loadRawConfig();
          if (latest.isConfigured &&
              (latest.failedAttempts > 0 || latest.cooldownUntilMs > 0)) {
            await _writeRawConfig(
              latest.copyWith(failedAttempts: 0, cooldownUntilMs: 0),
            );
          }
        }),
      );
    }
    return result;
  }
}
