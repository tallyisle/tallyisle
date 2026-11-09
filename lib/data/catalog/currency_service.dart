import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../../core/failure.dart';
import '../../domain/rules/asset_overview.dart' show normalizeCurrency;
import '../../domain/rules/currency_rates.dart';
import '../db/database.dart';
import '../db/failures.dart';

/// Write boundary for the `currency` table: manual exchange rates (P-03: no
/// online rate service). Rates are stored as exact decimal strings.
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
}
