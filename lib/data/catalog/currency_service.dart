import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../../core/failure.dart';
import '../../core/money.dart';
import '../../domain/rules/asset_overview.dart' show normalizeCurrency;
import '../../domain/rules/currency_rates.dart';
import '../../domain/rules/online_rate_rules.dart';
import '../../platform/files.dart';
import '../db/database.dart';
import '../db/failures.dart';
import 'exchange_rate_provider.dart';

/// Summary of an atomic online exchange-rate synchronization run.
final class OnlineRateSyncResult {
  OnlineRateSyncResult({
    required this.updatedCount,
    required List<String> updatedCodes,
    required List<String> skippedCodes,
    required this.syncedAtMs,
    required this.sourceLabel,
  }) : updatedCodes = List<String>.unmodifiable(updatedCodes),
       skippedCodes = List<String>.unmodifiable(skippedCodes);

  final int updatedCount;
  final List<String> updatedCodes;
  final List<String> skippedCodes;
  final int syncedAtMs;
  final String sourceLabel;

  Map<String, Object> toJson() => <String, Object>{
    'updatedCount': updatedCount,
    'updatedCodes': updatedCodes,
    'skippedCodes': skippedCodes,
    'syncedAtMs': syncedAtMs,
    'sourceLabel': sourceLabel,
  };

  String encode() => jsonEncode(toJson());

  static OnlineRateSyncResult parse(String raw) {
    final decoded = jsonDecode(raw) as Map<String, Object?>;
    final updatedCodes =
        (decoded['updatedCodes'] as List?)?.whereType<String>().toList() ??
        const <String>[];
    final skippedCodes =
        (decoded['skippedCodes'] as List?)?.whereType<String>().toList() ??
        const <String>[];
    return OnlineRateSyncResult(
      updatedCount: (decoded['updatedCount'] as int?) ?? updatedCodes.length,
      updatedCodes: updatedCodes,
      skippedCodes: skippedCodes,
      syncedAtMs: (decoded['syncedAtMs'] as int?) ?? 0,
      sourceLabel: (decoded['sourceLabel'] as String?) ?? '',
    );
  }
}

