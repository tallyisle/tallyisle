import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../core/failure.dart';

/// `ti_preference` key storing serialized [AppLockConfig] JSON (`F-024`).
const String appLockPreferenceKey = 'app_lock_config';

/// Allowed PIN lengths (4-digit or 6-digit numeric PIN).
const Set<int> allowedPinLengths = <int>{4, 6};

/// Allowed background lock timeout thresholds in seconds (`0` = immediate).
const List<int> allowedLockTimeouts = <int>[0, 30, 60, 300];

/// Minimum required PBKDF2-HMAC-SHA256 rounds (`>= 10,000`).
const int minPinHashRounds = 10000;

/// Default PBKDF2-HMAC-SHA256 rounds written for new PIN hashes.
const int defaultPinHashRounds = 10000;

/// Random salt length in bytes (`16` bytes = `128` bits).
const int pinSaltByteLength = 16;

/// Derived key length in bytes (`32` bytes = `256` bits).
const int pinHashByteLength = 32;

/// Maximum consecutive failed PIN attempts before cooldown lockout.
const int maxPinFailedAttempts = 5;

/// Cooldown lockout duration in milliseconds (`30` seconds).
const int pinCooldownDurationMs = 30 * 1000;

const _corruptLockConfig = Failure(FailureCode.corruptData, '应用安全锁配置格式损坏');

/// Human-readable label for a background lock timeout option.
String lockTimeoutLabel(int seconds) => switch (seconds) {
  0 => '切入后台立即锁定',
  30 => '30 秒后锁定',
  60 => '1 分钟后锁定',
  300 => '5 分钟后锁定',
  _ => '$seconds 秒后锁定',
};

/// Validates that [pin] consists strictly of 4 or 6 ASCII digits.
void validatePinFormat(String pin, {int? expectedLength}) {
  if (expectedLength != null && !allowedPinLengths.contains(expectedLength)) {
    throw const Failure(FailureCode.validation, '密码长度仅支持 4 位或 6 位');
  }
  final lengthOk = expectedLength != null
      ? pin.length == expectedLength
      : allowedPinLengths.contains(pin.length);
  if (!lengthOk || !RegExp(r'^[0-9]+$').hasMatch(pin)) {
    final hint = expectedLength != null ? '$expectedLength 位' : '4 位或 6 位';
    throw Failure(FailureCode.validation, '请输入 $hint纯数字密码');
  }
}

/// Validates that [timeoutSeconds] is one of `{0, 30, 60, 300}`.
void validateLockTimeoutSeconds(int timeoutSeconds) {
  if (!allowedLockTimeouts.contains(timeoutSeconds)) {
    throw const Failure(FailureCode.validation, '锁定延迟仅支持立即、30秒、1分钟或5分钟');
  }
}

/// Generates a cryptographically random 16-byte salt.
Uint8List generatePinSaltBytes([Random? random]) {
  final rng = random ?? Random.secure();
  final bytes = Uint8List(pinSaltByteLength);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = rng.nextInt(256);
  }
  return bytes;
}

/// Encodes bytes as lowercase hexadecimal.
String bytesToHex(List<int> bytes) {
  final buf = StringBuffer();
  for (final b in bytes) {
    buf.write((b & 0xff).toRadixString(16).padLeft(2, '0'));
  }
  return buf.toString();
}

