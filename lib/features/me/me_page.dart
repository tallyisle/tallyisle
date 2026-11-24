import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/adaptive.dart';
import '../../app/providers.dart';
import '../attachments/bill_images_page.dart';
import '../automation/auto_bill_page.dart';
import '../automation/automation_providers.dart'
    show autoBillDraftCountProvider;
import '../automation/desktop_widgets_page.dart';
import '../automation/mcp_settings_page.dart';
import '../automation/ocr_bill_page.dart';
import '../automation/url_scheme_page.dart';
import '../backup/backup_page.dart';
import '../backup/backup_providers.dart';
import '../backup/mobile_sync_backup_quick_sheet.dart';
import '../bank_cards/bank_cards_page.dart';
import '../batch_edit/batch_edit_page.dart';
import '../books/books_page.dart';
import '../categories/categories_page.dart';
import '../category_transfer/category_transfer_page.dart';
import '../csv_transfer/csv_export_page.dart';
import '../csv_transfer/csv_import_page.dart';
import '../csv_transfer/import_batches_page.dart';
import '../currencies/currencies_page.dart';
import '../debt/debt_page.dart';
import '../deposit/fixed_deposit_page.dart';
import '../installment/installment_page.dart';
import '../migration/migration_page.dart';
import '../notes/notes_page.dart';
import '../periodic/periodic_page.dart';
import '../receipt/diy_toolbar_settings_page.dart';
import '../reimburse/reimburse_page.dart';
import '../reminder/reminder_page.dart';
import '../savings/savings_page.dart';
import '../security/app_lock_settings_page.dart';
import '../settings/about_help_page.dart';
import '../settings/data_health_page.dart';
import '../settings/settings_page.dart';
import '../settings/stat_stories_page.dart';
import '../tags/tags_page.dart';
import '../templates/templates_page.dart';
import '../wishes/wishes_page.dart';

final class _SectionAccent {
  const _SectionAccent({required this.light, required this.dark});

  final Color light;
  final Color dark;

  static const basic = _SectionAccent(
    light: Color(0xFF0D7A6F),
    dark: Color(0xFF5EEAD4),
  );
  static const plan = _SectionAccent(
    light: Color(0xFF2B6CB0),
    dark: Color(0xFF93C5FD),
  );
  static const data = _SectionAccent(
    light: Color(0xFF1F7A53),
    dark: Color(0xFF6EE7B7),
  );
  static const tools = _SectionAccent(
    light: Color(0xFFB76E1D),
    dark: Color(0xFFFCD34D),
  );
  static const smart = _SectionAccent(
    light: Color(0xFF6355C7),
    dark: Color(0xFFC4B5FD),
  );
  static const system = _SectionAccent(
    light: Color(0xFF475E75),
    dark: Color(0xFF94A3B8),
  );
}

final class _MeMenuEntry {
  const _MeMenuEntry({
    required this.key,
    required this.icon,
    required this.title,
    required this.route,
    this.badgeCount = 0,
  });

  final Key key;
  final IconData icon;
  final String title;
  final String route;
  final int badgeCount;
}

final class _MeSectionData {
  const _MeSectionData({
    required this.title,
    required this.accent,
    required this.entries,
  });

  final String title;
  final _SectionAccent accent;
  final List<_MeMenuEntry> entries;
}

