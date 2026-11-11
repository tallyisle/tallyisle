import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../core/failure.dart';
import '../../core/money.dart';
import '../../core/zip_archive.dart';

const int tallyFormatVersion = 1;
const String tallyAppName = 'TallyIsle';
const String tallyDefaultAppVersion = '1.0.0';
const int tallySchemaVersion = 42;
const String tallyManifestFileName = 'manifest.json';
const String tallyDatabaseFileName = 'database.json';
const String tallyAttachmentsPrefix = 'attachments/';

const int defaultWebDavKeepCount = 10;
const int defaultAutoBackupIntervalHours = 24;
const int defaultAutoBackupCooldownMs =
    defaultAutoBackupIntervalHours * 60 * 60 * 1000;

/// Maximum integer magnitude representable without precision loss in IEEE-754
/// double / JavaScript `Number.MAX_SAFE_INTEGER` (`2^53 - 1`).
final BigInt maxSafeJsInteger = BigInt.parse('9007199254740991');

/// All 22 Room v42 business tables covered by TallyIsle `.tally` backups (R1, ADR-013).
const List<String> tallyBusinessTables = <String>[
  'account_book',
  'record',
  'asset',
  'record_category',
  'budget',
  'tag',
  'tag_record',
  'installment',
  'record_period',
  'reminder_event',
  'record_template',
  'bank_card',
  'wish',
  'remark',
  'money_save_plan',
  'money_save_plan_record',
  'asset_book',
  'stat_story',
  'auto_map',
  'import_platform',
  'note',
  'currency',
];

final RegExp _hex64Pattern = RegExp(r'^[0-9a-fA-F]{64}$');
final RegExp _strictIntPattern = RegExp(r'^-?(?:0|[1-9][0-9]*)$');

/// Computes lowercase 64-character SHA-256 hex digest of [bytes].
String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

/// Formats a canonical `.tally` backup filename (`backup_YYYYMMDD_HHMMSS.tally`).
String formatTallyBackupFileName(DateTime when) {
  String pad2(int n) => n.toString().padLeft(2, '0');
  final y = when.year.toString().padLeft(4, '0');
  final m = pad2(when.month);
  final d = pad2(when.day);
  final hh = pad2(when.hour);
  final mm = pad2(when.minute);
  final ss = pad2(when.second);
  return 'backup_${y}${m}${d}_${hh}${mm}${ss}.tally';
}

/// Serializes an `int64` minor-unit [BigInt] losslessly for JSON (ADR-011, R2).
///
/// Values within JS safe integer range (`|v| <= 2^53 - 1`) are emitted as JSON
/// integers (e.g. `10050`), while larger `int64` magnitudes up to `±(2^63 - 1)`
/// are emitted as exact decimal strings so `JSON.parse` never loses precision.
Object encodeMinorJson(BigInt minor) {
  final checked = Money.minor(minor).storageMinor;
  if (checked.abs() <= maxSafeJsInteger) {
    return checked.toInt();
  }
  return checked.toString();
}

Object? encodeNullableMinorJson(BigInt? minor) =>
    minor == null ? null : encodeMinorJson(minor);

/// Parses an `int64` minor-unit [BigInt] from JSON (`int` or decimal `String`),
/// strictly rejecting floating-point values or out-of-range integers (R2).
BigInt decodeMinorJson(Object? raw, {required String field}) {
  if (raw is BigInt) {
    try {
      return Money.minor(raw).storageMinor;
    } on Failure {
      throw Failure(FailureCode.corruptData, '字段 $field 超出 int64 整数分范围');
    }
  }
  if (raw is int) {
    try {
      return Money.minor(BigInt.from(raw)).storageMinor;
    } on Failure {
      throw Failure(FailureCode.corruptData, '字段 $field 超出 int64 整数分范围');
    }
  }
  if (raw is String) {
    if (!_strictIntPattern.hasMatch(raw)) {
      throw Failure(FailureCode.corruptData, '字段 $field 必须为整数分字符串，拒绝小数或非法字符');
    }
    try {
      return Money.minor(BigInt.parse(raw)).storageMinor;
    } on Failure {
      throw Failure(FailureCode.corruptData, '字段 $field 超出 int64 整数分范围');
    }
  }
  throw Failure(FailureCode.corruptData, '字段 $field 必须为整数分，禁止浮点数或空值');
}

