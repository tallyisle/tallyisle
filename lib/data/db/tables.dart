part of 'database.dart';

// Mirrors the original Room v42 schema (docs/reference/original-schema-room-v42.sql)
// with the deliberate changes recorded in ADR-013:
//  * money REAL -> INTEGER minor units (2 decimals), column suffix `_minor`;
//  * exchange rates REAL -> decimal TEXT;
//  * cloud-sync metadata (uid / sync_time / sstatus) dropped, deletes are physical;
//  * account_book keeps only the business key `id` (Room's `_id` row id dropped).
// The original `-1` "no reference" sentinels are kept so original rules port 1:1.

@DataClassName('AccountBook')
class AccountBooks extends Table {
  @override
  String get tableName => 'account_book';
  IntColumn get id => integer()();
  IntColumn get type => integer().withDefault(const Constant(1))();
  TextColumn get name => text()();
  TextColumn get cover => text().withDefault(const Constant(''))();
  IntColumn get sort => integer().withDefault(const Constant(1))();
  IntColumn get status => integer().withDefault(const Constant(0))();
  IntColumn get startDay => integer().withDefault(const Constant(1))();
  IntColumn get createDate => integer()();
  IntColumn get displayWay => integer().withDefault(const Constant(0))();
  TextColumn get extraInfo => text().nullable()();
  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('Asset')
class Assets extends Table {
  @override
  String get tableName => 'asset';
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  Int64Column get balanceMinor => int64()();
  IntColumn get type => integer()();
  IntColumn get subType => integer().withDefault(const Constant(-1))();
  IntColumn get createDate => integer()();
  IntColumn get sort => integer().withDefault(const Constant(0))();
  TextColumn get icon => text().withDefault(const Constant(''))();
  TextColumn get remark => text().nullable()();
  Int64Column get initMoneyMinor => int64()();
  BoolColumn get isDefault => boolean().withDefault(const Constant(false))();

  /// Original semantics: 1 = counted in net worth, except for type=4 (debt)
  /// where the polarity is inverted (0 = counted). Always written explicitly.
  IntColumn get isEffectiveAsset => integer().withDefault(const Constant(1))();
  IntColumn get usedTimes => integer().withDefault(const Constant(0))();
  TextColumn get color => text().nullable()();
  IntColumn get status => integer().withDefault(const Constant(0))();
  TextColumn get extraInfo => text().nullable()();
  TextColumn get loanInfo => text().nullable()();
  TextColumn get creditInfo => text().nullable()();
  TextColumn get fixedDepositInfo => text().nullable()();
  TextColumn get groupName => text().nullable()();