/// Decodes a hexadecimal string into raw bytes.
Uint8List hexToBytes(String hex) {
  final clean = hex.trim();
  if (clean.length.isOdd || !RegExp(r'^[0-9a-fA-F]*$').hasMatch(clean)) {
    throw _corruptLockConfig;
  }
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// Derives a 32-byte key from [pin] and [saltBytes] using standard RFC 2898
/// `PBKDF2-HMAC-SHA256` with [iterations] (`>= 10,000` rounds).
Uint8List derivePinHashBytes({
  required String pin,
  required List<int> saltBytes,
  int iterations = defaultPinHashRounds,
}) {
  if (iterations < minPinHashRounds) {
    throw const Failure(FailureCode.validation, '密码哈希迭代次数不足 10000 次');
  }
  if (saltBytes.length < pinSaltByteLength) {
    throw const Failure(FailureCode.validation, '密码盐长度必须不少于 16 字节');
  }
  final hmac = Hmac(sha256, utf8.encode(pin));
  // PBKDF2 block 1: U_1 = PRF(Password, Salt || INT_32_BE(1))
  final firstInput = Uint8List(saltBytes.length + 4)
    ..setRange(0, saltBytes.length, saltBytes)
    ..[saltBytes.length] = 0
    ..[saltBytes.length + 1] = 0
    ..[saltBytes.length + 2] = 0
    ..[saltBytes.length + 3] = 1;

  var u = hmac.convert(firstInput).bytes;
  final dk = Uint8List.fromList(u);
  for (var round = 1; round < iterations; round++) {
    u = hmac.convert(u).bytes;
    for (var j = 0; j < dk.length; j++) {
      dk[j] ^= u[j];
    }
  }
  return dk;
}

/// Constant-time byte slice equality check without early-return timing leaks.
bool constantTimeEquals(List<int> a, List<int> b) {
  var diff = a.length ^ b.length;
  final maxLen = a.length > b.length ? a.length : b.length;
  for (var i = 0; i < maxLen; i++) {
    final byteA = i < a.length ? (a[i] & 0xff) : 0;
    final byteB = i < b.length ? (b[i] & 0xff) : 0;
    diff |= byteA ^ byteB;
  }
  return diff == 0;
}

/// Constant-time hexadecimal digest equality check.
bool constantTimeHexEquals(String aHex, String bHex) {
  try {
    return constantTimeEquals(hexToBytes(aHex), hexToBytes(bHex));
  } on Failure {
    return false;
  }
}

/// Persisted App Lock configuration in `ti_preference` (`app_lock_config`).
///
/// Never stores or serializes a plaintext PIN (`docs/modules/app-lock.md` R1).
final class AppLockConfig {
  const AppLockConfig({
    this.enabled = false,
    this.pinLength = 4,
    this.saltHex = '',
    this.hashHex = '',
    this.iterations = defaultPinHashRounds,
    this.biometricEnabled = false,
    this.timeoutSeconds = 0,
    this.failedAttempts = 0,
    this.cooldownUntilMs = 0,
    this.updatedAtMs = 0,
  });

  static const AppLockConfig disabled = AppLockConfig();

  final bool enabled;
  final int pinLength;
  final String saltHex;
  final String hashHex;
  final int iterations;
  final bool biometricEnabled;
  final int timeoutSeconds;
  final int failedAttempts;
  final int cooldownUntilMs;
  final int updatedAtMs;

  bool get isConfigured =>
      enabled &&
      allowedPinLengths.contains(pinLength) &&
      saltHex.length >= pinSaltByteLength * 2 &&
      hashHex.length == pinHashByteLength * 2 &&
      iterations >= minPinHashRounds &&
      allowedLockTimeouts.contains(timeoutSeconds);

  bool isCoolingDownAt(int nowMs) => cooldownUntilMs > nowMs;

  int remainingCooldownSecondsAt(int nowMs) {
    if (nowMs >= cooldownUntilMs) return 0;
    return (cooldownUntilMs - nowMs + 999) ~/ 1000;
  }

  AppLockConfig copyWith({
    bool? enabled,
    int? pinLength,
    String? saltHex,
    String? hashHex,
    int? iterations,
    bool? biometricEnabled,
    int? timeoutSeconds,
    int? failedAttempts,
    int? cooldownUntilMs,
    int? updatedAtMs,
  }) => AppLockConfig(
    enabled: enabled ?? this.enabled,
    pinLength: pinLength ?? this.pinLength,
    saltHex: saltHex ?? this.saltHex,
    hashHex: hashHex ?? this.hashHex,
    iterations: iterations ?? this.iterations,
    biometricEnabled: biometricEnabled ?? this.biometricEnabled,
    timeoutSeconds: timeoutSeconds ?? this.timeoutSeconds,
    failedAttempts: failedAttempts ?? this.failedAttempts,
    cooldownUntilMs: cooldownUntilMs ?? this.cooldownUntilMs,
    updatedAtMs: updatedAtMs ?? this.updatedAtMs,
  );

  Map<String, Object> toJson() => <String, Object>{
    'enabled': enabled,
    'pinLength': pinLength,
    'saltHex': saltHex,
    'hashHex': hashHex,
    'iterations': iterations,
    'biometricEnabled': biometricEnabled,
    'timeoutSeconds': timeoutSeconds,
    'failedAttempts': failedAttempts,
    'cooldownUntilMs': cooldownUntilMs,
    'updatedAtMs': updatedAtMs,
  };

  String encode() => jsonEncode(toJson());

  static AppLockConfig parse(String? text) {
    if (text == null || text.trim().isEmpty) return disabled;
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw _corruptLockConfig;
    }
    if (decoded is! Map<String, Object?>) throw _corruptLockConfig;
    if (decoded.containsKey('pin') || decoded.containsKey('plaintextPin')) {
      throw _corruptLockConfig;
    }

    final enabled = decoded['enabled'];
    if (enabled is! bool) throw _corruptLockConfig;
    if (!enabled) return disabled;

    final pinLength = decoded['pinLength'];
    final saltHex = decoded['saltHex'];
    final hashHex = decoded['hashHex'];
    final iterations = decoded['iterations'];
    final biometricEnabled = decoded['biometricEnabled'] ?? false;
    final timeoutSeconds = decoded['timeoutSeconds'] ?? 0;
    final failedAttempts = decoded['failedAttempts'] ?? 0;
    final cooldownUntilMs = decoded['cooldownUntilMs'] ?? 0;
    final updatedAtMs = decoded['updatedAtMs'] ?? 0;

    if (pinLength is! int ||
        !allowedPinLengths.contains(pinLength) ||
        saltHex is! String ||
        hashHex is! String ||
        iterations is! int ||
        iterations < minPinHashRounds ||
        biometricEnabled is! bool ||
        timeoutSeconds is! int ||
        !allowedLockTimeouts.contains(timeoutSeconds) ||
        failedAttempts is! int ||
        failedAttempts < 0 ||
        cooldownUntilMs is! int ||
        cooldownUntilMs < 0 ||
        updatedAtMs is! int) {
      throw _corruptLockConfig;
    }

    final saltBytes = hexToBytes(saltHex);
    final hashBytes = hexToBytes(hashHex);
    if (saltBytes.length < pinSaltByteLength ||
        hashBytes.length != pinHashByteLength) {
      throw _corruptLockConfig;
    }

    return AppLockConfig(
      enabled: true,
      pinLength: pinLength,
      saltHex: saltHex.toLowerCase(),
      hashHex: hashHex.toLowerCase(),
      iterations: iterations,
      biometricEnabled: biometricEnabled,
      timeoutSeconds: timeoutSeconds,
      failedAttempts: failedAttempts,
      cooldownUntilMs: cooldownUntilMs,
      updatedAtMs: updatedAtMs,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppLockConfig &&
          enabled == other.enabled &&
          pinLength == other.pinLength &&
          saltHex == other.saltHex &&
          hashHex == other.hashHex &&
          iterations == other.iterations &&
          biometricEnabled == other.biometricEnabled &&
          timeoutSeconds == other.timeoutSeconds &&
          failedAttempts == other.failedAttempts &&
          cooldownUntilMs == other.cooldownUntilMs &&
          updatedAtMs == other.updatedAtMs;

  @override
  int get hashCode => Object.hash(
    enabled,
    pinLength,
    saltHex,
    hashHex,
    iterations,
    biometricEnabled,
    timeoutSeconds,
    failedAttempts,
    cooldownUntilMs,
    updatedAtMs,
  );
}

/// Builds a newly enabled [AppLockConfig] with a fresh 16-byte salt and
/// PBKDF2-HMAC-SHA256 digest (`R1`).
AppLockConfig createConfiguredAppLock({
  required String pin,
  required int nowMs,
  List<int>? saltBytes,
  int iterations = defaultPinHashRounds,
  bool biometricEnabled = false,
  int timeoutSeconds = 0,
}) {
  validatePinFormat(pin);
  validateLockTimeoutSeconds(timeoutSeconds);
  final effectiveSalt = saltBytes ?? generatePinSaltBytes();
  final hash = derivePinHashBytes(
    pin: pin,
    saltBytes: effectiveSalt,
    iterations: iterations,
  );
  return AppLockConfig(
    enabled: true,
    pinLength: pin.length,
    saltHex: bytesToHex(effectiveSalt),
    hashHex: bytesToHex(hash),
    iterations: iterations,
    biometricEnabled: biometricEnabled,
    timeoutSeconds: timeoutSeconds,
    failedAttempts: 0,
    cooldownUntilMs: 0,
    updatedAtMs: nowMs,
  );
}

/// Result of evaluating a single PIN unlock/verification attempt (`R2`, `R3`).
final class PinAttemptEvaluation {
  const PinAttemptEvaluation({
    required this.matched,
    required this.lockedOut,
    required this.remainingCooldownSeconds,
    required this.remainingAttemptsBeforeCooldown,
    required this.updatedConfig,
    required this.message,
  });

  final bool matched;
  final bool lockedOut;
  final int remainingCooldownSeconds;
  final int remainingAttemptsBeforeCooldown;
  final AppLockConfig updatedConfig;
  final String message;
}

/// Evaluates [candidatePin] against [config] at [nowMs], enforcing constant-time
/// comparison and the 5-failure 30-second cooldown rule (`R2`, `R3`).
PinAttemptEvaluation evaluatePinAttempt({
  required AppLockConfig config,
  required String candidatePin,
  required int nowMs,
}) {
  if (!config.isConfigured) {
    throw const Failure(FailureCode.validation, '应用安全锁尚未启用');
  }

  if (config.isCoolingDownAt(nowMs)) {
    final secs = config.remainingCooldownSecondsAt(nowMs);
    return PinAttemptEvaluation(
      matched: false,
      lockedOut: true,
      remainingCooldownSeconds: secs,
      remainingAttemptsBeforeCooldown: 0,
      updatedConfig: config,
      message: '密码连续错误次数过多，请等待 $secs 秒后再试',
    );
  }

  validatePinFormat(candidatePin, expectedLength: config.pinLength);

  final salt = hexToBytes(config.saltHex);
  final expectedHash = hexToBytes(config.hashHex);
  final actualHash = derivePinHashBytes(
    pin: candidatePin,
    saltBytes: salt,
    iterations: config.iterations,
  );

  if (constantTimeEquals(actualHash, expectedHash)) {
    final clean = config.copyWith(failedAttempts: 0, cooldownUntilMs: 0);
    return PinAttemptEvaluation(
      matched: true,
      lockedOut: false,
      remainingCooldownSeconds: 0,
      remainingAttemptsBeforeCooldown: maxPinFailedAttempts,
      updatedConfig: clean,
      message: '验证通过',
    );
  }

  final priorAttempts =
      config.failedAttempts >= maxPinFailedAttempts ||
          (config.cooldownUntilMs > 0 && nowMs >= config.cooldownUntilMs)
      ? 0
      : config.failedAttempts;
  final nextFailures = priorAttempts + 1;

  if (nextFailures >= maxPinFailedAttempts) {
    final until = nowMs + pinCooldownDurationMs;
    final secs = pinCooldownDurationMs ~/ 1000;
    final locked = config.copyWith(
      failedAttempts: nextFailures,
      cooldownUntilMs: until,
    );
    return PinAttemptEvaluation(
      matched: false,
      lockedOut: true,
      remainingCooldownSeconds: secs,
      remainingAttemptsBeforeCooldown: 0,
      updatedConfig: locked,
      message: '已连续输错 $maxPinFailedAttempts 次，请等待 $secs 秒后再试',
    );
  }

  final remaining = maxPinFailedAttempts - nextFailures;
  final updated = config.copyWith(
    failedAttempts: nextFailures,
    cooldownUntilMs: 0,
  );
  return PinAttemptEvaluation(
    matched: false,
    lockedOut: false,
    remainingCooldownSeconds: 0,
    remainingAttemptsBeforeCooldown: remaining,
    updatedConfig: updated,
    message: '密码不正确，还可尝试 $remaining 次',
  );
}

/// Determines whether the app must transition to locked state on cold start or
/// when resuming from background (`R4`).
bool shouldLockAfterBackground({
  required AppLockConfig config,
  required int? backgroundedAtMs,
  required int nowMs,
  bool isInitialColdStart = false,
}) {
  if (!config.isConfigured) return false;
  if (isInitialColdStart) return true;
  if (backgroundedAtMs == null) return false;
  final elapsedMs = nowMs - backgroundedAtMs;
  // Fail-closed if system clock jumped backward while backgrounded.
  if (elapsedMs < 0) return true;
  return elapsedMs >= config.timeoutSeconds * 1000;
}
