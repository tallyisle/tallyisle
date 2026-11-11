import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../data/periodic/periodic_service.dart';
import '../../data/repo/periodic_queries.dart';
import '../../domain/rules/periodic_records.dart';

final periodicServiceProvider = FutureProvider<PeriodicService>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return PeriodicService(db);
});

final periodicQueriesProvider = FutureProvider<PeriodicQueries>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return PeriodicQueries(db);
});

/// Selected tab state (`0` 进行中, `1` 已结束, `2` 已停用).
final class PeriodicTabNotifier extends Notifier<int> {
  @override
  int build() => PeriodState.active;

  void select(int tab) => state = tab;
}

final periodicTabProvider = NotifierProvider<PeriodicTabNotifier, int>(
  PeriodicTabNotifier.new,
);

final periodicRulesByStateProvider =
    StreamProvider.family<List<RecordPeriod>, int>((ref, state) async* {
      final q = await ref.watch(periodicQueriesProvider.future);
      yield* q.watchPeriodsByState(state);
    });

final periodicStateCountsProvider = StreamProvider<PeriodStateCounts>((
  ref,
) async* {
  final q = await ref.watch(periodicQueriesProvider.future);
  yield* q.watchStateCounts();
});

final periodicRuleProvider = StreamProvider.family<RecordPeriod?, int>((
  ref,
  id,
) async* {
  final q = await ref.watch(periodicQueriesProvider.future);
  yield* q.watchPeriod(id);
});

final periodicHistoryProvider = StreamProvider.family<List<LedgerRecord>, int>((
  ref,
  periodId,
) async* {
  final q = await ref.watch(periodicQueriesProvider.future);
  yield* q.watchHistoryRecords(periodId);
});

final periodicAllCategoriesProvider = StreamProvider<List<RecordCategory>>((
  ref,
) async* {
  final q = await ref.watch(periodicQueriesProvider.future);
  yield* q.watchAllCategories();
});
