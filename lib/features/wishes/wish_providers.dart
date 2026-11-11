import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../data/tools/wish_service.dart';
import '../../domain/rules/wish_note_rules.dart';

final wishServiceProvider = FutureProvider<WishService>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return WishService(db);
});

final allWishesProvider = StreamProvider<List<Wish>>((ref) async* {
  final service = await ref.watch(wishServiceProvider.future);
  yield* service.watchAllWishes();
});

final unrealizedWishesProvider = StreamProvider<List<Wish>>((ref) async* {
  final service = await ref.watch(wishServiceProvider.future);
  yield* service.watchUnrealizedWishes();
});

final realizedWishesProvider = StreamProvider<List<Wish>>((ref) async* {
  final service = await ref.watch(wishServiceProvider.future);
  yield* service.watchRealizedWishes();
});

final wishProvider = StreamProvider.family<Wish?, String>((ref, id) async* {
  final service = await ref.watch(wishServiceProvider.future);
  yield* service.watchWish(id);
});

final wishSummaryProvider = Provider<AsyncValue<WishSummary>>((ref) {
  final allAsync = ref.watch(allWishesProvider);
  return allAsync.whenData(
    (wishes) => summarizeWishes(
      wishes,
      isRealizedOf: (w) => w.isRealized,
      valueMinorOf: (w) => w.valueMinor,
    ),
  );
});

IconData wishIconData(String? key) => switch (key?.trim()) {
  'gift' => Icons.card_giftcard,
  'digital' => Icons.devices,
  'travel' => Icons.flight_takeoff,
  'clothes' => Icons.checkroom,
  'home' => Icons.weekend_outlined,
  'book' => Icons.menu_book,
  'sport' => Icons.fitness_center,
  'food' => Icons.restaurant,
  'saving' => Icons.savings_outlined,
  'star' || _ => Icons.auto_awesome,
};

String wishIconLabel(String? key) {
  final normalized = key?.trim();
  for (final option in presetWishIcons) {
    if (option.key == normalized) return option.label;
  }
  return (normalized == null || normalized.isEmpty) ? '星标' : normalized;
}
