import 'dart:async';

import 'package:drift/drift.dart' show TableUpdate;

import '../../domain/rules/cloud_sync_rules.dart';
import '../../domain/rules/tally_backup.dart';
import 'tally_backup_service.dart';
import 'webdav_client.dart';

/// Orchestrates opt-in automatic triggers for local `.tally` backups and
/// multi-device cloud synchronization (`WebDAV` / `S3`):
/// - `db.tableUpdates()` idle debounce (`N` quiet minutes after bookkeeping writes),
///   strictly scoped to the 22 business tables and suppressed during pull/restore;
/// - Startup & desktop window-focus checks (`onAppResumedOrFocused`);
/// - Mobile background pause (`onAppPaused`) & desktop window-close exit guard
///   with bounded timeout (`onDesktopExitRequested`);
/// - Periodic background schedule timers (`Timer.periodic`) reconfigured live
///   from reactive preference streams.
final class BackupSyncScheduler {
  BackupSyncScheduler({
    required this.service,
    int Function()? nowMs,
    this.onCloudSyncOutcome,
    this.onLocalBackupCreated,
    this.onError,
    Duration Function(int minutes)? idleTimerDurationBuilder,
    Duration Function(int minutes)? scheduleTimerDurationBuilder,
  }) : _nowMs = nowMs ?? service.db.nowMs,
       _idleDurationForMinutes =
           idleTimerDurationBuilder ?? _defaultMinutesDuration,
       _scheduleDurationForMinutes =
           scheduleTimerDurationBuilder ?? _defaultMinutesDuration;

  static Duration _defaultMinutesDuration(int minutes) =>
      Duration(minutes: minutes);

  /// Exact SQL names of all 22 business tables (`ti_preference` and
  /// `ti_write_command` are intentionally excluded).
  static final Set<String> businessTableNames = Set<String>.unmodifiable(
    tallyBusinessTables,
  );

  final TallyBackupService service;
  final int Function() _nowMs;
  final void Function(CloudSyncOutcome outcome)? onCloudSyncOutcome;
  final void Function(BackupFileMetadata metadata)? onLocalBackupCreated;
  final void Function(Object error, StackTrace stackTrace)? onError;
  final Duration Function(int minutes) _idleDurationForMinutes;
  final Duration Function(int minutes) _scheduleDurationForMinutes;

  LocalAutoBackupPolicy _localPolicy = LocalAutoBackupPolicy.defaults;
  CloudSyncSettings _cloudSettings = const CloudSyncSettings(
    deviceId: 'pending',
  );

  StreamSubscription<Set<TableUpdate>>? _tableUpdatesSub;
  StreamSubscription<LocalAutoBackupPolicy>? _localPolicySub;
  StreamSubscription<CloudSyncSettings>? _cloudSettingsSub;

  Timer? _localIdleTimer;
  Timer? _cloudIdleTimer;
  Timer? _localScheduleTimer;
  Timer? _cloudScheduleTimer;

  int? _activeLocalScheduleMinutes;
  int? _activeCloudScheduleMinutes;
  CloudBackendType? _activeCloudScheduleBackend;

  int? _pendingLocalChangeAtMs;
  int? _pendingCloudChangeAtMs;

  Future<void>? _startFuture;
  bool _initialized = false;
  bool _registeredWithService = false;
  bool _disposed = false;

  bool get isDisposed => _disposed;
  int? get pendingLocalChangeAtMs => _pendingLocalChangeAtMs;
  int? get pendingCloudChangeAtMs => _pendingCloudChangeAtMs;

  /// Attaches reactive listeners to `db.tableUpdates()` and policy streams.
  /// Safe to call multiple times (idempotent).
  Future<void> start() {
    if (_disposed) return Future<void>.value();
    return _startFuture ??= _startInternal();
  }

  Future<void> _startInternal() async {
    if (_disposed) return;

    if (!_registeredWithService) {
      service.registerAttachedScheduler();
      _registeredWithService = true;
    }

    _tableUpdatesSub = service.db.tableUpdates().listen(_onTableUpdates);
    _localPolicySub = service.watchLocalAutoBackupPolicy().listen(
      _onLocalPolicyChanged,
    );
    _cloudSettingsSub = service.watchCloudSyncSettings().listen(
      _onCloudSettingsChanged,
    );

    try {
      final loadedLocal = await service.getLocalAutoBackupPolicy();
      final loadedCloud = await service.getCloudSyncSettings();
      if (_disposed) return;
      _localPolicy = loadedLocal;
      _cloudSettings = loadedCloud;
      _initialized = true;
      _reconfigureLocalScheduleTimer();
      _reconfigureCloudScheduleTimer();
    } catch (e, st) {
      _initialized = true;
      onError?.call(e, st);
    }
  }

