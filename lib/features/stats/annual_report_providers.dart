import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/repo/annual_report_queries.dart';
import '../../domain/rules/annual_report.dart';

/// Provider for [AnnualReportQueries] data access.
final annualReportQueriesProvider = FutureProvider<AnnualReportQueries>((
  ref,
) async {
  final db = await ref.watch(databaseProvider.future);
  return AnnualReportQueries(db);
});

/// Watches available years for a given [bookId] (null means all books).
final annualAvailableYearsProvider = StreamProvider.family<List<int>, int?>((
  ref,
  bookId,
) async* {
  final q = await ref.watch(annualReportQueriesProvider.future);
  yield* q.watchAvailableYears(bookId: bookId);
});

/// Arguments for watching an annual report.
typedef AnnualReportQueryArgs = ({int year, int? bookId, int startDay});

/// Watches the full [AnnualReportResult] stream for specified year, book and startDay.
final annualReportDataProvider =
    StreamProvider.family<AnnualReportResult, AnnualReportQueryArgs>((
      ref,
      args,
    ) async* {
      final q = await ref.watch(annualReportQueriesProvider.future);
      yield* q.watchAnnualReport(
        year: args.year,
        startDay: args.startDay,
        bookId: args.bookId,
      );
    });
