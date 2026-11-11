import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../features/assets/asset_detail_page.dart';
import '../features/assets/asset_editor_page.dart';
import '../features/assets/assets_page.dart';
import '../features/books/books_page.dart';
import '../features/budget/budget_page.dart';
import '../features/calendar/calendar_page.dart';
import '../features/categories/categories_page.dart';
import '../features/currencies/currencies_page.dart';
import '../features/home/home_page.dart';
import '../features/me/me_page.dart';
import '../features/records/record_detail_page.dart';
import '../features/records/record_editor_page.dart';
import '../features/search/search_page.dart';
import '../features/stats/annual_report_page.dart';
import '../features/stats/asset_trend_page.dart';
import '../features/stats/category_stats_page.dart';
import '../features/stats/stats_page.dart';
import '../features/tags/tags_page.dart';

/// Semantic routes (ADR-015). Mapping to the original app's 73 routes is kept
/// in docs/reference/ as modules are implemented.
GoRouter buildRouter() => GoRouter(
  initialLocation: '/',
  routes: [
    StatefulShellRoute.indexedStack(
      builder: (context, state, shell) => _Shell(shell),
      branches: [
        StatefulShellBranch(
          routes: [GoRoute(path: '/', builder: (_, _) => const HomePage())],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(path: '/stats', builder: (_, _) => const StatsPage()),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(path: '/assets', builder: (_, _) => const AssetsPage()),
          ],
        ),
        StatefulShellBranch(
          routes: [GoRoute(path: '/me', builder: (_, _) => const MePage())],
        ),
      ],
    ),
    GoRoute(path: '/budget', builder: (_, _) => const BudgetPage()),
    GoRoute(
      path: '/stats/category',
      builder: (_, _) => const CategoryStatsPage(),
    ),
    GoRoute(
      path: '/stats/category/:id',
      builder: (_, state) => CategoryRouteDrilldownPage(
        categoryId: int.parse(state.pathParameters['id']!),
      ),
    ),
    GoRoute(
      path: '/stats/trend',
      builder: (_, state) => AssetTrendPage(
        initialAssetId: int.tryParse(
          state.uri.queryParameters['assetId'] ?? '',
        ),
      ),
    ),
    GoRoute(
      path: '/stats/annual',
      builder: (context, state) {
        final q = state.uri.queryParameters;
        return AnnualReportPage(
          initialYear: int.tryParse(q['year'] ?? ''),
          initialBookId: int.tryParse(q['bookId'] ?? ''),
          onRecordTap: (id) => context.push('/record/$id'),
        );
      },
    ),
    GoRoute(
      path: '/record/new',
      builder: (_, state) {
        final q = state.uri.queryParameters;
        return RecordEditorPage(
          initialType: int.tryParse(q['type'] ?? ''),
          initialAsset: int.tryParse(q['asset'] ?? ''),
          initialFrom: int.tryParse(q['from'] ?? ''),
          initialTo: int.tryParse(q['to'] ?? ''),
          initialAmount: q['amount'],
          initialRemark: q['remark'],
        );
      },
    ),
    GoRoute(
      path: '/record/:id',
      builder: (_, state) =>
          RecordDetailPage(recordId: state.pathParameters['id']!),
    ),
    GoRoute(
      path: '/record/:id/edit',
      builder: (_, state) =>
          RecordEditorPage(recordId: state.pathParameters['id']!),
    ),
    GoRoute(
      path: '/assets/new',
      builder: (_, state) => AssetEditorPage(
        initialType: int.tryParse(state.uri.queryParameters['type'] ?? ''),
      ),
    ),
    GoRoute(
      path: '/assets/:id',
      builder: (_, state) =>
          AssetDetailPage(assetId: int.parse(state.pathParameters['id']!)),
    ),
    GoRoute(
      path: '/assets/:id/edit',
      builder: (_, state) =>
          AssetEditorPage(assetId: int.parse(state.pathParameters['id']!)),
    ),
    GoRoute(path: '/search', builder: (_, _) => const SearchPage()),
    GoRoute(path: '/calendar', builder: (_, _) => const CalendarPage()),
    GoRoute(path: '/books', builder: (_, _) => const BooksPage()),
    GoRoute(path: '/categories', builder: (_, _) => const CategoriesPage()),
    GoRoute(path: '/tags', builder: (_, _) => const TagsPage()),
    GoRoute(path: '/currencies', builder: (_, _) => const CurrenciesPage()),
  ],
);

class _Shell extends StatelessWidget {
  const _Shell(this.shell);
  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: shell,
    bottomNavigationBar: NavigationBar(
      selectedIndex: shell.currentIndex,
      onDestinationSelected: (i) =>
          shell.goBranch(i, initialLocation: i == shell.currentIndex),
      destinations: const [
        NavigationDestination(icon: Icon(Icons.receipt_long), label: '明细'),
        NavigationDestination(icon: Icon(Icons.pie_chart_outline), label: '统计'),
        NavigationDestination(
          icon: Icon(Icons.account_balance_wallet),
          label: '资产',
        ),
        NavigationDestination(icon: Icon(Icons.person), label: '我的'),
      ],
    ),
  );
}
