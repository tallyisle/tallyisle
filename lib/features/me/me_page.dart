import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app.dart' show brandName;
import '../automation/automation_providers.dart'
    show autoBillDraftCountProvider;

class MePage extends ConsumerWidget {
  const MePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final draftCount = ref.watch(autoBillDraftCountProvider);
    Widget sectionHeader(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 20),
            Center(
              child: Image.asset(
                'assets/branding/tallyisle-logo-original.png',
                width: 88,
                height: 88,
              ),
            ),
            const SizedBox(height: 10),
            Center(
              child: Text(
                brandName(Localizations.localeOf(context)),
                style: theme.textTheme.headlineSmall,
              ),
            ),
            const SizedBox(height: 16),
            ListTile(
              key: const Key('me-books'),
              leading: const Icon(Icons.book_outlined),
              title: const Text('账本管理'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/books'),
            ),
            ListTile(
              key: const Key('me-categories'),
              leading: const Icon(Icons.category_outlined),
              title: const Text('分类管理'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/categories'),
            ),
            ListTile(
              key: const Key('me-tags'),
              leading: const Icon(Icons.label_outlined),
              title: const Text('标签管理'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/tags'),
            ),
            ListTile(
              key: const Key('me-currencies'),
              leading: const Icon(Icons.currency_exchange),
              title: const Text('币种与汇率'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/currencies'),
            ),
            const Divider(),
            sectionHeader('计划与提醒'),
            ListTile(
              key: const Key('me-periodic'),
              leading: const Icon(Icons.event_repeat_outlined),
              title: const Text('周期记账'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/periodic'),
            ),
            ListTile(
              key: const Key('me-installments'),
              leading: const Icon(Icons.calendar_view_month_outlined),
              title: const Text('分期管理'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/installments'),
            ),
            ListTile(
              key: const Key('me-debts'),
              leading: const Icon(Icons.swap_horiz_outlined),
              title: const Text('借贷管理'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/debts'),
            ),
            ListTile(
              key: const Key('me-savings'),
              leading: const Icon(Icons.savings_outlined),
              title: const Text('存钱计划'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/savings'),
            ),
            ListTile(
              key: const Key('me-deposits'),
              leading: const Icon(Icons.lock_clock_outlined),
              title: const Text('定期存款'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/deposits'),
            ),
            ListTile(
              key: const Key('me-reminders'),
              leading: const Icon(Icons.notifications_active_outlined),
              title: const Text('记账提醒'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/reminders'),
            ),
            const Divider(),
            sectionHeader('数据与备份'),
            ListTile(
              key: const Key('me-backup'),
              leading: const Icon(Icons.cloud_sync_outlined),
              title: const Text('备份与恢复'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/backup'),
            ),
            ListTile(
              key: const Key('me-import-csv'),
              leading: const Icon(Icons.upload_file_outlined),
              title: const Text('账单导入'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/import/csv'),
            ),
            ListTile(
              key: const Key('me-import-batches'),
              leading: const Icon(Icons.history_edu_outlined),
              title: const Text('导入批次管理'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/import/batches'),
            ),
            ListTile(
              key: const Key('me-export-csv'),
              leading: const Icon(Icons.download_outlined),
              title: const Text('账单导出'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/export/csv'),
            ),
            ListTile(
              key: const Key('me-import-penny'),
              leading: const Icon(Icons.archive_outlined),
              title: const Text('导入原版备份 (.penny)'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/import/penny'),
            ),
            ListTile(
              key: const Key('me-migration'),
              leading: const Icon(Icons.phonelink_setup_outlined),
              title: const Text('跨端迁移与局域网恢复'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/migration'),
            ),
            const Divider(),
            sectionHeader('常用工具'),
            ListTile(
              key: const Key('me-wishes'),
              leading: const Icon(Icons.auto_awesome_outlined),
              title: const Text('心愿单'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/wishes'),
            ),
            ListTile(
              key: const Key('me-notes'),
              leading: const Icon(Icons.sticky_note_2_outlined),
              title: const Text('便签与回收站'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/notes'),
            ),
            ListTile(
              key: const Key('me-templates'),
              leading: const Icon(Icons.bookmarks_outlined),
              title: const Text('账单模板'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/templates'),
            ),
            ListTile(
              key: const Key('me-remarks'),
              leading: const Icon(Icons.comment_outlined),
              title: const Text('常用备注'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/remarks'),
            ),
            ListTile(
              key: const Key('me-bank-cards'),
              leading: const Icon(Icons.credit_card_outlined),
              title: const Text('银行卡备忘'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/bank-cards'),
            ),
            ListTile(
              key: const Key('me-batch-records'),
              leading: const Icon(Icons.checklist_rtl_outlined),
              title: const Text('账单批量操作'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/records/batch'),
            ),
            ListTile(
              key: const Key('me-category-transfer'),
              leading: const Icon(Icons.import_export_outlined),
              title: const Text('分类导入导出与迁移'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/categories/transfer'),
            ),
            ListTile(
              key: const Key('me-attachments'),
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('账单图片库'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/attachments'),
            ),
            ListTile(
              key: const Key('me-stat-stories'),
              leading: const Icon(Icons.auto_stories_outlined),
              title: const Text('统计故事'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/stat-stories'),
            ),
            const Divider(),
            sectionHeader('智能与外部联动'),
            ListTile(
              key: const Key('me-auto-bill'),
              leading: Badge(
                isLabelVisible: draftCount > 0,
                label: Text('$draftCount'),
                child: const Icon(Icons.bolt_outlined),
              ),
              title: const Text('自动记账与草稿箱'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/automation/auto-bill'),
            ),
            ListTile(
              key: const Key('me-ocr'),
              leading: const Icon(Icons.document_scanner_outlined),
              title: const Text('账单截图识图'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/automation/ocr'),
            ),
            ListTile(
              key: const Key('me-widgets'),
              leading: const Icon(Icons.widgets_outlined),
              title: const Text('桌面小组件'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/automation/widgets'),
            ),
            ListTile(
              key: const Key('me-url-scheme'),
              leading: const Icon(Icons.link_outlined),
              title: const Text('外部快捷链接 (URL Scheme)'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/automation/url-scheme'),
            ),
            const Divider(),
            sectionHeader('安全与系统设置'),
            ListTile(
              key: const Key('me-app-lock'),
              leading: const Icon(Icons.lock_outline),
              title: const Text('应用安全锁'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/security/app-lock'),
            ),
            ListTile(
              key: const Key('me-settings'),
              leading: const Icon(Icons.tune_outlined),
              title: const Text('系统与首页设置'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/settings'),
            ),
            ListTile(
              key: const Key('me-diy-toolbar'),
              leading: const Icon(Icons.dashboard_customize_outlined),
              title: const Text('记账工具栏自定义'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/settings/diy-toolbar'),
            ),
            ListTile(
              key: const Key('me-data-health'),
              leading: const Icon(Icons.health_and_safety_outlined),
              title: const Text('数据体检'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/settings/data-health'),
            ),
            ListTile(
              key: const Key('me-about'),
              leading: const Icon(Icons.help_outline),
              title: const Text('帮助与关于'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/about'),
            ),
            const Divider(),
            const ListTile(
              leading: Icon(Icons.info_outline),
              title: Text('开发版本'),
              subtitle: Text(
                '数据保存在本机，可选配置私有 WebDAV 云备份；已支持核心记账、资产与多币种、统计预算、计划提醒、数据迁移备份，以及常用工具、安全锁与桌面/自动记账联动。',
              ),
            ),
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('开源许可'),
              onTap: () => showLicensePage(
                context: context,
                applicationName: brandName(Localizations.localeOf(context)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
