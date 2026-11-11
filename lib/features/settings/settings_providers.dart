import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../data/settings/app_settings_service.dart';
import '../../data/settings/data_health_service.dart';
import '../../data/settings/stat_story_service.dart';
import '../../domain/rules/app_settings_rules.dart';
import '../../domain/rules/data_health_rules.dart';

/// Persistence service provider for System & Home Settings (`F-038`).
final appSettingsServiceProvider = FutureProvider<AppSettingsService>((
  ref,
) async {
  final db = await ref.watch(databaseProvider.future);
  return AppSettingsService(db);
});

/// Reactive [AppSettings] stream from `ti_preference` (`'app_settings'`).
final appSettingsProvider = StreamProvider<AppSettings>((ref) async* {
  final svc = await ref.watch(appSettingsServiceProvider.future);
  yield* svc.watchSettings();
});

/// Service provider for ADR-012 Data Health Check & atomic repair.
final dataHealthServiceProvider = FutureProvider<DataHealthService>((
  ref,
) async {
  final db = await ref.watch(databaseProvider.future);
  return DataHealthService(db);
});

/// On-demand ADR-012 Data Health Check report snapshot.
final dataHealthReportProvider = FutureProvider<DataHealthReport>((ref) async {
  final svc = await ref.watch(dataHealthServiceProvider.future);
  return svc.checkHealth();
});

/// Service provider for `stat_story` CRUD and local narrative generation.
final statStoryServiceProvider = FutureProvider<StatStoryService>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return StatStoryService(db);
});

/// Active book filter (`null` = all books) on `StatStoriesPage`.
final class StatStoriesBookFilterNotifier extends Notifier<int?> {
  @override
  int? build() => null;

  void selectBook(int? bookId) => state = bookId;
}

final statStoriesBookFilterProvider =
    NotifierProvider<StatStoriesBookFilterNotifier, int?>(
      StatStoriesBookFilterNotifier.new,
    );

/// Reactive stream of `stat_story` rows filtered by [statStoriesBookFilterProvider].
final statStoriesProvider = StreamProvider<List<StatStory>>((ref) async* {
  final svc = await ref.watch(statStoryServiceProvider.future);
  final bookId = ref.watch(statStoriesBookFilterProvider);
  yield* svc.watchStories(bookId: bookId);
});
