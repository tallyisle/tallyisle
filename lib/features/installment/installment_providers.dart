import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../data/installment/installment_service.dart';
import '../../data/repo/installment_queries.dart';

final installmentServiceProvider = FutureProvider<InstallmentService>((
  ref,
) async {
  final db = await ref.watch(databaseProvider.future);
  return InstallmentService(db);
});

final installmentQueriesProvider = FutureProvider<InstallmentQueries>((
  ref,
) async {
  final db = await ref.watch(databaseProvider.future);
  return InstallmentQueries(db);
});

/// Controls whether the installment list displays all books (`true`) or only
/// the currently active book (`false`, default).
final class InstallmentBookScopeNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;
  void setAllBooks(bool value) => state = value;
}

final installmentAllBooksProvider =
    NotifierProvider<InstallmentBookScopeNotifier, bool>(
      InstallmentBookScopeNotifier.new,
    );

final activeInstallmentsProvider = StreamProvider<List<InstallmentSummaryView>>(
  (ref) async* {
    final q = await ref.watch(installmentQueriesProvider.future);
    final allBooks = ref.watch(installmentAllBooksProvider);
    final bookId = allBooks
        ? null
        : await ref.watch(currentBookIdProvider.future);
    yield* q.watchActiveInstallments(bookId: bookId);
  },
);

final finishedInstallmentsProvider =
    StreamProvider<List<InstallmentSummaryView>>((ref) async* {
      final q = await ref.watch(installmentQueriesProvider.future);
      final allBooks = ref.watch(installmentAllBooksProvider);
      final bookId = allBooks
          ? null
          : await ref.watch(currentBookIdProvider.future);
      yield* q.watchFinishedInstallments(bookId: bookId);
    });

final installmentRowProvider = StreamProvider.family<Installment?, int>((
  ref,
  id,
) async* {
  final q = await ref.watch(installmentQueriesProvider.future);
  yield* q.watchInstallment(id);
});

final installmentRecordsProvider =
    StreamProvider.family<List<LedgerRecord>, int>((ref, id) async* {
      final q = await ref.watch(installmentQueriesProvider.future);
      yield* q.watchRecordsForInstallment(id);
    });

final installmentDetailProvider =
    Provider.family<AsyncValue<InstallmentDetailView?>, int>((ref, id) {
      final rowAsync = ref.watch(installmentRowProvider(id));
      final recordsAsync = ref.watch(installmentRecordsProvider(id));
      return switch ((rowAsync, recordsAsync)) {
        (AsyncError(:final error, :final stackTrace), _) => AsyncError(
          error,
          stackTrace,
        ),
        (_, AsyncError(:final error, :final stackTrace)) => AsyncError(
          error,
          stackTrace,
        ),
        (AsyncData(value: final row), AsyncData(value: final records)) =>
          AsyncData(
            row == null ? null : InstallmentDetailView.compose(row, records),
          ),
        _ => const AsyncLoading(),
      };
    });
