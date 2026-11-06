import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/app.dart' show brandName;

class MePage extends StatelessWidget {
  const MePage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('我的')),
    body: ListView(
      children: [
        const SizedBox(height: 24),
        Center(
          child: Image.asset(
            'assets/branding/tallyisle-logo-original.png',
            width: 96,
            height: 96,
          ),
        ),
        const SizedBox(height: 12),
        Center(
          child: Text(
            brandName(Localizations.localeOf(context)),
            style: Theme.of(context).textTheme.headlineSmall,
          ),
        ),
        const SizedBox(height: 24),
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
        const Divider(),
        const ListTile(
          leading: Icon(Icons.info_outline),
          title: Text('开发版本'),
          subtitle: Text('数据只保存在本机；备份、设置等功能将在后续版本加入。'),
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