List<_MeSectionData> _buildMeSections({
  required bool showAndroidWidgets,
  required int draftCount,
}) => [
  const _MeSectionData(
    title: '基础管理',
    accent: _SectionAccent.basic,
    entries: [
      _MeMenuEntry(
        key: Key('me-books'),
        icon: Icons.book_outlined,
        title: '账本管理',
        route: '/books',
      ),
      _MeMenuEntry(
        key: Key('me-categories'),
        icon: Icons.category_outlined,
        title: '分类管理',
        route: '/categories',
      ),
      _MeMenuEntry(
        key: Key('me-tags'),
        icon: Icons.label_outlined,
        title: '标签管理',
        route: '/tags',
      ),
      _MeMenuEntry(
        key: Key('me-currencies'),
        icon: Icons.currency_exchange,
        title: '币种与汇率',
        route: '/currencies',
      ),
    ],
  ),
  const _MeSectionData(
    title: '计划与提醒',
    accent: _SectionAccent.plan,
    entries: [
      _MeMenuEntry(
        key: Key('me-reimburse'),
        icon: Icons.request_quote_outlined,
        title: '报销管理',
        route: '/reimburse',
      ),
      _MeMenuEntry(
        key: Key('me-periodic'),
        icon: Icons.event_repeat_outlined,
        title: '周期记账',
        route: '/periodic',
      ),
      _MeMenuEntry(
        key: Key('me-installments'),
        icon: Icons.calendar_view_month_outlined,
        title: '分期管理',
        route: '/installments',
      ),
      _MeMenuEntry(
        key: Key('me-debts'),
        icon: Icons.swap_horiz_outlined,
        title: '借贷管理',
        route: '/debts',
      ),
      _MeMenuEntry(
        key: Key('me-savings'),
        icon: Icons.savings_outlined,
        title: '存钱计划',
        route: '/savings',
      ),
      _MeMenuEntry(
        key: Key('me-deposits'),
        icon: Icons.lock_clock_outlined,
        title: '定期存款',
        route: '/deposits',
      ),
      _MeMenuEntry(
        key: Key('me-reminders'),
        icon: Icons.notifications_active_outlined,
        title: '记账提醒',
        route: '/reminders',
      ),
    ],
  ),
  const _MeSectionData(
    title: '数据与备份',
    accent: _SectionAccent.data,
    entries: [
      _MeMenuEntry(
        key: Key('me-backup'),
        icon: Icons.cloud_sync_outlined,
        title: '云同步与备份',
        route: '/backup',
      ),
      _MeMenuEntry(
        key: Key('me-import-csv'),
        icon: Icons.upload_file_outlined,
        title: '账单导入',
        route: '/import/csv',
      ),
      _MeMenuEntry(
        key: Key('me-import-batches'),
        icon: Icons.history_edu_outlined,
        title: '导入批次管理',
        route: '/import/batches',
      ),
      _MeMenuEntry(
        key: Key('me-export-csv'),
        icon: Icons.download_outlined,
        title: '账单导出',
        route: '/export/csv',
      ),
      _MeMenuEntry(
        key: Key('me-migration'),
        icon: Icons.phonelink_setup_outlined,
        title: '第三方数据导入',
        route: '/migration',
      ),
    ],
  ),
  const _MeSectionData(
    title: '常用工具',
    accent: _SectionAccent.tools,
    entries: [
      _MeMenuEntry(
        key: Key('me-wishes'),
        icon: Icons.auto_awesome_outlined,
        title: '心愿单',
        route: '/wishes',
      ),
      _MeMenuEntry(
        key: Key('me-notes'),
        icon: Icons.sticky_note_2_outlined,
        title: '便签与回收站',
        route: '/notes',
      ),
      _MeMenuEntry(
        key: Key('me-templates'),
        icon: Icons.bookmarks_outlined,
        title: '账单模板',
        route: '/templates',
      ),
      _MeMenuEntry(
        key: Key('me-remarks'),
        icon: Icons.comment_outlined,
        title: '常用备注',
        route: '/remarks',
      ),
      _MeMenuEntry(
        key: Key('me-bank-cards'),
        icon: Icons.credit_card_outlined,
        title: '银行卡备忘',
        route: '/bank-cards',
      ),
      _MeMenuEntry(
        key: Key('me-batch-records'),
        icon: Icons.checklist_rtl_outlined,
        title: '账单批量操作',
        route: '/records/batch',
      ),
      _MeMenuEntry(
        key: Key('me-category-transfer'),
        icon: Icons.import_export_outlined,
        title: '分类导入导出与迁移',
        route: '/categories/transfer',
      ),
      _MeMenuEntry(
        key: Key('me-attachments'),
        icon: Icons.photo_library_outlined,
        title: '账单图片库',
        route: '/attachments',
      ),
      _MeMenuEntry(
        key: Key('me-stat-stories'),
        icon: Icons.auto_stories_outlined,
        title: '统计故事',
        route: '/stat-stories',
      ),
    ],
  ),
  _MeSectionData(
    title: '智能与外部联动',
    accent: _SectionAccent.smart,
    entries: [
      _MeMenuEntry(
        key: const Key('me-auto-bill'),
        icon: Icons.bolt_outlined,
        title: '自动记账与草稿箱',
        route: '/automation/auto-bill',
        badgeCount: draftCount,
      ),
      const _MeMenuEntry(
        key: Key('me-ocr'),
        icon: Icons.document_scanner_outlined,
        title: '账单截图识图',
        route: '/automation/ocr',
      ),
      if (showAndroidWidgets)
        const _MeMenuEntry(
          key: Key('me-widgets'),
          icon: Icons.widgets_outlined,
          title: '桌面小组件',
          route: '/automation/widgets',
        ),
      const _MeMenuEntry(
        key: Key('me-url-scheme'),
        icon: Icons.link_outlined,
        title: '外部快捷链接 (URL Scheme)',
        route: '/automation/url-scheme',
      ),
      const _MeMenuEntry(
        key: Key('me-mcp'),
        icon: Icons.hub_outlined,
        title: 'MCP 服务 (AI Agents)',
        route: '/automation/mcp',
      ),
    ],
  ),
  const _MeSectionData(
    title: '安全与系统设置',
    accent: _SectionAccent.system,
    entries: [
      _MeMenuEntry(
        key: Key('me-app-lock'),
        icon: Icons.lock_outline,
        title: '应用安全锁',
        route: '/security/app-lock',
      ),
      _MeMenuEntry(
        key: Key('me-settings'),
        icon: Icons.tune_outlined,
        title: '系统与首页设置',
        route: '/settings',
      ),
      _MeMenuEntry(
        key: Key('me-diy-toolbar'),
        icon: Icons.dashboard_customize_outlined,
        title: '记账工具栏自定义',
        route: '/settings/diy-toolbar',
      ),
      _MeMenuEntry(
        key: Key('me-data-health'),
        icon: Icons.health_and_safety_outlined,
        title: '数据体检',
        route: '/settings/data-health',
      ),
      _MeMenuEntry(
        key: Key('me-about'),
        icon: Icons.help_outline,
        title: '帮助与关于',
        route: '/about',
      ),
    ],
  ),
];