  void _onTableUpdates(Set<TableUpdate> updates) {
    if (_disposed) return;

    final hasBusinessChange = updates.any(
      (u) => businessTableNames.contains(u.table),
    );
    if (!hasBusinessChange) {
      return;
    }

    if (service.isSuppressingTableChangeTriggers) {
      // Pull or restore just replaced the 22 business tables: never trigger
      // push/backup loops and clear any superseded pre-restore idle timers.
      _cancelLocalIdle();
      _cancelCloudIdle();
      return;
    }

    final changeAtMs = _nowMs();
    if (!_initialized && _startFuture != null) {
      unawaited(
        _startFuture!.then((_) {
          if (!_disposed && !service.isSuppressingTableChangeTriggers) {
            _scheduleIdleForBusinessChange(changeAtMs);
          }
        }),
      );
      return;
    }
    _scheduleIdleForBusinessChange(changeAtMs);
  }

  void _scheduleIdleForBusinessChange(int changeAtMs) {
    if (_localPolicy.backupOnIdle) {
      _pendingLocalChangeAtMs = changeAtMs;
      _armLocalIdleTimer(_idleDurationForMinutes(_localPolicy.idleMinutes));
    } else {
      _cancelLocalIdle();
    }

    if (_cloudSettings.syncOnIdle &&
        _cloudSettings.backend != CloudBackendType.none) {
      _pendingCloudChangeAtMs = changeAtMs;
      _armCloudIdleTimer(_idleDurationForMinutes(_cloudSettings.idleMinutes));
    } else {
      _cancelCloudIdle();
    }
  }

  void _armLocalIdleTimer(Duration duration) {
    _localIdleTimer?.cancel();
    _localIdleTimer = Timer(duration, () {
      _localIdleTimer = null;
      if (_disposed || !_localPolicy.backupOnIdle) {
        _pendingLocalChangeAtMs = null;
        return;
      }
      _pendingLocalChangeAtMs = null;
      unawaited(_triggerLocalBackup(AutoTriggerSource.idleAfterChange));
    });
  }

  void _armCloudIdleTimer(Duration duration) {
    _cloudIdleTimer?.cancel();
    _cloudIdleTimer = Timer(duration, () {
      _cloudIdleTimer = null;
      if (_disposed ||
          !_cloudSettings.syncOnIdle ||
          _cloudSettings.backend == CloudBackendType.none) {
        _pendingCloudChangeAtMs = null;
        return;
      }
      _pendingCloudChangeAtMs = null;
      unawaited(_triggerCloudSync(AutoTriggerSource.idleAfterChange));
    });
  }

  void _cancelLocalIdle() {
    _localIdleTimer?.cancel();
    _localIdleTimer = null;
    _pendingLocalChangeAtMs = null;
  }

  void _cancelCloudIdle() {
    _cloudIdleTimer?.cancel();
    _cloudIdleTimer = null;
    _pendingCloudChangeAtMs = null;
  }

  void _onLocalPolicyChanged(LocalAutoBackupPolicy nextPolicy) {
    if (_disposed) return;
    final prevIdleMinutes = _localPolicy.idleMinutes;
    _localPolicy = nextPolicy;

    if (!nextPolicy.backupOnIdle) {
      _cancelLocalIdle();
    } else if (_pendingLocalChangeAtMs != null &&
        prevIdleMinutes != nextPolicy.idleMinutes) {
      final elapsed = _nowMs() - _pendingLocalChangeAtMs!;
      if (elapsed >= nextPolicy.idleDurationMs) {
        _cancelLocalIdle();
        unawaited(_triggerLocalBackup(AutoTriggerSource.idleAfterChange));
      } else {
        _armLocalIdleTimer(
          Duration(milliseconds: nextPolicy.idleDurationMs - elapsed),
        );
      }
    }

    _reconfigureLocalScheduleTimer();
  }

