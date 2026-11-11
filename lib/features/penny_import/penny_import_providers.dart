import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/penny/penny_import_service.dart';
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
  const typeGroup = XTypeGroup(
    label: '一羽记账备份 (.penny, .yy)',
    extensions: <String>['penny', 'yy'],
  );
  final file = await openFile(
    acceptedTypeGroups: const <XTypeGroup>[typeGroup],
  );
  if (file == null) return null;
  final bytes = await file.readAsBytes();
  return PennyPickedFile(name: file.name, bytes: bytes);
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
