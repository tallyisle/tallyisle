import 'dart:io';

import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'database.dart';

/// File name is new on purpose: databases created by the pre-2026-11 foundation
/// (`profiles/*/tallyisle_dev_v1.sqlite`) use an incompatible schema and are left untouched.
const databaseFileName = 'tallyisle.sqlite';

AppDatabase openDatabaseFile(File file) => AppDatabase(
  NativeDatabase.createInBackground(
    file,
    setup: (db) {
      db.execute('PRAGMA busy_timeout = 5000');
      db.execute('PRAGMA journal_mode = WAL');
    },
  ),
);

Future<AppDatabase> openAppDatabase() async {
  final support = await getApplicationSupportDirectory();
  final directory = Directory(p.join(support.path, 'data'));
  await directory.create(recursive: true);
  return openDatabaseFile(File(p.join(directory.path, databaseFileName)));
}
