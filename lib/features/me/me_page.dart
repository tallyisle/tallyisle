import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../automation/automation_providers.dart'
    show autoBillDraftCountProvider;

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

class MePage extends ConsumerWidget {
  const MePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final draftCount = ref.watch(autoBillDraftCountProvider);

    final sectionCardColor = isDark
        ? scheme.surfaceContainerLow
        : Color.lerp(
            scheme.surfaceContainerLow,
            scheme.surfaceContainer,
            0.55,
          )!;

    Widget buildSection({
      required String title,
      required _SectionAccent accent,
      required List<_MeMenuEntry> entries,
      bool isFirst = false,
    }) {
      final baseTone = isDark ? accent.dark : accent.light;
      final fgTone = Color.lerp(baseTone, scheme.primary, 0.18)!;
      final badgeBg = fgTone.withValues(alpha: isDark ? 0.15 : 0.12);
      final badgeIconColor = isDark ? fgTone.withValues(alpha: 0.92) : fgTone;

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(22, isFirst ? 4 : 14, 22, 6),
            child: Text(
              title,
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
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Material(
              color: sectionCardColor,
              borderRadius: BorderRadius.circular(16),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  for (var i = 0; i < entries.length; i++) ...[
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
                      entry: entries[i],
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

    return Scaffold(
      appBar: AppBar(title: const Text('更多'), scrolledUnderElevation: 0),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(0, 2, 0, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            buildSection(
              title: '基础管理',
              accent: _SectionAccent.basic,
              isFirst: true,
              entries: const [
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
            buildSection(
              title: '计划与提醒',
              accent: _SectionAccent.plan,
              entries: const [
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
            buildSection(
              title: '数据与备份',
              accent: _SectionAccent.data,
              entries: const [
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
            buildSection(
              title: '常用工具',
              accent: _SectionAccent.tools,
              entries: const [
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
            buildSection(
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
              ],
            ),
            buildSection(
              title: '安全与系统设置',
              accent: _SectionAccent.system,
              entries: const [
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
          ],
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
