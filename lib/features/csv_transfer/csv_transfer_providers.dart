import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/csv_import/csv_excel_service.dart';
import '../../data/db/database.dart';
import '../../data/repo/import_batch_queries.dart';
import '../../platform/files.dart';

/// Injectable OS file chooser / save / share boundary for CSV & Excel transfer.
final csvFileAccessProvider = Provider<FileAccess>((_) => const FileAccess());

final csvExcelServiceProvider = FutureProvider<CsvExcelService>(
  (ref) async => CsvExcelService(await ref.watch(databaseProvider.future)),
);

final importBatchQueriesProvider = FutureProvider<ImportBatchQueries>(
  (ref) async => ImportBatchQueries(await ref.watch(databaseProvider.future)),
);

final visibleImportBatchesProvider = StreamProvider<List<ImportBatchSummary>>((
  ref,
) async* {
  final q = await ref.watch(importBatchQueriesProvider.future);
  yield* q.watchBatches(hidden: false);
});

final hiddenImportBatchesProvider = StreamProvider<List<ImportBatchSummary>>((
  ref,
) async* {
  final q = await ref.watch(importBatchQueriesProvider.future);
  yield* q.watchBatches(hidden: true);
});

final importBatchProvider = StreamProvider.family<ImportPlatform?, int>((
  ref,
  batchId,
) async* {
  final q = await ref.watch(importBatchQueriesProvider.future);
  yield* q.watchBatch(batchId);
});

final importBatchRecordsProvider =
    StreamProvider.family<List<BatchRecordItem>, int>((ref, batchId) async* {
      final q = await ref.watch(importBatchQueriesProvider.future);
      yield* q.watchBatchRecords(batchId);
    });
