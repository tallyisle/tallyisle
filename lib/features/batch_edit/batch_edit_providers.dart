import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../data/tools/batch_record_service.dart';
import '../../domain/ledger/record_relations.dart';
import '../../domain/model/codes.dart';

export '../../data/tools/batch_record_service.dart';

final batchRecordServiceProvider = FutureProvider<BatchRecordService>(
  (ref) async => BatchRecordService(await ref.watch(databaseProvider.future)),
);

/// Streams selectable records in [bookId] newest-first (filtering out internal
/// transfer-fee children and reimbursement receipt sub-rows).
final batchBookRecordsProvider = StreamProvider.family<List<LedgerRecord>, int>(
  (ref, bookId) async* {
    final db = await ref.watch(databaseProvider.future);
    final query = db.select(db.records)
      ..where(
        (t) =>
            t.accountBookId.equals(bookId) &
            t.type.equals(RecordType.reimburseReceipt).not(),
      )
      ..orderBy([
        (t) => OrderingTerm.desc(t.recordTime),
        (t) => OrderingTerm.desc(t.createDate),
        (t) => OrderingTerm.desc(t.recordId),
      ]);
    yield* query.watch().map((rows) {
      return [
        for (final r in rows)
          if (!isTransferFeeChildRecord(
            type: r.type,
            relations: RecordRelations.parse(r.relInfo),
          ))
            r,
      ];
    });
  },
);
