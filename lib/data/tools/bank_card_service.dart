import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../../core/failure.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/template_card_rules.dart';
import '../db/database.dart';
import '../db/failures.dart';

/// Input payload for creating or updating a bank card memo (`bank_card`).
final class BankCardDraft {
  const BankCardDraft({
    required this.cardType,
    required this.cardName,
    required this.cardNo,
    this.cardOwner = '',
    this.remark = '',
    this.cardColor,
    this.cardAssetId = noRef,
  });

  final int cardType;
  final String cardName;
  final String cardNo;
  final String cardOwner;
  final String remark;
  final String? cardColor;
  final int cardAssetId;

  List<Object?> get payload => <Object?>[
    cardType,
    cardName.trim(),
    stripCardSeparators(cardNo),
    cardOwner.trim(),
    remark.trim(),
    cardColor?.trim().toUpperCase(),
    cardAssetId,
  ];
}

/// Service and query access for the Bank Card Memo Folder (`F-023`, ADR-009).
final class BankCardService {
  BankCardService(this.db);
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

  // ---- Queries ----

  /// Watches stored bank cards, optionally filtered by `cardType`
  /// (`0` 储蓄卡 / `1` 信用卡), ordered by `sort ASC, createDate DESC, id DESC`.
  Stream<List<BankCard>> watchBankCards({int? cardType}) {
    final q = db.select(db.bankCards);
    if (cardType != null) {
      q.where((c) => c.cardType.equals(cardType));
    }
    q.orderBy([
      (c) => OrderingTerm.asc(c.sort),
      (c) => OrderingTerm.desc(c.createDate),
      (c) => OrderingTerm.desc(c.id),
    ]);
    return q.watch();
  }

  Future<List<BankCard>> getBankCards({int? cardType}) {
    final q = db.select(db.bankCards);
    if (cardType != null) {
      q.where((c) => c.cardType.equals(cardType));
    }
    q.orderBy([
      (c) => OrderingTerm.asc(c.sort),
      (c) => OrderingTerm.desc(c.createDate),
      (c) => OrderingTerm.desc(c.id),
    ]);
    return guardDatabase(q.get);
  }

  Stream<BankCard?> watchBankCard(int id) => (db.select(
    db.bankCards,
  )..where((c) => c.id.equals(id))).watchSingleOrNull();

  Future<BankCard?> getBankCard(int id) => guardDatabase(
    () => (db.select(
      db.bankCards,
    )..where((c) => c.id.equals(id))).getSingleOrNull(),
  );

  // ---- Commands ----

  /// Creates (`cardId == null`) or updates a `BankCard` row.
  /// Card numbers are normalized to digits (`8..30` digits); non-Luhn numbers
  /// are permitted (`R5`).
  Future<int> saveBankCard({
    required String commandId,
    int? cardId,
    required BankCardDraft draft,
  }) => _command(
    commandId,
    <Object?>['bank-card-save-v1', cardId, ...draft.payload],
    () async {
      final old = cardId == null ? null : await _requireCard(cardId);
      if (!BankCardType.isValid(draft.cardType)) {
        throw Failure(FailureCode.validation, '无效的银行卡类型 ${draft.cardType}');
      }
      final name = normalizeBankCardName(draft.cardName);
      final normalizedNo = normalizeBankCardNumber(draft.cardNo);
      final owner = normalizeBankCardOwner(draft.cardOwner);
      final remark = normalizeBankCardRemark(draft.remark);
      final color = normalizeCardColorHex(draft.cardColor);

      if (draft.cardAssetId != noRef) {
        final asset = await (db.select(
          db.assets,
        )..where((a) => a.id.equals(draft.cardAssetId))).getSingleOrNull();
        if (asset == null) {
          throw const Failure(FailureCode.validation, '关联的资产账户不存在');
        }
        if (asset.type == AssetType.debt) {
          throw const Failure(FailureCode.validation, '不能关联借贷账户');
        }
      }

      if (old == null) {
        final minSortRow = await db
            .customSelect('SELECT COALESCE(MIN(sort), 0) AS s FROM bank_card')
            .getSingle();
        final id = await db
            .into(db.bankCards)
            .insert(
              BankCardsCompanion.insert(
                cardType: draft.cardType,
                cardName: name,
                cardNo: normalizedNo,
                cardOwner: owner,
                remark: Value(remark),
                cardColor: Value(color),
                sort: Value(minSortRow.read<int>('s') - 1),
                createDate: _now(),
                cardAssetId: Value(draft.cardAssetId),
              ),
            );
        return '$id';
      } else {
        await (db.update(
          db.bankCards,
        )..where((c) => c.id.equals(old.id))).write(
          BankCardsCompanion(
            cardType: Value(draft.cardType),
            cardName: Value(name),
            cardNo: Value(normalizedNo),
            cardOwner: Value(owner),
            remark: Value(remark),
            cardColor: Value(color),
            cardAssetId: Value(draft.cardAssetId),
          ),
        );
        return '${old.id}';
      }
    },
    int.parse,
  );

  /// Updates `sort` order for the provided bank card IDs.
  Future<void> reorderBankCards({
    required String commandId,
    required List<int> orderedIds,
  }) => _command(
    commandId,
    <Object?>['bank-card-reorder-v1', orderedIds],
    () async {
      for (var i = 0; i < orderedIds.length; i++) {
        await (db.update(db.bankCards)
              ..where((c) => c.id.equals(orderedIds[i])))
            .write(BankCardsCompanion(sort: Value(i)));
      }
      return '${orderedIds.length}';
    },
    (_) {},
  );

  /// Deletes a `BankCard` row. Linked `Asset` rows are untouched.
  Future<void> deleteBankCard({
    required String commandId,
    required int cardId,
  }) => _command(commandId, <Object?>['bank-card-delete-v1', cardId], () async {
    await _requireCard(cardId);
    await (db.delete(db.bankCards)..where((c) => c.id.equals(cardId))).go();
    return '$cardId';
  }, (_) {});

  Future<BankCard> _requireCard(int id) async {
    final card = await (db.select(
      db.bankCards,
    )..where((c) => c.id.equals(id))).getSingleOrNull();
    if (card == null) {
      throw const Failure(FailureCode.conflict, '银行卡记录不存在或已删除');
    }
    return card;
  }
}
