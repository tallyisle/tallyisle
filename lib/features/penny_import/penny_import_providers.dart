import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/failure.dart';
import '../../data/penny/penny_import_service.dart';
import '../../platform/files.dart';
import '../reminder/reminder_providers.dart';

/// Picked `.penny` / `.yy` backup file name and raw bytes.
final class PennyPickedFile {
  const PennyPickedFile({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

/// Callback signature for selecting a `.penny` / `.yy` backup file.
typedef PennyFilePicker = Future<PennyPickedFile?> Function();

/// Opens the system file selector filtered for `.penny` and `.yy` backups.
Future<PennyPickedFile?> pickPennyBackupFile() async {
  try {
    final selected = await const FileAccess().pickBytes(
      allowedExtensions: const <String>['penny', 'yy'],
    );
    return PennyPickedFile(name: selected.name, bytes: selected.bytes);
  } on Failure catch (f) {
    if (f.code == FailureCode.cancelled) return null;
    rethrow;
  }
}

final pennyFilePickerProvider = Provider<PennyFilePicker>(
  (ref) => pickPennyBackupFile,
);

final pennyImportServiceProvider = FutureProvider<PennyImportService>((
  ref,
) async {
  final db = await ref.watch(databaseProvider.future);
  final reminderService = await ref.watch(reminderServiceProvider.future);
  return PennyImportService(db, reminderService: reminderService);
});