BigInt? decodeNullableMinorJson(Object? raw, {required String field}) =>
    raw == null ? null : decodeMinorJson(raw, field: field);

/// Validates and normalizes an attachment archive path (`attachments/<relPath>`).
String normalizeAttachmentArchivePath(String rawPath) {
  final stripped = rawPath.startsWith(tallyAttachmentsPrefix)
      ? rawPath
      : '$tallyAttachmentsPrefix$rawPath';
  final clean = validateZipEntryPath(stripped);
  if (!clean.startsWith(tallyAttachmentsPrefix) ||
      clean.length <= tallyAttachmentsPrefix.length) {
    throw Failure(
      FailureCode.corruptData,
      '附件路径必须位于 attachments/ 目录下：$rawPath',
    );
  }
  return clean;
}

/// Parsed `manifest.json` inside a `.tally` backup container (§2.2.A).
final class TallyManifest {
  TallyManifest({
    required this.formatVersion,
    required this.appName,
    required this.appVersion,
    required this.schemaVersion,
    required this.createdAtMs,
    required Map<String, int> tableCounts,
    required this.databaseFile,
    required String databaseSha256,
    required Map<String, String> filesChecksum,
    this.includeAttachments = true,
  }) : tableCounts = Map<String, int>.unmodifiable(tableCounts),
       databaseSha256 = databaseSha256.toLowerCase(),
       filesChecksum = Map<String, String>.unmodifiable({
         for (final entry in filesChecksum.entries)
           entry.key: entry.value.toLowerCase(),
       });

  final int formatVersion;
  final String appName;
  final String appVersion;
  final int schemaVersion;
  final int createdAtMs;
  final Map<String, int> tableCounts;
  final String databaseFile;
  final String databaseSha256;
  final Map<String, String> filesChecksum;
  final bool includeAttachments;

  int get totalRows =>
      tableCounts.values.fold<int>(0, (sum, count) => sum + count);

  int get recordCount => tableCounts['record'] ?? 0;
  int get noteCount => tableCounts['note'] ?? 0;
  int get currencyCount => tableCounts['currency'] ?? 0;
  int get attachmentCount => filesChecksum.length;

  Map<String, Object> toJson() => <String, Object>{
    'format_version': formatVersion,
    'app_name': appName,
    'app_version': appVersion,
    'schema_version': schemaVersion,
    'created_at_ms': createdAtMs,
    'include_attachments': includeAttachments,
    'table_counts': tableCounts,
    'database_file': databaseFile,
    'database_sha256': databaseSha256,
    'files_checksum': filesChecksum,
  };

