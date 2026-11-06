import 'package:drift/wasm.dart';

import '../../core/failure.dart';
import 'database.dart';

Future<AppDatabase> openAppDatabase() async {
  final result = await WasmDatabase.open(
    databaseName: 'tallyisle',
    sqlite3Uri: Uri.parse('sqlite3.wasm'),
    driftWorkerUri: Uri.parse('drift_worker.dart.js'),
  );
  // Fail closed: transient or unsafe storage must never accept ledger writes.
  if (result.chosenImplementation == WasmStorageImplementation.inMemory ||
      result.chosenImplementation ==
          WasmStorageImplementation.unsafeIndexedDb) {
    await result.resolvedExecutor.close();
    throw const Failure(FailureCode.storageUnavailable, '浏览器没有可用的安全持久存储');
  }
  return AppDatabase(result.resolvedExecutor);
}
