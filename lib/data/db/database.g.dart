// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class $AccountBooksTable extends AccountBooks
    with TableInfo<$AccountBooksTable, AccountBook> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AccountBooksTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<int> type = GeneratedColumn<int>(
    'type',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(1),
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _coverMeta = const VerificationMeta('cover');
  @override
  late final GeneratedColumn<String> cover = GeneratedColumn<String>(
    'cover',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _sortMeta = const VerificationMeta('sort');
  @override
  late final GeneratedColumn<int> sort = GeneratedColumn<int>(
    'sort',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(1),
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<int> status = GeneratedColumn<int>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _startDayMeta = const VerificationMeta(
    'startDay',
  );
  @override
  late final GeneratedColumn<int> startDay = GeneratedColumn<int>(
    'start_day',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(1),
  );
  static const VerificationMeta _createDateMeta = const VerificationMeta(
    'createDate',
  );
  @override
  late final GeneratedColumn<int> createDate = GeneratedColumn<int>(
    'create_date',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _displayWayMeta = const VerificationMeta(
    'displayWay',
  );
  @override
  late final GeneratedColumn<int> displayWay = GeneratedColumn<int>(
    'display_way',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _extraInfoMeta = const VerificationMeta(
    'extraInfo',
  );
  @override
  late final GeneratedColumn<String> extraInfo = GeneratedColumn<String>(
    'extra_info',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    type,
    name,
    cover,
    sort,
    status,
    startDay,
    createDate,
    displayWay,
    extraInfo,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'account_book';
  @override
  VerificationContext validateIntegrity(
    Insertable<AccountBook> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('type')) {
      context.handle(
        _typeMeta,
        type.isAcceptableOrUnknown(data['type']!, _typeMeta),
      );
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('cover')) {
      context.handle(
        _coverMeta,
        cover.isAcceptableOrUnknown(data['cover']!, _coverMeta),
      );
    }
    if (data.containsKey('sort')) {
      context.handle(
        _sortMeta,
        sort.isAcceptableOrUnknown(data['sort']!, _sortMeta),
      );
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    }
    if (data.containsKey('start_day')) {
      context.handle(
        _startDayMeta,
        startDay.isAcceptableOrUnknown(data['start_day']!, _startDayMeta),
      );
    }
    if (data.containsKey('create_date')) {
      context.handle(
        _createDateMeta,
        createDate.isAcceptableOrUnknown(data['create_date']!, _createDateMeta),
      );
    } else if (isInserting) {
      context.missing(_createDateMeta);
    }
    if (data.containsKey('display_way')) {
      context.handle(
        _displayWayMeta,
        displayWay.isAcceptableOrUnknown(data['display_way']!, _displayWayMeta),
      );
    }
    if (data.containsKey('extra_info')) {
      context.handle(
        _extraInfoMeta,
        extraInfo.isAcceptableOrUnknown(data['extra_info']!, _extraInfoMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  AccountBook map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AccountBook(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      type: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}type'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      cover: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}cover'],
      )!,
      sort: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}status'],
      )!,
      startDay: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}start_day'],
      )!,
      createDate: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}create_date'],
      )!,
      displayWay: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}display_way'],
      )!,
      extraInfo: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}extra_info'],
      ),
    );
  }

  @override
  $AccountBooksTable createAlias(String alias) {
    return $AccountBooksTable(attachedDatabase, alias);
  }
}

class AccountBook extends DataClass implements Insertable<AccountBook> {
  final int id;
  final int type;
  final String name;
  final String cover;
  final int sort;
  final int status;
  final int startDay;
  final int createDate;
  final int displayWay;
  final String? extraInfo;
  const AccountBook({
    required this.id,
    required this.type,
    required this.name,
    required this.cover,
    required this.sort,
    required this.status,
    required this.startDay,
    required this.createDate,
    required this.displayWay,
    this.extraInfo,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['type'] = Variable<int>(type);
    map['name'] = Variable<String>(name);
    map['cover'] = Variable<String>(cover);
    map['sort'] = Variable<int>(sort);
    map['status'] = Variable<int>(status);
    map['start_day'] = Variable<int>(startDay);
    map['create_date'] = Variable<int>(createDate);
    map['display_way'] = Variable<int>(displayWay);
    if (!nullToAbsent || extraInfo != null) {
      map['extra_info'] = Variable<String>(extraInfo);
    }
    return map;
  }

  AccountBooksCompanion toCompanion(bool nullToAbsent) {
    return AccountBooksCompanion(
      id: Value(id),
      type: Value(type),
      name: Value(name),
      cover: Value(cover),
      sort: Value(sort),
      status: Value(status),
      startDay: Value(startDay),
      createDate: Value(createDate),
      displayWay: Value(displayWay),
      extraInfo: extraInfo == null && nullToAbsent
          ? const Value.absent()
          : Value(extraInfo),
    );
  }

  factory AccountBook.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AccountBook(
      id: serializer.fromJson<int>(json['id']),
      type: serializer.fromJson<int>(json['type']),
      name: serializer.fromJson<String>(json['name']),
      cover: serializer.fromJson<String>(json['cover']),
      sort: serializer.fromJson<int>(json['sort']),
      status: serializer.fromJson<int>(json['status']),
      startDay: serializer.fromJson<int>(json['startDay']),
      createDate: serializer.fromJson<int>(json['createDate']),
      displayWay: serializer.fromJson<int>(json['displayWay']),
      extraInfo: serializer.fromJson<String?>(json['extraInfo']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'type': serializer.toJson<int>(type),
      'name': serializer.toJson<String>(name),
      'cover': serializer.toJson<String>(cover),
      'sort': serializer.toJson<int>(sort),
      'status': serializer.toJson<int>(status),
      'startDay': serializer.toJson<int>(startDay),
      'createDate': serializer.toJson<int>(createDate),
      'displayWay': serializer.toJson<int>(displayWay),
      'extraInfo': serializer.toJson<String?>(extraInfo),
    };
  }

  AccountBook copyWith({
    int? id,
    int? type,
    String? name,
    String? cover,
    int? sort,
    int? status,
    int? startDay,
    int? createDate,
    int? displayWay,
    Value<String?> extraInfo = const Value.absent(),
  }) => AccountBook(
    id: id ?? this.id,
    type: type ?? this.type,
    name: name ?? this.name,
    cover: cover ?? this.cover,
    sort: sort ?? this.sort,
    status: status ?? this.status,
    startDay: startDay ?? this.startDay,
    createDate: createDate ?? this.createDate,
    displayWay: displayWay ?? this.displayWay,
    extraInfo: extraInfo.present ? extraInfo.value : this.extraInfo,
  );
  AccountBook copyWithCompanion(AccountBooksCompanion data) {
    return AccountBook(
      id: data.id.present ? data.id.value : this.id,
      type: data.type.present ? data.type.value : this.type,
      name: data.name.present ? data.name.value : this.name,
      cover: data.cover.present ? data.cover.value : this.cover,
      sort: data.sort.present ? data.sort.value : this.sort,
      status: data.status.present ? data.status.value : this.status,
      startDay: data.startDay.present ? data.startDay.value : this.startDay,
      createDate: data.createDate.present
          ? data.createDate.value
          : this.createDate,
      displayWay: data.displayWay.present
          ? data.displayWay.value
          : this.displayWay,
      extraInfo: data.extraInfo.present ? data.extraInfo.value : this.extraInfo,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AccountBook(')
          ..write('id: $id, ')
          ..write('type: $type, ')
          ..write('name: $name, ')
          ..write('cover: $cover, ')
          ..write('sort: $sort, ')
          ..write('status: $status, ')
          ..write('startDay: $startDay, ')
          ..write('createDate: $createDate, ')
          ..write('displayWay: $displayWay, ')
          ..write('extraInfo: $extraInfo')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    type,
    name,
    cover,
    sort,
    status,
    startDay,
    createDate,
    displayWay,
    extraInfo,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AccountBook &&
          other.id == this.id &&
          other.type == this.type &&
          other.name == this.name &&
          other.cover == this.cover &&
          other.sort == this.sort &&
          other.status == this.status &&
          other.startDay == this.startDay &&
          other.createDate == this.createDate &&
          other.displayWay == this.displayWay &&
          other.extraInfo == this.extraInfo);
}

class AccountBooksCompanion extends UpdateCompanion<AccountBook> {
  final Value<int> id;
  final Value<int> type;
  final Value<String> name;
  final Value<String> cover;
  final Value<int> sort;
  final Value<int> status;
  final Value<int> startDay;
  final Value<int> createDate;
  final Value<int> displayWay;
  final Value<String?> extraInfo;
  const AccountBooksCompanion({
    this.id = const Value.absent(),
    this.type = const Value.absent(),
    this.name = const Value.absent(),
    this.cover = const Value.absent(),
    this.sort = const Value.absent(),
    this.status = const Value.absent(),
    this.startDay = const Value.absent(),
    this.createDate = const Value.absent(),
    this.displayWay = const Value.absent(),
    this.extraInfo = const Value.absent(),
  });
  AccountBooksCompanion.insert({
    this.id = const Value.absent(),
    this.type = const Value.absent(),
    required String name,
    this.cover = const Value.absent(),
    this.sort = const Value.absent(),
    this.status = const Value.absent(),
    this.startDay = const Value.absent(),
    required int createDate,
    this.displayWay = const Value.absent(),
    this.extraInfo = const Value.absent(),
  }) : name = Value(name),
       createDate = Value(createDate);
  static Insertable<AccountBook> custom({
    Expression<int>? id,
    Expression<int>? type,
    Expression<String>? name,
    Expression<String>? cover,
    Expression<int>? sort,
    Expression<int>? status,
    Expression<int>? startDay,
    Expression<int>? createDate,
    Expression<int>? displayWay,
    Expression<String>? extraInfo,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (type != null) 'type': type,
      if (name != null) 'name': name,
      if (cover != null) 'cover': cover,
      if (sort != null) 'sort': sort,
      if (status != null) 'status': status,
      if (startDay != null) 'start_day': startDay,
      if (createDate != null) 'create_date': createDate,
      if (displayWay != null) 'display_way': displayWay,
      if (extraInfo != null) 'extra_info': extraInfo,
    });
  }

  AccountBooksCompanion copyWith({
    Value<int>? id,
    Value<int>? type,
    Value<String>? name,
    Value<String>? cover,
    Value<int>? sort,
    Value<int>? status,
    Value<int>? startDay,
    Value<int>? createDate,
    Value<int>? displayWay,
    Value<String?>? extraInfo,
  }) {
    return AccountBooksCompanion(
      id: id ?? this.id,
      type: type ?? this.type,
      name: name ?? this.name,
      cover: cover ?? this.cover,
      sort: sort ?? this.sort,
      status: status ?? this.status,
      startDay: startDay ?? this.startDay,
      createDate: createDate ?? this.createDate,
      displayWay: displayWay ?? this.displayWay,
      extraInfo: extraInfo ?? this.extraInfo,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (type.present) {
      map['type'] = Variable<int>(type.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (cover.present) {
      map['cover'] = Variable<String>(cover.value);
    }
    if (sort.present) {
      map['sort'] = Variable<int>(sort.value);
    }
    if (status.present) {
      map['status'] = Variable<int>(status.value);
    }
    if (startDay.present) {
      map['start_day'] = Variable<int>(startDay.value);
    }
    if (createDate.present) {
      map['create_date'] = Variable<int>(createDate.value);
    }
    if (displayWay.present) {
      map['display_way'] = Variable<int>(displayWay.value);
    }
    if (extraInfo.present) {
      map['extra_info'] = Variable<String>(extraInfo.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AccountBooksCompanion(')
          ..write('id: $id, ')
          ..write('type: $type, ')
          ..write('name: $name, ')
          ..write('cover: $cover, ')
          ..write('sort: $sort, ')
          ..write('status: $status, ')
          ..write('startDay: $startDay, ')
          ..write('createDate: $createDate, ')
          ..write('displayWay: $displayWay, ')
          ..write('extraInfo: $extraInfo')
          ..write(')'))
        .toString();
  }
}

class $AssetsTable extends Assets with TableInfo<$AssetsTable, Asset> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AssetsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _balanceMinorMeta = const VerificationMeta(
    'balanceMinor',
  );
  @override
  late final GeneratedColumn<BigInt> balanceMinor = GeneratedColumn<BigInt>(
    'balance_minor',
    aliasedName,
    false,
    type: DriftSqlType.bigInt,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<int> type = GeneratedColumn<int>(
    'type',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _subTypeMeta = const VerificationMeta(
    'subType',
  );
  @override
  late final GeneratedColumn<int> subType = GeneratedColumn<int>(
    'sub_type',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(-1),
  );
  static const VerificationMeta _createDateMeta = const VerificationMeta(
    'createDate',
  );
  @override
  late final GeneratedColumn<int> createDate = GeneratedColumn<int>(
    'create_date',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sortMeta = const VerificationMeta('sort');
  @override
  late final GeneratedColumn<int> sort = GeneratedColumn<int>(
    'sort',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _iconMeta = const VerificationMeta('icon');
  @override
  late final GeneratedColumn<String> icon = GeneratedColumn<String>(
    'icon',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _remarkMeta = const VerificationMeta('remark');
  @override
  late final GeneratedColumn<String> remark = GeneratedColumn<String>(
    'remark',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _initMoneyMinorMeta = const VerificationMeta(
    'initMoneyMinor',
  );
  @override
  late final GeneratedColumn<BigInt> initMoneyMinor = GeneratedColumn<BigInt>(
    'init_money_minor',
    aliasedName,
    false,
    type: DriftSqlType.bigInt,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _isDefaultMeta = const VerificationMeta(
    'isDefault',
  );
  @override
  late final GeneratedColumn<bool> isDefault = GeneratedColumn<bool>(
    'is_default',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_default" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _isEffectiveAssetMeta = const VerificationMeta(
    'isEffectiveAsset',
  );
  @override
  late final GeneratedColumn<int> isEffectiveAsset = GeneratedColumn<int>(
    'is_effective_asset',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(1),
  );
  static const VerificationMeta _usedTimesMeta = const VerificationMeta(
    'usedTimes',
  );
  @override
  late final GeneratedColumn<int> usedTimes = GeneratedColumn<int>(
    'used_times',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _colorMeta = const VerificationMeta('color');
  @override
  late final GeneratedColumn<String> color = GeneratedColumn<String>(
    'color',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<int> status = GeneratedColumn<int>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _extraInfoMeta = const VerificationMeta(
    'extraInfo',
  );
  @override
  late final GeneratedColumn<String> extraInfo = GeneratedColumn<String>(
    'extra_info',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _loanInfoMeta = const VerificationMeta(
    'loanInfo',
  );
  @override
  late final GeneratedColumn<String> loanInfo = GeneratedColumn<String>(
    'loan_info',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _creditInfoMeta = const VerificationMeta(
    'creditInfo',
  );
  @override
  late final GeneratedColumn<String> creditInfo = GeneratedColumn<String>(
    'credit_info',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _fixedDepositInfoMeta = const VerificationMeta(
    'fixedDepositInfo',
  );
  @override
  late final GeneratedColumn<String> fixedDepositInfo = GeneratedColumn<String>(
    'fixed_deposit_info',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _groupNameMeta = const VerificationMeta(
    'groupName',
  );
  @override
  late final GeneratedColumn<String> groupName = GeneratedColumn<String>(
    'group_name',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _currencyMeta = const VerificationMeta(
    'currency',
  );
  @override
  late final GeneratedColumn<String> currency = GeneratedColumn<String>(
    'currency',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    balanceMinor,
    type,
    subType,
    createDate,
    sort,
    icon,
    remark,
    initMoneyMinor,
    isDefault,
    isEffectiveAsset,
    usedTimes,
    color,
    status,
    extraInfo,
    loanInfo,
    creditInfo,
    fixedDepositInfo,
    groupName,
    currency,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'asset';
  @override
  VerificationContext validateIntegrity(
    Insertable<Asset> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('balance_minor')) {
      context.handle(
        _balanceMinorMeta,
        balanceMinor.isAcceptableOrUnknown(
          data['balance_minor']!,
          _balanceMinorMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_balanceMinorMeta);
    }
    if (data.containsKey('type')) {
      context.handle(
        _typeMeta,
        type.isAcceptableOrUnknown(data['type']!, _typeMeta),
      );
    } else if (isInserting) {
      context.missing(_typeMeta);
    }
    if (data.containsKey('sub_type')) {
      context.handle(
        _subTypeMeta,
        subType.isAcceptableOrUnknown(data['sub_type']!, _subTypeMeta),
      );
    }
    if (data.containsKey('create_date')) {
      context.handle(
        _createDateMeta,
        createDate.isAcceptableOrUnknown(data['create_date']!, _createDateMeta),
      );
    } else if (isInserting) {
      context.missing(_createDateMeta);
    }
    if (data.containsKey('sort')) {
      context.handle(
        _sortMeta,
        sort.isAcceptableOrUnknown(data['sort']!, _sortMeta),
      );
    }
    if (data.containsKey('icon')) {
      context.handle(
        _iconMeta,
        icon.isAcceptableOrUnknown(data['icon']!, _iconMeta),
      );
    }
    if (data.containsKey('remark')) {
      context.handle(
        _remarkMeta,
        remark.isAcceptableOrUnknown(data['remark']!, _remarkMeta),
      );
    }
    if (data.containsKey('init_money_minor')) {
      context.handle(
        _initMoneyMinorMeta,
        initMoneyMinor.isAcceptableOrUnknown(
          data['init_money_minor']!,
          _initMoneyMinorMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_initMoneyMinorMeta);
    }
    if (data.containsKey('is_default')) {
      context.handle(
        _isDefaultMeta,
        isDefault.isAcceptableOrUnknown(data['is_default']!, _isDefaultMeta),
      );
    }
    if (data.containsKey('is_effective_asset')) {
      context.handle(
        _isEffectiveAssetMeta,
        isEffectiveAsset.isAcceptableOrUnknown(
          data['is_effective_asset']!,
          _isEffectiveAssetMeta,
        ),
      );
    }
    if (data.containsKey('used_times')) {
      context.handle(
        _usedTimesMeta,
        usedTimes.isAcceptableOrUnknown(data['used_times']!, _usedTimesMeta),
      );
    }
    if (data.containsKey('color')) {
      context.handle(
        _colorMeta,
        color.isAcceptableOrUnknown(data['color']!, _colorMeta),
      );
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    }
    if (data.containsKey('extra_info')) {
      context.handle(
        _extraInfoMeta,
        extraInfo.isAcceptableOrUnknown(data['extra_info']!, _extraInfoMeta),
      );
    }
    if (data.containsKey('loan_info')) {
      context.handle(
        _loanInfoMeta,
        loanInfo.isAcceptableOrUnknown(data['loan_info']!, _loanInfoMeta),
      );
    }
    if (data.containsKey('credit_info')) {
      context.handle(
        _creditInfoMeta,
        creditInfo.isAcceptableOrUnknown(data['credit_info']!, _creditInfoMeta),
      );
    }
    if (data.containsKey('fixed_deposit_info')) {
      context.handle(
        _fixedDepositInfoMeta,
        fixedDepositInfo.isAcceptableOrUnknown(
          data['fixed_deposit_info']!,
          _fixedDepositInfoMeta,
        ),
      );
    }
    if (data.containsKey('group_name')) {
      context.handle(
        _groupNameMeta,
        groupName.isAcceptableOrUnknown(data['group_name']!, _groupNameMeta),
      );
    }
    if (data.containsKey('currency')) {
      context.handle(
        _currencyMeta,
        currency.isAcceptableOrUnknown(data['currency']!, _currencyMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Asset map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Asset(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      balanceMinor: attachedDatabase.typeMapping.read(
        DriftSqlType.bigInt,
        data['${effectivePrefix}balance_minor'],
      )!,
      type: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}type'],
      )!,
      subType: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sub_type'],
      )!,
      createDate: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}create_date'],
      )!,
      sort: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort'],
      )!,
      icon: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}icon'],
      )!,
      remark: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}remark'],
      ),
      initMoneyMinor: attachedDatabase.typeMapping.read(
        DriftSqlType.bigInt,
        data['${effectivePrefix}init_money_minor'],
      )!,
      isDefault: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_default'],
      )!,
      isEffectiveAsset: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}is_effective_asset'],
      )!,
      usedTimes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}used_times'],
      )!,
      color: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}color'],
      ),
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}status'],
      )!,
      extraInfo: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}extra_info'],
      ),
      loanInfo: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}loan_info'],
      ),
      creditInfo: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}credit_info'],
      ),
      fixedDepositInfo: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}fixed_deposit_info'],
      ),
      groupName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}group_name'],
      ),
      currency: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}currency'],
      ),
    );
  }

  @override
  $AssetsTable createAlias(String alias) {
    return $AssetsTable(attachedDatabase, alias);
  }
}

class Asset extends DataClass implements Insertable<Asset> {
  final int id;
  final String name;
  final BigInt balanceMinor;
  final int type;
  final int subType;
  final int createDate;
  final int sort;
  final String icon;
  final String? remark;
  final BigInt initMoneyMinor;
  final bool isDefault;

  /// Original semantics: 1 = counted in net worth, except for type=4 (debt)
  /// where the polarity is inverted (0 = counted). Always written explicitly.
  final int isEffectiveAsset;
  final int usedTimes;
  final String? color;
  final int status;
  final String? extraInfo;
  final String? loanInfo;
  final String? creditInfo;
  final String? fixedDepositInfo;
  final String? groupName;

  /// Null means the app base currency (original behaviour).
  final String? currency;
  const Asset({
    required this.id,
    required this.name,
    required this.balanceMinor,
    required this.type,
    required this.subType,
    required this.createDate,
    required this.sort,
    required this.icon,
    this.remark,
    required this.initMoneyMinor,
    required this.isDefault,
    required this.isEffectiveAsset,
    required this.usedTimes,
    this.color,
    required this.status,
    this.extraInfo,
    this.loanInfo,
    this.creditInfo,
    this.fixedDepositInfo,
    this.groupName,
    this.currency,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['name'] = Variable<String>(name);
    map['balance_minor'] = Variable<BigInt>(balanceMinor);
    map['type'] = Variable<int>(type);
    map['sub_type'] = Variable<int>(subType);
    map['create_date'] = Variable<int>(createDate);
    map['sort'] = Variable<int>(sort);
    map['icon'] = Variable<String>(icon);
    if (!nullToAbsent || remark != null) {
      map['remark'] = Variable<String>(remark);
    }
    map['init_money_minor'] = Variable<BigInt>(initMoneyMinor);
    map['is_default'] = Variable<bool>(isDefault);
    map['is_effective_asset'] = Variable<int>(isEffectiveAsset);
    map['used_times'] = Variable<int>(usedTimes);
    if (!nullToAbsent || color != null) {
      map['color'] = Variable<String>(color);
    }
    map['status'] = Variable<int>(status);
    if (!nullToAbsent || extraInfo != null) {
      map['extra_info'] = Variable<String>(extraInfo);
    }
    if (!nullToAbsent || loanInfo != null) {
      map['loan_info'] = Variable<String>(loanInfo);
    }
    if (!nullToAbsent || creditInfo != null) {
      map['credit_info'] = Variable<String>(creditInfo);
    }
    if (!nullToAbsent || fixedDepositInfo != null) {
      map['fixed_deposit_info'] = Variable<String>(fixedDepositInfo);
    }
    if (!nullToAbsent || groupName != null) {
      map['group_name'] = Variable<String>(groupName);
    }
    if (!nullToAbsent || currency != null) {
      map['currency'] = Variable<String>(currency);
    }
    return map;
  }

  AssetsCompanion toCompanion(bool nullToAbsent) {
    return AssetsCompanion(
      id: Value(id),
      name: Value(name),
      balanceMinor: Value(balanceMinor),
      type: Value(type),
      subType: Value(subType),
      createDate: Value(createDate),
      sort: Value(sort),
      icon: Value(icon),
      remark: remark == null && nullToAbsent
          ? const Value.absent()
          : Value(remark),
      initMoneyMinor: Value(initMoneyMinor),
      isDefault: Value(isDefault),
      isEffectiveAsset: Value(isEffectiveAsset),
      usedTimes: Value(usedTimes),
      color: color == null && nullToAbsent
          ? const Value.absent()
          : Value(color),
      status: Value(status),
      extraInfo: extraInfo == null && nullToAbsent
          ? const Value.absent()
          : Value(extraInfo),
      loanInfo: loanInfo == null && nullToAbsent
          ? const Value.absent()
          : Value(loanInfo),
      creditInfo: creditInfo == null && nullToAbsent
          ? const Value.absent()
          : Value(creditInfo),
      fixedDepositInfo: fixedDepositInfo == null && nullToAbsent
          ? const Value.absent()
          : Value(fixedDepositInfo),
      groupName: groupName == null && nullToAbsent
          ? const Value.absent()
          : Value(groupName),
      currency: currency == null && nullToAbsent
          ? const Value.absent()
          : Value(currency),
    );
  }

  factory Asset.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Asset(
      id: serializer.fromJson<int>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      balanceMinor: serializer.fromJson<BigInt>(json['balanceMinor']),
      type: serializer.fromJson<int>(json['type']),
      subType: serializer.fromJson<int>(json['subType']),
      createDate: serializer.fromJson<int>(json['createDate']),
      sort: serializer.fromJson<int>(json['sort']),
      icon: serializer.fromJson<String>(json['icon']),
      remark: serializer.fromJson<String?>(json['remark']),
      initMoneyMinor: serializer.fromJson<BigInt>(json['initMoneyMinor']),
      isDefault: serializer.fromJson<bool>(json['isDefault']),
      isEffectiveAsset: serializer.fromJson<int>(json['isEffectiveAsset']),
      usedTimes: serializer.fromJson<int>(json['usedTimes']),
      color: serializer.fromJson<String?>(json['color']),
      status: serializer.fromJson<int>(json['status']),
      extraInfo: serializer.fromJson<String?>(json['extraInfo']),
      loanInfo: serializer.fromJson<String?>(json['loanInfo']),
      creditInfo: serializer.fromJson<String?>(json['creditInfo']),
      fixedDepositInfo: serializer.fromJson<String?>(json['fixedDepositInfo']),
      groupName: serializer.fromJson<String?>(json['groupName']),
      currency: serializer.fromJson<String?>(json['currency']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'name': serializer.toJson<String>(name),
      'balanceMinor': serializer.toJson<BigInt>(balanceMinor),
      'type': serializer.toJson<int>(type),
      'subType': serializer.toJson<int>(subType),
      'createDate': serializer.toJson<int>(createDate),
      'sort': serializer.toJson<int>(sort),
      'icon': serializer.toJson<String>(icon),
      'remark': serializer.toJson<String?>(remark),
      'initMoneyMinor': serializer.toJson<BigInt>(initMoneyMinor),
      'isDefault': serializer.toJson<bool>(isDefault),
      'isEffectiveAsset': serializer.toJson<int>(isEffectiveAsset),
      'usedTimes': serializer.toJson<int>(usedTimes),
      'color': serializer.toJson<String?>(color),
      'status': serializer.toJson<int>(status),
      'extraInfo': serializer.toJson<String?>(extraInfo),
      'loanInfo': serializer.toJson<String?>(loanInfo),
      'creditInfo': serializer.toJson<String?>(creditInfo),
      'fixedDepositInfo': serializer.toJson<String?>(fixedDepositInfo),
      'groupName': serializer.toJson<String?>(groupName),
      'currency': serializer.toJson<String?>(currency),
    };
  }

  Asset copyWith({
    int? id,
    String? name,
    BigInt? balanceMinor,
    int? type,
    int? subType,
    int? createDate,
    int? sort,
    String? icon,
    Value<String?> remark = const Value.absent(),
    BigInt? initMoneyMinor,
    bool? isDefault,
    int? isEffectiveAsset,
    int? usedTimes,
    Value<String?> color = const Value.absent(),
    int? status,
    Value<String?> extraInfo = const Value.absent(),
    Value<String?> loanInfo = const Value.absent(),
    Value<String?> creditInfo = const Value.absent(),
    Value<String?> fixedDepositInfo = const Value.absent(),
    Value<String?> groupName = const Value.absent(),
    Value<String?> currency = const Value.absent(),
  }) => Asset(
    id: id ?? this.id,
    name: name ?? this.name,
    balanceMinor: balanceMinor ?? this.balanceMinor,
    type: type ?? this.type,
    subType: subType ?? this.subType,
    createDate: createDate ?? this.createDate,
    sort: sort ?? this.sort,
    icon: icon ?? this.icon,
    remark: remark.present ? remark.value : this.remark,
    initMoneyMinor: initMoneyMinor ?? this.initMoneyMinor,
    isDefault: isDefault ?? this.isDefault,
    isEffectiveAsset: isEffectiveAsset ?? this.isEffectiveAsset,
    usedTimes: usedTimes ?? this.usedTimes,
    color: color.present ? color.value : this.color,
    status: status ?? this.status,
    extraInfo: extraInfo.present ? extraInfo.value : this.extraInfo,
    loanInfo: loanInfo.present ? loanInfo.value : this.loanInfo,
    creditInfo: creditInfo.present ? creditInfo.value : this.creditInfo,
    fixedDepositInfo: fixedDepositInfo.present
        ? fixedDepositInfo.value
        : this.fixedDepositInfo,
    groupName: groupName.present ? groupName.value : this.groupName,
    currency: currency.present ? currency.value : this.currency,
  );
  Asset copyWithCompanion(AssetsCompanion data) {
    return Asset(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      balanceMinor: data.balanceMinor.present
          ? data.balanceMinor.value
          : this.balanceMinor,
      type: data.type.present ? data.type.value : this.type,
      subType: data.subType.present ? data.subType.value : this.subType,
      createDate: data.createDate.present
          ? data.createDate.value
          : this.createDate,
      sort: data.sort.present ? data.sort.value : this.sort,
      icon: data.icon.present ? data.icon.value : this.icon,
      remark: data.remark.present ? data.remark.value : this.remark,
      initMoneyMinor: data.initMoneyMinor.present
          ? data.initMoneyMinor.value
          : this.initMoneyMinor,
      isDefault: data.isDefault.present ? data.isDefault.value : this.isDefault,
      isEffectiveAsset: data.isEffectiveAsset.present
          ? data.isEffectiveAsset.value
          : this.isEffectiveAsset,
      usedTimes: data.usedTimes.present ? data.usedTimes.value : this.usedTimes,
      color: data.color.present ? data.color.value : this.color,
      status: data.status.present ? data.status.value : this.status,
      extraInfo: data.extraInfo.present ? data.extraInfo.value : this.extraInfo,
      loanInfo: data.loanInfo.present ? data.loanInfo.value : this.loanInfo,
      creditInfo: data.creditInfo.present
          ? data.creditInfo.value
          : this.creditInfo,
      fixedDepositInfo: data.fixedDepositInfo.present
          ? data.fixedDepositInfo.value
          : this.fixedDepositInfo,
      groupName: data.groupName.present ? data.groupName.value : this.groupName,
      currency: data.currency.present ? data.currency.value : this.currency,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Asset(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('balanceMinor: $balanceMinor, ')
          ..write('type: $type, ')
          ..write('subType: $subType, ')
          ..write('createDate: $createDate, ')
          ..write('sort: $sort, ')
          ..write('icon: $icon, ')
          ..write('remark: $remark, ')
          ..write('initMoneyMinor: $initMoneyMinor, ')
          ..write('isDefault: $isDefault, ')
          ..write('isEffectiveAsset: $isEffectiveAsset, ')
          ..write('usedTimes: $usedTimes, ')
          ..write('color: $color, ')
          ..write('status: $status, ')
          ..write('extraInfo: $extraInfo, ')
          ..write('loanInfo: $loanInfo, ')
          ..write('creditInfo: $creditInfo, ')
          ..write('fixedDepositInfo: $fixedDepositInfo, ')
          ..write('groupName: $groupName, ')
          ..write('currency: $currency')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    id,
    name,
    balanceMinor,
    type,
    subType,
    createDate,
    sort,
    icon,
    remark,
    initMoneyMinor,
    isDefault,
    isEffectiveAsset,
    usedTimes,
    color,
    status,
    extraInfo,
    loanInfo,
    creditInfo,
    fixedDepositInfo,
    groupName,
    currency,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Asset &&
          other.id == this.id &&
          other.name == this.name &&
          other.balanceMinor == this.balanceMinor &&
          other.type == this.type &&
          other.subType == this.subType &&
          other.createDate == this.createDate &&
          other.sort == this.sort &&
          other.icon == this.icon &&
          other.remark == this.remark &&
          other.initMoneyMinor == this.initMoneyMinor &&
          other.isDefault == this.isDefault &&
          other.isEffectiveAsset == this.isEffectiveAsset &&
          other.usedTimes == this.usedTimes &&
          other.color == this.color &&
          other.status == this.status &&
          other.extraInfo == this.extraInfo &&
          other.loanInfo == this.loanInfo &&
          other.creditInfo == this.creditInfo &&
          other.fixedDepositInfo == this.fixedDepositInfo &&
          other.groupName == this.groupName &&
          other.currency == this.currency);
}

class AssetsCompanion extends UpdateCompanion<Asset> {
  final Value<int> id;
  final Value<String> name;
  final Value<BigInt> balanceMinor;
  final Value<int> type;
  final Value<int> subType;
  final Value<int> createDate;
  final Value<int> sort;
  final Value<String> icon;
  final Value<String?> remark;
  final Value<BigInt> initMoneyMinor;
  final Value<bool> isDefault;
  final Value<int> isEffectiveAsset;
  final Value<int> usedTimes;
  final Value<String?> color;
  final Value<int> status;
  final Value<String?> extraInfo;
  final Value<String?> loanInfo;
  final Value<String?> creditInfo;
  final Value<String?> fixedDepositInfo;
  final Value<String?> groupName;
  final Value<String?> currency;
  const AssetsCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.balanceMinor = const Value.absent(),
    this.type = const Value.absent(),
    this.subType = const Value.absent(),
    this.createDate = const Value.absent(),
    this.sort = const Value.absent(),
    this.icon = const Value.absent(),
    this.remark = const Value.absent(),
    this.initMoneyMinor = const Value.absent(),
    this.isDefault = const Value.absent(),
    this.isEffectiveAsset = const Value.absent(),
    this.usedTimes = const Value.absent(),
    this.color = const Value.absent(),
    this.status = const Value.absent(),
    this.extraInfo = const Value.absent(),
    this.loanInfo = const Value.absent(),
    this.creditInfo = const Value.absent(),
    this.fixedDepositInfo = const Value.absent(),
    this.groupName = const Value.absent(),
    this.currency = const Value.absent(),
  });
  AssetsCompanion.insert({
    this.id = const Value.absent(),
    required String name,
    required BigInt balanceMinor,
    required int type,
    this.subType = const Value.absent(),
    required int createDate,
    this.sort = const Value.absent(),
    this.icon = const Value.absent(),
    this.remark = const Value.absent(),
    required BigInt initMoneyMinor,
    this.isDefault = const Value.absent(),
    this.isEffectiveAsset = const Value.absent(),
    this.usedTimes = const Value.absent(),
    this.color = const Value.absent(),
    this.status = const Value.absent(),
    this.extraInfo = const Value.absent(),
    this.loanInfo = const Value.absent(),
    this.creditInfo = const Value.absent(),
    this.fixedDepositInfo = const Value.absent(),
    this.groupName = const Value.absent(),
    this.currency = const Value.absent(),
  }) : name = Value(name),
       balanceMinor = Value(balanceMinor),
       type = Value(type),
       createDate = Value(createDate),
       initMoneyMinor = Value(initMoneyMinor);
  static Insertable<Asset> custom({
    Expression<int>? id,
    Expression<String>? name,
    Expression<BigInt>? balanceMinor,
    Expression<int>? type,
    Expression<int>? subType,
    Expression<int>? createDate,
    Expression<int>? sort,
    Expression<String>? icon,
    Expression<String>? remark,
    Expression<BigInt>? initMoneyMinor,
    Expression<bool>? isDefault,
    Expression<int>? isEffectiveAsset,
    Expression<int>? usedTimes,
    Expression<String>? color,
    Expression<int>? status,
    Expression<String>? extraInfo,
    Expression<String>? loanInfo,
    Expression<String>? creditInfo,
    Expression<String>? fixedDepositInfo,
    Expression<String>? groupName,
    Expression<String>? currency,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (balanceMinor != null) 'balance_minor': balanceMinor,
      if (type != null) 'type': type,
      if (subType != null) 'sub_type': subType,
      if (createDate != null) 'create_date': createDate,
      if (sort != null) 'sort': sort,
      if (icon != null) 'icon': icon,
      if (remark != null) 'remark': remark,
      if (initMoneyMinor != null) 'init_money_minor': initMoneyMinor,
      if (isDefault != null) 'is_default': isDefault,
      if (isEffectiveAsset != null) 'is_effective_asset': isEffectiveAsset,
      if (usedTimes != null) 'used_times': usedTimes,
      if (color != null) 'color': color,
      if (status != null) 'status': status,
      if (extraInfo != null) 'extra_info': extraInfo,
      if (loanInfo != null) 'loan_info': loanInfo,
      if (creditInfo != null) 'credit_info': creditInfo,
      if (fixedDepositInfo != null) 'fixed_deposit_info': fixedDepositInfo,
      if (groupName != null) 'group_name': groupName,
      if (currency != null) 'currency': currency,
    });
  }

  AssetsCompanion copyWith({
    Value<int>? id,
    Value<String>? name,
    Value<BigInt>? balanceMinor,
    Value<int>? type,
    Value<int>? subType,
    Value<int>? createDate,
    Value<int>? sort,
    Value<String>? icon,
    Value<String?>? remark,
    Value<BigInt>? initMoneyMinor,
    Value<bool>? isDefault,
    Value<int>? isEffectiveAsset,
    Value<int>? usedTimes,
    Value<String?>? color,
    Value<int>? status,
    Value<String?>? extraInfo,
    Value<String?>? loanInfo,
    Value<String?>? creditInfo,
    Value<String?>? fixedDepositInfo,
    Value<String?>? groupName,
    Value<String?>? currency,
  }) {
    return AssetsCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      balanceMinor: balanceMinor ?? this.balanceMinor,
      type: type ?? this.type,
      subType: subType ?? this.subType,
      createDate: createDate ?? this.createDate,
      sort: sort ?? this.sort,
      icon: icon ?? this.icon,
      remark: remark ?? this.remark,
      initMoneyMinor: initMoneyMinor ?? this.initMoneyMinor,
      isDefault: isDefault ?? this.isDefault,
      isEffectiveAsset: isEffectiveAsset ?? this.isEffectiveAsset,
      usedTimes: usedTimes ?? this.usedTimes,
      color: color ?? this.color,
      status: status ?? this.status,
      extraInfo: extraInfo ?? this.extraInfo,
      loanInfo: loanInfo ?? this.loanInfo,
      creditInfo: creditInfo ?? this.creditInfo,
      fixedDepositInfo: fixedDepositInfo ?? this.fixedDepositInfo,
      groupName: groupName ?? this.groupName,
      currency: currency ?? this.currency,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (balanceMinor.present) {
      map['balance_minor'] = Variable<BigInt>(balanceMinor.value);
    }
    if (type.present) {
      map['type'] = Variable<int>(type.value);
    }
    if (subType.present) {
      map['sub_type'] = Variable<int>(subType.value);
    }
    if (createDate.present) {
      map['create_date'] = Variable<int>(createDate.value);
    }
    if (sort.present) {
      map['sort'] = Variable<int>(sort.value);
    }
    if (icon.present) {
      map['icon'] = Variable<String>(icon.value);
    }
    if (remark.present) {
      map['remark'] = Variable<String>(remark.value);
    }
    if (initMoneyMinor.present) {
      map['init_money_minor'] = Variable<BigInt>(initMoneyMinor.value);
    }
    if (isDefault.present) {
      map['is_default'] = Variable<bool>(isDefault.value);
    }
    if (isEffectiveAsset.present) {
      map['is_effective_asset'] = Variable<int>(isEffectiveAsset.value);
    }
    if (usedTimes.present) {
      map['used_times'] = Variable<int>(usedTimes.value);
    }
    if (color.present) {
      map['color'] = Variable<String>(color.value);
    }
    if (status.present) {
      map['status'] = Variable<int>(status.value);
    }
    if (extraInfo.present) {
      map['extra_info'] = Variable<String>(extraInfo.value);
    }
    if (loanInfo.present) {
      map['loan_info'] = Variable<String>(loanInfo.value);
    }
    if (creditInfo.present) {
      map['credit_info'] = Variable<String>(creditInfo.value);
    }
    if (fixedDepositInfo.present) {
      map['fixed_deposit_info'] = Variable<String>(fixedDepositInfo.value);
    }
    if (groupName.present) {
      map['group_name'] = Variable<String>(groupName.value);
    }
    if (currency.present) {
      map['currency'] = Variable<String>(currency.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AssetsCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('balanceMinor: $balanceMinor, ')
          ..write('type: $type, ')
          ..write('subType: $subType, ')
          ..write('createDate: $createDate, ')
          ..write('sort: $sort, ')
          ..write('icon: $icon, ')
          ..write('remark: $remark, ')
          ..write('initMoneyMinor: $initMoneyMinor, ')
          ..write('isDefault: $isDefault, ')
          ..write('isEffectiveAsset: $isEffectiveAsset, ')
          ..write('usedTimes: $usedTimes, ')
          ..write('color: $color, ')
          ..write('status: $status, ')
          ..write('extraInfo: $extraInfo, ')
          ..write('loanInfo: $loanInfo, ')
          ..write('creditInfo: $creditInfo, ')
          ..write('fixedDepositInfo: $fixedDepositInfo, ')
          ..write('groupName: $groupName, ')
          ..write('currency: $currency')
          ..write(')'))
        .toString();
  }
}

class $BankCardsTable extends BankCards
    with TableInfo<$BankCardsTable, BankCard> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $BankCardsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _cardTypeMeta = const VerificationMeta(
    'cardType',
  );
  @override
  late final GeneratedColumn<int> cardType = GeneratedColumn<int>(
    'card_type',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _cardNameMeta = const VerificationMeta(
    'cardName',
  );
  @override
  late final GeneratedColumn<String> cardName = GeneratedColumn<String>(
    'card_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _cardNoMeta = const VerificationMeta('cardNo');
  @override
  late final GeneratedColumn<String> cardNo = GeneratedColumn<String>(
    'card_no',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _cardOwnerMeta = const VerificationMeta(
    'cardOwner',
  );
  @override
  late final GeneratedColumn<String> cardOwner = GeneratedColumn<String>(
    'card_owner',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _remarkMeta = const VerificationMeta('remark');
  @override
  late final GeneratedColumn<String> remark = GeneratedColumn<String>(
    'remark',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _cardColorMeta = const VerificationMeta(
    'cardColor',
  );
  @override
  late final GeneratedColumn<String> cardColor = GeneratedColumn<String>(
    'card_color',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sortMeta = const VerificationMeta('sort');
  @override
  late final GeneratedColumn<int> sort = GeneratedColumn<int>(
    'sort',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(-1),
  );
  static const VerificationMeta _createDateMeta = const VerificationMeta(
    'createDate',
  );
  @override
  late final GeneratedColumn<int> createDate = GeneratedColumn<int>(
    'create_date',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _cardAssetIdMeta = const VerificationMeta(
    'cardAssetId',
  );
  @override
  late final GeneratedColumn<int> cardAssetId = GeneratedColumn<int>(
    'card_asset_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(-1),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    cardType,
    cardName,
    cardNo,
    cardOwner,
    remark,
    cardColor,
    sort,
    createDate,
    cardAssetId,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'bank_card';
  @override
  VerificationContext validateIntegrity(
    Insertable<BankCard> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('card_type')) {
      context.handle(
        _cardTypeMeta,
        cardType.isAcceptableOrUnknown(data['card_type']!, _cardTypeMeta),
      );
    } else if (isInserting) {
      context.missing(_cardTypeMeta);
    }
    if (data.containsKey('card_name')) {
      context.handle(
        _cardNameMeta,
        cardName.isAcceptableOrUnknown(data['card_name']!, _cardNameMeta),
      );
    } else if (isInserting) {
      context.missing(_cardNameMeta);
    }
    if (data.containsKey('card_no')) {
      context.handle(
        _cardNoMeta,
        cardNo.isAcceptableOrUnknown(data['card_no']!, _cardNoMeta),
      );
    } else if (isInserting) {
      context.missing(_cardNoMeta);
    }
    if (data.containsKey('card_owner')) {
      context.handle(
        _cardOwnerMeta,
        cardOwner.isAcceptableOrUnknown(data['card_owner']!, _cardOwnerMeta),
      );
    } else if (isInserting) {
      context.missing(_cardOwnerMeta);
    }
    if (data.containsKey('remark')) {
      context.handle(
        _remarkMeta,
        remark.isAcceptableOrUnknown(data['remark']!, _remarkMeta),
      );
    }
    if (data.containsKey('card_color')) {
      context.handle(
        _cardColorMeta,
        cardColor.isAcceptableOrUnknown(data['card_color']!, _cardColorMeta),
      );
    }
    if (data.containsKey('sort')) {
      context.handle(
        _sortMeta,
        sort.isAcceptableOrUnknown(data['sort']!, _sortMeta),
      );
    }
    if (data.containsKey('create_date')) {
      context.handle(
        _createDateMeta,
        createDate.isAcceptableOrUnknown(data['create_date']!, _createDateMeta),
      );
    } else if (isInserting) {
      context.missing(_createDateMeta);
    }
    if (data.containsKey('card_asset_id')) {
      context.handle(
        _cardAssetIdMeta,
        cardAssetId.isAcceptableOrUnknown(
          data['card_asset_id']!,
          _cardAssetIdMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  BankCard map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return BankCard(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      cardType: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}card_type'],
      )!,
      cardName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}card_name'],
      )!,
      cardNo: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}card_no'],
      )!,
      cardOwner: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}card_owner'],
      )!,
      remark: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}remark'],
      )!,
      cardColor: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}card_color'],
      ),
      sort: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort'],
      )!,
      createDate: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}create_date'],
      )!,
      cardAssetId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}card_asset_id'],
      )!,
    );
  }

  @override
  $BankCardsTable createAlias(String alias) {
    return $BankCardsTable(attachedDatabase, alias);
  }
}

class BankCard extends DataClass implements Insertable<BankCard> {
  final int id;
  final int cardType;
  final String cardName;
  final String cardNo;
  final String cardOwner;
  final String remark;
  final String? cardColor;
  final int sort;
  final int createDate;
  final int cardAssetId;
  const BankCard({
    required this.id,
    required this.cardType,
    required this.cardName,
    required this.cardNo,
    required this.cardOwner,
    required this.remark,
    this.cardColor,
    required this.sort,
    required this.createDate,
    required this.cardAssetId,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['card_type'] = Variable<int>(cardType);
    map['card_name'] = Variable<String>(cardName);
    map['card_no'] = Variable<String>(cardNo);
    map['card_owner'] = Variable<String>(cardOwner);
    map['remark'] = Variable<String>(remark);
    if (!nullToAbsent || cardColor != null) {
      map['card_color'] = Variable<String>(cardColor);
    }
    map['sort'] = Variable<int>(sort);
    map['create_date'] = Variable<int>(createDate);
    map['card_asset_id'] = Variable<int>(cardAssetId);
    return map;
  }

  BankCardsCompanion toCompanion(bool nullToAbsent) {
    return BankCardsCompanion(
      id: Value(id),
      cardType: Value(cardType),
      cardName: Value(cardName),
      cardNo: Value(cardNo),
      cardOwner: Value(cardOwner),
      remark: Value(remark),
      cardColor: cardColor == null && nullToAbsent
          ? const Value.absent()
          : Value(cardColor),
      sort: Value(sort),
      createDate: Value(createDate),
      cardAssetId: Value(cardAssetId),
    );
  }

  factory BankCard.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return BankCard(
      id: serializer.fromJson<int>(json['id']),
      cardType: serializer.fromJson<int>(json['cardType']),
      cardName: serializer.fromJson<String>(json['cardName']),
      cardNo: serializer.fromJson<String>(json['cardNo']),
      cardOwner: serializer.fromJson<String>(json['cardOwner']),
      remark: serializer.fromJson<String>(json['remark']),
      cardColor: serializer.fromJson<String?>(json['cardColor']),
      sort: serializer.fromJson<int>(json['sort']),
      createDate: serializer.fromJson<int>(json['createDate']),
      cardAssetId: serializer.fromJson<int>(json['cardAssetId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'cardType': serializer.toJson<int>(cardType),
      'cardName': serializer.toJson<String>(cardName),
      'cardNo': serializer.toJson<String>(cardNo),
      'cardOwner': serializer.toJson<String>(cardOwner),
      'remark': serializer.toJson<String>(remark),
      'cardColor': serializer.toJson<String?>(cardColor),
      'sort': serializer.toJson<int>(sort),
      'createDate': serializer.toJson<int>(createDate),
      'cardAssetId': serializer.toJson<int>(cardAssetId),
    };
  }

  BankCard copyWith({
    int? id,
    int? cardType,
    String? cardName,
    String? cardNo,
    String? cardOwner,
    String? remark,
    Value<String?> cardColor = const Value.absent(),
    int? sort,
    int? createDate,
    int? cardAssetId,
  }) => BankCard(
    id: id ?? this.id,
    cardType: cardType ?? this.cardType,
    cardName: cardName ?? this.cardName,
    cardNo: cardNo ?? this.cardNo,
    cardOwner: cardOwner ?? this.cardOwner,
    remark: remark ?? this.remark,
    cardColor: cardColor.present ? cardColor.value : this.cardColor,
    sort: sort ?? this.sort,
    createDate: createDate ?? this.createDate,
    cardAssetId: cardAssetId ?? this.cardAssetId,
  );
  BankCard copyWithCompanion(BankCardsCompanion data) {
    return BankCard(
      id: data.id.present ? data.id.value : this.id,
      cardType: data.cardType.present ? data.cardType.value : this.cardType,
      cardName: data.cardName.present ? data.cardName.value : this.cardName,
      cardNo: data.cardNo.present ? data.cardNo.value : this.cardNo,
      cardOwner: data.cardOwner.present ? data.cardOwner.value : this.cardOwner,
      remark: data.remark.present ? data.remark.value : this.remark,
      cardColor: data.cardColor.present ? data.cardColor.value : this.cardColor,
      sort: data.sort.present ? data.sort.value : this.sort,
      createDate: data.createDate.present
          ? data.createDate.value
          : this.createDate,
      cardAssetId: data.cardAssetId.present
          ? data.cardAssetId.value
          : this.cardAssetId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('BankCard(')
          ..write('id: $id, ')
          ..write('cardType: $cardType, ')
          ..write('cardName: $cardName, ')
          ..write('cardNo: $cardNo, ')
          ..write('cardOwner: $cardOwner, ')
          ..write('remark: $remark, ')
          ..write('cardColor: $cardColor, ')
          ..write('sort: $sort, ')
          ..write('createDate: $createDate, ')
          ..write('cardAssetId: $cardAssetId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    cardType,
    cardName,
    cardNo,
    cardOwner,
    remark,
    cardColor,
    sort,
    createDate,
    cardAssetId,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is BankCard &&
          other.id == this.id &&
          other.cardType == this.cardType &&
          other.cardName == this.cardName &&
          other.cardNo == this.cardNo &&
          other.cardOwner == this.cardOwner &&
          other.remark == this.remark &&
          other.cardColor == this.cardColor &&
          other.sort == this.sort &&
          other.createDate == this.createDate &&
          other.cardAssetId == this.cardAssetId);
}

class BankCardsCompanion extends UpdateCompanion<BankCard> {
  final Value<int> id;
  final Value<int> cardType;
  final Value<String> cardName;
  final Value<String> cardNo;
  final Value<String> cardOwner;
  final Value<String> remark;
  final Value<String?> cardColor;
  final Value<int> sort;
  final Value<int> createDate;
  final Value<int> cardAssetId;
  const BankCardsCompanion({
    this.id = const Value.absent(),
    this.cardType = const Value.absent(),
    this.cardName = const Value.absent(),
    this.cardNo = const Value.absent(),
    this.cardOwner = const Value.absent(),
    this.remark = const Value.absent(),
    this.cardColor = const Value.absent(),
    this.sort = const Value.absent(),
    this.createDate = const Value.absent(),
    this.cardAssetId = const Value.absent(),
  });
  BankCardsCompanion.insert({
    this.id = const Value.absent(),
    required int cardType,
    required String cardName,
    required String cardNo,
    required String cardOwner,
    this.remark = const Value.absent(),
    this.cardColor = const Value.absent(),
    this.sort = const Value.absent(),
    required int createDate,
    this.cardAssetId = const Value.absent(),
  }) : cardType = Value(cardType),
       cardName = Value(cardName),
       cardNo = Value(cardNo),
       cardOwner = Value(cardOwner),
       createDate = Value(createDate);
  static Insertable<BankCard> custom({
    Expression<int>? id,
    Expression<int>? cardType,
    Expression<String>? cardName,
    Expression<String>? cardNo,
    Expression<String>? cardOwner,
    Expression<String>? remark,
    Expression<String>? cardColor,
    Expression<int>? sort,
    Expression<int>? createDate,
    Expression<int>? cardAssetId,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (cardType != null) 'card_type': cardType,
      if (cardName != null) 'card_name': cardName,
      if (cardNo != null) 'card_no': cardNo,
      if (cardOwner != null) 'card_owner': cardOwner,
      if (remark != null) 'remark': remark,
      if (cardColor != null) 'card_color': cardColor,
      if (sort != null) 'sort': sort,
      if (createDate != null) 'create_date': createDate,
      if (cardAssetId != null) 'card_asset_id': cardAssetId,
    });
  }

  BankCardsCompanion copyWith({
    Value<int>? id,
    Value<int>? cardType,
    Value<String>? cardName,
    Value<String>? cardNo,
    Value<String>? cardOwner,
    Value<String>? remark,
    Value<String?>? cardColor,
    Value<int>? sort,
    Value<int>? createDate,
    Value<int>? cardAssetId,
  }) {
    return BankCardsCompanion(
      id: id ?? this.id,
      cardType: cardType ?? this.cardType,
      cardName: cardName ?? this.cardName,
      cardNo: cardNo ?? this.cardNo,
      cardOwner: cardOwner ?? this.cardOwner,
      remark: remark ?? this.remark,
      cardColor: cardColor ?? this.cardColor,
      sort: sort ?? this.sort,
      createDate: createDate ?? this.createDate,
      cardAssetId: cardAssetId ?? this.cardAssetId,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (cardType.present) {
      map['card_type'] = Variable<int>(cardType.value);
    }
    if (cardName.present) {
      map['card_name'] = Variable<String>(cardName.value);
    }
    if (cardNo.present) {
      map['card_no'] = Variable<String>(cardNo.value);
    }
    if (cardOwner.present) {
      map['card_owner'] = Variable<String>(cardOwner.value);
    }
    if (remark.present) {
      map['remark'] = Variable<String>(remark.value);
    }
    if (cardColor.present) {
      map['card_color'] = Variable<String>(cardColor.value);
    }
    if (sort.present) {
      map['sort'] = Variable<int>(sort.value);
    }
    if (createDate.present) {
      map['create_date'] = Variable<int>(createDate.value);
    }
    if (cardAssetId.present) {
      map['card_asset_id'] = Variable<int>(cardAssetId.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('BankCardsCompanion(')
          ..write('id: $id, ')
          ..write('cardType: $cardType, ')
          ..write('cardName: $cardName, ')
          ..write('cardNo: $cardNo, ')
          ..write('cardOwner: $cardOwner, ')
          ..write('remark: $remark, ')
          ..write('cardColor: $cardColor, ')
          ..write('sort: $sort, ')
          ..write('createDate: $createDate, ')
          ..write('cardAssetId: $cardAssetId')
          ..write(')'))
        .toString();
  }
}

class $BudgetsTable extends Budgets with TableInfo<$BudgetsTable, Budget> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $BudgetsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _budgetTypeMeta = const VerificationMeta(
    'budgetType',
  );
  @override
  late final GeneratedColumn<int> budgetType = GeneratedColumn<int>(
    'budget_type',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _recordCatIdMeta = const VerificationMeta(
    'recordCatId',
  );
  @override
  late final GeneratedColumn<int> recordCatId = GeneratedColumn<int>(
    'record_cat_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _amountMinorMeta = const VerificationMeta(
    'amountMinor',
  );
  @override
  late final GeneratedColumn<BigInt> amountMinor = GeneratedColumn<BigInt>(
    'amount_minor',
    aliasedName,
    false,
    type: DriftSqlType.bigInt,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _bookIdMeta = const VerificationMeta('bookId');
  @override
  late final GeneratedColumn<int> bookId = GeneratedColumn<int>(
    'book_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sectionMeta = const VerificationMeta(
    'section',
  );
  @override
  late final GeneratedColumn<String> section = GeneratedColumn<String>(
    'section',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sortMeta = const VerificationMeta('sort');
  @override
  late final GeneratedColumn<int> sort = GeneratedColumn<int>(
    'sort',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _createDateMeta = const VerificationMeta(
    'createDate',
  );
  @override
  late final GeneratedColumn<int> createDate = GeneratedColumn<int>(
    'create_date',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _remarkMeta = const VerificationMeta('remark');
  @override
  late final GeneratedColumn<String> remark = GeneratedColumn<String>(
    'remark',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _extraInfoMeta = const VerificationMeta(
    'extraInfo',
  );
  @override
  late final GeneratedColumn<String> extraInfo = GeneratedColumn<String>(
    'extra_info',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    budgetType,
    recordCatId,
    amountMinor,
    bookId,
    section,
    sort,
    createDate,
    remark,
    extraInfo,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'budget';
  @override
  VerificationContext validateIntegrity(
    Insertable<Budget> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('budget_type')) {
      context.handle(
        _budgetTypeMeta,
        budgetType.isAcceptableOrUnknown(data['budget_type']!, _budgetTypeMeta),
      );
    } else if (isInserting) {
      context.missing(_budgetTypeMeta);
    }
    if (data.containsKey('record_cat_id')) {
      context.handle(
        _recordCatIdMeta,
        recordCatId.isAcceptableOrUnknown(
          data['record_cat_id']!,
          _recordCatIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_recordCatIdMeta);
    }
    if (data.containsKey('amount_minor')) {
      context.handle(
        _amountMinorMeta,
        amountMinor.isAcceptableOrUnknown(
          data['amount_minor']!,
          _amountMinorMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_amountMinorMeta);
    }
    if (data.containsKey('book_id')) {
      context.handle(
        _bookIdMeta,
        bookId.isAcceptableOrUnknown(data['book_id']!, _bookIdMeta),
      );
    } else if (isInserting) {
      context.missing(_bookIdMeta);
    }
    if (data.containsKey('section')) {
      context.handle(
        _sectionMeta,
        section.isAcceptableOrUnknown(data['section']!, _sectionMeta),
      );
    } else if (isInserting) {
      context.missing(_sectionMeta);
    }
    if (data.containsKey('sort')) {
      context.handle(
        _sortMeta,
        sort.isAcceptableOrUnknown(data['sort']!, _sortMeta),
      );
    }
    if (data.containsKey('create_date')) {
      context.handle(
        _createDateMeta,
        createDate.isAcceptableOrUnknown(data['create_date']!, _createDateMeta),
      );
    } else if (isInserting) {
      context.missing(_createDateMeta);
    }
    if (data.containsKey('remark')) {
      context.handle(
        _remarkMeta,
        remark.isAcceptableOrUnknown(data['remark']!, _remarkMeta),
      );
    }
    if (data.containsKey('extra_info')) {
      context.handle(
        _extraInfoMeta,
        extraInfo.isAcceptableOrUnknown(data['extra_info']!, _extraInfoMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Budget map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Budget(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      budgetType: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}budget_type'],
      )!,
      recordCatId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}record_cat_id'],
      )!,
      amountMinor: attachedDatabase.typeMapping.read(
        DriftSqlType.bigInt,
        data['${effectivePrefix}amount_minor'],
      )!,
      bookId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}book_id'],
      )!,
      section: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}section'],
      )!,
      sort: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort'],
      )!,
      createDate: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}create_date'],
      )!,
      remark: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}remark'],
      ),
      extraInfo: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}extra_info'],
      ),
    );
  }

  @override
  $BudgetsTable createAlias(String alias) {
    return $BudgetsTable(attachedDatabase, alias);
  }
}

class Budget extends DataClass implements Insertable<Budget> {
  final int id;
  final int budgetType;
  final int recordCatId;
  final BigInt amountMinor;
  final int bookId;
  final String section;
  final int sort;
  final int createDate;
  final String? remark;
  final String? extraInfo;
  const Budget({
    required this.id,
    required this.budgetType,
    required this.recordCatId,
    required this.amountMinor,
    required this.bookId,
    required this.section,
    required this.sort,
    required this.createDate,
    this.remark,
    this.extraInfo,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['budget_type'] = Variable<int>(budgetType);
    map['record_cat_id'] = Variable<int>(recordCatId);
    map['amount_minor'] = Variable<BigInt>(amountMinor);
    map['book_id'] = Variable<int>(bookId);
    map['section'] = Variable<String>(section);
    map['sort'] = Variable<int>(sort);
    map['create_date'] = Variable<int>(createDate);
    if (!nullToAbsent || remark != null) {
      map['remark'] = Variable<String>(remark);
    }
    if (!nullToAbsent || extraInfo != null) {
      map['extra_info'] = Variable<String>(extraInfo);
    }
    return map;
  }

  BudgetsCompanion toCompanion(bool nullToAbsent) {
    return BudgetsCompanion(
      id: Value(id),
      budgetType: Value(budgetType),
      recordCatId: Value(recordCatId),
      amountMinor: Value(amountMinor),
      bookId: Value(bookId),
      section: Value(section),
      sort: Value(sort),
      createDate: Value(createDate),
      remark: remark == null && nullToAbsent
          ? const Value.absent()
          : Value(remark),
      extraInfo: extraInfo == null && nullToAbsent
          ? const Value.absent()
          : Value(extraInfo),
    );
  }

  factory Budget.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Budget(
      id: serializer.fromJson<int>(json['id']),
      budgetType: serializer.fromJson<int>(json['budgetType']),
      recordCatId: serializer.fromJson<int>(json['recordCatId']),
      amountMinor: serializer.fromJson<BigInt>(json['amountMinor']),
      bookId: serializer.fromJson<int>(json['bookId']),
      section: serializer.fromJson<String>(json['section']),
      sort: serializer.fromJson<int>(json['sort']),
      createDate: serializer.fromJson<int>(json['createDate']),
      remark: serializer.fromJson<String?>(json['remark']),
      extraInfo: serializer.fromJson<String?>(json['extraInfo']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'budgetType': serializer.toJson<int>(budgetType),
      'recordCatId': serializer.toJson<int>(recordCatId),
      'amountMinor': serializer.toJson<BigInt>(amountMinor),
      'bookId': serializer.toJson<int>(bookId),
      'section': serializer.toJson<String>(section),
      'sort': serializer.toJson<int>(sort),
      'createDate': serializer.toJson<int>(createDate),
      'remark': serializer.toJson<String?>(remark),
      'extraInfo': serializer.toJson<String?>(extraInfo),
    };
  }

  Budget copyWith({
    int? id,
    int? budgetType,
    int? recordCatId,
    BigInt? amountMinor,
    int? bookId,
    String? section,
    int? sort,
    int? createDate,
    Value<String?> remark = const Value.absent(),
    Value<String?> extraInfo = const Value.absent(),
  }) => Budget(
    id: id ?? this.id,
    budgetType: budgetType ?? this.budgetType,
    recordCatId: recordCatId ?? this.recordCatId,
    amountMinor: amountMinor ?? this.amountMinor,
    bookId: bookId ?? this.bookId,
    section: section ?? this.section,
    sort: sort ?? this.sort,
    createDate: createDate ?? this.createDate,
    remark: remark.present ? remark.value : this.remark,
    extraInfo: extraInfo.present ? extraInfo.value : this.extraInfo,
  );
  Budget copyWithCompanion(BudgetsCompanion data) {
    return Budget(
      id: data.id.present ? data.id.value : this.id,
      budgetType: data.budgetType.present
          ? data.budgetType.value
          : this.budgetType,
      recordCatId: data.recordCatId.present
          ? data.recordCatId.value
          : this.recordCatId,
      amountMinor: data.amountMinor.present
          ? data.amountMinor.value
          : this.amountMinor,
      bookId: data.bookId.present ? data.bookId.value : this.bookId,
      section: data.section.present ? data.section.value : this.section,
      sort: data.sort.present ? data.sort.value : this.sort,
      createDate: data.createDate.present
          ? data.createDate.value
          : this.createDate,
      remark: data.remark.present ? data.remark.value : this.remark,
      extraInfo: data.extraInfo.present ? data.extraInfo.value : this.extraInfo,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Budget(')
          ..write('id: $id, ')
          ..write('budgetType: $budgetType, ')
          ..write('recordCatId: $recordCatId, ')
          ..write('amountMinor: $amountMinor, ')
          ..write('bookId: $bookId, ')
          ..write('section: $section, ')
          ..write('sort: $sort, ')
          ..write('createDate: $createDate, ')
          ..write('remark: $remark, ')
          ..write('extraInfo: $extraInfo')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    budgetType,
    recordCatId,
    amountMinor,
    bookId,
    section,
    sort,
    createDate,
    remark,
    extraInfo,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Budget &&
          other.id == this.id &&
          other.budgetType == this.budgetType &&
          other.recordCatId == this.recordCatId &&
          other.amountMinor == this.amountMinor &&
          other.bookId == this.bookId &&
          other.section == this.section &&
          other.sort == this.sort &&
          other.createDate == this.createDate &&
          other.remark == this.remark &&
          other.extraInfo == this.extraInfo);
}

class BudgetsCompanion extends UpdateCompanion<Budget> {
  final Value<int> id;
  final Value<int> budgetType;
  final Value<int> recordCatId;
  final Value<BigInt> amountMinor;
  final Value<int> bookId;
  final Value<String> section;
  final Value<int> sort;
  final Value<int> createDate;
  final Value<String?> remark;
  final Value<String?> extraInfo;
  const BudgetsCompanion({
    this.id = const Value.absent(),
    this.budgetType = const Value.absent(),
    this.recordCatId = const Value.absent(),
    this.amountMinor = const Value.absent(),
    this.bookId = const Value.absent(),
    this.section = const Value.absent(),
    this.sort = const Value.absent(),
    this.createDate = const Value.absent(),
    this.remark = const Value.absent(),
    this.extraInfo = const Value.absent(),
  });
  BudgetsCompanion.insert({
    this.id = const Value.absent(),
    required int budgetType,
    required int recordCatId,
    required BigInt amountMinor,
    required int bookId,
    required String section,
    this.sort = const Value.absent(),
    required int createDate,
    this.remark = const Value.absent(),
    this.extraInfo = const Value.absent(),
  }) : budgetType = Value(budgetType),
       recordCatId = Value(recordCatId),
       amountMinor = Value(amountMinor),
       bookId = Value(bookId),
       section = Value(section),
       createDate = Value(createDate);
  static Insertable<Budget> custom({
    Expression<int>? id,
    Expression<int>? budgetType,
    Expression<int>? recordCatId,
    Expression<BigInt>? amountMinor,
    Expression<int>? bookId,
    Expression<String>? section,
    Expression<int>? sort,
    Expression<int>? createDate,
    Expression<String>? remark,
    Expression<String>? extraInfo,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (budgetType != null) 'budget_type': budgetType,
      if (recordCatId != null) 'record_cat_id': recordCatId,
      if (amountMinor != null) 'amount_minor': amountMinor,
      if (bookId != null) 'book_id': bookId,
      if (section != null) 'section': section,
      if (sort != null) 'sort': sort,
      if (createDate != null) 'create_date': createDate,
      if (remark != null) 'remark': remark,
      if (extraInfo != null) 'extra_info': extraInfo,
    });
  }

  BudgetsCompanion copyWith({
    Value<int>? id,
    Value<int>? budgetType,
    Value<int>? recordCatId,
    Value<BigInt>? amountMinor,
    Value<int>? bookId,
    Value<String>? section,
    Value<int>? sort,
    Value<int>? createDate,
    Value<String?>? remark,
    Value<String?>? extraInfo,
  }) {
    return BudgetsCompanion(
      id: id ?? this.id,
      budgetType: budgetType ?? this.budgetType,
      recordCatId: recordCatId ?? this.recordCatId,
      amountMinor: amountMinor ?? this.amountMinor,
      bookId: bookId ?? this.bookId,
      section: section ?? this.section,
      sort: sort ?? this.sort,
      createDate: createDate ?? this.createDate,
      remark: remark ?? this.remark,
      extraInfo: extraInfo ?? this.extraInfo,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (budgetType.present) {
      map['budget_type'] = Variable<int>(budgetType.value);
    }
    if (recordCatId.present) {
      map['record_cat_id'] = Variable<int>(recordCatId.value);
    }
    if (amountMinor.present) {
      map['amount_minor'] = Variable<BigInt>(amountMinor.value);
    }
    if (bookId.present) {
      map['book_id'] = Variable<int>(bookId.value);
    }
    if (section.present) {
      map['section'] = Variable<String>(section.value);
    }
    if (sort.present) {
      map['sort'] = Variable<int>(sort.value);
    }
    if (createDate.present) {
      map['create_date'] = Variable<int>(createDate.value);
    }
    if (remark.present) {
      map['remark'] = Variable<String>(remark.value);
    }
    if (extraInfo.present) {
      map['extra_info'] = Variable<String>(extraInfo.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('BudgetsCompanion(')
          ..write('id: $id, ')
          ..write('budgetType: $budgetType, ')
          ..write('recordCatId: $recordCatId, ')
          ..write('amountMinor: $amountMinor, ')
          ..write('bookId: $bookId, ')
          ..write('section: $section, ')
          ..write('sort: $sort, ')
          ..write('createDate: $createDate, ')
          ..write('remark: $remark, ')
          ..write('extraInfo: $extraInfo')
          ..write(')'))
        .toString();
  }
}

class $ImportPlatformsTable extends ImportPlatforms
    with TableInfo<$ImportPlatformsTable, ImportPlatform> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ImportPlatformsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _platformMeta = const VerificationMeta(
    'platform',
  );
  @override
  late final GeneratedColumn<String> platform = GeneratedColumn<String>(
    'platform',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _importRecordCountMeta = const VerificationMeta(
    'importRecordCount',
  );
  @override
  late final GeneratedColumn<int> importRecordCount = GeneratedColumn<int>(
    'import_record_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _importCategoryCountMeta =
      const VerificationMeta('importCategoryCount');
  @override
  late final GeneratedColumn<int> importCategoryCount = GeneratedColumn<int>(
    'import_category_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _importTimeMeta = const VerificationMeta(
    'importTime',
  );
  @override
  late final GeneratedColumn<int> importTime = GeneratedColumn<int>(
    'import_time',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _hiddenMeta = const VerificationMeta('hidden');
  @override
  late final GeneratedColumn<bool> hidden = GeneratedColumn<bool>(
    'hidden',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("hidden" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    platform,
    importRecordCount,
    importCategoryCount,
    importTime,
    hidden,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'import_platform';
  @override
  VerificationContext validateIntegrity(
    Insertable<ImportPlatform> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('platform')) {
      context.handle(
        _platformMeta,
        platform.isAcceptableOrUnknown(data['platform']!, _platformMeta),
      );
    } else if (isInserting) {
      context.missing(_platformMeta);
    }
    if (data.containsKey('import_record_count')) {
      context.handle(
        _importRecordCountMeta,
        importRecordCount.isAcceptableOrUnknown(
          data['import_record_count']!,
          _importRecordCountMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_importRecordCountMeta);
    }
    if (data.containsKey('import_category_count')) {
      context.handle(
        _importCategoryCountMeta,
        importCategoryCount.isAcceptableOrUnknown(
          data['import_category_count']!,
          _importCategoryCountMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_importCategoryCountMeta);
    }
    if (data.containsKey('import_time')) {
      context.handle(
        _importTimeMeta,
        importTime.isAcceptableOrUnknown(data['import_time']!, _importTimeMeta),
      );
    } else if (isInserting) {
      context.missing(_importTimeMeta);
    }
    if (data.containsKey('hidden')) {
      context.handle(
        _hiddenMeta,
        hidden.isAcceptableOrUnknown(data['hidden']!, _hiddenMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ImportPlatform map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ImportPlatform(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      platform: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}platform'],
      )!,
      importRecordCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}import_record_count'],
      )!,
      importCategoryCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}import_category_count'],
      )!,
      importTime: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}import_time'],
      )!,
      hidden: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}hidden'],
      )!,
    );
  }

  @override
  $ImportPlatformsTable createAlias(String alias) {
    return $ImportPlatformsTable(attachedDatabase, alias);
  }
}

class ImportPlatform extends DataClass implements Insertable<ImportPlatform> {
  final int id;
  final String platform;
  final int importRecordCount;
  final int importCategoryCount;
  final int importTime;
  final bool hidden;
  const ImportPlatform({
    required this.id,
    required this.platform,
    required this.importRecordCount,
    required this.importCategoryCount,
    required this.importTime,
    required this.hidden,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['platform'] = Variable<String>(platform);
    map['import_record_count'] = Variable<int>(importRecordCount);
    map['import_category_count'] = Variable<int>(importCategoryCount);
    map['import_time'] = Variable<int>(importTime);
    map['hidden'] = Variable<bool>(hidden);
    return map;
  }

  ImportPlatformsCompanion toCompanion(bool nullToAbsent) {
    return ImportPlatformsCompanion(
      id: Value(id),
      platform: Value(platform),
      importRecordCount: Value(importRecordCount),
      importCategoryCount: Value(importCategoryCount),
      importTime: Value(importTime),
      hidden: Value(hidden),
    );
  }

  factory ImportPlatform.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ImportPlatform(
      id: serializer.fromJson<int>(json['id']),
      platform: serializer.fromJson<String>(json['platform']),
      importRecordCount: serializer.fromJson<int>(json['importRecordCount']),
      importCategoryCount: serializer.fromJson<int>(
        json['importCategoryCount'],
      ),
      importTime: serializer.fromJson<int>(json['importTime']),
      hidden: serializer.fromJson<bool>(json['hidden']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'platform': serializer.toJson<String>(platform),
      'importRecordCount': serializer.toJson<int>(importRecordCount),
      'importCategoryCount': serializer.toJson<int>(importCategoryCount),
      'importTime': serializer.toJson<int>(importTime),
      'hidden': serializer.toJson<bool>(hidden),
    };
  }

  ImportPlatform copyWith({
    int? id,
    String? platform,
    int? importRecordCount,
    int? importCategoryCount,
    int? importTime,
    bool? hidden,
  }) => ImportPlatform(
    id: id ?? this.id,
    platform: platform ?? this.platform,
    importRecordCount: importRecordCount ?? this.importRecordCount,
    importCategoryCount: importCategoryCount ?? this.importCategoryCount,
    importTime: importTime ?? this.importTime,
    hidden: hidden ?? this.hidden,
  );
  ImportPlatform copyWithCompanion(ImportPlatformsCompanion data) {
    return ImportPlatform(
      id: data.id.present ? data.id.value : this.id,
      platform: data.platform.present ? data.platform.value : this.platform,
      importRecordCount: data.importRecordCount.present
          ? data.importRecordCount.value
          : this.importRecordCount,
      importCategoryCount: data.importCategoryCount.present
          ? data.importCategoryCount.value
          : this.importCategoryCount,
      importTime: data.importTime.present
          ? data.importTime.value
          : this.importTime,
      hidden: data.hidden.present ? data.hidden.value : this.hidden,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ImportPlatform(')
          ..write('id: $id, ')
          ..write('platform: $platform, ')
          ..write('importRecordCount: $importRecordCount, ')
          ..write('importCategoryCount: $importCategoryCount, ')
          ..write('importTime: $importTime, ')
          ..write('hidden: $hidden')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    platform,
    importRecordCount,
    importCategoryCount,
    importTime,
    hidden,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ImportPlatform &&
          other.id == this.id &&
          other.platform == this.platform &&
          other.importRecordCount == this.importRecordCount &&
          other.importCategoryCount == this.importCategoryCount &&
          other.importTime == this.importTime &&
          other.hidden == this.hidden);
}

class ImportPlatformsCompanion extends UpdateCompanion<ImportPlatform> {
  final Value<int> id;
  final Value<String> platform;
  final Value<int> importRecordCount;
  final Value<int> importCategoryCount;
  final Value<int> importTime;
  final Value<bool> hidden;
  const ImportPlatformsCompanion({
    this.id = const Value.absent(),
    this.platform = const Value.absent(),
    this.importRecordCount = const Value.absent(),
    this.importCategoryCount = const Value.absent(),
    this.importTime = const Value.absent(),
    this.hidden = const Value.absent(),
  });
  ImportPlatformsCompanion.insert({
    this.id = const Value.absent(),
    required String platform,
    required int importRecordCount,
    required int importCategoryCount,
    required int importTime,
    this.hidden = const Value.absent(),
  }) : platform = Value(platform),
       importRecordCount = Value(importRecordCount),
       importCategoryCount = Value(importCategoryCount),
       importTime = Value(importTime);
  static Insertable<ImportPlatform> custom({
    Expression<int>? id,
    Expression<String>? platform,
    Expression<int>? importRecordCount,
    Expression<int>? importCategoryCount,
    Expression<int>? importTime,
    Expression<bool>? hidden,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (platform != null) 'platform': platform,
      if (importRecordCount != null) 'import_record_count': importRecordCount,
      if (importCategoryCount != null)
        'import_category_count': importCategoryCount,
      if (importTime != null) 'import_time': importTime,
      if (hidden != null) 'hidden': hidden,
    });
  }

  ImportPlatformsCompanion copyWith({
    Value<int>? id,
    Value<String>? platform,
    Value<int>? importRecordCount,
    Value<int>? importCategoryCount,
    Value<int>? importTime,
    Value<bool>? hidden,
  }) {
    return ImportPlatformsCompanion(
      id: id ?? this.id,
      platform: platform ?? this.platform,
      importRecordCount: importRecordCount ?? this.importRecordCount,
      importCategoryCount: importCategoryCount ?? this.importCategoryCount,
      importTime: importTime ?? this.importTime,
      hidden: hidden ?? this.hidden,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (platform.present) {
      map['platform'] = Variable<String>(platform.value);
    }
    if (importRecordCount.present) {
      map['import_record_count'] = Variable<int>(importRecordCount.value);
    }
    if (importCategoryCount.present) {
      map['import_category_count'] = Variable<int>(importCategoryCount.value);
    }
    if (importTime.present) {
      map['import_time'] = Variable<int>(importTime.value);
    }
    if (hidden.present) {
      map['hidden'] = Variable<bool>(hidden.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ImportPlatformsCompanion(')
          ..write('id: $id, ')
          ..write('platform: $platform, ')
          ..write('importRecordCount: $importRecordCount, ')
          ..write('importCategoryCount: $importCategoryCount, ')
          ..write('importTime: $importTime, ')
          ..write('hidden: $hidden')
          ..write(')'))
        .toString();
  }
}

class $RecordsTable extends Records
    with TableInfo<$RecordsTable, LedgerRecord> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $RecordsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _recordIdMeta = const VerificationMeta(
    'recordId',
  );
  @override
  late final GeneratedColumn<String> recordId = GeneratedColumn<String>(
    'record_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<int> type = GeneratedColumn<int>(
    'type',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _subTypeMeta = const VerificationMeta(
    'subType',
  );
  @override
  late final GeneratedColumn<int> subType = GeneratedColumn<int>(
    'sub_type',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(-1),
  );
  static const VerificationMeta _moneyMinorMeta = const VerificationMeta(
    'moneyMinor',
  );
  @override
  late final GeneratedColumn<BigInt> moneyMinor = GeneratedColumn<BigInt>(
    'money_minor',
    aliasedName,
    false,
    type: DriftSqlType.bigInt,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _remarkMeta = const VerificationMeta('remark');
  @override
  late final GeneratedColumn<String> remark = GeneratedColumn<String>(
    'remark',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _recordTimeMeta = const VerificationMeta(
    'recordTime',
  );
  @override
  late final GeneratedColumn<int> recordTime = GeneratedColumn<int>(
    'record_time',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _recordCatIdMeta = const VerificationMeta(
    'recordCatId',
  );
  @override
  late final GeneratedColumn<int> recordCatId = GeneratedColumn<int>(
    'record_cat_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(-1),
  );
  static const VerificationMeta _assetIdMeta = const VerificationMeta(
    'assetId',
  );
  @override
  late final GeneratedColumn<int> assetId = GeneratedColumn<int>(
    'asset_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(-1),
  );
  static const VerificationMeta _fromAssetIdMeta = const VerificationMeta(
    'fromAssetId',
  );
  @override
  late final GeneratedColumn<int> fromAssetId = GeneratedColumn<int>(
    'from_asset_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(-1),
  );
  static const VerificationMeta _toAssetIdMeta = const VerificationMeta(
    'toAssetId',
  );
  @override
  late final GeneratedColumn<int> toAssetId = GeneratedColumn<int>(
    'to_asset_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(-1),
  );
  static const VerificationMeta _accountBookIdMeta = const VerificationMeta(
    'accountBookId',
  );
  @override
  late final GeneratedColumn<int> accountBookId = GeneratedColumn<int>(
    'account_book_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _excludeBudgetMeta = const VerificationMeta(
    'excludeBudget',
  );
  @override
  late final GeneratedColumn<bool> excludeBudget = GeneratedColumn<bool>(
    'exclude_budget',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("exclude_budget" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _excludeExInMeta = const VerificationMeta(
    'excludeExIn',
  );
  @override
  late final GeneratedColumn<bool> excludeExIn = GeneratedColumn<bool>(
    'exclude_ex_in',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("exclude_ex_in" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _platformIdMeta = const VerificationMeta(
    'platformId',
  );
  @override
  late final GeneratedColumn<int> platformId = GeneratedColumn<int>(
    'platform_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(-1),
  );
  static const VerificationMeta _periodIdMeta = const VerificationMeta(
    'periodId',
  );
  @override
  late final GeneratedColumn<int> periodId = GeneratedColumn<int>(
    'period_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(-1),
  );
  static const VerificationMeta _installmentMeta = const VerificationMeta(
    'installment',
  );
  @override
  late final GeneratedColumn<String> installment = GeneratedColumn<String>(
    'installment',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _imagesMeta = const VerificationMeta('images');
  @override
  late final GeneratedColumn<String> images = GeneratedColumn<String>(
    'images',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _relInfoMeta = const VerificationMeta(
    'relInfo',
  );
  @override
  late final GeneratedColumn<String> relInfo = GeneratedColumn<String>(
    'rel_info',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _discountMinorMeta = const VerificationMeta(
    'discountMinor',
  );
  @override
  late final GeneratedColumn<BigInt> discountMinor = GeneratedColumn<BigInt>(
    'discount_minor',
    aliasedName,
    true,
    type: DriftSqlType.bigInt,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _extraInfoMeta = const VerificationMeta(
    'extraInfo',
  );
  @override
  late final GeneratedColumn<String> extraInfo = GeneratedColumn<String>(
    'extra_info',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createDateMeta = const VerificationMeta(
    'createDate',
  );
  @override
  late final GeneratedColumn<int> createDate = GeneratedColumn<int>(
    'create_date',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    recordId,
    type,
    subType,
    moneyMinor,
    remark,
    recordTime,
    recordCatId,
    assetId,
    fromAssetId,
    toAssetId,
    accountBookId,
    excludeBudget,
    excludeExIn,
    platformId,
    periodId,
    installment,
    images,
    relInfo,
    discountMinor,
    extraInfo,
    createDate,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'record';
  @override
  VerificationContext validateIntegrity(
    Insertable<LedgerRecord> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('record_id')) {
      context.handle(
        _recordIdMeta,
        recordId.isAcceptableOrUnknown(data['record_id']!, _recordIdMeta),
      );
    } else if (isInserting) {
      context.missing(_recordIdMeta);
    }
    if (data.containsKey('type')) {
      context.handle(
        _typeMeta,
        type.isAcceptableOrUnknown(data['type']!, _typeMeta),
      );
    } else if (isInserting) {
      context.missing(_typeMeta);
    }
    if (data.containsKey('sub_type')) {
      context.handle(
        _subTypeMeta,
        subType.isAcceptableOrUnknown(data['sub_type']!, _subTypeMeta),
      );
    }
    if (data.containsKey('money_minor')) {
      context.handle(
        _moneyMinorMeta,
        moneyMinor.isAcceptableOrUnknown(data['money_minor']!, _moneyMinorMeta),
      );
    } else if (isInserting) {
      context.missing(_moneyMinorMeta);
    }
    if (data.containsKey('remark')) {
      context.handle(
        _remarkMeta,
        remark.isAcceptableOrUnknown(data['remark']!, _remarkMeta),
      );
    }
    if (data.containsKey('record_time')) {
      context.handle(
        _recordTimeMeta,
        recordTime.isAcceptableOrUnknown(data['record_time']!, _recordTimeMeta),
      );
    } else if (isInserting) {
      context.missing(_recordTimeMeta);
    }
    if (data.containsKey('record_cat_id')) {
      context.handle(
        _recordCatIdMeta,
        recordCatId.isAcceptableOrUnknown(
          data['record_cat_id']!,
          _recordCatIdMeta,
        ),
      );
    }
    if (data.containsKey('asset_id')) {
      context.handle(
        _assetIdMeta,
        assetId.isAcceptableOrUnknown(data['asset_id']!, _assetIdMeta),
      );
    }
    if (data.containsKey('from_asset_id')) {
      context.handle(
        _fromAssetIdMeta,
        fromAssetId.isAcceptableOrUnknown(
          data['from_asset_id']!,
          _fromAssetIdMeta,
        ),
      );
    }
    if (data.containsKey('to_asset_id')) {
      context.handle(
        _toAssetIdMeta,
        toAssetId.isAcceptableOrUnknown(data['to_asset_id']!, _toAssetIdMeta),
      );
    }
    if (data.containsKey('account_book_id')) {
      context.handle(
        _accountBookIdMeta,
        accountBookId.isAcceptableOrUnknown(
          data['account_book_id']!,
          _accountBookIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_accountBookIdMeta);
    }
    if (data.containsKey('exclude_budget')) {
      context.handle(
        _excludeBudgetMeta,
        excludeBudget.isAcceptableOrUnknown(
          data['exclude_budget']!,
          _excludeBudgetMeta,
        ),
      );
    }
    if (data.containsKey('exclude_ex_in')) {
      context.handle(
        _excludeExInMeta,
        excludeExIn.isAcceptableOrUnknown(
          data['exclude_ex_in']!,
          _excludeExInMeta,
        ),
      );
    }
    if (data.containsKey('platform_id')) {
      context.handle(
        _platformIdMeta,
        platformId.isAcceptableOrUnknown(data['platform_id']!, _platformIdMeta),
      );
    }
    if (data.containsKey('period_id')) {
      context.handle(
        _periodIdMeta,
        periodId.isAcceptableOrUnknown(data['period_id']!, _periodIdMeta),
      );
    }
    if (data.containsKey('installment')) {
      context.handle(
        _installmentMeta,
        installment.isAcceptableOrUnknown(
          data['installment']!,
          _installmentMeta,
        ),
      );
    }
    if (data.containsKey('images')) {
      context.handle(
        _imagesMeta,
        images.isAcceptableOrUnknown(data['images']!, _imagesMeta),
      );
    }
    if (data.containsKey('rel_info')) {
      context.handle(
        _relInfoMeta,
        relInfo.isAcceptableOrUnknown(data['rel_info']!, _relInfoMeta),
      );
    }
    if (data.containsKey('discount_minor')) {
      context.handle(
        _discountMinorMeta,
        discountMinor.isAcceptableOrUnknown(
          data['discount_minor']!,
          _discountMinorMeta,
        ),
      );
    }
    if (data.containsKey('extra_info')) {
      context.handle(
        _extraInfoMeta,
        extraInfo.isAcceptableOrUnknown(data['extra_info']!, _extraInfoMeta),
      );
    }
    if (data.containsKey('create_date')) {
      context.handle(
        _createDateMeta,
        createDate.isAcceptableOrUnknown(data['create_date']!, _createDateMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {recordId};
  @override
  LedgerRecord map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LedgerRecord(
      recordId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}record_id'],
      )!,
      type: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}type'],
      )!,
      subType: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sub_type'],
      )!,
      moneyMinor: attachedDatabase.typeMapping.read(
        DriftSqlType.bigInt,
        data['${effectivePrefix}money_minor'],
      )!,
      remark: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}remark'],
      )!,
      recordTime: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}record_time'],
      )!,
      recordCatId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}record_cat_id'],
      )!,
      assetId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}asset_id'],
      )!,
      fromAssetId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}from_asset_id'],
      )!,
      toAssetId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}to_asset_id'],
      )!,
      accountBookId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}account_book_id'],
      )!,
      excludeBudget: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}exclude_budget'],
      )!,
      excludeExIn: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}exclude_ex_in'],
      )!,
      platformId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}platform_id'],
      )!,
      periodId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}period_id'],
      )!,
      installment: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}installment'],
      ),
      images: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}images'],
      ),
      relInfo: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}rel_info'],
      ),
      discountMinor: attachedDatabase.typeMapping.read(
        DriftSqlType.bigInt,
        data['${effectivePrefix}discount_minor'],
      ),
      extraInfo: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}extra_info'],
      ),
      createDate: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}create_date'],
      ),
    );
  }

  @override
  $RecordsTable createAlias(String alias) {
    return $RecordsTable(attachedDatabase, alias);
  }
}

class LedgerRecord extends DataClass implements Insertable<LedgerRecord> {
  final String recordId;
  final int type;
  final int subType;
  final BigInt moneyMinor;
  final String remark;

  /// Epoch milliseconds.
  final int recordTime;
  final int recordCatId;
  final int assetId;
  final int fromAssetId;
  final int toAssetId;
  final int accountBookId;
  final bool excludeBudget;
  final bool excludeExIn;
  final int platformId;
  final int periodId;
  final String? installment;
  final String? images;
  final String? relInfo;
  final BigInt? discountMinor;
  final String? extraInfo;
  final int? createDate;
  const LedgerRecord({
    required this.recordId,
    required this.type,
    required this.subType,
    required this.moneyMinor,
    required this.remark,
    required this.recordTime,
    required this.recordCatId,
    required this.assetId,
    required this.fromAssetId,
    required this.toAssetId,
    required this.accountBookId,
    required this.excludeBudget,
    required this.excludeExIn,
    required this.platformId,
    required this.periodId,
    this.installment,
    this.images,
    this.relInfo,
    this.discountMinor,
    this.extraInfo,
    this.createDate,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['record_id'] = Variable<String>(recordId);
    map['type'] = Variable<int>(type);
    map['sub_type'] = Variable<int>(subType);
    map['money_minor'] = Variable<BigInt>(moneyMinor);
    map['remark'] = Variable<String>(remark);
    map['record_time'] = Variable<int>(recordTime);
    map['record_cat_id'] = Variable<int>(recordCatId);
    map['asset_id'] = Variable<int>(assetId);
    map['from_asset_id'] = Variable<int>(fromAssetId);
    map['to_asset_id'] = Variable<int>(toAssetId);
    map['account_book_id'] = Variable<int>(accountBookId);
    map['exclude_budget'] = Variable<bool>(excludeBudget);
    map['exclude_ex_in'] = Variable<bool>(excludeExIn);
    map['platform_id'] = Variable<int>(platformId);
    map['period_id'] = Variable<int>(periodId);
    if (!nullToAbsent || installment != null) {
      map['installment'] = Variable<String>(installment);
    }
    if (!nullToAbsent || images != null) {
      map['images'] = Variable<String>(images);
    }
    if (!nullToAbsent || relInfo != null) {
      map['rel_info'] = Variable<String>(relInfo);
    }
    if (!nullToAbsent || discountMinor != null) {
      map['discount_minor'] = Variable<BigInt>(discountMinor);
    }
    if (!nullToAbsent || extraInfo != null) {
      map['extra_info'] = Variable<String>(extraInfo);
    }
    if (!nullToAbsent || createDate != null) {
      map['create_date'] = Variable<int>(createDate);
    }
    return map;
  }

  RecordsCompanion toCompanion(bool nullToAbsent) {
    return RecordsCompanion(
      recordId: Value(recordId),
      type: Value(type),
      subType: Value(subType),
      moneyMinor: Value(moneyMinor),
      remark: Value(remark),
      recordTime: Value(recordTime),
      recordCatId: Value(recordCatId),
      assetId: Value(assetId),
      fromAssetId: Value(fromAssetId),
      toAssetId: Value(toAssetId),
      accountBookId: Value(accountBookId),
      excludeBudget: Value(excludeBudget),
      excludeExIn: Value(excludeExIn),
      platformId: Value(platformId),
      periodId: Value(periodId),
      installment: installment == null && nullToAbsent
          ? const Value.absent()
          : Value(installment),
      images: images == null && nullToAbsent
          ? const Value.absent()
          : Value(images),
      relInfo: relInfo == null && nullToAbsent
          ? const Value.absent()
          : Value(relInfo),
      discountMinor: discountMinor == null && nullToAbsent
          ? const Value.absent()
          : Value(discountMinor),
      extraInfo: extraInfo == null && nullToAbsent
          ? const Value.absent()
          : Value(extraInfo),
      createDate: createDate == null && nullToAbsent
          ? const Value.absent()
          : Value(createDate),
    );
  }

  factory LedgerRecord.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LedgerRecord(
      recordId: serializer.fromJson<String>(json['recordId']),
      type: serializer.fromJson<int>(json['type']),
      subType: serializer.fromJson<int>(json['subType']),
      moneyMinor: serializer.fromJson<BigInt>(json['moneyMinor']),
      remark: serializer.fromJson<String>(json['remark']),
      recordTime: serializer.fromJson<int>(json['recordTime']),
      recordCatId: serializer.fromJson<int>(json['recordCatId']),
      assetId: serializer.fromJson<int>(json['assetId']),
      fromAssetId: serializer.fromJson<int>(json['fromAssetId']),
      toAssetId: serializer.fromJson<int>(json['toAssetId']),
      accountBookId: serializer.fromJson<int>(json['accountBookId']),
      excludeBudget: serializer.fromJson<bool>(json['excludeBudget']),
      excludeExIn: serializer.fromJson<bool>(json['excludeExIn']),
      platformId: serializer.fromJson<int>(json['platformId']),
      periodId: serializer.fromJson<int>(json['periodId']),
      installment: serializer.fromJson<String?>(json['installment']),
      images: serializer.fromJson<String?>(json['images']),
      relInfo: serializer.fromJson<String?>(json['relInfo']),
      discountMinor: serializer.fromJson<BigInt?>(json['discountMinor']),
      extraInfo: serializer.fromJson<String?>(json['extraInfo']),
      createDate: serializer.fromJson<int?>(json['createDate']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'recordId': serializer.toJson<String>(recordId),
      'type': serializer.toJson<int>(type),
      'subType': serializer.toJson<int>(subType),
      'moneyMinor': serializer.toJson<BigInt>(moneyMinor),
      'remark': serializer.toJson<String>(remark),
      'recordTime': serializer.toJson<int>(recordTime),
      'recordCatId': serializer.toJson<int>(recordCatId),
      'assetId': serializer.toJson<int>(assetId),
      'fromAssetId': serializer.toJson<int>(fromAssetId),
      'toAssetId': serializer.toJson<int>(toAssetId),
      'accountBookId': serializer.toJson<int>(accountBookId),
      'excludeBudget': serializer.toJson<bool>(excludeBudget),
      'excludeExIn': serializer.toJson<bool>(excludeExIn),
      'platformId': serializer.toJson<int>(platformId),
      'periodId': serializer.toJson<int>(periodId),
      'installment': serializer.toJson<String?>(installment),
      'images': serializer.toJson<String?>(images),
      'relInfo': serializer.toJson<String?>(relInfo),
      'discountMinor': serializer.toJson<BigInt?>(discountMinor),
      'extraInfo': serializer.toJson<String?>(extraInfo),
      'createDate': serializer.toJson<int?>(createDate),
    };
  }

  LedgerRecord copyWith({
    String? recordId,
    int? type,
    int? subType,
    BigInt? moneyMinor,
    String? remark,
    int? recordTime,
    int? recordCatId,
    int? assetId,
    int? fromAssetId,
    int? toAssetId,
    int? accountBookId,
    bool? excludeBudget,
    bool? excludeExIn,
    int? platformId,
    int? periodId,
    Value<String?> installment = const Value.absent(),
    Value<String?> images = const Value.absent(),
    Value<String?> relInfo = const Value.absent(),
    Value<BigInt?> discountMinor = const Value.absent(),
    Value<String?> extraInfo = const Value.absent(),
    Value<int?> createDate = const Value.absent(),
  }) => LedgerRecord(
    recordId: recordId ?? this.recordId,
    type: type ?? this.type,
    subType: subType ?? this.subType,
    moneyMinor: moneyMinor ?? this.moneyMinor,
    remark: remark ?? this.remark,
    recordTime: recordTime ?? this.recordTime,
    recordCatId: recordCatId ?? this.recordCatId,
    assetId: assetId ?? this.assetId,
    fromAssetId: fromAssetId ?? this.fromAssetId,
    toAssetId: toAssetId ?? this.toAssetId,
    accountBookId: accountBookId ?? this.accountBookId,
    excludeBudget: excludeBudget ?? this.excludeBudget,
    excludeExIn: excludeExIn ?? this.excludeExIn,
    platformId: platformId ?? this.platformId,
    periodId: periodId ?? this.periodId,
    installment: installment.present ? installment.value : this.installment,
    images: images.present ? images.value : this.images,
    relInfo: relInfo.present ? relInfo.value : this.relInfo,
    discountMinor: discountMinor.present
        ? discountMinor.value
        : this.discountMinor,
    extraInfo: extraInfo.present ? extraInfo.value : this.extraInfo,
    createDate: createDate.present ? createDate.value : this.createDate,
  );
  LedgerRecord copyWithCompanion(RecordsCompanion data) {
    return LedgerRecord(
      recordId: data.recordId.present ? data.recordId.value : this.recordId,
      type: data.type.present ? data.type.value : this.type,
      subType: data.subType.present ? data.subType.value : this.subType,
      moneyMinor: data.moneyMinor.present
          ? data.moneyMinor.value
          : this.moneyMinor,
      remark: data.remark.present ? data.remark.value : this.remark,
      recordTime: data.recordTime.present
          ? data.recordTime.value
          : this.recordTime,
      recordCatId: data.recordCatId.present
          ? data.recordCatId.value
          : this.recordCatId,
      assetId: data.assetId.present ? data.assetId.value : this.assetId,
      fromAssetId: data.fromAssetId.present
          ? data.fromAssetId.value
          : this.fromAssetId,
      toAssetId: data.toAssetId.present ? data.toAssetId.value : this.toAssetId,
      accountBookId: data.accountBookId.present
          ? data.accountBookId.value
          : this.accountBookId,
      excludeBudget: data.excludeBudget.present
          ? data.excludeBudget.value
          : this.excludeBudget,
      excludeExIn: data.excludeExIn.present
          ? data.excludeExIn.value
          : this.excludeExIn,
      platformId: data.platformId.present
          ? data.platformId.value
          : this.platformId,
      periodId: data.periodId.present ? data.periodId.value : this.periodId,
      installment: data.installment.present
          ? data.installment.value
          : this.installment,
      images: data.images.present ? data.images.value : this.images,
      relInfo: data.relInfo.present ? data.relInfo.value : this.relInfo,
      discountMinor: data.discountMinor.present
          ? data.discountMinor.value
          : this.discountMinor,
      extraInfo: data.extraInfo.present ? data.extraInfo.value : this.extraInfo,
      createDate: data.createDate.present
          ? data.createDate.value
          : this.createDate,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LedgerRecord(')
          ..write('recordId: $recordId, ')
          ..write('type: $type, ')
          ..write('subType: $subType, ')
          ..write('moneyMinor: $moneyMinor, ')
          ..write('remark: $remark, ')
          ..write('recordTime: $recordTime, ')
          ..write('recordCatId: $recordCatId, ')
          ..write('assetId: $assetId, ')
          ..write('fromAssetId: $fromAssetId, ')
          ..write('toAssetId: $toAssetId, ')
          ..write('accountBookId: $accountBookId, ')
          ..write('excludeBudget: $excludeBudget, ')
          ..write('excludeExIn: $excludeExIn, ')
          ..write('platformId: $platformId, ')
          ..write('periodId: $periodId, ')
          ..write('installment: $installment, ')
          ..write('images: $images, ')
          ..write('relInfo: $relInfo, ')
          ..write('discountMinor: $discountMinor, ')
          ..write('extraInfo: $extraInfo, ')
          ..write('createDate: $createDate')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    recordId,
    type,
    subType,
    moneyMinor,
    remark,
    recordTime,
    recordCatId,
    assetId,
    fromAssetId,
    toAssetId,
    accountBookId,
    excludeBudget,
    excludeExIn,
    platformId,
    periodId,
    installment,
    images,
    relInfo,
    discountMinor,
    extraInfo,
    createDate,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LedgerRecord &&
          other.recordId == this.recordId &&
          other.type == this.type &&
          other.subType == this.subType &&
          other.moneyMinor == this.moneyMinor &&
          other.remark == this.remark &&
          other.recordTime == this.recordTime &&
          other.recordCatId == this.recordCatId &&
          other.assetId == this.assetId &&
          other.fromAssetId == this.fromAssetId &&
          other.toAssetId == this.toAssetId &&
          other.accountBookId == this.accountBookId &&
          other.excludeBudget == this.excludeBudget &&
          other.excludeExIn == this.excludeExIn &&
          other.platformId == this.platformId &&
          other.periodId == this.periodId &&
          other.installment == this.installment &&
          other.images == this.images &&
          other.relInfo == this.relInfo &&
          other.discountMinor == this.discountMinor &&
          other.extraInfo == this.extraInfo &&
          other.createDate == this.createDate);
}

class RecordsCompanion extends UpdateCompanion<LedgerRecord> {
  final Value<String> recordId;
  final Value<int> type;
  final Value<int> subType;
  final Value<BigInt> moneyMinor;
  final Value<String> remark;
  final Value<int> recordTime;
  final Value<int> recordCatId;
  final Value<int> assetId;
  final Value<int> fromAssetId;
  final Value<int> toAssetId;
  final Value<int> accountBookId;
  final Value<bool> excludeBudget;
  final Value<bool> excludeExIn;
  final Value<int> platformId;
  final Value<int> periodId;
  final Value<String?> installment;
  final Value<String?> images;
  final Value<String?> relInfo;
  final Value<BigInt?> discountMinor;
  final Value<String?> extraInfo;
  final Value<int?> createDate;
  final Value<int> rowid;
  const RecordsCompanion({
    this.recordId = const Value.absent(),
    this.type = const Value.absent(),
    this.subType = const Value.absent(),
    this.moneyMinor = const Value.absent(),
    this.remark = const Value.absent(),
    this.recordTime = const Value.absent(),
    this.recordCatId = const Value.absent(),
    this.assetId = const Value.absent(),
    this.fromAssetId = const Value.absent(),
    this.toAssetId = const Value.absent(),
    this.accountBookId = const Value.absent(),
    this.excludeBudget = const Value.absent(),
    this.excludeExIn = const Value.absent(),
    this.platformId = const Value.absent(),
    this.periodId = const Value.absent(),
    this.installment = const Value.absent(),
    this.images = const Value.absent(),
    this.relInfo = const Value.absent(),
    this.discountMinor = const Value.absent(),
    this.extraInfo = const Value.absent(),
    this.createDate = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  RecordsCompanion.insert({
    required String recordId,
    required int type,
    this.subType = const Value.absent(),
    required BigInt moneyMinor,
    this.remark = const Value.absent(),
    required int recordTime,
    this.recordCatId = const Value.absent(),
    this.assetId = const Value.absent(),
    this.fromAssetId = const Value.absent(),
    this.toAssetId = const Value.absent(),
    required int accountBookId,
    this.excludeBudget = const Value.absent(),
    this.excludeExIn = const Value.absent(),
    this.platformId = const Value.absent(),
    this.periodId = const Value.absent(),
    this.installment = const Value.absent(),
    this.images = const Value.absent(),
    this.relInfo = const Value.absent(),
    this.discountMinor = const Value.absent(),
    this.extraInfo = const Value.absent(),
    this.createDate = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : recordId = Value(recordId),
       type = Value(type),
       moneyMinor = Value(moneyMinor),
       recordTime = Value(recordTime),
       accountBookId = Value(accountBookId);
  static Insertable<LedgerRecord> custom({
    Expression<String>? recordId,
    Expression<int>? type,
    Expression<int>? subType,
    Expression<BigInt>? moneyMinor,
    Expression<String>? remark,
    Expression<int>? recordTime,
    Expression<int>? recordCatId,
    Expression<int>? assetId,
    Expression<int>? fromAssetId,
    Expression<int>? toAssetId,
    Expression<int>? accountBookId,
    Expression<bool>? excludeBudget,
    Expression<bool>? excludeExIn,
    Expression<int>? platformId,
    Expression<int>? periodId,
    Expression<String>? installment,
    Expression<String>? images,
    Expression<String>? relInfo,
    Expression<BigInt>? discountMinor,
    Expression<String>? extraInfo,
    Expression<int>? createDate,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (recordId != null) 'record_id': recordId,
      if (type != null) 'type': type,
      if (subType != null) 'sub_type': subType,
      if (moneyMinor != null) 'money_minor': moneyMinor,
      if (remark != null) 'remark': remark,
      if (recordTime != null) 'record_time': recordTime,
      if (recordCatId != null) 'record_cat_id': recordCatId,
      if (assetId != null) 'asset_id': assetId,
      if (fromAssetId != null) 'from_asset_id': fromAssetId,
      if (toAssetId != null) 'to_asset_id': toAssetId,
      if (accountBookId != null) 'account_book_id': accountBookId,
      if (excludeBudget != null) 'exclude_budget': excludeBudget,
      if (excludeExIn != null) 'exclude_ex_in': excludeExIn,
      if (platformId != null) 'platform_id': platformId,
      if (periodId != null) 'period_id': periodId,
      if (installment != null) 'installment': installment,
      if (images != null) 'images': images,
      if (relInfo != null) 'rel_info': relInfo,
      if (discountMinor != null) 'discount_minor': discountMinor,
      if (extraInfo != null) 'extra_info': extraInfo,
      if (createDate != null) 'create_date': createDate,
      if (rowid != null) 'rowid': rowid,
    });
  }

  RecordsCompanion copyWith({
    Value<String>? recordId,
    Value<int>? type,
    Value<int>? subType,
    Value<BigInt>? moneyMinor,
    Value<String>? remark,
    Value<int>? recordTime,
    Value<int>? recordCatId,
    Value<int>? assetId,
    Value<int>? fromAssetId,
    Value<int>? toAssetId,
    Value<int>? accountBookId,
    Value<bool>? excludeBudget,
    Value<bool>? excludeExIn,
    Value<int>? platformId,
    Value<int>? periodId,
    Value<String?>? installment,
    Value<String?>? images,
    Value<String?>? relInfo,
    Value<BigInt?>? discountMinor,
    Value<String?>? extraInfo,
    Value<int?>? createDate,
    Value<int>? rowid,
  }) {
    return RecordsCompanion(
      recordId: recordId ?? this.recordId,
      type: type ?? this.type,
      subType: subType ?? this.subType,
      moneyMinor: moneyMinor ?? this.moneyMinor,
      remark: remark ?? this.remark,
      recordTime: recordTime ?? this.recordTime,
      recordCatId: recordCatId ?? this.recordCatId,
      assetId: assetId ?? this.assetId,
      fromAssetId: fromAssetId ?? this.fromAssetId,
      toAssetId: toAssetId ?? this.toAssetId,
      accountBookId: accountBookId ?? this.accountBookId,
      excludeBudget: excludeBudget ?? this.excludeBudget,
      excludeExIn: excludeExIn ?? this.excludeExIn,
      platformId: platformId ?? this.platformId,
      periodId: periodId ?? this.periodId,
      installment: installment ?? this.installment,
      images: images ?? this.images,
      relInfo: relInfo ?? this.relInfo,
      discountMinor: discountMinor ?? this.discountMinor,
      extraInfo: extraInfo ?? this.extraInfo,
      createDate: createDate ?? this.createDate,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (recordId.present) {
      map['record_id'] = Variable<String>(recordId.value);
    }
    if (type.present) {
      map['type'] = Variable<int>(type.value);
    }
    if (subType.present) {
      map['sub_type'] = Variable<int>(subType.value);
    }
    if (moneyMinor.present) {
      map['money_minor'] = Variable<BigInt>(moneyMinor.value);
    }
    if (remark.present) {
      map['remark'] = Variable<String>(remark.value);
    }
    if (recordTime.present) {
      map['record_time'] = Variable<int>(recordTime.value);
    }
    if (recordCatId.present) {
      map['record_cat_id'] = Variable<int>(recordCatId.value);
    }
    if (assetId.present) {
      map['asset_id'] = Variable<int>(assetId.value);
    }
    if (fromAssetId.present) {
      map['from_asset_id'] = Variable<int>(fromAssetId.value);
    }
    if (toAssetId.present) {
      map['to_asset_id'] = Variable<int>(toAssetId.value);
    }
    if (accountBookId.present) {
      map['account_book_id'] = Variable<int>(accountBookId.value);
    }
    if (excludeBudget.present) {
      map['exclude_budget'] = Variable<bool>(excludeBudget.value);
    }
    if (excludeExIn.present) {
      map['exclude_ex_in'] = Variable<bool>(excludeExIn.value);
    }
    if (platformId.present) {
      map['platform_id'] = Variable<int>(platformId.value);
    }
    if (periodId.present) {
      map['period_id'] = Variable<int>(periodId.value);
    }
    if (installment.present) {
      map['installment'] = Variable<String>(installment.value);
    }
    if (images.present) {
      map['images'] = Variable<String>(images.value);
    }
    if (relInfo.present) {
      map['rel_info'] = Variable<String>(relInfo.value);
    }
    if (discountMinor.present) {
      map['discount_minor'] = Variable<BigInt>(discountMinor.value);
    }
    if (extraInfo.present) {
      map['extra_info'] = Variable<String>(extraInfo.value);
    }
    if (createDate.present) {
      map['create_date'] = Variable<int>(createDate.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('RecordsCompanion(')
          ..write('recordId: $recordId, ')
          ..write('type: $type, ')
          ..write('subType: $subType, ')
          ..write('moneyMinor: $moneyMinor, ')
          ..write('remark: $remark, ')
          ..write('recordTime: $recordTime, ')
          ..write('recordCatId: $recordCatId, ')
          ..write('assetId: $assetId, ')
          ..write('fromAssetId: $fromAssetId, ')
          ..write('toAssetId: $toAssetId, ')
          ..write('accountBookId: $accountBookId, ')
          ..write('excludeBudget: $excludeBudget, ')
          ..write('excludeExIn: $excludeExIn, ')
          ..write('platformId: $platformId, ')
          ..write('periodId: $periodId, ')
          ..write('installment: $installment, ')
          ..write('images: $images, ')
          ..write('relInfo: $relInfo, ')
          ..write('discountMinor: $discountMinor, ')
          ..write('extraInfo: $extraInfo, ')
          ..write('createDate: $createDate, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $RecordCategoriesTable extends RecordCategories
    with TableInfo<$RecordCategoriesTable, RecordCategory> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $RecordCategoriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _iconMeta = const VerificationMeta('icon');
  @override
  late final GeneratedColumn<String> icon = GeneratedColumn<String>(
    'icon',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<int> type = GeneratedColumn<int>(
    'type',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sortMeta = const VerificationMeta('sort');
  @override
  late final GeneratedColumn<int> sort = GeneratedColumn<int>(
    'sort',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _parentCatIdMeta = const VerificationMeta(
    'parentCatId',
  );
  @override
  late final GeneratedColumn<int> parentCatId = GeneratedColumn<int>(
    'parent_cat_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(-1),
  );
  static const VerificationMeta _colorFillMeta = const VerificationMeta(
    'colorFill',
  );
  @override
  late final GeneratedColumn<String> colorFill = GeneratedColumn<String>(
    'color_fill',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _platformIdMeta = const VerificationMeta(
    'platformId',
  );
  @override
  late final GeneratedColumn<int> platformId = GeneratedColumn<int>(
    'platform_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(-1),
  );
  static const VerificationMeta _accountBookIdMeta = const VerificationMeta(
    'accountBookId',
  );
  @override
  late final GeneratedColumn<int> accountBookId = GeneratedColumn<int>(
    'account_book_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _isHideMeta = const VerificationMeta('isHide');
  @override
  late final GeneratedColumn<bool> isHide = GeneratedColumn<bool>(
    'is_hide',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_hide" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _extraInfoMeta = const VerificationMeta(
    'extraInfo',
  );
  @override
  late final GeneratedColumn<String> extraInfo = GeneratedColumn<String>(
    'extra_info',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    icon,
    type,
    sort,
    parentCatId,
    colorFill,
    platformId,
    accountBookId,
    isHide,
    extraInfo,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'record_category';
  @override
  VerificationContext validateIntegrity(
    Insertable<RecordCategory> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('icon')) {
      context.handle(
        _iconMeta,
        icon.isAcceptableOrUnknown(data['icon']!, _iconMeta),
      );
    }
    if (data.containsKey('type')) {
      context.handle(
        _typeMeta,
        type.isAcceptableOrUnknown(data['type']!, _typeMeta),
      );
    } else if (isInserting) {
      context.missing(_typeMeta);
    }
    if (data.containsKey('sort')) {
      context.handle(
        _sortMeta,
        sort.isAcceptableOrUnknown(data['sort']!, _sortMeta),
      );
    }
    if (data.containsKey('parent_cat_id')) {
      context.handle(
        _parentCatIdMeta,
        parentCatId.isAcceptableOrUnknown(
          data['parent_cat_id']!,
          _parentCatIdMeta,
        ),
      );
    }
    if (data.containsKey('color_fill')) {
      context.handle(
        _colorFillMeta,
        colorFill.isAcceptableOrUnknown(data['color_fill']!, _colorFillMeta),
      );
    }
    if (data.containsKey('platform_id')) {
      context.handle(
        _platformIdMeta,
        platformId.isAcceptableOrUnknown(data['platform_id']!, _platformIdMeta),
      );
    }
    if (data.containsKey('account_book_id')) {
      context.handle(
        _accountBookIdMeta,
        accountBookId.isAcceptableOrUnknown(
          data['account_book_id']!,
          _accountBookIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_accountBookIdMeta);
    }
    if (data.containsKey('is_hide')) {
      context.handle(
        _isHideMeta,
        isHide.isAcceptableOrUnknown(data['is_hide']!, _isHideMeta),
      );
    }
    if (data.containsKey('extra_info')) {
      context.handle(
        _extraInfoMeta,
        extraInfo.isAcceptableOrUnknown(data['extra_info']!, _extraInfoMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  RecordCategory map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return RecordCategory(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      icon: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}icon'],
      )!,
      type: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}type'],
      )!,
      sort: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort'],
      )!,
      parentCatId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}parent_cat_id'],
      )!,
      colorFill: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}color_fill'],
      ),
      platformId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}platform_id'],
      )!,
      accountBookId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}account_book_id'],
      )!,
      isHide: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_hide'],
      )!,
      extraInfo: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}extra_info'],
      ),
    );
  }

  @override
  $RecordCategoriesTable createAlias(String alias) {
    return $RecordCategoriesTable(attachedDatabase, alias);
  }
}

class RecordCategory extends DataClass implements Insertable<RecordCategory> {
  final int id;
  final String name;
  final String icon;

  /// 0 expense, 1 income.
  final int type;
  final int sort;
  final int parentCatId;
  final String? colorFill;
  final int platformId;
  final int accountBookId;
  final bool isHide;
  final String? extraInfo;
  const RecordCategory({
    required this.id,
    required this.name,
    required this.icon,
    required this.type,
    required this.sort,
    required this.parentCatId,
    this.colorFill,
    required this.platformId,
    required this.accountBookId,
    required this.isHide,
    this.extraInfo,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['name'] = Variable<String>(name);
    map['icon'] = Variable<String>(icon);
    map['type'] = Variable<int>(type);
    map['sort'] = Variable<int>(sort);
    map['parent_cat_id'] = Variable<int>(parentCatId);
    if (!nullToAbsent || colorFill != null) {
      map['color_fill'] = Variable<String>(colorFill);
    }
    map['platform_id'] = Variable<int>(platformId);
    map['account_book_id'] = Variable<int>(accountBookId);
    map['is_hide'] = Variable<bool>(isHide);
    if (!nullToAbsent || extraInfo != null) {
      map['extra_info'] = Variable<String>(extraInfo);
    }
    return map;
  }

  RecordCategoriesCompanion toCompanion(bool nullToAbsent) {
    return RecordCategoriesCompanion(
      id: Value(id),
      name: Value(name),
      icon: Value(icon),
      type: Value(type),
      sort: Value(sort),
      parentCatId: Value(parentCatId),
      colorFill: colorFill == null && nullToAbsent
          ? const Value.absent()
          : Value(colorFill),
      platformId: Value(platformId),
      accountBookId: Value(accountBookId),
      isHide: Value(isHide),
      extraInfo: extraInfo == null && nullToAbsent
          ? const Value.absent()
          : Value(extraInfo),
    );
  }

  factory RecordCategory.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return RecordCategory(
      id: serializer.fromJson<int>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      icon: serializer.fromJson<String>(json['icon']),
      type: serializer.fromJson<int>(json['type']),
      sort: serializer.fromJson<int>(json['sort']),
      parentCatId: serializer.fromJson<int>(json['parentCatId']),
      colorFill: serializer.fromJson<String?>(json['colorFill']),
      platformId: serializer.fromJson<int>(json['platformId']),
      accountBookId: serializer.fromJson<int>(json['accountBookId']),
      isHide: serializer.fromJson<bool>(json['isHide']),
      extraInfo: serializer.fromJson<String?>(json['extraInfo']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'name': serializer.toJson<String>(name),
      'icon': serializer.toJson<String>(icon),
      'type': serializer.toJson<int>(type),
      'sort': serializer.toJson<int>(sort),
      'parentCatId': serializer.toJson<int>(parentCatId),
      'colorFill': serializer.toJson<String?>(colorFill),
      'platformId': serializer.toJson<int>(platformId),
      'accountBookId': serializer.toJson<int>(accountBookId),
      'isHide': serializer.toJson<bool>(isHide),
      'extraInfo': serializer.toJson<String?>(extraInfo),
    };
  }

  RecordCategory copyWith({
    int? id,
    String? name,
    String? icon,
    int? type,
    int? sort,
    int? parentCatId,
    Value<String?> colorFill = const Value.absent(),
    int? platformId,
    int? accountBookId,
    bool? isHide,
    Value<String?> extraInfo = const Value.absent(),
  }) => RecordCategory(
    id: id ?? this.id,
    name: name ?? this.name,
    icon: icon ?? this.icon,
    type: type ?? this.type,
    sort: sort ?? this.sort,
    parentCatId: parentCatId ?? this.parentCatId,
    colorFill: colorFill.present ? colorFill.value : this.colorFill,
    platformId: platformId ?? this.platformId,
    accountBookId: accountBookId ?? this.accountBookId,
    isHide: isHide ?? this.isHide,
    extraInfo: extraInfo.present ? extraInfo.value : this.extraInfo,
  );
  RecordCategory copyWithCompanion(RecordCategoriesCompanion data) {
    return RecordCategory(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      icon: data.icon.present ? data.icon.value : this.icon,
      type: data.type.present ? data.type.value : this.type,
      sort: data.sort.present ? data.sort.value : this.sort,
      parentCatId: data.parentCatId.present
          ? data.parentCatId.value
          : this.parentCatId,
      colorFill: data.colorFill.present ? data.colorFill.value : this.colorFill,
      platformId: data.platformId.present
          ? data.platformId.value
          : this.platformId,
      accountBookId: data.accountBookId.present
          ? data.accountBookId.value
          : this.accountBookId,
      isHide: data.isHide.present ? data.isHide.value : this.isHide,
      extraInfo: data.extraInfo.present ? data.extraInfo.value : this.extraInfo,
    );
  }

  @override
  String toString() {
    return (StringBuffer('RecordCategory(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('icon: $icon, ')
          ..write('type: $type, ')
          ..write('sort: $sort, ')
          ..write('parentCatId: $parentCatId, ')
          ..write('colorFill: $colorFill, ')
          ..write('platformId: $platformId, ')
          ..write('accountBookId: $accountBookId, ')
          ..write('isHide: $isHide, ')
          ..write('extraInfo: $extraInfo')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    name,
    icon,
    type,
    sort,
    parentCatId,
    colorFill,
    platformId,
    accountBookId,
    isHide,
    extraInfo,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RecordCategory &&
          other.id == this.id &&
          other.name == this.name &&
          other.icon == this.icon &&
          other.type == this.type &&
          other.sort == this.sort &&
          other.parentCatId == this.parentCatId &&
          other.colorFill == this.colorFill &&
          other.platformId == this.platformId &&
          other.accountBookId == this.accountBookId &&
          other.isHide == this.isHide &&
          other.extraInfo == this.extraInfo);
}

class RecordCategoriesCompanion extends UpdateCompanion<RecordCategory> {
  final Value<int> id;
  final Value<String> name;
  final Value<String> icon;
  final Value<int> type;
  final Value<int> sort;
  final Value<int> parentCatId;
  final Value<String?> colorFill;
  final Value<int> platformId;
  final Value<int> accountBookId;
  final Value<bool> isHide;
  final Value<String?> extraInfo;
  const RecordCategoriesCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.icon = const Value.absent(),
    this.type = const Value.absent(),
    this.sort = const Value.absent(),
    this.parentCatId = const Value.absent(),
    this.colorFill = const Value.absent(),
    this.platformId = const Value.absent(),
    this.accountBookId = const Value.absent(),
    this.isHide = const Value.absent(),
    this.extraInfo = const Value.absent(),
  });
  RecordCategoriesCompanion.insert({
    this.id = const Value.absent(),
    required String name,
    this.icon = const Value.absent(),
    required int type,
    this.sort = const Value.absent(),
    this.parentCatId = const Value.absent(),
    this.colorFill = const Value.absent(),
    this.platformId = const Value.absent(),
    required int accountBookId,
    this.isHide = const Value.absent(),
    this.extraInfo = const Value.absent(),
  }) : name = Value(name),
       type = Value(type),
       accountBookId = Value(accountBookId);
  static Insertable<RecordCategory> custom({
    Expression<int>? id,
    Expression<String>? name,
    Expression<String>? icon,
    Expression<int>? type,
    Expression<int>? sort,
    Expression<int>? parentCatId,
    Expression<String>? colorFill,
    Expression<int>? platformId,
    Expression<int>? accountBookId,
    Expression<bool>? isHide,
    Expression<String>? extraInfo,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (icon != null) 'icon': icon,
      if (type != null) 'type': type,
      if (sort != null) 'sort': sort,
      if (parentCatId != null) 'parent_cat_id': parentCatId,
      if (colorFill != null) 'color_fill': colorFill,
      if (platformId != null) 'platform_id': platformId,
      if (accountBookId != null) 'account_book_id': accountBookId,
      if (isHide != null) 'is_hide': isHide,
      if (extraInfo != null) 'extra_info': extraInfo,
    });
  }

  RecordCategoriesCompanion copyWith({
    Value<int>? id,
    Value<String>? name,
    Value<String>? icon,
    Value<int>? type,
    Value<int>? sort,
    Value<int>? parentCatId,
    Value<String?>? colorFill,
    Value<int>? platformId,
    Value<int>? accountBookId,
    Value<bool>? isHide,
    Value<String?>? extraInfo,
  }) {
    return RecordCategoriesCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      icon: icon ?? this.icon,
      type: type ?? this.type,
      sort: sort ?? this.sort,
      parentCatId: parentCatId ?? this.parentCatId,
      colorFill: colorFill ?? this.colorFill,
      platformId: platformId ?? this.platformId,
      accountBookId: accountBookId ?? this.accountBookId,
      isHide: isHide ?? this.isHide,
      extraInfo: extraInfo ?? this.extraInfo,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (icon.present) {
      map['icon'] = Variable<String>(icon.value);
    }
    if (type.present) {
      map['type'] = Variable<int>(type.value);
    }
    if (sort.present) {
      map['sort'] = Variable<int>(sort.value);
    }
    if (parentCatId.present) {
      map['parent_cat_id'] = Variable<int>(parentCatId.value);
    }
    if (colorFill.present) {
      map['color_fill'] = Variable<String>(colorFill.value);
    }
    if (platformId.present) {
      map['platform_id'] = Variable<int>(platformId.value);
    }
    if (accountBookId.present) {
      map['account_book_id'] = Variable<int>(accountBookId.value);
    }
    if (isHide.present) {
      map['is_hide'] = Variable<bool>(isHide.value);
    }
    if (extraInfo.present) {
      map['extra_info'] = Variable<String>(extraInfo.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('RecordCategoriesCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('icon: $icon, ')
          ..write('type: $type, ')
          ..write('sort: $sort, ')
          ..write('parentCatId: $parentCatId, ')
          ..write('colorFill: $colorFill, ')
          ..write('platformId: $platformId, ')
          ..write('accountBookId: $accountBookId, ')
          ..write('isHide: $isHide, ')
          ..write('extraInfo: $extraInfo')
          ..write(')'))
        .toString();
  }
}

class $RemarksTable extends Remarks with TableInfo<$RemarksTable, Remark> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $RemarksTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _contentMeta = const VerificationMeta(
    'content',
  );
  @override
  late final GeneratedColumn<String> content = GeneratedColumn<String>(
    'content',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _recordCatIdMeta = const VerificationMeta(
    'recordCatId',
  );
  @override
  late final GeneratedColumn<int> recordCatId = GeneratedColumn<int>(
    'record_cat_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _usedTimesMeta = const VerificationMeta(
    'usedTimes',
  );
  @override
  late final GeneratedColumn<int> usedTimes = GeneratedColumn<int>(
    'used_times',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [id, content, recordCatId, usedTimes];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'remark';
  @override
  VerificationContext validateIntegrity(
    Insertable<Remark> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('content')) {
      context.handle(
        _contentMeta,
        content.isAcceptableOrUnknown(data['content']!, _contentMeta),
      );
    } else if (isInserting) {
      context.missing(_contentMeta);
    }
    if (data.containsKey('record_cat_id')) {
      context.handle(
        _recordCatIdMeta,
        recordCatId.isAcceptableOrUnknown(
          data['record_cat_id']!,
          _recordCatIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_recordCatIdMeta);
    }
    if (data.containsKey('used_times')) {
      context.handle(
        _usedTimesMeta,
        usedTimes.isAcceptableOrUnknown(data['used_times']!, _usedTimesMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Remark map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Remark(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      content: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content'],
      )!,
      recordCatId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}record_cat_id'],
      )!,
      usedTimes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}used_times'],
      )!,
    );
  }

  @override
  $RemarksTable createAlias(String alias) {
    return $RemarksTable(attachedDatabase, alias);
  }
}

class Remark extends DataClass implements Insertable<Remark> {
  final int id;
  final String content;
  final int recordCatId;
  final int usedTimes;
  const Remark({
    required this.id,
    required this.content,
    required this.recordCatId,
    required this.usedTimes,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['content'] = Variable<String>(content);
    map['record_cat_id'] = Variable<int>(recordCatId);
    map['used_times'] = Variable<int>(usedTimes);
    return map;
  }

  RemarksCompanion toCompanion(bool nullToAbsent) {
    return RemarksCompanion(
      id: Value(id),
      content: Value(content),
      recordCatId: Value(recordCatId),
      usedTimes: Value(usedTimes),
    );
  }

  factory Remark.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Remark(
      id: serializer.fromJson<int>(json['id']),
      content: serializer.fromJson<String>(json['content']),
      recordCatId: serializer.fromJson<int>(json['recordCatId']),
      usedTimes: serializer.fromJson<int>(json['usedTimes']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'content': serializer.toJson<String>(content),
      'recordCatId': serializer.toJson<int>(recordCatId),
      'usedTimes': serializer.toJson<int>(usedTimes),
    };
  }

  Remark copyWith({
    int? id,
    String? content,
    int? recordCatId,
    int? usedTimes,
  }) => Remark(
    id: id ?? this.id,
    content: content ?? this.content,
    recordCatId: recordCatId ?? this.recordCatId,
    usedTimes: usedTimes ?? this.usedTimes,
  );
  Remark copyWithCompanion(RemarksCompanion data) {
    return Remark(
      id: data.id.present ? data.id.value : this.id,
      content: data.content.present ? data.content.value : this.content,
      recordCatId: data.recordCatId.present
          ? data.recordCatId.value
          : this.recordCatId,
      usedTimes: data.usedTimes.present ? data.usedTimes.value : this.usedTimes,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Remark(')
          ..write('id: $id, ')
          ..write('content: $content, ')
          ..write('recordCatId: $recordCatId, ')
          ..write('usedTimes: $usedTimes')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, content, recordCatId, usedTimes);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Remark &&
          other.id == this.id &&
          other.content == this.content &&
          other.recordCatId == this.recordCatId &&
          other.usedTimes == this.usedTimes);
}

class RemarksCompanion extends UpdateCompanion<Remark> {
  final Value<int> id;
  final Value<String> content;
  final Value<int> recordCatId;
  final Value<int> usedTimes;
  const RemarksCompanion({
    this.id = const Value.absent(),
    this.content = const Value.absent(),
    this.recordCatId = const Value.absent(),
    this.usedTimes = const Value.absent(),
  });
  RemarksCompanion.insert({
    this.id = const Value.absent(),
    required String content,
    required int recordCatId,
    this.usedTimes = const Value.absent(),
  }) : content = Value(content),
       recordCatId = Value(recordCatId);
  static Insertable<Remark> custom({
    Expression<int>? id,
    Expression<String>? content,
    Expression<int>? recordCatId,
    Expression<int>? usedTimes,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (content != null) 'content': content,
      if (recordCatId != null) 'record_cat_id': recordCatId,
      if (usedTimes != null) 'used_times': usedTimes,
    });
  }

  RemarksCompanion copyWith({
    Value<int>? id,
    Value<String>? content,
    Value<int>? recordCatId,
    Value<int>? usedTimes,
  }) {
    return RemarksCompanion(
      id: id ?? this.id,
      content: content ?? this.content,
      recordCatId: recordCatId ?? this.recordCatId,
      usedTimes: usedTimes ?? this.usedTimes,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (content.present) {
      map['content'] = Variable<String>(content.value);
    }
    if (recordCatId.present) {
      map['record_cat_id'] = Variable<int>(recordCatId.value);
    }
    if (usedTimes.present) {
      map['used_times'] = Variable<int>(usedTimes.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('RemarksCompanion(')
          ..write('id: $id, ')
          ..write('content: $content, ')
          ..write('recordCatId: $recordCatId, ')
          ..write('usedTimes: $usedTimes')
          ..write(')'))
        .toString();
  }
}

class $RecordTemplatesTable extends RecordTemplates
    with TableInfo<$RecordTemplatesTable, RecordTemplate> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $RecordTemplatesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<int> type = GeneratedColumn<int>(
    'type',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _remarkMeta = const VerificationMeta('remark');
  @override
  late final GeneratedColumn<String> remark = GeneratedColumn<String>(
    'remark',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _moneyMinorMeta = const VerificationMeta(
    'moneyMinor',
  );
  @override
  late final GeneratedColumn<BigInt> moneyMinor = GeneratedColumn<BigInt>(
    'money_minor',
    aliasedName,
    false,
    type: DriftSqlType.bigInt,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _feeMinorMeta = const VerificationMeta(
    'feeMinor',
  );
  @override
  late final GeneratedColumn<BigInt> feeMinor = GeneratedColumn<BigInt>(
    'fee_minor',
    aliasedName,
    false,
    type: DriftSqlType.bigInt,
    requiredDuringInsert: false,
    defaultValue: Constant(BigInt.zero),
  );
  static const VerificationMeta _recordCatIdMeta = const VerificationMeta(
    'recordCatId',
  );
  @override
  late final GeneratedColumn<int> recordCatId = GeneratedColumn<int>(
    'record_cat_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _assetIdMeta = const VerificationMeta(
    'assetId',
  );
  @override
  late final GeneratedColumn<int> assetId = GeneratedColumn<int>(
    'asset_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(-1),
  );
  static const VerificationMeta _assetId2Meta = const VerificationMeta(
    'assetId2',
  );
  @override
  late final GeneratedColumn<int> assetId2 = GeneratedColumn<int>(
    'asset_id2',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(-1),
  );
  static const VerificationMeta _sortMeta = const VerificationMeta('sort');
  @override
  late final GeneratedColumn<int> sort = GeneratedColumn<int>(
    'sort',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _autoSaveMeta = const VerificationMeta(
    'autoSave',
  );
  @override
  late final GeneratedColumn<bool> autoSave = GeneratedColumn<bool>(
    'auto_save',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("auto_save" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _bookIdMeta = const VerificationMeta('bookId');
  @override
  late final GeneratedColumn<int> bookId = GeneratedColumn<int>(
    'book_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _excludeBudgetMeta = const VerificationMeta(
    'excludeBudget',
  );
  @override
  late final GeneratedColumn<bool> excludeBudget = GeneratedColumn<bool>(
    'exclude_budget',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("exclude_budget" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _excludeExInMeta = const VerificationMeta(
    'excludeExIn',
  );
  @override
  late final GeneratedColumn<bool> excludeExIn = GeneratedColumn<bool>(
    'exclude_ex_in',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("exclude_ex_in" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _createDateMeta = const VerificationMeta(
    'createDate',
  );
  @override
  late final GeneratedColumn<int> createDate = GeneratedColumn<int>(
    'create_date',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _tagsMeta = const VerificationMeta('tags');
  @override
  late final GeneratedColumn<String> tags = GeneratedColumn<String>(
    'tags',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _exiMeta = const VerificationMeta('exi');
  @override
  late final GeneratedColumn<String> exi = GeneratedColumn<String>(
    'exi',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    type,
    remark,
    moneyMinor,
    feeMinor,
    recordCatId,
    assetId,
    assetId2,
    sort,
    autoSave,
    bookId,
    excludeBudget,
    excludeExIn,
    createDate,
    tags,
    exi,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'record_template';
  @override
  VerificationContext validateIntegrity(
    Insertable<RecordTemplate> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('type')) {
      context.handle(
        _typeMeta,
        type.isAcceptableOrUnknown(data['type']!, _typeMeta),
      );
    } else if (isInserting) {
      context.missing(_typeMeta);
    }
    if (data.containsKey('remark')) {
      context.handle(
        _remarkMeta,
        remark.isAcceptableOrUnknown(data['remark']!, _remarkMeta),
      );
    }
    if (data.containsKey('money_minor')) {
      context.handle(
        _moneyMinorMeta,
        moneyMinor.isAcceptableOrUnknown(data['money_minor']!, _moneyMinorMeta),
      );
    } else if (isInserting) {
      context.missing(_moneyMinorMeta);
    }
    if (data.containsKey('fee_minor')) {
      context.handle(
        _feeMinorMeta,
        feeMinor.isAcceptableOrUnknown(data['fee_minor']!, _feeMinorMeta),
      );
    }
    if (data.containsKey('record_cat_id')) {
      context.handle(
        _recordCatIdMeta,
        recordCatId.isAcceptableOrUnknown(
          data['record_cat_id']!,
          _recordCatIdMeta,
        ),
      );
    }
    if (data.containsKey('asset_id')) {
      context.handle(
        _assetIdMeta,
        assetId.isAcceptableOrUnknown(data['asset_id']!, _assetIdMeta),
      );
    }
    if (data.containsKey('asset_id2')) {
      context.handle(
        _assetId2Meta,
        assetId2.isAcceptableOrUnknown(data['asset_id2']!, _assetId2Meta),
      );
    }
    if (data.containsKey('sort')) {
      context.handle(
        _sortMeta,
        sort.isAcceptableOrUnknown(data['sort']!, _sortMeta),
      );
    }
    if (data.containsKey('auto_save')) {
      context.handle(
        _autoSaveMeta,
        autoSave.isAcceptableOrUnknown(data['auto_save']!, _autoSaveMeta),
      );
    }
    if (data.containsKey('book_id')) {
      context.handle(
        _bookIdMeta,
        bookId.isAcceptableOrUnknown(data['book_id']!, _bookIdMeta),
      );
    } else if (isInserting) {
      context.missing(_bookIdMeta);
    }
    if (data.containsKey('exclude_budget')) {
      context.handle(
        _excludeBudgetMeta,
        excludeBudget.isAcceptableOrUnknown(
          data['exclude_budget']!,
          _excludeBudgetMeta,
        ),
      );
    }
    if (data.containsKey('exclude_ex_in')) {
      context.handle(
        _excludeExInMeta,
        excludeExIn.isAcceptableOrUnknown(
          data['exclude_ex_in']!,
          _excludeExInMeta,
        ),
      );
    }
    if (data.containsKey('create_date')) {
      context.handle(
        _createDateMeta,
        createDate.isAcceptableOrUnknown(data['create_date']!, _createDateMeta),
      );
    } else if (isInserting) {
      context.missing(_createDateMeta);
    }
    if (data.containsKey('tags')) {
      context.handle(
        _tagsMeta,
        tags.isAcceptableOrUnknown(data['tags']!, _tagsMeta),
      );
    }
    if (data.containsKey('exi')) {
      context.handle(
        _exiMeta,
        exi.isAcceptableOrUnknown(data['exi']!, _exiMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  RecordTemplate map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return RecordTemplate(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      type: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}type'],
      )!,
      remark: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}remark'],
      ),
      moneyMinor: attachedDatabase.typeMapping.read(
        DriftSqlType.bigInt,
        data['${effectivePrefix}money_minor'],
      )!,
      feeMinor: attachedDatabase.typeMapping.read(
        DriftSqlType.bigInt,
        data['${effectivePrefix}fee_minor'],
      )!,
      recordCatId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}record_cat_id'],
      ),
      assetId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}asset_id'],
      )!,
      assetId2: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}asset_id2'],
      )!,
      sort: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort'],
      )!,
      autoSave: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}auto_save'],
      )!,
      bookId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}book_id'],
      )!,
      excludeBudget: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}exclude_budget'],
      )!,
      excludeExIn: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}exclude_ex_in'],
      )!,
      createDate: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}create_date'],
      )!,
      tags: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tags'],
      ),
      exi: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}exi'],
      ),
    );
  }

  @override
  $RecordTemplatesTable createAlias(String alias) {
    return $RecordTemplatesTable(attachedDatabase, alias);
  }
}

class RecordTemplate extends DataClass implements Insertable<RecordTemplate> {
  final int id;
  final int type;
  final String? remark;
  final BigInt moneyMinor;
  final BigInt feeMinor;
  final int? recordCatId;
  final int assetId;
  final int assetId2;
  final int sort;
  final bool autoSave;
  final int bookId;
  final bool excludeBudget;
  final bool excludeExIn;
  final int createDate;
  final String? tags;
  final String? exi;
  const RecordTemplate({
    required this.id,
    required this.type,
    this.remark,
    required this.moneyMinor,
    required this.feeMinor,
    this.recordCatId,
    required this.assetId,
    required this.assetId2,
    required this.sort,
    required this.autoSave,
    required this.bookId,
    required this.excludeBudget,
    required this.excludeExIn,
    required this.createDate,
    this.tags,
    this.exi,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['type'] = Variable<int>(type);
    if (!nullToAbsent || remark != null) {
      map['remark'] = Variable<String>(remark);
    }
    map['money_minor'] = Variable<BigInt>(moneyMinor);
    map['fee_minor'] = Variable<BigInt>(feeMinor);
    if (!nullToAbsent || recordCatId != null) {
      map['record_cat_id'] = Variable<int>(recordCatId);
    }
    map['asset_id'] = Variable<int>(assetId);
    map['asset_id2'] = Variable<int>(assetId2);
    map['sort'] = Variable<int>(sort);
    map['auto_save'] = Variable<bool>(autoSave);
    map['book_id'] = Variable<int>(bookId);
    map['exclude_budget'] = Variable<bool>(excludeBudget);
    map['exclude_ex_in'] = Variable<bool>(excludeExIn);
    map['create_date'] = Variable<int>(createDate);
    if (!nullToAbsent || tags != null) {
      map['tags'] = Variable<String>(tags);
    }
    if (!nullToAbsent || exi != null) {
      map['exi'] = Variable<String>(exi);
    }
    return map;
  }

  RecordTemplatesCompanion toCompanion(bool nullToAbsent) {
    return RecordTemplatesCompanion(
      id: Value(id),
      type: Value(type),
      remark: remark == null && nullToAbsent
          ? const Value.absent()
          : Value(remark),
      moneyMinor: Value(moneyMinor),
      feeMinor: Value(feeMinor),
      recordCatId: recordCatId == null && nullToAbsent
          ? const Value.absent()
          : Value(recordCatId),
      assetId: Value(assetId),
      assetId2: Value(assetId2),
      sort: Value(sort),
      autoSave: Value(autoSave),
      bookId: Value(bookId),
      excludeBudget: Value(excludeBudget),
      excludeExIn: Value(excludeExIn),
      createDate: Value(createDate),
      tags: tags == null && nullToAbsent ? const Value.absent() : Value(tags),
      exi: exi == null && nullToAbsent ? const Value.absent() : Value(exi),
    );
  }

  factory RecordTemplate.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return RecordTemplate(
      id: serializer.fromJson<int>(json['id']),
      type: serializer.fromJson<int>(json['type']),
      remark: serializer.fromJson<String?>(json['remark']),
      moneyMinor: serializer.fromJson<BigInt>(json['moneyMinor']),
      feeMinor: serializer.fromJson<BigInt>(json['feeMinor']),
      recordCatId: serializer.fromJson<int?>(json['recordCatId']),
      assetId: serializer.fromJson<int>(json['assetId']),
      assetId2: serializer.fromJson<int>(json['assetId2']),
      sort: serializer.fromJson<int>(json['sort']),
      autoSave: serializer.fromJson<bool>(json['autoSave']),
      bookId: serializer.fromJson<int>(json['bookId']),
      excludeBudget: serializer.fromJson<bool>(json['excludeBudget']),
      excludeExIn: serializer.fromJson<bool>(json['excludeExIn']),
      createDate: serializer.fromJson<int>(json['createDate']),
      tags: serializer.fromJson<String?>(json['tags']),
      exi: serializer.fromJson<String?>(json['exi']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'type': serializer.toJson<int>(type),
      'remark': serializer.toJson<String?>(remark),
      'moneyMinor': serializer.toJson<BigInt>(moneyMinor),
      'feeMinor': serializer.toJson<BigInt>(feeMinor),
      'recordCatId': serializer.toJson<int?>(recordCatId),
      'assetId': serializer.toJson<int>(assetId),
      'assetId2': serializer.toJson<int>(assetId2),
      'sort': serializer.toJson<int>(sort),
      'autoSave': serializer.toJson<bool>(autoSave),
      'bookId': serializer.toJson<int>(bookId),
      'excludeBudget': serializer.toJson<bool>(excludeBudget),
      'excludeExIn': serializer.toJson<bool>(excludeExIn),
      'createDate': serializer.toJson<int>(createDate),
      'tags': serializer.toJson<String?>(tags),
      'exi': serializer.toJson<String?>(exi),
    };
  }

  RecordTemplate copyWith({
    int? id,
    int? type,
    Value<String?> remark = const Value.absent(),
    BigInt? moneyMinor,
    BigInt? feeMinor,
    Value<int?> recordCatId = const Value.absent(),
    int? assetId,
    int? assetId2,
    int? sort,
    bool? autoSave,
    int? bookId,
    bool? excludeBudget,
    bool? excludeExIn,
    int? createDate,
    Value<String?> tags = const Value.absent(),
    Value<String?> exi = const Value.absent(),
  }) => RecordTemplate(
    id: id ?? this.id,
    type: type ?? this.type,
    remark: remark.present ? remark.value : this.remark,
    moneyMinor: moneyMinor ?? this.moneyMinor,
    feeMinor: feeMinor ?? this.feeMinor,
    recordCatId: recordCatId.present ? recordCatId.value : this.recordCatId,
    assetId: assetId ?? this.assetId,
    assetId2: assetId2 ?? this.assetId2,
    sort: sort ?? this.sort,
    autoSave: autoSave ?? this.autoSave,
    bookId: bookId ?? this.bookId,
    excludeBudget: excludeBudget ?? this.excludeBudget,
    excludeExIn: excludeExIn ?? this.excludeExIn,
    createDate: createDate ?? this.createDate,
    tags: tags.present ? tags.value : this.tags,
    exi: exi.present ? exi.value : this.exi,
  );
  RecordTemplate copyWithCompanion(RecordTemplatesCompanion data) {
    return RecordTemplate(
      id: data.id.present ? data.id.value : this.id,
      type: data.type.present ? data.type.value : this.type,
      remark: data.remark.present ? data.remark.value : this.remark,
      moneyMinor: data.moneyMinor.present
          ? data.moneyMinor.value
          : this.moneyMinor,
      feeMinor: data.feeMinor.present ? data.feeMinor.value : this.feeMinor,
      recordCatId: data.recordCatId.present
          ? data.recordCatId.value
          : this.recordCatId,
      assetId: data.assetId.present ? data.assetId.value : this.assetId,
      assetId2: data.assetId2.present ? data.assetId2.value : this.assetId2,
      sort: data.sort.present ? data.sort.value : this.sort,
      autoSave: data.autoSave.present ? data.autoSave.value : this.autoSave,
      bookId: data.bookId.present ? data.bookId.value : this.bookId,
      excludeBudget: data.excludeBudget.present
          ? data.excludeBudget.value
          : this.excludeBudget,
      excludeExIn: data.excludeExIn.present
          ? data.excludeExIn.value
          : this.excludeExIn,
      createDate: data.createDate.present
          ? data.createDate.value
          : this.createDate,
      tags: data.tags.present ? data.tags.value : this.tags,
      exi: data.exi.present ? data.exi.value : this.exi,
    );
  }

  @override
  String toString() {
    return (StringBuffer('RecordTemplate(')
          ..write('id: $id, ')
          ..write('type: $type, ')
          ..write('remark: $remark, ')
          ..write('moneyMinor: $moneyMinor, ')
          ..write('feeMinor: $feeMinor, ')
          ..write('recordCatId: $recordCatId, ')
          ..write('assetId: $assetId, ')
          ..write('assetId2: $assetId2, ')
          ..write('sort: $sort, ')
          ..write('autoSave: $autoSave, ')
          ..write('bookId: $bookId, ')
          ..write('excludeBudget: $excludeBudget, ')
          ..write('excludeExIn: $excludeExIn, ')
          ..write('createDate: $createDate, ')
          ..write('tags: $tags, ')
          ..write('exi: $exi')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    type,
    remark,
    moneyMinor,
    feeMinor,
    recordCatId,
    assetId,
    assetId2,
    sort,
    autoSave,
    bookId,
    excludeBudget,
    excludeExIn,
    createDate,
    tags,
    exi,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RecordTemplate &&
          other.id == this.id &&
          other.type == this.type &&
          other.remark == this.remark &&
          other.moneyMinor == this.moneyMinor &&
          other.feeMinor == this.feeMinor &&
          other.recordCatId == this.recordCatId &&
          other.assetId == this.assetId &&
          other.assetId2 == this.assetId2 &&
          other.sort == this.sort &&
          other.autoSave == this.autoSave &&
          other.bookId == this.bookId &&
          other.excludeBudget == this.excludeBudget &&
          other.excludeExIn == this.excludeExIn &&
          other.createDate == this.createDate &&
          other.tags == this.tags &&
          other.exi == this.exi);
}

class RecordTemplatesCompanion extends UpdateCompanion<RecordTemplate> {
  final Value<int> id;
  final Value<int> type;
  final Value<String?> remark;
  final Value<BigInt> moneyMinor;
  final Value<BigInt> feeMinor;
  final Value<int?> recordCatId;
  final Value<int> assetId;
  final Value<int> assetId2;
  final Value<int> sort;
  final Value<bool> autoSave;
  final Value<int> bookId;
  final Value<bool> excludeBudget;
  final Value<bool> excludeExIn;
  final Value<int> createDate;
  final Value<String?> tags;
  final Value<String?> exi;
  const RecordTemplatesCompanion({
    this.id = const Value.absent(),
    this.type = const Value.absent(),
    this.remark = const Value.absent(),
    this.moneyMinor = const Value.absent(),
    this.feeMinor = const Value.absent(),
    this.recordCatId = const Value.absent(),
    this.assetId = const Value.absent(),
    this.assetId2 = const Value.absent(),
    this.sort = const Value.absent(),
    this.autoSave = const Value.absent(),
    this.bookId = const Value.absent(),
    this.excludeBudget = const Value.absent(),
    this.excludeExIn = const Value.absent(),
    this.createDate = const Value.absent(),
    this.tags = const Value.absent(),
    this.exi = const Value.absent(),
  });
  RecordTemplatesCompanion.insert({
    this.id = const Value.absent(),
    required int type,
    this.remark = const Value.absent(),
    required BigInt moneyMinor,
    this.feeMinor = const Value.absent(),
    this.recordCatId = const Value.absent(),
    this.assetId = const Value.absent(),
    this.assetId2 = const Value.absent(),
    this.sort = const Value.absent(),
    this.autoSave = const Value.absent(),
    required int bookId,
    this.excludeBudget = const Value.absent(),
    this.excludeExIn = const Value.absent(),
    required int createDate,
    this.tags = const Value.absent(),
    this.exi = const Value.absent(),
  }) : type = Value(type),
       moneyMinor = Value(moneyMinor),
       bookId = Value(bookId),
       createDate = Value(createDate);
  static Insertable<RecordTemplate> custom({
    Expression<int>? id,
    Expression<int>? type,
    Expression<String>? remark,
    Expression<BigInt>? moneyMinor,
    Expression<BigInt>? feeMinor,
    Expression<int>? recordCatId,
    Expression<int>? assetId,
    Expression<int>? assetId2,
    Expression<int>? sort,
    Expression<bool>? autoSave,
    Expression<int>? bookId,
    Expression<bool>? excludeBudget,
    Expression<bool>? excludeExIn,
    Expression<int>? createDate,
    Expression<String>? tags,
    Expression<String>? exi,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (type != null) 'type': type,
      if (remark != null) 'remark': remark,
      if (moneyMinor != null) 'money_minor': moneyMinor,
      if (feeMinor != null) 'fee_minor': feeMinor,
      if (recordCatId != null) 'record_cat_id': recordCatId,
      if (assetId != null) 'asset_id': assetId,
      if (assetId2 != null) 'asset_id2': assetId2,
      if (sort != null) 'sort': sort,
      if (autoSave != null) 'auto_save': autoSave,
      if (bookId != null) 'book_id': bookId,
      if (excludeBudget != null) 'exclude_budget': excludeBudget,
      if (excludeExIn != null) 'exclude_ex_in': excludeExIn,
      if (createDate != null) 'create_date': createDate,
      if (tags != null) 'tags': tags,
      if (exi != null) 'exi': exi,
    });
  }

  RecordTemplatesCompanion copyWith({
    Value<int>? id,
    Value<int>? type,
    Value<String?>? remark,
    Value<BigInt>? moneyMinor,
    Value<BigInt>? feeMinor,
    Value<int?>? recordCatId,
    Value<int>? assetId,
    Value<int>? assetId2,
    Value<int>? sort,
    Value<bool>? autoSave,
    Value<int>? bookId,
    Value<bool>? excludeBudget,
    Value<bool>? excludeExIn,
    Value<int>? createDate,
    Value<String?>? tags,
    Value<String?>? exi,
  }) {
    return RecordTemplatesCompanion(
      id: id ?? this.id,
      type: type ?? this.type,
      remark: remark ?? this.remark,
      moneyMinor: moneyMinor ?? this.moneyMinor,
      feeMinor: feeMinor ?? this.feeMinor,
      recordCatId: recordCatId ?? this.recordCatId,
      assetId: assetId ?? this.assetId,
      assetId2: assetId2 ?? this.assetId2,
      sort: sort ?? this.sort,
      autoSave: autoSave ?? this.autoSave,
      bookId: bookId ?? this.bookId,
      excludeBudget: excludeBudget ?? this.excludeBudget,
      excludeExIn: excludeExIn ?? this.excludeExIn,
      createDate: createDate ?? this.createDate,
      tags: tags ?? this.tags,
      exi: exi ?? this.exi,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (type.present) {
      map['type'] = Variable<int>(type.value);
    }
    if (remark.present) {
      map['remark'] = Variable<String>(remark.value);
    }
    if (moneyMinor.present) {
      map['money_minor'] = Variable<BigInt>(moneyMinor.value);
    }
    if (feeMinor.present) {
      map['fee_minor'] = Variable<BigInt>(feeMinor.value);
    }
    if (recordCatId.present) {
      map['record_cat_id'] = Variable<int>(recordCatId.value);
    }
    if (assetId.present) {
      map['asset_id'] = Variable<int>(assetId.value);
    }
    if (assetId2.present) {
      map['asset_id2'] = Variable<int>(assetId2.value);
    }
    if (sort.present) {
      map['sort'] = Variable<int>(sort.value);
    }
    if (autoSave.present) {
      map['auto_save'] = Variable<bool>(autoSave.value);
    }
    if (bookId.present) {
      map['book_id'] = Variable<int>(bookId.value);
    }
    if (excludeBudget.present) {
      map['exclude_budget'] = Variable<bool>(excludeBudget.value);
    }
    if (excludeExIn.present) {
      map['exclude_ex_in'] = Variable<bool>(excludeExIn.value);
    }
    if (createDate.present) {
      map['create_date'] = Variable<int>(createDate.value);
    }
    if (tags.present) {
      map['tags'] = Variable<String>(tags.value);
    }
    if (exi.present) {
      map['exi'] = Variable<String>(exi.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('RecordTemplatesCompanion(')
          ..write('id: $id, ')
          ..write('type: $type, ')
          ..write('remark: $remark, ')
          ..write('moneyMinor: $moneyMinor, ')
          ..write('feeMinor: $feeMinor, ')
          ..write('recordCatId: $recordCatId, ')
          ..write('assetId: $assetId, ')
          ..write('assetId2: $assetId2, ')
          ..write('sort: $sort, ')
          ..write('autoSave: $autoSave, ')
          ..write('bookId: $bookId, ')
          ..write('excludeBudget: $excludeBudget, ')
          ..write('excludeExIn: $excludeExIn, ')
          ..write('createDate: $createDate, ')
          ..write('tags: $tags, ')
          ..write('exi: $exi')
          ..write(')'))
        .toString();
  }
}

class $WishesTable extends Wishes with TableInfo<$WishesTable, Wish> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $WishesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _contentMeta = const VerificationMeta(
    'content',
  );
  @override
  late final GeneratedColumn<String> content = GeneratedColumn<String>(
    'content',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueMinorMeta = const VerificationMeta(
    'valueMinor',
  );
  @override
  late final GeneratedColumn<BigInt> valueMinor = GeneratedColumn<BigInt>(
    'value_minor',
    aliasedName,
    false,
    type: DriftSqlType.bigInt,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createDateMeta = const VerificationMeta(
    'createDate',
  );
  @override
  late final GeneratedColumn<int> createDate = GeneratedColumn<int>(
    'create_date',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _isRealizedMeta = const VerificationMeta(
    'isRealized',
  );
  @override
  late final GeneratedColumn<bool> isRealized = GeneratedColumn<bool>(
    'is_realized',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_realized" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _realizedDateMeta = const VerificationMeta(
    'realizedDate',
  );
  @override
  late final GeneratedColumn<int> realizedDate = GeneratedColumn<int>(
    'realized_date',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _sortMeta = const VerificationMeta('sort');
  @override
  late final GeneratedColumn<int> sort = GeneratedColumn<int>(
    'sort',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _iconMeta = const VerificationMeta('icon');
  @override
  late final GeneratedColumn<String> icon = GeneratedColumn<String>(
    'icon',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _targetDateMeta = const VerificationMeta(
    'targetDate',
  );
  @override
  late final GeneratedColumn<int> targetDate = GeneratedColumn<int>(
    'target_date',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    content,
    valueMinor,
    createDate,
    isRealized,
    realizedDate,
    sort,
    icon,
    targetDate,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'wish';
  @override
  VerificationContext validateIntegrity(
    Insertable<Wish> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('content')) {
      context.handle(
        _contentMeta,
        content.isAcceptableOrUnknown(data['content']!, _contentMeta),
      );
    } else if (isInserting) {
      context.missing(_contentMeta);
    }
    if (data.containsKey('value_minor')) {
      context.handle(
        _valueMinorMeta,
        valueMinor.isAcceptableOrUnknown(data['value_minor']!, _valueMinorMeta),
      );
    } else if (isInserting) {
      context.missing(_valueMinorMeta);
    }
    if (data.containsKey('create_date')) {
      context.handle(
        _createDateMeta,
        createDate.isAcceptableOrUnknown(data['create_date']!, _createDateMeta),
      );
    } else if (isInserting) {
      context.missing(_createDateMeta);
    }
    if (data.containsKey('is_realized')) {
      context.handle(
        _isRealizedMeta,
        isRealized.isAcceptableOrUnknown(data['is_realized']!, _isRealizedMeta),
      );
    }
    if (data.containsKey('realized_date')) {
      context.handle(
        _realizedDateMeta,
        realizedDate.isAcceptableOrUnknown(
          data['realized_date']!,
          _realizedDateMeta,
        ),
      );
    }
    if (data.containsKey('sort')) {
      context.handle(
        _sortMeta,
        sort.isAcceptableOrUnknown(data['sort']!, _sortMeta),
      );
    }
    if (data.containsKey('icon')) {
      context.handle(
        _iconMeta,
        icon.isAcceptableOrUnknown(data['icon']!, _iconMeta),
      );
    }
    if (data.containsKey('target_date')) {
      context.handle(
        _targetDateMeta,
        targetDate.isAcceptableOrUnknown(data['target_date']!, _targetDateMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Wish map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Wish(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      content: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content'],
      )!,
      valueMinor: attachedDatabase.typeMapping.read(
        DriftSqlType.bigInt,
        data['${effectivePrefix}value_minor'],
      )!,
      createDate: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}create_date'],
      )!,
      isRealized: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_realized'],
      )!,
      realizedDate: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}realized_date'],
      )!,
      sort: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort'],
      )!,
      icon: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}icon'],
      ),
      targetDate: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}target_date'],
      )!,
    );
  }

  @override
  $WishesTable createAlias(String alias) {
    return $WishesTable(attachedDatabase, alias);
  }
}

class Wish extends DataClass implements Insertable<Wish> {
  final String id;
  final String content;
  final BigInt valueMinor;
  final int createDate;
  final bool isRealized;
  final int realizedDate;
  final int sort;
  final String? icon;
  final int targetDate;
  const Wish({
    required this.id,
    required this.content,
    required this.valueMinor,
    required this.createDate,
    required this.isRealized,
    required this.realizedDate,
    required this.sort,
    this.icon,
    required this.targetDate,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['content'] = Variable<String>(content);
    map['value_minor'] = Variable<BigInt>(valueMinor);
    map['create_date'] = Variable<int>(createDate);
    map['is_realized'] = Variable<bool>(isRealized);
    map['realized_date'] = Variable<int>(realizedDate);
    map['sort'] = Variable<int>(sort);
    if (!nullToAbsent || icon != null) {
      map['icon'] = Variable<String>(icon);
    }
    map['target_date'] = Variable<int>(targetDate);
    return map;
  }

  WishesCompanion toCompanion(bool nullToAbsent) {
    return WishesCompanion(
      id: Value(id),
      content: Value(content),
      valueMinor: Value(valueMinor),
      createDate: Value(createDate),
      isRealized: Value(isRealized),
      realizedDate: Value(realizedDate),
      sort: Value(sort),
      icon: icon == null && nullToAbsent ? const Value.absent() : Value(icon),
      targetDate: Value(targetDate),
    );
  }

  factory Wish.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Wish(
      id: serializer.fromJson<String>(json['id']),
      content: serializer.fromJson<String>(json['content']),
      valueMinor: serializer.fromJson<BigInt>(json['valueMinor']),
      createDate: serializer.fromJson<int>(json['createDate']),
      isRealized: serializer.fromJson<bool>(json['isRealized']),
      realizedDate: serializer.fromJson<int>(json['realizedDate']),
      sort: serializer.fromJson<int>(json['sort']),
      icon: serializer.fromJson<String?>(json['icon']),
      targetDate: serializer.fromJson<int>(json['targetDate']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'content': serializer.toJson<String>(content),
      'valueMinor': serializer.toJson<BigInt>(valueMinor),
      'createDate': serializer.toJson<int>(createDate),
      'isRealized': serializer.toJson<bool>(isRealized),
      'realizedDate': serializer.toJson<int>(realizedDate),
      'sort': serializer.toJson<int>(sort),
      'icon': serializer.toJson<String?>(icon),
      'targetDate': serializer.toJson<int>(targetDate),
    };
  }

  Wish copyWith({
    String? id,
    String? content,
    BigInt? valueMinor,
    int? createDate,
    bool? isRealized,
    int? realizedDate,
    int? sort,
    Value<String?> icon = const Value.absent(),
    int? targetDate,
  }) => Wish(
    id: id ?? this.id,
    content: content ?? this.content,
    valueMinor: valueMinor ?? this.valueMinor,
    createDate: createDate ?? this.createDate,
    isRealized: isRealized ?? this.isRealized,
    realizedDate: realizedDate ?? this.realizedDate,
    sort: sort ?? this.sort,
    icon: icon.present ? icon.value : this.icon,
    targetDate: targetDate ?? this.targetDate,
  );
  Wish copyWithCompanion(WishesCompanion data) {
    return Wish(
      id: data.id.present ? data.id.value : this.id,
      content: data.content.present ? data.content.value : this.content,
      valueMinor: data.valueMinor.present
          ? data.valueMinor.value
          : this.valueMinor,
      createDate: data.createDate.present
          ? data.createDate.value
          : this.createDate,
      isRealized: data.isRealized.present
          ? data.isRealized.value
          : this.isRealized,
      realizedDate: data.realizedDate.present
          ? data.realizedDate.value
          : this.realizedDate,
      sort: data.sort.present ? data.sort.value : this.sort,
      icon: data.icon.present ? data.icon.value : this.icon,
      targetDate: data.targetDate.present
          ? data.targetDate.value
          : this.targetDate,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Wish(')
          ..write('id: $id, ')
          ..write('content: $content, ')
          ..write('valueMinor: $valueMinor, ')
          ..write('createDate: $createDate, ')
          ..write('isRealized: $isRealized, ')
          ..write('realizedDate: $realizedDate, ')
          ..write('sort: $sort, ')
          ..write('icon: $icon, ')
          ..write('targetDate: $targetDate')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    content,
    valueMinor,
    createDate,
    isRealized,
    realizedDate,
    sort,
    icon,
    targetDate,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Wish &&
          other.id == this.id &&
          other.content == this.content &&
          other.valueMinor == this.valueMinor &&
          other.createDate == this.createDate &&
          other.isRealized == this.isRealized &&
          other.realizedDate == this.realizedDate &&
          other.sort == this.sort &&
          other.icon == this.icon &&
          other.targetDate == this.targetDate);
}

class WishesCompanion extends UpdateCompanion<Wish> {
  final Value<String> id;
  final Value<String> content;
  final Value<BigInt> valueMinor;
  final Value<int> createDate;
  final Value<bool> isRealized;
  final Value<int> realizedDate;
  final Value<int> sort;
  final Value<String?> icon;
  final Value<int> targetDate;
  final Value<int> rowid;
  const WishesCompanion({
    this.id = const Value.absent(),
    this.content = const Value.absent(),
    this.valueMinor = const Value.absent(),
    this.createDate = const Value.absent(),
    this.isRealized = const Value.absent(),
    this.realizedDate = const Value.absent(),
    this.sort = const Value.absent(),
    this.icon = const Value.absent(),
    this.targetDate = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  WishesCompanion.insert({
    required String id,
    required String content,
    required BigInt valueMinor,
    required int createDate,
    this.isRealized = const Value.absent(),
    this.realizedDate = const Value.absent(),
    this.sort = const Value.absent(),
    this.icon = const Value.absent(),
    this.targetDate = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       content = Value(content),
       valueMinor = Value(valueMinor),
       createDate = Value(createDate);
  static Insertable<Wish> custom({
    Expression<String>? id,
    Expression<String>? content,
    Expression<BigInt>? valueMinor,
    Expression<int>? createDate,
    Expression<bool>? isRealized,
    Expression<int>? realizedDate,
    Expression<int>? sort,
    Expression<String>? icon,
    Expression<int>? targetDate,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (content != null) 'content': content,
      if (valueMinor != null) 'value_minor': valueMinor,
      if (createDate != null) 'create_date': createDate,
      if (isRealized != null) 'is_realized': isRealized,
      if (realizedDate != null) 'realized_date': realizedDate,
      if (sort != null) 'sort': sort,
      if (icon != null) 'icon': icon,
      if (targetDate != null) 'target_date': targetDate,
      if (rowid != null) 'rowid': rowid,
    });
  }

  WishesCompanion copyWith({
    Value<String>? id,
    Value<String>? content,
    Value<BigInt>? valueMinor,
    Value<int>? createDate,
    Value<bool>? isRealized,
    Value<int>? realizedDate,
    Value<int>? sort,
    Value<String?>? icon,
    Value<int>? targetDate,
    Value<int>? rowid,
  }) {
    return WishesCompanion(
      id: id ?? this.id,
      content: content ?? this.content,
      valueMinor: valueMinor ?? this.valueMinor,
      createDate: createDate ?? this.createDate,
      isRealized: isRealized ?? this.isRealized,
      realizedDate: realizedDate ?? this.realizedDate,
      sort: sort ?? this.sort,
      icon: icon ?? this.icon,
      targetDate: targetDate ?? this.targetDate,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (content.present) {
      map['content'] = Variable<String>(content.value);
    }
    if (valueMinor.present) {
      map['value_minor'] = Variable<BigInt>(valueMinor.value);
    }
    if (createDate.present) {
      map['create_date'] = Variable<int>(createDate.value);
    }
    if (isRealized.present) {
      map['is_realized'] = Variable<bool>(isRealized.value);
    }
    if (realizedDate.present) {
      map['realized_date'] = Variable<int>(realizedDate.value);
    }
    if (sort.present) {
      map['sort'] = Variable<int>(sort.value);
    }
    if (icon.present) {
      map['icon'] = Variable<String>(icon.value);
    }
    if (targetDate.present) {
      map['target_date'] = Variable<int>(targetDate.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('WishesCompanion(')
          ..write('id: $id, ')
          ..write('content: $content, ')
          ..write('valueMinor: $valueMinor, ')
          ..write('createDate: $createDate, ')
          ..write('isRealized: $isRealized, ')
          ..write('realizedDate: $realizedDate, ')
          ..write('sort: $sort, ')
          ..write('icon: $icon, ')
          ..write('targetDate: $targetDate, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $RecordPeriodsTable extends RecordPeriods
    with TableInfo<$RecordPeriodsTable, RecordPeriod> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $RecordPeriodsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _recordTypeMeta = const VerificationMeta(
    'recordType',
  );
  @override
  late final GeneratedColumn<int> recordType = GeneratedColumn<int>(
    'record_type',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _moneyMinorMeta = const VerificationMeta(
    'moneyMinor',
  );
  @override
  late final GeneratedColumn<BigInt> moneyMinor = GeneratedColumn<BigInt>(
    'money_minor',
    aliasedName,
    false,
    type: DriftSqlType.bigInt,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _feeMinorMeta = const VerificationMeta(
    'feeMinor',
  );
  @override
  late final GeneratedColumn<BigInt> feeMinor = GeneratedColumn<BigInt>(
    'fee_minor',
    aliasedName,
    false,
    type: DriftSqlType.bigInt,
    requiredDuringInsert: false,
    defaultValue: Constant(BigInt.zero),
  );
  static const VerificationMeta _remarkMeta = const VerificationMeta('remark');
  @override
  late final GeneratedColumn<String> remark = GeneratedColumn<String>(
    'remark',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _catIdMeta = const VerificationMeta('catId');
  @override
  late final GeneratedColumn<int> catId = GeneratedColumn<int>(
    'cat_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(-1),
  );
  static const VerificationMeta _assetIdMeta = const VerificationMeta(
    'assetId',
  );
  @override
  late final GeneratedColumn<int> assetId = GeneratedColumn<int>(
    'asset_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(-1),
  );
  static const VerificationMeta _assetId2Meta = const VerificationMeta(
    'assetId2',
  );
  @override
  late final GeneratedColumn<int> assetId2 = GeneratedColumn<int>(
    'asset_id2',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(-1),
  );
  static const VerificationMeta _bookIdMeta = const VerificationMeta('bookId');
  @override
  late final GeneratedColumn<int> bookId = GeneratedColumn<int>(
    'book_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _imagesMeta = const VerificationMeta('images');
  @override
  late final GeneratedColumn<String> images = GeneratedColumn<String>(
    'images',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _stateMeta = const VerificationMeta('state');
  @override
  late final GeneratedColumn<int> state = GeneratedColumn<int>(
    'state',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _timeMeta = const VerificationMeta('time');
  @override
  late final GeneratedColumn<String> time = GeneratedColumn<String>(
    'time',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _excludeBudgetMeta = const VerificationMeta(
    'excludeBudget',
  );
  @override
  late final GeneratedColumn<bool> excludeBudget = GeneratedColumn<bool>(
    'exclude_budget',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("exclude_budget" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _excludeExInMeta = const VerificationMeta(
    'excludeExIn',
  );
  @override
  late final GeneratedColumn<bool> excludeExIn = GeneratedColumn<bool>(
    'exclude_ex_in',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("exclude_ex_in" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _periodTypeMeta = const VerificationMeta(
    'periodType',
  );
  @override
  late final GeneratedColumn<int> periodType = GeneratedColumn<int>(
    'period_type',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _periodTypeDateMeta = const VerificationMeta(
    'periodTypeDate',
  );
  @override
  late final GeneratedColumn<String> periodTypeDate = GeneratedColumn<String>(
    'period_type_date',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _periodStartDateMeta = const VerificationMeta(
    'periodStartDate',
  );
  @override
  late final GeneratedColumn<int> periodStartDate = GeneratedColumn<int>(
    'period_start_date',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _periodEndDateMeta = const VerificationMeta(
    'periodEndDate',
  );
  @override
  late final GeneratedColumn<int> periodEndDate = GeneratedColumn<int>(
    'period_end_date',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _frequencyMeta = const VerificationMeta(
    'frequency',
  );
  @override
  late final GeneratedColumn<int> frequency = GeneratedColumn<int>(
    'frequency',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(1),
  );
  static const VerificationMeta _lastAddDateMeta = const VerificationMeta(
    'lastAddDate',
  );
  @override
  late final GeneratedColumn<int> lastAddDate = GeneratedColumn<int>(
    'last_add_date',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(-1),
  );
  static const VerificationMeta _periodAddTimesMeta = const VerificationMeta(
    'periodAddTimes',
  );
  @override
  late final GeneratedColumn<int> periodAddTimes = GeneratedColumn<int>(
    'period_add_times',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _createTimeMeta = const VerificationMeta(
    'createTime',
  );
  @override
  late final GeneratedColumn<int> createTime = GeneratedColumn<int>(
    'create_time',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _tagsMeta = const VerificationMeta('tags');
  @override
  late final GeneratedColumn<String> tags = GeneratedColumn<String>(
    'tags',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _exiMeta = const VerificationMeta('exi');
  @override
  late final GeneratedColumn<String> exi = GeneratedColumn<String>(
    'exi',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    recordType,
    moneyMinor,
    feeMinor,
    remark,
    catId,
    assetId,
    assetId2,
    bookId,
    images,
    state,
    time,
    excludeBudget,
    excludeExIn,
    periodType,
    periodTypeDate,
    periodStartDate,
    periodEndDate,
    frequency,
    lastAddDate,
    periodAddTimes,
    createTime,
    tags,
    exi,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'record_period';
  @override
  VerificationContext validateIntegrity(
    Insertable<RecordPeriod> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('record_type')) {
      context.handle(
        _recordTypeMeta,
        recordType.isAcceptableOrUnknown(data['record_type']!, _recordTypeMeta),
      );
    } else if (isInserting) {
      context.missing(_recordTypeMeta);
    }
    if (data.containsKey('money_minor')) {
      context.handle(
        _moneyMinorMeta,
        moneyMinor.isAcceptableOrUnknown(data['money_minor']!, _moneyMinorMeta),
      );
    } else if (isInserting) {
      context.missing(_moneyMinorMeta);
    }
    if (data.containsKey('fee_minor')) {
      context.handle(
        _feeMinorMeta,
        feeMinor.isAcceptableOrUnknown(data['fee_minor']!, _feeMinorMeta),
      );
    }
    if (data.containsKey('remark')) {
      context.handle(
        _remarkMeta,
        remark.isAcceptableOrUnknown(data['remark']!, _remarkMeta),
      );
    }
    if (data.containsKey('cat_id')) {
      context.handle(
        _catIdMeta,
        catId.isAcceptableOrUnknown(data['cat_id']!, _catIdMeta),
      );
    }
    if (data.containsKey('asset_id')) {
      context.handle(
        _assetIdMeta,
        assetId.isAcceptableOrUnknown(data['asset_id']!, _assetIdMeta),
      );
    }
    if (data.containsKey('asset_id2')) {
      context.handle(
        _assetId2Meta,
        assetId2.isAcceptableOrUnknown(data['asset_id2']!, _assetId2Meta),
      );
    }
    if (data.containsKey('book_id')) {
      context.handle(
        _bookIdMeta,
        bookId.isAcceptableOrUnknown(data['book_id']!, _bookIdMeta),
      );
    } else if (isInserting) {
      context.missing(_bookIdMeta);
    }
    if (data.containsKey('images')) {
      context.handle(
        _imagesMeta,
        images.isAcceptableOrUnknown(data['images']!, _imagesMeta),
      );
    }
    if (data.containsKey('state')) {
      context.handle(
        _stateMeta,
        state.isAcceptableOrUnknown(data['state']!, _stateMeta),
      );
    }
    if (data.containsKey('time')) {
      context.handle(
        _timeMeta,
        time.isAcceptableOrUnknown(data['time']!, _timeMeta),
      );
    }
    if (data.containsKey('exclude_budget')) {
      context.handle(
        _excludeBudgetMeta,
        excludeBudget.isAcceptableOrUnknown(
          data['exclude_budget']!,
          _excludeBudgetMeta,
        ),
      );
    }
    if (data.containsKey('exclude_ex_in')) {
      context.handle(
        _excludeExInMeta,
        excludeExIn.isAcceptableOrUnknown(
          data['exclude_ex_in']!,
          _excludeExInMeta,
        ),
      );
    }
    if (data.containsKey('period_type')) {
      context.handle(
        _periodTypeMeta,
        periodType.isAcceptableOrUnknown(data['period_type']!, _periodTypeMeta),
      );
    } else if (isInserting) {
      context.missing(_periodTypeMeta);
    }
    if (data.containsKey('period_type_date')) {
      context.handle(
        _periodTypeDateMeta,
        periodTypeDate.isAcceptableOrUnknown(
          data['period_type_date']!,
          _periodTypeDateMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_periodTypeDateMeta);
    }
    if (data.containsKey('period_start_date')) {
      context.handle(
        _periodStartDateMeta,
        periodStartDate.isAcceptableOrUnknown(
          data['period_start_date']!,
          _periodStartDateMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_periodStartDateMeta);
    }
    if (data.containsKey('period_end_date')) {
      context.handle(
        _periodEndDateMeta,
        periodEndDate.isAcceptableOrUnknown(
          data['period_end_date']!,
          _periodEndDateMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_periodEndDateMeta);
    }
    if (data.containsKey('frequency')) {
      context.handle(
        _frequencyMeta,
        frequency.isAcceptableOrUnknown(data['frequency']!, _frequencyMeta),
      );
    }
    if (data.containsKey('last_add_date')) {
      context.handle(
        _lastAddDateMeta,
        lastAddDate.isAcceptableOrUnknown(
          data['last_add_date']!,
          _lastAddDateMeta,
        ),
      );
    }
    if (data.containsKey('period_add_times')) {
      context.handle(
        _periodAddTimesMeta,
        periodAddTimes.isAcceptableOrUnknown(
          data['period_add_times']!,
          _periodAddTimesMeta,
        ),
      );
    }
    if (data.containsKey('create_time')) {
      context.handle(
        _createTimeMeta,
        createTime.isAcceptableOrUnknown(data['create_time']!, _createTimeMeta),
      );
    } else if (isInserting) {
      context.missing(_createTimeMeta);
    }
    if (data.containsKey('tags')) {
      context.handle(
        _tagsMeta,
        tags.isAcceptableOrUnknown(data['tags']!, _tagsMeta),
      );
    }
    if (data.containsKey('exi')) {
      context.handle(
        _exiMeta,
        exi.isAcceptableOrUnknown(data['exi']!, _exiMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  RecordPeriod map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return RecordPeriod(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      recordType: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}record_type'],
      )!,
      moneyMinor: attachedDatabase.typeMapping.read(
        DriftSqlType.bigInt,
        data['${effectivePrefix}money_minor'],
      )!,
      feeMinor: attachedDatabase.typeMapping.read(
        DriftSqlType.bigInt,
        data['${effectivePrefix}fee_minor'],
      )!,
      remark: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}remark'],
      )!,
      catId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}cat_id'],
      )!,
      assetId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}asset_id'],
      )!,
      assetId2: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}asset_id2'],
      )!,
      bookId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}book_id'],
      )!,
      images: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}images'],
      ),
      state: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}state'],
      )!,
      time: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}time'],
      ),
      excludeBudget: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}exclude_budget'],
      )!,
      excludeExIn: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}exclude_ex_in'],
      )!,
      periodType: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}period_type'],
      )!,
      periodTypeDate: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}period_type_date'],
      )!,
      periodStartDate: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}period_start_date'],
      )!,
      periodEndDate: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}period_end_date'],
      )!,
      frequency: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}frequency'],
      )!,
      lastAddDate: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_add_date'],
      )!,
      periodAddTimes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}period_add_times'],
      )!,
      createTime: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}create_time'],
      )!,
      tags: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tags'],
      ),
      exi: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}exi'],
      ),
    );
  }

  @override
  $RecordPeriodsTable createAlias(String alias) {
    return $RecordPeriodsTable(attachedDatabase, alias);
  }
}

class RecordPeriod extends DataClass implements Insertable<RecordPeriod> {
  final int id;
  final int recordType;
  final BigInt moneyMinor;
  final BigInt feeMinor;
  final String remark;
  final int catId;
  final int assetId;
  final int assetId2;
  final int bookId;
  final String? images;
  final int state;
  final String? time;
  final bool excludeBudget;
  final bool excludeExIn;
  final int periodType;
  final String periodTypeDate;
  final int periodStartDate;
  final int periodEndDate;
  final int frequency;
  final int lastAddDate;
  final int periodAddTimes;
  final int createTime;
  final String? tags;
  final String? exi;
  const RecordPeriod({
    required this.id,
    required this.recordType,
    required this.moneyMinor,
    required this.feeMinor,
    required this.remark,
    required this.catId,
    required this.assetId,
    required this.assetId2,
    required this.bookId,
    this.images,
    required this.state,
    this.time,
    required this.excludeBudget,
    required this.excludeExIn,
    required this.periodType,
    required this.periodTypeDate,
    required this.periodStartDate,
    required this.periodEndDate,
    required this.frequency,
    required this.lastAddDate,
    required this.periodAddTimes,
    required this.createTime,
    this.tags,
    this.exi,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['record_type'] = Variable<int>(recordType);
    map['money_minor'] = Variable<BigInt>(moneyMinor);
    map['fee_minor'] = Variable<BigInt>(feeMinor);
    map['remark'] = Variable<String>(remark);
    map['cat_id'] = Variable<int>(catId);
    map['asset_id'] = Variable<int>(assetId);
    map['asset_id2'] = Variable<int>(assetId2);
    map['book_id'] = Variable<int>(bookId);
    if (!nullToAbsent || images != null) {
      map['images'] = Variable<String>(images);
    }
    map['state'] = Variable<int>(state);
    if (!nullToAbsent || time != null) {
      map['time'] = Variable<String>(time);
    }
    map['exclude_budget'] = Variable<bool>(excludeBudget);
    map['exclude_ex_in'] = Variable<bool>(excludeExIn);
    map['period_type'] = Variable<int>(periodType);
    map['period_type_date'] = Variable<String>(periodTypeDate);
    map['period_start_date'] = Variable<int>(periodStartDate);
    map['period_end_date'] = Variable<int>(periodEndDate);
    map['frequency'] = Variable<int>(frequency);
    map['last_add_date'] = Variable<int>(lastAddDate);
    map['period_add_times'] = Variable<int>(periodAddTimes);
    map['create_time'] = Variable<int>(createTime);
    if (!nullToAbsent || tags != null) {
      map['tags'] = Variable<String>(tags);
    }
    if (!nullToAbsent || exi != null) {
      map['exi'] = Variable<String>(exi);
    }
    return map;
  }

  RecordPeriodsCompanion toCompanion(bool nullToAbsent) {
    return RecordPeriodsCompanion(
      id: Value(id),
      recordType: Value(recordType),
      moneyMinor: Value(moneyMinor),
      feeMinor: Value(feeMinor),
      remark: Value(remark),
      catId: Value(catId),
      assetId: Value(assetId),
      assetId2: Value(assetId2),
      bookId: Value(bookId),
      images: images == null && nullToAbsent
          ? const Value.absent()
          : Value(images),
      state: Value(state),
      time: time == null && nullToAbsent ? const Value.absent() : Value(time),
      excludeBudget: Value(excludeBudget),
      excludeExIn: Value(excludeExIn),
      periodType: Value(periodType),
      periodTypeDate: Value(periodTypeDate),
      periodStartDate: Value(periodStartDate),
      periodEndDate: Value(periodEndDate),
      frequency: Value(frequency),
      lastAddDate: Value(lastAddDate),
      periodAddTimes: Value(periodAddTimes),
      createTime: Value(createTime),
      tags: tags == null && nullToAbsent ? const Value.absent() : Value(tags),
      exi: exi == null && nullToAbsent ? const Value.absent() : Value(exi),
    );
  }

  factory RecordPeriod.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return RecordPeriod(
      id: serializer.fromJson<int>(json['id']),
      recordType: serializer.fromJson<int>(json['recordType']),
      moneyMinor: serializer.fromJson<BigInt>(json['moneyMinor']),
      feeMinor: serializer.fromJson<BigInt>(json['feeMinor']),
      remark: serializer.fromJson<String>(json['remark']),
      catId: serializer.fromJson<int>(json['catId']),
      assetId: serializer.fromJson<int>(json['assetId']),
      assetId2: serializer.fromJson<int>(json['assetId2']),
      bookId: serializer.fromJson<int>(json['bookId']),
      images: serializer.fromJson<String?>(json['images']),
      state: serializer.fromJson<int>(json['state']),
      time: serializer.fromJson<String?>(json['time']),
      excludeBudget: serializer.fromJson<bool>(json['excludeBudget']),
      excludeExIn: serializer.fromJson<bool>(json['excludeExIn']),
      periodType: serializer.fromJson<int>(json['periodType']),
      periodTypeDate: serializer.fromJson<String>(json['periodTypeDate']),
      periodStartDate: serializer.fromJson<int>(json['periodStartDate']),
      periodEndDate: serializer.fromJson<int>(json['periodEndDate']),
      frequency: serializer.fromJson<int>(json['frequency']),
      lastAddDate: serializer.fromJson<int>(json['lastAddDate']),
      periodAddTimes: serializer.fromJson<int>(json['periodAddTimes']),
      createTime: serializer.fromJson<int>(json['createTime']),
      tags: serializer.fromJson<String?>(json['tags']),
      exi: serializer.fromJson<String?>(json['exi']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'recordType': serializer.toJson<int>(recordType),
      'moneyMinor': serializer.toJson<BigInt>(moneyMinor),
      'feeMinor': serializer.toJson<BigInt>(feeMinor),
      'remark': serializer.toJson<String>(remark),
      'catId': serializer.toJson<int>(catId),
      'assetId': serializer.toJson<int>(assetId),
      'assetId2': serializer.toJson<int>(assetId2),
      'bookId': serializer.toJson<int>(bookId),
      'images': serializer.toJson<String?>(images),
      'state': serializer.toJson<int>(state),
      'time': serializer.toJson<String?>(time),
      'excludeBudget': serializer.toJson<bool>(excludeBudget),
      'excludeExIn': serializer.toJson<bool>(excludeExIn),
      'periodType': serializer.toJson<int>(periodType),
      'periodTypeDate': serializer.toJson<String>(periodTypeDate),
      'periodStartDate': serializer.toJson<int>(periodStartDate),
      'periodEndDate': serializer.toJson<int>(periodEndDate),
      'frequency': serializer.toJson<int>(frequency),
      'lastAddDate': serializer.toJson<int>(lastAddDate),
      'periodAddTimes': serializer.toJson<int>(periodAddTimes),
      'createTime': serializer.toJson<int>(createTime),
      'tags': serializer.toJson<String?>(tags),
      'exi': serializer.toJson<String?>(exi),
    };
  }

  RecordPeriod copyWith({
    int? id,
    int? recordType,
    BigInt? moneyMinor,
    BigInt? feeMinor,
    String? remark,
    int? catId,
    int? assetId,
    int? assetId2,
    int? bookId,
    Value<String?> images = const Value.absent(),
    int? state,
    Value<String?> time = const Value.absent(),
    bool? excludeBudget,
    bool? excludeExIn,
    int? periodType,
    String? periodTypeDate,
    int? periodStartDate,
    int? periodEndDate,
    int? frequency,
    int? lastAddDate,
    int? periodAddTimes,
    int? createTime,
    Value<String?> tags = const Value.absent(),
    Value<String?> exi = const Value.absent(),
  }) => RecordPeriod(
    id: id ?? this.id,
    recordType: recordType ?? this.recordType,
    moneyMinor: moneyMinor ?? this.moneyMinor,
    feeMinor: feeMinor ?? this.feeMinor,
    remark: remark ?? this.remark,
    catId: catId ?? this.catId,
    assetId: assetId ?? this.assetId,
    assetId2: assetId2 ?? this.assetId2,
    bookId: bookId ?? this.bookId,
    images: images.present ? images.value : this.images,
    state: state ?? this.state,
    time: time.present ? time.value : this.time,
    excludeBudget: excludeBudget ?? this.excludeBudget,
    excludeExIn: excludeExIn ?? this.excludeExIn,
    periodType: periodType ?? this.periodType,
    periodTypeDate: periodTypeDate ?? this.periodTypeDate,
    periodStartDate: periodStartDate ?? this.periodStartDate,
    periodEndDate: periodEndDate ?? this.periodEndDate,
    frequency: frequency ?? this.frequency,
    lastAddDate: lastAddDate ?? this.lastAddDate,
    periodAddTimes: periodAddTimes ?? this.periodAddTimes,
    createTime: createTime ?? this.createTime,
    tags: tags.present ? tags.value : this.tags,
    exi: exi.present ? exi.value : this.exi,
  );
  RecordPeriod copyWithCompanion(RecordPeriodsCompanion data) {
    return RecordPeriod(
      id: data.id.present ? data.id.value : this.id,
      recordType: data.recordType.present
          ? data.recordType.value
          : this.recordType,
      moneyMinor: data.moneyMinor.present
          ? data.moneyMinor.value
          : this.moneyMinor,
      feeMinor: data.feeMinor.present ? data.feeMinor.value : this.feeMinor,
      remark: data.remark.present ? data.remark.value : this.remark,
      catId: data.catId.present ? data.catId.value : this.catId,
      assetId: data.assetId.present ? data.assetId.value : this.assetId,
      assetId2: data.assetId2.present ? data.assetId2.value : this.assetId2,
      bookId: data.bookId.present ? data.bookId.value : this.bookId,
      images: data.images.present ? data.images.value : this.images,
      state: data.state.present ? data.state.value : this.state,
      time: data.time.present ? data.time.value : this.time,
      excludeBudget: data.excludeBudget.present
          ? data.excludeBudget.value
          : this.excludeBudget,
      excludeExIn: data.excludeExIn.present
          ? data.excludeExIn.value
          : this.excludeExIn,
      periodType: data.periodType.present
          ? data.periodType.value
          : this.periodType,
      periodTypeDate: data.periodTypeDate.present
          ? data.periodTypeDate.value
          : this.periodTypeDate,
      periodStartDate: data.periodStartDate.present
          ? data.periodStartDate.value
          : this.periodStartDate,
      periodEndDate: data.periodEndDate.present
          ? data.periodEndDate.value
          : this.periodEndDate,
      frequency: data.frequency.present ? data.frequency.value : this.frequency,
      lastAddDate: data.lastAddDate.present
          ? data.lastAddDate.value
          : this.lastAddDate,
      periodAddTimes: data.periodAddTimes.present
          ? data.periodAddTimes.value
          : this.periodAddTimes,
      createTime: data.createTime.present
          ? data.createTime.value
          : this.createTime,
      tags: data.tags.present ? data.tags.value : this.tags,
      exi: data.exi.present ? data.exi.value : this.exi,
    );
  }

  @override
  String toString() {
    return (StringBuffer('RecordPeriod(')
          ..write('id: $id, ')
          ..write('recordType: $recordType, ')
          ..write('moneyMinor: $moneyMinor, ')
          ..write('feeMinor: $feeMinor, ')
          ..write('remark: $remark, ')
          ..write('catId: $catId, ')
          ..write('assetId: $assetId, ')
          ..write('assetId2: $assetId2, ')
          ..write('bookId: $bookId, ')
          ..write('images: $images, ')
          ..write('state: $state, ')
          ..write('time: $time, ')
          ..write('excludeBudget: $excludeBudget, ')
          ..write('excludeExIn: $excludeExIn, ')
          ..write('periodType: $periodType, ')
          ..write('periodTypeDate: $periodTypeDate, ')
          ..write('periodStartDate: $periodStartDate, ')
          ..write('periodEndDate: $periodEndDate, ')
          ..write('frequency: $frequency, ')
          ..write('lastAddDate: $lastAddDate, ')
          ..write('periodAddTimes: $periodAddTimes, ')
          ..write('createTime: $createTime, ')
          ..write('tags: $tags, ')
          ..write('exi: $exi')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    id,
    recordType,
    moneyMinor,
    feeMinor,
    remark,
    catId,
    assetId,
    assetId2,
    bookId,
    images,
    state,
    time,
    excludeBudget,
    excludeExIn,
    periodType,
    periodTypeDate,
    periodStartDate,
    periodEndDate,
    frequency,
    lastAddDate,
    periodAddTimes,
    createTime,
    tags,
    exi,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RecordPeriod &&
          other.id == this.id &&
          other.recordType == this.recordType &&
          other.moneyMinor == this.moneyMinor &&
          other.feeMinor == this.feeMinor &&
          other.remark == this.remark &&
          other.catId == this.catId &&
          other.assetId == this.assetId &&
          other.assetId2 == this.assetId2 &&
          other.bookId == this.bookId &&
          other.images == this.images &&
          other.state == this.state &&
          other.time == this.time &&
          other.excludeBudget == this.excludeBudget &&
          other.excludeExIn == this.excludeExIn &&
          other.periodType == this.periodType &&
          other.periodTypeDate == this.periodTypeDate &&
          other.periodStartDate == this.periodStartDate &&
          other.periodEndDate == this.periodEndDate &&
          other.frequency == this.frequency &&
          other.lastAddDate == this.lastAddDate &&
          other.periodAddTimes == this.periodAddTimes &&
          other.createTime == this.createTime &&
          other.tags == this.tags &&
          other.exi == this.exi);
}

class RecordPeriodsCompanion extends UpdateCompanion<RecordPeriod> {
  final Value<int> id;
  final Value<int> recordType;
  final Value<BigInt> moneyMinor;
  final Value<BigInt> feeMinor;
  final Value<String> remark;
  final Value<int> catId;
  final Value<int> assetId;
  final Value<int> assetId2;
  final Value<int> bookId;
  final Value<String?> images;
  final Value<int> state;
  final Value<String?> time;
  final Value<bool> excludeBudget;
  final Value<bool> excludeExIn;
  final Value<int> periodType;
  final Value<String> periodTypeDate;
  final Value<int> periodStartDate;
  final Value<int> periodEndDate;
  final Value<int> frequency;
  final Value<int> lastAddDate;
  final Value<int> periodAddTimes;
  final Value<int> createTime;
  final Value<String?> tags;
  final Value<String?> exi;
  const RecordPeriodsCompanion({
    this.id = const Value.absent(),
    this.recordType = const Value.absent(),
    this.moneyMinor = const Value.absent(),
    this.feeMinor = const Value.absent(),
    this.remark = const Value.absent(),
    this.catId = const Value.absent(),
    this.assetId = const Value.absent(),
    this.assetId2 = const Value.absent(),
    this.bookId = const Value.absent(),
    this.images = const Value.absent(),
    this.state = const Value.absent(),
    this.time = const Value.absent(),
    this.excludeBudget = const Value.absent(),
    this.excludeExIn = const Value.absent(),
    this.periodType = const Value.absent(),
    this.periodTypeDate = const Value.absent(),
    this.periodStartDate = const Value.absent(),
    this.periodEndDate = const Value.absent(),
    this.frequency = const Value.absent(),
    this.lastAddDate = const Value.absent(),
    this.periodAddTimes = const Value.absent(),
    this.createTime = const Value.absent(),
    this.tags = const Value.absent(),
    this.exi = const Value.absent(),
  });
  RecordPeriodsCompanion.insert({
    this.id = const Value.absent(),
    required int recordType,
    required BigInt moneyMinor,
    this.feeMinor = const Value.absent(),
    this.remark = const Value.absent(),
    this.catId = const Value.absent(),
    this.assetId = const Value.absent(),
    this.assetId2 = const Value.absent(),
    required int bookId,
    this.images = const Value.absent(),
    this.state = const Value.absent(),
    this.time = const Value.absent(),
    this.excludeBudget = const Value.absent(),
    this.excludeExIn = const Value.absent(),
    required int periodType,
    required String periodTypeDate,
    required int periodStartDate,
    required int periodEndDate,
    this.frequency = const Value.absent(),
    this.lastAddDate = const Value.absent(),
    this.periodAddTimes = const Value.absent(),
    required int createTime,
    this.tags = const Value.absent(),
    this.exi = const Value.absent(),
  }) : recordType = Value(recordType),
       moneyMinor = Value(moneyMinor),
       bookId = Value(bookId),
       periodType = Value(periodType),
       periodTypeDate = Value(periodTypeDate),
       periodStartDate = Value(periodStartDate),
       periodEndDate = Value(periodEndDate),
       createTime = Value(createTime);
  static Insertable<RecordPeriod> custom({
    Expression<int>? id,
    Expression<int>? recordType,
    Expression<BigInt>? moneyMinor,
    Expression<BigInt>? feeMinor,
    Expression<String>? remark,
    Expression<int>? catId,
    Expression<int>? assetId,
    Expression<int>? assetId2,
    Expression<int>? bookId,
    Expression<String>? images,
    Expression<int>? state,
    Expression<String>? time,
    Expression<bool>? excludeBudget,
    Expression<bool>? excludeExIn,
    Expression<int>? periodType,
    Expression<String>? periodTypeDate,
    Expression<int>? periodStartDate,
    Expression<int>? periodEndDate,
    Expression<int>? frequency,
    Expression<int>? lastAddDate,
    Expression<int>? periodAddTimes,
    Expression<int>? createTime,
    Expression<String>? tags,
    Expression<String>? exi,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (recordType != null) 'record_type': recordType,
      if (moneyMinor != null) 'money_minor': moneyMinor,
      if (feeMinor != null) 'fee_minor': feeMinor,
      if (remark != null) 'remark': remark,
      if (catId != null) 'cat_id': catId,
      if (assetId != null) 'asset_id': assetId,
      if (assetId2 != null) 'asset_id2': assetId2,
      if (bookId != null) 'book_id': bookId,
      if (images != null) 'images': images,
      if (state != null) 'state': state,
      if (time != null) 'time': time,
      if (excludeBudget != null) 'exclude_budget': excludeBudget,
      if (excludeExIn != null) 'exclude_ex_in': excludeExIn,
      if (periodType != null) 'period_type': periodType,
      if (periodTypeDate != null) 'period_type_date': periodTypeDate,
      if (periodStartDate != null) 'period_start_date': periodStartDate,
      if (periodEndDate != null) 'period_end_date': periodEndDate,
      if (frequency != null) 'frequency': frequency,
      if (lastAddDate != null) 'last_add_date': lastAddDate,
      if (periodAddTimes != null) 'period_add_times': periodAddTimes,
      if (createTime != null) 'create_time': createTime,
      if (tags != null) 'tags': tags,
      if (exi != null) 'exi': exi,
    });
  }

  RecordPeriodsCompanion copyWith({
    Value<int>? id,
    Value<int>? recordType,
    Value<BigInt>? moneyMinor,
    Value<BigInt>? feeMinor,
    Value<String>? remark,
    Value<int>? catId,
    Value<int>? assetId,
    Value<int>? assetId2,
    Value<int>? bookId,
    Value<String?>? images,
    Value<int>? state,
    Value<String?>? time,
    Value<bool>? excludeBudget,
    Value<bool>? excludeExIn,
    Value<int>? periodType,
    Value<String>? periodTypeDate,
    Value<int>? periodStartDate,
    Value<int>? periodEndDate,
    Value<int>? frequency,
    Value<int>? lastAddDate,
    Value<int>? periodAddTimes,
    Value<int>? createTime,
    Value<String?>? tags,
    Value<String?>? exi,
  }) {
    return RecordPeriodsCompanion(
      id: id ?? this.id,
      recordType: recordType ?? this.recordType,
      moneyMinor: moneyMinor ?? this.moneyMinor,
      feeMinor: feeMinor ?? this.feeMinor,
      remark: remark ?? this.remark,
      catId: catId ?? this.catId,
      assetId: assetId ?? this.assetId,
      assetId2: assetId2 ?? this.assetId2,
      bookId: bookId ?? this.bookId,
      images: images ?? this.images,
      state: state ?? this.state,
      time: time ?? this.time,
      excludeBudget: excludeBudget ?? this.excludeBudget,
      excludeExIn: excludeExIn ?? this.excludeExIn,
      periodType: periodType ?? this.periodType,
      periodTypeDate: periodTypeDate ?? this.periodTypeDate,
      periodStartDate: periodStartDate ?? this.periodStartDate,
      periodEndDate: periodEndDate ?? this.periodEndDate,
      frequency: frequency ?? this.frequency,
      lastAddDate: lastAddDate ?? this.lastAddDate,
      periodAddTimes: periodAddTimes ?? this.periodAddTimes,
      createTime: createTime ?? this.createTime,
      tags: tags ?? this.tags,
      exi: exi ?? this.exi,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (recordType.present) {
      map['record_type'] = Variable<int>(recordType.value);
    }
    if (moneyMinor.present) {
      map['money_minor'] = Variable<BigInt>(moneyMinor.value);
    }
    if (feeMinor.present) {
      map['fee_minor'] = Variable<BigInt>(feeMinor.value);
    }
    if (remark.present) {
      map['remark'] = Variable<String>(remark.value);
    }
    if (catId.present) {
      map['cat_id'] = Variable<int>(catId.value);
    }
    if (assetId.present) {
      map['asset_id'] = Variable<int>(assetId.value);
    }
    if (assetId2.present) {
      map['asset_id2'] = Variable<int>(assetId2.value);
    }
    if (bookId.present) {
      map['book_id'] = Variable<int>(bookId.value);
    }
    if (images.present) {
      map['images'] = Variable<String>(images.value);
    }
    if (state.present) {
      map['state'] = Variable<int>(state.value);
    }
    if (time.present) {
      map['time'] = Variable<String>(time.value);
    }
    if (excludeBudget.present) {
      map['exclude_budget'] = Variable<bool>(excludeBudget.value);
    }
    if (excludeExIn.present) {
      map['exclude_ex_in'] = Variable<bool>(excludeExIn.value);
    }
    if (periodType.present) {
      map['period_type'] = Variable<int>(periodType.value);
    }
    if (periodTypeDate.present) {
      map['period_type_date'] = Variable<String>(periodTypeDate.value);
    }
    if (periodStartDate.present) {
      map['period_start_date'] = Variable<int>(periodStartDate.value);
    }
    if (periodEndDate.present) {
      map['period_end_date'] = Variable<int>(periodEndDate.value);
    }
    if (frequency.present) {
      map['frequency'] = Variable<int>(frequency.value);
    }
    if (lastAddDate.present) {
      map['last_add_date'] = Variable<int>(lastAddDate.value);
    }
    if (periodAddTimes.present) {
      map['period_add_times'] = Variable<int>(periodAddTimes.value);
    }
    if (createTime.present) {
      map['create_time'] = Variable<int>(createTime.value);
    }
    if (tags.present) {
      map['tags'] = Variable<String>(tags.value);
    }
    if (exi.present) {
      map['exi'] = Variable<String>(exi.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('RecordPeriodsCompanion(')
          ..write('id: $id, ')
          ..write('recordType: $recordType, ')
          ..write('moneyMinor: $moneyMinor, ')
          ..write('feeMinor: $feeMinor, ')
          ..write('remark: $remark, ')
          ..write('catId: $catId, ')
          ..write('assetId: $assetId, ')
          ..write('assetId2: $assetId2, ')
          ..write('bookId: $bookId, ')
          ..write('images: $images, ')
          ..write('state: $state, ')
          ..write('time: $time, ')
          ..write('excludeBudget: $excludeBudget, ')
          ..write('excludeExIn: $excludeExIn, ')
          ..write('periodType: $periodType, ')
          ..write('periodTypeDate: $periodTypeDate, ')
          ..write('periodStartDate: $periodStartDate, ')
          ..write('periodEndDate: $periodEndDate, ')
          ..write('frequency: $frequency, ')
          ..write('lastAddDate: $lastAddDate, ')
          ..write('periodAddTimes: $periodAddTimes, ')
          ..write('createTime: $createTime, ')
          ..write('tags: $tags, ')
          ..write('exi: $exi')
          ..write(')'))
        .toString();
  }
}

class $ReminderEventsTable extends ReminderEvents
    with TableInfo<$ReminderEventsTable, ReminderEvent> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ReminderEventsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _reminderTimeMeta = const VerificationMeta(
    'reminderTime',
  );
  @override
  late final GeneratedColumn<int> reminderTime = GeneratedColumn<int>(
    'reminder_time',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _reminderTipMeta = const VerificationMeta(
    'reminderTip',
  );
  @override
  late final GeneratedColumn<String> reminderTip = GeneratedColumn<String>(
    'reminder_tip',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [id, reminderTime, reminderTip];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'reminder_event';
  @override
  VerificationContext validateIntegrity(
    Insertable<ReminderEvent> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('reminder_time')) {
      context.handle(
        _reminderTimeMeta,
        reminderTime.isAcceptableOrUnknown(
          data['reminder_time']!,
          _reminderTimeMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_reminderTimeMeta);
    }
    if (data.containsKey('reminder_tip')) {
      context.handle(
        _reminderTipMeta,
        reminderTip.isAcceptableOrUnknown(
          data['reminder_tip']!,
          _reminderTipMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ReminderEvent map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ReminderEvent(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      reminderTime: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}reminder_time'],
      )!,
      reminderTip: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}reminder_tip'],
      ),
    );
  }

  @override
  $ReminderEventsTable createAlias(String alias) {
    return $ReminderEventsTable(attachedDatabase, alias);
  }
}

class ReminderEvent extends DataClass implements Insertable<ReminderEvent> {
  final int id;
  final int reminderTime;
  final String? reminderTip;
  const ReminderEvent({
    required this.id,
    required this.reminderTime,
    this.reminderTip,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['reminder_time'] = Variable<int>(reminderTime);
    if (!nullToAbsent || reminderTip != null) {
      map['reminder_tip'] = Variable<String>(reminderTip);
    }
    return map;
  }

  ReminderEventsCompanion toCompanion(bool nullToAbsent) {
    return ReminderEventsCompanion(
      id: Value(id),
      reminderTime: Value(reminderTime),
      reminderTip: reminderTip == null && nullToAbsent
          ? const Value.absent()
          : Value(reminderTip),
    );
  }

  factory ReminderEvent.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ReminderEvent(
      id: serializer.fromJson<int>(json['id']),
      reminderTime: serializer.fromJson<int>(json['reminderTime']),
      reminderTip: serializer.fromJson<String?>(json['reminderTip']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'reminderTime': serializer.toJson<int>(reminderTime),
      'reminderTip': serializer.toJson<String?>(reminderTip),
    };
  }

  ReminderEvent copyWith({
    int? id,
    int? reminderTime,
    Value<String?> reminderTip = const Value.absent(),
  }) => ReminderEvent(
    id: id ?? this.id,
    reminderTime: reminderTime ?? this.reminderTime,
    reminderTip: reminderTip.present ? reminderTip.value : this.reminderTip,
  );
  ReminderEvent copyWithCompanion(ReminderEventsCompanion data) {
    return ReminderEvent(
      id: data.id.present ? data.id.value : this.id,
      reminderTime: data.reminderTime.present
          ? data.reminderTime.value
          : this.reminderTime,
      reminderTip: data.reminderTip.present
          ? data.reminderTip.value
          : this.reminderTip,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ReminderEvent(')
          ..write('id: $id, ')
          ..write('reminderTime: $reminderTime, ')
          ..write('reminderTip: $reminderTip')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, reminderTime, reminderTip);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ReminderEvent &&
          other.id == this.id &&
          other.reminderTime == this.reminderTime &&
          other.reminderTip == this.reminderTip);
}

class ReminderEventsCompanion extends UpdateCompanion<ReminderEvent> {
  final Value<int> id;
  final Value<int> reminderTime;
  final Value<String?> reminderTip;
  const ReminderEventsCompanion({
    this.id = const Value.absent(),
    this.reminderTime = const Value.absent(),
    this.reminderTip = const Value.absent(),
  });
  ReminderEventsCompanion.insert({
    this.id = const Value.absent(),
    required int reminderTime,
    this.reminderTip = const Value.absent(),
  }) : reminderTime = Value(reminderTime);
  static Insertable<ReminderEvent> custom({
    Expression<int>? id,
    Expression<int>? reminderTime,
    Expression<String>? reminderTip,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (reminderTime != null) 'reminder_time': reminderTime,
      if (reminderTip != null) 'reminder_tip': reminderTip,
    });
  }

  ReminderEventsCompanion copyWith({
    Value<int>? id,
    Value<int>? reminderTime,
    Value<String?>? reminderTip,
  }) {
    return ReminderEventsCompanion(
      id: id ?? this.id,
      reminderTime: reminderTime ?? this.reminderTime,
      reminderTip: reminderTip ?? this.reminderTip,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (reminderTime.present) {
      map['reminder_time'] = Variable<int>(reminderTime.value);
    }
    if (reminderTip.present) {
      map['reminder_tip'] = Variable<String>(reminderTip.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ReminderEventsCompanion(')
          ..write('id: $id, ')
          ..write('reminderTime: $reminderTime, ')
          ..write('reminderTip: $reminderTip')
          ..write(')'))
        .toString();
  }
}

class $InstallmentsTable extends Installments
    with TableInfo<$InstallmentsTable, Installment> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $InstallmentsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _catIdMeta = const VerificationMeta('catId');
  @override
  late final GeneratedColumn<int> catId = GeneratedColumn<int>(
    'cat_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(-1),
  );
  static const VerificationMeta _principalMinorMeta = const VerificationMeta(
    'principalMinor',
  );
  @override
  late final GeneratedColumn<BigInt> principalMinor = GeneratedColumn<BigInt>(
    'principal_minor',
    aliasedName,
    false,
    type: DriftSqlType.bigInt,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _periodsMeta = const VerificationMeta(
    'periods',
  );
  @override
  late final GeneratedColumn<int> periods = GeneratedColumn<int>(
    'periods',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _chargeMinorMeta = const VerificationMeta(
    'chargeMinor',
  );
  @override
  late final GeneratedColumn<BigInt> chargeMinor = GeneratedColumn<BigInt>(
    'charge_minor',
    aliasedName,
    false,
    type: DriftSqlType.bigInt,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _chargeWayMeta = const VerificationMeta(
    'chargeWay',
  );
  @override
  late final GeneratedColumn<int> chargeWay = GeneratedColumn<int>(
    'charge_way',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _remainderInMeta = const VerificationMeta(
    'remainderIn',
  );
  @override
  late final GeneratedColumn<int> remainderIn = GeneratedColumn<int>(
    'remainder_in',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _calWayMeta = const VerificationMeta('calWay');
  @override
  late final GeneratedColumn<int> calWay = GeneratedColumn<int>(
    'cal_way',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _startDateMeta = const VerificationMeta(
    'startDate',
  );
  @override
  late final GeneratedColumn<int> startDate = GeneratedColumn<int>(
    'start_date',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _assetIdMeta = const VerificationMeta(
    'assetId',
  );
  @override
  late final GeneratedColumn<int> assetId = GeneratedColumn<int>(
    'asset_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nextPeriodMeta = const VerificationMeta(
    'nextPeriod',
  );
  @override
  late final GeneratedColumn<int> nextPeriod = GeneratedColumn<int>(
    'next_period',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nextPeriodDateMeta = const VerificationMeta(
    'nextPeriodDate',
  );
  @override
  late final GeneratedColumn<int> nextPeriodDate = GeneratedColumn<int>(
    'next_period_date',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _creditedMeta = const VerificationMeta(
    'credited',
  );
  @override
  late final GeneratedColumn<String> credited = GeneratedColumn<String>(
    'credited',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _bookIdMeta = const VerificationMeta('bookId');
  @override
  late final GeneratedColumn<int> bookId = GeneratedColumn<int>(
    'book_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _excludeBudgetMeta = const VerificationMeta(
    'excludeBudget',
  );
  @override
  late final GeneratedColumn<bool> excludeBudget = GeneratedColumn<bool>(
    'exclude_budget',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("exclude_budget" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _excludeExInMeta = const VerificationMeta(
    'excludeExIn',
  );
  @override
  late final GeneratedColumn<bool> excludeExIn = GeneratedColumn<bool>(
    'exclude_ex_in',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("exclude_ex_in" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _createDateMeta = const VerificationMeta(
    'createDate',
  );
  @override
  late final GeneratedColumn<int> createDate = GeneratedColumn<int>(
    'create_date',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _tagsMeta = const VerificationMeta('tags');
  @override
  late final GeneratedColumn<String> tags = GeneratedColumn<String>(
    'tags',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _imagesMeta = const VerificationMeta('images');
  @override
  late final GeneratedColumn<String> images = GeneratedColumn<String>(
    'images',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _exiMeta = const VerificationMeta('exi');
  @override
  late final GeneratedColumn<String> exi = GeneratedColumn<String>(
    'exi',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    catId,
    principalMinor,
    periods,
    chargeMinor,
    chargeWay,
    remainderIn,
    calWay,
    startDate,
    assetId,
    nextPeriod,
    nextPeriodDate,
    credited,
    bookId,
    excludeBudget,
    excludeExIn,
    createDate,
    tags,
    images,
    exi,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'installment';
  @override
  VerificationContext validateIntegrity(
    Insertable<Installment> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('cat_id')) {
      context.handle(
        _catIdMeta,
        catId.isAcceptableOrUnknown(data['cat_id']!, _catIdMeta),
      );
    }
    if (data.containsKey('principal_minor')) {
      context.handle(
        _principalMinorMeta,
        principalMinor.isAcceptableOrUnknown(
          data['principal_minor']!,
          _principalMinorMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_principalMinorMeta);
    }
    if (data.containsKey('periods')) {
      context.handle(
        _periodsMeta,
        periods.isAcceptableOrUnknown(data['periods']!, _periodsMeta),
      );
    } else if (isInserting) {
      context.missing(_periodsMeta);
    }
    if (data.containsKey('charge_minor')) {
      context.handle(
        _chargeMinorMeta,
        chargeMinor.isAcceptableOrUnknown(
          data['charge_minor']!,
          _chargeMinorMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_chargeMinorMeta);
    }
    if (data.containsKey('charge_way')) {
      context.handle(
        _chargeWayMeta,
        chargeWay.isAcceptableOrUnknown(data['charge_way']!, _chargeWayMeta),
      );
    } else if (isInserting) {
      context.missing(_chargeWayMeta);
    }
    if (data.containsKey('remainder_in')) {
      context.handle(
        _remainderInMeta,
        remainderIn.isAcceptableOrUnknown(
          data['remainder_in']!,
          _remainderInMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_remainderInMeta);
    }
    if (data.containsKey('cal_way')) {
      context.handle(
        _calWayMeta,
        calWay.isAcceptableOrUnknown(data['cal_way']!, _calWayMeta),
      );
    } else if (isInserting) {
      context.missing(_calWayMeta);
    }
    if (data.containsKey('start_date')) {
      context.handle(
        _startDateMeta,
        startDate.isAcceptableOrUnknown(data['start_date']!, _startDateMeta),
      );
    } else if (isInserting) {
      context.missing(_startDateMeta);
    }
    if (data.containsKey('asset_id')) {
      context.handle(
        _assetIdMeta,
        assetId.isAcceptableOrUnknown(data['asset_id']!, _assetIdMeta),
      );
    } else if (isInserting) {
      context.missing(_assetIdMeta);
    }
    if (data.containsKey('next_period')) {
      context.handle(
        _nextPeriodMeta,
        nextPeriod.isAcceptableOrUnknown(data['next_period']!, _nextPeriodMeta),
      );
    } else if (isInserting) {
      context.missing(_nextPeriodMeta);
    }
    if (data.containsKey('next_period_date')) {
      context.handle(
        _nextPeriodDateMeta,
        nextPeriodDate.isAcceptableOrUnknown(
          data['next_period_date']!,
          _nextPeriodDateMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_nextPeriodDateMeta);
    }
    if (data.containsKey('credited')) {
      context.handle(
        _creditedMeta,
        credited.isAcceptableOrUnknown(data['credited']!, _creditedMeta),
      );
    }
    if (data.containsKey('book_id')) {
      context.handle(
        _bookIdMeta,
        bookId.isAcceptableOrUnknown(data['book_id']!, _bookIdMeta),
      );
    } else if (isInserting) {
      context.missing(_bookIdMeta);
    }
    if (data.containsKey('exclude_budget')) {
      context.handle(
        _excludeBudgetMeta,
        excludeBudget.isAcceptableOrUnknown(
          data['exclude_budget']!,
          _excludeBudgetMeta,
        ),
      );
    }
    if (data.containsKey('exclude_ex_in')) {
      context.handle(
        _excludeExInMeta,
        excludeExIn.isAcceptableOrUnknown(
          data['exclude_ex_in']!,
          _excludeExInMeta,
        ),
      );
    }
    if (data.containsKey('create_date')) {
      context.handle(
        _createDateMeta,
        createDate.isAcceptableOrUnknown(data['create_date']!, _createDateMeta),
      );
    } else if (isInserting) {
      context.missing(_createDateMeta);
    }
    if (data.containsKey('tags')) {
      context.handle(
        _tagsMeta,
        tags.isAcceptableOrUnknown(data['tags']!, _tagsMeta),
      );
    }
    if (data.containsKey('images')) {
      context.handle(
        _imagesMeta,
        images.isAcceptableOrUnknown(data['images']!, _imagesMeta),
      );
    }
    if (data.containsKey('exi')) {
      context.handle(
        _exiMeta,
        exi.isAcceptableOrUnknown(data['exi']!, _exiMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Installment map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Installment(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      catId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}cat_id'],
      )!,
      principalMinor: attachedDatabase.typeMapping.read(
        DriftSqlType.bigInt,
        data['${effectivePrefix}principal_minor'],
      )!,
      periods: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}periods'],
      )!,
      chargeMinor: attachedDatabase.typeMapping.read(
        DriftSqlType.bigInt,
        data['${effectivePrefix}charge_minor'],
      )!,
      chargeWay: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}charge_way'],
      )!,
      remainderIn: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}remainder_in'],
      )!,
      calWay: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}cal_way'],
      )!,
      startDate: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}start_date'],
      )!,
      assetId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}asset_id'],
      )!,
      nextPeriod: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}next_period'],
      )!,
      nextPeriodDate: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}next_period_date'],
      )!,
      credited: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}credited'],
      ),
      bookId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}book_id'],
      )!,
      excludeBudget: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}exclude_budget'],
      )!,
      excludeExIn: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}exclude_ex_in'],
      )!,
      createDate: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}create_date'],
      )!,
      tags: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tags'],
      ),
      images: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}images'],
      ),
      exi: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}exi'],
      ),
    );
  }

  @override
  $InstallmentsTable createAlias(String alias) {
    return $InstallmentsTable(attachedDatabase, alias);
  }
}

class Installment extends DataClass implements Insertable<Installment> {
  final int id;
  final String name;
  final int catId;
  final BigInt principalMinor;
  final int periods;
  final BigInt chargeMinor;
  final int chargeWay;
  final int remainderIn;
  final int calWay;
  final int startDate;
  final int assetId;
  final int nextPeriod;
  final int nextPeriodDate;
  final String? credited;
  final int bookId;
  final bool excludeBudget;
  final bool excludeExIn;
  final int createDate;
  final String? tags;
  final String? images;
  final String? exi;
  const Installment({
    required this.id,
    required this.name,
    required this.catId,
    required this.principalMinor,
    required this.periods,
    required this.chargeMinor,
    required this.chargeWay,
    required this.remainderIn,
    required this.calWay,
    required this.startDate,
    required this.assetId,
    required this.nextPeriod,
    required this.nextPeriodDate,
    this.credited,
    required this.bookId,
    required this.excludeBudget,
    required this.excludeExIn,
    required this.createDate,
    this.tags,
    this.images,
    this.exi,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['name'] = Variable<String>(name);
    map['cat_id'] = Variable<int>(catId);
    map['principal_minor'] = Variable<BigInt>(principalMinor);
    map['periods'] = Variable<int>(periods);
    map['charge_minor'] = Variable<BigInt>(chargeMinor);
    map['charge_way'] = Variable<int>(chargeWay);
    map['remainder_in'] = Variable<int>(remainderIn);
    map['cal_way'] = Variable<int>(calWay);
    map['start_date'] = Variable<int>(startDate);
    map['asset_id'] = Variable<int>(assetId);
    map['next_period'] = Variable<int>(nextPeriod);
    map['next_period_date'] = Variable<int>(nextPeriodDate);
    if (!nullToAbsent || credited != null) {
      map['credited'] = Variable<String>(credited);
    }
    map['book_id'] = Variable<int>(bookId);
    map['exclude_budget'] = Variable<bool>(excludeBudget);
    map['exclude_ex_in'] = Variable<bool>(excludeExIn);
    map['create_date'] = Variable<int>(createDate);
    if (!nullToAbsent || tags != null) {
      map['tags'] = Variable<String>(tags);
    }
    if (!nullToAbsent || images != null) {
      map['images'] = Variable<String>(images);
    }
    if (!nullToAbsent || exi != null) {
      map['exi'] = Variable<String>(exi);
    }
    return map;
  }

  InstallmentsCompanion toCompanion(bool nullToAbsent) {
    return InstallmentsCompanion(
      id: Value(id),
      name: Value(name),
      catId: Value(catId),
      principalMinor: Value(principalMinor),
      periods: Value(periods),
      chargeMinor: Value(chargeMinor),
      chargeWay: Value(chargeWay),
      remainderIn: Value(remainderIn),
      calWay: Value(calWay),
      startDate: Value(startDate),
      assetId: Value(assetId),
      nextPeriod: Value(nextPeriod),
      nextPeriodDate: Value(nextPeriodDate),
      credited: credited == null && nullToAbsent
          ? const Value.absent()
          : Value(credited),
      bookId: Value(bookId),
      excludeBudget: Value(excludeBudget),
      excludeExIn: Value(excludeExIn),
      createDate: Value(createDate),
      tags: tags == null && nullToAbsent ? const Value.absent() : Value(tags),
      images: images == null && nullToAbsent
          ? const Value.absent()
          : Value(images),
      exi: exi == null && nullToAbsent ? const Value.absent() : Value(exi),
    );
  }

  factory Installment.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Installment(
      id: serializer.fromJson<int>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      catId: serializer.fromJson<int>(json['catId']),
      principalMinor: serializer.fromJson<BigInt>(json['principalMinor']),
      periods: serializer.fromJson<int>(json['periods']),
      chargeMinor: serializer.fromJson<BigInt>(json['chargeMinor']),
      chargeWay: serializer.fromJson<int>(json['chargeWay']),
      remainderIn: serializer.fromJson<int>(json['remainderIn']),
      calWay: serializer.fromJson<int>(json['calWay']),
      startDate: serializer.fromJson<int>(json['startDate']),
      assetId: serializer.fromJson<int>(json['assetId']),
      nextPeriod: serializer.fromJson<int>(json['nextPeriod']),
      nextPeriodDate: serializer.fromJson<int>(json['nextPeriodDate']),
      credited: serializer.fromJson<String?>(json['credited']),
      bookId: serializer.fromJson<int>(json['bookId']),
      excludeBudget: serializer.fromJson<bool>(json['excludeBudget']),
      excludeExIn: serializer.fromJson<bool>(json['excludeExIn']),
      createDate: serializer.fromJson<int>(json['createDate']),
      tags: serializer.fromJson<String?>(json['tags']),
      images: serializer.fromJson<String?>(json['images']),
      exi: serializer.fromJson<String?>(json['exi']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'name': serializer.toJson<String>(name),
      'catId': serializer.toJson<int>(catId),
      'principalMinor': serializer.toJson<BigInt>(principalMinor),
      'periods': serializer.toJson<int>(periods),
      'chargeMinor': serializer.toJson<BigInt>(chargeMinor),
      'chargeWay': serializer.toJson<int>(chargeWay),
      'remainderIn': serializer.toJson<int>(remainderIn),
      'calWay': serializer.toJson<int>(calWay),
      'startDate': serializer.toJson<int>(startDate),
      'assetId': serializer.toJson<int>(assetId),
      'nextPeriod': serializer.toJson<int>(nextPeriod),
      'nextPeriodDate': serializer.toJson<int>(nextPeriodDate),
      'credited': serializer.toJson<String?>(credited),
      'bookId': serializer.toJson<int>(bookId),
      'excludeBudget': serializer.toJson<bool>(excludeBudget),
      'excludeExIn': serializer.toJson<bool>(excludeExIn),
      'createDate': serializer.toJson<int>(createDate),
      'tags': serializer.toJson<String?>(tags),
      'images': serializer.toJson<String?>(images),
      'exi': serializer.toJson<String?>(exi),
    };
  }

  Installment copyWith({
    int? id,
    String? name,
    int? catId,
    BigInt? principalMinor,
    int? periods,
    BigInt? chargeMinor,
    int? chargeWay,
    int? remainderIn,
    int? calWay,
    int? startDate,
    int? assetId,
    int? nextPeriod,
    int? nextPeriodDate,
    Value<String?> credited = const Value.absent(),
    int? bookId,
    bool? excludeBudget,
    bool? excludeExIn,
    int? createDate,
    Value<String?> tags = const Value.absent(),
    Value<String?> images = const Value.absent(),
    Value<String?> exi = const Value.absent(),
  }) => Installment(
    id: id ?? this.id,
    name: name ?? this.name,
    catId: catId ?? this.catId,
    principalMinor: principalMinor ?? this.principalMinor,
    periods: periods ?? this.periods,
    chargeMinor: chargeMinor ?? this.chargeMinor,
    chargeWay: chargeWay ?? this.chargeWay,
    remainderIn: remainderIn ?? this.remainderIn,
    calWay: calWay ?? this.calWay,
    startDate: startDate ?? this.startDate,
    assetId: assetId ?? this.assetId,
    nextPeriod: nextPeriod ?? this.nextPeriod,
    nextPeriodDate: nextPeriodDate ?? this.nextPeriodDate,
    credited: credited.present ? credited.value : this.credited,
    bookId: bookId ?? this.bookId,
    excludeBudget: excludeBudget ?? this.excludeBudget,
    excludeExIn: excludeExIn ?? this.excludeExIn,
    createDate: createDate ?? this.createDate,
    tags: tags.present ? tags.value : this.tags,
    images: images.present ? images.value : this.images,
    exi: exi.present ? exi.value : this.exi,
  );
  Installment copyWithCompanion(InstallmentsCompanion data) {
    return Installment(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      catId: data.catId.present ? data.catId.value : this.catId,
      principalMinor: data.principalMinor.present
          ? data.principalMinor.value
          : this.principalMinor,
      periods: data.periods.present ? data.periods.value : this.periods,
      chargeMinor: data.chargeMinor.present
          ? data.chargeMinor.value
          : this.chargeMinor,
      chargeWay: data.chargeWay.present ? data.chargeWay.value : this.chargeWay,
      remainderIn: data.remainderIn.present
          ? data.remainderIn.value
          : this.remainderIn,
      calWay: data.calWay.present ? data.calWay.value : this.calWay,
      startDate: data.startDate.present ? data.startDate.value : this.startDate,
      assetId: data.assetId.present ? data.assetId.value : this.assetId,
      nextPeriod: data.nextPeriod.present
          ? data.nextPeriod.value
          : this.nextPeriod,
      nextPeriodDate: data.nextPeriodDate.present
          ? data.nextPeriodDate.value
          : this.nextPeriodDate,
      credited: data.credited.present ? data.credited.value : this.credited,
      bookId: data.bookId.present ? data.bookId.value : this.bookId,
      excludeBudget: data.excludeBudget.present
          ? data.excludeBudget.value
          : this.excludeBudget,
      excludeExIn: data.excludeExIn.present
          ? data.excludeExIn.value
          : this.excludeExIn,
      createDate: data.createDate.present
          ? data.createDate.value
          : this.createDate,
      tags: data.tags.present ? data.tags.value : this.tags,
      images: data.images.present ? data.images.value : this.images,
      exi: data.exi.present ? data.exi.value : this.exi,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Installment(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('catId: $catId, ')
          ..write('principalMinor: $principalMinor, ')
          ..write('periods: $periods, ')
          ..write('chargeMinor: $chargeMinor, ')
          ..write('chargeWay: $chargeWay, ')
          ..write('remainderIn: $remainderIn, ')
          ..write('calWay: $calWay, ')
          ..write('startDate: $startDate, ')
          ..write('assetId: $assetId, ')
          ..write('nextPeriod: $nextPeriod, ')
          ..write('nextPeriodDate: $nextPeriodDate, ')
          ..write('credited: $credited, ')
          ..write('bookId: $bookId, ')
          ..write('excludeBudget: $excludeBudget, ')
          ..write('excludeExIn: $excludeExIn, ')
          ..write('createDate: $createDate, ')
          ..write('tags: $tags, ')
          ..write('images: $images, ')
          ..write('exi: $exi')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    id,
    name,
    catId,
    principalMinor,
    periods,
    chargeMinor,
    chargeWay,
    remainderIn,
    calWay,
    startDate,
    assetId,
    nextPeriod,
    nextPeriodDate,
    credited,
    bookId,
    excludeBudget,
    excludeExIn,
    createDate,
    tags,
    images,
    exi,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Installment &&
          other.id == this.id &&
          other.name == this.name &&
          other.catId == this.catId &&
          other.principalMinor == this.principalMinor &&
          other.periods == this.periods &&
          other.chargeMinor == this.chargeMinor &&
          other.chargeWay == this.chargeWay &&
          other.remainderIn == this.remainderIn &&
          other.calWay == this.calWay &&
          other.startDate == this.startDate &&
          other.assetId == this.assetId &&
          other.nextPeriod == this.nextPeriod &&
          other.nextPeriodDate == this.nextPeriodDate &&
          other.credited == this.credited &&
          other.bookId == this.bookId &&
          other.excludeBudget == this.excludeBudget &&
          other.excludeExIn == this.excludeExIn &&
          other.createDate == this.createDate &&
          other.tags == this.tags &&
          other.images == this.images &&
          other.exi == this.exi);
}

class InstallmentsCompanion extends UpdateCompanion<Installment> {
  final Value<int> id;
  final Value<String> name;
  final Value<int> catId;
  final Value<BigInt> principalMinor;
  final Value<int> periods;
  final Value<BigInt> chargeMinor;
  final Value<int> chargeWay;
  final Value<int> remainderIn;
  final Value<int> calWay;
  final Value<int> startDate;
  final Value<int> assetId;
  final Value<int> nextPeriod;
  final Value<int> nextPeriodDate;
  final Value<String?> credited;
  final Value<int> bookId;
  final Value<bool> excludeBudget;
  final Value<bool> excludeExIn;
  final Value<int> createDate;
  final Value<String?> tags;
  final Value<String?> images;
  final Value<String?> exi;
  const InstallmentsCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.catId = const Value.absent(),
    this.principalMinor = const Value.absent(),
    this.periods = const Value.absent(),
    this.chargeMinor = const Value.absent(),
    this.chargeWay = const Value.absent(),
    this.remainderIn = const Value.absent(),
    this.calWay = const Value.absent(),
    this.startDate = const Value.absent(),
    this.assetId = const Value.absent(),
    this.nextPeriod = const Value.absent(),
    this.nextPeriodDate = const Value.absent(),
    this.credited = const Value.absent(),
    this.bookId = const Value.absent(),
    this.excludeBudget = const Value.absent(),
    this.excludeExIn = const Value.absent(),
    this.createDate = const Value.absent(),
    this.tags = const Value.absent(),
    this.images = const Value.absent(),
    this.exi = const Value.absent(),
  });
  InstallmentsCompanion.insert({
    this.id = const Value.absent(),
    required String name,
    this.catId = const Value.absent(),
    required BigInt principalMinor,
    required int periods,
    required BigInt chargeMinor,
    required int chargeWay,
    required int remainderIn,
    required int calWay,
    required int startDate,
    required int assetId,
    required int nextPeriod,
    required int nextPeriodDate,
    this.credited = const Value.absent(),
    required int bookId,
    this.excludeBudget = const Value.absent(),
    this.excludeExIn = const Value.absent(),
    required int createDate,
    this.tags = const Value.absent(),
    this.images = const Value.absent(),
    this.exi = const Value.absent(),
  }) : name = Value(name),
       principalMinor = Value(principalMinor),
       periods = Value(periods),
       chargeMinor = Value(chargeMinor),
       chargeWay = Value(chargeWay),
       remainderIn = Value(remainderIn),
       calWay = Value(calWay),
       startDate = Value(startDate),
       assetId = Value(assetId),
       nextPeriod = Value(nextPeriod),
       nextPeriodDate = Value(nextPeriodDate),
       bookId = Value(bookId),
       createDate = Value(createDate);
  static Insertable<Installment> custom({
    Expression<int>? id,
    Expression<String>? name,
    Expression<int>? catId,
    Expression<BigInt>? principalMinor,
    Expression<int>? periods,
    Expression<BigInt>? chargeMinor,
    Expression<int>? chargeWay,
    Expression<int>? remainderIn,
    Expression<int>? calWay,
    Expression<int>? startDate,
    Expression<int>? assetId,
    Expression<int>? nextPeriod,
    Expression<int>? nextPeriodDate,
    Expression<String>? credited,
    Expression<int>? bookId,
    Expression<bool>? excludeBudget,
    Expression<bool>? excludeExIn,
    Expression<int>? createDate,
    Expression<String>? tags,
    Expression<String>? images,
    Expression<String>? exi,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (catId != null) 'cat_id': catId,
      if (principalMinor != null) 'principal_minor': principalMinor,
      if (periods != null) 'periods': periods,
      if (chargeMinor != null) 'charge_minor': chargeMinor,
      if (chargeWay != null) 'charge_way': chargeWay,
      if (remainderIn != null) 'remainder_in': remainderIn,
      if (calWay != null) 'cal_way': calWay,
      if (startDate != null) 'start_date': startDate,
      if (assetId != null) 'asset_id': assetId,
      if (nextPeriod != null) 'next_period': nextPeriod,
      if (nextPeriodDate != null) 'next_period_date': nextPeriodDate,
      if (credited != null) 'credited': credited,
      if (bookId != null) 'book_id': bookId,
      if (excludeBudget != null) 'exclude_budget': excludeBudget,
      if (excludeExIn != null) 'exclude_ex_in': excludeExIn,
      if (createDate != null) 'create_date': createDate,
      if (tags != null) 'tags': tags,
      if (images != null) 'images': images,
      if (exi != null) 'exi': exi,
    });
  }

  InstallmentsCompanion copyWith({
    Value<int>? id,
    Value<String>? name,
    Value<int>? catId,
    Value<BigInt>? principalMinor,
    Value<int>? periods,
    Value<BigInt>? chargeMinor,
    Value<int>? chargeWay,
    Value<int>? remainderIn,
    Value<int>? calWay,
    Value<int>? startDate,
    Value<int>? assetId,
    Value<int>? nextPeriod,
    Value<int>? nextPeriodDate,
    Value<String?>? credited,
    Value<int>? bookId,
    Value<bool>? excludeBudget,
    Value<bool>? excludeExIn,
    Value<int>? createDate,
    Value<String?>? tags,
    Value<String?>? images,
    Value<String?>? exi,
  }) {
    return InstallmentsCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      catId: catId ?? this.catId,
      principalMinor: principalMinor ?? this.principalMinor,
      periods: periods ?? this.periods,
      chargeMinor: chargeMinor ?? this.chargeMinor,
      chargeWay: chargeWay ?? this.chargeWay,
      remainderIn: remainderIn ?? this.remainderIn,
      calWay: calWay ?? this.calWay,
      startDate: startDate ?? this.startDate,
      assetId: assetId ?? this.assetId,
      nextPeriod: nextPeriod ?? this.nextPeriod,
      nextPeriodDate: nextPeriodDate ?? this.nextPeriodDate,
      credited: credited ?? this.credited,
      bookId: bookId ?? this.bookId,
      excludeBudget: excludeBudget ?? this.excludeBudget,
      excludeExIn: excludeExIn ?? this.excludeExIn,
      createDate: createDate ?? this.createDate,
      tags: tags ?? this.tags,
      images: images ?? this.images,
      exi: exi ?? this.exi,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (catId.present) {
      map['cat_id'] = Variable<int>(catId.value);
    }
    if (principalMinor.present) {
      map['principal_minor'] = Variable<BigInt>(principalMinor.value);
    }
    if (periods.present) {
      map['periods'] = Variable<int>(periods.value);
    }
    if (chargeMinor.present) {
      map['charge_minor'] = Variable<BigInt>(chargeMinor.value);
    }
    if (chargeWay.present) {
      map['charge_way'] = Variable<int>(chargeWay.value);
    }
    if (remainderIn.present) {
      map['remainder_in'] = Variable<int>(remainderIn.value);
    }
    if (calWay.present) {
      map['cal_way'] = Variable<int>(calWay.value);
    }
    if (startDate.present) {
      map['start_date'] = Variable<int>(startDate.value);
    }
    if (assetId.present) {
      map['asset_id'] = Variable<int>(assetId.value);
    }
    if (nextPeriod.present) {
      map['next_period'] = Variable<int>(nextPeriod.value);
    }
    if (nextPeriodDate.present) {
      map['next_period_date'] = Variable<int>(nextPeriodDate.value);
    }
    if (credited.present) {
      map['credited'] = Variable<String>(credited.value);
    }
    if (bookId.present) {
      map['book_id'] = Variable<int>(bookId.value);
    }
    if (excludeBudget.present) {
      map['exclude_budget'] = Variable<bool>(excludeBudget.value);
    }
    if (excludeExIn.present) {
      map['exclude_ex_in'] = Variable<bool>(excludeExIn.value);
    }
    if (createDate.present) {
      map['create_date'] = Variable<int>(createDate.value);
    }
    if (tags.present) {
      map['tags'] = Variable<String>(tags.value);
    }
    if (images.present) {
      map['images'] = Variable<String>(images.value);
    }
    if (exi.present) {
      map['exi'] = Variable<String>(exi.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('InstallmentsCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('catId: $catId, ')
          ..write('principalMinor: $principalMinor, ')
          ..write('periods: $periods, ')
          ..write('chargeMinor: $chargeMinor, ')
          ..write('chargeWay: $chargeWay, ')
          ..write('remainderIn: $remainderIn, ')
          ..write('calWay: $calWay, ')
          ..write('startDate: $startDate, ')
          ..write('assetId: $assetId, ')
          ..write('nextPeriod: $nextPeriod, ')
          ..write('nextPeriodDate: $nextPeriodDate, ')
          ..write('credited: $credited, ')
          ..write('bookId: $bookId, ')
          ..write('excludeBudget: $excludeBudget, ')
          ..write('excludeExIn: $excludeExIn, ')
          ..write('createDate: $createDate, ')
          ..write('tags: $tags, ')
          ..write('images: $images, ')
          ..write('exi: $exi')
          ..write(')'))
        .toString();
  }
}

class $NotesTable extends Notes with TableInfo<$NotesTable, Note> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $NotesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _contentMeta = const VerificationMeta(
    'content',
  );
  @override
  late final GeneratedColumn<String> content = GeneratedColumn<String>(
    'content',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createTimeMeta = const VerificationMeta(
    'createTime',
  );
  @override
  late final GeneratedColumn<int> createTime = GeneratedColumn<int>(
    'create_time',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updateTimeMeta = const VerificationMeta(
    'updateTime',
  );
  @override
  late final GeneratedColumn<int> updateTime = GeneratedColumn<int>(
    'update_time',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _trashTimeMeta = const VerificationMeta(
    'trashTime',
  );
  @override
  late final GeneratedColumn<int> trashTime = GeneratedColumn<int>(
    'trash_time',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    title,
    content,
    createTime,
    updateTime,
    trashTime,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'note';
  @override
  VerificationContext validateIntegrity(
    Insertable<Note> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    }
    if (data.containsKey('content')) {
      context.handle(
        _contentMeta,
        content.isAcceptableOrUnknown(data['content']!, _contentMeta),
      );
    } else if (isInserting) {
      context.missing(_contentMeta);
    }
    if (data.containsKey('create_time')) {
      context.handle(
        _createTimeMeta,
        createTime.isAcceptableOrUnknown(data['create_time']!, _createTimeMeta),
      );
    } else if (isInserting) {
      context.missing(_createTimeMeta);
    }
    if (data.containsKey('update_time')) {
      context.handle(
        _updateTimeMeta,
        updateTime.isAcceptableOrUnknown(data['update_time']!, _updateTimeMeta),
      );
    } else if (isInserting) {
      context.missing(_updateTimeMeta);
    }
    if (data.containsKey('trash_time')) {
      context.handle(
        _trashTimeMeta,
        trashTime.isAcceptableOrUnknown(data['trash_time']!, _trashTimeMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Note map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Note(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      ),
      content: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content'],
      )!,
      createTime: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}create_time'],
      )!,
      updateTime: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}update_time'],
      )!,
      trashTime: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}trash_time'],
      )!,
    );
  }

  @override
  $NotesTable createAlias(String alias) {
    return $NotesTable(attachedDatabase, alias);
  }
}

class Note extends DataClass implements Insertable<Note> {
  final int id;
  final String? title;
  final String content;
  final int createTime;
  final int updateTime;
  final int trashTime;
  const Note({
    required this.id,
    this.title,
    required this.content,
    required this.createTime,
    required this.updateTime,
    required this.trashTime,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    if (!nullToAbsent || title != null) {
      map['title'] = Variable<String>(title);
    }
    map['content'] = Variable<String>(content);
    map['create_time'] = Variable<int>(createTime);
    map['update_time'] = Variable<int>(updateTime);
    map['trash_time'] = Variable<int>(trashTime);
    return map;
  }

  NotesCompanion toCompanion(bool nullToAbsent) {
    return NotesCompanion(
      id: Value(id),
      title: title == null && nullToAbsent
          ? const Value.absent()
          : Value(title),
      content: Value(content),
      createTime: Value(createTime),
      updateTime: Value(updateTime),
      trashTime: Value(trashTime),
    );
  }

  factory Note.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Note(
      id: serializer.fromJson<int>(json['id']),
      title: serializer.fromJson<String?>(json['title']),
      content: serializer.fromJson<String>(json['content']),
      createTime: serializer.fromJson<int>(json['createTime']),
      updateTime: serializer.fromJson<int>(json['updateTime']),
      trashTime: serializer.fromJson<int>(json['trashTime']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'title': serializer.toJson<String?>(title),
      'content': serializer.toJson<String>(content),
      'createTime': serializer.toJson<int>(createTime),
      'updateTime': serializer.toJson<int>(updateTime),
      'trashTime': serializer.toJson<int>(trashTime),
    };
  }

  Note copyWith({
    int? id,
    Value<String?> title = const Value.absent(),
    String? content,
    int? createTime,
    int? updateTime,
    int? trashTime,
  }) => Note(
    id: id ?? this.id,
    title: title.present ? title.value : this.title,
    content: content ?? this.content,
    createTime: createTime ?? this.createTime,
    updateTime: updateTime ?? this.updateTime,
    trashTime: trashTime ?? this.trashTime,
  );
  Note copyWithCompanion(NotesCompanion data) {
    return Note(
      id: data.id.present ? data.id.value : this.id,
      title: data.title.present ? data.title.value : this.title,
      content: data.content.present ? data.content.value : this.content,
      createTime: data.createTime.present
          ? data.createTime.value
          : this.createTime,
      updateTime: data.updateTime.present
          ? data.updateTime.value
          : this.updateTime,
      trashTime: data.trashTime.present ? data.trashTime.value : this.trashTime,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Note(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('content: $content, ')
          ..write('createTime: $createTime, ')
          ..write('updateTime: $updateTime, ')
          ..write('trashTime: $trashTime')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, title, content, createTime, updateTime, trashTime);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Note &&
          other.id == this.id &&
          other.title == this.title &&
          other.content == this.content &&
          other.createTime == this.createTime &&
          other.updateTime == this.updateTime &&
          other.trashTime == this.trashTime);
}

class NotesCompanion extends UpdateCompanion<Note> {
  final Value<int> id;
  final Value<String?> title;
  final Value<String> content;
  final Value<int> createTime;
  final Value<int> updateTime;
  final Value<int> trashTime;
  const NotesCompanion({
    this.id = const Value.absent(),
    this.title = const Value.absent(),
    this.content = const Value.absent(),
    this.createTime = const Value.absent(),
    this.updateTime = const Value.absent(),
    this.trashTime = const Value.absent(),
  });
  NotesCompanion.insert({
    this.id = const Value.absent(),
    this.title = const Value.absent(),
    required String content,
    required int createTime,
    required int updateTime,
    this.trashTime = const Value.absent(),
  }) : content = Value(content),
       createTime = Value(createTime),
       updateTime = Value(updateTime);
  static Insertable<Note> custom({
    Expression<int>? id,
    Expression<String>? title,
    Expression<String>? content,
    Expression<int>? createTime,
    Expression<int>? updateTime,
    Expression<int>? trashTime,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (title != null) 'title': title,
      if (content != null) 'content': content,
      if (createTime != null) 'create_time': createTime,
      if (updateTime != null) 'update_time': updateTime,
      if (trashTime != null) 'trash_time': trashTime,
    });
  }

  NotesCompanion copyWith({
    Value<int>? id,
    Value<String?>? title,
    Value<String>? content,
    Value<int>? createTime,
    Value<int>? updateTime,
    Value<int>? trashTime,
  }) {
    return NotesCompanion(
      id: id ?? this.id,
      title: title ?? this.title,
      content: content ?? this.content,
      createTime: createTime ?? this.createTime,
      updateTime: updateTime ?? this.updateTime,
      trashTime: trashTime ?? this.trashTime,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (content.present) {
      map['content'] = Variable<String>(content.value);
    }
    if (createTime.present) {
      map['create_time'] = Variable<int>(createTime.value);
    }
    if (updateTime.present) {
      map['update_time'] = Variable<int>(updateTime.value);
    }
    if (trashTime.present) {
      map['trash_time'] = Variable<int>(trashTime.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('NotesCompanion(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('content: $content, ')
          ..write('createTime: $createTime, ')
          ..write('updateTime: $updateTime, ')
          ..write('trashTime: $trashTime')
          ..write(')'))
        .toString();
  }
}

class $TagsTable extends Tags with TableInfo<$TagsTable, Tag> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TagsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _tagIdMeta = const VerificationMeta('tagId');
  @override
  late final GeneratedColumn<String> tagId = GeneratedColumn<String>(
    'tag_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sortMeta = const VerificationMeta('sort');
  @override
  late final GeneratedColumn<int> sort = GeneratedColumn<int>(
    'sort',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _hiddenMeta = const VerificationMeta('hidden');
  @override
  late final GeneratedColumn<bool> hidden = GeneratedColumn<bool>(
    'hidden',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("hidden" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _parentTagIdMeta = const VerificationMeta(
    'parentTagId',
  );
  @override
  late final GeneratedColumn<String> parentTagId = GeneratedColumn<String>(
    'parent_tag_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _parentMeta = const VerificationMeta('parent');
  @override
  late final GeneratedColumn<int> parent = GeneratedColumn<int>(
    'parent',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _colorMeta = const VerificationMeta('color');
  @override
  late final GeneratedColumn<String> color = GeneratedColumn<String>(
    'color',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _extraInfoMeta = const VerificationMeta(
    'extraInfo',
  );
  @override
  late final GeneratedColumn<String> extraInfo = GeneratedColumn<String>(
    'extra_info',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    tagId,
    name,
    sort,
    hidden,
    parentTagId,
    parent,
    color,
    extraInfo,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'tag';
  @override
  VerificationContext validateIntegrity(
    Insertable<Tag> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('tag_id')) {
      context.handle(
        _tagIdMeta,
        tagId.isAcceptableOrUnknown(data['tag_id']!, _tagIdMeta),
      );
    } else if (isInserting) {
      context.missing(_tagIdMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('sort')) {
      context.handle(
        _sortMeta,
        sort.isAcceptableOrUnknown(data['sort']!, _sortMeta),
      );
    }
    if (data.containsKey('hidden')) {
      context.handle(
        _hiddenMeta,
        hidden.isAcceptableOrUnknown(data['hidden']!, _hiddenMeta),
      );
    }
    if (data.containsKey('parent_tag_id')) {
      context.handle(
        _parentTagIdMeta,
        parentTagId.isAcceptableOrUnknown(
          data['parent_tag_id']!,
          _parentTagIdMeta,
        ),
      );
    }
    if (data.containsKey('parent')) {
      context.handle(
        _parentMeta,
        parent.isAcceptableOrUnknown(data['parent']!, _parentMeta),
      );
    }
    if (data.containsKey('color')) {
      context.handle(
        _colorMeta,
        color.isAcceptableOrUnknown(data['color']!, _colorMeta),
      );
    }
    if (data.containsKey('extra_info')) {
      context.handle(
        _extraInfoMeta,
        extraInfo.isAcceptableOrUnknown(data['extra_info']!, _extraInfoMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {tagId};
  @override
  Tag map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Tag(
      tagId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tag_id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      sort: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort'],
      )!,
      hidden: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}hidden'],
      )!,
      parentTagId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}parent_tag_id'],
      ),
      parent: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}parent'],
      )!,
      color: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}color'],
      ),
      extraInfo: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}extra_info'],
      ),
    );
  }

  @override
  $TagsTable createAlias(String alias) {
    return $TagsTable(attachedDatabase, alias);
  }
}

class Tag extends DataClass implements Insertable<Tag> {
  final String tagId;
  final String name;
  final int sort;
  final bool hidden;
  final String? parentTagId;
  final int parent;
  final String? color;
  final String? extraInfo;
  const Tag({
    required this.tagId,
    required this.name,
    required this.sort,
    required this.hidden,
    this.parentTagId,
    required this.parent,
    this.color,
    this.extraInfo,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['tag_id'] = Variable<String>(tagId);
    map['name'] = Variable<String>(name);
    map['sort'] = Variable<int>(sort);
    map['hidden'] = Variable<bool>(hidden);
    if (!nullToAbsent || parentTagId != null) {
      map['parent_tag_id'] = Variable<String>(parentTagId);
    }
    map['parent'] = Variable<int>(parent);
    if (!nullToAbsent || color != null) {
      map['color'] = Variable<String>(color);
    }
    if (!nullToAbsent || extraInfo != null) {
      map['extra_info'] = Variable<String>(extraInfo);
    }
    return map;
  }

  TagsCompanion toCompanion(bool nullToAbsent) {
    return TagsCompanion(
      tagId: Value(tagId),
      name: Value(name),
      sort: Value(sort),
      hidden: Value(hidden),
      parentTagId: parentTagId == null && nullToAbsent
          ? const Value.absent()
          : Value(parentTagId),
      parent: Value(parent),
      color: color == null && nullToAbsent
          ? const Value.absent()
          : Value(color),
      extraInfo: extraInfo == null && nullToAbsent
          ? const Value.absent()
          : Value(extraInfo),
    );
  }

  factory Tag.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Tag(
      tagId: serializer.fromJson<String>(json['tagId']),
      name: serializer.fromJson<String>(json['name']),
      sort: serializer.fromJson<int>(json['sort']),
      hidden: serializer.fromJson<bool>(json['hidden']),
      parentTagId: serializer.fromJson<String?>(json['parentTagId']),
      parent: serializer.fromJson<int>(json['parent']),
      color: serializer.fromJson<String?>(json['color']),
      extraInfo: serializer.fromJson<String?>(json['extraInfo']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'tagId': serializer.toJson<String>(tagId),
      'name': serializer.toJson<String>(name),
      'sort': serializer.toJson<int>(sort),
      'hidden': serializer.toJson<bool>(hidden),
      'parentTagId': serializer.toJson<String?>(parentTagId),
      'parent': serializer.toJson<int>(parent),
      'color': serializer.toJson<String?>(color),
      'extraInfo': serializer.toJson<String?>(extraInfo),
    };
  }

  Tag copyWith({
    String? tagId,
    String? name,
    int? sort,
    bool? hidden,
    Value<String?> parentTagId = const Value.absent(),
    int? parent,
    Value<String?> color = const Value.absent(),
    Value<String?> extraInfo = const Value.absent(),
  }) => Tag(
    tagId: tagId ?? this.tagId,
    name: name ?? this.name,
    sort: sort ?? this.sort,
    hidden: hidden ?? this.hidden,
    parentTagId: parentTagId.present ? parentTagId.value : this.parentTagId,
    parent: parent ?? this.parent,
    color: color.present ? color.value : this.color,
    extraInfo: extraInfo.present ? extraInfo.value : this.extraInfo,
  );
  Tag copyWithCompanion(TagsCompanion data) {
    return Tag(
      tagId: data.tagId.present ? data.tagId.value : this.tagId,
      name: data.name.present ? data.name.value : this.name,
      sort: data.sort.present ? data.sort.value : this.sort,
      hidden: data.hidden.present ? data.hidden.value : this.hidden,
      parentTagId: data.parentTagId.present
          ? data.parentTagId.value
          : this.parentTagId,
      parent: data.parent.present ? data.parent.value : this.parent,
      color: data.color.present ? data.color.value : this.color,
      extraInfo: data.extraInfo.present ? data.extraInfo.value : this.extraInfo,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Tag(')
          ..write('tagId: $tagId, ')
          ..write('name: $name, ')
          ..write('sort: $sort, ')
          ..write('hidden: $hidden, ')
          ..write('parentTagId: $parentTagId, ')
          ..write('parent: $parent, ')
          ..write('color: $color, ')
          ..write('extraInfo: $extraInfo')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    tagId,
    name,
    sort,
    hidden,
    parentTagId,
    parent,
    color,
    extraInfo,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Tag &&
          other.tagId == this.tagId &&
          other.name == this.name &&
          other.sort == this.sort &&
          other.hidden == this.hidden &&
          other.parentTagId == this.parentTagId &&
          other.parent == this.parent &&
          other.color == this.color &&
          other.extraInfo == this.extraInfo);
}

class TagsCompanion extends UpdateCompanion<Tag> {
  final Value<String> tagId;
  final Value<String> name;
  final Value<int> sort;
  final Value<bool> hidden;
  final Value<String?> parentTagId;
  final Value<int> parent;
  final Value<String?> color;
  final Value<String?> extraInfo;
  final Value<int> rowid;
  const TagsCompanion({
    this.tagId = const Value.absent(),
    this.name = const Value.absent(),
    this.sort = const Value.absent(),
    this.hidden = const Value.absent(),
    this.parentTagId = const Value.absent(),
    this.parent = const Value.absent(),
    this.color = const Value.absent(),
    this.extraInfo = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TagsCompanion.insert({
    required String tagId,
    required String name,
    this.sort = const Value.absent(),
    this.hidden = const Value.absent(),
    this.parentTagId = const Value.absent(),
    this.parent = const Value.absent(),
    this.color = const Value.absent(),
    this.extraInfo = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : tagId = Value(tagId),
       name = Value(name);
  static Insertable<Tag> custom({
    Expression<String>? tagId,
    Expression<String>? name,
    Expression<int>? sort,
    Expression<bool>? hidden,
    Expression<String>? parentTagId,
    Expression<int>? parent,
    Expression<String>? color,
    Expression<String>? extraInfo,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (tagId != null) 'tag_id': tagId,
      if (name != null) 'name': name,
      if (sort != null) 'sort': sort,
      if (hidden != null) 'hidden': hidden,
      if (parentTagId != null) 'parent_tag_id': parentTagId,
      if (parent != null) 'parent': parent,
      if (color != null) 'color': color,
      if (extraInfo != null) 'extra_info': extraInfo,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TagsCompanion copyWith({
    Value<String>? tagId,
    Value<String>? name,
    Value<int>? sort,
    Value<bool>? hidden,
    Value<String?>? parentTagId,
    Value<int>? parent,
    Value<String?>? color,
    Value<String?>? extraInfo,
    Value<int>? rowid,
  }) {
    return TagsCompanion(
      tagId: tagId ?? this.tagId,
      name: name ?? this.name,
      sort: sort ?? this.sort,
      hidden: hidden ?? this.hidden,
      parentTagId: parentTagId ?? this.parentTagId,
      parent: parent ?? this.parent,
      color: color ?? this.color,
      extraInfo: extraInfo ?? this.extraInfo,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (tagId.present) {
      map['tag_id'] = Variable<String>(tagId.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (sort.present) {
      map['sort'] = Variable<int>(sort.value);
    }
    if (hidden.present) {
      map['hidden'] = Variable<bool>(hidden.value);
    }
    if (parentTagId.present) {
      map['parent_tag_id'] = Variable<String>(parentTagId.value);
    }
    if (parent.present) {
      map['parent'] = Variable<int>(parent.value);
    }
    if (color.present) {
      map['color'] = Variable<String>(color.value);
    }
    if (extraInfo.present) {
      map['extra_info'] = Variable<String>(extraInfo.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TagsCompanion(')
          ..write('tagId: $tagId, ')
          ..write('name: $name, ')
          ..write('sort: $sort, ')
          ..write('hidden: $hidden, ')
          ..write('parentTagId: $parentTagId, ')
          ..write('parent: $parent, ')
          ..write('color: $color, ')
          ..write('extraInfo: $extraInfo, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $TagRecordsTable extends TagRecords
    with TableInfo<$TagRecordsTable, TagRecord> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TagRecordsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _tagIdMeta = const VerificationMeta('tagId');
  @override
  late final GeneratedColumn<String> tagId = GeneratedColumn<String>(
    'tag_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _recordIdMeta = const VerificationMeta(
    'recordId',
  );
  @override
  late final GeneratedColumn<String> recordId = GeneratedColumn<String>(
    'record_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [tagId, recordId];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'tag_record';
  @override
  VerificationContext validateIntegrity(
    Insertable<TagRecord> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('tag_id')) {
      context.handle(
        _tagIdMeta,
        tagId.isAcceptableOrUnknown(data['tag_id']!, _tagIdMeta),
      );
    } else if (isInserting) {
      context.missing(_tagIdMeta);
    }
    if (data.containsKey('record_id')) {
      context.handle(
        _recordIdMeta,
        recordId.isAcceptableOrUnknown(data['record_id']!, _recordIdMeta),
      );
    } else if (isInserting) {
      context.missing(_recordIdMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {tagId, recordId};
  @override
  TagRecord map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TagRecord(
      tagId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tag_id'],
      )!,
      recordId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}record_id'],
      )!,
    );
  }

  @override
  $TagRecordsTable createAlias(String alias) {
    return $TagRecordsTable(attachedDatabase, alias);
  }
}

class TagRecord extends DataClass implements Insertable<TagRecord> {
  final String tagId;
  final String recordId;
  const TagRecord({required this.tagId, required this.recordId});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['tag_id'] = Variable<String>(tagId);
    map['record_id'] = Variable<String>(recordId);
    return map;
  }

  TagRecordsCompanion toCompanion(bool nullToAbsent) {
    return TagRecordsCompanion(tagId: Value(tagId), recordId: Value(recordId));
  }

  factory TagRecord.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TagRecord(
      tagId: serializer.fromJson<String>(json['tagId']),
      recordId: serializer.fromJson<String>(json['recordId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'tagId': serializer.toJson<String>(tagId),
      'recordId': serializer.toJson<String>(recordId),
    };
  }

  TagRecord copyWith({String? tagId, String? recordId}) => TagRecord(
    tagId: tagId ?? this.tagId,
    recordId: recordId ?? this.recordId,
  );
  TagRecord copyWithCompanion(TagRecordsCompanion data) {
    return TagRecord(
      tagId: data.tagId.present ? data.tagId.value : this.tagId,
      recordId: data.recordId.present ? data.recordId.value : this.recordId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TagRecord(')
          ..write('tagId: $tagId, ')
          ..write('recordId: $recordId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(tagId, recordId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TagRecord &&
          other.tagId == this.tagId &&
          other.recordId == this.recordId);
}

class TagRecordsCompanion extends UpdateCompanion<TagRecord> {
  final Value<String> tagId;
  final Value<String> recordId;
  final Value<int> rowid;
  const TagRecordsCompanion({
    this.tagId = const Value.absent(),
    this.recordId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TagRecordsCompanion.insert({
    required String tagId,
    required String recordId,
    this.rowid = const Value.absent(),
  }) : tagId = Value(tagId),
       recordId = Value(recordId);
  static Insertable<TagRecord> custom({
    Expression<String>? tagId,
    Expression<String>? recordId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (tagId != null) 'tag_id': tagId,
      if (recordId != null) 'record_id': recordId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TagRecordsCompanion copyWith({
    Value<String>? tagId,
    Value<String>? recordId,
    Value<int>? rowid,
  }) {
    return TagRecordsCompanion(
      tagId: tagId ?? this.tagId,
      recordId: recordId ?? this.recordId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (tagId.present) {
      map['tag_id'] = Variable<String>(tagId.value);
    }
    if (recordId.present) {
      map['record_id'] = Variable<String>(recordId.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TagRecordsCompanion(')
          ..write('tagId: $tagId, ')
          ..write('recordId: $recordId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MoneySavePlansTable extends MoneySavePlans
    with TableInfo<$MoneySavePlansTable, MoneySavePlan> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MoneySavePlansTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _remarkMeta = const VerificationMeta('remark');
  @override
  late final GeneratedColumn<String> remark = GeneratedColumn<String>(
    'remark',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _planTypeMeta = const VerificationMeta(
    'planType',
  );
  @override
  late final GeneratedColumn<int> planType = GeneratedColumn<int>(
    'plan_type',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _cycleTypeMeta = const VerificationMeta(
    'cycleType',
  );
  @override
  late final GeneratedColumn<int> cycleType = GeneratedColumn<int>(
    'cycle_type',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _startDateMeta = const VerificationMeta(
    'startDate',
  );
  @override
  late final GeneratedColumn<int> startDate = GeneratedColumn<int>(
    'start_date',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _endDateMeta = const VerificationMeta(
    'endDate',
  );
  @override
  late final GeneratedColumn<int> endDate = GeneratedColumn<int>(
    'end_date',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _planMoneyMinorMeta = const VerificationMeta(
    'planMoneyMinor',
  );
  @override
  late final GeneratedColumn<BigInt> planMoneyMinor = GeneratedColumn<BigInt>(
    'plan_money_minor',
    aliasedName,
    false,
    type: DriftSqlType.bigInt,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _savedMoneyMinorMeta = const VerificationMeta(
    'savedMoneyMinor',
  );
  @override
  late final GeneratedColumn<BigInt> savedMoneyMinor = GeneratedColumn<BigInt>(
    'saved_money_minor',
    aliasedName,
    false,
    type: DriftSqlType.bigInt,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _autoPlanMeta = const VerificationMeta(
    'autoPlan',
  );
  @override
  late final GeneratedColumn<bool> autoPlan = GeneratedColumn<bool>(
    'auto_plan',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("auto_plan" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _fromAssetIdMeta = const VerificationMeta(
    'fromAssetId',
  );
  @override
  late final GeneratedColumn<int> fromAssetId = GeneratedColumn<int>(
    'from_asset_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(-1),
  );
  static const VerificationMeta _toAssetIdMeta = const VerificationMeta(
    'toAssetId',
  );
  @override
  late final GeneratedColumn<int> toAssetId = GeneratedColumn<int>(
    'to_asset_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(-1),
  );
  static const VerificationMeta _bookIdMeta = const VerificationMeta('bookId');
  @override
  late final GeneratedColumn<int> bookId = GeneratedColumn<int>(
    'book_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(-1),
  );
  static const VerificationMeta _startMoneyMinorMeta = const VerificationMeta(
    'startMoneyMinor',
  );
  @override
  late final GeneratedColumn<BigInt> startMoneyMinor = GeneratedColumn<BigInt>(
    'start_money_minor',
    aliasedName,
    false,
    type: DriftSqlType.bigInt,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _incrementalMinorMeta = const VerificationMeta(
    'incrementalMinor',
  );
  @override
  late final GeneratedColumn<BigInt> incrementalMinor = GeneratedColumn<BigInt>(
    'incremental_minor',
    aliasedName,
    false,
    type: DriftSqlType.bigInt,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<int> status = GeneratedColumn<int>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _createDateMeta = const VerificationMeta(
    'createDate',
  );
  @override
  late final GeneratedColumn<int> createDate = GeneratedColumn<int>(
    'create_date',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sortMeta = const VerificationMeta('sort');
  @override
  late final GeneratedColumn<int> sort = GeneratedColumn<int>(
    'sort',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _nextSaveDateMeta = const VerificationMeta(
    'nextSaveDate',
  );
  @override
  late final GeneratedColumn<int> nextSaveDate = GeneratedColumn<int>(
    'next_save_date',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _bbzDailyTimesMeta = const VerificationMeta(
    'bbzDailyTimes',
  );
  @override
  late final GeneratedColumn<int> bbzDailyTimes = GeneratedColumn<int>(
    'bbz_daily_times',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _iconMeta = const VerificationMeta('icon');
  @override
  late final GeneratedColumn<String> icon = GeneratedColumn<String>(
    'icon',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _extraInfoMeta = const VerificationMeta(
    'extraInfo',
  );
  @override
  late final GeneratedColumn<String> extraInfo = GeneratedColumn<String>(
    'extra_info',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    remark,
    planType,
    cycleType,
    startDate,
    endDate,
    planMoneyMinor,
    savedMoneyMinor,
    autoPlan,
    fromAssetId,
    toAssetId,
    bookId,
    startMoneyMinor,
    incrementalMinor,
    status,
    createDate,
    sort,
    nextSaveDate,
    bbzDailyTimes,
    icon,
    extraInfo,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'money_save_plan';
  @override
  VerificationContext validateIntegrity(
    Insertable<MoneySavePlan> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('remark')) {
      context.handle(
        _remarkMeta,
        remark.isAcceptableOrUnknown(data['remark']!, _remarkMeta),
      );
    }
    if (data.containsKey('plan_type')) {
      context.handle(
        _planTypeMeta,
        planType.isAcceptableOrUnknown(data['plan_type']!, _planTypeMeta),
      );
    } else if (isInserting) {
      context.missing(_planTypeMeta);
    }
    if (data.containsKey('cycle_type')) {
      context.handle(
        _cycleTypeMeta,
        cycleType.isAcceptableOrUnknown(data['cycle_type']!, _cycleTypeMeta),
      );
    } else if (isInserting) {
      context.missing(_cycleTypeMeta);
    }
    if (data.containsKey('start_date')) {
      context.handle(
        _startDateMeta,
        startDate.isAcceptableOrUnknown(data['start_date']!, _startDateMeta),
      );
    } else if (isInserting) {
      context.missing(_startDateMeta);
    }
    if (data.containsKey('end_date')) {
      context.handle(
        _endDateMeta,
        endDate.isAcceptableOrUnknown(data['end_date']!, _endDateMeta),
      );
    } else if (isInserting) {
      context.missing(_endDateMeta);
    }
    if (data.containsKey('plan_money_minor')) {
      context.handle(
        _planMoneyMinorMeta,
        planMoneyMinor.isAcceptableOrUnknown(
          data['plan_money_minor']!,
          _planMoneyMinorMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_planMoneyMinorMeta);
    }
    if (data.containsKey('saved_money_minor')) {
      context.handle(
        _savedMoneyMinorMeta,
        savedMoneyMinor.isAcceptableOrUnknown(
          data['saved_money_minor']!,
          _savedMoneyMinorMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_savedMoneyMinorMeta);
    }
    if (data.containsKey('auto_plan')) {
      context.handle(
        _autoPlanMeta,
        autoPlan.isAcceptableOrUnknown(data['auto_plan']!, _autoPlanMeta),
      );
    }
    if (data.containsKey('from_asset_id')) {
      context.handle(
        _fromAssetIdMeta,
        fromAssetId.isAcceptableOrUnknown(
          data['from_asset_id']!,
          _fromAssetIdMeta,
        ),
      );
    }
    if (data.containsKey('to_asset_id')) {
      context.handle(
        _toAssetIdMeta,
        toAssetId.isAcceptableOrUnknown(data['to_asset_id']!, _toAssetIdMeta),
      );
    }
    if (data.containsKey('book_id')) {
      context.handle(
        _bookIdMeta,
        bookId.isAcceptableOrUnknown(data['book_id']!, _bookIdMeta),
      );
    }
    if (data.containsKey('start_money_minor')) {
      context.handle(
        _startMoneyMinorMeta,
        startMoneyMinor.isAcceptableOrUnknown(
          data['start_money_minor']!,
          _startMoneyMinorMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_startMoneyMinorMeta);
    }
    if (data.containsKey('incremental_minor')) {
      context.handle(
        _incrementalMinorMeta,
        incrementalMinor.isAcceptableOrUnknown(
          data['incremental_minor']!,
          _incrementalMinorMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_incrementalMinorMeta);
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    }
    if (data.containsKey('create_date')) {
      context.handle(
        _createDateMeta,
        createDate.isAcceptableOrUnknown(data['create_date']!, _createDateMeta),
      );
    } else if (isInserting) {
      context.missing(_createDateMeta);
    }
    if (data.containsKey('sort')) {
      context.handle(
        _sortMeta,
        sort.isAcceptableOrUnknown(data['sort']!, _sortMeta),
      );
    }
    if (data.containsKey('next_save_date')) {
      context.handle(
        _nextSaveDateMeta,
        nextSaveDate.isAcceptableOrUnknown(
          data['next_save_date']!,
          _nextSaveDateMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_nextSaveDateMeta);
    }
    if (data.containsKey('bbz_daily_times')) {
      context.handle(
        _bbzDailyTimesMeta,
        bbzDailyTimes.isAcceptableOrUnknown(
          data['bbz_daily_times']!,
          _bbzDailyTimesMeta,
        ),
      );
    }
    if (data.containsKey('icon')) {
      context.handle(
        _iconMeta,
        icon.isAcceptableOrUnknown(data['icon']!, _iconMeta),
      );
    }
    if (data.containsKey('extra_info')) {
      context.handle(
        _extraInfoMeta,
        extraInfo.isAcceptableOrUnknown(data['extra_info']!, _extraInfoMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  MoneySavePlan map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MoneySavePlan(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      remark: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}remark'],
      )!,
      planType: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}plan_type'],
      )!,
      cycleType: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}cycle_type'],
      )!,
      startDate: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}start_date'],
      )!,
      endDate: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}end_date'],
      )!,
      planMoneyMinor: attachedDatabase.typeMapping.read(
        DriftSqlType.bigInt,
        data['${effectivePrefix}plan_money_minor'],
      )!,
      savedMoneyMinor: attachedDatabase.typeMapping.read(
        DriftSqlType.bigInt,
        data['${effectivePrefix}saved_money_minor'],
      )!,
      autoPlan: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}auto_plan'],
      )!,
      fromAssetId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}from_asset_id'],
      )!,
      toAssetId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}to_asset_id'],
      )!,
      bookId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}book_id'],
      )!,
      startMoneyMinor: attachedDatabase.typeMapping.read(
        DriftSqlType.bigInt,
        data['${effectivePrefix}start_money_minor'],
      )!,
      incrementalMinor: attachedDatabase.typeMapping.read(
        DriftSqlType.bigInt,
        data['${effectivePrefix}incremental_minor'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}status'],
      )!,
      createDate: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}create_date'],
      )!,
      sort: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort'],
      )!,
      nextSaveDate: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}next_save_date'],
      )!,
      bbzDailyTimes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}bbz_daily_times'],
      )!,
      icon: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}icon'],
      ),
      extraInfo: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}extra_info'],
      ),
    );
  }

  @override
  $MoneySavePlansTable createAlias(String alias) {
    return $MoneySavePlansTable(attachedDatabase, alias);
  }
}

class MoneySavePlan extends DataClass implements Insertable<MoneySavePlan> {
  final int id;
  final String name;
  final String remark;
  final int planType;
  final int cycleType;
  final int startDate;
  final int endDate;
  final BigInt planMoneyMinor;
  final BigInt savedMoneyMinor;
  final bool autoPlan;
  final int fromAssetId;
  final int toAssetId;
  final int bookId;
  final BigInt startMoneyMinor;
  final BigInt incrementalMinor;
  final int status;
  final int createDate;
  final int sort;
  final int nextSaveDate;
  final int bbzDailyTimes;
  final String? icon;
  final String? extraInfo;
  const MoneySavePlan({
    required this.id,
    required this.name,
    required this.remark,
    required this.planType,
    required this.cycleType,
    required this.startDate,
    required this.endDate,
    required this.planMoneyMinor,
    required this.savedMoneyMinor,
    required this.autoPlan,
    required this.fromAssetId,
    required this.toAssetId,
    required this.bookId,
    required this.startMoneyMinor,
    required this.incrementalMinor,
    required this.status,
    required this.createDate,
    required this.sort,
    required this.nextSaveDate,
    required this.bbzDailyTimes,
    this.icon,
    this.extraInfo,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['name'] = Variable<String>(name);
    map['remark'] = Variable<String>(remark);
    map['plan_type'] = Variable<int>(planType);
    map['cycle_type'] = Variable<int>(cycleType);
    map['start_date'] = Variable<int>(startDate);
    map['end_date'] = Variable<int>(endDate);
    map['plan_money_minor'] = Variable<BigInt>(planMoneyMinor);
    map['saved_money_minor'] = Variable<BigInt>(savedMoneyMinor);
    map['auto_plan'] = Variable<bool>(autoPlan);
    map['from_asset_id'] = Variable<int>(fromAssetId);
    map['to_asset_id'] = Variable<int>(toAssetId);
    map['book_id'] = Variable<int>(bookId);
    map['start_money_minor'] = Variable<BigInt>(startMoneyMinor);
    map['incremental_minor'] = Variable<BigInt>(incrementalMinor);
    map['status'] = Variable<int>(status);
    map['create_date'] = Variable<int>(createDate);
    map['sort'] = Variable<int>(sort);
    map['next_save_date'] = Variable<int>(nextSaveDate);
    map['bbz_daily_times'] = Variable<int>(bbzDailyTimes);
    if (!nullToAbsent || icon != null) {
      map['icon'] = Variable<String>(icon);
    }
    if (!nullToAbsent || extraInfo != null) {
      map['extra_info'] = Variable<String>(extraInfo);
    }
    return map;
  }

  MoneySavePlansCompanion toCompanion(bool nullToAbsent) {
    return MoneySavePlansCompanion(
      id: Value(id),
      name: Value(name),
      remark: Value(remark),
      planType: Value(planType),
      cycleType: Value(cycleType),
      startDate: Value(startDate),
      endDate: Value(endDate),
      planMoneyMinor: Value(planMoneyMinor),
      savedMoneyMinor: Value(savedMoneyMinor),
      autoPlan: Value(autoPlan),
      fromAssetId: Value(fromAssetId),
      toAssetId: Value(toAssetId),
      bookId: Value(bookId),
      startMoneyMinor: Value(startMoneyMinor),
      incrementalMinor: Value(incrementalMinor),
      status: Value(status),
      createDate: Value(createDate),
      sort: Value(sort),
      nextSaveDate: Value(nextSaveDate),
      bbzDailyTimes: Value(bbzDailyTimes),
      icon: icon == null && nullToAbsent ? const Value.absent() : Value(icon),
      extraInfo: extraInfo == null && nullToAbsent
          ? const Value.absent()
          : Value(extraInfo),
    );
  }

  factory MoneySavePlan.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MoneySavePlan(
      id: serializer.fromJson<int>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      remark: serializer.fromJson<String>(json['remark']),
      planType: serializer.fromJson<int>(json['planType']),
      cycleType: serializer.fromJson<int>(json['cycleType']),
      startDate: serializer.fromJson<int>(json['startDate']),
      endDate: serializer.fromJson<int>(json['endDate']),
      planMoneyMinor: serializer.fromJson<BigInt>(json['planMoneyMinor']),
      savedMoneyMinor: serializer.fromJson<BigInt>(json['savedMoneyMinor']),
      autoPlan: serializer.fromJson<bool>(json['autoPlan']),
      fromAssetId: serializer.fromJson<int>(json['fromAssetId']),
      toAssetId: serializer.fromJson<int>(json['toAssetId']),
      bookId: serializer.fromJson<int>(json['bookId']),
      startMoneyMinor: serializer.fromJson<BigInt>(json['startMoneyMinor']),
      incrementalMinor: serializer.fromJson<BigInt>(json['incrementalMinor']),
      status: serializer.fromJson<int>(json['status']),
      createDate: serializer.fromJson<int>(json['createDate']),
      sort: serializer.fromJson<int>(json['sort']),
      nextSaveDate: serializer.fromJson<int>(json['nextSaveDate']),
      bbzDailyTimes: serializer.fromJson<int>(json['bbzDailyTimes']),
      icon: serializer.fromJson<String?>(json['icon']),
      extraInfo: serializer.fromJson<String?>(json['extraInfo']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'name': serializer.toJson<String>(name),
      'remark': serializer.toJson<String>(remark),
      'planType': serializer.toJson<int>(planType),
      'cycleType': serializer.toJson<int>(cycleType),
      'startDate': serializer.toJson<int>(startDate),
      'endDate': serializer.toJson<int>(endDate),
      'planMoneyMinor': serializer.toJson<BigInt>(planMoneyMinor),
      'savedMoneyMinor': serializer.toJson<BigInt>(savedMoneyMinor),
      'autoPlan': serializer.toJson<bool>(autoPlan),
      'fromAssetId': serializer.toJson<int>(fromAssetId),
      'toAssetId': serializer.toJson<int>(toAssetId),
      'bookId': serializer.toJson<int>(bookId),
      'startMoneyMinor': serializer.toJson<BigInt>(startMoneyMinor),
      'incrementalMinor': serializer.toJson<BigInt>(incrementalMinor),
      'status': serializer.toJson<int>(status),
      'createDate': serializer.toJson<int>(createDate),
      'sort': serializer.toJson<int>(sort),
      'nextSaveDate': serializer.toJson<int>(nextSaveDate),
      'bbzDailyTimes': serializer.toJson<int>(bbzDailyTimes),
      'icon': serializer.toJson<String?>(icon),
      'extraInfo': serializer.toJson<String?>(extraInfo),
    };
  }

  MoneySavePlan copyWith({
    int? id,
    String? name,
    String? remark,
    int? planType,
    int? cycleType,
    int? startDate,
    int? endDate,
    BigInt? planMoneyMinor,
    BigInt? savedMoneyMinor,
    bool? autoPlan,
    int? fromAssetId,
    int? toAssetId,
    int? bookId,
    BigInt? startMoneyMinor,
    BigInt? incrementalMinor,
    int? status,
    int? createDate,
    int? sort,
    int? nextSaveDate,
    int? bbzDailyTimes,
    Value<String?> icon = const Value.absent(),
    Value<String?> extraInfo = const Value.absent(),
  }) => MoneySavePlan(
    id: id ?? this.id,
    name: name ?? this.name,
    remark: remark ?? this.remark,
    planType: planType ?? this.planType,
    cycleType: cycleType ?? this.cycleType,
    startDate: startDate ?? this.startDate,
    endDate: endDate ?? this.endDate,
    planMoneyMinor: planMoneyMinor ?? this.planMoneyMinor,
    savedMoneyMinor: savedMoneyMinor ?? this.savedMoneyMinor,
    autoPlan: autoPlan ?? this.autoPlan,
    fromAssetId: fromAssetId ?? this.fromAssetId,
    toAssetId: toAssetId ?? this.toAssetId,
    bookId: bookId ?? this.bookId,
    startMoneyMinor: startMoneyMinor ?? this.startMoneyMinor,
    incrementalMinor: incrementalMinor ?? this.incrementalMinor,
    status: status ?? this.status,
    createDate: createDate ?? this.createDate,
    sort: sort ?? this.sort,
    nextSaveDate: nextSaveDate ?? this.nextSaveDate,
    bbzDailyTimes: bbzDailyTimes ?? this.bbzDailyTimes,
    icon: icon.present ? icon.value : this.icon,
    extraInfo: extraInfo.present ? extraInfo.value : this.extraInfo,
  );
  MoneySavePlan copyWithCompanion(MoneySavePlansCompanion data) {
    return MoneySavePlan(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      remark: data.remark.present ? data.remark.value : this.remark,
      planType: data.planType.present ? data.planType.value : this.planType,
      cycleType: data.cycleType.present ? data.cycleType.value : this.cycleType,
      startDate: data.startDate.present ? data.startDate.value : this.startDate,
      endDate: data.endDate.present ? data.endDate.value : this.endDate,
      planMoneyMinor: data.planMoneyMinor.present
          ? data.planMoneyMinor.value
          : this.planMoneyMinor,
      savedMoneyMinor: data.savedMoneyMinor.present
          ? data.savedMoneyMinor.value
          : this.savedMoneyMinor,
      autoPlan: data.autoPlan.present ? data.autoPlan.value : this.autoPlan,
      fromAssetId: data.fromAssetId.present
          ? data.fromAssetId.value
          : this.fromAssetId,
      toAssetId: data.toAssetId.present ? data.toAssetId.value : this.toAssetId,
      bookId: data.bookId.present ? data.bookId.value : this.bookId,
      startMoneyMinor: data.startMoneyMinor.present
          ? data.startMoneyMinor.value
          : this.startMoneyMinor,
      incrementalMinor: data.incrementalMinor.present
          ? data.incrementalMinor.value
          : this.incrementalMinor,
      status: data.status.present ? data.status.value : this.status,
      createDate: data.createDate.present
          ? data.createDate.value
          : this.createDate,
      sort: data.sort.present ? data.sort.value : this.sort,
      nextSaveDate: data.nextSaveDate.present
          ? data.nextSaveDate.value
          : this.nextSaveDate,
      bbzDailyTimes: data.bbzDailyTimes.present
          ? data.bbzDailyTimes.value
          : this.bbzDailyTimes,
      icon: data.icon.present ? data.icon.value : this.icon,
      extraInfo: data.extraInfo.present ? data.extraInfo.value : this.extraInfo,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MoneySavePlan(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('remark: $remark, ')
          ..write('planType: $planType, ')
          ..write('cycleType: $cycleType, ')
          ..write('startDate: $startDate, ')
          ..write('endDate: $endDate, ')
          ..write('planMoneyMinor: $planMoneyMinor, ')
          ..write('savedMoneyMinor: $savedMoneyMinor, ')
          ..write('autoPlan: $autoPlan, ')
          ..write('fromAssetId: $fromAssetId, ')
          ..write('toAssetId: $toAssetId, ')
          ..write('bookId: $bookId, ')
          ..write('startMoneyMinor: $startMoneyMinor, ')
          ..write('incrementalMinor: $incrementalMinor, ')
          ..write('status: $status, ')
          ..write('createDate: $createDate, ')
          ..write('sort: $sort, ')
          ..write('nextSaveDate: $nextSaveDate, ')
          ..write('bbzDailyTimes: $bbzDailyTimes, ')
          ..write('icon: $icon, ')
          ..write('extraInfo: $extraInfo')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    id,
    name,
    remark,
    planType,
    cycleType,
    startDate,
    endDate,
    planMoneyMinor,
    savedMoneyMinor,
    autoPlan,
    fromAssetId,
    toAssetId,
    bookId,
    startMoneyMinor,
    incrementalMinor,
    status,
    createDate,
    sort,
    nextSaveDate,
    bbzDailyTimes,
    icon,
    extraInfo,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MoneySavePlan &&
          other.id == this.id &&
          other.name == this.name &&
          other.remark == this.remark &&
          other.planType == this.planType &&
          other.cycleType == this.cycleType &&
          other.startDate == this.startDate &&
          other.endDate == this.endDate &&
          other.planMoneyMinor == this.planMoneyMinor &&
          other.savedMoneyMinor == this.savedMoneyMinor &&
          other.autoPlan == this.autoPlan &&
          other.fromAssetId == this.fromAssetId &&
          other.toAssetId == this.toAssetId &&
          other.bookId == this.bookId &&
          other.startMoneyMinor == this.startMoneyMinor &&
          other.incrementalMinor == this.incrementalMinor &&
          other.status == this.status &&
          other.createDate == this.createDate &&
          other.sort == this.sort &&
          other.nextSaveDate == this.nextSaveDate &&
          other.bbzDailyTimes == this.bbzDailyTimes &&
          other.icon == this.icon &&
          other.extraInfo == this.extraInfo);
}

class MoneySavePlansCompanion extends UpdateCompanion<MoneySavePlan> {
  final Value<int> id;
  final Value<String> name;
  final Value<String> remark;
  final Value<int> planType;
  final Value<int> cycleType;
  final Value<int> startDate;
  final Value<int> endDate;
  final Value<BigInt> planMoneyMinor;
  final Value<BigInt> savedMoneyMinor;
  final Value<bool> autoPlan;
  final Value<int> fromAssetId;
  final Value<int> toAssetId;
  final Value<int> bookId;
  final Value<BigInt> startMoneyMinor;
  final Value<BigInt> incrementalMinor;
  final Value<int> status;
  final Value<int> createDate;
  final Value<int> sort;
  final Value<int> nextSaveDate;
  final Value<int> bbzDailyTimes;
  final Value<String?> icon;
  final Value<String?> extraInfo;
  const MoneySavePlansCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.remark = const Value.absent(),
    this.planType = const Value.absent(),
    this.cycleType = const Value.absent(),
    this.startDate = const Value.absent(),
    this.endDate = const Value.absent(),
    this.planMoneyMinor = const Value.absent(),
    this.savedMoneyMinor = const Value.absent(),
    this.autoPlan = const Value.absent(),
    this.fromAssetId = const Value.absent(),
    this.toAssetId = const Value.absent(),
    this.bookId = const Value.absent(),
    this.startMoneyMinor = const Value.absent(),
    this.incrementalMinor = const Value.absent(),
    this.status = const Value.absent(),
    this.createDate = const Value.absent(),
    this.sort = const Value.absent(),
    this.nextSaveDate = const Value.absent(),
    this.bbzDailyTimes = const Value.absent(),
    this.icon = const Value.absent(),
    this.extraInfo = const Value.absent(),
  });
  MoneySavePlansCompanion.insert({
    this.id = const Value.absent(),
    required String name,
    this.remark = const Value.absent(),
    required int planType,
    required int cycleType,
    required int startDate,
    required int endDate,
    required BigInt planMoneyMinor,
    required BigInt savedMoneyMinor,
    this.autoPlan = const Value.absent(),
    this.fromAssetId = const Value.absent(),
    this.toAssetId = const Value.absent(),
    this.bookId = const Value.absent(),
    required BigInt startMoneyMinor,
    required BigInt incrementalMinor,
    this.status = const Value.absent(),
    required int createDate,
    this.sort = const Value.absent(),
    required int nextSaveDate,
    this.bbzDailyTimes = const Value.absent(),
    this.icon = const Value.absent(),
    this.extraInfo = const Value.absent(),
  }) : name = Value(name),
       planType = Value(planType),
       cycleType = Value(cycleType),
       startDate = Value(startDate),
       endDate = Value(endDate),
       planMoneyMinor = Value(planMoneyMinor),
       savedMoneyMinor = Value(savedMoneyMinor),
       startMoneyMinor = Value(startMoneyMinor),
       incrementalMinor = Value(incrementalMinor),
       createDate = Value(createDate),
       nextSaveDate = Value(nextSaveDate);
  static Insertable<MoneySavePlan> custom({
    Expression<int>? id,
    Expression<String>? name,
    Expression<String>? remark,
    Expression<int>? planType,
    Expression<int>? cycleType,
    Expression<int>? startDate,
    Expression<int>? endDate,
    Expression<BigInt>? planMoneyMinor,
    Expression<BigInt>? savedMoneyMinor,
    Expression<bool>? autoPlan,
    Expression<int>? fromAssetId,
    Expression<int>? toAssetId,
    Expression<int>? bookId,
    Expression<BigInt>? startMoneyMinor,
    Expression<BigInt>? incrementalMinor,
    Expression<int>? status,
    Expression<int>? createDate,
    Expression<int>? sort,
    Expression<int>? nextSaveDate,
    Expression<int>? bbzDailyTimes,
    Expression<String>? icon,
    Expression<String>? extraInfo,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (remark != null) 'remark': remark,
      if (planType != null) 'plan_type': planType,
      if (cycleType != null) 'cycle_type': cycleType,
      if (startDate != null) 'start_date': startDate,
      if (endDate != null) 'end_date': endDate,
      if (planMoneyMinor != null) 'plan_money_minor': planMoneyMinor,
      if (savedMoneyMinor != null) 'saved_money_minor': savedMoneyMinor,
      if (autoPlan != null) 'auto_plan': autoPlan,
      if (fromAssetId != null) 'from_asset_id': fromAssetId,
      if (toAssetId != null) 'to_asset_id': toAssetId,
      if (bookId != null) 'book_id': bookId,
      if (startMoneyMinor != null) 'start_money_minor': startMoneyMinor,
      if (incrementalMinor != null) 'incremental_minor': incrementalMinor,
      if (status != null) 'status': status,
      if (createDate != null) 'create_date': createDate,
      if (sort != null) 'sort': sort,
      if (nextSaveDate != null) 'next_save_date': nextSaveDate,
      if (bbzDailyTimes != null) 'bbz_daily_times': bbzDailyTimes,
      if (icon != null) 'icon': icon,
      if (extraInfo != null) 'extra_info': extraInfo,
    });
  }

  MoneySavePlansCompanion copyWith({
    Value<int>? id,
    Value<String>? name,
    Value<String>? remark,
    Value<int>? planType,
    Value<int>? cycleType,
    Value<int>? startDate,
    Value<int>? endDate,
    Value<BigInt>? planMoneyMinor,
    Value<BigInt>? savedMoneyMinor,
    Value<bool>? autoPlan,
    Value<int>? fromAssetId,
    Value<int>? toAssetId,
    Value<int>? bookId,
    Value<BigInt>? startMoneyMinor,
    Value<BigInt>? incrementalMinor,
    Value<int>? status,
    Value<int>? createDate,
    Value<int>? sort,
    Value<int>? nextSaveDate,
    Value<int>? bbzDailyTimes,
    Value<String?>? icon,
    Value<String?>? extraInfo,
  }) {
    return MoneySavePlansCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      remark: remark ?? this.remark,
      planType: planType ?? this.planType,
      cycleType: cycleType ?? this.cycleType,
      startDate: startDate ?? this.startDate,
      endDate: endDate ?? this.endDate,
      planMoneyMinor: planMoneyMinor ?? this.planMoneyMinor,
      savedMoneyMinor: savedMoneyMinor ?? this.savedMoneyMinor,
      autoPlan: autoPlan ?? this.autoPlan,
      fromAssetId: fromAssetId ?? this.fromAssetId,
      toAssetId: toAssetId ?? this.toAssetId,
      bookId: bookId ?? this.bookId,
      startMoneyMinor: startMoneyMinor ?? this.startMoneyMinor,
      incrementalMinor: incrementalMinor ?? this.incrementalMinor,
      status: status ?? this.status,
      createDate: createDate ?? this.createDate,
      sort: sort ?? this.sort,
      nextSaveDate: nextSaveDate ?? this.nextSaveDate,
      bbzDailyTimes: bbzDailyTimes ?? this.bbzDailyTimes,
      icon: icon ?? this.icon,
      extraInfo: extraInfo ?? this.extraInfo,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (remark.present) {
      map['remark'] = Variable<String>(remark.value);
    }
    if (planType.present) {
      map['plan_type'] = Variable<int>(planType.value);
    }
    if (cycleType.present) {
      map['cycle_type'] = Variable<int>(cycleType.value);
    }
    if (startDate.present) {
      map['start_date'] = Variable<int>(startDate.value);
    }
    if (endDate.present) {
      map['end_date'] = Variable<int>(endDate.value);
    }
    if (planMoneyMinor.present) {
      map['plan_money_minor'] = Variable<BigInt>(planMoneyMinor.value);
    }
    if (savedMoneyMinor.present) {
      map['saved_money_minor'] = Variable<BigInt>(savedMoneyMinor.value);
    }
    if (autoPlan.present) {
      map['auto_plan'] = Variable<bool>(autoPlan.value);
    }
    if (fromAssetId.present) {
      map['from_asset_id'] = Variable<int>(fromAssetId.value);
    }
    if (toAssetId.present) {
      map['to_asset_id'] = Variable<int>(toAssetId.value);
    }
    if (bookId.present) {
      map['book_id'] = Variable<int>(bookId.value);
    }
    if (startMoneyMinor.present) {
      map['start_money_minor'] = Variable<BigInt>(startMoneyMinor.value);
    }
    if (incrementalMinor.present) {
      map['incremental_minor'] = Variable<BigInt>(incrementalMinor.value);
    }
    if (status.present) {
      map['status'] = Variable<int>(status.value);
    }
    if (createDate.present) {
      map['create_date'] = Variable<int>(createDate.value);
    }
    if (sort.present) {
      map['sort'] = Variable<int>(sort.value);
    }
    if (nextSaveDate.present) {
      map['next_save_date'] = Variable<int>(nextSaveDate.value);
    }
    if (bbzDailyTimes.present) {
      map['bbz_daily_times'] = Variable<int>(bbzDailyTimes.value);
    }
    if (icon.present) {
      map['icon'] = Variable<String>(icon.value);
    }
    if (extraInfo.present) {
      map['extra_info'] = Variable<String>(extraInfo.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MoneySavePlansCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('remark: $remark, ')
          ..write('planType: $planType, ')
          ..write('cycleType: $cycleType, ')
          ..write('startDate: $startDate, ')
          ..write('endDate: $endDate, ')
          ..write('planMoneyMinor: $planMoneyMinor, ')
          ..write('savedMoneyMinor: $savedMoneyMinor, ')
          ..write('autoPlan: $autoPlan, ')
          ..write('fromAssetId: $fromAssetId, ')
          ..write('toAssetId: $toAssetId, ')
          ..write('bookId: $bookId, ')
          ..write('startMoneyMinor: $startMoneyMinor, ')
          ..write('incrementalMinor: $incrementalMinor, ')
          ..write('status: $status, ')
          ..write('createDate: $createDate, ')
          ..write('sort: $sort, ')
          ..write('nextSaveDate: $nextSaveDate, ')
          ..write('bbzDailyTimes: $bbzDailyTimes, ')
          ..write('icon: $icon, ')
          ..write('extraInfo: $extraInfo')
          ..write(')'))
        .toString();
  }
}

class $MoneySavePlanRecordsTable extends MoneySavePlanRecords
    with TableInfo<$MoneySavePlanRecordsTable, MoneySavePlanRecord> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MoneySavePlanRecordsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _planIdMeta = const VerificationMeta('planId');
  @override
  late final GeneratedColumn<int> planId = GeneratedColumn<int>(
    'plan_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _remarkMeta = const VerificationMeta('remark');
  @override
  late final GeneratedColumn<String> remark = GeneratedColumn<String>(
    'remark',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _fromAssetIdMeta = const VerificationMeta(
    'fromAssetId',
  );
  @override
  late final GeneratedColumn<int> fromAssetId = GeneratedColumn<int>(
    'from_asset_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(-1),
  );
  static const VerificationMeta _toAssetIdMeta = const VerificationMeta(
    'toAssetId',
  );
  @override
  late final GeneratedColumn<int> toAssetId = GeneratedColumn<int>(
    'to_asset_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(-1),
  );
  static const VerificationMeta _recordDateMeta = const VerificationMeta(
    'recordDate',
  );
  @override
  late final GeneratedColumn<int> recordDate = GeneratedColumn<int>(
    'record_date',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _recordMoneyMinorMeta = const VerificationMeta(
    'recordMoneyMinor',
  );
  @override
  late final GeneratedColumn<BigInt> recordMoneyMinor = GeneratedColumn<BigInt>(
    'record_money_minor',
    aliasedName,
    false,
    type: DriftSqlType.bigInt,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _recordIdMeta = const VerificationMeta(
    'recordId',
  );
  @override
  late final GeneratedColumn<String> recordId = GeneratedColumn<String>(
    'record_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    planId,
    remark,
    fromAssetId,
    toAssetId,
    recordDate,
    recordMoneyMinor,
    recordId,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'money_save_plan_record';
  @override
  VerificationContext validateIntegrity(
    Insertable<MoneySavePlanRecord> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('plan_id')) {
      context.handle(
        _planIdMeta,
        planId.isAcceptableOrUnknown(data['plan_id']!, _planIdMeta),
      );
    } else if (isInserting) {
      context.missing(_planIdMeta);
    }
    if (data.containsKey('remark')) {
      context.handle(
        _remarkMeta,
        remark.isAcceptableOrUnknown(data['remark']!, _remarkMeta),
      );
    }
    if (data.containsKey('from_asset_id')) {
      context.handle(
        _fromAssetIdMeta,
        fromAssetId.isAcceptableOrUnknown(
          data['from_asset_id']!,
          _fromAssetIdMeta,
        ),
      );
    }
    if (data.containsKey('to_asset_id')) {
      context.handle(
        _toAssetIdMeta,
        toAssetId.isAcceptableOrUnknown(data['to_asset_id']!, _toAssetIdMeta),
      );
    }
    if (data.containsKey('record_date')) {
      context.handle(
        _recordDateMeta,
        recordDate.isAcceptableOrUnknown(data['record_date']!, _recordDateMeta),
      );
    } else if (isInserting) {
      context.missing(_recordDateMeta);
    }
    if (data.containsKey('record_money_minor')) {
      context.handle(
        _recordMoneyMinorMeta,
        recordMoneyMinor.isAcceptableOrUnknown(
          data['record_money_minor']!,
          _recordMoneyMinorMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_recordMoneyMinorMeta);
    }
    if (data.containsKey('record_id')) {
      context.handle(
        _recordIdMeta,
        recordId.isAcceptableOrUnknown(data['record_id']!, _recordIdMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  MoneySavePlanRecord map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MoneySavePlanRecord(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      planId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}plan_id'],
      )!,
      remark: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}remark'],
      )!,
      fromAssetId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}from_asset_id'],
      )!,
      toAssetId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}to_asset_id'],
      )!,
      recordDate: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}record_date'],
      )!,
      recordMoneyMinor: attachedDatabase.typeMapping.read(
        DriftSqlType.bigInt,
        data['${effectivePrefix}record_money_minor'],
      )!,
      recordId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}record_id'],
      ),
    );
  }

  @override
  $MoneySavePlanRecordsTable createAlias(String alias) {
    return $MoneySavePlanRecordsTable(attachedDatabase, alias);
  }
}

class MoneySavePlanRecord extends DataClass
    implements Insertable<MoneySavePlanRecord> {
  final int id;
  final int planId;
  final String remark;
  final int fromAssetId;
  final int toAssetId;
  final int recordDate;
  final BigInt recordMoneyMinor;
  final String? recordId;
  const MoneySavePlanRecord({
    required this.id,
    required this.planId,
    required this.remark,
    required this.fromAssetId,
    required this.toAssetId,
    required this.recordDate,
    required this.recordMoneyMinor,
    this.recordId,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['plan_id'] = Variable<int>(planId);
    map['remark'] = Variable<String>(remark);
    map['from_asset_id'] = Variable<int>(fromAssetId);
    map['to_asset_id'] = Variable<int>(toAssetId);
    map['record_date'] = Variable<int>(recordDate);
    map['record_money_minor'] = Variable<BigInt>(recordMoneyMinor);
    if (!nullToAbsent || recordId != null) {
      map['record_id'] = Variable<String>(recordId);
    }
    return map;
  }

  MoneySavePlanRecordsCompanion toCompanion(bool nullToAbsent) {
    return MoneySavePlanRecordsCompanion(
      id: Value(id),
      planId: Value(planId),
      remark: Value(remark),
      fromAssetId: Value(fromAssetId),
      toAssetId: Value(toAssetId),
      recordDate: Value(recordDate),
      recordMoneyMinor: Value(recordMoneyMinor),
      recordId: recordId == null && nullToAbsent
          ? const Value.absent()
          : Value(recordId),
    );
  }

  factory MoneySavePlanRecord.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MoneySavePlanRecord(
      id: serializer.fromJson<int>(json['id']),
      planId: serializer.fromJson<int>(json['planId']),
      remark: serializer.fromJson<String>(json['remark']),
      fromAssetId: serializer.fromJson<int>(json['fromAssetId']),
      toAssetId: serializer.fromJson<int>(json['toAssetId']),
      recordDate: serializer.fromJson<int>(json['recordDate']),
      recordMoneyMinor: serializer.fromJson<BigInt>(json['recordMoneyMinor']),
      recordId: serializer.fromJson<String?>(json['recordId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'planId': serializer.toJson<int>(planId),
      'remark': serializer.toJson<String>(remark),
      'fromAssetId': serializer.toJson<int>(fromAssetId),
      'toAssetId': serializer.toJson<int>(toAssetId),
      'recordDate': serializer.toJson<int>(recordDate),
      'recordMoneyMinor': serializer.toJson<BigInt>(recordMoneyMinor),
      'recordId': serializer.toJson<String?>(recordId),
    };
  }

  MoneySavePlanRecord copyWith({
    int? id,
    int? planId,
    String? remark,
    int? fromAssetId,
    int? toAssetId,
    int? recordDate,
    BigInt? recordMoneyMinor,
    Value<String?> recordId = const Value.absent(),
  }) => MoneySavePlanRecord(
    id: id ?? this.id,
    planId: planId ?? this.planId,
    remark: remark ?? this.remark,
    fromAssetId: fromAssetId ?? this.fromAssetId,
    toAssetId: toAssetId ?? this.toAssetId,
    recordDate: recordDate ?? this.recordDate,
    recordMoneyMinor: recordMoneyMinor ?? this.recordMoneyMinor,
    recordId: recordId.present ? recordId.value : this.recordId,
  );
  MoneySavePlanRecord copyWithCompanion(MoneySavePlanRecordsCompanion data) {
    return MoneySavePlanRecord(
      id: data.id.present ? data.id.value : this.id,
      planId: data.planId.present ? data.planId.value : this.planId,
      remark: data.remark.present ? data.remark.value : this.remark,
      fromAssetId: data.fromAssetId.present
          ? data.fromAssetId.value
          : this.fromAssetId,
      toAssetId: data.toAssetId.present ? data.toAssetId.value : this.toAssetId,
      recordDate: data.recordDate.present
          ? data.recordDate.value
          : this.recordDate,
      recordMoneyMinor: data.recordMoneyMinor.present
          ? data.recordMoneyMinor.value
          : this.recordMoneyMinor,
      recordId: data.recordId.present ? data.recordId.value : this.recordId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MoneySavePlanRecord(')
          ..write('id: $id, ')
          ..write('planId: $planId, ')
          ..write('remark: $remark, ')
          ..write('fromAssetId: $fromAssetId, ')
          ..write('toAssetId: $toAssetId, ')
          ..write('recordDate: $recordDate, ')
          ..write('recordMoneyMinor: $recordMoneyMinor, ')
          ..write('recordId: $recordId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    planId,
    remark,
    fromAssetId,
    toAssetId,
    recordDate,
    recordMoneyMinor,
    recordId,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MoneySavePlanRecord &&
          other.id == this.id &&
          other.planId == this.planId &&
          other.remark == this.remark &&
          other.fromAssetId == this.fromAssetId &&
          other.toAssetId == this.toAssetId &&
          other.recordDate == this.recordDate &&
          other.recordMoneyMinor == this.recordMoneyMinor &&
          other.recordId == this.recordId);
}

class MoneySavePlanRecordsCompanion
    extends UpdateCompanion<MoneySavePlanRecord> {
  final Value<int> id;
  final Value<int> planId;
  final Value<String> remark;
  final Value<int> fromAssetId;
  final Value<int> toAssetId;
  final Value<int> recordDate;
  final Value<BigInt> recordMoneyMinor;
  final Value<String?> recordId;
  const MoneySavePlanRecordsCompanion({
    this.id = const Value.absent(),
    this.planId = const Value.absent(),
    this.remark = const Value.absent(),
    this.fromAssetId = const Value.absent(),
    this.toAssetId = const Value.absent(),
    this.recordDate = const Value.absent(),
    this.recordMoneyMinor = const Value.absent(),
    this.recordId = const Value.absent(),
  });
  MoneySavePlanRecordsCompanion.insert({
    this.id = const Value.absent(),
    required int planId,
    this.remark = const Value.absent(),
    this.fromAssetId = const Value.absent(),
    this.toAssetId = const Value.absent(),
    required int recordDate,
    required BigInt recordMoneyMinor,
    this.recordId = const Value.absent(),
  }) : planId = Value(planId),
       recordDate = Value(recordDate),
       recordMoneyMinor = Value(recordMoneyMinor);
  static Insertable<MoneySavePlanRecord> custom({
    Expression<int>? id,
    Expression<int>? planId,
    Expression<String>? remark,
    Expression<int>? fromAssetId,
    Expression<int>? toAssetId,
    Expression<int>? recordDate,
    Expression<BigInt>? recordMoneyMinor,
    Expression<String>? recordId,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (planId != null) 'plan_id': planId,
      if (remark != null) 'remark': remark,
      if (fromAssetId != null) 'from_asset_id': fromAssetId,
      if (toAssetId != null) 'to_asset_id': toAssetId,
      if (recordDate != null) 'record_date': recordDate,
      if (recordMoneyMinor != null) 'record_money_minor': recordMoneyMinor,
      if (recordId != null) 'record_id': recordId,
    });
  }

  MoneySavePlanRecordsCompanion copyWith({
    Value<int>? id,
    Value<int>? planId,
    Value<String>? remark,
    Value<int>? fromAssetId,
    Value<int>? toAssetId,
    Value<int>? recordDate,
    Value<BigInt>? recordMoneyMinor,
    Value<String?>? recordId,
  }) {
    return MoneySavePlanRecordsCompanion(
      id: id ?? this.id,
      planId: planId ?? this.planId,
      remark: remark ?? this.remark,
      fromAssetId: fromAssetId ?? this.fromAssetId,
      toAssetId: toAssetId ?? this.toAssetId,
      recordDate: recordDate ?? this.recordDate,
      recordMoneyMinor: recordMoneyMinor ?? this.recordMoneyMinor,
      recordId: recordId ?? this.recordId,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (planId.present) {
      map['plan_id'] = Variable<int>(planId.value);
    }
    if (remark.present) {
      map['remark'] = Variable<String>(remark.value);
    }
    if (fromAssetId.present) {
      map['from_asset_id'] = Variable<int>(fromAssetId.value);
    }
    if (toAssetId.present) {
      map['to_asset_id'] = Variable<int>(toAssetId.value);
    }
    if (recordDate.present) {
      map['record_date'] = Variable<int>(recordDate.value);
    }
    if (recordMoneyMinor.present) {
      map['record_money_minor'] = Variable<BigInt>(recordMoneyMinor.value);
    }
    if (recordId.present) {
      map['record_id'] = Variable<String>(recordId.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MoneySavePlanRecordsCompanion(')
          ..write('id: $id, ')
          ..write('planId: $planId, ')
          ..write('remark: $remark, ')
          ..write('fromAssetId: $fromAssetId, ')
          ..write('toAssetId: $toAssetId, ')
          ..write('recordDate: $recordDate, ')
          ..write('recordMoneyMinor: $recordMoneyMinor, ')
          ..write('recordId: $recordId')
          ..write(')'))
        .toString();
  }
}

class $AssetBooksTable extends AssetBooks
    with TableInfo<$AssetBooksTable, AssetBook> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AssetBooksTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _assetIdMeta = const VerificationMeta(
    'assetId',
  );
  @override
  late final GeneratedColumn<int> assetId = GeneratedColumn<int>(
    'asset_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _bookIdMeta = const VerificationMeta('bookId');
  @override
  late final GeneratedColumn<int> bookId = GeneratedColumn<int>(
    'book_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [assetId, bookId];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'asset_book';
  @override
  VerificationContext validateIntegrity(
    Insertable<AssetBook> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('asset_id')) {
      context.handle(
        _assetIdMeta,
        assetId.isAcceptableOrUnknown(data['asset_id']!, _assetIdMeta),
      );
    } else if (isInserting) {
      context.missing(_assetIdMeta);
    }
    if (data.containsKey('book_id')) {
      context.handle(
        _bookIdMeta,
        bookId.isAcceptableOrUnknown(data['book_id']!, _bookIdMeta),
      );
    } else if (isInserting) {
      context.missing(_bookIdMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {assetId, bookId};
  @override
  AssetBook map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AssetBook(
      assetId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}asset_id'],
      )!,
      bookId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}book_id'],
      )!,
    );
  }

  @override
  $AssetBooksTable createAlias(String alias) {
    return $AssetBooksTable(attachedDatabase, alias);
  }
}

class AssetBook extends DataClass implements Insertable<AssetBook> {
  final int assetId;
  final int bookId;
  const AssetBook({required this.assetId, required this.bookId});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['asset_id'] = Variable<int>(assetId);
    map['book_id'] = Variable<int>(bookId);
    return map;
  }

  AssetBooksCompanion toCompanion(bool nullToAbsent) {
    return AssetBooksCompanion(assetId: Value(assetId), bookId: Value(bookId));
  }

  factory AssetBook.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AssetBook(
      assetId: serializer.fromJson<int>(json['assetId']),
      bookId: serializer.fromJson<int>(json['bookId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'assetId': serializer.toJson<int>(assetId),
      'bookId': serializer.toJson<int>(bookId),
    };
  }

  AssetBook copyWith({int? assetId, int? bookId}) => AssetBook(
    assetId: assetId ?? this.assetId,
    bookId: bookId ?? this.bookId,
  );
  AssetBook copyWithCompanion(AssetBooksCompanion data) {
    return AssetBook(
      assetId: data.assetId.present ? data.assetId.value : this.assetId,
      bookId: data.bookId.present ? data.bookId.value : this.bookId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AssetBook(')
          ..write('assetId: $assetId, ')
          ..write('bookId: $bookId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(assetId, bookId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AssetBook &&
          other.assetId == this.assetId &&
          other.bookId == this.bookId);
}

class AssetBooksCompanion extends UpdateCompanion<AssetBook> {
  final Value<int> assetId;
  final Value<int> bookId;
  final Value<int> rowid;
  const AssetBooksCompanion({
    this.assetId = const Value.absent(),
    this.bookId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AssetBooksCompanion.insert({
    required int assetId,
    required int bookId,
    this.rowid = const Value.absent(),
  }) : assetId = Value(assetId),
       bookId = Value(bookId);
  static Insertable<AssetBook> custom({
    Expression<int>? assetId,
    Expression<int>? bookId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (assetId != null) 'asset_id': assetId,
      if (bookId != null) 'book_id': bookId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AssetBooksCompanion copyWith({
    Value<int>? assetId,
    Value<int>? bookId,
    Value<int>? rowid,
  }) {
    return AssetBooksCompanion(
      assetId: assetId ?? this.assetId,
      bookId: bookId ?? this.bookId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (assetId.present) {
      map['asset_id'] = Variable<int>(assetId.value);
    }
    if (bookId.present) {
      map['book_id'] = Variable<int>(bookId.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AssetBooksCompanion(')
          ..write('assetId: $assetId, ')
          ..write('bookId: $bookId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $StatStoriesTable extends StatStories
    with TableInfo<$StatStoriesTable, StatStory> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $StatStoriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _storyMeta = const VerificationMeta('story');
  @override
  late final GeneratedColumn<String> story = GeneratedColumn<String>(
    'story',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _bookIdMeta = const VerificationMeta('bookId');
  @override
  late final GeneratedColumn<int> bookId = GeneratedColumn<int>(
    'book_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sdateMeta = const VerificationMeta('sdate');
  @override
  late final GeneratedColumn<int> sdate = GeneratedColumn<int>(
    'sdate',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _edateMeta = const VerificationMeta('edate');
  @override
  late final GeneratedColumn<int> edate = GeneratedColumn<int>(
    'edate',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _dsectionMeta = const VerificationMeta(
    'dsection',
  );
  @override
  late final GeneratedColumn<String> dsection = GeneratedColumn<String>(
    'dsection',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    story,
    bookId,
    sdate,
    edate,
    dsection,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'stat_story';
  @override
  VerificationContext validateIntegrity(
    Insertable<StatStory> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('story')) {
      context.handle(
        _storyMeta,
        story.isAcceptableOrUnknown(data['story']!, _storyMeta),
      );
    } else if (isInserting) {
      context.missing(_storyMeta);
    }
    if (data.containsKey('book_id')) {
      context.handle(
        _bookIdMeta,
        bookId.isAcceptableOrUnknown(data['book_id']!, _bookIdMeta),
      );
    } else if (isInserting) {
      context.missing(_bookIdMeta);
    }
    if (data.containsKey('sdate')) {
      context.handle(
        _sdateMeta,
        sdate.isAcceptableOrUnknown(data['sdate']!, _sdateMeta),
      );
    } else if (isInserting) {
      context.missing(_sdateMeta);
    }
    if (data.containsKey('edate')) {
      context.handle(
        _edateMeta,
        edate.isAcceptableOrUnknown(data['edate']!, _edateMeta),
      );
    } else if (isInserting) {
      context.missing(_edateMeta);
    }
    if (data.containsKey('dsection')) {
      context.handle(
        _dsectionMeta,
        dsection.isAcceptableOrUnknown(data['dsection']!, _dsectionMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  StatStory map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StatStory(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      story: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}story'],
      )!,
      bookId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}book_id'],
      )!,
      sdate: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sdate'],
      )!,
      edate: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}edate'],
      )!,
      dsection: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}dsection'],
      ),
    );
  }

  @override
  $StatStoriesTable createAlias(String alias) {
    return $StatStoriesTable(attachedDatabase, alias);
  }
}

class StatStory extends DataClass implements Insertable<StatStory> {
  final String id;
  final String story;
  final int bookId;
  final int sdate;
  final int edate;
  final String? dsection;
  const StatStory({
    required this.id,
    required this.story,
    required this.bookId,
    required this.sdate,
    required this.edate,
    this.dsection,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['story'] = Variable<String>(story);
    map['book_id'] = Variable<int>(bookId);
    map['sdate'] = Variable<int>(sdate);
    map['edate'] = Variable<int>(edate);
    if (!nullToAbsent || dsection != null) {
      map['dsection'] = Variable<String>(dsection);
    }
    return map;
  }

  StatStoriesCompanion toCompanion(bool nullToAbsent) {
    return StatStoriesCompanion(
      id: Value(id),
      story: Value(story),
      bookId: Value(bookId),
      sdate: Value(sdate),
      edate: Value(edate),
      dsection: dsection == null && nullToAbsent
          ? const Value.absent()
          : Value(dsection),
    );
  }

  factory StatStory.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StatStory(
      id: serializer.fromJson<String>(json['id']),
      story: serializer.fromJson<String>(json['story']),
      bookId: serializer.fromJson<int>(json['bookId']),
      sdate: serializer.fromJson<int>(json['sdate']),
      edate: serializer.fromJson<int>(json['edate']),
      dsection: serializer.fromJson<String?>(json['dsection']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'story': serializer.toJson<String>(story),
      'bookId': serializer.toJson<int>(bookId),
      'sdate': serializer.toJson<int>(sdate),
      'edate': serializer.toJson<int>(edate),
      'dsection': serializer.toJson<String?>(dsection),
    };
  }

  StatStory copyWith({
    String? id,
    String? story,
    int? bookId,
    int? sdate,
    int? edate,
    Value<String?> dsection = const Value.absent(),
  }) => StatStory(
    id: id ?? this.id,
    story: story ?? this.story,
    bookId: bookId ?? this.bookId,
    sdate: sdate ?? this.sdate,
    edate: edate ?? this.edate,
    dsection: dsection.present ? dsection.value : this.dsection,
  );
  StatStory copyWithCompanion(StatStoriesCompanion data) {
    return StatStory(
      id: data.id.present ? data.id.value : this.id,
      story: data.story.present ? data.story.value : this.story,
      bookId: data.bookId.present ? data.bookId.value : this.bookId,
      sdate: data.sdate.present ? data.sdate.value : this.sdate,
      edate: data.edate.present ? data.edate.value : this.edate,
      dsection: data.dsection.present ? data.dsection.value : this.dsection,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StatStory(')
          ..write('id: $id, ')
          ..write('story: $story, ')
          ..write('bookId: $bookId, ')
          ..write('sdate: $sdate, ')
          ..write('edate: $edate, ')
          ..write('dsection: $dsection')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, story, bookId, sdate, edate, dsection);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StatStory &&
          other.id == this.id &&
          other.story == this.story &&
          other.bookId == this.bookId &&
          other.sdate == this.sdate &&
          other.edate == this.edate &&
          other.dsection == this.dsection);
}

class StatStoriesCompanion extends UpdateCompanion<StatStory> {
  final Value<String> id;
  final Value<String> story;
  final Value<int> bookId;
  final Value<int> sdate;
  final Value<int> edate;
  final Value<String?> dsection;
  final Value<int> rowid;
  const StatStoriesCompanion({
    this.id = const Value.absent(),
    this.story = const Value.absent(),
    this.bookId = const Value.absent(),
    this.sdate = const Value.absent(),
    this.edate = const Value.absent(),
    this.dsection = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  StatStoriesCompanion.insert({
    required String id,
    required String story,
    required int bookId,
    required int sdate,
    required int edate,
    this.dsection = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       story = Value(story),
       bookId = Value(bookId),
       sdate = Value(sdate),
       edate = Value(edate);
  static Insertable<StatStory> custom({
    Expression<String>? id,
    Expression<String>? story,
    Expression<int>? bookId,
    Expression<int>? sdate,
    Expression<int>? edate,
    Expression<String>? dsection,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (story != null) 'story': story,
      if (bookId != null) 'book_id': bookId,
      if (sdate != null) 'sdate': sdate,
      if (edate != null) 'edate': edate,
      if (dsection != null) 'dsection': dsection,
      if (rowid != null) 'rowid': rowid,
    });
  }

  StatStoriesCompanion copyWith({
    Value<String>? id,
    Value<String>? story,
    Value<int>? bookId,
    Value<int>? sdate,
    Value<int>? edate,
    Value<String?>? dsection,
    Value<int>? rowid,
  }) {
    return StatStoriesCompanion(
      id: id ?? this.id,
      story: story ?? this.story,
      bookId: bookId ?? this.bookId,
      sdate: sdate ?? this.sdate,
      edate: edate ?? this.edate,
      dsection: dsection ?? this.dsection,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (story.present) {
      map['story'] = Variable<String>(story.value);
    }
    if (bookId.present) {
      map['book_id'] = Variable<int>(bookId.value);
    }
    if (sdate.present) {
      map['sdate'] = Variable<int>(sdate.value);
    }
    if (edate.present) {
      map['edate'] = Variable<int>(edate.value);
    }
    if (dsection.present) {
      map['dsection'] = Variable<String>(dsection.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('StatStoriesCompanion(')
          ..write('id: $id, ')
          ..write('story: $story, ')
          ..write('bookId: $bookId, ')
          ..write('sdate: $sdate, ')
          ..write('edate: $edate, ')
          ..write('dsection: $dsection, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AutoMapsTable extends AutoMaps with TableInfo<$AutoMapsTable, AutoMap> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AutoMapsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _mapInfoMeta = const VerificationMeta(
    'mapInfo',
  );
  @override
  late final GeneratedColumn<String> mapInfo = GeneratedColumn<String>(
    'map_info',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _draftMeta = const VerificationMeta('draft');
  @override
  late final GeneratedColumn<String> draft = GeneratedColumn<String>(
    'draft',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [id, key, mapInfo, draft];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'auto_map';
  @override
  VerificationContext validateIntegrity(
    Insertable<AutoMap> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('map_info')) {
      context.handle(
        _mapInfoMeta,
        mapInfo.isAcceptableOrUnknown(data['map_info']!, _mapInfoMeta),
      );
    }
    if (data.containsKey('draft')) {
      context.handle(
        _draftMeta,
        draft.isAcceptableOrUnknown(data['draft']!, _draftMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  AutoMap map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AutoMap(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      mapInfo: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}map_info'],
      ),
      draft: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}draft'],
      ),
    );
  }

  @override
  $AutoMapsTable createAlias(String alias) {
    return $AutoMapsTable(attachedDatabase, alias);
  }
}

class AutoMap extends DataClass implements Insertable<AutoMap> {
  final int id;
  final String key;
  final String? mapInfo;
  final String? draft;
  const AutoMap({
    required this.id,
    required this.key,
    this.mapInfo,
    this.draft,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['key'] = Variable<String>(key);
    if (!nullToAbsent || mapInfo != null) {
      map['map_info'] = Variable<String>(mapInfo);
    }
    if (!nullToAbsent || draft != null) {
      map['draft'] = Variable<String>(draft);
    }
    return map;
  }

  AutoMapsCompanion toCompanion(bool nullToAbsent) {
    return AutoMapsCompanion(
      id: Value(id),
      key: Value(key),
      mapInfo: mapInfo == null && nullToAbsent
          ? const Value.absent()
          : Value(mapInfo),
      draft: draft == null && nullToAbsent
          ? const Value.absent()
          : Value(draft),
    );
  }

  factory AutoMap.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AutoMap(
      id: serializer.fromJson<int>(json['id']),
      key: serializer.fromJson<String>(json['key']),
      mapInfo: serializer.fromJson<String?>(json['mapInfo']),
      draft: serializer.fromJson<String?>(json['draft']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'key': serializer.toJson<String>(key),
      'mapInfo': serializer.toJson<String?>(mapInfo),
      'draft': serializer.toJson<String?>(draft),
    };
  }

  AutoMap copyWith({
    int? id,
    String? key,
    Value<String?> mapInfo = const Value.absent(),
    Value<String?> draft = const Value.absent(),
  }) => AutoMap(
    id: id ?? this.id,
    key: key ?? this.key,
    mapInfo: mapInfo.present ? mapInfo.value : this.mapInfo,
    draft: draft.present ? draft.value : this.draft,
  );
  AutoMap copyWithCompanion(AutoMapsCompanion data) {
    return AutoMap(
      id: data.id.present ? data.id.value : this.id,
      key: data.key.present ? data.key.value : this.key,
      mapInfo: data.mapInfo.present ? data.mapInfo.value : this.mapInfo,
      draft: data.draft.present ? data.draft.value : this.draft,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AutoMap(')
          ..write('id: $id, ')
          ..write('key: $key, ')
          ..write('mapInfo: $mapInfo, ')
          ..write('draft: $draft')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, key, mapInfo, draft);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AutoMap &&
          other.id == this.id &&
          other.key == this.key &&
          other.mapInfo == this.mapInfo &&
          other.draft == this.draft);
}

class AutoMapsCompanion extends UpdateCompanion<AutoMap> {
  final Value<int> id;
  final Value<String> key;
  final Value<String?> mapInfo;
  final Value<String?> draft;
  const AutoMapsCompanion({
    this.id = const Value.absent(),
    this.key = const Value.absent(),
    this.mapInfo = const Value.absent(),
    this.draft = const Value.absent(),
  });
  AutoMapsCompanion.insert({
    this.id = const Value.absent(),
    required String key,
    this.mapInfo = const Value.absent(),
    this.draft = const Value.absent(),
  }) : key = Value(key);
  static Insertable<AutoMap> custom({
    Expression<int>? id,
    Expression<String>? key,
    Expression<String>? mapInfo,
    Expression<String>? draft,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (key != null) 'key': key,
      if (mapInfo != null) 'map_info': mapInfo,
      if (draft != null) 'draft': draft,
    });
  }

  AutoMapsCompanion copyWith({
    Value<int>? id,
    Value<String>? key,
    Value<String?>? mapInfo,
    Value<String?>? draft,
  }) {
    return AutoMapsCompanion(
      id: id ?? this.id,
      key: key ?? this.key,
      mapInfo: mapInfo ?? this.mapInfo,
      draft: draft ?? this.draft,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (mapInfo.present) {
      map['map_info'] = Variable<String>(mapInfo.value);
    }
    if (draft.present) {
      map['draft'] = Variable<String>(draft.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AutoMapsCompanion(')
          ..write('id: $id, ')
          ..write('key: $key, ')
          ..write('mapInfo: $mapInfo, ')
          ..write('draft: $draft')
          ..write(')'))
        .toString();
  }
}

class $CurrenciesTable extends Currencies
    with TableInfo<$CurrenciesTable, Currency> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CurrenciesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _codeMeta = const VerificationMeta('code');
  @override
  late final GeneratedColumn<String> code = GeneratedColumn<String>(
    'code',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _symbolMeta = const VerificationMeta('symbol');
  @override
  late final GeneratedColumn<String> symbol = GeneratedColumn<String>(
    'symbol',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<int> type = GeneratedColumn<int>(
    'type',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _rateToAnchorMeta = const VerificationMeta(
    'rateToAnchor',
  );
  @override
  late final GeneratedColumn<String> rateToAnchor = GeneratedColumn<String>(
    'rate_to_anchor',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _anchorCodeMeta = const VerificationMeta(
    'anchorCode',
  );
  @override
  late final GeneratedColumn<String> anchorCode = GeneratedColumn<String>(
    'anchor_code',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _rateRefreshTimeMeta = const VerificationMeta(
    'rateRefreshTime',
  );
  @override
  late final GeneratedColumn<int> rateRefreshTime = GeneratedColumn<int>(
    'rate_refresh_time',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _iconMeta = const VerificationMeta('icon');
  @override
  late final GeneratedColumn<String> icon = GeneratedColumn<String>(
    'icon',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _enableMeta = const VerificationMeta('enable');
  @override
  late final GeneratedColumn<bool> enable = GeneratedColumn<bool>(
    'enable',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("enable" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  @override
  List<GeneratedColumn> get $columns => [
    code,
    name,
    symbol,
    type,
    rateToAnchor,
    anchorCode,
    rateRefreshTime,
    icon,
    enable,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'currency';
  @override
  VerificationContext validateIntegrity(
    Insertable<Currency> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('code')) {
      context.handle(
        _codeMeta,
        code.isAcceptableOrUnknown(data['code']!, _codeMeta),
      );
    } else if (isInserting) {
      context.missing(_codeMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('symbol')) {
      context.handle(
        _symbolMeta,
        symbol.isAcceptableOrUnknown(data['symbol']!, _symbolMeta),
      );
    } else if (isInserting) {
      context.missing(_symbolMeta);
    }
    if (data.containsKey('type')) {
      context.handle(
        _typeMeta,
        type.isAcceptableOrUnknown(data['type']!, _typeMeta),
      );
    }
    if (data.containsKey('rate_to_anchor')) {
      context.handle(
        _rateToAnchorMeta,
        rateToAnchor.isAcceptableOrUnknown(
          data['rate_to_anchor']!,
          _rateToAnchorMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_rateToAnchorMeta);
    }
    if (data.containsKey('anchor_code')) {
      context.handle(
        _anchorCodeMeta,
        anchorCode.isAcceptableOrUnknown(data['anchor_code']!, _anchorCodeMeta),
      );
    } else if (isInserting) {
      context.missing(_anchorCodeMeta);
    }
    if (data.containsKey('rate_refresh_time')) {
      context.handle(
        _rateRefreshTimeMeta,
        rateRefreshTime.isAcceptableOrUnknown(
          data['rate_refresh_time']!,
          _rateRefreshTimeMeta,
        ),
      );
    }
    if (data.containsKey('icon')) {
      context.handle(
        _iconMeta,
        icon.isAcceptableOrUnknown(data['icon']!, _iconMeta),
      );
    }
    if (data.containsKey('enable')) {
      context.handle(
        _enableMeta,
        enable.isAcceptableOrUnknown(data['enable']!, _enableMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {code};
  @override
  Currency map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Currency(
      code: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}code'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      symbol: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}symbol'],
      )!,
      type: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}type'],
      )!,
      rateToAnchor: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}rate_to_anchor'],
      )!,
      anchorCode: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}anchor_code'],
      )!,
      rateRefreshTime: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}rate_refresh_time'],
      )!,
      icon: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}icon'],
      ),
      enable: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}enable'],
      )!,
    );
  }

  @override
  $CurrenciesTable createAlias(String alias) {
    return $CurrenciesTable(attachedDatabase, alias);
  }
}

class Currency extends DataClass implements Insertable<Currency> {
  final String code;
  final String name;
  final String symbol;
  final int type;

  /// Decimal string, never REAL (ADR-011).
  final String rateToAnchor;
  final String anchorCode;
  final int rateRefreshTime;
  final String? icon;
  final bool enable;
  const Currency({
    required this.code,
    required this.name,
    required this.symbol,
    required this.type,
    required this.rateToAnchor,
    required this.anchorCode,
    required this.rateRefreshTime,
    this.icon,
    required this.enable,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['code'] = Variable<String>(code);
    map['name'] = Variable<String>(name);
    map['symbol'] = Variable<String>(symbol);
    map['type'] = Variable<int>(type);
    map['rate_to_anchor'] = Variable<String>(rateToAnchor);
    map['anchor_code'] = Variable<String>(anchorCode);
    map['rate_refresh_time'] = Variable<int>(rateRefreshTime);
    if (!nullToAbsent || icon != null) {
      map['icon'] = Variable<String>(icon);
    }
    map['enable'] = Variable<bool>(enable);
    return map;
  }

  CurrenciesCompanion toCompanion(bool nullToAbsent) {
    return CurrenciesCompanion(
      code: Value(code),
      name: Value(name),
      symbol: Value(symbol),
      type: Value(type),
      rateToAnchor: Value(rateToAnchor),
      anchorCode: Value(anchorCode),
      rateRefreshTime: Value(rateRefreshTime),
      icon: icon == null && nullToAbsent ? const Value.absent() : Value(icon),
      enable: Value(enable),
    );
  }

  factory Currency.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Currency(
      code: serializer.fromJson<String>(json['code']),
      name: serializer.fromJson<String>(json['name']),
      symbol: serializer.fromJson<String>(json['symbol']),
      type: serializer.fromJson<int>(json['type']),
      rateToAnchor: serializer.fromJson<String>(json['rateToAnchor']),
      anchorCode: serializer.fromJson<String>(json['anchorCode']),
      rateRefreshTime: serializer.fromJson<int>(json['rateRefreshTime']),
      icon: serializer.fromJson<String?>(json['icon']),
      enable: serializer.fromJson<bool>(json['enable']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'code': serializer.toJson<String>(code),
      'name': serializer.toJson<String>(name),
      'symbol': serializer.toJson<String>(symbol),
      'type': serializer.toJson<int>(type),
      'rateToAnchor': serializer.toJson<String>(rateToAnchor),
      'anchorCode': serializer.toJson<String>(anchorCode),
      'rateRefreshTime': serializer.toJson<int>(rateRefreshTime),
      'icon': serializer.toJson<String?>(icon),
      'enable': serializer.toJson<bool>(enable),
    };
  }

  Currency copyWith({
    String? code,
    String? name,
    String? symbol,
    int? type,
    String? rateToAnchor,
    String? anchorCode,
    int? rateRefreshTime,
    Value<String?> icon = const Value.absent(),
    bool? enable,
  }) => Currency(
    code: code ?? this.code,
    name: name ?? this.name,
    symbol: symbol ?? this.symbol,
    type: type ?? this.type,
    rateToAnchor: rateToAnchor ?? this.rateToAnchor,
    anchorCode: anchorCode ?? this.anchorCode,
    rateRefreshTime: rateRefreshTime ?? this.rateRefreshTime,
    icon: icon.present ? icon.value : this.icon,
    enable: enable ?? this.enable,
  );
  Currency copyWithCompanion(CurrenciesCompanion data) {
    return Currency(
      code: data.code.present ? data.code.value : this.code,
      name: data.name.present ? data.name.value : this.name,
      symbol: data.symbol.present ? data.symbol.value : this.symbol,
      type: data.type.present ? data.type.value : this.type,
      rateToAnchor: data.rateToAnchor.present
          ? data.rateToAnchor.value
          : this.rateToAnchor,
      anchorCode: data.anchorCode.present
          ? data.anchorCode.value
          : this.anchorCode,
      rateRefreshTime: data.rateRefreshTime.present
          ? data.rateRefreshTime.value
          : this.rateRefreshTime,
      icon: data.icon.present ? data.icon.value : this.icon,
      enable: data.enable.present ? data.enable.value : this.enable,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Currency(')
          ..write('code: $code, ')
          ..write('name: $name, ')
          ..write('symbol: $symbol, ')
          ..write('type: $type, ')
          ..write('rateToAnchor: $rateToAnchor, ')
          ..write('anchorCode: $anchorCode, ')
          ..write('rateRefreshTime: $rateRefreshTime, ')
          ..write('icon: $icon, ')
          ..write('enable: $enable')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    code,
    name,
    symbol,
    type,
    rateToAnchor,
    anchorCode,
    rateRefreshTime,
    icon,
    enable,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Currency &&
          other.code == this.code &&
          other.name == this.name &&
          other.symbol == this.symbol &&
          other.type == this.type &&
          other.rateToAnchor == this.rateToAnchor &&
          other.anchorCode == this.anchorCode &&
          other.rateRefreshTime == this.rateRefreshTime &&
          other.icon == this.icon &&
          other.enable == this.enable);
}

class CurrenciesCompanion extends UpdateCompanion<Currency> {
  final Value<String> code;
  final Value<String> name;
  final Value<String> symbol;
  final Value<int> type;
  final Value<String> rateToAnchor;
  final Value<String> anchorCode;
  final Value<int> rateRefreshTime;
  final Value<String?> icon;
  final Value<bool> enable;
  final Value<int> rowid;
  const CurrenciesCompanion({
    this.code = const Value.absent(),
    this.name = const Value.absent(),
    this.symbol = const Value.absent(),
    this.type = const Value.absent(),
    this.rateToAnchor = const Value.absent(),
    this.anchorCode = const Value.absent(),
    this.rateRefreshTime = const Value.absent(),
    this.icon = const Value.absent(),
    this.enable = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CurrenciesCompanion.insert({
    required String code,
    required String name,
    required String symbol,
    this.type = const Value.absent(),
    required String rateToAnchor,
    required String anchorCode,
    this.rateRefreshTime = const Value.absent(),
    this.icon = const Value.absent(),
    this.enable = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : code = Value(code),
       name = Value(name),
       symbol = Value(symbol),
       rateToAnchor = Value(rateToAnchor),
       anchorCode = Value(anchorCode);
  static Insertable<Currency> custom({
    Expression<String>? code,
    Expression<String>? name,
    Expression<String>? symbol,
    Expression<int>? type,
    Expression<String>? rateToAnchor,
    Expression<String>? anchorCode,
    Expression<int>? rateRefreshTime,
    Expression<String>? icon,
    Expression<bool>? enable,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (code != null) 'code': code,
      if (name != null) 'name': name,
      if (symbol != null) 'symbol': symbol,
      if (type != null) 'type': type,
      if (rateToAnchor != null) 'rate_to_anchor': rateToAnchor,
      if (anchorCode != null) 'anchor_code': anchorCode,
      if (rateRefreshTime != null) 'rate_refresh_time': rateRefreshTime,
      if (icon != null) 'icon': icon,
      if (enable != null) 'enable': enable,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CurrenciesCompanion copyWith({
    Value<String>? code,
    Value<String>? name,
    Value<String>? symbol,
    Value<int>? type,
    Value<String>? rateToAnchor,
    Value<String>? anchorCode,
    Value<int>? rateRefreshTime,
    Value<String?>? icon,
    Value<bool>? enable,
    Value<int>? rowid,
  }) {
    return CurrenciesCompanion(
      code: code ?? this.code,
      name: name ?? this.name,
      symbol: symbol ?? this.symbol,
      type: type ?? this.type,
      rateToAnchor: rateToAnchor ?? this.rateToAnchor,
      anchorCode: anchorCode ?? this.anchorCode,
      rateRefreshTime: rateRefreshTime ?? this.rateRefreshTime,
      icon: icon ?? this.icon,
      enable: enable ?? this.enable,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (code.present) {
      map['code'] = Variable<String>(code.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (symbol.present) {
      map['symbol'] = Variable<String>(symbol.value);
    }
    if (type.present) {
      map['type'] = Variable<int>(type.value);
    }
    if (rateToAnchor.present) {
      map['rate_to_anchor'] = Variable<String>(rateToAnchor.value);
    }
    if (anchorCode.present) {
      map['anchor_code'] = Variable<String>(anchorCode.value);
    }
    if (rateRefreshTime.present) {
      map['rate_refresh_time'] = Variable<int>(rateRefreshTime.value);
    }
    if (icon.present) {
      map['icon'] = Variable<String>(icon.value);
    }
    if (enable.present) {
      map['enable'] = Variable<bool>(enable.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CurrenciesCompanion(')
          ..write('code: $code, ')
          ..write('name: $name, ')
          ..write('symbol: $symbol, ')
          ..write('type: $type, ')
          ..write('rateToAnchor: $rateToAnchor, ')
          ..write('anchorCode: $anchorCode, ')
          ..write('rateRefreshTime: $rateRefreshTime, ')
          ..write('icon: $icon, ')
          ..write('enable: $enable, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $WriteCommandsTable extends WriteCommands
    with TableInfo<$WriteCommandsTable, WriteCommand> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $WriteCommandsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _commandIdMeta = const VerificationMeta(
    'commandId',
  );
  @override
  late final GeneratedColumn<String> commandId = GeneratedColumn<String>(
    'command_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _payloadHashMeta = const VerificationMeta(
    'payloadHash',
  );
  @override
  late final GeneratedColumn<String> payloadHash = GeneratedColumn<String>(
    'payload_hash',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _resultIdMeta = const VerificationMeta(
    'resultId',
  );
  @override
  late final GeneratedColumn<String> resultId = GeneratedColumn<String>(
    'result_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _committedAtMeta = const VerificationMeta(
    'committedAt',
  );
  @override
  late final GeneratedColumn<int> committedAt = GeneratedColumn<int>(
    'committed_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    commandId,
    payloadHash,
    resultId,
    committedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'ti_write_command';
  @override
  VerificationContext validateIntegrity(
    Insertable<WriteCommand> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('command_id')) {
      context.handle(
        _commandIdMeta,
        commandId.isAcceptableOrUnknown(data['command_id']!, _commandIdMeta),
      );
    } else if (isInserting) {
      context.missing(_commandIdMeta);
    }
    if (data.containsKey('payload_hash')) {
      context.handle(
        _payloadHashMeta,
        payloadHash.isAcceptableOrUnknown(
          data['payload_hash']!,
          _payloadHashMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_payloadHashMeta);
    }
    if (data.containsKey('result_id')) {
      context.handle(
        _resultIdMeta,
        resultId.isAcceptableOrUnknown(data['result_id']!, _resultIdMeta),
      );
    } else if (isInserting) {
      context.missing(_resultIdMeta);
    }
    if (data.containsKey('committed_at')) {
      context.handle(
        _committedAtMeta,
        committedAt.isAcceptableOrUnknown(
          data['committed_at']!,
          _committedAtMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_committedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {commandId};
  @override
  WriteCommand map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return WriteCommand(
      commandId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}command_id'],
      )!,
      payloadHash: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}payload_hash'],
      )!,
      resultId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}result_id'],
      )!,
      committedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}committed_at'],
      )!,
    );
  }

  @override
  $WriteCommandsTable createAlias(String alias) {
    return $WriteCommandsTable(attachedDatabase, alias);
  }
}

class WriteCommand extends DataClass implements Insertable<WriteCommand> {
  final String commandId;
  final String payloadHash;
  final String resultId;
  final int committedAt;
  const WriteCommand({
    required this.commandId,
    required this.payloadHash,
    required this.resultId,
    required this.committedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['command_id'] = Variable<String>(commandId);
    map['payload_hash'] = Variable<String>(payloadHash);
    map['result_id'] = Variable<String>(resultId);
    map['committed_at'] = Variable<int>(committedAt);
    return map;
  }

  WriteCommandsCompanion toCompanion(bool nullToAbsent) {
    return WriteCommandsCompanion(
      commandId: Value(commandId),
      payloadHash: Value(payloadHash),
      resultId: Value(resultId),
      committedAt: Value(committedAt),
    );
  }

  factory WriteCommand.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return WriteCommand(
      commandId: serializer.fromJson<String>(json['commandId']),
      payloadHash: serializer.fromJson<String>(json['payloadHash']),
      resultId: serializer.fromJson<String>(json['resultId']),
      committedAt: serializer.fromJson<int>(json['committedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'commandId': serializer.toJson<String>(commandId),
      'payloadHash': serializer.toJson<String>(payloadHash),
      'resultId': serializer.toJson<String>(resultId),
      'committedAt': serializer.toJson<int>(committedAt),
    };
  }

  WriteCommand copyWith({
    String? commandId,
    String? payloadHash,
    String? resultId,
    int? committedAt,
  }) => WriteCommand(
    commandId: commandId ?? this.commandId,
    payloadHash: payloadHash ?? this.payloadHash,
    resultId: resultId ?? this.resultId,
    committedAt: committedAt ?? this.committedAt,
  );
  WriteCommand copyWithCompanion(WriteCommandsCompanion data) {
    return WriteCommand(
      commandId: data.commandId.present ? data.commandId.value : this.commandId,
      payloadHash: data.payloadHash.present
          ? data.payloadHash.value
          : this.payloadHash,
      resultId: data.resultId.present ? data.resultId.value : this.resultId,
      committedAt: data.committedAt.present
          ? data.committedAt.value
          : this.committedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('WriteCommand(')
          ..write('commandId: $commandId, ')
          ..write('payloadHash: $payloadHash, ')
          ..write('resultId: $resultId, ')
          ..write('committedAt: $committedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(commandId, payloadHash, resultId, committedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is WriteCommand &&
          other.commandId == this.commandId &&
          other.payloadHash == this.payloadHash &&
          other.resultId == this.resultId &&
          other.committedAt == this.committedAt);
}

class WriteCommandsCompanion extends UpdateCompanion<WriteCommand> {
  final Value<String> commandId;
  final Value<String> payloadHash;
  final Value<String> resultId;
  final Value<int> committedAt;
  final Value<int> rowid;
  const WriteCommandsCompanion({
    this.commandId = const Value.absent(),
    this.payloadHash = const Value.absent(),
    this.resultId = const Value.absent(),
    this.committedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  WriteCommandsCompanion.insert({
    required String commandId,
    required String payloadHash,
    required String resultId,
    required int committedAt,
    this.rowid = const Value.absent(),
  }) : commandId = Value(commandId),
       payloadHash = Value(payloadHash),
       resultId = Value(resultId),
       committedAt = Value(committedAt);
  static Insertable<WriteCommand> custom({
    Expression<String>? commandId,
    Expression<String>? payloadHash,
    Expression<String>? resultId,
    Expression<int>? committedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (commandId != null) 'command_id': commandId,
      if (payloadHash != null) 'payload_hash': payloadHash,
      if (resultId != null) 'result_id': resultId,
      if (committedAt != null) 'committed_at': committedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  WriteCommandsCompanion copyWith({
    Value<String>? commandId,
    Value<String>? payloadHash,
    Value<String>? resultId,
    Value<int>? committedAt,
    Value<int>? rowid,
  }) {
    return WriteCommandsCompanion(
      commandId: commandId ?? this.commandId,
      payloadHash: payloadHash ?? this.payloadHash,
      resultId: resultId ?? this.resultId,
      committedAt: committedAt ?? this.committedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (commandId.present) {
      map['command_id'] = Variable<String>(commandId.value);
    }
    if (payloadHash.present) {
      map['payload_hash'] = Variable<String>(payloadHash.value);
    }
    if (resultId.present) {
      map['result_id'] = Variable<String>(resultId.value);
    }
    if (committedAt.present) {
      map['committed_at'] = Variable<int>(committedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('WriteCommandsCompanion(')
          ..write('commandId: $commandId, ')
          ..write('payloadHash: $payloadHash, ')
          ..write('resultId: $resultId, ')
          ..write('committedAt: $committedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $PreferencesTable extends Preferences
    with TableInfo<$PreferencesTable, Preference> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PreferencesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'ti_preference';
  @override
  VerificationContext validateIntegrity(
    Insertable<Preference> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  Preference map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Preference(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value'],
      )!,
    );
  }

  @override
  $PreferencesTable createAlias(String alias) {
    return $PreferencesTable(attachedDatabase, alias);
  }
}

class Preference extends DataClass implements Insertable<Preference> {
  final String key;
  final String value;
  const Preference({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  PreferencesCompanion toCompanion(bool nullToAbsent) {
    return PreferencesCompanion(key: Value(key), value: Value(value));
  }

  factory Preference.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Preference(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
    };
  }

  Preference copyWith({String? key, String? value}) =>
      Preference(key: key ?? this.key, value: value ?? this.value);
  Preference copyWithCompanion(PreferencesCompanion data) {
    return Preference(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Preference(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Preference &&
          other.key == this.key &&
          other.value == this.value);
}

class PreferencesCompanion extends UpdateCompanion<Preference> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const PreferencesCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PreferencesCompanion.insert({
    required String key,
    required String value,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       value = Value(value);
  static Insertable<Preference> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PreferencesCompanion copyWith({
    Value<String>? key,
    Value<String>? value,
    Value<int>? rowid,
  }) {
    return PreferencesCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PreferencesCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $AccountBooksTable accountBooks = $AccountBooksTable(this);
  late final $AssetsTable assets = $AssetsTable(this);
  late final $BankCardsTable bankCards = $BankCardsTable(this);
  late final $BudgetsTable budgets = $BudgetsTable(this);
  late final $ImportPlatformsTable importPlatforms = $ImportPlatformsTable(
    this,
  );
  late final $RecordsTable records = $RecordsTable(this);
  late final $RecordCategoriesTable recordCategories = $RecordCategoriesTable(
    this,
  );
  late final $RemarksTable remarks = $RemarksTable(this);
  late final $RecordTemplatesTable recordTemplates = $RecordTemplatesTable(
    this,
  );
  late final $WishesTable wishes = $WishesTable(this);
  late final $RecordPeriodsTable recordPeriods = $RecordPeriodsTable(this);
  late final $ReminderEventsTable reminderEvents = $ReminderEventsTable(this);
  late final $InstallmentsTable installments = $InstallmentsTable(this);
  late final $NotesTable notes = $NotesTable(this);
  late final $TagsTable tags = $TagsTable(this);
  late final $TagRecordsTable tagRecords = $TagRecordsTable(this);
  late final $MoneySavePlansTable moneySavePlans = $MoneySavePlansTable(this);
  late final $MoneySavePlanRecordsTable moneySavePlanRecords =
      $MoneySavePlanRecordsTable(this);
  late final $AssetBooksTable assetBooks = $AssetBooksTable(this);
  late final $StatStoriesTable statStories = $StatStoriesTable(this);
  late final $AutoMapsTable autoMaps = $AutoMapsTable(this);
  late final $CurrenciesTable currencies = $CurrenciesTable(this);
  late final $WriteCommandsTable writeCommands = $WriteCommandsTable(this);
  late final $PreferencesTable preferences = $PreferencesTable(this);
  late final Index indexBudgetRecordCatId = Index(
    'index_budget_record_cat_id',
    'CREATE INDEX index_budget_record_cat_id ON budget (record_cat_id)',
  );
  late final Index indexRecordAccountBookId = Index(
    'index_record_account_book_id',
    'CREATE INDEX index_record_account_book_id ON record (account_book_id)',
  );
  late final Index recordBookTime = Index(
    'record_book_time',
    'CREATE INDEX record_book_time ON record (account_book_id, record_time DESC)',
  );
  late final Index recordAsset = Index(
    'record_asset',
    'CREATE INDEX record_asset ON record (asset_id)',
  );
  late final Index recordFromAsset = Index(
    'record_from_asset',
    'CREATE INDEX record_from_asset ON record (from_asset_id)',
  );
  late final Index recordToAsset = Index(
    'record_to_asset',
    'CREATE INDEX record_to_asset ON record (to_asset_id)',
  );
  late final Index recordCategoryBookParent = Index(
    'record_category_book_parent',
    'CREATE INDEX record_category_book_parent ON record_category (account_book_id, parent_cat_id, sort)',
  );
  late final Index indexTagRecordRecordId = Index(
    'index_tag_record_record_id',
    'CREATE INDEX index_tag_record_record_id ON tag_record (record_id)',
  );
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    accountBooks,
    assets,
    bankCards,
    budgets,
    importPlatforms,
    records,
    recordCategories,
    remarks,
    recordTemplates,
    wishes,
    recordPeriods,
    reminderEvents,
    installments,
    notes,
    tags,
    tagRecords,
    moneySavePlans,
    moneySavePlanRecords,
    assetBooks,
    statStories,
    autoMaps,
    currencies,
    writeCommands,
    preferences,
    indexBudgetRecordCatId,
    indexRecordAccountBookId,
    recordBookTime,
    recordAsset,
    recordFromAsset,
    recordToAsset,
    recordCategoryBookParent,
    indexTagRecordRecordId,
  ];
}

typedef $$AccountBooksTableCreateCompanionBuilder =
    AccountBooksCompanion Function({
      Value<int> id,
      Value<int> type,
      required String name,
      Value<String> cover,
      Value<int> sort,
      Value<int> status,
      Value<int> startDay,
      required int createDate,
      Value<int> displayWay,
      Value<String?> extraInfo,
    });
typedef $$AccountBooksTableUpdateCompanionBuilder =
    AccountBooksCompanion Function({
      Value<int> id,
      Value<int> type,
      Value<String> name,
      Value<String> cover,
      Value<int> sort,
      Value<int> status,
      Value<int> startDay,
      Value<int> createDate,
      Value<int> displayWay,
      Value<String?> extraInfo,
    });

class $$AccountBooksTableFilterComposer
    extends Composer<_$AppDatabase, $AccountBooksTable> {
  $$AccountBooksTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get cover => $composableBuilder(
    column: $table.cover,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sort => $composableBuilder(
    column: $table.sort,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get startDay => $composableBuilder(
    column: $table.startDay,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createDate => $composableBuilder(
    column: $table.createDate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get displayWay => $composableBuilder(
    column: $table.displayWay,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get extraInfo => $composableBuilder(
    column: $table.extraInfo,
    builder: (column) => ColumnFilters(column),
  );
}

class $$AccountBooksTableOrderingComposer
    extends Composer<_$AppDatabase, $AccountBooksTable> {
  $$AccountBooksTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get cover => $composableBuilder(
    column: $table.cover,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sort => $composableBuilder(
    column: $table.sort,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get startDay => $composableBuilder(
    column: $table.startDay,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createDate => $composableBuilder(
    column: $table.createDate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get displayWay => $composableBuilder(
    column: $table.displayWay,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get extraInfo => $composableBuilder(
    column: $table.extraInfo,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AccountBooksTableAnnotationComposer
    extends Composer<_$AppDatabase, $AccountBooksTable> {
  $$AccountBooksTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get cover =>
      $composableBuilder(column: $table.cover, builder: (column) => column);

  GeneratedColumn<int> get sort =>
      $composableBuilder(column: $table.sort, builder: (column) => column);

  GeneratedColumn<int> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<int> get startDay =>
      $composableBuilder(column: $table.startDay, builder: (column) => column);

  GeneratedColumn<int> get createDate => $composableBuilder(
    column: $table.createDate,
    builder: (column) => column,
  );

  GeneratedColumn<int> get displayWay => $composableBuilder(
    column: $table.displayWay,
    builder: (column) => column,
  );

  GeneratedColumn<String> get extraInfo =>
      $composableBuilder(column: $table.extraInfo, builder: (column) => column);
}

class $$AccountBooksTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $AccountBooksTable,
          AccountBook,
          $$AccountBooksTableFilterComposer,
          $$AccountBooksTableOrderingComposer,
          $$AccountBooksTableAnnotationComposer,
          $$AccountBooksTableCreateCompanionBuilder,
          $$AccountBooksTableUpdateCompanionBuilder,
          (
            AccountBook,
            BaseReferences<_$AppDatabase, $AccountBooksTable, AccountBook>,
          ),
          AccountBook,
          PrefetchHooks Function()
        > {
  $$AccountBooksTableTableManager(_$AppDatabase db, $AccountBooksTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AccountBooksTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AccountBooksTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AccountBooksTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> type = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> cover = const Value.absent(),
                Value<int> sort = const Value.absent(),
                Value<int> status = const Value.absent(),
                Value<int> startDay = const Value.absent(),
                Value<int> createDate = const Value.absent(),
                Value<int> displayWay = const Value.absent(),
                Value<String?> extraInfo = const Value.absent(),
              }) => AccountBooksCompanion(
                id: id,
                type: type,
                name: name,
                cover: cover,
                sort: sort,
                status: status,
                startDay: startDay,
                createDate: createDate,
                displayWay: displayWay,
                extraInfo: extraInfo,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> type = const Value.absent(),
                required String name,
                Value<String> cover = const Value.absent(),
                Value<int> sort = const Value.absent(),
                Value<int> status = const Value.absent(),
                Value<int> startDay = const Value.absent(),
                required int createDate,
                Value<int> displayWay = const Value.absent(),
                Value<String?> extraInfo = const Value.absent(),
              }) => AccountBooksCompanion.insert(
                id: id,
                type: type,
                name: name,
                cover: cover,
                sort: sort,
                status: status,
                startDay: startDay,
                createDate: createDate,
                displayWay: displayWay,
                extraInfo: extraInfo,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$AccountBooksTable, AccountBook>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $AccountBooksTable,
                    AccountBook
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$AccountBooksTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $AccountBooksTable,
      AccountBook,
      $$AccountBooksTableFilterComposer,
      $$AccountBooksTableOrderingComposer,
      $$AccountBooksTableAnnotationComposer,
      $$AccountBooksTableCreateCompanionBuilder,
      $$AccountBooksTableUpdateCompanionBuilder,
      (
        AccountBook,
        BaseReferences<_$AppDatabase, $AccountBooksTable, AccountBook>,
      ),
      AccountBook,
      PrefetchHooks Function()
    >;
typedef $$AssetsTableCreateCompanionBuilder =
    AssetsCompanion Function({
      Value<int> id,
      required String name,
      required BigInt balanceMinor,
      required int type,
      Value<int> subType,
      required int createDate,
      Value<int> sort,
      Value<String> icon,
      Value<String?> remark,
      required BigInt initMoneyMinor,
      Value<bool> isDefault,
      Value<int> isEffectiveAsset,
      Value<int> usedTimes,
      Value<String?> color,
      Value<int> status,
      Value<String?> extraInfo,
      Value<String?> loanInfo,
      Value<String?> creditInfo,
      Value<String?> fixedDepositInfo,
      Value<String?> groupName,
      Value<String?> currency,
    });
typedef $$AssetsTableUpdateCompanionBuilder =
    AssetsCompanion Function({
      Value<int> id,
      Value<String> name,
      Value<BigInt> balanceMinor,
      Value<int> type,
      Value<int> subType,
      Value<int> createDate,
      Value<int> sort,
      Value<String> icon,
      Value<String?> remark,
      Value<BigInt> initMoneyMinor,
      Value<bool> isDefault,
      Value<int> isEffectiveAsset,
      Value<int> usedTimes,
      Value<String?> color,
      Value<int> status,
      Value<String?> extraInfo,
      Value<String?> loanInfo,
      Value<String?> creditInfo,
      Value<String?> fixedDepositInfo,
      Value<String?> groupName,
      Value<String?> currency,
    });

class $$AssetsTableFilterComposer
    extends Composer<_$AppDatabase, $AssetsTable> {
  $$AssetsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<BigInt> get balanceMinor => $composableBuilder(
    column: $table.balanceMinor,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get subType => $composableBuilder(
    column: $table.subType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createDate => $composableBuilder(
    column: $table.createDate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sort => $composableBuilder(
    column: $table.sort,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get icon => $composableBuilder(
    column: $table.icon,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get remark => $composableBuilder(
    column: $table.remark,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<BigInt> get initMoneyMinor => $composableBuilder(
    column: $table.initMoneyMinor,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isDefault => $composableBuilder(
    column: $table.isDefault,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get isEffectiveAsset => $composableBuilder(
    column: $table.isEffectiveAsset,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get usedTimes => $composableBuilder(
    column: $table.usedTimes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get color => $composableBuilder(
    column: $table.color,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get extraInfo => $composableBuilder(
    column: $table.extraInfo,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get loanInfo => $composableBuilder(
    column: $table.loanInfo,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get creditInfo => $composableBuilder(
    column: $table.creditInfo,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get fixedDepositInfo => $composableBuilder(
    column: $table.fixedDepositInfo,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get groupName => $composableBuilder(
    column: $table.groupName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get currency => $composableBuilder(
    column: $table.currency,
    builder: (column) => ColumnFilters(column),
  );
}

class $$AssetsTableOrderingComposer
    extends Composer<_$AppDatabase, $AssetsTable> {
  $$AssetsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<BigInt> get balanceMinor => $composableBuilder(
    column: $table.balanceMinor,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get subType => $composableBuilder(
    column: $table.subType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createDate => $composableBuilder(
    column: $table.createDate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sort => $composableBuilder(
    column: $table.sort,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get icon => $composableBuilder(
    column: $table.icon,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get remark => $composableBuilder(
    column: $table.remark,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<BigInt> get initMoneyMinor => $composableBuilder(
    column: $table.initMoneyMinor,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isDefault => $composableBuilder(
    column: $table.isDefault,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get isEffectiveAsset => $composableBuilder(
    column: $table.isEffectiveAsset,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get usedTimes => $composableBuilder(
    column: $table.usedTimes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get color => $composableBuilder(
    column: $table.color,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get extraInfo => $composableBuilder(
    column: $table.extraInfo,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get loanInfo => $composableBuilder(
    column: $table.loanInfo,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get creditInfo => $composableBuilder(
    column: $table.creditInfo,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get fixedDepositInfo => $composableBuilder(
    column: $table.fixedDepositInfo,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get groupName => $composableBuilder(
    column: $table.groupName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get currency => $composableBuilder(
    column: $table.currency,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AssetsTableAnnotationComposer
    extends Composer<_$AppDatabase, $AssetsTable> {
  $$AssetsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<BigInt> get balanceMinor => $composableBuilder(
    column: $table.balanceMinor,
    builder: (column) => column,
  );

  GeneratedColumn<int> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<int> get subType =>
      $composableBuilder(column: $table.subType, builder: (column) => column);

  GeneratedColumn<int> get createDate => $composableBuilder(
    column: $table.createDate,
    builder: (column) => column,
  );

  GeneratedColumn<int> get sort =>
      $composableBuilder(column: $table.sort, builder: (column) => column);

  GeneratedColumn<String> get icon =>
      $composableBuilder(column: $table.icon, builder: (column) => column);

  GeneratedColumn<String> get remark =>
      $composableBuilder(column: $table.remark, builder: (column) => column);

  GeneratedColumn<BigInt> get initMoneyMinor => $composableBuilder(
    column: $table.initMoneyMinor,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isDefault =>
      $composableBuilder(column: $table.isDefault, builder: (column) => column);

  GeneratedColumn<int> get isEffectiveAsset => $composableBuilder(
    column: $table.isEffectiveAsset,
    builder: (column) => column,
  );

  GeneratedColumn<int> get usedTimes =>
      $composableBuilder(column: $table.usedTimes, builder: (column) => column);

  GeneratedColumn<String> get color =>
      $composableBuilder(column: $table.color, builder: (column) => column);

  GeneratedColumn<int> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<String> get extraInfo =>
      $composableBuilder(column: $table.extraInfo, builder: (column) => column);

  GeneratedColumn<String> get loanInfo =>
      $composableBuilder(column: $table.loanInfo, builder: (column) => column);

  GeneratedColumn<String> get creditInfo => $composableBuilder(
    column: $table.creditInfo,
    builder: (column) => column,
  );

  GeneratedColumn<String> get fixedDepositInfo => $composableBuilder(
    column: $table.fixedDepositInfo,
    builder: (column) => column,
  );

  GeneratedColumn<String> get groupName =>
      $composableBuilder(column: $table.groupName, builder: (column) => column);

  GeneratedColumn<String> get currency =>
      $composableBuilder(column: $table.currency, builder: (column) => column);
}

class $$AssetsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $AssetsTable,
          Asset,
          $$AssetsTableFilterComposer,
          $$AssetsTableOrderingComposer,
          $$AssetsTableAnnotationComposer,
          $$AssetsTableCreateCompanionBuilder,
          $$AssetsTableUpdateCompanionBuilder,
          (Asset, BaseReferences<_$AppDatabase, $AssetsTable, Asset>),
          Asset,
          PrefetchHooks Function()
        > {
  $$AssetsTableTableManager(_$AppDatabase db, $AssetsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AssetsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AssetsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AssetsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<BigInt> balanceMinor = const Value.absent(),
                Value<int> type = const Value.absent(),
                Value<int> subType = const Value.absent(),
                Value<int> createDate = const Value.absent(),
                Value<int> sort = const Value.absent(),
                Value<String> icon = const Value.absent(),
                Value<String?> remark = const Value.absent(),
                Value<BigInt> initMoneyMinor = const Value.absent(),
                Value<bool> isDefault = const Value.absent(),
                Value<int> isEffectiveAsset = const Value.absent(),
                Value<int> usedTimes = const Value.absent(),
                Value<String?> color = const Value.absent(),
                Value<int> status = const Value.absent(),
                Value<String?> extraInfo = const Value.absent(),
                Value<String?> loanInfo = const Value.absent(),
                Value<String?> creditInfo = const Value.absent(),
                Value<String?> fixedDepositInfo = const Value.absent(),
                Value<String?> groupName = const Value.absent(),
                Value<String?> currency = const Value.absent(),
              }) => AssetsCompanion(
                id: id,
                name: name,
                balanceMinor: balanceMinor,
                type: type,
                subType: subType,
                createDate: createDate,
                sort: sort,
                icon: icon,
                remark: remark,
                initMoneyMinor: initMoneyMinor,
                isDefault: isDefault,
                isEffectiveAsset: isEffectiveAsset,
                usedTimes: usedTimes,
                color: color,
                status: status,
                extraInfo: extraInfo,
                loanInfo: loanInfo,
                creditInfo: creditInfo,
                fixedDepositInfo: fixedDepositInfo,
                groupName: groupName,
                currency: currency,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String name,
                required BigInt balanceMinor,
                required int type,
                Value<int> subType = const Value.absent(),
                required int createDate,
                Value<int> sort = const Value.absent(),
                Value<String> icon = const Value.absent(),
                Value<String?> remark = const Value.absent(),
                required BigInt initMoneyMinor,
                Value<bool> isDefault = const Value.absent(),
                Value<int> isEffectiveAsset = const Value.absent(),
                Value<int> usedTimes = const Value.absent(),
                Value<String?> color = const Value.absent(),
                Value<int> status = const Value.absent(),
                Value<String?> extraInfo = const Value.absent(),
                Value<String?> loanInfo = const Value.absent(),
                Value<String?> creditInfo = const Value.absent(),
                Value<String?> fixedDepositInfo = const Value.absent(),
                Value<String?> groupName = const Value.absent(),
                Value<String?> currency = const Value.absent(),
              }) => AssetsCompanion.insert(
                id: id,
                name: name,
                balanceMinor: balanceMinor,
                type: type,
                subType: subType,
                createDate: createDate,
                sort: sort,
                icon: icon,
                remark: remark,
                initMoneyMinor: initMoneyMinor,
                isDefault: isDefault,
                isEffectiveAsset: isEffectiveAsset,
                usedTimes: usedTimes,
                color: color,
                status: status,
                extraInfo: extraInfo,
                loanInfo: loanInfo,
                creditInfo: creditInfo,
                fixedDepositInfo: fixedDepositInfo,
                groupName: groupName,
                currency: currency,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$AssetsTable, Asset>(table),
                  BaseReferences<_$AppDatabase, $AssetsTable, Asset>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$AssetsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $AssetsTable,
      Asset,
      $$AssetsTableFilterComposer,
      $$AssetsTableOrderingComposer,
      $$AssetsTableAnnotationComposer,
      $$AssetsTableCreateCompanionBuilder,
      $$AssetsTableUpdateCompanionBuilder,
      (Asset, BaseReferences<_$AppDatabase, $AssetsTable, Asset>),
      Asset,
      PrefetchHooks Function()
    >;
typedef $$BankCardsTableCreateCompanionBuilder =
    BankCardsCompanion Function({
      Value<int> id,
      required int cardType,
      required String cardName,
      required String cardNo,
      required String cardOwner,
      Value<String> remark,
      Value<String?> cardColor,
      Value<int> sort,
      required int createDate,
      Value<int> cardAssetId,
    });
typedef $$BankCardsTableUpdateCompanionBuilder =
    BankCardsCompanion Function({
      Value<int> id,
      Value<int> cardType,
      Value<String> cardName,
      Value<String> cardNo,
      Value<String> cardOwner,
      Value<String> remark,
      Value<String?> cardColor,
      Value<int> sort,
      Value<int> createDate,
      Value<int> cardAssetId,
    });

class $$BankCardsTableFilterComposer
    extends Composer<_$AppDatabase, $BankCardsTable> {
  $$BankCardsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get cardType => $composableBuilder(
    column: $table.cardType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get cardName => $composableBuilder(
    column: $table.cardName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get cardNo => $composableBuilder(
    column: $table.cardNo,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get cardOwner => $composableBuilder(
    column: $table.cardOwner,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get remark => $composableBuilder(
    column: $table.remark,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get cardColor => $composableBuilder(
    column: $table.cardColor,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sort => $composableBuilder(
    column: $table.sort,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createDate => $composableBuilder(
    column: $table.createDate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get cardAssetId => $composableBuilder(
    column: $table.cardAssetId,
    builder: (column) => ColumnFilters(column),
  );
}

class $$BankCardsTableOrderingComposer
    extends Composer<_$AppDatabase, $BankCardsTable> {
  $$BankCardsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get cardType => $composableBuilder(
    column: $table.cardType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get cardName => $composableBuilder(
    column: $table.cardName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get cardNo => $composableBuilder(
    column: $table.cardNo,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get cardOwner => $composableBuilder(
    column: $table.cardOwner,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get remark => $composableBuilder(
    column: $table.remark,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get cardColor => $composableBuilder(
    column: $table.cardColor,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sort => $composableBuilder(
    column: $table.sort,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createDate => $composableBuilder(
    column: $table.createDate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get cardAssetId => $composableBuilder(
    column: $table.cardAssetId,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$BankCardsTableAnnotationComposer
    extends Composer<_$AppDatabase, $BankCardsTable> {
  $$BankCardsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get cardType =>
      $composableBuilder(column: $table.cardType, builder: (column) => column);

  GeneratedColumn<String> get cardName =>
      $composableBuilder(column: $table.cardName, builder: (column) => column);

  GeneratedColumn<String> get cardNo =>
      $composableBuilder(column: $table.cardNo, builder: (column) => column);

  GeneratedColumn<String> get cardOwner =>
      $composableBuilder(column: $table.cardOwner, builder: (column) => column);

  GeneratedColumn<String> get remark =>
      $composableBuilder(column: $table.remark, builder: (column) => column);

  GeneratedColumn<String> get cardColor =>
      $composableBuilder(column: $table.cardColor, builder: (column) => column);

  GeneratedColumn<int> get sort =>
      $composableBuilder(column: $table.sort, builder: (column) => column);

  GeneratedColumn<int> get createDate => $composableBuilder(
    column: $table.createDate,
    builder: (column) => column,
  );

  GeneratedColumn<int> get cardAssetId => $composableBuilder(
    column: $table.cardAssetId,
    builder: (column) => column,
  );
}

class $$BankCardsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $BankCardsTable,
          BankCard,
          $$BankCardsTableFilterComposer,
          $$BankCardsTableOrderingComposer,
          $$BankCardsTableAnnotationComposer,
          $$BankCardsTableCreateCompanionBuilder,
          $$BankCardsTableUpdateCompanionBuilder,
          (BankCard, BaseReferences<_$AppDatabase, $BankCardsTable, BankCard>),
          BankCard,
          PrefetchHooks Function()
        > {
  $$BankCardsTableTableManager(_$AppDatabase db, $BankCardsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$BankCardsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$BankCardsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$BankCardsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> cardType = const Value.absent(),
                Value<String> cardName = const Value.absent(),
                Value<String> cardNo = const Value.absent(),
                Value<String> cardOwner = const Value.absent(),
                Value<String> remark = const Value.absent(),
                Value<String?> cardColor = const Value.absent(),
                Value<int> sort = const Value.absent(),
                Value<int> createDate = const Value.absent(),
                Value<int> cardAssetId = const Value.absent(),
              }) => BankCardsCompanion(
                id: id,
                cardType: cardType,
                cardName: cardName,
                cardNo: cardNo,
                cardOwner: cardOwner,
                remark: remark,
                cardColor: cardColor,
                sort: sort,
                createDate: createDate,
                cardAssetId: cardAssetId,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int cardType,
                required String cardName,
                required String cardNo,
                required String cardOwner,
                Value<String> remark = const Value.absent(),
                Value<String?> cardColor = const Value.absent(),
                Value<int> sort = const Value.absent(),
                required int createDate,
                Value<int> cardAssetId = const Value.absent(),
              }) => BankCardsCompanion.insert(
                id: id,
                cardType: cardType,
                cardName: cardName,
                cardNo: cardNo,
                cardOwner: cardOwner,
                remark: remark,
                cardColor: cardColor,
                sort: sort,
                createDate: createDate,
                cardAssetId: cardAssetId,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$BankCardsTable, BankCard>(table),
                  BaseReferences<_$AppDatabase, $BankCardsTable, BankCard>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$BankCardsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $BankCardsTable,
      BankCard,
      $$BankCardsTableFilterComposer,
      $$BankCardsTableOrderingComposer,
      $$BankCardsTableAnnotationComposer,
      $$BankCardsTableCreateCompanionBuilder,
      $$BankCardsTableUpdateCompanionBuilder,
      (BankCard, BaseReferences<_$AppDatabase, $BankCardsTable, BankCard>),
      BankCard,
      PrefetchHooks Function()
    >;
typedef $$BudgetsTableCreateCompanionBuilder =
    BudgetsCompanion Function({
      Value<int> id,
      required int budgetType,
      required int recordCatId,
      required BigInt amountMinor,
      required int bookId,
      required String section,
      Value<int> sort,
      required int createDate,
      Value<String?> remark,
      Value<String?> extraInfo,
    });
typedef $$BudgetsTableUpdateCompanionBuilder =
    BudgetsCompanion Function({
      Value<int> id,
      Value<int> budgetType,
      Value<int> recordCatId,
      Value<BigInt> amountMinor,
      Value<int> bookId,
      Value<String> section,
      Value<int> sort,
      Value<int> createDate,
      Value<String?> remark,
      Value<String?> extraInfo,
    });

class $$BudgetsTableFilterComposer
    extends Composer<_$AppDatabase, $BudgetsTable> {
  $$BudgetsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get budgetType => $composableBuilder(
    column: $table.budgetType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get recordCatId => $composableBuilder(
    column: $table.recordCatId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<BigInt> get amountMinor => $composableBuilder(
    column: $table.amountMinor,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get bookId => $composableBuilder(
    column: $table.bookId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get section => $composableBuilder(
    column: $table.section,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sort => $composableBuilder(
    column: $table.sort,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createDate => $composableBuilder(
    column: $table.createDate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get remark => $composableBuilder(
    column: $table.remark,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get extraInfo => $composableBuilder(
    column: $table.extraInfo,
    builder: (column) => ColumnFilters(column),
  );
}

class $$BudgetsTableOrderingComposer
    extends Composer<_$AppDatabase, $BudgetsTable> {
  $$BudgetsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get budgetType => $composableBuilder(
    column: $table.budgetType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get recordCatId => $composableBuilder(
    column: $table.recordCatId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<BigInt> get amountMinor => $composableBuilder(
    column: $table.amountMinor,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get bookId => $composableBuilder(
    column: $table.bookId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get section => $composableBuilder(
    column: $table.section,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sort => $composableBuilder(
    column: $table.sort,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createDate => $composableBuilder(
    column: $table.createDate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get remark => $composableBuilder(
    column: $table.remark,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get extraInfo => $composableBuilder(
    column: $table.extraInfo,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$BudgetsTableAnnotationComposer
    extends Composer<_$AppDatabase, $BudgetsTable> {
  $$BudgetsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get budgetType => $composableBuilder(
    column: $table.budgetType,
    builder: (column) => column,
  );

  GeneratedColumn<int> get recordCatId => $composableBuilder(
    column: $table.recordCatId,
    builder: (column) => column,
  );

  GeneratedColumn<BigInt> get amountMinor => $composableBuilder(
    column: $table.amountMinor,
    builder: (column) => column,
  );

  GeneratedColumn<int> get bookId =>
      $composableBuilder(column: $table.bookId, builder: (column) => column);

  GeneratedColumn<String> get section =>
      $composableBuilder(column: $table.section, builder: (column) => column);

  GeneratedColumn<int> get sort =>
      $composableBuilder(column: $table.sort, builder: (column) => column);

  GeneratedColumn<int> get createDate => $composableBuilder(
    column: $table.createDate,
    builder: (column) => column,
  );

  GeneratedColumn<String> get remark =>
      $composableBuilder(column: $table.remark, builder: (column) => column);

  GeneratedColumn<String> get extraInfo =>
      $composableBuilder(column: $table.extraInfo, builder: (column) => column);
}

class $$BudgetsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $BudgetsTable,
          Budget,
          $$BudgetsTableFilterComposer,
          $$BudgetsTableOrderingComposer,
          $$BudgetsTableAnnotationComposer,
          $$BudgetsTableCreateCompanionBuilder,
          $$BudgetsTableUpdateCompanionBuilder,
          (Budget, BaseReferences<_$AppDatabase, $BudgetsTable, Budget>),
          Budget,
          PrefetchHooks Function()
        > {
  $$BudgetsTableTableManager(_$AppDatabase db, $BudgetsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$BudgetsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$BudgetsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$BudgetsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> budgetType = const Value.absent(),
                Value<int> recordCatId = const Value.absent(),
                Value<BigInt> amountMinor = const Value.absent(),
                Value<int> bookId = const Value.absent(),
                Value<String> section = const Value.absent(),
                Value<int> sort = const Value.absent(),
                Value<int> createDate = const Value.absent(),
                Value<String?> remark = const Value.absent(),
                Value<String?> extraInfo = const Value.absent(),
              }) => BudgetsCompanion(
                id: id,
                budgetType: budgetType,
                recordCatId: recordCatId,
                amountMinor: amountMinor,
                bookId: bookId,
                section: section,
                sort: sort,
                createDate: createDate,
                remark: remark,
                extraInfo: extraInfo,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int budgetType,
                required int recordCatId,
                required BigInt amountMinor,
                required int bookId,
                required String section,
                Value<int> sort = const Value.absent(),
                required int createDate,
                Value<String?> remark = const Value.absent(),
                Value<String?> extraInfo = const Value.absent(),
              }) => BudgetsCompanion.insert(
                id: id,
                budgetType: budgetType,
                recordCatId: recordCatId,
                amountMinor: amountMinor,
                bookId: bookId,
                section: section,
                sort: sort,
                createDate: createDate,
                remark: remark,
                extraInfo: extraInfo,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$BudgetsTable, Budget>(table),
                  BaseReferences<_$AppDatabase, $BudgetsTable, Budget>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$BudgetsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $BudgetsTable,
      Budget,
      $$BudgetsTableFilterComposer,
      $$BudgetsTableOrderingComposer,
      $$BudgetsTableAnnotationComposer,
      $$BudgetsTableCreateCompanionBuilder,
      $$BudgetsTableUpdateCompanionBuilder,
      (Budget, BaseReferences<_$AppDatabase, $BudgetsTable, Budget>),
      Budget,
      PrefetchHooks Function()
    >;
typedef $$ImportPlatformsTableCreateCompanionBuilder =
    ImportPlatformsCompanion Function({
      Value<int> id,
      required String platform,
      required int importRecordCount,
      required int importCategoryCount,
      required int importTime,
      Value<bool> hidden,
    });
typedef $$ImportPlatformsTableUpdateCompanionBuilder =
    ImportPlatformsCompanion Function({
      Value<int> id,
      Value<String> platform,
      Value<int> importRecordCount,
      Value<int> importCategoryCount,
      Value<int> importTime,
      Value<bool> hidden,
    });

class $$ImportPlatformsTableFilterComposer
    extends Composer<_$AppDatabase, $ImportPlatformsTable> {
  $$ImportPlatformsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get platform => $composableBuilder(
    column: $table.platform,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get importRecordCount => $composableBuilder(
    column: $table.importRecordCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get importCategoryCount => $composableBuilder(
    column: $table.importCategoryCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get importTime => $composableBuilder(
    column: $table.importTime,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get hidden => $composableBuilder(
    column: $table.hidden,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ImportPlatformsTableOrderingComposer
    extends Composer<_$AppDatabase, $ImportPlatformsTable> {
  $$ImportPlatformsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get platform => $composableBuilder(
    column: $table.platform,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get importRecordCount => $composableBuilder(
    column: $table.importRecordCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get importCategoryCount => $composableBuilder(
    column: $table.importCategoryCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get importTime => $composableBuilder(
    column: $table.importTime,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get hidden => $composableBuilder(
    column: $table.hidden,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ImportPlatformsTableAnnotationComposer
    extends Composer<_$AppDatabase, $ImportPlatformsTable> {
  $$ImportPlatformsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get platform =>
      $composableBuilder(column: $table.platform, builder: (column) => column);

  GeneratedColumn<int> get importRecordCount => $composableBuilder(
    column: $table.importRecordCount,
    builder: (column) => column,
  );

  GeneratedColumn<int> get importCategoryCount => $composableBuilder(
    column: $table.importCategoryCount,
    builder: (column) => column,
  );

  GeneratedColumn<int> get importTime => $composableBuilder(
    column: $table.importTime,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get hidden =>
      $composableBuilder(column: $table.hidden, builder: (column) => column);
}

class $$ImportPlatformsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ImportPlatformsTable,
          ImportPlatform,
          $$ImportPlatformsTableFilterComposer,
          $$ImportPlatformsTableOrderingComposer,
          $$ImportPlatformsTableAnnotationComposer,
          $$ImportPlatformsTableCreateCompanionBuilder,
          $$ImportPlatformsTableUpdateCompanionBuilder,
          (
            ImportPlatform,
            BaseReferences<
              _$AppDatabase,
              $ImportPlatformsTable,
              ImportPlatform
            >,
          ),
          ImportPlatform,
          PrefetchHooks Function()
        > {
  $$ImportPlatformsTableTableManager(
    _$AppDatabase db,
    $ImportPlatformsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ImportPlatformsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ImportPlatformsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ImportPlatformsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> platform = const Value.absent(),
                Value<int> importRecordCount = const Value.absent(),
                Value<int> importCategoryCount = const Value.absent(),
                Value<int> importTime = const Value.absent(),
                Value<bool> hidden = const Value.absent(),
              }) => ImportPlatformsCompanion(
                id: id,
                platform: platform,
                importRecordCount: importRecordCount,
                importCategoryCount: importCategoryCount,
                importTime: importTime,
                hidden: hidden,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String platform,
                required int importRecordCount,
                required int importCategoryCount,
                required int importTime,
                Value<bool> hidden = const Value.absent(),
              }) => ImportPlatformsCompanion.insert(
                id: id,
                platform: platform,
                importRecordCount: importRecordCount,
                importCategoryCount: importCategoryCount,
                importTime: importTime,
                hidden: hidden,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ImportPlatformsTable, ImportPlatform>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $ImportPlatformsTable,
                    ImportPlatform
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ImportPlatformsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ImportPlatformsTable,
      ImportPlatform,
      $$ImportPlatformsTableFilterComposer,
      $$ImportPlatformsTableOrderingComposer,
      $$ImportPlatformsTableAnnotationComposer,
      $$ImportPlatformsTableCreateCompanionBuilder,
      $$ImportPlatformsTableUpdateCompanionBuilder,
      (
        ImportPlatform,
        BaseReferences<_$AppDatabase, $ImportPlatformsTable, ImportPlatform>,
      ),
      ImportPlatform,
      PrefetchHooks Function()
    >;
typedef $$RecordsTableCreateCompanionBuilder =
    RecordsCompanion Function({
      required String recordId,
      required int type,
      Value<int> subType,
      required BigInt moneyMinor,
      Value<String> remark,
      required int recordTime,
      Value<int> recordCatId,
      Value<int> assetId,
      Value<int> fromAssetId,
      Value<int> toAssetId,
      required int accountBookId,
      Value<bool> excludeBudget,
      Value<bool> excludeExIn,
      Value<int> platformId,
      Value<int> periodId,
      Value<String?> installment,
      Value<String?> images,
      Value<String?> relInfo,
      Value<BigInt?> discountMinor,
      Value<String?> extraInfo,
      Value<int?> createDate,
      Value<int> rowid,
    });
typedef $$RecordsTableUpdateCompanionBuilder =
    RecordsCompanion Function({
      Value<String> recordId,
      Value<int> type,
      Value<int> subType,
      Value<BigInt> moneyMinor,
      Value<String> remark,
      Value<int> recordTime,
      Value<int> recordCatId,
      Value<int> assetId,
      Value<int> fromAssetId,
      Value<int> toAssetId,
      Value<int> accountBookId,
      Value<bool> excludeBudget,
      Value<bool> excludeExIn,
      Value<int> platformId,
      Value<int> periodId,
      Value<String?> installment,
      Value<String?> images,
      Value<String?> relInfo,
      Value<BigInt?> discountMinor,
      Value<String?> extraInfo,
      Value<int?> createDate,
      Value<int> rowid,
    });

class $$RecordsTableFilterComposer
    extends Composer<_$AppDatabase, $RecordsTable> {
  $$RecordsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get recordId => $composableBuilder(
    column: $table.recordId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get subType => $composableBuilder(
    column: $table.subType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<BigInt> get moneyMinor => $composableBuilder(
    column: $table.moneyMinor,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get remark => $composableBuilder(
    column: $table.remark,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get recordTime => $composableBuilder(
    column: $table.recordTime,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get recordCatId => $composableBuilder(
    column: $table.recordCatId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get assetId => $composableBuilder(
    column: $table.assetId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get fromAssetId => $composableBuilder(
    column: $table.fromAssetId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get toAssetId => $composableBuilder(
    column: $table.toAssetId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get accountBookId => $composableBuilder(
    column: $table.accountBookId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get excludeBudget => $composableBuilder(
    column: $table.excludeBudget,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get excludeExIn => $composableBuilder(
    column: $table.excludeExIn,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get platformId => $composableBuilder(
    column: $table.platformId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get periodId => $composableBuilder(
    column: $table.periodId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get installment => $composableBuilder(
    column: $table.installment,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get images => $composableBuilder(
    column: $table.images,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get relInfo => $composableBuilder(
    column: $table.relInfo,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<BigInt> get discountMinor => $composableBuilder(
    column: $table.discountMinor,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get extraInfo => $composableBuilder(
    column: $table.extraInfo,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createDate => $composableBuilder(
    column: $table.createDate,
    builder: (column) => ColumnFilters(column),
  );
}

class $$RecordsTableOrderingComposer
    extends Composer<_$AppDatabase, $RecordsTable> {
  $$RecordsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get recordId => $composableBuilder(
    column: $table.recordId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get subType => $composableBuilder(
    column: $table.subType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<BigInt> get moneyMinor => $composableBuilder(
    column: $table.moneyMinor,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get remark => $composableBuilder(
    column: $table.remark,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get recordTime => $composableBuilder(
    column: $table.recordTime,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get recordCatId => $composableBuilder(
    column: $table.recordCatId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get assetId => $composableBuilder(
    column: $table.assetId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get fromAssetId => $composableBuilder(
    column: $table.fromAssetId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get toAssetId => $composableBuilder(
    column: $table.toAssetId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get accountBookId => $composableBuilder(
    column: $table.accountBookId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get excludeBudget => $composableBuilder(
    column: $table.excludeBudget,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get excludeExIn => $composableBuilder(
    column: $table.excludeExIn,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get platformId => $composableBuilder(
    column: $table.platformId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get periodId => $composableBuilder(
    column: $table.periodId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get installment => $composableBuilder(
    column: $table.installment,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get images => $composableBuilder(
    column: $table.images,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get relInfo => $composableBuilder(
    column: $table.relInfo,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<BigInt> get discountMinor => $composableBuilder(
    column: $table.discountMinor,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get extraInfo => $composableBuilder(
    column: $table.extraInfo,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createDate => $composableBuilder(
    column: $table.createDate,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$RecordsTableAnnotationComposer
    extends Composer<_$AppDatabase, $RecordsTable> {
  $$RecordsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get recordId =>
      $composableBuilder(column: $table.recordId, builder: (column) => column);

  GeneratedColumn<int> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<int> get subType =>
      $composableBuilder(column: $table.subType, builder: (column) => column);

  GeneratedColumn<BigInt> get moneyMinor => $composableBuilder(
    column: $table.moneyMinor,
    builder: (column) => column,
  );

  GeneratedColumn<String> get remark =>
      $composableBuilder(column: $table.remark, builder: (column) => column);

  GeneratedColumn<int> get recordTime => $composableBuilder(
    column: $table.recordTime,
    builder: (column) => column,
  );

  GeneratedColumn<int> get recordCatId => $composableBuilder(
    column: $table.recordCatId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get assetId =>
      $composableBuilder(column: $table.assetId, builder: (column) => column);

  GeneratedColumn<int> get fromAssetId => $composableBuilder(
    column: $table.fromAssetId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get toAssetId =>
      $composableBuilder(column: $table.toAssetId, builder: (column) => column);

  GeneratedColumn<int> get accountBookId => $composableBuilder(
    column: $table.accountBookId,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get excludeBudget => $composableBuilder(
    column: $table.excludeBudget,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get excludeExIn => $composableBuilder(
    column: $table.excludeExIn,
    builder: (column) => column,
  );

  GeneratedColumn<int> get platformId => $composableBuilder(
    column: $table.platformId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get periodId =>
      $composableBuilder(column: $table.periodId, builder: (column) => column);

  GeneratedColumn<String> get installment => $composableBuilder(
    column: $table.installment,
    builder: (column) => column,
  );

  GeneratedColumn<String> get images =>
      $composableBuilder(column: $table.images, builder: (column) => column);

  GeneratedColumn<String> get relInfo =>
      $composableBuilder(column: $table.relInfo, builder: (column) => column);

  GeneratedColumn<BigInt> get discountMinor => $composableBuilder(
    column: $table.discountMinor,
    builder: (column) => column,
  );

  GeneratedColumn<String> get extraInfo =>
      $composableBuilder(column: $table.extraInfo, builder: (column) => column);

  GeneratedColumn<int> get createDate => $composableBuilder(
    column: $table.createDate,
    builder: (column) => column,
  );
}

class $$RecordsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $RecordsTable,
          LedgerRecord,
          $$RecordsTableFilterComposer,
          $$RecordsTableOrderingComposer,
          $$RecordsTableAnnotationComposer,
          $$RecordsTableCreateCompanionBuilder,
          $$RecordsTableUpdateCompanionBuilder,
          (
            LedgerRecord,
            BaseReferences<_$AppDatabase, $RecordsTable, LedgerRecord>,
          ),
          LedgerRecord,
          PrefetchHooks Function()
        > {
  $$RecordsTableTableManager(_$AppDatabase db, $RecordsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$RecordsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$RecordsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$RecordsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> recordId = const Value.absent(),
                Value<int> type = const Value.absent(),
                Value<int> subType = const Value.absent(),
                Value<BigInt> moneyMinor = const Value.absent(),
                Value<String> remark = const Value.absent(),
                Value<int> recordTime = const Value.absent(),
                Value<int> recordCatId = const Value.absent(),
                Value<int> assetId = const Value.absent(),
                Value<int> fromAssetId = const Value.absent(),
                Value<int> toAssetId = const Value.absent(),
                Value<int> accountBookId = const Value.absent(),
                Value<bool> excludeBudget = const Value.absent(),
                Value<bool> excludeExIn = const Value.absent(),
                Value<int> platformId = const Value.absent(),
                Value<int> periodId = const Value.absent(),
                Value<String?> installment = const Value.absent(),
                Value<String?> images = const Value.absent(),
                Value<String?> relInfo = const Value.absent(),
                Value<BigInt?> discountMinor = const Value.absent(),
                Value<String?> extraInfo = const Value.absent(),
                Value<int?> createDate = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => RecordsCompanion(
                recordId: recordId,
                type: type,
                subType: subType,
                moneyMinor: moneyMinor,
                remark: remark,
                recordTime: recordTime,
                recordCatId: recordCatId,
                assetId: assetId,
                fromAssetId: fromAssetId,
                toAssetId: toAssetId,
                accountBookId: accountBookId,
                excludeBudget: excludeBudget,
                excludeExIn: excludeExIn,
                platformId: platformId,
                periodId: periodId,
                installment: installment,
                images: images,
                relInfo: relInfo,
                discountMinor: discountMinor,
                extraInfo: extraInfo,
                createDate: createDate,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String recordId,
                required int type,
                Value<int> subType = const Value.absent(),
                required BigInt moneyMinor,
                Value<String> remark = const Value.absent(),
                required int recordTime,
                Value<int> recordCatId = const Value.absent(),
                Value<int> assetId = const Value.absent(),
                Value<int> fromAssetId = const Value.absent(),
                Value<int> toAssetId = const Value.absent(),
                required int accountBookId,
                Value<bool> excludeBudget = const Value.absent(),
                Value<bool> excludeExIn = const Value.absent(),
                Value<int> platformId = const Value.absent(),
                Value<int> periodId = const Value.absent(),
                Value<String?> installment = const Value.absent(),
                Value<String?> images = const Value.absent(),
                Value<String?> relInfo = const Value.absent(),
                Value<BigInt?> discountMinor = const Value.absent(),
                Value<String?> extraInfo = const Value.absent(),
                Value<int?> createDate = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => RecordsCompanion.insert(
                recordId: recordId,
                type: type,
                subType: subType,
                moneyMinor: moneyMinor,
                remark: remark,
                recordTime: recordTime,
                recordCatId: recordCatId,
                assetId: assetId,
                fromAssetId: fromAssetId,
                toAssetId: toAssetId,
                accountBookId: accountBookId,
                excludeBudget: excludeBudget,
                excludeExIn: excludeExIn,
                platformId: platformId,
                periodId: periodId,
                installment: installment,
                images: images,
                relInfo: relInfo,
                discountMinor: discountMinor,
                extraInfo: extraInfo,
                createDate: createDate,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$RecordsTable, LedgerRecord>(table),
                  BaseReferences<_$AppDatabase, $RecordsTable, LedgerRecord>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$RecordsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $RecordsTable,
      LedgerRecord,
      $$RecordsTableFilterComposer,
      $$RecordsTableOrderingComposer,
      $$RecordsTableAnnotationComposer,
      $$RecordsTableCreateCompanionBuilder,
      $$RecordsTableUpdateCompanionBuilder,
      (
        LedgerRecord,
        BaseReferences<_$AppDatabase, $RecordsTable, LedgerRecord>,
      ),
      LedgerRecord,
      PrefetchHooks Function()
    >;
typedef $$RecordCategoriesTableCreateCompanionBuilder =
    RecordCategoriesCompanion Function({
      Value<int> id,
      required String name,
      Value<String> icon,
      required int type,
      Value<int> sort,
      Value<int> parentCatId,
      Value<String?> colorFill,
      Value<int> platformId,
      required int accountBookId,
      Value<bool> isHide,
      Value<String?> extraInfo,
    });
typedef $$RecordCategoriesTableUpdateCompanionBuilder =
    RecordCategoriesCompanion Function({
      Value<int> id,
      Value<String> name,
      Value<String> icon,
      Value<int> type,
      Value<int> sort,
      Value<int> parentCatId,
      Value<String?> colorFill,
      Value<int> platformId,
      Value<int> accountBookId,
      Value<bool> isHide,
      Value<String?> extraInfo,
    });

class $$RecordCategoriesTableFilterComposer
    extends Composer<_$AppDatabase, $RecordCategoriesTable> {
  $$RecordCategoriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get icon => $composableBuilder(
    column: $table.icon,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sort => $composableBuilder(
    column: $table.sort,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get parentCatId => $composableBuilder(
    column: $table.parentCatId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get colorFill => $composableBuilder(
    column: $table.colorFill,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get platformId => $composableBuilder(
    column: $table.platformId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get accountBookId => $composableBuilder(
    column: $table.accountBookId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isHide => $composableBuilder(
    column: $table.isHide,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get extraInfo => $composableBuilder(
    column: $table.extraInfo,
    builder: (column) => ColumnFilters(column),
  );
}

class $$RecordCategoriesTableOrderingComposer
    extends Composer<_$AppDatabase, $RecordCategoriesTable> {
  $$RecordCategoriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get icon => $composableBuilder(
    column: $table.icon,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sort => $composableBuilder(
    column: $table.sort,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get parentCatId => $composableBuilder(
    column: $table.parentCatId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get colorFill => $composableBuilder(
    column: $table.colorFill,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get platformId => $composableBuilder(
    column: $table.platformId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get accountBookId => $composableBuilder(
    column: $table.accountBookId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isHide => $composableBuilder(
    column: $table.isHide,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get extraInfo => $composableBuilder(
    column: $table.extraInfo,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$RecordCategoriesTableAnnotationComposer
    extends Composer<_$AppDatabase, $RecordCategoriesTable> {
  $$RecordCategoriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get icon =>
      $composableBuilder(column: $table.icon, builder: (column) => column);

  GeneratedColumn<int> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<int> get sort =>
      $composableBuilder(column: $table.sort, builder: (column) => column);

  GeneratedColumn<int> get parentCatId => $composableBuilder(
    column: $table.parentCatId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get colorFill =>
      $composableBuilder(column: $table.colorFill, builder: (column) => column);

  GeneratedColumn<int> get platformId => $composableBuilder(
    column: $table.platformId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get accountBookId => $composableBuilder(
    column: $table.accountBookId,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isHide =>
      $composableBuilder(column: $table.isHide, builder: (column) => column);

  GeneratedColumn<String> get extraInfo =>
      $composableBuilder(column: $table.extraInfo, builder: (column) => column);
}

class $$RecordCategoriesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $RecordCategoriesTable,
          RecordCategory,
          $$RecordCategoriesTableFilterComposer,
          $$RecordCategoriesTableOrderingComposer,
          $$RecordCategoriesTableAnnotationComposer,
          $$RecordCategoriesTableCreateCompanionBuilder,
          $$RecordCategoriesTableUpdateCompanionBuilder,
          (
            RecordCategory,
            BaseReferences<
              _$AppDatabase,
              $RecordCategoriesTable,
              RecordCategory
            >,
          ),
          RecordCategory,
          PrefetchHooks Function()
        > {
  $$RecordCategoriesTableTableManager(
    _$AppDatabase db,
    $RecordCategoriesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$RecordCategoriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$RecordCategoriesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$RecordCategoriesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> icon = const Value.absent(),
                Value<int> type = const Value.absent(),
                Value<int> sort = const Value.absent(),
                Value<int> parentCatId = const Value.absent(),
                Value<String?> colorFill = const Value.absent(),
                Value<int> platformId = const Value.absent(),
                Value<int> accountBookId = const Value.absent(),
                Value<bool> isHide = const Value.absent(),
                Value<String?> extraInfo = const Value.absent(),
              }) => RecordCategoriesCompanion(
                id: id,
                name: name,
                icon: icon,
                type: type,
                sort: sort,
                parentCatId: parentCatId,
                colorFill: colorFill,
                platformId: platformId,
                accountBookId: accountBookId,
                isHide: isHide,
                extraInfo: extraInfo,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String name,
                Value<String> icon = const Value.absent(),
                required int type,
                Value<int> sort = const Value.absent(),
                Value<int> parentCatId = const Value.absent(),
                Value<String?> colorFill = const Value.absent(),
                Value<int> platformId = const Value.absent(),
                required int accountBookId,
                Value<bool> isHide = const Value.absent(),
                Value<String?> extraInfo = const Value.absent(),
              }) => RecordCategoriesCompanion.insert(
                id: id,
                name: name,
                icon: icon,
                type: type,
                sort: sort,
                parentCatId: parentCatId,
                colorFill: colorFill,
                platformId: platformId,
                accountBookId: accountBookId,
                isHide: isHide,
                extraInfo: extraInfo,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$RecordCategoriesTable, RecordCategory>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $RecordCategoriesTable,
                    RecordCategory
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$RecordCategoriesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $RecordCategoriesTable,
      RecordCategory,
      $$RecordCategoriesTableFilterComposer,
      $$RecordCategoriesTableOrderingComposer,
      $$RecordCategoriesTableAnnotationComposer,
      $$RecordCategoriesTableCreateCompanionBuilder,
      $$RecordCategoriesTableUpdateCompanionBuilder,
      (
        RecordCategory,
        BaseReferences<_$AppDatabase, $RecordCategoriesTable, RecordCategory>,
      ),
      RecordCategory,
      PrefetchHooks Function()
    >;
typedef $$RemarksTableCreateCompanionBuilder =
    RemarksCompanion Function({
      Value<int> id,
      required String content,
      required int recordCatId,
      Value<int> usedTimes,
    });
typedef $$RemarksTableUpdateCompanionBuilder =
    RemarksCompanion Function({
      Value<int> id,
      Value<String> content,
      Value<int> recordCatId,
      Value<int> usedTimes,
    });

class $$RemarksTableFilterComposer
    extends Composer<_$AppDatabase, $RemarksTable> {
  $$RemarksTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get recordCatId => $composableBuilder(
    column: $table.recordCatId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get usedTimes => $composableBuilder(
    column: $table.usedTimes,
    builder: (column) => ColumnFilters(column),
  );
}

class $$RemarksTableOrderingComposer
    extends Composer<_$AppDatabase, $RemarksTable> {
  $$RemarksTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get recordCatId => $composableBuilder(
    column: $table.recordCatId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get usedTimes => $composableBuilder(
    column: $table.usedTimes,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$RemarksTableAnnotationComposer
    extends Composer<_$AppDatabase, $RemarksTable> {
  $$RemarksTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get content =>
      $composableBuilder(column: $table.content, builder: (column) => column);

  GeneratedColumn<int> get recordCatId => $composableBuilder(
    column: $table.recordCatId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get usedTimes =>
      $composableBuilder(column: $table.usedTimes, builder: (column) => column);
}

class $$RemarksTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $RemarksTable,
          Remark,
          $$RemarksTableFilterComposer,
          $$RemarksTableOrderingComposer,
          $$RemarksTableAnnotationComposer,
          $$RemarksTableCreateCompanionBuilder,
          $$RemarksTableUpdateCompanionBuilder,
          (Remark, BaseReferences<_$AppDatabase, $RemarksTable, Remark>),
          Remark,
          PrefetchHooks Function()
        > {
  $$RemarksTableTableManager(_$AppDatabase db, $RemarksTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$RemarksTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$RemarksTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$RemarksTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> content = const Value.absent(),
                Value<int> recordCatId = const Value.absent(),
                Value<int> usedTimes = const Value.absent(),
              }) => RemarksCompanion(
                id: id,
                content: content,
                recordCatId: recordCatId,
                usedTimes: usedTimes,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String content,
                required int recordCatId,
                Value<int> usedTimes = const Value.absent(),
              }) => RemarksCompanion.insert(
                id: id,
                content: content,
                recordCatId: recordCatId,
                usedTimes: usedTimes,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$RemarksTable, Remark>(table),
                  BaseReferences<_$AppDatabase, $RemarksTable, Remark>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$RemarksTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $RemarksTable,
      Remark,
      $$RemarksTableFilterComposer,
      $$RemarksTableOrderingComposer,
      $$RemarksTableAnnotationComposer,
      $$RemarksTableCreateCompanionBuilder,
      $$RemarksTableUpdateCompanionBuilder,
      (Remark, BaseReferences<_$AppDatabase, $RemarksTable, Remark>),
      Remark,
      PrefetchHooks Function()
    >;
typedef $$RecordTemplatesTableCreateCompanionBuilder =
    RecordTemplatesCompanion Function({
      Value<int> id,
      required int type,
      Value<String?> remark,
      required BigInt moneyMinor,
      Value<BigInt> feeMinor,
      Value<int?> recordCatId,
      Value<int> assetId,
      Value<int> assetId2,
      Value<int> sort,
      Value<bool> autoSave,
      required int bookId,
      Value<bool> excludeBudget,
      Value<bool> excludeExIn,
      required int createDate,
      Value<String?> tags,
      Value<String?> exi,
    });
typedef $$RecordTemplatesTableUpdateCompanionBuilder =
    RecordTemplatesCompanion Function({
      Value<int> id,
      Value<int> type,
      Value<String?> remark,
      Value<BigInt> moneyMinor,
      Value<BigInt> feeMinor,
      Value<int?> recordCatId,
      Value<int> assetId,
      Value<int> assetId2,
      Value<int> sort,
      Value<bool> autoSave,
      Value<int> bookId,
      Value<bool> excludeBudget,
      Value<bool> excludeExIn,
      Value<int> createDate,
      Value<String?> tags,
      Value<String?> exi,
    });

class $$RecordTemplatesTableFilterComposer
    extends Composer<_$AppDatabase, $RecordTemplatesTable> {
  $$RecordTemplatesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get remark => $composableBuilder(
    column: $table.remark,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<BigInt> get moneyMinor => $composableBuilder(
    column: $table.moneyMinor,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<BigInt> get feeMinor => $composableBuilder(
    column: $table.feeMinor,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get recordCatId => $composableBuilder(
    column: $table.recordCatId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get assetId => $composableBuilder(
    column: $table.assetId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get assetId2 => $composableBuilder(
    column: $table.assetId2,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sort => $composableBuilder(
    column: $table.sort,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get autoSave => $composableBuilder(
    column: $table.autoSave,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get bookId => $composableBuilder(
    column: $table.bookId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get excludeBudget => $composableBuilder(
    column: $table.excludeBudget,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get excludeExIn => $composableBuilder(
    column: $table.excludeExIn,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createDate => $composableBuilder(
    column: $table.createDate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get tags => $composableBuilder(
    column: $table.tags,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get exi => $composableBuilder(
    column: $table.exi,
    builder: (column) => ColumnFilters(column),
  );
}

class $$RecordTemplatesTableOrderingComposer
    extends Composer<_$AppDatabase, $RecordTemplatesTable> {
  $$RecordTemplatesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get remark => $composableBuilder(
    column: $table.remark,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<BigInt> get moneyMinor => $composableBuilder(
    column: $table.moneyMinor,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<BigInt> get feeMinor => $composableBuilder(
    column: $table.feeMinor,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get recordCatId => $composableBuilder(
    column: $table.recordCatId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get assetId => $composableBuilder(
    column: $table.assetId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get assetId2 => $composableBuilder(
    column: $table.assetId2,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sort => $composableBuilder(
    column: $table.sort,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get autoSave => $composableBuilder(
    column: $table.autoSave,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get bookId => $composableBuilder(
    column: $table.bookId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get excludeBudget => $composableBuilder(
    column: $table.excludeBudget,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get excludeExIn => $composableBuilder(
    column: $table.excludeExIn,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createDate => $composableBuilder(
    column: $table.createDate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tags => $composableBuilder(
    column: $table.tags,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get exi => $composableBuilder(
    column: $table.exi,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$RecordTemplatesTableAnnotationComposer
    extends Composer<_$AppDatabase, $RecordTemplatesTable> {
  $$RecordTemplatesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<String> get remark =>
      $composableBuilder(column: $table.remark, builder: (column) => column);

  GeneratedColumn<BigInt> get moneyMinor => $composableBuilder(
    column: $table.moneyMinor,
    builder: (column) => column,
  );

  GeneratedColumn<BigInt> get feeMinor =>
      $composableBuilder(column: $table.feeMinor, builder: (column) => column);

  GeneratedColumn<int> get recordCatId => $composableBuilder(
    column: $table.recordCatId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get assetId =>
      $composableBuilder(column: $table.assetId, builder: (column) => column);

  GeneratedColumn<int> get assetId2 =>
      $composableBuilder(column: $table.assetId2, builder: (column) => column);

  GeneratedColumn<int> get sort =>
      $composableBuilder(column: $table.sort, builder: (column) => column);

  GeneratedColumn<bool> get autoSave =>
      $composableBuilder(column: $table.autoSave, builder: (column) => column);

  GeneratedColumn<int> get bookId =>
      $composableBuilder(column: $table.bookId, builder: (column) => column);

  GeneratedColumn<bool> get excludeBudget => $composableBuilder(
    column: $table.excludeBudget,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get excludeExIn => $composableBuilder(
    column: $table.excludeExIn,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createDate => $composableBuilder(
    column: $table.createDate,
    builder: (column) => column,
  );

  GeneratedColumn<String> get tags =>
      $composableBuilder(column: $table.tags, builder: (column) => column);

  GeneratedColumn<String> get exi =>
      $composableBuilder(column: $table.exi, builder: (column) => column);
}

class $$RecordTemplatesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $RecordTemplatesTable,
          RecordTemplate,
          $$RecordTemplatesTableFilterComposer,
          $$RecordTemplatesTableOrderingComposer,
          $$RecordTemplatesTableAnnotationComposer,
          $$RecordTemplatesTableCreateCompanionBuilder,
          $$RecordTemplatesTableUpdateCompanionBuilder,
          (
            RecordTemplate,
            BaseReferences<
              _$AppDatabase,
              $RecordTemplatesTable,
              RecordTemplate
            >,
          ),
          RecordTemplate,
          PrefetchHooks Function()
        > {
  $$RecordTemplatesTableTableManager(
    _$AppDatabase db,
    $RecordTemplatesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$RecordTemplatesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$RecordTemplatesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$RecordTemplatesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> type = const Value.absent(),
                Value<String?> remark = const Value.absent(),
                Value<BigInt> moneyMinor = const Value.absent(),
                Value<BigInt> feeMinor = const Value.absent(),
                Value<int?> recordCatId = const Value.absent(),
                Value<int> assetId = const Value.absent(),
                Value<int> assetId2 = const Value.absent(),
                Value<int> sort = const Value.absent(),
                Value<bool> autoSave = const Value.absent(),
                Value<int> bookId = const Value.absent(),
                Value<bool> excludeBudget = const Value.absent(),
                Value<bool> excludeExIn = const Value.absent(),
                Value<int> createDate = const Value.absent(),
                Value<String?> tags = const Value.absent(),
                Value<String?> exi = const Value.absent(),
              }) => RecordTemplatesCompanion(
                id: id,
                type: type,
                remark: remark,
                moneyMinor: moneyMinor,
                feeMinor: feeMinor,
                recordCatId: recordCatId,
                assetId: assetId,
                assetId2: assetId2,
                sort: sort,
                autoSave: autoSave,
                bookId: bookId,
                excludeBudget: excludeBudget,
                excludeExIn: excludeExIn,
                createDate: createDate,
                tags: tags,
                exi: exi,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int type,
                Value<String?> remark = const Value.absent(),
                required BigInt moneyMinor,
                Value<BigInt> feeMinor = const Value.absent(),
                Value<int?> recordCatId = const Value.absent(),
                Value<int> assetId = const Value.absent(),
                Value<int> assetId2 = const Value.absent(),
                Value<int> sort = const Value.absent(),
                Value<bool> autoSave = const Value.absent(),
                required int bookId,
                Value<bool> excludeBudget = const Value.absent(),
                Value<bool> excludeExIn = const Value.absent(),
                required int createDate,
                Value<String?> tags = const Value.absent(),
                Value<String?> exi = const Value.absent(),
              }) => RecordTemplatesCompanion.insert(
                id: id,
                type: type,
                remark: remark,
                moneyMinor: moneyMinor,
                feeMinor: feeMinor,
                recordCatId: recordCatId,
                assetId: assetId,
                assetId2: assetId2,
                sort: sort,
                autoSave: autoSave,
                bookId: bookId,
                excludeBudget: excludeBudget,
                excludeExIn: excludeExIn,
                createDate: createDate,
                tags: tags,
                exi: exi,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$RecordTemplatesTable, RecordTemplate>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $RecordTemplatesTable,
                    RecordTemplate
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$RecordTemplatesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $RecordTemplatesTable,
      RecordTemplate,
      $$RecordTemplatesTableFilterComposer,
      $$RecordTemplatesTableOrderingComposer,
      $$RecordTemplatesTableAnnotationComposer,
      $$RecordTemplatesTableCreateCompanionBuilder,
      $$RecordTemplatesTableUpdateCompanionBuilder,
      (
        RecordTemplate,
        BaseReferences<_$AppDatabase, $RecordTemplatesTable, RecordTemplate>,
      ),
      RecordTemplate,
      PrefetchHooks Function()
    >;
typedef $$WishesTableCreateCompanionBuilder =
    WishesCompanion Function({
      required String id,
      required String content,
      required BigInt valueMinor,
      required int createDate,
      Value<bool> isRealized,
      Value<int> realizedDate,
      Value<int> sort,
      Value<String?> icon,
      Value<int> targetDate,
      Value<int> rowid,
    });
typedef $$WishesTableUpdateCompanionBuilder =
    WishesCompanion Function({
      Value<String> id,
      Value<String> content,
      Value<BigInt> valueMinor,
      Value<int> createDate,
      Value<bool> isRealized,
      Value<int> realizedDate,
      Value<int> sort,
      Value<String?> icon,
      Value<int> targetDate,
      Value<int> rowid,
    });

class $$WishesTableFilterComposer
    extends Composer<_$AppDatabase, $WishesTable> {
  $$WishesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<BigInt> get valueMinor => $composableBuilder(
    column: $table.valueMinor,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createDate => $composableBuilder(
    column: $table.createDate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isRealized => $composableBuilder(
    column: $table.isRealized,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get realizedDate => $composableBuilder(
    column: $table.realizedDate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sort => $composableBuilder(
    column: $table.sort,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get icon => $composableBuilder(
    column: $table.icon,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get targetDate => $composableBuilder(
    column: $table.targetDate,
    builder: (column) => ColumnFilters(column),
  );
}

class $$WishesTableOrderingComposer
    extends Composer<_$AppDatabase, $WishesTable> {
  $$WishesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<BigInt> get valueMinor => $composableBuilder(
    column: $table.valueMinor,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createDate => $composableBuilder(
    column: $table.createDate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isRealized => $composableBuilder(
    column: $table.isRealized,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get realizedDate => $composableBuilder(
    column: $table.realizedDate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sort => $composableBuilder(
    column: $table.sort,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get icon => $composableBuilder(
    column: $table.icon,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get targetDate => $composableBuilder(
    column: $table.targetDate,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$WishesTableAnnotationComposer
    extends Composer<_$AppDatabase, $WishesTable> {
  $$WishesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get content =>
      $composableBuilder(column: $table.content, builder: (column) => column);

  GeneratedColumn<BigInt> get valueMinor => $composableBuilder(
    column: $table.valueMinor,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createDate => $composableBuilder(
    column: $table.createDate,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isRealized => $composableBuilder(
    column: $table.isRealized,
    builder: (column) => column,
  );

  GeneratedColumn<int> get realizedDate => $composableBuilder(
    column: $table.realizedDate,
    builder: (column) => column,
  );

  GeneratedColumn<int> get sort =>
      $composableBuilder(column: $table.sort, builder: (column) => column);

  GeneratedColumn<String> get icon =>
      $composableBuilder(column: $table.icon, builder: (column) => column);

  GeneratedColumn<int> get targetDate => $composableBuilder(
    column: $table.targetDate,
    builder: (column) => column,
  );
}

class $$WishesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $WishesTable,
          Wish,
          $$WishesTableFilterComposer,
          $$WishesTableOrderingComposer,
          $$WishesTableAnnotationComposer,
          $$WishesTableCreateCompanionBuilder,
          $$WishesTableUpdateCompanionBuilder,
          (Wish, BaseReferences<_$AppDatabase, $WishesTable, Wish>),
          Wish,
          PrefetchHooks Function()
        > {
  $$WishesTableTableManager(_$AppDatabase db, $WishesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$WishesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$WishesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$WishesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> content = const Value.absent(),
                Value<BigInt> valueMinor = const Value.absent(),
                Value<int> createDate = const Value.absent(),
                Value<bool> isRealized = const Value.absent(),
                Value<int> realizedDate = const Value.absent(),
                Value<int> sort = const Value.absent(),
                Value<String?> icon = const Value.absent(),
                Value<int> targetDate = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => WishesCompanion(
                id: id,
                content: content,
                valueMinor: valueMinor,
                createDate: createDate,
                isRealized: isRealized,
                realizedDate: realizedDate,
                sort: sort,
                icon: icon,
                targetDate: targetDate,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String content,
                required BigInt valueMinor,
                required int createDate,
                Value<bool> isRealized = const Value.absent(),
                Value<int> realizedDate = const Value.absent(),
                Value<int> sort = const Value.absent(),
                Value<String?> icon = const Value.absent(),
                Value<int> targetDate = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => WishesCompanion.insert(
                id: id,
                content: content,
                valueMinor: valueMinor,
                createDate: createDate,
                isRealized: isRealized,
                realizedDate: realizedDate,
                sort: sort,
                icon: icon,
                targetDate: targetDate,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$WishesTable, Wish>(table),
                  BaseReferences<_$AppDatabase, $WishesTable, Wish>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$WishesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $WishesTable,
      Wish,
      $$WishesTableFilterComposer,
      $$WishesTableOrderingComposer,
      $$WishesTableAnnotationComposer,
      $$WishesTableCreateCompanionBuilder,
      $$WishesTableUpdateCompanionBuilder,
      (Wish, BaseReferences<_$AppDatabase, $WishesTable, Wish>),
      Wish,
      PrefetchHooks Function()
    >;
typedef $$RecordPeriodsTableCreateCompanionBuilder =
    RecordPeriodsCompanion Function({
      Value<int> id,
      required int recordType,
      required BigInt moneyMinor,
      Value<BigInt> feeMinor,
      Value<String> remark,
      Value<int> catId,
      Value<int> assetId,
      Value<int> assetId2,
      required int bookId,
      Value<String?> images,
      Value<int> state,
      Value<String?> time,
      Value<bool> excludeBudget,
      Value<bool> excludeExIn,
      required int periodType,
      required String periodTypeDate,
      required int periodStartDate,
      required int periodEndDate,
      Value<int> frequency,
      Value<int> lastAddDate,
      Value<int> periodAddTimes,
      required int createTime,
      Value<String?> tags,
      Value<String?> exi,
    });
typedef $$RecordPeriodsTableUpdateCompanionBuilder =
    RecordPeriodsCompanion Function({
      Value<int> id,
      Value<int> recordType,
      Value<BigInt> moneyMinor,
      Value<BigInt> feeMinor,
      Value<String> remark,
      Value<int> catId,
      Value<int> assetId,
      Value<int> assetId2,
      Value<int> bookId,
      Value<String?> images,
      Value<int> state,
      Value<String?> time,
      Value<bool> excludeBudget,
      Value<bool> excludeExIn,
      Value<int> periodType,
      Value<String> periodTypeDate,
      Value<int> periodStartDate,
      Value<int> periodEndDate,
      Value<int> frequency,
      Value<int> lastAddDate,
      Value<int> periodAddTimes,
      Value<int> createTime,
      Value<String?> tags,
      Value<String?> exi,
    });

class $$RecordPeriodsTableFilterComposer
    extends Composer<_$AppDatabase, $RecordPeriodsTable> {
  $$RecordPeriodsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get recordType => $composableBuilder(
    column: $table.recordType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<BigInt> get moneyMinor => $composableBuilder(
    column: $table.moneyMinor,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<BigInt> get feeMinor => $composableBuilder(
    column: $table.feeMinor,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get remark => $composableBuilder(
    column: $table.remark,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get catId => $composableBuilder(
    column: $table.catId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get assetId => $composableBuilder(
    column: $table.assetId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get assetId2 => $composableBuilder(
    column: $table.assetId2,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get bookId => $composableBuilder(
    column: $table.bookId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get images => $composableBuilder(
    column: $table.images,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get time => $composableBuilder(
    column: $table.time,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get excludeBudget => $composableBuilder(
    column: $table.excludeBudget,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get excludeExIn => $composableBuilder(
    column: $table.excludeExIn,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get periodType => $composableBuilder(
    column: $table.periodType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get periodTypeDate => $composableBuilder(
    column: $table.periodTypeDate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get periodStartDate => $composableBuilder(
    column: $table.periodStartDate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get periodEndDate => $composableBuilder(
    column: $table.periodEndDate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get frequency => $composableBuilder(
    column: $table.frequency,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastAddDate => $composableBuilder(
    column: $table.lastAddDate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get periodAddTimes => $composableBuilder(
    column: $table.periodAddTimes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createTime => $composableBuilder(
    column: $table.createTime,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get tags => $composableBuilder(
    column: $table.tags,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get exi => $composableBuilder(
    column: $table.exi,
    builder: (column) => ColumnFilters(column),
  );
}

class $$RecordPeriodsTableOrderingComposer
    extends Composer<_$AppDatabase, $RecordPeriodsTable> {
  $$RecordPeriodsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get recordType => $composableBuilder(
    column: $table.recordType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<BigInt> get moneyMinor => $composableBuilder(
    column: $table.moneyMinor,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<BigInt> get feeMinor => $composableBuilder(
    column: $table.feeMinor,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get remark => $composableBuilder(
    column: $table.remark,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get catId => $composableBuilder(
    column: $table.catId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get assetId => $composableBuilder(
    column: $table.assetId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get assetId2 => $composableBuilder(
    column: $table.assetId2,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get bookId => $composableBuilder(
    column: $table.bookId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get images => $composableBuilder(
    column: $table.images,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get time => $composableBuilder(
    column: $table.time,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get excludeBudget => $composableBuilder(
    column: $table.excludeBudget,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get excludeExIn => $composableBuilder(
    column: $table.excludeExIn,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get periodType => $composableBuilder(
    column: $table.periodType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get periodTypeDate => $composableBuilder(
    column: $table.periodTypeDate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get periodStartDate => $composableBuilder(
    column: $table.periodStartDate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get periodEndDate => $composableBuilder(
    column: $table.periodEndDate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get frequency => $composableBuilder(
    column: $table.frequency,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastAddDate => $composableBuilder(
    column: $table.lastAddDate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get periodAddTimes => $composableBuilder(
    column: $table.periodAddTimes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createTime => $composableBuilder(
    column: $table.createTime,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tags => $composableBuilder(
    column: $table.tags,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get exi => $composableBuilder(
    column: $table.exi,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$RecordPeriodsTableAnnotationComposer
    extends Composer<_$AppDatabase, $RecordPeriodsTable> {
  $$RecordPeriodsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get recordType => $composableBuilder(
    column: $table.recordType,
    builder: (column) => column,
  );

  GeneratedColumn<BigInt> get moneyMinor => $composableBuilder(
    column: $table.moneyMinor,
    builder: (column) => column,
  );

  GeneratedColumn<BigInt> get feeMinor =>
      $composableBuilder(column: $table.feeMinor, builder: (column) => column);

  GeneratedColumn<String> get remark =>
      $composableBuilder(column: $table.remark, builder: (column) => column);

  GeneratedColumn<int> get catId =>
      $composableBuilder(column: $table.catId, builder: (column) => column);

  GeneratedColumn<int> get assetId =>
      $composableBuilder(column: $table.assetId, builder: (column) => column);

  GeneratedColumn<int> get assetId2 =>
      $composableBuilder(column: $table.assetId2, builder: (column) => column);

  GeneratedColumn<int> get bookId =>
      $composableBuilder(column: $table.bookId, builder: (column) => column);

  GeneratedColumn<String> get images =>
      $composableBuilder(column: $table.images, builder: (column) => column);

  GeneratedColumn<int> get state =>
      $composableBuilder(column: $table.state, builder: (column) => column);

  GeneratedColumn<String> get time =>
      $composableBuilder(column: $table.time, builder: (column) => column);

  GeneratedColumn<bool> get excludeBudget => $composableBuilder(
    column: $table.excludeBudget,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get excludeExIn => $composableBuilder(
    column: $table.excludeExIn,
    builder: (column) => column,
  );

  GeneratedColumn<int> get periodType => $composableBuilder(
    column: $table.periodType,
    builder: (column) => column,
  );

  GeneratedColumn<String> get periodTypeDate => $composableBuilder(
    column: $table.periodTypeDate,
    builder: (column) => column,
  );

  GeneratedColumn<int> get periodStartDate => $composableBuilder(
    column: $table.periodStartDate,
    builder: (column) => column,
  );

  GeneratedColumn<int> get periodEndDate => $composableBuilder(
    column: $table.periodEndDate,
    builder: (column) => column,
  );

  GeneratedColumn<int> get frequency =>
      $composableBuilder(column: $table.frequency, builder: (column) => column);

  GeneratedColumn<int> get lastAddDate => $composableBuilder(
    column: $table.lastAddDate,
    builder: (column) => column,
  );

  GeneratedColumn<int> get periodAddTimes => $composableBuilder(
    column: $table.periodAddTimes,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createTime => $composableBuilder(
    column: $table.createTime,
    builder: (column) => column,
  );

  GeneratedColumn<String> get tags =>
      $composableBuilder(column: $table.tags, builder: (column) => column);

  GeneratedColumn<String> get exi =>
      $composableBuilder(column: $table.exi, builder: (column) => column);
}

class $$RecordPeriodsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $RecordPeriodsTable,
          RecordPeriod,
          $$RecordPeriodsTableFilterComposer,
          $$RecordPeriodsTableOrderingComposer,
          $$RecordPeriodsTableAnnotationComposer,
          $$RecordPeriodsTableCreateCompanionBuilder,
          $$RecordPeriodsTableUpdateCompanionBuilder,
          (
            RecordPeriod,
            BaseReferences<_$AppDatabase, $RecordPeriodsTable, RecordPeriod>,
          ),
          RecordPeriod,
          PrefetchHooks Function()
        > {
  $$RecordPeriodsTableTableManager(_$AppDatabase db, $RecordPeriodsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$RecordPeriodsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$RecordPeriodsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$RecordPeriodsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> recordType = const Value.absent(),
                Value<BigInt> moneyMinor = const Value.absent(),
                Value<BigInt> feeMinor = const Value.absent(),
                Value<String> remark = const Value.absent(),
                Value<int> catId = const Value.absent(),
                Value<int> assetId = const Value.absent(),
                Value<int> assetId2 = const Value.absent(),
                Value<int> bookId = const Value.absent(),
                Value<String?> images = const Value.absent(),
                Value<int> state = const Value.absent(),
                Value<String?> time = const Value.absent(),
                Value<bool> excludeBudget = const Value.absent(),
                Value<bool> excludeExIn = const Value.absent(),
                Value<int> periodType = const Value.absent(),
                Value<String> periodTypeDate = const Value.absent(),
                Value<int> periodStartDate = const Value.absent(),
                Value<int> periodEndDate = const Value.absent(),
                Value<int> frequency = const Value.absent(),
                Value<int> lastAddDate = const Value.absent(),
                Value<int> periodAddTimes = const Value.absent(),
                Value<int> createTime = const Value.absent(),
                Value<String?> tags = const Value.absent(),
                Value<String?> exi = const Value.absent(),
              }) => RecordPeriodsCompanion(
                id: id,
                recordType: recordType,
                moneyMinor: moneyMinor,
                feeMinor: feeMinor,
                remark: remark,
                catId: catId,
                assetId: assetId,
                assetId2: assetId2,
                bookId: bookId,
                images: images,
                state: state,
                time: time,
                excludeBudget: excludeBudget,
                excludeExIn: excludeExIn,
                periodType: periodType,
                periodTypeDate: periodTypeDate,
                periodStartDate: periodStartDate,
                periodEndDate: periodEndDate,
                frequency: frequency,
                lastAddDate: lastAddDate,
                periodAddTimes: periodAddTimes,
                createTime: createTime,
                tags: tags,
                exi: exi,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int recordType,
                required BigInt moneyMinor,
                Value<BigInt> feeMinor = const Value.absent(),
                Value<String> remark = const Value.absent(),
                Value<int> catId = const Value.absent(),
                Value<int> assetId = const Value.absent(),
                Value<int> assetId2 = const Value.absent(),
                required int bookId,
                Value<String?> images = const Value.absent(),
                Value<int> state = const Value.absent(),
                Value<String?> time = const Value.absent(),
                Value<bool> excludeBudget = const Value.absent(),
                Value<bool> excludeExIn = const Value.absent(),
                required int periodType,
                required String periodTypeDate,
                required int periodStartDate,
                required int periodEndDate,
                Value<int> frequency = const Value.absent(),
                Value<int> lastAddDate = const Value.absent(),
                Value<int> periodAddTimes = const Value.absent(),
                required int createTime,
                Value<String?> tags = const Value.absent(),
                Value<String?> exi = const Value.absent(),
              }) => RecordPeriodsCompanion.insert(
                id: id,
                recordType: recordType,
                moneyMinor: moneyMinor,
                feeMinor: feeMinor,
                remark: remark,
                catId: catId,
                assetId: assetId,
                assetId2: assetId2,
                bookId: bookId,
                images: images,
                state: state,
                time: time,
                excludeBudget: excludeBudget,
                excludeExIn: excludeExIn,
                periodType: periodType,
                periodTypeDate: periodTypeDate,
                periodStartDate: periodStartDate,
                periodEndDate: periodEndDate,
                frequency: frequency,
                lastAddDate: lastAddDate,
                periodAddTimes: periodAddTimes,
                createTime: createTime,
                tags: tags,
                exi: exi,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$RecordPeriodsTable, RecordPeriod>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $RecordPeriodsTable,
                    RecordPeriod
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$RecordPeriodsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $RecordPeriodsTable,
      RecordPeriod,
      $$RecordPeriodsTableFilterComposer,
      $$RecordPeriodsTableOrderingComposer,
      $$RecordPeriodsTableAnnotationComposer,
      $$RecordPeriodsTableCreateCompanionBuilder,
      $$RecordPeriodsTableUpdateCompanionBuilder,
      (
        RecordPeriod,
        BaseReferences<_$AppDatabase, $RecordPeriodsTable, RecordPeriod>,
      ),
      RecordPeriod,
      PrefetchHooks Function()
    >;
typedef $$ReminderEventsTableCreateCompanionBuilder =
    ReminderEventsCompanion Function({
      Value<int> id,
      required int reminderTime,
      Value<String?> reminderTip,
    });
typedef $$ReminderEventsTableUpdateCompanionBuilder =
    ReminderEventsCompanion Function({
      Value<int> id,
      Value<int> reminderTime,
      Value<String?> reminderTip,
    });

class $$ReminderEventsTableFilterComposer
    extends Composer<_$AppDatabase, $ReminderEventsTable> {
  $$ReminderEventsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get reminderTime => $composableBuilder(
    column: $table.reminderTime,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get reminderTip => $composableBuilder(
    column: $table.reminderTip,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ReminderEventsTableOrderingComposer
    extends Composer<_$AppDatabase, $ReminderEventsTable> {
  $$ReminderEventsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get reminderTime => $composableBuilder(
    column: $table.reminderTime,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get reminderTip => $composableBuilder(
    column: $table.reminderTip,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ReminderEventsTableAnnotationComposer
    extends Composer<_$AppDatabase, $ReminderEventsTable> {
  $$ReminderEventsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get reminderTime => $composableBuilder(
    column: $table.reminderTime,
    builder: (column) => column,
  );

  GeneratedColumn<String> get reminderTip => $composableBuilder(
    column: $table.reminderTip,
    builder: (column) => column,
  );
}

class $$ReminderEventsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ReminderEventsTable,
          ReminderEvent,
          $$ReminderEventsTableFilterComposer,
          $$ReminderEventsTableOrderingComposer,
          $$ReminderEventsTableAnnotationComposer,
          $$ReminderEventsTableCreateCompanionBuilder,
          $$ReminderEventsTableUpdateCompanionBuilder,
          (
            ReminderEvent,
            BaseReferences<_$AppDatabase, $ReminderEventsTable, ReminderEvent>,
          ),
          ReminderEvent,
          PrefetchHooks Function()
        > {
  $$ReminderEventsTableTableManager(
    _$AppDatabase db,
    $ReminderEventsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ReminderEventsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ReminderEventsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ReminderEventsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> reminderTime = const Value.absent(),
                Value<String?> reminderTip = const Value.absent(),
              }) => ReminderEventsCompanion(
                id: id,
                reminderTime: reminderTime,
                reminderTip: reminderTip,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int reminderTime,
                Value<String?> reminderTip = const Value.absent(),
              }) => ReminderEventsCompanion.insert(
                id: id,
                reminderTime: reminderTime,
                reminderTip: reminderTip,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ReminderEventsTable, ReminderEvent>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $ReminderEventsTable,
                    ReminderEvent
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ReminderEventsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ReminderEventsTable,
      ReminderEvent,
      $$ReminderEventsTableFilterComposer,
      $$ReminderEventsTableOrderingComposer,
      $$ReminderEventsTableAnnotationComposer,
      $$ReminderEventsTableCreateCompanionBuilder,
      $$ReminderEventsTableUpdateCompanionBuilder,
      (
        ReminderEvent,
        BaseReferences<_$AppDatabase, $ReminderEventsTable, ReminderEvent>,
      ),
      ReminderEvent,
      PrefetchHooks Function()
    >;
typedef $$InstallmentsTableCreateCompanionBuilder =
    InstallmentsCompanion Function({
      Value<int> id,
      required String name,
      Value<int> catId,
      required BigInt principalMinor,
      required int periods,
      required BigInt chargeMinor,
      required int chargeWay,
      required int remainderIn,
      required int calWay,
      required int startDate,
      required int assetId,
      required int nextPeriod,
      required int nextPeriodDate,
      Value<String?> credited,
      required int bookId,
      Value<bool> excludeBudget,
      Value<bool> excludeExIn,
      required int createDate,
      Value<String?> tags,
      Value<String?> images,
      Value<String?> exi,
    });
typedef $$InstallmentsTableUpdateCompanionBuilder =
    InstallmentsCompanion Function({
      Value<int> id,
      Value<String> name,
      Value<int> catId,
      Value<BigInt> principalMinor,
      Value<int> periods,
      Value<BigInt> chargeMinor,
      Value<int> chargeWay,
      Value<int> remainderIn,
      Value<int> calWay,
      Value<int> startDate,
      Value<int> assetId,
      Value<int> nextPeriod,
      Value<int> nextPeriodDate,
      Value<String?> credited,
      Value<int> bookId,
      Value<bool> excludeBudget,
      Value<bool> excludeExIn,
      Value<int> createDate,
      Value<String?> tags,
      Value<String?> images,
      Value<String?> exi,
    });

class $$InstallmentsTableFilterComposer
    extends Composer<_$AppDatabase, $InstallmentsTable> {
  $$InstallmentsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get catId => $composableBuilder(
    column: $table.catId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<BigInt> get principalMinor => $composableBuilder(
    column: $table.principalMinor,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get periods => $composableBuilder(
    column: $table.periods,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<BigInt> get chargeMinor => $composableBuilder(
    column: $table.chargeMinor,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get chargeWay => $composableBuilder(
    column: $table.chargeWay,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get remainderIn => $composableBuilder(
    column: $table.remainderIn,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get calWay => $composableBuilder(
    column: $table.calWay,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get startDate => $composableBuilder(
    column: $table.startDate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get assetId => $composableBuilder(
    column: $table.assetId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get nextPeriod => $composableBuilder(
    column: $table.nextPeriod,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get nextPeriodDate => $composableBuilder(
    column: $table.nextPeriodDate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get credited => $composableBuilder(
    column: $table.credited,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get bookId => $composableBuilder(
    column: $table.bookId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get excludeBudget => $composableBuilder(
    column: $table.excludeBudget,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get excludeExIn => $composableBuilder(
    column: $table.excludeExIn,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createDate => $composableBuilder(
    column: $table.createDate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get tags => $composableBuilder(
    column: $table.tags,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get images => $composableBuilder(
    column: $table.images,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get exi => $composableBuilder(
    column: $table.exi,
    builder: (column) => ColumnFilters(column),
  );
}

class $$InstallmentsTableOrderingComposer
    extends Composer<_$AppDatabase, $InstallmentsTable> {
  $$InstallmentsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get catId => $composableBuilder(
    column: $table.catId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<BigInt> get principalMinor => $composableBuilder(
    column: $table.principalMinor,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get periods => $composableBuilder(
    column: $table.periods,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<BigInt> get chargeMinor => $composableBuilder(
    column: $table.chargeMinor,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get chargeWay => $composableBuilder(
    column: $table.chargeWay,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get remainderIn => $composableBuilder(
    column: $table.remainderIn,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get calWay => $composableBuilder(
    column: $table.calWay,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get startDate => $composableBuilder(
    column: $table.startDate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get assetId => $composableBuilder(
    column: $table.assetId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get nextPeriod => $composableBuilder(
    column: $table.nextPeriod,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get nextPeriodDate => $composableBuilder(
    column: $table.nextPeriodDate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get credited => $composableBuilder(
    column: $table.credited,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get bookId => $composableBuilder(
    column: $table.bookId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get excludeBudget => $composableBuilder(
    column: $table.excludeBudget,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get excludeExIn => $composableBuilder(
    column: $table.excludeExIn,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createDate => $composableBuilder(
    column: $table.createDate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tags => $composableBuilder(
    column: $table.tags,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get images => $composableBuilder(
    column: $table.images,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get exi => $composableBuilder(
    column: $table.exi,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$InstallmentsTableAnnotationComposer
    extends Composer<_$AppDatabase, $InstallmentsTable> {
  $$InstallmentsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<int> get catId =>
      $composableBuilder(column: $table.catId, builder: (column) => column);

  GeneratedColumn<BigInt> get principalMinor => $composableBuilder(
    column: $table.principalMinor,
    builder: (column) => column,
  );

  GeneratedColumn<int> get periods =>
      $composableBuilder(column: $table.periods, builder: (column) => column);

  GeneratedColumn<BigInt> get chargeMinor => $composableBuilder(
    column: $table.chargeMinor,
    builder: (column) => column,
  );

  GeneratedColumn<int> get chargeWay =>
      $composableBuilder(column: $table.chargeWay, builder: (column) => column);

  GeneratedColumn<int> get remainderIn => $composableBuilder(
    column: $table.remainderIn,
    builder: (column) => column,
  );

  GeneratedColumn<int> get calWay =>
      $composableBuilder(column: $table.calWay, builder: (column) => column);

  GeneratedColumn<int> get startDate =>
      $composableBuilder(column: $table.startDate, builder: (column) => column);

  GeneratedColumn<int> get assetId =>
      $composableBuilder(column: $table.assetId, builder: (column) => column);

  GeneratedColumn<int> get nextPeriod => $composableBuilder(
    column: $table.nextPeriod,
    builder: (column) => column,
  );

  GeneratedColumn<int> get nextPeriodDate => $composableBuilder(
    column: $table.nextPeriodDate,
    builder: (column) => column,
  );

  GeneratedColumn<String> get credited =>
      $composableBuilder(column: $table.credited, builder: (column) => column);

  GeneratedColumn<int> get bookId =>
      $composableBuilder(column: $table.bookId, builder: (column) => column);

  GeneratedColumn<bool> get excludeBudget => $composableBuilder(
    column: $table.excludeBudget,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get excludeExIn => $composableBuilder(
    column: $table.excludeExIn,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createDate => $composableBuilder(
    column: $table.createDate,
    builder: (column) => column,
  );

  GeneratedColumn<String> get tags =>
      $composableBuilder(column: $table.tags, builder: (column) => column);

  GeneratedColumn<String> get images =>
      $composableBuilder(column: $table.images, builder: (column) => column);

  GeneratedColumn<String> get exi =>
      $composableBuilder(column: $table.exi, builder: (column) => column);
}

class $$InstallmentsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $InstallmentsTable,
          Installment,
          $$InstallmentsTableFilterComposer,
          $$InstallmentsTableOrderingComposer,
          $$InstallmentsTableAnnotationComposer,
          $$InstallmentsTableCreateCompanionBuilder,
          $$InstallmentsTableUpdateCompanionBuilder,
          (
            Installment,
            BaseReferences<_$AppDatabase, $InstallmentsTable, Installment>,
          ),
          Installment,
          PrefetchHooks Function()
        > {
  $$InstallmentsTableTableManager(_$AppDatabase db, $InstallmentsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$InstallmentsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$InstallmentsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$InstallmentsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<int> catId = const Value.absent(),
                Value<BigInt> principalMinor = const Value.absent(),
                Value<int> periods = const Value.absent(),
                Value<BigInt> chargeMinor = const Value.absent(),
                Value<int> chargeWay = const Value.absent(),
                Value<int> remainderIn = const Value.absent(),
                Value<int> calWay = const Value.absent(),
                Value<int> startDate = const Value.absent(),
                Value<int> assetId = const Value.absent(),
                Value<int> nextPeriod = const Value.absent(),
                Value<int> nextPeriodDate = const Value.absent(),
                Value<String?> credited = const Value.absent(),
                Value<int> bookId = const Value.absent(),
                Value<bool> excludeBudget = const Value.absent(),
                Value<bool> excludeExIn = const Value.absent(),
                Value<int> createDate = const Value.absent(),
                Value<String?> tags = const Value.absent(),
                Value<String?> images = const Value.absent(),
                Value<String?> exi = const Value.absent(),
              }) => InstallmentsCompanion(
                id: id,
                name: name,
                catId: catId,
                principalMinor: principalMinor,
                periods: periods,
                chargeMinor: chargeMinor,
                chargeWay: chargeWay,
                remainderIn: remainderIn,
                calWay: calWay,
                startDate: startDate,
                assetId: assetId,
                nextPeriod: nextPeriod,
                nextPeriodDate: nextPeriodDate,
                credited: credited,
                bookId: bookId,
                excludeBudget: excludeBudget,
                excludeExIn: excludeExIn,
                createDate: createDate,
                tags: tags,
                images: images,
                exi: exi,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String name,
                Value<int> catId = const Value.absent(),
                required BigInt principalMinor,
                required int periods,
                required BigInt chargeMinor,
                required int chargeWay,
                required int remainderIn,
                required int calWay,
                required int startDate,
                required int assetId,
                required int nextPeriod,
                required int nextPeriodDate,
                Value<String?> credited = const Value.absent(),
                required int bookId,
                Value<bool> excludeBudget = const Value.absent(),
                Value<bool> excludeExIn = const Value.absent(),
                required int createDate,
                Value<String?> tags = const Value.absent(),
                Value<String?> images = const Value.absent(),
                Value<String?> exi = const Value.absent(),
              }) => InstallmentsCompanion.insert(
                id: id,
                name: name,
                catId: catId,
                principalMinor: principalMinor,
                periods: periods,
                chargeMinor: chargeMinor,
                chargeWay: chargeWay,
                remainderIn: remainderIn,
                calWay: calWay,
                startDate: startDate,
                assetId: assetId,
                nextPeriod: nextPeriod,
                nextPeriodDate: nextPeriodDate,
                credited: credited,
                bookId: bookId,
                excludeBudget: excludeBudget,
                excludeExIn: excludeExIn,
                createDate: createDate,
                tags: tags,
                images: images,
                exi: exi,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$InstallmentsTable, Installment>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $InstallmentsTable,
                    Installment
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$InstallmentsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $InstallmentsTable,
      Installment,
      $$InstallmentsTableFilterComposer,
      $$InstallmentsTableOrderingComposer,
      $$InstallmentsTableAnnotationComposer,
      $$InstallmentsTableCreateCompanionBuilder,
      $$InstallmentsTableUpdateCompanionBuilder,
      (
        Installment,
        BaseReferences<_$AppDatabase, $InstallmentsTable, Installment>,
      ),
      Installment,
      PrefetchHooks Function()
    >;
typedef $$NotesTableCreateCompanionBuilder =
    NotesCompanion Function({
      Value<int> id,
      Value<String?> title,
      required String content,
      required int createTime,
      required int updateTime,
      Value<int> trashTime,
    });
typedef $$NotesTableUpdateCompanionBuilder =
    NotesCompanion Function({
      Value<int> id,
      Value<String?> title,
      Value<String> content,
      Value<int> createTime,
      Value<int> updateTime,
      Value<int> trashTime,
    });

class $$NotesTableFilterComposer extends Composer<_$AppDatabase, $NotesTable> {
  $$NotesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createTime => $composableBuilder(
    column: $table.createTime,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updateTime => $composableBuilder(
    column: $table.updateTime,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get trashTime => $composableBuilder(
    column: $table.trashTime,
    builder: (column) => ColumnFilters(column),
  );
}

class $$NotesTableOrderingComposer
    extends Composer<_$AppDatabase, $NotesTable> {
  $$NotesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createTime => $composableBuilder(
    column: $table.createTime,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updateTime => $composableBuilder(
    column: $table.updateTime,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get trashTime => $composableBuilder(
    column: $table.trashTime,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$NotesTableAnnotationComposer
    extends Composer<_$AppDatabase, $NotesTable> {
  $$NotesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get content =>
      $composableBuilder(column: $table.content, builder: (column) => column);

  GeneratedColumn<int> get createTime => $composableBuilder(
    column: $table.createTime,
    builder: (column) => column,
  );

  GeneratedColumn<int> get updateTime => $composableBuilder(
    column: $table.updateTime,
    builder: (column) => column,
  );

  GeneratedColumn<int> get trashTime =>
      $composableBuilder(column: $table.trashTime, builder: (column) => column);
}

class $$NotesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $NotesTable,
          Note,
          $$NotesTableFilterComposer,
          $$NotesTableOrderingComposer,
          $$NotesTableAnnotationComposer,
          $$NotesTableCreateCompanionBuilder,
          $$NotesTableUpdateCompanionBuilder,
          (Note, BaseReferences<_$AppDatabase, $NotesTable, Note>),
          Note,
          PrefetchHooks Function()
        > {
  $$NotesTableTableManager(_$AppDatabase db, $NotesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$NotesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$NotesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$NotesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String?> title = const Value.absent(),
                Value<String> content = const Value.absent(),
                Value<int> createTime = const Value.absent(),
                Value<int> updateTime = const Value.absent(),
                Value<int> trashTime = const Value.absent(),
              }) => NotesCompanion(
                id: id,
                title: title,
                content: content,
                createTime: createTime,
                updateTime: updateTime,
                trashTime: trashTime,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String?> title = const Value.absent(),
                required String content,
                required int createTime,
                required int updateTime,
                Value<int> trashTime = const Value.absent(),
              }) => NotesCompanion.insert(
                id: id,
                title: title,
                content: content,
                createTime: createTime,
                updateTime: updateTime,
                trashTime: trashTime,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$NotesTable, Note>(table),
                  BaseReferences<_$AppDatabase, $NotesTable, Note>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$NotesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $NotesTable,
      Note,
      $$NotesTableFilterComposer,
      $$NotesTableOrderingComposer,
      $$NotesTableAnnotationComposer,
      $$NotesTableCreateCompanionBuilder,
      $$NotesTableUpdateCompanionBuilder,
      (Note, BaseReferences<_$AppDatabase, $NotesTable, Note>),
      Note,
      PrefetchHooks Function()
    >;
typedef $$TagsTableCreateCompanionBuilder =
    TagsCompanion Function({
      required String tagId,
      required String name,
      Value<int> sort,
      Value<bool> hidden,
      Value<String?> parentTagId,
      Value<int> parent,
      Value<String?> color,
      Value<String?> extraInfo,
      Value<int> rowid,
    });
typedef $$TagsTableUpdateCompanionBuilder =
    TagsCompanion Function({
      Value<String> tagId,
      Value<String> name,
      Value<int> sort,
      Value<bool> hidden,
      Value<String?> parentTagId,
      Value<int> parent,
      Value<String?> color,
      Value<String?> extraInfo,
      Value<int> rowid,
    });

class $$TagsTableFilterComposer extends Composer<_$AppDatabase, $TagsTable> {
  $$TagsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get tagId => $composableBuilder(
    column: $table.tagId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sort => $composableBuilder(
    column: $table.sort,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get hidden => $composableBuilder(
    column: $table.hidden,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get parentTagId => $composableBuilder(
    column: $table.parentTagId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get parent => $composableBuilder(
    column: $table.parent,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get color => $composableBuilder(
    column: $table.color,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get extraInfo => $composableBuilder(
    column: $table.extraInfo,
    builder: (column) => ColumnFilters(column),
  );
}

class $$TagsTableOrderingComposer extends Composer<_$AppDatabase, $TagsTable> {
  $$TagsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get tagId => $composableBuilder(
    column: $table.tagId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sort => $composableBuilder(
    column: $table.sort,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get hidden => $composableBuilder(
    column: $table.hidden,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get parentTagId => $composableBuilder(
    column: $table.parentTagId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get parent => $composableBuilder(
    column: $table.parent,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get color => $composableBuilder(
    column: $table.color,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get extraInfo => $composableBuilder(
    column: $table.extraInfo,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$TagsTableAnnotationComposer
    extends Composer<_$AppDatabase, $TagsTable> {
  $$TagsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get tagId =>
      $composableBuilder(column: $table.tagId, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<int> get sort =>
      $composableBuilder(column: $table.sort, builder: (column) => column);

  GeneratedColumn<bool> get hidden =>
      $composableBuilder(column: $table.hidden, builder: (column) => column);

  GeneratedColumn<String> get parentTagId => $composableBuilder(
    column: $table.parentTagId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get parent =>
      $composableBuilder(column: $table.parent, builder: (column) => column);

  GeneratedColumn<String> get color =>
      $composableBuilder(column: $table.color, builder: (column) => column);

  GeneratedColumn<String> get extraInfo =>
      $composableBuilder(column: $table.extraInfo, builder: (column) => column);
}

class $$TagsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $TagsTable,
          Tag,
          $$TagsTableFilterComposer,
          $$TagsTableOrderingComposer,
          $$TagsTableAnnotationComposer,
          $$TagsTableCreateCompanionBuilder,
          $$TagsTableUpdateCompanionBuilder,
          (Tag, BaseReferences<_$AppDatabase, $TagsTable, Tag>),
          Tag,
          PrefetchHooks Function()
        > {
  $$TagsTableTableManager(_$AppDatabase db, $TagsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TagsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TagsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TagsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> tagId = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<int> sort = const Value.absent(),
                Value<bool> hidden = const Value.absent(),
                Value<String?> parentTagId = const Value.absent(),
                Value<int> parent = const Value.absent(),
                Value<String?> color = const Value.absent(),
                Value<String?> extraInfo = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TagsCompanion(
                tagId: tagId,
                name: name,
                sort: sort,
                hidden: hidden,
                parentTagId: parentTagId,
                parent: parent,
                color: color,
                extraInfo: extraInfo,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String tagId,
                required String name,
                Value<int> sort = const Value.absent(),
                Value<bool> hidden = const Value.absent(),
                Value<String?> parentTagId = const Value.absent(),
                Value<int> parent = const Value.absent(),
                Value<String?> color = const Value.absent(),
                Value<String?> extraInfo = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TagsCompanion.insert(
                tagId: tagId,
                name: name,
                sort: sort,
                hidden: hidden,
                parentTagId: parentTagId,
                parent: parent,
                color: color,
                extraInfo: extraInfo,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$TagsTable, Tag>(table),
                  BaseReferences<_$AppDatabase, $TagsTable, Tag>(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$TagsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $TagsTable,
      Tag,
      $$TagsTableFilterComposer,
      $$TagsTableOrderingComposer,
      $$TagsTableAnnotationComposer,
      $$TagsTableCreateCompanionBuilder,
      $$TagsTableUpdateCompanionBuilder,
      (Tag, BaseReferences<_$AppDatabase, $TagsTable, Tag>),
      Tag,
      PrefetchHooks Function()
    >;
typedef $$TagRecordsTableCreateCompanionBuilder =
    TagRecordsCompanion Function({
      required String tagId,
      required String recordId,
      Value<int> rowid,
    });
typedef $$TagRecordsTableUpdateCompanionBuilder =
    TagRecordsCompanion Function({
      Value<String> tagId,
      Value<String> recordId,
      Value<int> rowid,
    });

class $$TagRecordsTableFilterComposer
    extends Composer<_$AppDatabase, $TagRecordsTable> {
  $$TagRecordsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get tagId => $composableBuilder(
    column: $table.tagId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get recordId => $composableBuilder(
    column: $table.recordId,
    builder: (column) => ColumnFilters(column),
  );
}

class $$TagRecordsTableOrderingComposer
    extends Composer<_$AppDatabase, $TagRecordsTable> {
  $$TagRecordsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get tagId => $composableBuilder(
    column: $table.tagId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get recordId => $composableBuilder(
    column: $table.recordId,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$TagRecordsTableAnnotationComposer
    extends Composer<_$AppDatabase, $TagRecordsTable> {
  $$TagRecordsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get tagId =>
      $composableBuilder(column: $table.tagId, builder: (column) => column);

  GeneratedColumn<String> get recordId =>
      $composableBuilder(column: $table.recordId, builder: (column) => column);
}

class $$TagRecordsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $TagRecordsTable,
          TagRecord,
          $$TagRecordsTableFilterComposer,
          $$TagRecordsTableOrderingComposer,
          $$TagRecordsTableAnnotationComposer,
          $$TagRecordsTableCreateCompanionBuilder,
          $$TagRecordsTableUpdateCompanionBuilder,
          (
            TagRecord,
            BaseReferences<_$AppDatabase, $TagRecordsTable, TagRecord>,
          ),
          TagRecord,
          PrefetchHooks Function()
        > {
  $$TagRecordsTableTableManager(_$AppDatabase db, $TagRecordsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TagRecordsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TagRecordsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TagRecordsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> tagId = const Value.absent(),
                Value<String> recordId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TagRecordsCompanion(
                tagId: tagId,
                recordId: recordId,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String tagId,
                required String recordId,
                Value<int> rowid = const Value.absent(),
              }) => TagRecordsCompanion.insert(
                tagId: tagId,
                recordId: recordId,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$TagRecordsTable, TagRecord>(table),
                  BaseReferences<_$AppDatabase, $TagRecordsTable, TagRecord>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$TagRecordsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $TagRecordsTable,
      TagRecord,
      $$TagRecordsTableFilterComposer,
      $$TagRecordsTableOrderingComposer,
      $$TagRecordsTableAnnotationComposer,
      $$TagRecordsTableCreateCompanionBuilder,
      $$TagRecordsTableUpdateCompanionBuilder,
      (TagRecord, BaseReferences<_$AppDatabase, $TagRecordsTable, TagRecord>),
      TagRecord,
      PrefetchHooks Function()
    >;
typedef $$MoneySavePlansTableCreateCompanionBuilder =
    MoneySavePlansCompanion Function({
      Value<int> id,
      required String name,
      Value<String> remark,
      required int planType,
      required int cycleType,
      required int startDate,
      required int endDate,
      required BigInt planMoneyMinor,
      required BigInt savedMoneyMinor,
      Value<bool> autoPlan,
      Value<int> fromAssetId,
      Value<int> toAssetId,
      Value<int> bookId,
      required BigInt startMoneyMinor,
      required BigInt incrementalMinor,
      Value<int> status,
      required int createDate,
      Value<int> sort,
      required int nextSaveDate,
      Value<int> bbzDailyTimes,
      Value<String?> icon,
      Value<String?> extraInfo,
    });
typedef $$MoneySavePlansTableUpdateCompanionBuilder =
    MoneySavePlansCompanion Function({
      Value<int> id,
      Value<String> name,
      Value<String> remark,
      Value<int> planType,
      Value<int> cycleType,
      Value<int> startDate,
      Value<int> endDate,
      Value<BigInt> planMoneyMinor,
      Value<BigInt> savedMoneyMinor,
      Value<bool> autoPlan,
      Value<int> fromAssetId,
      Value<int> toAssetId,
      Value<int> bookId,
      Value<BigInt> startMoneyMinor,
      Value<BigInt> incrementalMinor,
      Value<int> status,
      Value<int> createDate,
      Value<int> sort,
      Value<int> nextSaveDate,
      Value<int> bbzDailyTimes,
      Value<String?> icon,
      Value<String?> extraInfo,
    });

class $$MoneySavePlansTableFilterComposer
    extends Composer<_$AppDatabase, $MoneySavePlansTable> {
  $$MoneySavePlansTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get remark => $composableBuilder(
    column: $table.remark,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get planType => $composableBuilder(
    column: $table.planType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get cycleType => $composableBuilder(
    column: $table.cycleType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get startDate => $composableBuilder(
    column: $table.startDate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get endDate => $composableBuilder(
    column: $table.endDate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<BigInt> get planMoneyMinor => $composableBuilder(
    column: $table.planMoneyMinor,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<BigInt> get savedMoneyMinor => $composableBuilder(
    column: $table.savedMoneyMinor,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get autoPlan => $composableBuilder(
    column: $table.autoPlan,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get fromAssetId => $composableBuilder(
    column: $table.fromAssetId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get toAssetId => $composableBuilder(
    column: $table.toAssetId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get bookId => $composableBuilder(
    column: $table.bookId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<BigInt> get startMoneyMinor => $composableBuilder(
    column: $table.startMoneyMinor,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<BigInt> get incrementalMinor => $composableBuilder(
    column: $table.incrementalMinor,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createDate => $composableBuilder(
    column: $table.createDate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sort => $composableBuilder(
    column: $table.sort,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get nextSaveDate => $composableBuilder(
    column: $table.nextSaveDate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get bbzDailyTimes => $composableBuilder(
    column: $table.bbzDailyTimes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get icon => $composableBuilder(
    column: $table.icon,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get extraInfo => $composableBuilder(
    column: $table.extraInfo,
    builder: (column) => ColumnFilters(column),
  );
}

class $$MoneySavePlansTableOrderingComposer
    extends Composer<_$AppDatabase, $MoneySavePlansTable> {
  $$MoneySavePlansTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get remark => $composableBuilder(
    column: $table.remark,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get planType => $composableBuilder(
    column: $table.planType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get cycleType => $composableBuilder(
    column: $table.cycleType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get startDate => $composableBuilder(
    column: $table.startDate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get endDate => $composableBuilder(
    column: $table.endDate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<BigInt> get planMoneyMinor => $composableBuilder(
    column: $table.planMoneyMinor,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<BigInt> get savedMoneyMinor => $composableBuilder(
    column: $table.savedMoneyMinor,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get autoPlan => $composableBuilder(
    column: $table.autoPlan,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get fromAssetId => $composableBuilder(
    column: $table.fromAssetId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get toAssetId => $composableBuilder(
    column: $table.toAssetId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get bookId => $composableBuilder(
    column: $table.bookId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<BigInt> get startMoneyMinor => $composableBuilder(
    column: $table.startMoneyMinor,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<BigInt> get incrementalMinor => $composableBuilder(
    column: $table.incrementalMinor,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createDate => $composableBuilder(
    column: $table.createDate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sort => $composableBuilder(
    column: $table.sort,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get nextSaveDate => $composableBuilder(
    column: $table.nextSaveDate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get bbzDailyTimes => $composableBuilder(
    column: $table.bbzDailyTimes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get icon => $composableBuilder(
    column: $table.icon,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get extraInfo => $composableBuilder(
    column: $table.extraInfo,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$MoneySavePlansTableAnnotationComposer
    extends Composer<_$AppDatabase, $MoneySavePlansTable> {
  $$MoneySavePlansTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get remark =>
      $composableBuilder(column: $table.remark, builder: (column) => column);

  GeneratedColumn<int> get planType =>
      $composableBuilder(column: $table.planType, builder: (column) => column);

  GeneratedColumn<int> get cycleType =>
      $composableBuilder(column: $table.cycleType, builder: (column) => column);

  GeneratedColumn<int> get startDate =>
      $composableBuilder(column: $table.startDate, builder: (column) => column);

  GeneratedColumn<int> get endDate =>
      $composableBuilder(column: $table.endDate, builder: (column) => column);

  GeneratedColumn<BigInt> get planMoneyMinor => $composableBuilder(
    column: $table.planMoneyMinor,
    builder: (column) => column,
  );

  GeneratedColumn<BigInt> get savedMoneyMinor => $composableBuilder(
    column: $table.savedMoneyMinor,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get autoPlan =>
      $composableBuilder(column: $table.autoPlan, builder: (column) => column);

  GeneratedColumn<int> get fromAssetId => $composableBuilder(
    column: $table.fromAssetId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get toAssetId =>
      $composableBuilder(column: $table.toAssetId, builder: (column) => column);

  GeneratedColumn<int> get bookId =>
      $composableBuilder(column: $table.bookId, builder: (column) => column);

  GeneratedColumn<BigInt> get startMoneyMinor => $composableBuilder(
    column: $table.startMoneyMinor,
    builder: (column) => column,
  );

  GeneratedColumn<BigInt> get incrementalMinor => $composableBuilder(
    column: $table.incrementalMinor,
    builder: (column) => column,
  );

  GeneratedColumn<int> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<int> get createDate => $composableBuilder(
    column: $table.createDate,
    builder: (column) => column,
  );

  GeneratedColumn<int> get sort =>
      $composableBuilder(column: $table.sort, builder: (column) => column);

  GeneratedColumn<int> get nextSaveDate => $composableBuilder(
    column: $table.nextSaveDate,
    builder: (column) => column,
  );

  GeneratedColumn<int> get bbzDailyTimes => $composableBuilder(
    column: $table.bbzDailyTimes,
    builder: (column) => column,
  );

  GeneratedColumn<String> get icon =>
      $composableBuilder(column: $table.icon, builder: (column) => column);

  GeneratedColumn<String> get extraInfo =>
      $composableBuilder(column: $table.extraInfo, builder: (column) => column);
}

class $$MoneySavePlansTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $MoneySavePlansTable,
          MoneySavePlan,
          $$MoneySavePlansTableFilterComposer,
          $$MoneySavePlansTableOrderingComposer,
          $$MoneySavePlansTableAnnotationComposer,
          $$MoneySavePlansTableCreateCompanionBuilder,
          $$MoneySavePlansTableUpdateCompanionBuilder,
          (
            MoneySavePlan,
            BaseReferences<_$AppDatabase, $MoneySavePlansTable, MoneySavePlan>,
          ),
          MoneySavePlan,
          PrefetchHooks Function()
        > {
  $$MoneySavePlansTableTableManager(
    _$AppDatabase db,
    $MoneySavePlansTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MoneySavePlansTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MoneySavePlansTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MoneySavePlansTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> remark = const Value.absent(),
                Value<int> planType = const Value.absent(),
                Value<int> cycleType = const Value.absent(),
                Value<int> startDate = const Value.absent(),
                Value<int> endDate = const Value.absent(),
                Value<BigInt> planMoneyMinor = const Value.absent(),
                Value<BigInt> savedMoneyMinor = const Value.absent(),
                Value<bool> autoPlan = const Value.absent(),
                Value<int> fromAssetId = const Value.absent(),
                Value<int> toAssetId = const Value.absent(),
                Value<int> bookId = const Value.absent(),
                Value<BigInt> startMoneyMinor = const Value.absent(),
                Value<BigInt> incrementalMinor = const Value.absent(),
                Value<int> status = const Value.absent(),
                Value<int> createDate = const Value.absent(),
                Value<int> sort = const Value.absent(),
                Value<int> nextSaveDate = const Value.absent(),
                Value<int> bbzDailyTimes = const Value.absent(),
                Value<String?> icon = const Value.absent(),
                Value<String?> extraInfo = const Value.absent(),
              }) => MoneySavePlansCompanion(
                id: id,
                name: name,
                remark: remark,
                planType: planType,
                cycleType: cycleType,
                startDate: startDate,
                endDate: endDate,
                planMoneyMinor: planMoneyMinor,
                savedMoneyMinor: savedMoneyMinor,
                autoPlan: autoPlan,
                fromAssetId: fromAssetId,
                toAssetId: toAssetId,
                bookId: bookId,
                startMoneyMinor: startMoneyMinor,
                incrementalMinor: incrementalMinor,
                status: status,
                createDate: createDate,
                sort: sort,
                nextSaveDate: nextSaveDate,
                bbzDailyTimes: bbzDailyTimes,
                icon: icon,
                extraInfo: extraInfo,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String name,
                Value<String> remark = const Value.absent(),
                required int planType,
                required int cycleType,
                required int startDate,
                required int endDate,
                required BigInt planMoneyMinor,
                required BigInt savedMoneyMinor,
                Value<bool> autoPlan = const Value.absent(),
                Value<int> fromAssetId = const Value.absent(),
                Value<int> toAssetId = const Value.absent(),
                Value<int> bookId = const Value.absent(),
                required BigInt startMoneyMinor,
                required BigInt incrementalMinor,
                Value<int> status = const Value.absent(),
                required int createDate,
                Value<int> sort = const Value.absent(),
                required int nextSaveDate,
                Value<int> bbzDailyTimes = const Value.absent(),
                Value<String?> icon = const Value.absent(),
                Value<String?> extraInfo = const Value.absent(),
              }) => MoneySavePlansCompanion.insert(
                id: id,
                name: name,
                remark: remark,
                planType: planType,
                cycleType: cycleType,
                startDate: startDate,
                endDate: endDate,
                planMoneyMinor: planMoneyMinor,
                savedMoneyMinor: savedMoneyMinor,
                autoPlan: autoPlan,
                fromAssetId: fromAssetId,
                toAssetId: toAssetId,
                bookId: bookId,
                startMoneyMinor: startMoneyMinor,
                incrementalMinor: incrementalMinor,
                status: status,
                createDate: createDate,
                sort: sort,
                nextSaveDate: nextSaveDate,
                bbzDailyTimes: bbzDailyTimes,
                icon: icon,
                extraInfo: extraInfo,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$MoneySavePlansTable, MoneySavePlan>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $MoneySavePlansTable,
                    MoneySavePlan
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$MoneySavePlansTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $MoneySavePlansTable,
      MoneySavePlan,
      $$MoneySavePlansTableFilterComposer,
      $$MoneySavePlansTableOrderingComposer,
      $$MoneySavePlansTableAnnotationComposer,
      $$MoneySavePlansTableCreateCompanionBuilder,
      $$MoneySavePlansTableUpdateCompanionBuilder,
      (
        MoneySavePlan,
        BaseReferences<_$AppDatabase, $MoneySavePlansTable, MoneySavePlan>,
      ),
      MoneySavePlan,
      PrefetchHooks Function()
    >;
typedef $$MoneySavePlanRecordsTableCreateCompanionBuilder =
    MoneySavePlanRecordsCompanion Function({
      Value<int> id,
      required int planId,
      Value<String> remark,
      Value<int> fromAssetId,
      Value<int> toAssetId,
      required int recordDate,
      required BigInt recordMoneyMinor,
      Value<String?> recordId,
    });
typedef $$MoneySavePlanRecordsTableUpdateCompanionBuilder =
    MoneySavePlanRecordsCompanion Function({
      Value<int> id,
      Value<int> planId,
      Value<String> remark,
      Value<int> fromAssetId,
      Value<int> toAssetId,
      Value<int> recordDate,
      Value<BigInt> recordMoneyMinor,
      Value<String?> recordId,
    });

class $$MoneySavePlanRecordsTableFilterComposer
    extends Composer<_$AppDatabase, $MoneySavePlanRecordsTable> {
  $$MoneySavePlanRecordsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get planId => $composableBuilder(
    column: $table.planId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get remark => $composableBuilder(
    column: $table.remark,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get fromAssetId => $composableBuilder(
    column: $table.fromAssetId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get toAssetId => $composableBuilder(
    column: $table.toAssetId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get recordDate => $composableBuilder(
    column: $table.recordDate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<BigInt> get recordMoneyMinor => $composableBuilder(
    column: $table.recordMoneyMinor,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get recordId => $composableBuilder(
    column: $table.recordId,
    builder: (column) => ColumnFilters(column),
  );
}

class $$MoneySavePlanRecordsTableOrderingComposer
    extends Composer<_$AppDatabase, $MoneySavePlanRecordsTable> {
  $$MoneySavePlanRecordsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get planId => $composableBuilder(
    column: $table.planId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get remark => $composableBuilder(
    column: $table.remark,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get fromAssetId => $composableBuilder(
    column: $table.fromAssetId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get toAssetId => $composableBuilder(
    column: $table.toAssetId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get recordDate => $composableBuilder(
    column: $table.recordDate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<BigInt> get recordMoneyMinor => $composableBuilder(
    column: $table.recordMoneyMinor,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get recordId => $composableBuilder(
    column: $table.recordId,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$MoneySavePlanRecordsTableAnnotationComposer
    extends Composer<_$AppDatabase, $MoneySavePlanRecordsTable> {
  $$MoneySavePlanRecordsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get planId =>
      $composableBuilder(column: $table.planId, builder: (column) => column);

  GeneratedColumn<String> get remark =>
      $composableBuilder(column: $table.remark, builder: (column) => column);

  GeneratedColumn<int> get fromAssetId => $composableBuilder(
    column: $table.fromAssetId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get toAssetId =>
      $composableBuilder(column: $table.toAssetId, builder: (column) => column);

  GeneratedColumn<int> get recordDate => $composableBuilder(
    column: $table.recordDate,
    builder: (column) => column,
  );

  GeneratedColumn<BigInt> get recordMoneyMinor => $composableBuilder(
    column: $table.recordMoneyMinor,
    builder: (column) => column,
  );

  GeneratedColumn<String> get recordId =>
      $composableBuilder(column: $table.recordId, builder: (column) => column);
}

class $$MoneySavePlanRecordsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $MoneySavePlanRecordsTable,
          MoneySavePlanRecord,
          $$MoneySavePlanRecordsTableFilterComposer,
          $$MoneySavePlanRecordsTableOrderingComposer,
          $$MoneySavePlanRecordsTableAnnotationComposer,
          $$MoneySavePlanRecordsTableCreateCompanionBuilder,
          $$MoneySavePlanRecordsTableUpdateCompanionBuilder,
          (
            MoneySavePlanRecord,
            BaseReferences<
              _$AppDatabase,
              $MoneySavePlanRecordsTable,
              MoneySavePlanRecord
            >,
          ),
          MoneySavePlanRecord,
          PrefetchHooks Function()
        > {
  $$MoneySavePlanRecordsTableTableManager(
    _$AppDatabase db,
    $MoneySavePlanRecordsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MoneySavePlanRecordsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MoneySavePlanRecordsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$MoneySavePlanRecordsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> planId = const Value.absent(),
                Value<String> remark = const Value.absent(),
                Value<int> fromAssetId = const Value.absent(),
                Value<int> toAssetId = const Value.absent(),
                Value<int> recordDate = const Value.absent(),
                Value<BigInt> recordMoneyMinor = const Value.absent(),
                Value<String?> recordId = const Value.absent(),
              }) => MoneySavePlanRecordsCompanion(
                id: id,
                planId: planId,
                remark: remark,
                fromAssetId: fromAssetId,
                toAssetId: toAssetId,
                recordDate: recordDate,
                recordMoneyMinor: recordMoneyMinor,
                recordId: recordId,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int planId,
                Value<String> remark = const Value.absent(),
                Value<int> fromAssetId = const Value.absent(),
                Value<int> toAssetId = const Value.absent(),
                required int recordDate,
                required BigInt recordMoneyMinor,
                Value<String?> recordId = const Value.absent(),
              }) => MoneySavePlanRecordsCompanion.insert(
                id: id,
                planId: planId,
                remark: remark,
                fromAssetId: fromAssetId,
                toAssetId: toAssetId,
                recordDate: recordDate,
                recordMoneyMinor: recordMoneyMinor,
                recordId: recordId,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$MoneySavePlanRecordsTable, MoneySavePlanRecord>(
                    table,
                  ),
                  BaseReferences<
                    _$AppDatabase,
                    $MoneySavePlanRecordsTable,
                    MoneySavePlanRecord
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$MoneySavePlanRecordsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $MoneySavePlanRecordsTable,
      MoneySavePlanRecord,
      $$MoneySavePlanRecordsTableFilterComposer,
      $$MoneySavePlanRecordsTableOrderingComposer,
      $$MoneySavePlanRecordsTableAnnotationComposer,
      $$MoneySavePlanRecordsTableCreateCompanionBuilder,
      $$MoneySavePlanRecordsTableUpdateCompanionBuilder,
      (
        MoneySavePlanRecord,
        BaseReferences<
          _$AppDatabase,
          $MoneySavePlanRecordsTable,
          MoneySavePlanRecord
        >,
      ),
      MoneySavePlanRecord,
      PrefetchHooks Function()
    >;
typedef $$AssetBooksTableCreateCompanionBuilder =
    AssetBooksCompanion Function({
      required int assetId,
      required int bookId,
      Value<int> rowid,
    });
typedef $$AssetBooksTableUpdateCompanionBuilder =
    AssetBooksCompanion Function({
      Value<int> assetId,
      Value<int> bookId,
      Value<int> rowid,
    });

class $$AssetBooksTableFilterComposer
    extends Composer<_$AppDatabase, $AssetBooksTable> {
  $$AssetBooksTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get assetId => $composableBuilder(
    column: $table.assetId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get bookId => $composableBuilder(
    column: $table.bookId,
    builder: (column) => ColumnFilters(column),
  );
}

class $$AssetBooksTableOrderingComposer
    extends Composer<_$AppDatabase, $AssetBooksTable> {
  $$AssetBooksTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get assetId => $composableBuilder(
    column: $table.assetId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get bookId => $composableBuilder(
    column: $table.bookId,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AssetBooksTableAnnotationComposer
    extends Composer<_$AppDatabase, $AssetBooksTable> {
  $$AssetBooksTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get assetId =>
      $composableBuilder(column: $table.assetId, builder: (column) => column);

  GeneratedColumn<int> get bookId =>
      $composableBuilder(column: $table.bookId, builder: (column) => column);
}

class $$AssetBooksTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $AssetBooksTable,
          AssetBook,
          $$AssetBooksTableFilterComposer,
          $$AssetBooksTableOrderingComposer,
          $$AssetBooksTableAnnotationComposer,
          $$AssetBooksTableCreateCompanionBuilder,
          $$AssetBooksTableUpdateCompanionBuilder,
          (
            AssetBook,
            BaseReferences<_$AppDatabase, $AssetBooksTable, AssetBook>,
          ),
          AssetBook,
          PrefetchHooks Function()
        > {
  $$AssetBooksTableTableManager(_$AppDatabase db, $AssetBooksTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AssetBooksTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AssetBooksTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AssetBooksTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> assetId = const Value.absent(),
                Value<int> bookId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AssetBooksCompanion(
                assetId: assetId,
                bookId: bookId,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required int assetId,
                required int bookId,
                Value<int> rowid = const Value.absent(),
              }) => AssetBooksCompanion.insert(
                assetId: assetId,
                bookId: bookId,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$AssetBooksTable, AssetBook>(table),
                  BaseReferences<_$AppDatabase, $AssetBooksTable, AssetBook>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$AssetBooksTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $AssetBooksTable,
      AssetBook,
      $$AssetBooksTableFilterComposer,
      $$AssetBooksTableOrderingComposer,
      $$AssetBooksTableAnnotationComposer,
      $$AssetBooksTableCreateCompanionBuilder,
      $$AssetBooksTableUpdateCompanionBuilder,
      (AssetBook, BaseReferences<_$AppDatabase, $AssetBooksTable, AssetBook>),
      AssetBook,
      PrefetchHooks Function()
    >;
typedef $$StatStoriesTableCreateCompanionBuilder =
    StatStoriesCompanion Function({
      required String id,
      required String story,
      required int bookId,
      required int sdate,
      required int edate,
      Value<String?> dsection,
      Value<int> rowid,
    });
typedef $$StatStoriesTableUpdateCompanionBuilder =
    StatStoriesCompanion Function({
      Value<String> id,
      Value<String> story,
      Value<int> bookId,
      Value<int> sdate,
      Value<int> edate,
      Value<String?> dsection,
      Value<int> rowid,
    });

class $$StatStoriesTableFilterComposer
    extends Composer<_$AppDatabase, $StatStoriesTable> {
  $$StatStoriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get story => $composableBuilder(
    column: $table.story,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get bookId => $composableBuilder(
    column: $table.bookId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sdate => $composableBuilder(
    column: $table.sdate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get edate => $composableBuilder(
    column: $table.edate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get dsection => $composableBuilder(
    column: $table.dsection,
    builder: (column) => ColumnFilters(column),
  );
}

class $$StatStoriesTableOrderingComposer
    extends Composer<_$AppDatabase, $StatStoriesTable> {
  $$StatStoriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get story => $composableBuilder(
    column: $table.story,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get bookId => $composableBuilder(
    column: $table.bookId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sdate => $composableBuilder(
    column: $table.sdate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get edate => $composableBuilder(
    column: $table.edate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get dsection => $composableBuilder(
    column: $table.dsection,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$StatStoriesTableAnnotationComposer
    extends Composer<_$AppDatabase, $StatStoriesTable> {
  $$StatStoriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get story =>
      $composableBuilder(column: $table.story, builder: (column) => column);

  GeneratedColumn<int> get bookId =>
      $composableBuilder(column: $table.bookId, builder: (column) => column);

  GeneratedColumn<int> get sdate =>
      $composableBuilder(column: $table.sdate, builder: (column) => column);

  GeneratedColumn<int> get edate =>
      $composableBuilder(column: $table.edate, builder: (column) => column);

  GeneratedColumn<String> get dsection =>
      $composableBuilder(column: $table.dsection, builder: (column) => column);
}

class $$StatStoriesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $StatStoriesTable,
          StatStory,
          $$StatStoriesTableFilterComposer,
          $$StatStoriesTableOrderingComposer,
          $$StatStoriesTableAnnotationComposer,
          $$StatStoriesTableCreateCompanionBuilder,
          $$StatStoriesTableUpdateCompanionBuilder,
          (
            StatStory,
            BaseReferences<_$AppDatabase, $StatStoriesTable, StatStory>,
          ),
          StatStory,
          PrefetchHooks Function()
        > {
  $$StatStoriesTableTableManager(_$AppDatabase db, $StatStoriesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$StatStoriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$StatStoriesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$StatStoriesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> story = const Value.absent(),
                Value<int> bookId = const Value.absent(),
                Value<int> sdate = const Value.absent(),
                Value<int> edate = const Value.absent(),
                Value<String?> dsection = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => StatStoriesCompanion(
                id: id,
                story: story,
                bookId: bookId,
                sdate: sdate,
                edate: edate,
                dsection: dsection,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String story,
                required int bookId,
                required int sdate,
                required int edate,
                Value<String?> dsection = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => StatStoriesCompanion.insert(
                id: id,
                story: story,
                bookId: bookId,
                sdate: sdate,
                edate: edate,
                dsection: dsection,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$StatStoriesTable, StatStory>(table),
                  BaseReferences<_$AppDatabase, $StatStoriesTable, StatStory>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$StatStoriesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $StatStoriesTable,
      StatStory,
      $$StatStoriesTableFilterComposer,
      $$StatStoriesTableOrderingComposer,
      $$StatStoriesTableAnnotationComposer,
      $$StatStoriesTableCreateCompanionBuilder,
      $$StatStoriesTableUpdateCompanionBuilder,
      (StatStory, BaseReferences<_$AppDatabase, $StatStoriesTable, StatStory>),
      StatStory,
      PrefetchHooks Function()
    >;
typedef $$AutoMapsTableCreateCompanionBuilder =
    AutoMapsCompanion Function({
      Value<int> id,
      required String key,
      Value<String?> mapInfo,
      Value<String?> draft,
    });
typedef $$AutoMapsTableUpdateCompanionBuilder =
    AutoMapsCompanion Function({
      Value<int> id,
      Value<String> key,
      Value<String?> mapInfo,
      Value<String?> draft,
    });

class $$AutoMapsTableFilterComposer
    extends Composer<_$AppDatabase, $AutoMapsTable> {
  $$AutoMapsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get mapInfo => $composableBuilder(
    column: $table.mapInfo,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get draft => $composableBuilder(
    column: $table.draft,
    builder: (column) => ColumnFilters(column),
  );
}

class $$AutoMapsTableOrderingComposer
    extends Composer<_$AppDatabase, $AutoMapsTable> {
  $$AutoMapsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get mapInfo => $composableBuilder(
    column: $table.mapInfo,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get draft => $composableBuilder(
    column: $table.draft,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AutoMapsTableAnnotationComposer
    extends Composer<_$AppDatabase, $AutoMapsTable> {
  $$AutoMapsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get mapInfo =>
      $composableBuilder(column: $table.mapInfo, builder: (column) => column);

  GeneratedColumn<String> get draft =>
      $composableBuilder(column: $table.draft, builder: (column) => column);
}

class $$AutoMapsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $AutoMapsTable,
          AutoMap,
          $$AutoMapsTableFilterComposer,
          $$AutoMapsTableOrderingComposer,
          $$AutoMapsTableAnnotationComposer,
          $$AutoMapsTableCreateCompanionBuilder,
          $$AutoMapsTableUpdateCompanionBuilder,
          (AutoMap, BaseReferences<_$AppDatabase, $AutoMapsTable, AutoMap>),
          AutoMap,
          PrefetchHooks Function()
        > {
  $$AutoMapsTableTableManager(_$AppDatabase db, $AutoMapsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AutoMapsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AutoMapsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AutoMapsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> key = const Value.absent(),
                Value<String?> mapInfo = const Value.absent(),
                Value<String?> draft = const Value.absent(),
              }) => AutoMapsCompanion(
                id: id,
                key: key,
                mapInfo: mapInfo,
                draft: draft,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String key,
                Value<String?> mapInfo = const Value.absent(),
                Value<String?> draft = const Value.absent(),
              }) => AutoMapsCompanion.insert(
                id: id,
                key: key,
                mapInfo: mapInfo,
                draft: draft,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$AutoMapsTable, AutoMap>(table),
                  BaseReferences<_$AppDatabase, $AutoMapsTable, AutoMap>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$AutoMapsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $AutoMapsTable,
      AutoMap,
      $$AutoMapsTableFilterComposer,
      $$AutoMapsTableOrderingComposer,
      $$AutoMapsTableAnnotationComposer,
      $$AutoMapsTableCreateCompanionBuilder,
      $$AutoMapsTableUpdateCompanionBuilder,
      (AutoMap, BaseReferences<_$AppDatabase, $AutoMapsTable, AutoMap>),
      AutoMap,
      PrefetchHooks Function()
    >;
typedef $$CurrenciesTableCreateCompanionBuilder =
    CurrenciesCompanion Function({
      required String code,
      required String name,
      required String symbol,
      Value<int> type,
      required String rateToAnchor,
      required String anchorCode,
      Value<int> rateRefreshTime,
      Value<String?> icon,
      Value<bool> enable,
      Value<int> rowid,
    });
typedef $$CurrenciesTableUpdateCompanionBuilder =
    CurrenciesCompanion Function({
      Value<String> code,
      Value<String> name,
      Value<String> symbol,
      Value<int> type,
      Value<String> rateToAnchor,
      Value<String> anchorCode,
      Value<int> rateRefreshTime,
      Value<String?> icon,
      Value<bool> enable,
      Value<int> rowid,
    });

class $$CurrenciesTableFilterComposer
    extends Composer<_$AppDatabase, $CurrenciesTable> {
  $$CurrenciesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get code => $composableBuilder(
    column: $table.code,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get symbol => $composableBuilder(
    column: $table.symbol,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get rateToAnchor => $composableBuilder(
    column: $table.rateToAnchor,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get anchorCode => $composableBuilder(
    column: $table.anchorCode,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get rateRefreshTime => $composableBuilder(
    column: $table.rateRefreshTime,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get icon => $composableBuilder(
    column: $table.icon,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get enable => $composableBuilder(
    column: $table.enable,
    builder: (column) => ColumnFilters(column),
  );
}

class $$CurrenciesTableOrderingComposer
    extends Composer<_$AppDatabase, $CurrenciesTable> {
  $$CurrenciesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get code => $composableBuilder(
    column: $table.code,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get symbol => $composableBuilder(
    column: $table.symbol,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get rateToAnchor => $composableBuilder(
    column: $table.rateToAnchor,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get anchorCode => $composableBuilder(
    column: $table.anchorCode,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get rateRefreshTime => $composableBuilder(
    column: $table.rateRefreshTime,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get icon => $composableBuilder(
    column: $table.icon,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get enable => $composableBuilder(
    column: $table.enable,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$CurrenciesTableAnnotationComposer
    extends Composer<_$AppDatabase, $CurrenciesTable> {
  $$CurrenciesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get code =>
      $composableBuilder(column: $table.code, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get symbol =>
      $composableBuilder(column: $table.symbol, builder: (column) => column);

  GeneratedColumn<int> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<String> get rateToAnchor => $composableBuilder(
    column: $table.rateToAnchor,
    builder: (column) => column,
  );

  GeneratedColumn<String> get anchorCode => $composableBuilder(
    column: $table.anchorCode,
    builder: (column) => column,
  );

  GeneratedColumn<int> get rateRefreshTime => $composableBuilder(
    column: $table.rateRefreshTime,
    builder: (column) => column,
  );

  GeneratedColumn<String> get icon =>
      $composableBuilder(column: $table.icon, builder: (column) => column);

  GeneratedColumn<bool> get enable =>
      $composableBuilder(column: $table.enable, builder: (column) => column);
}

class $$CurrenciesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $CurrenciesTable,
          Currency,
          $$CurrenciesTableFilterComposer,
          $$CurrenciesTableOrderingComposer,
          $$CurrenciesTableAnnotationComposer,
          $$CurrenciesTableCreateCompanionBuilder,
          $$CurrenciesTableUpdateCompanionBuilder,
          (Currency, BaseReferences<_$AppDatabase, $CurrenciesTable, Currency>),
          Currency,
          PrefetchHooks Function()
        > {
  $$CurrenciesTableTableManager(_$AppDatabase db, $CurrenciesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CurrenciesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CurrenciesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CurrenciesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> code = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> symbol = const Value.absent(),
                Value<int> type = const Value.absent(),
                Value<String> rateToAnchor = const Value.absent(),
                Value<String> anchorCode = const Value.absent(),
                Value<int> rateRefreshTime = const Value.absent(),
                Value<String?> icon = const Value.absent(),
                Value<bool> enable = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CurrenciesCompanion(
                code: code,
                name: name,
                symbol: symbol,
                type: type,
                rateToAnchor: rateToAnchor,
                anchorCode: anchorCode,
                rateRefreshTime: rateRefreshTime,
                icon: icon,
                enable: enable,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String code,
                required String name,
                required String symbol,
                Value<int> type = const Value.absent(),
                required String rateToAnchor,
                required String anchorCode,
                Value<int> rateRefreshTime = const Value.absent(),
                Value<String?> icon = const Value.absent(),
                Value<bool> enable = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CurrenciesCompanion.insert(
                code: code,
                name: name,
                symbol: symbol,
                type: type,
                rateToAnchor: rateToAnchor,
                anchorCode: anchorCode,
                rateRefreshTime: rateRefreshTime,
                icon: icon,
                enable: enable,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$CurrenciesTable, Currency>(table),
                  BaseReferences<_$AppDatabase, $CurrenciesTable, Currency>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$CurrenciesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $CurrenciesTable,
      Currency,
      $$CurrenciesTableFilterComposer,
      $$CurrenciesTableOrderingComposer,
      $$CurrenciesTableAnnotationComposer,
      $$CurrenciesTableCreateCompanionBuilder,
      $$CurrenciesTableUpdateCompanionBuilder,
      (Currency, BaseReferences<_$AppDatabase, $CurrenciesTable, Currency>),
      Currency,
      PrefetchHooks Function()
    >;
typedef $$WriteCommandsTableCreateCompanionBuilder =
    WriteCommandsCompanion Function({
      required String commandId,
      required String payloadHash,
      required String resultId,
      required int committedAt,
      Value<int> rowid,
    });
typedef $$WriteCommandsTableUpdateCompanionBuilder =
    WriteCommandsCompanion Function({
      Value<String> commandId,
      Value<String> payloadHash,
      Value<String> resultId,
      Value<int> committedAt,
      Value<int> rowid,
    });

class $$WriteCommandsTableFilterComposer
    extends Composer<_$AppDatabase, $WriteCommandsTable> {
  $$WriteCommandsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get commandId => $composableBuilder(
    column: $table.commandId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get payloadHash => $composableBuilder(
    column: $table.payloadHash,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get resultId => $composableBuilder(
    column: $table.resultId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get committedAt => $composableBuilder(
    column: $table.committedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$WriteCommandsTableOrderingComposer
    extends Composer<_$AppDatabase, $WriteCommandsTable> {
  $$WriteCommandsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get commandId => $composableBuilder(
    column: $table.commandId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get payloadHash => $composableBuilder(
    column: $table.payloadHash,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get resultId => $composableBuilder(
    column: $table.resultId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get committedAt => $composableBuilder(
    column: $table.committedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$WriteCommandsTableAnnotationComposer
    extends Composer<_$AppDatabase, $WriteCommandsTable> {
  $$WriteCommandsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get commandId =>
      $composableBuilder(column: $table.commandId, builder: (column) => column);

  GeneratedColumn<String> get payloadHash => $composableBuilder(
    column: $table.payloadHash,
    builder: (column) => column,
  );

  GeneratedColumn<String> get resultId =>
      $composableBuilder(column: $table.resultId, builder: (column) => column);

  GeneratedColumn<int> get committedAt => $composableBuilder(
    column: $table.committedAt,
    builder: (column) => column,
  );
}

class $$WriteCommandsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $WriteCommandsTable,
          WriteCommand,
          $$WriteCommandsTableFilterComposer,
          $$WriteCommandsTableOrderingComposer,
          $$WriteCommandsTableAnnotationComposer,
          $$WriteCommandsTableCreateCompanionBuilder,
          $$WriteCommandsTableUpdateCompanionBuilder,
          (
            WriteCommand,
            BaseReferences<_$AppDatabase, $WriteCommandsTable, WriteCommand>,
          ),
          WriteCommand,
          PrefetchHooks Function()
        > {
  $$WriteCommandsTableTableManager(_$AppDatabase db, $WriteCommandsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$WriteCommandsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$WriteCommandsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$WriteCommandsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> commandId = const Value.absent(),
                Value<String> payloadHash = const Value.absent(),
                Value<String> resultId = const Value.absent(),
                Value<int> committedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => WriteCommandsCompanion(
                commandId: commandId,
                payloadHash: payloadHash,
                resultId: resultId,
                committedAt: committedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String commandId,
                required String payloadHash,
                required String resultId,
                required int committedAt,
                Value<int> rowid = const Value.absent(),
              }) => WriteCommandsCompanion.insert(
                commandId: commandId,
                payloadHash: payloadHash,
                resultId: resultId,
                committedAt: committedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$WriteCommandsTable, WriteCommand>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $WriteCommandsTable,
                    WriteCommand
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$WriteCommandsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $WriteCommandsTable,
      WriteCommand,
      $$WriteCommandsTableFilterComposer,
      $$WriteCommandsTableOrderingComposer,
      $$WriteCommandsTableAnnotationComposer,
      $$WriteCommandsTableCreateCompanionBuilder,
      $$WriteCommandsTableUpdateCompanionBuilder,
      (
        WriteCommand,
        BaseReferences<_$AppDatabase, $WriteCommandsTable, WriteCommand>,
      ),
      WriteCommand,
      PrefetchHooks Function()
    >;
typedef $$PreferencesTableCreateCompanionBuilder =
    PreferencesCompanion Function({
      required String key,
      required String value,
      Value<int> rowid,
    });
typedef $$PreferencesTableUpdateCompanionBuilder =
    PreferencesCompanion Function({
      Value<String> key,
      Value<String> value,
      Value<int> rowid,
    });

class $$PreferencesTableFilterComposer
    extends Composer<_$AppDatabase, $PreferencesTable> {
  $$PreferencesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );
}

class $$PreferencesTableOrderingComposer
    extends Composer<_$AppDatabase, $PreferencesTable> {
  $$PreferencesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$PreferencesTableAnnotationComposer
    extends Composer<_$AppDatabase, $PreferencesTable> {
  $$PreferencesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$PreferencesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $PreferencesTable,
          Preference,
          $$PreferencesTableFilterComposer,
          $$PreferencesTableOrderingComposer,
          $$PreferencesTableAnnotationComposer,
          $$PreferencesTableCreateCompanionBuilder,
          $$PreferencesTableUpdateCompanionBuilder,
          (
            Preference,
            BaseReferences<_$AppDatabase, $PreferencesTable, Preference>,
          ),
          Preference,
          PrefetchHooks Function()
        > {
  $$PreferencesTableTableManager(_$AppDatabase db, $PreferencesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PreferencesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PreferencesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PreferencesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> key = const Value.absent(),
                Value<String> value = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PreferencesCompanion(key: key, value: value, rowid: rowid),
          createCompanionCallback:
              ({
                required String key,
                required String value,
                Value<int> rowid = const Value.absent(),
              }) => PreferencesCompanion.insert(
                key: key,
                value: value,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$PreferencesTable, Preference>(table),
                  BaseReferences<_$AppDatabase, $PreferencesTable, Preference>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$PreferencesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $PreferencesTable,
      Preference,
      $$PreferencesTableFilterComposer,
      $$PreferencesTableOrderingComposer,
      $$PreferencesTableAnnotationComposer,
      $$PreferencesTableCreateCompanionBuilder,
      $$PreferencesTableUpdateCompanionBuilder,
      (
        Preference,
        BaseReferences<_$AppDatabase, $PreferencesTable, Preference>,
      ),
      Preference,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$AccountBooksTableTableManager get accountBooks =>
      $$AccountBooksTableTableManager(_db, _db.accountBooks);
  $$AssetsTableTableManager get assets =>
      $$AssetsTableTableManager(_db, _db.assets);
  $$BankCardsTableTableManager get bankCards =>
      $$BankCardsTableTableManager(_db, _db.bankCards);
  $$BudgetsTableTableManager get budgets =>
      $$BudgetsTableTableManager(_db, _db.budgets);
  $$ImportPlatformsTableTableManager get importPlatforms =>
      $$ImportPlatformsTableTableManager(_db, _db.importPlatforms);
  $$RecordsTableTableManager get records =>
      $$RecordsTableTableManager(_db, _db.records);
  $$RecordCategoriesTableTableManager get recordCategories =>
      $$RecordCategoriesTableTableManager(_db, _db.recordCategories);
  $$RemarksTableTableManager get remarks =>
      $$RemarksTableTableManager(_db, _db.remarks);
  $$RecordTemplatesTableTableManager get recordTemplates =>
      $$RecordTemplatesTableTableManager(_db, _db.recordTemplates);
  $$WishesTableTableManager get wishes =>
      $$WishesTableTableManager(_db, _db.wishes);
  $$RecordPeriodsTableTableManager get recordPeriods =>
      $$RecordPeriodsTableTableManager(_db, _db.recordPeriods);
  $$ReminderEventsTableTableManager get reminderEvents =>
      $$ReminderEventsTableTableManager(_db, _db.reminderEvents);
  $$InstallmentsTableTableManager get installments =>
      $$InstallmentsTableTableManager(_db, _db.installments);
  $$NotesTableTableManager get notes =>
      $$NotesTableTableManager(_db, _db.notes);
  $$TagsTableTableManager get tags => $$TagsTableTableManager(_db, _db.tags);
  $$TagRecordsTableTableManager get tagRecords =>
      $$TagRecordsTableTableManager(_db, _db.tagRecords);
  $$MoneySavePlansTableTableManager get moneySavePlans =>
      $$MoneySavePlansTableTableManager(_db, _db.moneySavePlans);
  $$MoneySavePlanRecordsTableTableManager get moneySavePlanRecords =>
      $$MoneySavePlanRecordsTableTableManager(_db, _db.moneySavePlanRecords);
  $$AssetBooksTableTableManager get assetBooks =>
      $$AssetBooksTableTableManager(_db, _db.assetBooks);
  $$StatStoriesTableTableManager get statStories =>
      $$StatStoriesTableTableManager(_db, _db.statStories);
  $$AutoMapsTableTableManager get autoMaps =>
      $$AutoMapsTableTableManager(_db, _db.autoMaps);
  $$CurrenciesTableTableManager get currencies =>
      $$CurrenciesTableTableManager(_db, _db.currencies);
  $$WriteCommandsTableTableManager get writeCommands =>
      $$WriteCommandsTableTableManager(_db, _db.writeCommands);
  $$PreferencesTableTableManager get preferences =>
      $$PreferencesTableTableManager(_db, _db.preferences);
}
