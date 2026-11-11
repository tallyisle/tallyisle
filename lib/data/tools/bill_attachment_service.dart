import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/failure.dart';
import '../../domain/ledger/record_extra.dart';
import '../../domain/rules/receipt_diy_rules.dart';
import '../../platform/files.dart';
import '../db/database.dart';
import '../db/failures.dart';

export '../../domain/rules/receipt_diy_rules.dart';

const int maxSingleAttachmentBytes = 20 * 1024 * 1024;

/// Summary of scanning `<support>/attachments/` against DB references (F-022).
final class OrphanAttachmentScan {
  const OrphanAttachmentScan({
    required this.orphanFileNames,
    required this.orphanTotalBytes,
    required this.referencedCount,
    required this.missingOnDiskNames,
  });

  final List<String> orphanFileNames;
  final int orphanTotalBytes;
  final int referencedCount;
  final List<String> missingOnDiskNames;

  int get orphanCount => orphanFileNames.length;
  int get missingCount => missingOnDiskNames.length;
}

/// Result of cleaning up unreferenced files in `<support>/attachments/` (F-022).
final class OrphanCleanupResult {
  const OrphanCleanupResult({
    required this.deletedFileNames,
    required this.freedBytes,
  });

  final List<String> deletedFileNames;
  final int freedBytes;

  int get deletedCount => deletedFileNames.length;

  Map<String, Object> toJson() => {
    'deletedFileNames': deletedFileNames,
    'freedBytes': freedBytes,
  };

  factory OrphanCleanupResult.fromJson(Map<String, Object?> json) =>
      OrphanCleanupResult(
        deletedFileNames: [
          for (final item
              in (json['deletedFileNames'] as List<Object?>? ?? const []))
            if (item is String) item,
        ],
        freedBytes: (json['freedBytes'] as int?) ?? 0,
      );
}

/// Local bill image attachment store (`<support>/attachments/`, compatible with
/// `.tally` backups) + DIY toolbar & bill location write boundary (F-022, F-036).
final class BillAttachmentService {
  BillAttachmentService(
    this.db, {
    Future<Directory> Function()? attachmentsDirectoryProvider,
  }) : _attachmentsDirProvider =
           attachmentsDirectoryProvider ?? defaultAttachmentsDirectory;

  final AppDatabase db;
  final Future<Directory> Function() _attachmentsDirProvider;

  static Directory? _headlessSupportRoot;

  static Future<Directory> defaultAttachmentsDirectory() async {
    try {
      final support = await getApplicationSupportDirectory();
      return Directory(p.join(support.path, 'attachments'));
    } on MissingPluginException {
      final root = _headlessSupportRoot ??= await Directory.systemTemp
          .createTemp('tallyisle_support_');
      return Directory(p.join(root.path, 'attachments'));
    }
  }

  int _now() => db.nowMs();

  Future<T> _command<T>(
    String commandId,
    List<Object?> payload,
    Future<String> Function() body,
    T Function(String resultId) decode,
  ) async {
    if (commandId.isEmpty || commandId.length > 128) {
      throw const Failure(FailureCode.validation, '提交标识无效');
    }
    final hash = sha256.convert(utf8.encode(jsonEncode(payload))).toString();
    return guardDatabase(
      () => db.transaction(() async {
        final previous = await (db.select(
          db.writeCommands,
        )..where((t) => t.commandId.equals(commandId))).getSingleOrNull();
        if (previous != null) {
          if (previous.payloadHash != hash) {
            throw const Failure(FailureCode.conflict, '同一提交标识的内容发生变化');
          }
          return decode(previous.resultId);
        }
        final resultText = await body();
        await db
            .into(db.writeCommands)
            .insert(
              WriteCommandsCompanion.insert(
                commandId: commandId,
                payloadHash: hash,
                resultId: resultText,
                committedAt: _now(),
              ),
            );
        return decode(resultText);
      }),
    );
  }

  // ---------------------------------------------------------------------------
  // F-022: Attachment File Storage & `record.images`
  // ---------------------------------------------------------------------------

