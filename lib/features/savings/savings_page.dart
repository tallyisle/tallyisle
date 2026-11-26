import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/adaptive.dart';
import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../domain/rules/savings_plan.dart';
import '../common/common.dart';
import '../common/desktop_modal_page.dart';
import 'savings_detail_page.dart';
import 'savings_editor_page.dart';
import 'savings_providers.dart';

/// Savings Plan management page (F-012).
class SavingsPage extends ConsumerStatefulWidget {
  const SavingsPage({super.key});

  @override
  ConsumerState<SavingsPage> createState() => _SavingsPageState();
}

class _SavingsPageState extends ConsumerState<SavingsPage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final TabController _tabController;
  int _tabIndex = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (_tabIndex != _tabController.index && mounted) {
        setState(() => _tabIndex = _tabController.index);
      }
    });
    unawaited(_triggerAutoSave());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_triggerAutoSave());
    }
  }

  Future<void> _triggerAutoSave() async {
    try {
      final service = await ref.read(savingsServiceProvider.future);
      await service.runAutoSave();
    } catch (_) {
      // Non-blocking background compensation; individual errors stay out of UI.
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _openEditor() async {
    await pushDesktopModalOrMaterialRoute<int>(
      context,
      child: const SavingsEditorPage(),
    );
  }

  Future<void> _openDetail(int planId) async {
    await pushDesktopModalOrMaterialRoute<void>(
      context,
      child: SavingsDetailPage(planId: planId),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = DesktopAdaptive.isDesktop(context);
    final activeAsync = ref.watch(activeSavingsPlansProvider);
    final archivedAsync = ref.watch(archivedSavingsPlansProvider);
    final summaryAsync = ref.watch(savingsActiveSummaryProvider);
    final currenciesAsync = ref.watch(currenciesProvider);
    final currencies = currenciesAsync.value ?? const <Currency>[];

    return Scaffold(
      key: const Key('savings_page'),
      appBar: AppBar(
        title: const Text('存钱计划'),
        actions: isDesktop && _tabIndex == 0
            ? [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilledButton.tonalIcon(
                    key: const Key('add_savings_plan_fab'),
                    onPressed: _openEditor,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('新建计划'),
                  ),
                ),
              ]
            : null,
        bottom: isDesktop
            ? PreferredSize(
                preferredSize: const Size.fromHeight(46),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 800),
                    child: TabBar(
                      controller: _tabController,
                      tabs: const [
                        Tab(key: Key('savings_tab_active'), text: '进行中'),
                        Tab(key: Key('savings_tab_archived'), text: '已归档'),
                      ],
                    ),
                  ),
                ),
              )
            : TabBar(
                controller: _tabController,
                tabs: const [
                  Tab(key: Key('savings_tab_active'), text: '进行中'),
                  Tab(key: Key('savings_tab_archived'), text: '已归档'),
                ],
              ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _ActivePlansTab(
            plansAsync: activeAsync,
            summaryAsync: summaryAsync,
            currencies: currencies,
            onTapPlan: _openDetail,
          ),
          _ArchivedPlansTab(
            plansAsync: archivedAsync,
            currencies: currencies,
            onTapPlan: _openDetail,
          ),
        ],
      ),
      floatingActionButton: !isDesktop && _tabIndex == 0
          ? FloatingActionButton.extended(
              key: const Key('add_savings_plan_fab'),
              heroTag: 'fab-savings',
              onPressed: _openEditor,
              icon: const Icon(Icons.add),
              label: const Text('新建计划'),
            )
          : null,
    );
  }
}

class _ActivePlansTab extends StatelessWidget {
  const _ActivePlansTab({
    required this.plansAsync,
    required this.summaryAsync,
    required this.currencies,
    required this.onTapPlan,
  });

  final AsyncValue<List<MoneySavePlan>> plansAsync;
  final AsyncValue<SavingsActiveSummary> summaryAsync;
  final List<Currency> currencies;
  final ValueChanged<int> onTapPlan;

  @override
  Widget build(BuildContext context) => asyncBody(plansAsync, (plans) {
    final isDesktop = DesktopAdaptive.isDesktop(context);
    final today = LocalCalendarDate.fromDateTime(DateTime.now());
    final list = ListView(
      padding: EdgeInsets.fromLTRB(16, 12, 16, isDesktop ? 24 : 88),
      children: [
        _ActiveSummaryCard(summaryAsync: summaryAsync),
        const SizedBox(height: 12),
        if (plans.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 48),
            child: Center(
              child: Text(
                isDesktop
                    ? '暂无进行中的存钱计划，点击右上角“新建计划”开始存钱吧'
                    : '暂无进行中的存钱计划，点击右下角“新建计划”开始存钱吧',
                key: const Key('empty_active_savings_text'),
                textAlign: TextAlign.center,
              ),
            ),
          )
        else
          for (final plan in plans) ...[
            _SavingsPlanCard(
              plan: plan,
              currencies: currencies,
              today: today,
              onTap: () => onTapPlan(plan.id),
            ),
            const SizedBox(height: 10),
          ],
      ],
    );
    if (!isDesktop) return list;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 800),
        child: list,
      ),
    );
  });
}