const Set<String> _supportedEmbeddedRoutes = <String>{
  '/books',
  '/categories',
  '/tags',
  '/currencies',
  '/reimburse',
  '/periodic',
  '/installments',
  '/debts',
  '/savings',
  '/deposits',
  '/reminders',
  '/backup',
  '/import/csv',
  '/import/batches',
  '/export/csv',
  '/migration',
  '/wishes',
  '/notes',
  '/templates',
  '/remarks',
  '/bank-cards',
  '/records/batch',
  '/categories/transfer',
  '/attachments',
  '/stat-stories',
  '/automation/auto-bill',
  '/automation/ocr',
  '/automation/widgets',
  '/automation/url-scheme',
  '/automation/mcp',
  '/security/app-lock',
  '/settings',
  '/settings/diy-toolbar',
  '/settings/data-health',
  '/about',
};

/// Scope exposed by [MePage] when rendering its expanded two-column desktop
/// workspace (`>= 1080px`), allowing embedded subpages to switch sibling
/// directory routes in-place without pushing full-screen routes over the
/// directory sidebar.
class MeEmbeddedNavigationScope extends InheritedWidget {
  const MeEmbeddedNavigationScope({
    super.key,
    required this.selectedRoute,
    required this.onSelectRoute,
    required super.child,
  });

  final String selectedRoute;
  final ValueChanged<String> onSelectRoute;

  static MeEmbeddedNavigationScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MeEmbeddedNavigationScope>();

  static bool isSupportedRoute(String route) =>
      _supportedEmbeddedRoutes.contains(route);

  @override
  bool updateShouldNotify(MeEmbeddedNavigationScope oldWidget) =>
      selectedRoute != oldWidget.selectedRoute ||
      onSelectRoute != oldWidget.onSelectRoute;
}

