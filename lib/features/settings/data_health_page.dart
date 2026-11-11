import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../app/providers.dart';
import '../../core/failure.dart';
import '../../domain/rules/data_health_rules.dart';
import 'settings_providers.dart';

const _uuid = Uuid();

/// ADR-012 Data Health Check ("数据体检") & atomic safe repair page.
class DataHealthPage extends ConsumerStatefulWidget {
  const DataHealthPage({super.key});

  @override
  ConsumerState<DataHealthPage> createState() => _DataHealthPageState();
}

class _DataHealthPageState extends ConsumerState<DataHealthPage> {
  bool _repairing = false;

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  void _recheck() {
    ref.invalidate(dataHealthReportProvider);
  }

  Future<void> _confirmAndRepair(DataHealthReport report) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('确认执行一键校准修复'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('将严格依据现有真实账单流水，在单个数据库事务内完成以下安全修复：'),
            const SizedBox(height: 12),
            if (report.ordinaryRepairs.isNotEmpty)
              Text('• 普通/储蓄/投资账户缓存余额校准：${report.ordinaryRepairs.length} 项'),
            if (report.debtRepairs.isNotEmpty)
              Text('• 借贷账户剩余本金与结清状态重算：${report.debtRepairs.length} 项'),
            if (report.orphanTagRepairs.isNotEmpty)
              Text('• 清理指向缺失记录或标签的孤立关联：${report.orphanTagRepairs.length} 项'),
            const SizedBox(height: 12),
            Text(
              '承诺：绝不修改或删除任何账单流水记录，绝不改动信用卡（type=6）余额或授信额度。',
              style: Theme.of(dialogContext).textTheme.bodySmall?.copyWith(
                color: Theme.of(dialogContext).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('data_health_confirm_repair_button'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('立即修复'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _repairing = true);
    try {
      final svc = await ref.read(dataHealthServiceProvider.future);
      final result = await svc.repairDataHealth(commandId: _uuid.v4());
      ref.invalidate(dataHealthReportProvider);
      ref.invalidate(assetsProvider);
      _toast(
        '已完成安全修复 ${result.totalRepairedCount} 项'
        '（余额 ${result.repairedOrdinaryCount} / 借贷 ${result.repairedDebtCount} / 孤立标签 ${result.removedOrphanTagCount}）',
      );
    } on Failure catch (f) {
      _toast(f.message);
    } finally {
      if (mounted) setState(() => _repairing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final reportAsync = ref.watch(dataHealthReportProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('数据体检'),
        actions: [
          IconButton(
            key: const Key('data_health_recheck_button'),
            tooltip: '重新体检',
            onPressed: _repairing ? null : _recheck,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: reportAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline, size: 48, color: scheme.error),
                const SizedBox(height: 12),
                Text('体检读取失败：$err', textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton.tonalIcon(
                  onPressed: _recheck,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重试'),
                ),
              ],
            ),
          ),
        ),
        data: (report) {
          final healthy = report.isHealthy;
          final bannerBg = healthy
              ? scheme.secondaryContainer
              : (report.errorCount > 0
                    ? scheme.errorContainer
                    : scheme.tertiaryContainer);
          final bannerFg = healthy
              ? scheme.onSecondaryContainer
              : (report.errorCount > 0
                    ? scheme.onErrorContainer
                    : scheme.onTertiaryContainer);

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              Card(
                key: const Key('data_health_status_banner'),
                elevation: 0,
                color: bannerBg,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        healthy
                            ? Icons.verified_user_outlined
                            : Icons.warning_amber_rounded,
                        size: 32,
                        color: bannerFg,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              healthy
                                  ? '账本数据健康'
                                  : '发现 ${report.errorCount} 项错误 · ${report.warningCount} 项警告',
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: bannerFg,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              healthy
                                  ? '已核对 ${report.checkedAssetCount} 个账户、${report.checkedRecordCount} 条流水与 ${report.checkedTagRecordCount} 条标签关联，所有派生余额与引用均一致。'
                                  : '已扫描 ${report.checkedAssetCount} 个账户与 ${report.checkedRecordCount} 条流水；其中 ${report.repairableCount} 项派生偏差支持一键安全校准。',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: bannerFg,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _MetricTile(
                      label: '已检账户',
                      value: '${report.checkedAssetCount}',
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _MetricTile(
                      label: '已检流水',
                      value: '${report.checkedRecordCount}',
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _MetricTile(
                      label: '可自动修复',
                      value: '${report.repairableCount}',
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _MetricTile(
                      label: '提示信息',
                      value: '${report.infoCount}',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Card(
                elevation: 0,
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.info_outline,
                        size: 20,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '核对口径（ADR-012）：普通/储蓄/投资账户核对 期初金额 + 流水变动；借贷账户重算本金与结清状态；信用卡账户（type=6）的授信额度（init_money）绝不计入余额，建卡期初欠款仅作提示、绝不自动覆盖。',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _repairing ? null : _recheck,
                    icon: const Icon(Icons.refresh),
                    label: const Text('重新体检'),
                  ),
                  if (report.repairableCount > 0)
                    FilledButton.icon(
                      key: const Key('data_health_repair_button'),
                      onPressed: _repairing
                          ? null
                          : () => _confirmAndRepair(report),
                      icon: _repairing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.build_circle_outlined),
                      label: Text('一键修复可自动校准项 (${report.repairableCount})'),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              if (report.issues.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 28),
                  child: Column(
                    children: [
                      Icon(
                        Icons.task_alt,
                        size: 48,
                        color: scheme.primary.withValues(alpha: 0.8),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '未发现任何异常或提示项',
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                )
              else ...[
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    '诊断明细（共 ${report.issues.length} 项）',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                for (var i = 0; i < report.issues.length; i++)
                  _IssueCard(
                    key: Key('data_health_issue_$i'),
                    issue: report.issues[i],
                  ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        child: Column(
          children: [
            Text(
              value,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _IssueCard extends StatelessWidget {
  const _IssueCard({super.key, required this.issue});

  final DataHealthIssue issue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (
      IconData icon,
      Color badgeBg,
      Color badgeFg,
      String severityLabel,
    ) = switch (issue.severity) {
      DataHealthSeverity.error => (
        Icons.error_outline,
        scheme.errorContainer,
        scheme.onErrorContainer,
        '错误',
      ),
      DataHealthSeverity.warning => (
        Icons.warning_amber_rounded,
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
        '警告',
      ),
      DataHealthSeverity.info => (
        Icons.info_outline,
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
        '提示',
      ),
    };

    final actionLabel = issue.repairable
        ? '可自动校准'
        : (issue.severity == DataHealthSeverity.info ? '说明信息' : '需人工核查');

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: badgeFg),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: badgeBg,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    severityLabel,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: badgeFg,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    actionLabel,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              issue.title,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              issue.description,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
