import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../features/assets/assets_page.dart';
import '../features/calendar/calendar_page.dart';
import '../features/home/home_page.dart';
import '../features/me/me_page.dart';
import '../features/records/record_detail_page.dart';
import '../features/records/record_editor_page.dart';
import '../features/search/search_page.dart';

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
            GoRoute(path: '/assets', builder: (_, _) => const AssetsPage()),
          ],
        ),
        StatefulShellBranch(
          routes: [GoRoute(path: '/me', builder: (_, _) => const MePage())],
        ),
      ],
    ),
    GoRoute(
      path: '/record/new',
      builder: (_, state) => RecordEditorPage(
        initialType: int.tryParse(state.uri.queryParameters['type'] ?? ''),
      ),
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
    GoRoute(path: '/assets/new', builder: (_, _) => const AssetEditorPage()),
    GoRoute(path: '/search', builder: (_, _) => const SearchPage()),
    GoRoute(path: '/calendar', builder: (_, _) => const CalendarPage()),
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
        NavigationDestination(
          icon: Icon(Icons.account_balance_wallet),
          label: '资产',
        ),
        NavigationDestination(icon: Icon(Icons.person), label: '我的'),
      ],
    ),
  );
}
