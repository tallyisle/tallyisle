import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../core/failure.dart';
import '../../domain/rules/app_settings_rules.dart';
import '../db/database.dart';
import '../db/failures.dart';

/// Persistence service for System & Home Settings (`F-038`, `ADR-009`).
final class AppSettingsService {
  AppSettingsService(this.db);
  final AppDatabase db;

  int _now() => db.nowMs();

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

  /// Reactive stream of [AppSettings] from `ti_preference`.
  Stream<AppSettings> watchSettings() =>
      (db.select(db.preferences)
            ..where((t) => t.key.equals(appSettingsPreferenceKey)))
          .watchSingleOrNull()
          .map((row) {
            try {
              return AppSettings.parse(row?.value);
            } on Failure {
              return AppSettings.defaults;
            }
          });

  /// Reads current [AppSettings] snapshot.
  Future<AppSettings> getSettings() => guardDatabase(() async {
    final row = await (db.select(
      db.preferences,
    )..where((t) => t.key.equals(appSettingsPreferenceKey))).getSingleOrNull();
    try {
      return AppSettings.parse(row?.value);
    } on Failure {
      return AppSettings.defaults;
    }
  });

  /// Saves validated [AppSettings] idempotently (`ADR-009`).
  Future<AppSettings> saveSettings({
    required String commandId,
    required AppSettings settings,
  }) async {
    final normalized = settings.validated();
    return _command(
      commandId,
      ['app-settings-save-v1', normalized.toJson()],
      () async {
        final encoded = normalized.encode();
        await db
            .into(db.preferences)
            .insertOnConflictUpdate(
              PreferencesCompanion.insert(
                key: appSettingsPreferenceKey,
                value: encoded,
              ),
            );
        return encoded;
      },
      AppSettings.parse,
    );
  }

  /// Resets all [AppSettings] fields back to defaults (`ADR-009`).
  Future<AppSettings> resetSettings({required String commandId}) =>
      saveSettings(commandId: commandId, settings: AppSettings.defaults);
}