  void _onCloudSettingsChanged(CloudSyncSettings nextSettings) {
    if (_disposed) return;
    final prevIdleMinutes = _cloudSettings.idleMinutes;
    _cloudSettings = nextSettings;

    if (!nextSettings.syncOnIdle ||
        nextSettings.backend == CloudBackendType.none) {
      _cancelCloudIdle();
    } else if (_pendingCloudChangeAtMs != null &&
        prevIdleMinutes != nextSettings.idleMinutes) {
      final elapsed = _nowMs() - _pendingCloudChangeAtMs!;
      if (elapsed >= nextSettings.idleDurationMs) {
        _cancelCloudIdle();
        unawaited(_triggerCloudSync(AutoTriggerSource.idleAfterChange));
      } else {
        _armCloudIdleTimer(
          Duration(milliseconds: nextSettings.idleDurationMs - elapsed),
        );
      }
    }

    _reconfigureCloudScheduleTimer();
  }

  void _reconfigureLocalScheduleTimer() {
    if (_disposed || !_localPolicy.backupOnSchedule) {
      _localScheduleTimer?.cancel();
      _localScheduleTimer = null;
      _activeLocalScheduleMinutes = null;
      return;
    }
    if (_localScheduleTimer != null &&
        _activeLocalScheduleMinutes == _localPolicy.scheduleIntervalMinutes) {
      return;
    }
    _localScheduleTimer?.cancel();
    _activeLocalScheduleMinutes = _localPolicy.scheduleIntervalMinutes;
    _localScheduleTimer = Timer.periodic(
      _scheduleDurationForMinutes(_localPolicy.scheduleIntervalMinutes),
      (_) {
        if (_disposed) return;
        unawaited(_triggerLocalBackup(AutoTriggerSource.schedule));
      },
    );
  }

  void _reconfigureCloudScheduleTimer() {
    if (_disposed ||
        !_cloudSettings.syncOnSchedule ||
        _cloudSettings.backend == CloudBackendType.none) {
      _cloudScheduleTimer?.cancel();
      _cloudScheduleTimer = null;
      _activeCloudScheduleMinutes = null;
      _activeCloudScheduleBackend = null;
      return;
    }
    if (_cloudScheduleTimer != null &&
        _activeCloudScheduleMinutes == _cloudSettings.scheduleIntervalMinutes &&
        _activeCloudScheduleBackend == _cloudSettings.backend) {
      return;
    }
    _cloudScheduleTimer?.cancel();
    _activeCloudScheduleMinutes = _cloudSettings.scheduleIntervalMinutes;
    _activeCloudScheduleBackend = _cloudSettings.backend;
    _cloudScheduleTimer = Timer.periodic(
      _scheduleDurationForMinutes(_cloudSettings.scheduleIntervalMinutes),
      (_) {
        if (_disposed) return;
        unawaited(_triggerCloudSync(AutoTriggerSource.schedule));
      },
    );
  }

  /// Handles mobile backgrounding (`AppLifecycleState.paused`).
  Future<void> onAppPaused() async {
    if (_disposed) return;
    await start();
    if (_disposed) return;

    if (_localPolicy.backupOnExit) {
      _cancelLocalIdle();
      await _triggerLocalBackup(AutoTriggerSource.exit);
    }
    if (_cloudSettings.syncOnExit &&
        _cloudSettings.backend != CloudBackendType.none) {
      _cancelCloudIdle();
      await _triggerCloudSync(AutoTriggerSource.exit);
    }
  }