Widget _buildEmbeddedMePage(BuildContext context, String route) =>
    switch (route) {
      '/books' => const BooksPage(),
      '/categories' => const CategoriesPage(),
      '/tags' => const TagsPage(),
      '/currencies' => const CurrenciesPage(),
      '/reimburse' => ReimbursePage(
        onRecordTap: (id) => context.push('/record/$id'),
      ),
      '/periodic' => PeriodicPage(
        onRecordTap: (id) => context.push('/record/$id'),
      ),
      '/installments' => InstallmentPage(
        onRecordTap: (id) => context.push('/record/$id'),
      ),
      '/debts' => const DebtPage(),
      '/savings' => const SavingsPage(),
      '/deposits' => FixedDepositPage(
        onRecordTap: (id) => context.push('/record/$id'),
      ),
      '/reminders' => const ReminderPage(),
      '/backup' => const BackupPage(),
      '/import/csv' => const CsvImportPage(),
      '/import/batches' => const ImportBatchesPage(),
      '/export/csv' => const CsvExportPage(),
      '/migration' => const MigrationPage(),
      '/wishes' => const WishesPage(),
      '/notes' => const NotesPage(),
      '/templates' => const TemplatesPage(),
      '/remarks' => const RemarksPage(),
      '/bank-cards' => const BankCardsPage(),
      '/records/batch' => const BatchEditPage(),
      '/categories/transfer' => const CategoryTransferPage(),
      '/attachments' => const BillImagesPage(),
      '/stat-stories' => const StatStoriesPage(),
      '/automation/auto-bill' => const AutoBillPage(),
      '/automation/ocr' => const OcrBillPage(),
      '/automation/widgets' => const DesktopWidgetsPage(),
      '/automation/url-scheme' => const UrlSchemePage(),
      '/automation/mcp' => const McpSettingsPage(),
      '/security/app-lock' => const AppLockSettingsPage(),
      '/settings' => const SettingsPage(),
      '/settings/diy-toolbar' => const DiyToolbarSettingsPage(),
      '/settings/data-health' => const DataHealthPage(),
      '/about' => const AboutHelpPage(),
      _ => const BooksPage(),
    };

class MePage extends ConsumerStatefulWidget {
  const MePage({super.key});

  @override
  ConsumerState<MePage> createState() => _MePageState();
}

class _MePageState extends ConsumerState<MePage> {
  String _selectedRoute = '/books';
  String? _lastSyncedSectionParam;
  final ScrollController _directoryScrollController = ScrollController();

