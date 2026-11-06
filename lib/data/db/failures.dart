// Public exception unwrapping only; host and worker both pin Drift 2.35.2.
// ignore: experimental_member_use
import 'package:drift/remote.dart' show DriftRemoteException;
import 'package:drift/drift.dart' show CouldNotRollBackException;
import 'package:sqlite3/common.dart' show SqliteException;
import '../../core/failure.dart';

/// Drift serializes custom exceptions to text across workers/isolate callbacks.
/// Recognize our exact safe marker; never surface raw SQL/error payloads.
Failure? databaseFailure(Object error) {
  while (error is DriftRemoteException) {
    error = error.remoteCause;
  }
  if (error is CouldNotRollBackException) {
    var cause = error.cause;
    var rollback = error.exception;
    while (cause is DriftRemoteException) {
      cause = cause.remoteCause;
    }
    while (rollback is DriftRemoteException) {
      rollback = rollback.remoteCause;
    }
    // SQLite FULL may itself abort the transaction. Drift's subsequent ROLLBACK
    // then reports "no transaction is active". Only this verified combination
    // is classified as FULL; unknown rollback failures remain unavailable.
    if (cause is SqliteException &&
        cause.resultCode == 13 &&
        rollback is SqliteException &&
        rollback.resultCode == 1 &&
        rollback.message.contains('no transaction is active')) {
      return const Failure(FailureCode.storageFull, '存储空间不足，操作已回滚');
    }
    return const Failure(
      FailureCode.storageUnavailable,
      '存储事务状态无法确认，请关闭应用后重新核对',
    );
  }
  if (error is Failure) return error;
  if (error is String && error.startsWith('TALLYISLE_FAILURE:')) {
    final name = error.substring('TALLYISLE_FAILURE:'.length);
    for (final code in FailureCode.values) {
      if (code.name == name)
        return Failure(code, switch (code) {
          FailureCode.upgradeRequired => '数据库版本较新，请使用更新的应用',
          FailureCode.migrationFailed => '升级未完成，原数据库已保留',
          FailureCode.corruptData => '数据库校验失败，原文件已保留',
          _ => '数据库操作未完成，请重试',
        });
    }
  }
  if (error is SqliteException) {
    if (error.resultCode == 13)
      return const Failure(FailureCode.storageFull, '存储空间不足，未提交');
    if (error.resultCode == 5 || error.resultCode == 6)
      return const Failure(FailureCode.conflict, '数据库忙，请重试此提交');
    if (error.resultCode == 11 || error.resultCode == 26)
      return const Failure(FailureCode.corruptData, '数据库损坏，已保留原文件');
    return const Failure(FailureCode.storageUnavailable, '无法访问数据库，操作未提交');
  }
  return null;
}

Future<T> guardDatabase<T>(Future<T> Function() operation) async {
  try {
    return await operation();
  } catch (error) {
    final failure = databaseFailure(error);
    if (failure != null) throw failure;
    rethrow;
  }
}
