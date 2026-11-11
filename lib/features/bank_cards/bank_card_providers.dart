import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../data/tools/bank_card_service.dart';

final bankCardServiceProvider = FutureProvider<BankCardService>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return BankCardService(db);
});

final bankCardsProvider = StreamProvider.family<List<BankCard>, int?>((
  ref,
  cardType,
) async* {
  final svc = await ref.watch(bankCardServiceProvider.future);
  yield* svc.watchBankCards(cardType: cardType);
});

final bankCardByIdProvider = StreamProvider.family<BankCard?, int>((
  ref,
  id,
) async* {
  final svc = await ref.watch(bankCardServiceProvider.future);
  yield* svc.watchBankCard(id);
});

/// Selected filter tab on `BankCardsPage` (`null` = 全部, `0` = 储蓄卡, `1` = 信用卡).
final class BankCardFilterNotifier extends Notifier<int?> {
  @override
  int? build() => null;

  void select(int? cardType) => state = cardType;
}

final bankCardFilterProvider = NotifierProvider<BankCardFilterNotifier, int?>(
  BankCardFilterNotifier.new,
);

/// Mask/unmask display state for `BankCardsPage` (masked `**** 1234` by default).
final class BankCardMaskState {
  const BankCardMaskState({
    this.maskByDefault = true,
    this.overriddenCardIds = const <int>{},
  });

  final bool maskByDefault;
  final Set<int> overriddenCardIds;

  bool isCardMasked(int cardId) => maskByDefault
      ? !overriddenCardIds.contains(cardId)
      : overriddenCardIds.contains(cardId);
}

final class BankCardMaskNotifier extends Notifier<BankCardMaskState> {
  @override
  BankCardMaskState build() => const BankCardMaskState();

  void toggleGlobal() {
    state = BankCardMaskState(maskByDefault: !state.maskByDefault);
  }

  void toggleCard(int cardId) {
    final next = <int>{...state.overriddenCardIds};
    if (!next.remove(cardId)) {
      next.add(cardId);
    }
    state = BankCardMaskState(
      maskByDefault: state.maskByDefault,
      overriddenCardIds: next,
    );
  }
}

final bankCardMaskProvider =
    NotifierProvider<BankCardMaskNotifier, BankCardMaskState>(
      BankCardMaskNotifier.new,
    );
