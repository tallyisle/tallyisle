import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../data/migration/cross_migration_service.dart';
import '../../platform/files.dart';
import '../reminder/reminder_providers.dart';

/// Snapshot of local database counts displayed on the cross-migration page.
final class MigrationLocalSummary {
  const MigrationLocalSummary({
    required this.bookCount,
    required this.assetCount,
    required this.recordCount,
    required this.noteCount,
  });

  final int bookCount;
  final int assetCount;
  final int recordCount;
  final int noteCount;
}

/// Injectable [FileAccess] boundary for `.ya2i` export, `.yi2a` import, and LAN `.zip`/`.db` picking.
final migrationFileAccessProvider = Provider<FileAccess>(
  (ref) => const FileAccess(),
);

/// Provides [CrossMigrationService] wired to [databaseProvider] and [reminderServiceProvider].
final crossMigrationServiceProvider = FutureProvider<CrossMigrationService>((
  ref,
) async {
  final db = await ref.watch(databaseProvider.future);
  final reminderService = await ref.watch(reminderServiceProvider.future);
  return CrossMigrationService(db, reminderService: reminderService);
});

/// Reads current local counts for books, accounts, records, and preserved local notes.
final migrationLocalSummaryProvider = FutureProvider<MigrationLocalSummary>((
  ref,
) async {
  final db = await ref.watch(databaseProvider.future);
  return _loadLocalSummary(db);
});

Future<MigrationLocalSummary> _loadLocalSummary(AppDatabase db) async {
  Future<int> countRows(TableInfo<Table, Object?> table) async {
    final countExpr = countAll();
    final query = db.selectOnly(table)..addColumns([countExpr]);
    final row = await query.getSingle();
    return row.read(countExpr) ?? 0;
  }

  final books = await countRows(db.accountBooks);
  final assets = await countRows(db.assets);
  final records = await countRows(db.records);
  final notes = await countRows(db.notes);

  return MigrationLocalSummary(
    bookCount: books,
    assetCount: assets,
    recordCount: records,
    noteCount: notes,
  );
}
