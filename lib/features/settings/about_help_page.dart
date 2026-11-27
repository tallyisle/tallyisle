import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../../app/adaptive.dart';
import '../../app/app.dart' show appDisplayVersion;
import '../../core/app_version.dart' show appVersionName;
import '../../platform/files.dart';
import '../common/desktop_modal_page.dart';

const String tallyIsleFeedbackEmail = 'support@tallyisle.com';
const String tallyIsleFeedbackMailto = 'mailto:support@tallyisle.com';

/// Offline Help, Feedback & License entries, Local-First Privacy Commitment,
/// and FAQ page.
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
    final isMail = url.startsWith('mailto:');
    final copyText = isMail ? url.substring('mailto:'.length) : url;
    try {
      await fileAccess.openExternalUrl(url);
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: copyText));
      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              isMail ? '未检测到邮件应用，已复制反馈邮箱：$copyText' : '未检测到可用浏览器，已复制链接：$url',
            ),
          ),
        );
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
          margin: EdgeInsets.zero,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          clipBehavior: Clip.antiAlias,
          shape: _aboutCardShape,
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
                  '本地优先、精确到分的个人记账与资产管理工具',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '基于 Flutter 构建 · 支持 Android / iOS / HarmonyOS / Windows / Linux / macOS 全平台',
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
        const _AboutSectionHeader(title: '反馈与许可'),
        Card(
          margin: EdgeInsets.zero,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          clipBehavior: Clip.antiAlias,
          shape: _aboutCardShape,
          color: _aboutCardColor(theme),
          child: Column(
            children: [
              ListTile(
                key: const Key('about_feedback_email_tile'),
                leading: const Icon(Icons.mail_outline_rounded),
                title: const Text('问题反馈与建议'),
                subtitle: const Text(
                  tallyIsleFeedbackEmail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: IconButton(
                  key: const Key('about_copy_feedback_email_button'),
                  visualDensity: VisualDensity.compact,
                  tooltip: '复制反馈邮箱',
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  onPressed: () => unawaited(
                    _copyLink(
                      context,
                      url: tallyIsleFeedbackEmail,
                      message: '已复制反馈邮箱',
                    ),
                  ),
                ),
                onTap: () => unawaited(
                  _openExternalLink(context, tallyIsleFeedbackMailto),
                ),
              ),
              ListTile(
                key: const Key('about_licenses_tile'),
                leading: const Icon(Icons.description_outlined),
                title: const Text('第三方开源组件与图标许可'),
                subtitle: const Text('查看帐屿所使用的开源组件及银行矢量图标许可证（MIT）'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  showLicensePage(
                    context: context,
                    applicationName: '帐屿 / TallyIsle',
                    applicationVersion: appVersionName,
                  );
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        const _AboutSectionHeader(title: '隐私与数据承诺'),
        Card(
          margin: EdgeInsets.zero,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          clipBehavior: Clip.antiAlias,
          shape: _aboutCardShape,
          color: _aboutCardColor(theme),
          child: Column(
            children: [
              ListTile(
                leading: Icon(Icons.shield_outlined),
                title: Text('纯本地离线存储'),
                subtitle: Text(
                  '所有账本、流水、资产、预算、心愿、备忘与安全锁配置默认保存在设备本地数据库中，不接入任何官方服务器，不收集任何遥测或隐私数据；云同步与在线汇率仅在您主动开启并配置自有服务时按需连接。',
                ),
              ),
              ListTile(
                leading: Icon(Icons.verified_outlined),
                title: Text('本地核心功能完整开放 · 无广告干扰'),
                subtitle: Text(
                  '无需强制注册或登录账号，无开屏与信息流广告；多账本、多币种、信用账户账期、预算统计、数据体检及标准备份导出等本地功能离线完整可用。',
                ),
              ),
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
        Card(
          margin: EdgeInsets.zero,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          clipBehavior: Clip.antiAlias,
          shape: _aboutCardShape,
          color: _aboutCardColor(theme),
          child: Column(
            children: [
              ExpansionTile(
                shape: Border(),
                collapsedShape: Border(),
                key: Key('faq_cloud_sync_usage_tile'),
                leading: Icon(Icons.cloud_sync_outlined),
                title: Text('多端云同步适用于什么场景？可以多台设备同时离线记账吗？'),
                childrenPadding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  Text(
                    '帐屿多端云同步（WebDAV / S3）采用「整库快照版本接力」机制，适用于「同一时段固定在一台主力设备记账，换用另一台设备前先同步接力」的场景：\n'
                    '1. 标准换机接力：在旧主力设备完成记账并执行一次同步推送（或开启空闲/退出自动同步），再在新设备打开应用拉取最新快照后继续记账。\n'
                    '2. 避免多机并发离线记账：请勿在多台设备离线或未同步状态下同时新增/修改账单，否则双端会产生快照版本分叉冲突。\n'
                    '3. 冲突自动留档：一旦检测到双端均有未同步的新改动，系统不会静默覆盖，会自动将本机完整数据（含图片附件）归档保存为 conflict_*.tally（同时留存于本机与云端备份列表），再由您选择保留版本。',
                  ),
                ],
              ),
              ExpansionTile(
                shape: Border(),
                collapsedShape: Border(),
                leading: Icon(Icons.credit_card_outlined),
                title: Text('信用账户的“授信额度”与当前余额有什么关系？'),
                childrenPadding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  Text(
                    '信用账户的授信额度仅表示固定信用总额度，不作为期初余额计入欠款。余额为负数表示当前待还欠款，正数表示溢缴款，可用额度 = 授信额度 + 当前余额。',
                  ),
                ],
              ),
              ExpansionTile(
                shape: Border(),
                collapsedShape: Border(),
                leading: Icon(Icons.health_and_safety_outlined),
                title: Text('“数据体检”的一键修复会改动我的账单流水吗？'),
                childrenPadding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  Text(
                    '不会。数据体检严格以您的真实账单流水为准：一键修复仅校准普通/储蓄/投资账户的缓存余额、重算借贷账户剩余本金与结清状态，并清理指向已删除记录的孤立标签关联；不会删改任何账单流水，也不会改动信用账户余额或授信额度。',
                  ),
                ],
              ),
              ExpansionTile(
                shape: Border(),
                collapsedShape: Border(),
                leading: Icon(Icons.lock_outline),
                title: Text('忘记应用安全锁数字密码怎么办？'),
                childrenPadding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  Text(
                    '帐屿采用本地随机盐与高强度 PBKDF2-HMAC-SHA256 不可逆哈希保存密码，无云端账号找回通道。若您已开启生物识别，可通过系统指纹/面容进入应用；建议平时定期导出 .tally 本地备份或配置 WebDAV / S3 备份妥善保管。',
                  ),
                ],
              ),
              ExpansionTile(
                shape: Border(),
                collapsedShape: Border(),
                leading: Icon(Icons.save_alt_outlined),
                title: Text('如何备份、导出或迁移我的账本数据？'),
                childrenPadding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  Text(
                    '移动端可在首页右上角「同步与备份」按钮或「更多」页顶部快捷卡片一键执行云同步、本地备份与 .tally 另存导出；桌面端与完整配置可在「更多 → 云同步与备份」管理 WebDAV / S3、导出标准 CSV 表格及导入历史备份文件。',
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

final _aboutCardShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.circular(16),
);

Color _aboutCardColor(ThemeData theme) {
  final scheme = theme.colorScheme;
  return theme.brightness == Brightness.dark
      ? scheme.surfaceContainerLow
      : Color.lerp(scheme.surfaceContainerLow, scheme.surfaceContainer, 0.55)!;
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
