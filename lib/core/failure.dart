enum FailureCode {
  validation,
  scaleMismatch,
  conflict,
  storageUnavailable,
  storageFull,
  corruptData,
  migrationFailed,
  upgradeRequired,
  permissionDenied,
  unsupportedCapability,
  remoteUnavailable,
  authRequired,
  cancelled,
}

/// Carries a safe message. Database errors, payloads and credentials stay out of UI.
final class Failure implements Exception {
  const Failure(this.code, this.message);
  final FailureCode code;
  final String message;
  @override
  String toString() => 'TALLYISLE_FAILURE:${code.name}';
}
