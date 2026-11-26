import 'package:drift/drift.dart';

import '../../core/failure.dart';
import 'seed.dart';

part 'tables.dart';
part 'database.g.dart';

@DriftDatabase(
  tables: [
    AccountBooks,
    Assets,
    BankCards,
    Budgets,
    ImportPlatforms,
    Records,
    RecordCategories,
    Remarks,
    RecordTemplates,
    Wishes,
    RecordPeriods,
    ReminderEvents,
    Installments,
    Notes,
    Tags,
    TagRecords,
    MoneySavePlans,
    MoneySavePlanRecords,
    AssetBooks,
    StatStories,
    AutoMaps,
    Currencies,
    WriteCommands,
    Preferences,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.executor, {int Function()? nowMs})
    : nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final int Function() nowMs;

  /// Schema lock policy (ADR-013): the 24 SQLite tables and column definitions
  /// are strictly frozen; never alter schema without explicit user approval and
  /// a complete compatibility migration plan.
  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await seedDefaults(this, nowMs());
    },
    onUpgrade: (m, from, to) async {
      if (from > to) {
        throw const Failure(FailureCode.upgradeRequired, '数据库版本较新，请使用更新的应用');
      }
      throw const Failure(FailureCode.migrationFailed, '没有可用的数据库升级路径，原库已保留');
    },
  );
}