  factory TallyManifest.fromJson(Map<String, Object?> json) {
    final formatVersion = json['format_version'];
    if (formatVersion is! int) {
      throw const Failure(FailureCode.corruptData, '备份清单缺少有效的 format_version');
    }
    if (formatVersion > tallyFormatVersion) {
      throw const Failure(FailureCode.upgradeRequired, '备份格式版本较新，请升级帐屿后再恢复');
    }
    if (formatVersion < 1) {
      throw const Failure(FailureCode.corruptData, '备份格式版本无效');
    }

    final appName = json['app_name'];
    if (appName is! String || appName != tallyAppName) {
      throw const Failure(FailureCode.corruptData, '不是有效的帐屿（TallyIsle）备份文件');
    }

    final appVersion = json['app_version'] is String
        ? json['app_version'] as String
        : tallyDefaultAppVersion;

    final schemaVersion = json['schema_version'];
    if (schemaVersion is! int || schemaVersion <= 0) {
      throw const Failure(FailureCode.corruptData, '备份清单 schema_version 无效');
    }
    if (schemaVersion > tallySchemaVersion) {
      throw const Failure(FailureCode.upgradeRequired, '备份数据库结构版本较新，请升级帐屿后再恢复');
    }

    final createdAtMs = json['created_at_ms'];
    if (createdAtMs is! int || createdAtMs < 0) {
      throw const Failure(FailureCode.corruptData, '备份清单 created_at_ms 无效');
    }

    final includeAttachments = json['include_attachments'] is bool
        ? json['include_attachments'] as bool
        : true;

    final databaseFile = json['database_file'];
    if (databaseFile is! String ||
        databaseFile.isEmpty ||
        databaseFile.contains('/')) {
      throw const Failure(FailureCode.corruptData, '备份清单 database_file 无效');
    }
    validateZipEntryPath(databaseFile);

    final databaseSha256 = json['database_sha256'];
    if (databaseSha256 is! String || !_hex64Pattern.hasMatch(databaseSha256)) {
      throw const Failure(FailureCode.corruptData, '备份清单 database_sha256 格式损坏');
    }

    final rawCounts = json['table_counts'];
    if (rawCounts is! Map) {
      throw const Failure(FailureCode.corruptData, '备份清单 table_counts 缺失');
    }
    final tableCounts = <String, int>{};
    for (final entry in rawCounts.entries) {
      final k = entry.key;
      final v = entry.value;
      if (k is! String || v is! int || v < 0) {
        throw const Failure(FailureCode.corruptData, '备份清单 table_counts 条目损坏');
      }
      tableCounts[k] = v;
    }

    final rawFiles = json['files_checksum'];
    if (rawFiles is! Map) {
      throw const Failure(FailureCode.corruptData, '备份清单 files_checksum 缺失');
    }
    final filesChecksum = <String, String>{};
    for (final entry in rawFiles.entries) {
      final k = entry.key;
      final v = entry.value;
      if (k is! String || v is! String || !_hex64Pattern.hasMatch(v)) {
        throw const Failure(
          FailureCode.corruptData,
          '备份清单 files_checksum 条目损坏',
        );
      }
      final cleanPath = validateZipEntryPath(k);
      if (!cleanPath.startsWith(tallyAttachmentsPrefix) ||
          cleanPath.length <= tallyAttachmentsPrefix.length) {
        throw Failure(FailureCode.corruptData, '备份清单附件路径非法：$cleanPath');
      }
      filesChecksum[cleanPath] = v.toLowerCase();
    }

    return TallyManifest(
      formatVersion: formatVersion,
      appName: appName,
      appVersion: appVersion,
      schemaVersion: schemaVersion,
      createdAtMs: createdAtMs,
      tableCounts: tableCounts,
      databaseFile: databaseFile,
      databaseSha256: databaseSha256,
      filesChecksum: filesChecksum,
      includeAttachments: includeAttachments,
    );
  }
}

/// Encoded `.tally` archive bytes paired with its generated [TallyManifest].
final class PackedTallyBackup {
  const PackedTallyBackup({required this.bytes, required this.manifest});

  final Uint8List bytes;
  final TallyManifest manifest;
}

/// Verified unpacked `.tally` archive ready for stage-3 atomic DB replacement.
final class VerifiedTallyArchive {
  VerifiedTallyArchive({
    required this.manifest,
    required Map<String, List<Map<String, Object?>>> tables,
    required Map<String, Uint8List> attachments,
  }) : tables = Map<String, List<Map<String, Object?>>>.unmodifiable({
         for (final entry in tables.entries)
           entry.key: List<Map<String, Object?>>.unmodifiable(entry.value),
       }),
       attachments = Map<String, Uint8List>.unmodifiable(attachments);

  final TallyManifest manifest;
  final Map<String, List<Map<String, Object?>>> tables;

  /// Keys are validated archive paths under `attachments/` (e.g. `attachments/a.jpg`).
  final Map<String, Uint8List> attachments;
}