/// Write boundary for the `currency` table and optional privacy-first online
/// exchange rate sync (`P-03`, `ADR-009`, `ADR-011`, `ADR-017`).
final class CurrencyService {
  CurrencyService(this.db);
  final AppDatabase db;

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
                committedAt: db.nowMs(),
              ),
            );
        return result(id);
      }),
    );
  }

  /// Adds or updates a currency. [price] is "1 [code] = price CNY".
  Future<void> saveCurrency({
    required String commandId,
    required String code,
    required String name,
    required String symbol,
    required String price,
  }) => _command(
    commandId,
    ['save-currency-v1', code, name, symbol, price],
    () async {
      final c = normalizeCurrency(code);
      if (c == null || !RegExp(r'^[A-Z]{3,8}$').hasMatch(c)) {
        throw const Failure(FailureCode.validation, '币种代码须为 3–8 位英文字母');
      }
      if (c == baseCurrency) {
        throw const Failure(FailureCode.validation, '人民币是本位币，汇率固定为 1');
      }
      final n = name.trim();
      if (n.isEmpty || n.length > 30) {
        throw const Failure(FailureCode.validation, '币种名称须为 1–30 字');
      }
      final rate = rateToAnchorFromPrice(price);
      await db
          .into(db.currencies)
          .insertOnConflictUpdate(
            CurrenciesCompanion.insert(
              code: c,
              name: n,
              symbol: symbol.trim().isEmpty ? c : symbol.trim(),
              rateToAnchor: rate,
              anchorCode: baseCurrency,
              rateRefreshTime: Value(db.nowMs()),
            ),
          );
      return c;
    },
    (_) {},
  );

  /// Removes a currency no account or bill uses.
  Future<void> deleteCurrency({
    required String commandId,
    required String code,
  }) => _command(commandId, ['delete-currency-v1', code], () async {
    final c = normalizeCurrency(code);
    if (c == null || c == baseCurrency) {
      throw const Failure(FailureCode.validation, '本位币不能删除');
    }
    final assets = await db
        .customSelect(
          'SELECT COUNT(*) AS n FROM asset WHERE UPPER(TRIM(currency)) = ?',
          variables: [Variable.withString(c)],
        )
        .getSingle();
    final records = await db
        .customSelect(
          "SELECT COUNT(*) AS n FROM record WHERE "
          "json_extract(extra_info, '\$.curr.sc') = ?1 OR "
          "json_extract(extra_info, '\$.curr.ac') = ?1",
          variables: [Variable.withString(c)],
        )
        .getSingle();
    if (assets.read<int>('n') > 0 || records.read<int>('n') > 0) {
      throw const Failure(FailureCode.validation, '已有账户或账单使用该币种，不能删除');
    }
    await (db.delete(db.currencies)..where((t) => t.code.equals(c))).go();
    return c;
  }, (_) {});

  /// Reads current [OnlineRateSettings] from `ti_preference` (defaults to
  /// pure offline `enabled: false` if absent or malformed).
  Future<OnlineRateSettings> getOnlineRateSettings() =>
      guardDatabase(_readSettingsUnsafe);

  Future<OnlineRateSettings> _readSettingsUnsafe() async {
    final row =
        await (db.select(db.preferences)
              ..where((t) => t.key.equals(onlineRateSettingsPreferenceKey)))
            .getSingleOrNull();
    try {
      return OnlineRateSettings.parse(row?.value);
    } on Failure {
      return OnlineRateSettings.defaults;
    }
  }

  /// Watches [OnlineRateSettings] reactively from `ti_preference`.
  Stream<OnlineRateSettings> watchOnlineRateSettings() =>
      (db.select(db.preferences)
            ..where((t) => t.key.equals(onlineRateSettingsPreferenceKey)))
          .watchSingleOrNull()
          .map((row) {
            try {
              return OnlineRateSettings.parse(row?.value);
            } on Failure {
              return OnlineRateSettings.defaults;
            }
          });

  /// Saves validated [OnlineRateSettings] idempotently (`ADR-009`).
  Future<OnlineRateSettings> saveOnlineRateSettings({
    required String commandId,
    required OnlineRateSettings settings,
  }) {
    final normalized = settings.validated();
    return _command(
      commandId,
      ['online-rate-settings-save-v1', normalized.toJson()],
      () async {
        final encoded = normalized.encode();
        await db
            .into(db.preferences)
            .insertOnConflictUpdate(
              PreferencesCompanion.insert(
                key: onlineRateSettingsPreferenceKey,
                value: encoded,
              ),
            );
        return encoded;
      },
      OnlineRateSettings.parse,
    );
  }

  /// Synchronizes existing non-`CNY` currencies in `db.currencies` via [provider].
  ///
  /// - Refuses immediately when [provider] capability is unavailable (`enabled == false`).
  /// - Returns `updatedCount == 0` cleanly with zero network I/O when no foreign
  ///   currencies exist in `db.currencies`.
  /// - Updates only matching currencies atomically, leaves custom unquoted currencies
  ///   untouched with their manual rates, and NEVER modifies historical `record` rows.
  Future<OnlineRateSyncResult> syncOnlineRates({
    required String commandId,
    required ExchangeRateProvider provider,
  }) async {
    if (commandId.isEmpty || commandId.length > 128) {
      throw const Failure(FailureCode.validation, '提交标识无效');
    }
    final payload = <Object?>['sync-online-rates-v1', baseCurrency];
    final hash = sha256.convert(utf8.encode(jsonEncode(payload))).toString();

    final existingReceipt = await guardDatabase(
      () => (db.select(
        db.writeCommands,
      )..where((t) => t.commandId.equals(commandId))).getSingleOrNull(),
    );
    if (existingReceipt != null) {
      if (existingReceipt.payloadHash != hash) {
        throw const Failure(FailureCode.conflict, '同一提交标识的内容发生变化');
      }
      return OnlineRateSyncResult.parse(existingReceipt.resultId);
    }

    final capability = provider.capability;
    if (capability.state != CapabilityState.available) {
      throw Failure(FailureCode.unsupportedCapability, capability.reason);
    }

    final initialCurrencies = await guardDatabase(
      () => db.select(db.currencies).get(),
    );
    final hasForeignCurrencies = initialCurrencies.any((c) {
      final norm = normalizeCurrency(c.code);
      return norm != null && norm != baseCurrency;
    });

    if (!hasForeignCurrencies) {
      return _command(
        commandId,
        payload,
        () async => OnlineRateSyncResult(
          updatedCount: 0,
          updatedCodes: const <String>[],
          skippedCodes: const <String>[],
          syncedAtMs: db.nowMs(),
          sourceLabel: '',
        ).encode(),
        OnlineRateSyncResult.parse,
      );
    }

    // Perform network fetch outside SQLite write lock.
    final fetched = await provider.fetchRatesRelativeToBase(
      baseCode: baseCurrency,
    );

    return guardDatabase(
      () => db.transaction(() async {
        final previous = await (db.select(
          db.writeCommands,
        )..where((t) => t.commandId.equals(commandId))).getSingleOrNull();
        if (previous != null) {
          if (previous.payloadHash != hash) {
            throw const Failure(FailureCode.conflict, '同一提交标识的内容发生变化');
          }
          return OnlineRateSyncResult.parse(previous.resultId);
        }

        final now = db.nowMs();
        final currentCurrencies = await db.select(db.currencies).get();
        final updatedCodes = <String>[];
        final skippedCodes = <String>[];

        for (final currency in currentCurrencies) {
          final normCode = normalizeCurrency(currency.code);
          if (normCode == null || normCode == baseCurrency) continue;

          final quotedRate = fetched.ratesToAnchor[normCode];
          if (quotedRate == null) {
            skippedCodes.add(normCode);
            continue;
          }

          final verifiedDecimal = DecimalValue.parse(quotedRate);
          if (verifiedDecimal.coefficient <= BigInt.zero) {
            skippedCodes.add(normCode);
            continue;
          }

          await (db.update(
            db.currencies,
          )..where((t) => t.code.equals(currency.code))).write(
            CurrenciesCompanion(
              rateToAnchor: Value(quotedRate),
              rateRefreshTime: Value(now),
            ),
          );
          updatedCodes.add(normCode);
        }

        final currentSettings = await _readSettingsUnsafe();
        final updatedSettings = currentSettings
            .copyWith(lastSyncedAtMs: now, lastSyncSource: fetched.sourceLabel)
            .validated();
        await db
            .into(db.preferences)
            .insertOnConflictUpdate(
              PreferencesCompanion.insert(
                key: onlineRateSettingsPreferenceKey,
                value: updatedSettings.encode(),
              ),
            );

        final syncResult = OnlineRateSyncResult(
          updatedCount: updatedCodes.length,
          updatedCodes: updatedCodes,
          skippedCodes: skippedCodes,
          syncedAtMs: now,
          sourceLabel: fetched.sourceLabel,
        );
        final encodedResult = syncResult.encode();
        await db
            .into(db.writeCommands)
            .insert(
              WriteCommandsCompanion.insert(
                commandId: commandId,
                payloadHash: hash,
                resultId: encodedResult,
                committedAt: now,
              ),
            );
        return syncResult;
      }),
    );
  }

  /// Runs silent background auto-sync ONLY when `enabled && autoSyncOnLaunch`
  /// and at least 24 hours have elapsed since `lastSyncedAtMs`.
  ///
  /// Immediately returns `null` with ZERO network I/O when disabled or within
  /// cooldown, and swallows transient network/remote errors gracefully.
  Future<OnlineRateSyncResult?> runAutoSyncIfNeeded({
    required ExchangeRateProvider provider,
    String? commandId,
  }) async {
    final settings = await getOnlineRateSettings();
    final now = db.nowMs();
    if (!settings.shouldAutoSync(nowMs: now)) {
      return null;
    }
    if (provider.capability.state != CapabilityState.available) {
      return null;
    }
    final effectiveCommandId =
        commandId ?? 'auto-online-rate-sync-$now-${settings.lastSyncedAtMs}';
    try {
      return await syncOnlineRates(
        commandId: effectiveCommandId,
        provider: provider,
      );
    } on Failure {
      return null;
    } catch (_) {
      return null;
    }
  }
}
