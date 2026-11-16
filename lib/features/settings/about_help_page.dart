import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../../app/adaptive.dart';
import '../../app/app.dart' show appDisplayVersion;
import '../../platform/files.dart';
import '../common/desktop_modal_page.dart';

const String tallyIsleRepoUrl = 'https://github.com/tallyisle/tallyisle';
const String tallyIsleIssuesUrl =
    'https://github.com/tallyisle/tallyisle/issues';

/// Offline Help, Open-Source Project Links, Local-First Privacy Commitment,
/// and All-Free Policy page.
class AboutHelpPage extends StatelessWidget {
  const AboutHelpPage({super.key, this.fileAccess = const FileAccess()});

  final FileAccess fileAccess;

  Future<void> _copyLink(
    BuildContext context, {
    required String url,
    required String message,
  }) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    await Clipboard.setData(ClipboardData(text: url));
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openExternalLink(BuildContext context, String url) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await fileAccess.openExternalUrl(url);
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: url));
      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('未检测到可用浏览器，已复制链接：$url')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final isDesktop = DesktopAdaptive.isDesktop(context);
    final isPopupModal = isDesktop && ModalRoute.of(context) is PopupRoute;
    final listView = ListView(
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
                  textAlign: TextAlign.center,
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
                  '本地优先、精确到分的开源个人记账与资产管理工具',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '基于 Flutter 构建 · 支持 Android / iOS / Windows / Linux / macOS',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        const _AboutSectionHeader(title: '项目与开源'),
        Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              ListTile(
                key: const Key('about_github_repo_tile'),
                leading: const Icon(Icons.code_rounded),
                title: const Text('开源代码仓库'),
                subtitle: const Text(
                  'https://github.com/tallyisle/tallyisle',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      key: const Key('about_copy_repo_url_button'),
                      visualDensity: VisualDensity.compact,
                      tooltip: '复制仓库地址',
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      onPressed: () => unawaited(
                        _copyLink(
                          context,
                          url: tallyIsleRepoUrl,
                          message: '已复制开源仓库地址',
                        ),
                      ),
                    ),
                    Icon(
                      Icons.open_in_new_rounded,
                      size: 18,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
                onTap: () =>
                    unawaited(_openExternalLink(context, tallyIsleRepoUrl)),
              ),
              const Divider(height: 1),
              ListTile(
                key: const Key('about_github_issues_tile'),
                leading: const Icon(Icons.bug_report_outlined),
                title: const Text('问题反馈与建议'),
                subtitle: const Text(
                  '前往 GitHub Issues 提交 Bug 或功能建议',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      key: const Key('about_copy_issues_url_button'),
                      visualDensity: VisualDensity.compact,
                      tooltip: '复制反馈地址',
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      onPressed: () => unawaited(
                        _copyLink(
                          context,
                          url: tallyIsleIssuesUrl,
                          message: '已复制问题反馈地址',
                        ),
                      ),
                    ),
                    Icon(
                      Icons.open_in_new_rounded,
                      size: 18,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
                onTap: () =>
                    unawaited(_openExternalLink(context, tallyIsleIssuesUrl)),
              ),
              const Divider(height: 1),
              ListTile(
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
            ],
          ),
        ),
        const SizedBox(height: 16),
        const _AboutSectionHeader(title: '隐私与免费承诺'),
        const Card(
          child: Column(
            children: [
              ListTile(
                leading: Icon(Icons.shield_outlined),
                title: Text('纯本地离线存储'),
                subtitle: Text(
                  '所有账本、流水、资产、预算、心愿、备忘与安全锁配置默认保存在设备本地数据库中，不接入任何官方服务器，不收集任何遥测或隐私数据；云同步与在线汇率仅在您主动开启并配置自有服务时按需连接。',
                ),
              ),
              Divider(height: 1),
              ListTile(
                leading: Icon(Icons.verified_outlined),
                title: Text('全功能永久免费 · 无会员门控'),
                subtitle: Text(
                  '无需注册或登录账号，无广告、无订阅付费墙。多账本、多币种、信用账户账期、定期存款计息、预算结转、存钱计划、数据体检及备份导出等全部功能完整开放。',
                ),
              ),
              Divider(height: 1),
              ListTile(
                leading: Icon(Icons.calculate_outlined),
                title: Text('整数精确记账'),
                subtitle: Text(
                  '全链路采用整数最小货币单位精确存储与运算，杜绝浮点数舍入误差，支持数据体检随时核对全库账目。',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        const _AboutSectionHeader(title: '常见问题解答'),
        const Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              ExpansionTile(
                leading: Icon(Icons.credit_card_outlined),
                title: Text('信用账户的“授信额度”与当前余额有什么关系？'),
                childrenPadding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  Text(
                    '信用账户的授信额度仅表示固定信用总额度，绝不作为期初余额计入欠款。余额为负数表示当前待还欠款，正数表示溢缴款，可用额度 = 授信额度 + 当前余额。',
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
                    '不会。数据体检严格以您的真实账单流水为准：一键修复仅校准普通/储蓄/投资账户的缓存余额、重算借贷账户剩余本金与结清状态，并清理指向已删除记录的孤立标签关联；绝不删改任何账单流水，也绝不改动信用账户余额或授信额度。',
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
                    '帐屿采用本地随机盐与高强度 PBKDF2-HMAC-SHA256 不可逆哈希保存密码，无云端账号找回通道。若您已开启生物识别，可通过系统指纹/面容进入应用；建议平时定期导出 .tally 本地备份或配置 WebDAV / S3 备份妥善保管。',
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
                    '您可在数据备份与导出页面随时导出完整离线 .tally 备份包（或通过自托管 WebDAV / S3 备份恢复），同时支持导出标准 CSV 表格及兼容导入历史备份文件。',
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );

    return DesktopModalEscapeScope(
      enabled: isPopupModal,
      child: Scaffold(
        appBar: AppBar(
          leading: isPopupModal ? const CloseButton() : null,
          scrolledUnderElevation: isDesktop ? 0 : null,
          title: const Text('帮助与关于'),
        ),
        body: isDesktop
            ? Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 800),
                  child: listView,
                ),
              )
            : listView,
      ),
    );
  }
}

class _AboutSectionHeader extends StatelessWidget {
  const _AboutSectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: Text(
        title,
        style: theme.textTheme.labelMedium?.copyWith(
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}