/// Packs all 22 business tables and optional attachment files into a standard
/// `.tally` ZIP archive with SHA-256 checksums (§2.2, R1, R2, R3, §6.3).
PackedTallyBackup packTallyArchive({
  required Map<String, List<Map<String, Object?>>> tables,
  Map<String, Uint8List> attachments = const <String, Uint8List>{},
  required int createdAtMs,
  String appVersion = tallyDefaultAppVersion,
  bool includeAttachments = true,
}) {
  final canonicalTables = <String, List<Map<String, Object?>>>{};
  final tableCounts = <String, int>{};
  for (final tableName in tallyBusinessTables) {
    final rows = tables[tableName] ?? const <Map<String, Object?>>[];
    canonicalTables[tableName] = rows;
    tableCounts[tableName] = rows.length;
  }

  final databaseBytes = Uint8List.fromList(
    utf8.encode(jsonEncode(canonicalTables)),
  );
  final databaseSha256 = sha256Hex(databaseBytes);

  final normalizedAttachments = <String, Uint8List>{};
  final filesChecksum = <String, String>{};
  if (includeAttachments && attachments.isNotEmpty) {
    final sortedKeys = attachments.keys.toList()..sort();
    for (final rawKey in sortedKeys) {
      final bytes = attachments[rawKey]!;
      final archivePath = normalizeAttachmentArchivePath(rawKey);
      if (normalizedAttachments.containsKey(archivePath)) {
        throw Failure(FailureCode.validation, '重复的附件路径：$archivePath');
      }
      normalizedAttachments[archivePath] = bytes;
      filesChecksum[archivePath] = sha256Hex(bytes);
    }
  }

  final manifest = TallyManifest(
    formatVersion: tallyFormatVersion,
    appName: tallyAppName,
    appVersion: appVersion,
    schemaVersion: tallySchemaVersion,
    createdAtMs: createdAtMs,
    tableCounts: tableCounts,
    databaseFile: tallyDatabaseFileName,
    databaseSha256: databaseSha256,
    filesChecksum: filesChecksum,
    includeAttachments: includeAttachments,
  );

  final manifestBytes = Uint8List.fromList(
    utf8.encode(const JsonEncoder.withIndent('  ').convert(manifest.toJson())),
  );

  final modAt = DateTime.fromMillisecondsSinceEpoch(createdAtMs, isUtc: true);
  final zipEntries = <ZipEntry>[
    ZipEntry(
      name: tallyManifestFileName,
      bytes: manifestBytes,
      method: ZipCompressionMethod.deflate,
      modifiedAt: modAt,
    ),
    ZipEntry(
      name: tallyDatabaseFileName,
      bytes: databaseBytes,
      method: ZipCompressionMethod.deflate,
      modifiedAt: modAt,
    ),
    for (final entry in normalizedAttachments.entries)
      ZipEntry(
        name: entry.key,
        bytes: entry.value,
        method: ZipCompressionMethod.deflate,
        modifiedAt: modAt,
      ),
  ];

  final zipBytes = ZipArchive.encode(zipEntries, defaultModifiedAt: modAt);
  return PackedTallyBackup(bytes: zipBytes, manifest: manifest);
}

/// Unpacks a `.tally` ZIP archive and verifies `manifest.json`,
/// `database_sha256`, `table_counts`, and every `attachments/*` SHA-256
/// checksum BEFORE any database mutation occurs (R3, R5).
VerifiedTallyArchive unpackAndVerifyTallyArchive(Uint8List archiveBytes) {
  final archive = ZipArchive.decode(archiveBytes);

  final manifestEntry = archive[tallyManifestFileName];
  if (manifestEntry == null) {
    throw const Failure(FailureCode.corruptData, '备份包缺少 manifest.json');
  }

  final Object? decodedManifest;
  try {
    decodedManifest = jsonDecode(utf8.decode(manifestEntry.bytes));
  } catch (_) {
    throw const Failure(FailureCode.corruptData, '备份包 manifest.json 解析失败');
  }
  if (decodedManifest is! Map<String, Object?>) {
    throw const Failure(FailureCode.corruptData, '备份包 manifest.json 结构损坏');
  }
  final manifest = TallyManifest.fromJson(decodedManifest);

  final dbEntry = archive[manifest.databaseFile];
  if (dbEntry == null) {
    throw Failure(
      FailureCode.corruptData,
      '备份包缺少数据库文件 ${manifest.databaseFile}',
    );
  }
  final actualDbSha = sha256Hex(dbEntry.bytes);
  if (actualDbSha != manifest.databaseSha256) {
    throw const Failure(
      FailureCode.corruptData,
      '备份数据文件哈希校验失败（文件已被修改或损坏），已拒绝恢复',
    );
  }

  final verifiedAttachments = <String, Uint8List>{};
  for (final expected in manifest.filesChecksum.entries) {
    final attEntry = archive[expected.key];
    if (attEntry == null) {
      throw Failure(FailureCode.corruptData, '备份包缺少清单登记的附件文件：${expected.key}');
    }
    final actualAttSha = sha256Hex(attEntry.bytes);
    if (actualAttSha != expected.value) {
      throw Failure(
        FailureCode.corruptData,
        '备份附件哈希校验失败（${expected.key}），已拒绝恢复',
      );
    }
    verifiedAttachments[expected.key] = attEntry.bytes;
  }

  for (final entry in archive.entries) {
    if (entry.name.startsWith(tallyAttachmentsPrefix) &&
        !manifest.filesChecksum.containsKey(entry.name)) {
      throw Failure(
        FailureCode.corruptData,
        '备份包存在未在清单登记的额外附件（${entry.name}），已拒绝恢复',
      );
    }
  }

  final Object? decodedDb;
  try {
    decodedDb = jsonDecode(utf8.decode(dbEntry.bytes));
  } catch (_) {
    throw const Failure(FailureCode.corruptData, '备份数据库 JSON 内容损坏');
  }
  if (decodedDb is! Map<String, Object?>) {
    throw const Failure(FailureCode.corruptData, '备份数据库 JSON 顶层结构必须为对象');
  }

  final parsedTables = <String, List<Map<String, Object?>>>{};
  for (final tableName in tallyBusinessTables) {
    final rawList = decodedDb[tableName];
    if (rawList == null) {
      parsedTables[tableName] = const <Map<String, Object?>>[];
      continue;
    }
    if (rawList is! List) {
      throw Failure(FailureCode.corruptData, '备份表 $tableName 格式必须为数组');
    }
    final rows = <Map<String, Object?>>[];
    for (final item in rawList) {
      if (item is! Map<String, Object?>) {
        throw Failure(FailureCode.corruptData, '备份表 $tableName 行记录必须为对象');
      }
      rows.add(item);
    }
    parsedTables[tableName] = rows;
  }

  for (final countEntry in manifest.tableCounts.entries) {
    if (!parsedTables.containsKey(countEntry.key)) continue;
    final actualCount = parsedTables[countEntry.key]!.length;
    if (actualCount != countEntry.value) {
      throw Failure(
        FailureCode.corruptData,
        '备份表 ${countEntry.key} 记录数（$actualCount）与清单（${countEntry.value}）不一致',
      );
    }
  }

  return VerifiedTallyArchive(
    manifest: manifest,
    tables: parsedTables,
    attachments: verifiedAttachments,
  );
}

