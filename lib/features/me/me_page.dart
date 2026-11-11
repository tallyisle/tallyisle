import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/app.dart' show brandName;

class MePage extends StatelessWidget {
  const MePage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
      body: ListView(
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
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('开发版本'),
            subtitle: Text(
              '数据只保存在本机；已支持核心记账、资产与多币种、统计预算及计划提醒，备份与更多设置将在后续版本加入。',
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
    );
  }
}
