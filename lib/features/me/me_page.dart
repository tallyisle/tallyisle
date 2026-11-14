import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../automation/automation_providers.dart'
    show autoBillDraftCountProvider;

final class _MeMenuEntry {
  const _MeMenuEntry({
    required this.key,
    required this.leading,
    required this.title,
    required this.route,
  });

  final Key key;
  final Widget leading;
  final String title;
  final String route;
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

    Widget buildSection(String title, List<_MeMenuEntry> entries) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
            child: Text(
              title,
              style: theme.textTheme.labelLarge?.copyWith(
                color: scheme.primary,
                fontWeight: FontWeight.w600,
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
                        indent: 52,
                        endIndent: 16,
                        color: scheme.outlineVariant.withValues(alpha: 0.35),
                      ),
                    ListTile(
                      key: entries[i].key,
                      visualDensity: const VisualDensity(vertical: -1),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 1,
                      ),
                      iconColor: scheme.onSurfaceVariant,
                      leading: entries[i].leading,
                      title: Text(entries[i].title),
                      trailing: Icon(
                        Icons.chevron_right_rounded,
                        size: 20,
                        color: scheme.onSurfaceVariant,
                      ),
                      onTap: () => context.push(entries[i].route),
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
        padding: const EdgeInsets.fromLTRB(0, 6, 0, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
              child: Material(
                key: const Key('me-brand-card'),
                color: scheme.primaryContainer.withValues(
                  alpha: isDark ? 0.32 : 0.45,
                ),
                borderRadius: BorderRadius.circular(16),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => context.push('/about'),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    child: Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.asset(
                            'assets/branding/tallyisle-logo-original.png',
                            width: 44,
                            height: 44,
                            errorBuilder: (_, _, _) => Container(
                              width: 44,
                              height: 44,
                              color: scheme.primaryContainer,
                              alignment: Alignment.center,
                              child: Icon(
                                Icons.account_balance_wallet_outlined,
                                size: 24,
                                color: scheme.onPrimaryContainer,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '帐屿 · TallyIsle',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '本地优先 · 精确记账',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(
                          Icons.chevron_right_rounded,
                          color: scheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            buildSection('基础管理', const [
              _MeMenuEntry(
                key: Key('me-books'),
                leading: Icon(Icons.book_outlined),
                title: '账本管理',
                route: '/books',
              ),
              _MeMenuEntry(
                key: Key('me-categories'),
                leading: Icon(Icons.category_outlined),
                title: '分类管理',
                route: '/categories',
              ),
              _MeMenuEntry(
                key: Key('me-tags'),
                leading: Icon(Icons.label_outlined),
                title: '标签管理',
                route: '/tags',
              ),
              _MeMenuEntry(
                key: Key('me-currencies'),
                leading: Icon(Icons.currency_exchange),
                title: '币种与汇率',
                route: '/currencies',
              ),
            ]),
            buildSection('计划与提醒', const [
              _MeMenuEntry(
                key: Key('me-reimburse'),
                leading: Icon(Icons.request_quote_outlined),
                title: '报销管理',
                route: '/reimburse',
              ),
              _MeMenuEntry(
                key: Key('me-periodic'),
                leading: Icon(Icons.event_repeat_outlined),
                title: '周期记账',
                route: '/periodic',
              ),
              _MeMenuEntry(
                key: Key('me-installments'),
                leading: Icon(Icons.calendar_view_month_outlined),
                title: '分期管理',
                route: '/installments',
              ),
              _MeMenuEntry(
                key: Key('me-debts'),
                leading: Icon(Icons.swap_horiz_outlined),
                title: '借贷管理',
                route: '/debts',
              ),
              _MeMenuEntry(
                key: Key('me-savings'),
                leading: Icon(Icons.savings_outlined),
                title: '存钱计划',
                route: '/savings',
              ),
              _MeMenuEntry(
                key: Key('me-deposits'),
                leading: Icon(Icons.lock_clock_outlined),
                title: '定期存款',
                route: '/deposits',
              ),
              _MeMenuEntry(
                key: Key('me-reminders'),
                leading: Icon(Icons.notifications_active_outlined),
                title: '记账提醒',
                route: '/reminders',
              ),
            ]),
            buildSection('数据与备份', const [
              _MeMenuEntry(
                key: Key('me-backup'),
                leading: Icon(Icons.cloud_sync_outlined),
                title: '云同步与备份',
                route: '/backup',
              ),
              _MeMenuEntry(
                key: Key('me-import-csv'),
                leading: Icon(Icons.upload_file_outlined),
                title: '账单导入',
                route: '/import/csv',
              ),
              _MeMenuEntry(
                key: Key('me-import-batches'),
                leading: Icon(Icons.history_edu_outlined),
                title: '导入批次管理',
                route: '/import/batches',
              ),
              _MeMenuEntry(
                key: Key('me-export-csv'),
                leading: Icon(Icons.download_outlined),
                title: '账单导出',
                route: '/export/csv',
              ),
              _MeMenuEntry(
                key: Key('me-migration'),
                leading: Icon(Icons.phonelink_setup_outlined),
                title: '第三方数据导入',
                route: '/migration',
              ),
            ]),
            buildSection('常用工具', const [
              _MeMenuEntry(
                key: Key('me-wishes'),
                leading: Icon(Icons.auto_awesome_outlined),
                title: '心愿单',
                route: '/wishes',
              ),
              _MeMenuEntry(
                key: Key('me-notes'),
                leading: Icon(Icons.sticky_note_2_outlined),
                title: '便签与回收站',
                route: '/notes',
              ),
              _MeMenuEntry(
                key: Key('me-templates'),
                leading: Icon(Icons.bookmarks_outlined),
                title: '账单模板',
                route: '/templates',
              ),
              _MeMenuEntry(
                key: Key('me-remarks'),
                leading: Icon(Icons.comment_outlined),
                title: '常用备注',
                route: '/remarks',
              ),
              _MeMenuEntry(
                key: Key('me-bank-cards'),
                leading: Icon(Icons.credit_card_outlined),
                title: '银行卡备忘',
                route: '/bank-cards',
              ),
              _MeMenuEntry(
                key: Key('me-batch-records'),
                leading: Icon(Icons.checklist_rtl_outlined),
                title: '账单批量操作',
                route: '/records/batch',
              ),
              _MeMenuEntry(
                key: Key('me-category-transfer'),
                leading: Icon(Icons.import_export_outlined),
                title: '分类导入导出与迁移',
                route: '/categories/transfer',
              ),
              _MeMenuEntry(
                key: Key('me-attachments'),
                leading: Icon(Icons.photo_library_outlined),
                title: '账单图片库',
                route: '/attachments',
              ),
              _MeMenuEntry(
                key: Key('me-stat-stories'),
                leading: Icon(Icons.auto_stories_outlined),
                title: '统计故事',
                route: '/stat-stories',
              ),
            ]),
            buildSection('智能与外部联动', [
              _MeMenuEntry(
                key: const Key('me-auto-bill'),
                leading: Badge(
                  isLabelVisible: draftCount > 0,
                  label: Text('$draftCount'),
                  child: const Icon(Icons.bolt_outlined),
                ),
                title: '自动记账与草稿箱',
                route: '/automation/auto-bill',
              ),
              const _MeMenuEntry(
                key: Key('me-ocr'),
                leading: Icon(Icons.document_scanner_outlined),
                title: '账单截图识图',
                route: '/automation/ocr',
              ),
              const _MeMenuEntry(
                key: Key('me-widgets'),
                leading: Icon(Icons.widgets_outlined),
                title: '桌面小组件',
                route: '/automation/widgets',
              ),
              const _MeMenuEntry(
                key: Key('me-url-scheme'),
                leading: Icon(Icons.link_outlined),
                title: '外部快捷链接 (URL Scheme)',
                route: '/automation/url-scheme',
              ),
            ]),
            buildSection('安全与系统设置', const [
              _MeMenuEntry(
                key: Key('me-app-lock'),
                leading: Icon(Icons.lock_outline),
                title: '应用安全锁',
                route: '/security/app-lock',
              ),
              _MeMenuEntry(
                key: Key('me-settings'),
                leading: Icon(Icons.tune_outlined),
                title: '系统与首页设置',
                route: '/settings',
              ),
              _MeMenuEntry(
                key: Key('me-diy-toolbar'),
                leading: Icon(Icons.dashboard_customize_outlined),
                title: '记账工具栏自定义',
                route: '/settings/diy-toolbar',
              ),
              _MeMenuEntry(
                key: Key('me-data-health'),
                leading: Icon(Icons.health_and_safety_outlined),
                title: '数据体检',
                route: '/settings/data-health',
              ),
              _MeMenuEntry(
                key: Key('me-about'),
                leading: Icon(Icons.help_outline),
                title: '帮助与关于',
                route: '/about',
              ),
            ]),
          ],
        ),
      ),
    );
  }
}
