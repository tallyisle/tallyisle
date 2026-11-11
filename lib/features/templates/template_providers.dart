import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../data/tools/template_remark_service.dart';

final templateRemarkServiceProvider = FutureProvider<TemplateRemarkService>((
  ref,
) async {
  final db = await ref.watch(databaseProvider.future);
  return TemplateRemarkService(db);
});

typedef TemplateFilterQuery = ({int? bookId, int? type});

final templatesQueryProvider =
    StreamProvider.family<List<RecordTemplate>, TemplateFilterQuery>((
      ref,
      filter,
    ) async* {
      final svc = await ref.watch(templateRemarkServiceProvider.future);
      yield* svc.watchTemplates(bookId: filter.bookId, type: filter.type);
    });

final templatesByBookProvider =
    StreamProvider.family<List<RecordTemplate>, int>((ref, bookId) async* {
      final svc = await ref.watch(templateRemarkServiceProvider.future);
      yield* svc.watchTemplates(bookId: bookId);
    });

final templateByIdProvider = StreamProvider.family<RecordTemplate?, int>((
  ref,
  id,
) async* {
  final svc = await ref.watch(templateRemarkServiceProvider.future);
  yield* svc.watchTemplate(id);
});

final remarksForCategoryProvider = StreamProvider.family<List<Remark>, int>((
  ref,
  catId,
) async* {
  final svc = await ref.watch(templateRemarkServiceProvider.future);
  yield* svc.watchRemarksForCategory(catId);
});

final allRemarksProvider = StreamProvider.family<List<Remark>, int?>((
  ref,
  categoryId,
) async* {
  final svc = await ref.watch(templateRemarkServiceProvider.future);
  yield* svc.watchAllRemarks(categoryId: categoryId);
});

final allBookCategoriesMapProvider = FutureProvider<Map<int, RecordCategory>>((
  ref,
) async {
  final db = await ref.watch(databaseProvider.future);
  final rows = await db.select(db.recordCategories).get();
  return <int, RecordCategory>{for (final r in rows) r.id: r};
});

/// Selected type filter on `TemplatesPage` (`null` = 全部, or a `RecordType`).
final class TemplateTypeFilterNotifier extends Notifier<int?> {
  @override
  int? build() => null;

  void select(int? type) => state = type;
}

final templateTypeFilterProvider =
    NotifierProvider<TemplateTypeFilterNotifier, int?>(
      TemplateTypeFilterNotifier.new,
    );