  static String _detectImageExtension(Uint8List bytes, String? originalName) {
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'png';
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return 'jpg';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'webp';
    }
    if (bytes.length >= 4 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x38) {
      return 'gif';
    }
    if (originalName != null) {
      final ext = p.extension(originalName).toLowerCase().replaceFirst('.', '');
      if (const {
        'jpg',
        'jpeg',
        'png',
        'webp',
        'gif',
        'bmp',
        'heic',
      }.contains(ext)) {
        return ext;
      }
    }
    return 'jpg';
  }

  /// Resolves a validated relative attachment [fileName] inside `<support>/attachments/`.
  Future<File> resolveAttachmentFile(String fileName) async {
    final safeName = validateAttachmentFileName(fileName);
    final dir = await _attachmentsDirProvider();
    final canonicalRoot = p.normalize(dir.absolute.path);
    final candidatePath = p.normalize(p.join(canonicalRoot, safeName));
    if (p.dirname(candidatePath) != canonicalRoot) {
      throw Failure(FailureCode.validation, '非法的图片附件路径：$fileName');
    }
    return File(candidatePath);
  }

  /// Reads raw bytes of [fileName] from `<support>/attachments/`, or `null` if missing.
  Future<Uint8List?> readAttachmentBytes(String fileName) async {
    final file = await resolveAttachmentFile(fileName);
    if (!await file.exists()) return null;
    try {
      return await file.readAsBytes();
    } on FileSystemException {
      throw const Failure(FailureCode.storageUnavailable, '无法读取本地图片附件');
    }
  }

  /// Atomically stores [bytes] into `<support>/attachments/` and returns the safe relative filename.
  Future<String> saveImageBytes({
    required Uint8List bytes,
    String? originalName,
  }) async {
    if (bytes.isEmpty) {
      throw const Failure(FailureCode.validation, '图片内容不能为空');
    }
    if (bytes.length > maxSingleAttachmentBytes) {
      throw const Failure(FailureCode.validation, '单张图片大小不能超过 20 MB');
    }
    final ext = _detectImageExtension(bytes, originalName);
    final digest = sha256.convert(bytes).toString().substring(0, 24);
    final fileName = validateAttachmentFileName('img_$digest.$ext');

    try {
      final dir = await _attachmentsDirProvider();
      await dir.create(recursive: true);
      final dst = File(p.join(dir.path, fileName));
      if (!await dst.exists()) {
        final tmp = File(
          p.join(dir.path, '$fileName.${_now().toRadixString(36)}.tmp'),
        );
        await tmp.writeAsBytes(bytes, flush: true);
        await tmp.rename(dst.path);
      }
      return fileName;
    } on FileSystemException {
      throw const Failure(FailureCode.storageUnavailable, '保存图片附件到本地失败');
    }
  }

  /// Prompts the user to pick an image via [FileAccess], saves it to `<support>/attachments/`,
  /// and returns the stored relative filename.
  Future<String> pickAndSaveImage({required FileAccess fileAccess}) async {
    final selected = await fileAccess.pickBytes(
      allowedExtensions: const [
        'jpg',
        'jpeg',
        'png',
        'webp',
        'gif',
        'bmp',
        'heic',
      ],
    );
    return saveImageBytes(bytes: selected.bytes, originalName: selected.name);
  }

  /// Atomically sets `record.images` on [recordId] (validating paths & max 9 images, R5).
  Future<List<String>> setRecordImages({
    required String commandId,
    required String recordId,
    required Iterable<String> imageNames,
  }) {
    final encoded = encodeRecordImages(imageNames);
    final normalizedList = encoded == null
        ? const <String>[]
        : parseRecordImages(encoded);
    return _command(
      commandId,
      ['set-record-images-v1', recordId, normalizedList],
      () async {
        final existing = await (db.select(
          db.records,
        )..where((t) => t.recordId.equals(recordId))).getSingleOrNull();
        if (existing == null) {
          throw const Failure(FailureCode.conflict, '账单不存在或已删除');
        }
        await (db.update(db.records)..where((t) => t.recordId.equals(recordId)))
            .write(RecordsCompanion(images: Value(encoded)));
        return jsonEncode(normalizedList);
      },
      (raw) => [
        for (final item in (jsonDecode(raw) as List<Object?>))
          if (item is String) item,
      ],
    );
  }

  /// Watches all bills that carry at least one image attachment, newest first.
  Stream<List<LedgerRecord>> watchRecordsWithImages({int? bookId}) {
    final query = db.select(db.records)
      ..where(
        (t) =>
            t.images.isNotNull() &
            t.images.equals('').not() &
            (bookId == null
                ? const Constant(true)
                : t.accountBookId.equals(bookId)),
      )
      ..orderBy([
        (t) => OrderingTerm.desc(t.recordTime),
        (t) => OrderingTerm.desc(t.createDate),
        (t) => OrderingTerm.desc(t.recordId),
      ]);
    return query.watch();
  }

  Future<Set<String>> _loadAllReferencedAttachmentNames() async {
    final recRows = await db
        .customSelect(
          "SELECT images FROM record WHERE images IS NOT NULL AND TRIM(images) != ''",
        )
        .get();
    final periodRows = await db
        .customSelect(
          "SELECT images FROM record_period WHERE images IS NOT NULL AND TRIM(images) != ''",
        )
        .get();
    final instRows = await db
        .customSelect(
          "SELECT images FROM installment WHERE images IS NOT NULL AND TRIM(images) != ''",
        )
        .get();
    return collectReferencedAttachmentNames([
      for (final r in recRows) r.read<String?>('images'),
      for (final r in periodRows) r.read<String?>('images'),
      for (final r in instRows) r.read<String?>('images'),
    ]);
  }

  /// Scans `<support>/attachments/` against `record`, `record_period`, and `installment`.
  Future<OrphanAttachmentScan> scanOrphanAttachments() async {
    final referenced = await guardDatabase(_loadAllReferencedAttachmentNames);
    final dir = await _attachmentsDirProvider();
    final diskSizes = <String, int>{};
    if (await dir.exists()) {
      await for (final entity in dir.list(
        recursive: false,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (name.toLowerCase().endsWith('.tmp')) continue;
        diskSizes[name] = await entity.length();
      }
    }

    final orphanNames = <String>[
      for (final name in diskSizes.keys)
        if (!referenced.contains(name)) name,
    ]..sort();
    var orphanBytes = 0;
    for (final name in orphanNames) {
      orphanBytes += diskSizes[name] ?? 0;
    }

    final missingNames = <String>[
      for (final ref in referenced)
        if (!diskSizes.containsKey(ref)) ref,
    ]..sort();

    return OrphanAttachmentScan(
      orphanFileNames: orphanNames,
      orphanTotalBytes: orphanBytes,
      referencedCount: referenced.length,
      missingOnDiskNames: missingNames,
    );
  }

  /// Deletes unreferenced attachment files from `<support>/attachments/` with ADR-009 idempotency.
  Future<OrphanCleanupResult> cleanupOrphanAttachments({
    required String commandId,
  }) => _command(
    commandId,
    ['cleanup-orphan-attachments-v1'],
    () async {
      final referenced = await _loadAllReferencedAttachmentNames();
      final dir = await _attachmentsDirProvider();
      final deleted = <String>[];
      var freedBytes = 0;

      if (await dir.exists()) {
        final candidates = <File>[];
        await for (final entity in dir.list(
          recursive: false,
          followLinks: false,
        )) {
          if (entity is! File) continue;
          final name = p.basename(entity.path);
          if (name.toLowerCase().endsWith('.tmp')) continue;
          if (!referenced.contains(name)) {
            candidates.add(entity);
          }
        }
        candidates.sort(
          (a, b) => p.basename(a.path).compareTo(p.basename(b.path)),
        );
        for (final file in candidates) {
          final name = p.basename(file.path);
          final len = await file.length();
          await file.delete();
          deleted.add(name);
          freedBytes += len;
        }
      }

      return jsonEncode(
        OrphanCleanupResult(
          deletedFileNames: deleted,
          freedBytes: freedBytes,
        ).toJson(),
      );
    },
    (raw) =>
        OrphanCleanupResult.fromJson(jsonDecode(raw) as Map<String, Object?>),
  );

  // ---------------------------------------------------------------------------
  // F-036: DIY Toolbar (`ti_preference`) & Bill Location (`extra_info.loc`)
  // ---------------------------------------------------------------------------

  /// Reactive stream of [DiyToolbarConfig] from `ti_preference` (`record_diy_toolbar`).
  Stream<DiyToolbarConfig> watchDiyToolbarConfig() =>
      (db.select(db.preferences)
            ..where((t) => t.key.equals(prefKeyRecordDiyToolbar)))
          .watchSingleOrNull()
          .map((row) => DiyToolbarConfig.decode(row?.value));

  /// Reads current [DiyToolbarConfig] snapshot.
  Future<DiyToolbarConfig> getDiyToolbarConfig() async {
    final row = await guardDatabase(
      () => (db.select(
        db.preferences,
      )..where((t) => t.key.equals(prefKeyRecordDiyToolbar))).getSingleOrNull(),
    );
    return DiyToolbarConfig.decode(row?.value);
  }

  /// Saves [config] into `ti_preference` (`record_diy_toolbar`) with ADR-009 idempotency.
  Future<DiyToolbarConfig> saveDiyToolbarConfig({
    required String commandId,
    required DiyToolbarConfig config,
  }) {
    final encoded = config.encode();
    return _command(
      commandId,
      ['save-diy-toolbar-v1', config.toJson()],
      () async {
        await db
            .into(db.preferences)
            .insertOnConflictUpdate(
              PreferencesCompanion.insert(
                key: prefKeyRecordDiyToolbar,
                value: encoded,
              ),
            );
        return encoded;
      },
      DiyToolbarConfig.decode,
    );
  }

  /// Sets or clears `record.extra_info.loc` while preserving all other `extra_info` keys.
  Future<BillLocationInfo?> setRecordLocation({
    required String commandId,
    required String recordId,
    required BillLocationInfo? location,
  }) {
    final normalizedLoc = location == null || location.isEmpty
        ? null
        : location;
    return _command(
      commandId,
      ['set-record-location-v1', recordId, normalizedLoc?.toJson()],
      () async {
        final existing = await (db.select(
          db.records,
        )..where((t) => t.recordId.equals(recordId))).getSingleOrNull();
        if (existing == null) {
          throw const Failure(FailureCode.conflict, '账单不存在或已删除');
        }
        final extra = RecordExtra.parse(existing.extraInfo)
          ..location = normalizedLoc;
        await (db.update(db.records)..where((t) => t.recordId.equals(recordId)))
            .write(RecordsCompanion(extraInfo: Value(extra.encode())));
        return jsonEncode(normalizedLoc?.toJson());
      },
      (raw) => BillLocationInfo.fromJson(jsonDecode(raw)),
    );
  }
}