  static String? _normalizeSectionRoute(
    String? raw, {
    required bool showAndroidWidgets,
  }) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final candidate = trimmed.startsWith('/') ? trimmed : '/$trimmed';
    if (!showAndroidWidgets && candidate == '/automation/widgets') {
      return null;
    }
    return _supportedEmbeddedRoutes.contains(candidate) ? candidate : null;
  }

  static Uri? _currentRouterUri(BuildContext context) {
    if (GoRouter.maybeOf(context) == null) return null;
    try {
      return GoRouterState.of(context).uri;
    } catch (_) {
      return GoRouter.maybeOf(context)?.routerDelegate.currentConfiguration.uri;
    }
  }

  void _selectEmbeddedRoute(BuildContext context, String route) {
    final showAndroidWidgets = DesktopAdaptive.supportsAndroidAppWidgets(
      context,
    );
    final normalized = _normalizeSectionRoute(
      route,
      showAndroidWidgets: showAndroidWidgets,
    );
    if (normalized == null) return;
    if (_selectedRoute != normalized) {
      setState(() => _selectedRoute = normalized);
    }
    final currentUri = _currentRouterUri(context);
    final router = GoRouter.maybeOf(context);
    if (router != null &&
        currentUri != null &&
        currentUri.path == '/me' &&
        currentUri.queryParameters.containsKey('section') &&
        currentUri.queryParameters['section'] != normalized) {
      _lastSyncedSectionParam = normalized;
      router.go('/me?section=${Uri.encodeComponent(normalized)}');
    }
  }

  @override
  void dispose() {
    _directoryScrollController.dispose();
    super.dispose();
  }

  Widget _buildCardSection(
    BuildContext context, {
    required _MeSectionData section,
    required Color sectionCardColor,
    bool isFirst = false,
    double horizontalPadding = 16,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final baseTone = isDark ? section.accent.dark : section.accent.light;
    final fgTone = Color.lerp(baseTone, scheme.primary, 0.18)!;
    final badgeBg = fgTone.withValues(alpha: isDark ? 0.15 : 0.12);
    final badgeIconColor = isDark ? fgTone.withValues(alpha: 0.92) : fgTone;
    final headerHorizontal = horizontalPadding + 6;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            headerHorizontal,
            isFirst ? 4 : 14,
            headerHorizontal,
            6,
          ),
          child: Text(
            section.title,
            style: theme.textTheme.labelMedium?.copyWith(
              color: scheme.onSurfaceVariant.withValues(
                alpha: isDark ? 0.78 : 0.85,
              ),
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          child: Material(
            color: sectionCardColor,
            borderRadius: BorderRadius.circular(16),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < section.entries.length; i++) ...[
                  if (i > 0)
                    Divider(
                      height: 1,
                      thickness: 0.5,
                      indent: 58,
                      endIndent: 16,
                      color: scheme.outlineVariant.withValues(
                        alpha: isDark ? 0.28 : 0.35,
                      ),
                    ),
                  _MeMenuRow(
                    entry: section.entries[i],
                    badgeBg: badgeBg,
                    badgeIconColor: badgeIconColor,
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDirectorySection(
    BuildContext context, {
    required _MeSectionData section,
    bool isFirst = false,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final baseTone = isDark ? section.accent.dark : section.accent.light;
    final fgTone = Color.lerp(baseTone, scheme.primary, 0.18)!;
    final badgeBg = fgTone.withValues(alpha: isDark ? 0.18 : 0.13);
    final badgeIconColor = isDark ? fgTone.withValues(alpha: 0.95) : fgTone;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(10, isFirst ? 4 : 14, 10, 4),
          child: Text(
            section.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 11.5,
              color: scheme.onSurfaceVariant.withValues(
                alpha: isDark ? 0.8 : 0.88,
              ),
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
        ),
        for (final entry in section.entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: _DesktopDirectoryTile(
              entry: entry,
              badgeBg: badgeBg,
              badgeIconColor: badgeIconColor,
              selected: _selectedRoute == entry.route,
              onTap: () => _selectEmbeddedRoute(context, entry.route),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final draftCount = ref.watch(autoBillDraftCountProvider);
    final isDesktop = DesktopAdaptive.isDesktop(context);
    final showAndroidWidgets = DesktopAdaptive.supportsAndroidAppWidgets(
      context,
    );
    final quickEntryVis =
        (ref.exists(databaseProvider) || ref.exists(cloudSyncSettingsProvider))
        ? ref.watch(quickSyncEntryVisibilityProvider)
        : (showHome: false, showMe: false);
    final rawSection = _currentRouterUri(context)?.queryParameters['section'];
    if (rawSection != _lastSyncedSectionParam) {
      _lastSyncedSectionParam = rawSection;
      final target = _normalizeSectionRoute(
        rawSection,
        showAndroidWidgets: showAndroidWidgets,
      );
      if (target != null && target != _selectedRoute) {
        _selectedRoute = target;
      }
    }
    final sections = _buildMeSections(
      showAndroidWidgets: showAndroidWidgets,
      draftCount: draftCount,
    );

    if (DesktopAdaptive.isExpandedDesktop(context)) {
      final directoryBg = isDark
          ? scheme.surfaceContainerLowest
          : Color.lerp(scheme.surface, scheme.surfaceContainerLow, 0.65)!;

      return MeEmbeddedNavigationScope(
        selectedRoute: _selectedRoute,
        onSelectRoute: (route) => _selectEmbeddedRoute(context, route),
        child: Scaffold(
          body: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                key: const Key('me-desktop-directory'),
                width: 236,
                child: Material(
                  color: directoryBg,
                  child: SafeArea(
                    right: false,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Container(
                          height: kToolbarHeight,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '管理与设置',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Divider(
                          height: 1,
                          thickness: 0.6,
                          color: scheme.outlineVariant.withValues(alpha: 0.4),
                        ),
                        Expanded(
                          child: SingleChildScrollView(
                            controller: _directoryScrollController,
                            padding: const EdgeInsets.fromLTRB(8, 6, 8, 20),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (var i = 0; i < sections.length; i++)
                                  _buildDirectorySection(
                                    context,
                                    section: sections[i],
                                    isFirst: i == 0,
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              VerticalDivider(
                width: 1,
                thickness: 1,
                color: scheme.outlineVariant.withValues(alpha: 0.45),
              ),
              Expanded(
                key: const Key('me-desktop-content-pane'),
                child: KeyedSubtree(
                  key: ValueKey<String>(_selectedRoute),
                  child: HeroMode(
                    enabled: false,
                    child: _buildEmbeddedMePage(context, _selectedRoute),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final sectionCardColor = isDark
        ? scheme.surfaceContainerLow
        : Color.lerp(
            scheme.surfaceContainerLow,
            scheme.surfaceContainer,
            0.55,
          )!;

    if (isDesktop &&
        DesktopAdaptive.sizeClassOf(context) == DesktopWindowSizeClass.medium) {
      final leftSections = sections.sublist(0, 3);
      final rightSections = sections.sublist(3);

      return Scaffold(
        appBar: AppBar(title: const Text('更多'), scrolledUnderElevation: 0),
        body: SingleChildScrollView(
          key: const Key('me-desktop-card-grid'),
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 980),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = 0; i < leftSections.length; i++)
                          _buildCardSection(
                            context,
                            section: leftSections[i],
                            sectionCardColor: sectionCardColor,
                            isFirst: i == 0,
                            horizontalPadding: 0,
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = 0; i < rightSections.length; i++)
                          _buildCardSection(
                            context,
                            section: rightSections[i],
                            sectionCardColor: sectionCardColor,
                            isFirst: i == 0,
                            horizontalPadding: 0,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('更多'), scrolledUnderElevation: 0),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(0, 2, 0, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!isDesktop && quickEntryVis.showMe)
              MobileMeSyncQuickCard(cardColor: sectionCardColor),
            for (var i = 0; i < sections.length; i++)
              _buildCardSection(
                context,
                section: sections[i],
                sectionCardColor: sectionCardColor,
                isFirst: i == 0 && (isDesktop || !quickEntryVis.showMe),
              ),
          ],
        ),
      ),
    );
  }
}

class _DesktopDirectoryTile extends StatelessWidget {
  const _DesktopDirectoryTile({
    required this.entry,
    required this.badgeBg,
    required this.badgeIconColor,
    required this.selected,
    required this.onTap,
  });

  final _MeMenuEntry entry;
  final Color badgeBg;
  final Color badgeIconColor;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    Widget iconBadge = Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: badgeBg,
        borderRadius: BorderRadius.circular(8),
      ),
      alignment: Alignment.center,
      child: Icon(entry.icon, size: 17, color: badgeIconColor),
    );

    if (entry.badgeCount > 0) {
      iconBadge = Badge(label: Text('${entry.badgeCount}'), child: iconBadge);
    }

    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? scheme.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: entry.key,
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 40),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                children: [
                  iconBadge,
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      entry.title,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontSize: 13.5,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: selected
                            ? scheme.onSecondaryContainer
                            : scheme.onSurface,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MeMenuRow extends StatelessWidget {
  const _MeMenuRow({
    required this.entry,
    required this.badgeBg,
    required this.badgeIconColor,
  });

  final _MeMenuEntry entry;
  final Color badgeBg;
  final Color badgeIconColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    Widget iconBadge = Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        color: badgeBg,
        borderRadius: BorderRadius.circular(8),
      ),
      alignment: Alignment.center,
      child: Icon(entry.icon, size: 18, color: badgeIconColor),
    );

    if (entry.badgeCount > 0) {
      iconBadge = Badge(label: Text('${entry.badgeCount}'), child: iconBadge);
    }

    return InkWell(
      key: entry.key,
      onTap: () => context.push(entry.route),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 9, 12, 9),
          child: Row(
            children: [
              iconBadge,
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  entry.title,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontSize: 15,
                    fontWeight: FontWeight.w400,
                    color: scheme.onSurface,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.65),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