/// Resolves the active `current_book_id` after restoring `account_book` rows:
/// selects book `1` if present, otherwise the first book ordered by `(sort, id)`,
/// or `1` when empty.
int resolveRestoredActiveBookId(Iterable<({int id, int sort})> books) {
  final list = books.toList();
  if (list.isEmpty) return 1;
  for (final b in list) {
    if (b.id == 1) return 1;
  }
  list.sort((a, b) {
    final bySort = a.sort.compareTo(b.sort);
    return bySort != 0 ? bySort : a.id.compareTo(b.id);
  });
  return list.first.id;
}

/// Evaluates R7 silent auto-backup eligibility:
/// `enabled && webDavConfigured && localDataChanged && elapsed >= cooldownMs`.
bool shouldTriggerAutoBackup({
  required bool enabled,
  required bool webDavConfigured,
  required bool localDataChanged,
  required int? lastBackupAtMs,
  required int nowMs,
  int cooldownMs = defaultAutoBackupCooldownMs,
}) {
  if (!enabled || !webDavConfigured || !localDataChanged) {
    return false;
  }
  if (lastBackupAtMs == null) {
    return true;
  }
  return (nowMs - lastBackupAtMs) >= cooldownMs;
}

/// Minimal metadata item used for backup retention pruning (§6.2).
final class BackupRetentionItem {
  const BackupRetentionItem({
    required this.fileName,
    required this.modifiedAtMs,
  });

  final String fileName;
  final int modifiedAtMs;
}

/// Selects older backup files exceeding [keepCount] (sorted newest-first by
/// `(modifiedAtMs, fileName)`) for automatic retention cleanup (§6.2).
List<String> selectBackupsToPrune(
  Iterable<BackupRetentionItem> items, {
  int keepCount = defaultWebDavKeepCount,
}) {
  if (keepCount <= 0) return const <String>[];
  final sorted = items.toList()
    ..sort((a, b) {
      final byTime = b.modifiedAtMs.compareTo(a.modifiedAtMs);
      if (byTime != 0) return byTime;
      return b.fileName.compareTo(a.fileName);
    });
  if (sorted.length <= keepCount) return const <String>[];
  return <String>[
    for (var i = keepCount; i < sorted.length; i++) sorted[i].fileName,
  ];
}
