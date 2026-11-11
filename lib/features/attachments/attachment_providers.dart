import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../data/tools/bill_attachment_service.dart';
import '../../platform/files.dart';
import '../backup/backup_providers.dart'
    show backupAttachmentsDirectoryOverrideProvider;

export '../../data/tools/bill_attachment_service.dart';
export 'bill_images_page.dart' show BillAttachmentStrip, BillImagesPage;

final attachmentFileAccessProvider = Provider<FileAccess>(
  (ref) => const FileAccess(),
);

final attachmentDirectoryOverrideProvider =
    Provider<Future<Directory> Function()?>((ref) {
      return ref.watch(backupAttachmentsDirectoryOverrideProvider);
    });

final billAttachmentServiceProvider = FutureProvider<BillAttachmentService>((
  ref,
) async {
  final db = await ref.watch(databaseProvider.future);
  final dirOverride = ref.watch(attachmentDirectoryOverrideProvider);
  return BillAttachmentService(db, attachmentsDirectoryProvider: dirOverride);
});

/// Watches bills with non-empty `images`, optionally filtered by [bookId] (`null` = all books).
final recordsWithImagesProvider =
    StreamProvider.family<List<LedgerRecord>, int?>((ref, bookId) async* {
      final service = await ref.watch(billAttachmentServiceProvider.future);
      yield* service.watchRecordsWithImages(bookId: bookId);
    });

final orphanAttachmentScanProvider = FutureProvider<OrphanAttachmentScan>((
  ref,
) async {
  final service = await ref.watch(billAttachmentServiceProvider.future);
  return service.scanOrphanAttachments();
});

final attachmentBytesProvider = FutureProvider.family<Uint8List?, String>((
  ref,
  fileName,
) async {
  final service = await ref.watch(billAttachmentServiceProvider.future);
  return service.readAttachmentBytes(fileName);
});