  /// Handles cold start (`isInitialStartup: true`) as well as mobile foreground
  /// resume & desktop window focus (`isInitialStartup: false`).
  Future<void> onAppResumedOrFocused({required bool isInitialStartup}) async {
    if (_disposed) return;
    await start();
    if (_disposed) return;

    final now = _nowMs();
    var ranLocal = false;
    var ranCloud = false;

    // 1. Catch up overdue idle work if OS suspended background timers.
    if (_localPolicy.backupOnIdle && _pendingLocalChangeAtMs != null) {
      final elapsed = now - _pendingLocalChangeAtMs!;
      if (elapsed >= _localPolicy.idleDurationMs) {
        _cancelLocalIdle();
        await _triggerLocalBackup(AutoTriggerSource.idleAfterChange);
        ranLocal = true;
      } else {
        _armLocalIdleTimer(
          Duration(milliseconds: _localPolicy.idleDurationMs - elapsed),
        );
      }
    }

    if (_cloudSettings.syncOnIdle &&
        _cloudSettings.backend != CloudBackendType.none &&
        _pendingCloudChangeAtMs != null) {
      final elapsed = now - _pendingCloudChangeAtMs!;
      if (elapsed >= _cloudSettings.idleDurationMs) {
        _cancelCloudIdle();
        await _triggerCloudSync(AutoTriggerSource.idleAfterChange);
        ranCloud = true;
      } else {
        _armCloudIdleTimer(
          Duration(milliseconds: _cloudSettings.idleDurationMs - elapsed),
        );
      }
    }

    // 2. Run startup / windowFocus triggers if enabled.
    final source = isInitialStartup
        ? AutoTriggerSource.startup
        : AutoTriggerSource.windowFocus;

    if (!ranLocal && _localPolicy.backupOnStartup) {
      final stampBefore = _pendingLocalChangeAtMs;
      final saved = await _triggerLocalBackup(source);
      if (saved != null && _pendingLocalChangeAtMs == stampBefore) {
        _cancelLocalIdle();
      }
    }

    if (!ranCloud &&
        _cloudSettings.syncOnStartup &&
        _cloudSettings.backend != CloudBackendType.none) {
      final stampBefore = _pendingCloudChangeAtMs;
      final outcome = await _triggerCloudSync(source);
      if (outcome != null &&
          !outcome.isConflict &&
          _pendingCloudChangeAtMs == stampBefore) {
        _cancelCloudIdle();
      }
    }
  }

  /// Executes enabled exit backup/sync on desktop window close, bounded by
  /// [timeout] (default 5s) so offline or hung servers NEVER block window exit.
  Future<void> onDesktopExitRequested({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (_disposed) return;
    await start();
    if (_disposed) return;

    _cancelLocalIdle();
    _cancelCloudIdle();

    final shouldLocal = _localPolicy.backupOnExit;
    final shouldCloud =
        _cloudSettings.syncOnExit &&
        _cloudSettings.backend != CloudBackendType.none;
    if (!shouldLocal && !shouldCloud) {
      return;
    }

    final tasks = <Future<void>>[
      if (shouldLocal) _triggerLocalBackup(AutoTriggerSource.exit).then((_) {}),
      if (shouldCloud) _triggerCloudSync(AutoTriggerSource.exit).then((_) {}),
    ];

    try {
      await Future.wait(
        tasks,
      ).timeout(timeout, onTimeout: () => const <void>[]);
    } catch (_) {
      // Never allow exit backup/sync failures to block desktop window close.
    }
  }

  Future<BackupFileMetadata?> _triggerLocalBackup(
    AutoTriggerSource source,
  ) async {
    try {
      final saved = await service.runLocalAutoBackupForTrigger(source);
      if (saved != null && !_disposed) {
        onLocalBackupCreated?.call(saved);
      }
      return saved;
    } catch (e, st) {
      onError?.call(e, st);
      return null;
    }
  }

  Future<CloudSyncOutcome?> _triggerCloudSync(AutoTriggerSource source) async {
    try {
      final outcome = await service.runCloudAutoSyncForTrigger(source);
      if (outcome != null && !_disposed) {
        onCloudSyncOutcome?.call(outcome);
      }
      return outcome;
    } catch (e, st) {
      onError?.call(e, st);
      return null;
    }
  }

  /// Cancels all timers and database/preference stream subscriptions.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (_registeredWithService) {
      service.unregisterAttachedScheduler();
      _registeredWithService = false;
    }
    _cancelLocalIdle();
    _cancelCloudIdle();
    _localScheduleTimer?.cancel();
    _localScheduleTimer = null;
    _cloudScheduleTimer?.cancel();
    _cloudScheduleTimer = null;

    final f1 = _tableUpdatesSub?.cancel();
    final f2 = _localPolicySub?.cancel();
    final f3 = _cloudSettingsSub?.cancel();
    _tableUpdatesSub = null;
    _localPolicySub = null;
    _cloudSettingsSub = null;

    await Future.wait(<Future<void>>[
      if (f1 != null) f1,
      if (f2 != null) f2,
      if (f3 != null) f3,
    ]);
  }
}
