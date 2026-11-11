import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../data/deposit/fixed_deposit_service.dart';
import '../../data/repo/fixed_deposit_queries.dart';

final fixedDepositServiceProvider = FutureProvider<FixedDepositService>((
  ref,
) async {
  final db = await ref.watch(databaseProvider.future);
  return FixedDepositService(db);
});

final fixedDepositQueriesProvider = FutureProvider<FixedDepositQueries>((
  ref,
) async {
  final db = await ref.watch(databaseProvider.future);
  return FixedDepositQueries(db);
});

final eligibleDepositAssetsProvider = StreamProvider<List<Asset>>((ref) async* {
  final q = await ref.watch(fixedDepositQueriesProvider.future);
  yield* q.watchEligibleAssets();
});

final fixedDepositOverviewProvider =
    StreamProvider.family<FixedDepositOverview, int?>((ref, assetId) async* {
      final q = await ref.watch(fixedDepositQueriesProvider.future);
      yield* q.watchOverview(assetId: assetId);
    });
