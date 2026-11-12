import 'package:flutter/material.dart';

import '../../app/app.dart' show appDisplayVersion;

/// Offline Help, Local-First Privacy Commitment, and `P-03` All-Free Policy
/// page (`F-038` & `F-037` replacement, `BRAND-001`).
class AboutHelpPage extends StatelessWidget {
  const AboutHelpPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('帮助与关于')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Card(
            elevation: 0,
            color: scheme.primaryContainer.withValues(alpha: 0.45),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: Image.asset(
                      'assets/branding/tallyisle-logo-original.png',
                      width: 72,
                      height: 72,
                      errorBuilder: (_, _, _) => Container(
                        width: 72,
                        height: 72,
                        color: scheme.primaryContainer,
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.account_balance_wallet_outlined,
                          size: 36,
                          color: scheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '帐屿 · TallyIsle',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.surface.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '版本 $appDisplayVersion',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: scheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '本地优先、精确到分的个人记账与资产管理工具',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Text(
              '隐私与免费承诺',
              style: theme.textTheme.titleSmall?.copyWith(
                color: scheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const Card(
            child: Column(
              children: [
                ListTile(
                  leading: Icon(Icons.shield_outlined),
                  title: Text('纯本地离线存储'),
                  subtitle: Text(
                    '所有账本、流水、资产、预算、心愿、备忘与安全锁配置均保存在设备本地 SQLite 数据库中，不连接云端服务器，不收集任何遥测或隐私数据。',
                  ),
                ),
                Divider(height: 1),
                ListTile(
                  leading: Icon(Icons.verified_outlined),
                  title: Text('全功能永久免费 · 无会员门控'),
                  subtitle: Text(
                    '无需注册或登录账号，无广告、无订阅付费墙。多账本、多币种、信用卡账期、定期存款计息、预算结转、存钱计划、数据体检及备份导出等全部功能完整开放。',
                  ),
                ),
                Divider(height: 1),
                ListTile(
                  leading: Icon(Icons.calculate_outlined),
                  title: Text('整数精确记账'),
                  subtitle: Text(
                    '全链路采用整数最小货币单位（Money / BigInt）存储与运算，杜绝浮点数舍入误差，支持数据体检随时核对全库账目。',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Text(
              '常见问题解答',
              style: theme.textTheme.titleSmall?.copyWith(
                color: scheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                ExpansionTile(
                  leading: Icon(Icons.credit_card_outlined),
                  title: Text('信用卡账户的“授信额度”与当前余额有什么关系？'),
                  childrenPadding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                  children: [
                    Text(
                      '信用卡账户的授信额度（init_money）仅表示固定信用总额度，绝不作为期初余额计入欠款。余额为负数表示当前待还欠款，正数表示溢缴款，可用额度 = 授信额度 + 当前余额。',
                    ),
                  ],
                ),
                Divider(height: 1),
                ExpansionTile(
                  leading: Icon(Icons.health_and_safety_outlined),
                  title: Text('“数据体检”的一键修复会改动我的账单流水吗？'),
                  childrenPadding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                  children: [
                    Text(
                      '不会。数据体检严格以您的真实账单流水为准：一键修复仅校准普通/储蓄/投资账户的缓存余额、重算借贷账户剩余本金与结清状态，并清理指向已删除记录的孤立标签关联；绝不删改任何账单流水，也绝不改动信用卡余额或授信额度。',
                    ),
                  ],
                ),
                Divider(height: 1),
                ExpansionTile(
                  leading: Icon(Icons.lock_outline),
                  title: Text('忘记应用安全锁数字密码怎么办？'),
                  childrenPadding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                  children: [
                    Text(
                      '帐屿采用本地随机盐与高强度 PBKDF2-HMAC-SHA256 不可逆哈希保存密码，无云端账号找回通道。若您已开启生物识别，可通过系统指纹/面容进入应用；建议平时定期导出 .tally 本地备份或配置 WebDAV 备份妥善保管。',
                    ),
                  ],
                ),
                Divider(height: 1),
                ExpansionTile(
                  leading: Icon(Icons.save_alt_outlined),
                  title: Text('如何备份、导出或迁移我的账本数据？'),
                  childrenPadding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                  children: [
                    Text(
                      '您可在数据备份与导出页面随时导出完整离线 .tally 备份包（或通过自托管 WebDAV 备份恢复），同时支持导出标准 CSV 表格及兼容导入历史备份文件。',
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: ListTile(
              key: const Key('about_licenses_tile'),
              leading: const Icon(Icons.description_outlined),
              title: const Text('开源组件许可'),
              subtitle: const Text('查看帐屿所使用的开源软件许可证'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                showLicensePage(
                  context: context,
                  applicationName: '帐屿 / TallyIsle',
                  applicationVersion: appDisplayVersion,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