class _ArchivedPlansTab extends StatelessWidget {
  const _ArchivedPlansTab({
    required this.plansAsync,
    required this.currencies,
    required this.onTapPlan,
  });

  final AsyncValue<List<MoneySavePlan>> plansAsync;
  final List<Currency> currencies;
  final ValueChanged<int> onTapPlan;

  @override
  Widget build(BuildContext context) => asyncBody(plansAsync, (plans) {
    if (plans.isEmpty) {
      return const Center(
        child: Text('暂无已归档的存钱计划', key: Key('empty_archived_savings_text')),
      );
    }
    final isDesktop = DesktopAdaptive.isDesktop(context);
    final today = LocalCalendarDate.fromDateTime(DateTime.now());
    final list = ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: plans.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final plan = plans[index];
        return _SavingsPlanCard(
          plan: plan,
          currencies: currencies,
          today: today,
          onTap: () => onTapPlan(plan.id),
        );
      },
    );
    if (!isDesktop) return list;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 800),
        child: list,
      ),
    );
  });
}

class _ActiveSummaryCard extends StatelessWidget {
  const _ActiveSummaryCard({required this.summaryAsync});

  final AsyncValue<SavingsActiveSummary> summaryAsync;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: const Key('savings_active_summary_card'),
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      color: _tonalCardColor(Theme.of(context)),
      shape: _tonalCardShape,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: summaryAsync.when(
          loading: () => const SizedBox(
            height: 48,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          ),
          error: (e, _) => Text(safeMessage(e)),
          data: (summary) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('你已经存下了', style: theme.textTheme.bodyMedium),
              const SizedBox(height: 6),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  '¥${formatMinor(summary.totalSavedBaseMinor)}',
                  key: const Key('savings_total_saved_text'),
                  maxLines: 1,
                  softWrap: false,
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (summary.missingRates.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  key: const Key('savings_missing_rate_banner'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        size: 16,
                        color: theme.colorScheme.onErrorContainer,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '缺少有效汇率（${summary.missingRates.join('、')}），外币计划未计入折算汇总',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onErrorContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SavingsPlanCard extends StatelessWidget {
  const _SavingsPlanCard({
    required this.plan,
    required this.currencies,
    required this.today,
    required this.onTap,
  });

  final MoneySavePlan plan;
  final List<Currency> currencies;
  final LocalCalendarDate today;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final curr = SavingsPlanExtra.parse(plan.extraInfo).currency;
    final symbol = resolveCurrencySymbol(curr, currencies);
    final permille = clampedProgressPermille(
      plan.savedMoneyMinor,
      plan.planMoneyMinor,
    );
    final percentText = formatProgressPercent(
      plan.savedMoneyMinor,
      plan.planMoneyMinor,
    );
    final tip = formatConductTip(
      startDateMs: plan.startDate,
      endDateMs: plan.endDate,
      status: plan.status,
      today: today,
    );
    final typeLabel = SavingsPlanType.labelOf(plan.planType);
    final cycleLabel = plan.planType == SavingsPlanType.free
        ? ''
        : ' · ${SavingsCycleType.labelOf(plan.cycleType)}';

    return Card(
      key: Key('savings_plan_card_${plan.id}'),
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      color: _tonalCardColor(Theme.of(context)),
      shape: _tonalCardShape,
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      plan.name,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  if (plan.autoPlan && plan.status == SavingsPlanStatus.active)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '自动存钱',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '$typeLabel$cycleLabel${tip.isEmpty ? '' : '  $tip'}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              SavingsProgressBar(
                barKey: Key('savings_plan_progress_${plan.id}'),
                permille: permille,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '已存 $symbol${formatMinor(plan.savedMoneyMinor)} / 目标 $symbol${formatMinor(plan.planMoneyMinor)}',
                        maxLines: 1,
                        softWrap: false,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    percentText,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Pure integer-flex progress bar (`permille` in `0..1000`) with zero float math.
class SavingsProgressBar extends StatelessWidget {
  const SavingsProgressBar({required this.permille, this.barKey, super.key});

  final int permille;
  final Key? barKey;

  @override
  Widget build(BuildContext context) {
    final clamped = permille.clamp(0, 1000);
    final fillColor = Theme.of(context).colorScheme.primary;
    final bgColor = Theme.of(context).colorScheme.surfaceContainerHighest;

    return ClipRRect(
      key: barKey,
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: 8,
        child: Row(
          children: [
            if (clamped > 0)
              Expanded(
                flex: clamped,
                child: ColoredBox(
                  color: fillColor,
                  child: const SizedBox.expand(),
                ),
              ),
            if (clamped < 1000)
              Expanded(
                flex: 1000 - clamped,
                child: ColoredBox(
                  color: bgColor,
                  child: const SizedBox.expand(),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Borderless soft tonal card surface (16dp) shared by this feature's cards.
Color _tonalCardColor(ThemeData theme) {
  final scheme = theme.colorScheme;
  return theme.brightness == Brightness.dark
      ? scheme.surfaceContainerLow
      : Color.lerp(scheme.surfaceContainerLow, scheme.surfaceContainer, 0.55)!;
}

const RoundedRectangleBorder _tonalCardShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(16)),
);