  /// Null means the app base currency (original behaviour).
  TextColumn get currency => text().nullable()();
}

@DataClassName('BankCard')
class BankCards extends Table {
  @override
  String get tableName => 'bank_card';
  IntColumn get id => integer().autoIncrement()();
  IntColumn get cardType => integer()();
  TextColumn get cardName => text()();
  TextColumn get cardNo => text()();
  TextColumn get cardOwner => text()();
  TextColumn get remark => text().withDefault(const Constant(''))();
  TextColumn get cardColor => text().nullable()();
  IntColumn get sort => integer().withDefault(const Constant(-1))();
  IntColumn get createDate => integer()();
  IntColumn get cardAssetId => integer().withDefault(const Constant(-1))();
}

@DataClassName('Budget')
@TableIndex(name: 'index_budget_record_cat_id', columns: {#recordCatId})
class Budgets extends Table {
  @override
  String get tableName => 'budget';
  IntColumn get id => integer()();
  IntColumn get budgetType => integer()();
  IntColumn get recordCatId => integer()();
  Int64Column get amountMinor => int64()();
  IntColumn get bookId => integer()();
  TextColumn get section => text()();
  IntColumn get sort => integer().withDefault(const Constant(0))();
  IntColumn get createDate => integer()();
  TextColumn get remark => text().nullable()();
  TextColumn get extraInfo => text().nullable()();
  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('ImportPlatform')
class ImportPlatforms extends Table {
  @override
  String get tableName => 'import_platform';
  IntColumn get id => integer().autoIncrement()();
  TextColumn get platform => text()();
  IntColumn get importRecordCount => integer()();
  IntColumn get importCategoryCount => integer()();
  IntColumn get importTime => integer()();
  BoolColumn get hidden => boolean().withDefault(const Constant(false))();
}

@DataClassName('LedgerRecord')
@TableIndex(name: 'index_record_account_book_id', columns: {#accountBookId})
@TableIndex.sql(
  'CREATE INDEX record_book_time ON record (account_book_id, record_time DESC)',
)
@TableIndex.sql('CREATE INDEX record_asset ON record (asset_id)')
@TableIndex.sql('CREATE INDEX record_from_asset ON record (from_asset_id)')
@TableIndex.sql('CREATE INDEX record_to_asset ON record (to_asset_id)')
class Records extends Table {
  @override
  String get tableName => 'record';
  TextColumn get recordId => text()();
  IntColumn get type => integer()();
  IntColumn get subType => integer().withDefault(const Constant(-1))();
  Int64Column get moneyMinor => int64()();
  TextColumn get remark => text().withDefault(const Constant(''))();

  /// Epoch milliseconds.
  IntColumn get recordTime => integer()();
  IntColumn get recordCatId => integer().withDefault(const Constant(-1))();
  IntColumn get assetId => integer().withDefault(const Constant(-1))();
  IntColumn get fromAssetId => integer().withDefault(const Constant(-1))();
  IntColumn get toAssetId => integer().withDefault(const Constant(-1))();
  IntColumn get accountBookId => integer()();
  BoolColumn get excludeBudget =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get excludeExIn => boolean().withDefault(const Constant(false))();
  IntColumn get platformId => integer().withDefault(const Constant(-1))();
  IntColumn get periodId => integer().withDefault(const Constant(-1))();
  TextColumn get installment => text().nullable()();
  TextColumn get images => text().nullable()();
  TextColumn get relInfo => text().nullable()();
  Int64Column get discountMinor => int64().nullable()();
  TextColumn get extraInfo => text().nullable()();
  IntColumn get createDate => integer().nullable()();
  @override
  Set<Column> get primaryKey => {recordId};
}

@DataClassName('RecordCategory')
@TableIndex(
  name: 'record_category_book_parent',
  columns: {#accountBookId, #parentCatId, #sort},
)
class RecordCategories extends Table {
  @override
  String get tableName => 'record_category';
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  TextColumn get icon => text().withDefault(const Constant(''))();

  /// 0 expense, 1 income.
  IntColumn get type => integer()();
  IntColumn get sort => integer().withDefault(const Constant(0))();
  IntColumn get parentCatId => integer().withDefault(const Constant(-1))();
  TextColumn get colorFill => text().nullable()();
  IntColumn get platformId => integer().withDefault(const Constant(-1))();
  IntColumn get accountBookId => integer()();
  BoolColumn get isHide => boolean().withDefault(const Constant(false))();
  TextColumn get extraInfo => text().nullable()();
}

@DataClassName('Remark')
class Remarks extends Table {
  @override
  String get tableName => 'remark';
  IntColumn get id => integer().autoIncrement()();
  TextColumn get content => text()();
  IntColumn get recordCatId => integer()();
  IntColumn get usedTimes => integer().withDefault(const Constant(0))();
}

@DataClassName('RecordTemplate')
class RecordTemplates extends Table {
  @override
  String get tableName => 'record_template';
  IntColumn get id => integer()();
  IntColumn get type => integer()();
  TextColumn get remark => text().nullable()();
  Int64Column get moneyMinor => int64()();
  Int64Column get feeMinor => int64().withDefault(Constant(BigInt.zero))();
  IntColumn get recordCatId => integer().nullable()();
  IntColumn get assetId => integer().withDefault(const Constant(-1))();
  IntColumn get assetId2 => integer().withDefault(const Constant(-1))();
  IntColumn get sort => integer().withDefault(const Constant(0))();
  BoolColumn get autoSave => boolean().withDefault(const Constant(false))();
  IntColumn get bookId => integer()();
  BoolColumn get excludeBudget =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get excludeExIn => boolean().withDefault(const Constant(false))();
  IntColumn get createDate => integer()();
  TextColumn get tags => text().nullable()();
  TextColumn get exi => text().nullable()();
  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('Wish')
class Wishes extends Table {
  @override
  String get tableName => 'wish';
  TextColumn get id => text()();
  TextColumn get content => text()();
  Int64Column get valueMinor => int64()();
  IntColumn get createDate => integer()();
  BoolColumn get isRealized => boolean().withDefault(const Constant(false))();
  IntColumn get realizedDate => integer().withDefault(const Constant(0))();
  IntColumn get sort => integer().withDefault(const Constant(0))();
  TextColumn get icon => text().nullable()();
  IntColumn get targetDate => integer().withDefault(const Constant(0))();
  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('RecordPeriod')
class RecordPeriods extends Table {
  @override
  String get tableName => 'record_period';
  IntColumn get id => integer().autoIncrement()();
  IntColumn get recordType => integer()();
  Int64Column get moneyMinor => int64()();
  Int64Column get feeMinor => int64().withDefault(Constant(BigInt.zero))();
  TextColumn get remark => text().withDefault(const Constant(''))();
  IntColumn get catId => integer().withDefault(const Constant(-1))();
  IntColumn get assetId => integer().withDefault(const Constant(-1))();
  IntColumn get assetId2 => integer().withDefault(const Constant(-1))();
  IntColumn get bookId => integer()();
  TextColumn get images => text().nullable()();
  IntColumn get state => integer().withDefault(const Constant(0))();
  TextColumn get time => text().nullable()();
  BoolColumn get excludeBudget =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get excludeExIn => boolean().withDefault(const Constant(false))();
  IntColumn get periodType => integer()();
  TextColumn get periodTypeDate => text()();
  IntColumn get periodStartDate => integer()();
  IntColumn get periodEndDate => integer()();
  IntColumn get frequency => integer().withDefault(const Constant(1))();
  IntColumn get lastAddDate => integer().withDefault(const Constant(-1))();
  IntColumn get periodAddTimes => integer().withDefault(const Constant(0))();
  IntColumn get createTime => integer()();
  TextColumn get tags => text().nullable()();
  TextColumn get exi => text().nullable()();
}

@DataClassName('ReminderEvent')
class ReminderEvents extends Table {
  @override
  String get tableName => 'reminder_event';
  IntColumn get id => integer().autoIncrement()();
  IntColumn get reminderTime => integer()();
  TextColumn get reminderTip => text().nullable()();
}

@DataClassName('Installment')
class Installments extends Table {
  @override
  String get tableName => 'installment';
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  IntColumn get catId => integer().withDefault(const Constant(-1))();
  Int64Column get principalMinor => int64()();
  IntColumn get periods => integer()();
  Int64Column get chargeMinor => int64()();
  IntColumn get chargeWay => integer()();
  IntColumn get remainderIn => integer()();
  IntColumn get calWay => integer()();
  IntColumn get startDate => integer()();
  IntColumn get assetId => integer()();
  IntColumn get nextPeriod => integer()();
  IntColumn get nextPeriodDate => integer()();
  TextColumn get credited => text().nullable()();
  IntColumn get bookId => integer()();
  BoolColumn get excludeBudget =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get excludeExIn => boolean().withDefault(const Constant(false))();
  IntColumn get createDate => integer()();
  TextColumn get tags => text().nullable()();
  TextColumn get images => text().nullable()();
  TextColumn get exi => text().nullable()();
}

@DataClassName('Note')
class Notes extends Table {
  @override
  String get tableName => 'note';
  IntColumn get id => integer().autoIncrement()();
  TextColumn get title => text().nullable()();
  TextColumn get content => text()();
  IntColumn get createTime => integer()();
  IntColumn get updateTime => integer()();
  IntColumn get trashTime => integer().withDefault(const Constant(0))();
}

@DataClassName('Tag')
class Tags extends Table {
  @override
  String get tableName => 'tag';
  TextColumn get tagId => text()();
  TextColumn get name => text()();
  IntColumn get sort => integer().withDefault(const Constant(0))();
  BoolColumn get hidden => boolean().withDefault(const Constant(false))();
  TextColumn get parentTagId => text().nullable()();
  IntColumn get parent => integer().withDefault(const Constant(0))();
  TextColumn get color => text().nullable()();
  TextColumn get extraInfo => text().nullable()();
  @override
  Set<Column> get primaryKey => {tagId};
}

@DataClassName('TagRecord')
@TableIndex(name: 'index_tag_record_record_id', columns: {#recordId})
class TagRecords extends Table {
  @override
  String get tableName => 'tag_record';
  TextColumn get tagId => text()();
  TextColumn get recordId => text()();
  @override
  Set<Column> get primaryKey => {tagId, recordId};
}

@DataClassName('MoneySavePlan')
class MoneySavePlans extends Table {
  @override
  String get tableName => 'money_save_plan';
  IntColumn get id => integer()();
  TextColumn get name => text()();
  TextColumn get remark => text().withDefault(const Constant(''))();
  IntColumn get planType => integer()();
  IntColumn get cycleType => integer()();
  IntColumn get startDate => integer()();
  IntColumn get endDate => integer()();
  Int64Column get planMoneyMinor => int64()();
  Int64Column get savedMoneyMinor => int64()();
  BoolColumn get autoPlan => boolean().withDefault(const Constant(false))();
  IntColumn get fromAssetId => integer().withDefault(const Constant(-1))();
  IntColumn get toAssetId => integer().withDefault(const Constant(-1))();
  IntColumn get bookId => integer().withDefault(const Constant(-1))();
  Int64Column get startMoneyMinor => int64()();
  Int64Column get incrementalMinor => int64()();
  IntColumn get status => integer().withDefault(const Constant(0))();
  IntColumn get createDate => integer()();
  IntColumn get sort => integer().withDefault(const Constant(0))();
  IntColumn get nextSaveDate => integer()();
  IntColumn get bbzDailyTimes => integer().withDefault(const Constant(0))();
  TextColumn get icon => text().nullable()();
  TextColumn get extraInfo => text().nullable()();
  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('MoneySavePlanRecord')
class MoneySavePlanRecords extends Table {
  @override
  String get tableName => 'money_save_plan_record';
  IntColumn get id => integer()();
  IntColumn get planId => integer()();
  TextColumn get remark => text().withDefault(const Constant(''))();
  IntColumn get fromAssetId => integer().withDefault(const Constant(-1))();
  IntColumn get toAssetId => integer().withDefault(const Constant(-1))();
  IntColumn get recordDate => integer()();
  Int64Column get recordMoneyMinor => int64()();
  TextColumn get recordId => text().nullable()();
  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('AssetBook')
class AssetBooks extends Table {
  @override
  String get tableName => 'asset_book';
  IntColumn get assetId => integer()();
  IntColumn get bookId => integer()();
  @override
  Set<Column> get primaryKey => {assetId, bookId};
}

@DataClassName('StatStory')
class StatStories extends Table {
  @override
  String get tableName => 'stat_story';
  TextColumn get id => text()();
  TextColumn get story => text()();
  IntColumn get bookId => integer()();
  IntColumn get sdate => integer()();
  IntColumn get edate => integer()();
  TextColumn get dsection => text().nullable()();
  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('AutoMap')
class AutoMaps extends Table {
  @override
  String get tableName => 'auto_map';
  IntColumn get id => integer().autoIncrement()();
  TextColumn get key => text()();
  TextColumn get mapInfo => text().nullable()();
  TextColumn get draft => text().nullable()();
}

@DataClassName('Currency')
class Currencies extends Table {
  @override
  String get tableName => 'currency';
  TextColumn get code => text()();
  TextColumn get name => text()();
  TextColumn get symbol => text()();
  IntColumn get type => integer().withDefault(const Constant(0))();

  /// Decimal string, never REAL (ADR-011).
  TextColumn get rateToAnchor => text()();
  TextColumn get anchorCode => text()();
  IntColumn get rateRefreshTime => integer().withDefault(const Constant(0))();
  TextColumn get icon => text().nullable()();
  BoolColumn get enable => boolean().withDefault(const Constant(true))();
  @override
  Set<Column> get primaryKey => {code};
}

// ---- TallyIsle-only tables ----

/// Idempotent write receipts (ADR-009).
@DataClassName('WriteCommand')
class WriteCommands extends Table {
  @override
  String get tableName => 'ti_write_command';
  TextColumn get commandId => text()();
  TextColumn get payloadHash => text()();
  TextColumn get resultId => text()();
  IntColumn get committedAt => integer()();
  @override
  Set<Column> get primaryKey => {commandId};
}

/// Key/value preferences (replaces the original MMKV store).
@DataClassName('Preference')
class Preferences extends Table {
  @override
  String get tableName => 'ti_preference';
  TextColumn get key => text()();
  TextColumn get value => text()();
  @override
  Set<Column> get primaryKey => {key};
}
