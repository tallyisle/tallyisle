import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/tools/category_transfer_service.dart';
import '../../platform/files.dart';

export '../../data/tools/category_transfer_service.dart';

final categoryTransferFileAccessProvider = Provider<FileAccess>(
  (ref) => const FileAccess(),
);

final categoryTransferServiceProvider = FutureProvider<CategoryTransferService>(
  (ref) async =>
      CategoryTransferService(await ref.watch(databaseProvider.future)),
);
