import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/adaptive.dart';
import '../../app/providers.dart';
import '../../core/failure.dart';
import '../../core/money.dart';
import '../../data/db/database.dart';
import '../../data/ledger/ledger_service.dart';
import '../../domain/ledger/asset_json.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/asset_overview.dart';
import '../../domain/rules/credit_cycle.dart';
import '../../domain/rules/currency_rates.dart';
import '../../domain/rules/reconciliation.dart';
import '../common/catalog_icons.dart';
import '../common/common.dart';
import '../common/desktop_modal_page.dart';
import '../common/year_month_picker_dialog.dart';
import '../debt/debt_detail_page.dart';
import '../debt/debt_providers.dart' show debtServiceProvider;
import '../deposit/fixed_deposit_page.dart';
import '../installment/installment_page.dart';
import '../receipt/receipt_diy_providers.dart' show diyToolbarConfigProvider;
import '../records/record_detail_page.dart';
import '../records/record_editor_page.dart';
import '../stats/asset_trend_page.dart';
import 'asset_editor_page.dart';
import 'asset_flow_providers.dart';
import 'asset_flow_section.dart';
import 'credit_providers.dart';
import 'credit_section.dart';
import 'fund_monthly_section.dart';

Future<void> _pushRouteOrModal(
  BuildContext context,
  String path,
  Widget Function() modalBuilder, {
  double maxWidth = 560,
  double maxHeight = 700,
  bool replaceIfPageCanPop = false,
  bool embeddedInPane = false,
}) {
  final route = ModalRoute.of(context);
  final useImperativeModal =
      (route != null && (route is PopupRoute || route.settings is! Page)) ||
      GoRouter.maybeOf(context) == null;
  if (!useImperativeModal) {
    if (replaceIfPageCanPop &&
        !embeddedInPane &&
        (GoRouter.maybeOf(context)?.canPop() ?? false)) {
      return Future<void>.sync(() => context.pushReplacement(path));
    }
    return context.push<void>(path);
  }
  return pushDesktopModalOrMaterialRoute<void>(
    context,
    maxWidth: maxWidth,
    maxHeight: maxHeight,
    child: modalBuilder(),
  );
}

final _maxAdjustAmount = Money.parse('88888888888.00');

Money _parseAmount(String text) {
  final t = text.trim();
  if (t.isEmpty) return Money.zero();
  final normalized = t.endsWith('.') ? t.substring(0, t.length - 1) : t;
  final money = Money.parse(
    normalized.startsWith('.') ? '0$normalized' : normalized,
  );
  if (money.units > _maxAdjustAmount.units) {
    throw const Failure(FailureCode.validation, '金额不能超过 88888888888.00');
  }
  return money;
}

Future<int> _readCurrentBookId(AppDatabase db) async {
  final pref = await (db.select(
    db.preferences,
  )..where((t) => t.key.equals(prefKeyCurrentBookId))).getSingleOrNull();
  final parsed = int.tryParse(pref?.value ?? '');
  if (parsed != null) return parsed;
  final firstBook =
      await (db.select(db.accountBooks)
            ..orderBy([
              (t) => OrderingTerm.asc(t.sort),
              (t) => OrderingTerm.asc(t.id),
            ])
            ..limit(1))
          .getSingleOrNull();
  return firstBook?.id ?? 1;
}

/// "欠款 320.00" / "溢存款 50.00" for credit balances (reconciliation.md R4:
/// never a double minus sign).
String creditBalanceLabel(BigInt balance) => balance > BigInt.zero
    ? '溢存款 ${formatMinor(balance)}'
    : '欠款 ${formatMinor(-balance)}';

/// Account detail (`/assets/:id`): unified dual-metric compact header card,
/// pinned sticky control bar (`流水明细 | 账期账单` + `对账模式`), scroll-linked
/// balance reveal in title bar, flow list, and credit statements.
class AssetDetailPage extends ConsumerStatefulWidget {
  const AssetDetailPage({
    super.key,
    required this.assetId,
    this.embeddedInPane = false,
    this.onDeleted,
  });

  final int assetId;
  final bool embeddedInPane;
  final VoidCallback? onDeleted;

  @override
  ConsumerState<AssetDetailPage> createState() => _AssetDetailPageState();
}

class _AssetDetailPageState extends ConsumerState<AssetDetailPage> {
  static const double _collapseScrollThreshold = 116.0;

  final ScrollController _scrollController = ScrollController();
  bool _headerCollapsed = false;
  int _activeTab = 0; // 0 = 流水明细, 1 = 账期账单 / 月度账单
  bool _reconMode = false;
  CreditStatementPeriod? _periodFilter;
  NaturalMonthPeriod? _monthFilter;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
    _scheduleResetStatementYears();
  }

  @override
  void didUpdateWidget(covariant AssetDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.assetId != widget.assetId) {
      _headerCollapsed = false;
      _activeTab = 0;
      _reconMode = false;
      _periodFilter = null;
      _monthFilter = null;
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
      _scheduleResetStatementYears();
    }
  }

  void _scheduleResetStatementYears() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final currentYear = DateTime.now().year;
      if (ref.read(creditSelectedYearProvider) != currentYear) {
        ref.read(creditSelectedYearProvider.notifier).reset();
      }
      if (ref.read(fundSelectedYearProvider) != currentYear) {
        ref.read(fundSelectedYearProvider.notifier).reset();
      }
    });
  }

  Future<void> _openFlowPeriodPicker(BuildContext context, Asset a) async {
    final now = DateTime.now();
    final isCredit = a.type == AssetType.credit;
    final info = isCredit ? CreditInfo.parse(a.creditInfo) : null;
    if (isCredit && info != null && info.configured) {
      final currentCycle = currentCreditPeriodForToday(
        creditInfo: info,
        today: now,
      );
      final picked = await showCreditPeriodPickerDialog(
        context,
        creditInfo: info,
        initialYear: _periodFilter?.year ?? currentCycle.year,
        initialPeriodIndex:
            _periodFilter?.periodIndex ?? currentCycle.periodIndex,
        today: now,
      );
      if (picked != null && mounted) {
        setState(() {
          _periodFilter = picked;
          _monthFilter = null;
        });
      }
      return;
    }

    final picked = await showYearMonthPickerDialog(
      context,
      initialYear: _monthFilter?.year ?? now.year,
      initialMonth: _monthFilter?.month ?? now.month,
      currentYear: now.year,
      currentMonth: now.month,
    );
    if (picked != null && mounted) {
      setState(() {
        _monthFilter = NaturalMonthPeriod(
          year: picked.year,
          month: picked.month,
        );
        _periodFilter = null;
      });
    }
  }

  void _handleScroll() {
    if (!_scrollController.hasClients) return;
    final nextCollapsed = _scrollController.offset > _collapseScrollThreshold;
    if (nextCollapsed != _headerCollapsed) {
      setState(() => _headerCollapsed = nextCollapsed);
    }
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_handleScroll)
      ..dispose();
    super.dispose();
  }

  Future<void> _openCreditRepay(
    BuildContext context,
    Asset card,
    BigInt repayAmount,
  ) {
    final from = AssetExtra.parse(card.extraInfo).repayAssetId;
    return _pushRouteOrModal(
      context,
      repayRoute(card, repayAmount),
      () => RecordEditorPage(
        initialType: RecordType.transfer,
        initialTo: card.id,
        initialFrom: from,
        initialAmount: repayAmount > BigInt.zero
            ? formatMinor(repayAmount)
            : null,
        initialRemark: '信用账户还款',
      ),
      maxWidth: 900,
      maxHeight: 740,
    );
  }

  Future<void> _openEditAsset(BuildContext context, int assetId) {
    return _pushRouteOrModal(
      context,
      '/assets/$assetId/edit',
      () => AssetEditorPage(assetId: assetId),
    );
  }

  Future<void> _openRecordDetail(BuildContext context, String recordId) {
    return _pushRouteOrModal(
      context,
      '/record/$recordId',
      () => RecordDetailPage(recordId: recordId),
      maxWidth: 560,
      maxHeight: 740,
    );
  }

  Widget _buildTitleRow(
    BuildContext context,
    Asset? asset, {
    required bool isPaneBar,
  }) {
    final theme = Theme.of(context);
    final titleStyle = isPaneBar
        ? theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)
        : null;

    if (!_headerCollapsed || asset == null) {
      return Text(
        asset?.name ?? '账户详情',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: titleStyle,
      );
    }

    final balanceSummary = asset.type == AssetType.credit
        ? creditBalanceLabel(asset.balanceMinor)
        : '余额 ${formatMinor(asset.balanceMinor)}';

    return Row(
      mainAxisSize: isPaneBar ? MainAxisSize.max : MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            asset.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: titleStyle,
          ),
        ),
        const SizedBox(width: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 148),
          child: Container(
            key: const Key('asset-collapsed-balance-pill'),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(
                alpha: 0.75,
              ),
              borderRadius: BorderRadius.circular(999),
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                balanceSummary,
                maxLines: 1,
                softWrap: false,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final assetId = widget.assetId;
    final embeddedInPane = widget.embeddedInPane;
    final asset = ref.watch(assetProvider(assetId));
    final fallbackAsset = embeddedInPane
        ? ref
              .watch(assetsProvider)
              .value
              ?.where((x) => x.id == assetId)
              .firstOrNull
        : null;
    final currentAsset = asset.value ?? fallbackAsset;
    final diyConfig =
        ref.exists(databaseProvider) || ref.exists(diyToolbarConfigProvider)
        ? ref.watch(diyToolbarConfigProvider).value
        : null;
    final theme = Theme.of(context);

    Widget buildScrollableDetail(Asset a) {
      final isCredit = a.type == AssetType.credit;
      final isDebt = a.type == AssetType.debt;
      final isFund = !isCredit && !isDebt;
      final hasStatementTab = isCredit || isFund;
      final effectiveTab = hasStatementTab ? _activeTab : 0;
      final isDefaultAccount =
          a.status == AssetStatus.active &&
          a.type != AssetType.debt &&
          diyConfig != null &&
          diyConfig.autoSelectDefaultAccount &&
          diyConfig.defaultAccountId == a.id;

      final recordsList = ref.watch(assetRecordsProvider(a.id)).value;
      final totalRecordCount = recordsList?.length ?? 0;

      final pendingBanner = isCredit
          ? ref.watch(creditPendingBannerProvider(a)).value
          : null;
      final selectedStatementYear = isCredit
          ? ref.watch(creditSelectedYearProvider)
          : ref.watch(fundSelectedYearProvider);
      final hasActiveFilter =
          (isCredit && _periodFilter != null) ||
          (!isDebt && _monthFilter != null);

      return CustomScrollView(
        controller: _scrollController,
        slivers: [
          SliverToBoxAdapter(
            key: const ValueKey('asset-header'),
            child: _UnifiedAssetHeaderCard(
              asset: a,
              isDefaultAccount: isDefaultAccount,
              totalRecordCount: totalRecordCount,
              embeddedInPane: embeddedInPane,
              onCreditRepay: (amount) => _openCreditRepay(context, a, amount),
            ),
          ),
          if (isCredit && pendingBanner != null)
            SliverToBoxAdapter(
              key: const ValueKey('asset-credit-pending-banner'),
              child: CreditPendingBanner(
                asset: a,
                banner: pendingBanner,
                onRepay: (amount) => _openCreditRepay(context, a, amount),
              ),
            ),
          SliverPersistentHeader(
            pinned: true,
            delegate: _StickyDetailControlBarDelegate(
              isCredit: isCredit,
              isDebt: isDebt,
              activeTab: effectiveTab,
              totalRecordCount: totalRecordCount,
              hasPendingRepayment: pendingBanner != null,
              reconMode: _reconMode,
              hasActiveFilter: hasActiveFilter,
              selectedStatementYear: selectedStatementYear,
              colorScheme: theme.colorScheme,
              textTheme: theme.textTheme,
              onTabChanged: (tab) => setState(() => _activeTab = tab),
              onReconChanged: (v) => setState(() => _reconMode = v),
              onOpenPeriodPicker: isDebt
                  ? null
                  : () => _openFlowPeriodPicker(context, a),
              onStatementYearChanged: (year) {
                if (isCredit) {
                  ref.read(creditSelectedYearProvider.notifier).setYear(year);
                } else {
                  ref.read(fundSelectedYearProvider.notifier).setYear(year);
                }
              },
            ),
          ),
          if (isCredit && effectiveTab == 1)
            SliverToBoxAdapter(
              key: const ValueKey('asset-credit-section'),
              child: CreditSection(
                asset: a,
                selectedPeriod: _periodFilter,
                onConfigureTap: () => _openEditAsset(context, a.id),
                onRepayAmount: (amount) => _openCreditRepay(context, a, amount),
                onSelectPeriod: (period) {
                  setState(() {
                    _periodFilter = period;
                    _monthFilter = null;
                    _activeTab = 0;
                  });
                },
              ),
            )
          else if (isFund && effectiveTab == 1)
            SliverToBoxAdapter(
              key: const ValueKey('asset-fund-monthly-section'),
              child: FundMonthlySection(
                asset: a,
                selectedMonth: _monthFilter,
                onSelectMonth: (period) {
                  setState(() {
                    _monthFilter = period;
                    _periodFilter = null;
                    _activeTab = 0;
                  });
                },
              ),
            )
          else
            AssetFlowSection(
              key: const ValueKey('asset-flow-section'),
              asset: a,
              reconMode: _reconMode,
              periodFilter: isCredit ? _periodFilter : null,
              monthFilter: isDebt ? null : _monthFilter,
              onChangePeriodFilter: isCredit
                  ? (period) => setState(() {
                      _periodFilter = period;
                      _monthFilter = null;
                    })
                  : null,
              onChangeMonthFilter: isDebt
                  ? null
                  : (period) => setState(() {
                      _monthFilter = period;
                      _periodFilter = null;
                    }),
              onClearPeriodFilter: () => setState(() {
                _periodFilter = null;
                _monthFilter = null;
              }),
              onOpenRecord: (recordId) => _openRecordDetail(context, recordId),
            ),
          SliverToBoxAdapter(
            key: const ValueKey('asset-bottom-pad'),
            child: SizedBox(height: embeddedInPane ? 64 : 96),
          ),
        ],
      );
    }

    final Widget detailBody;
    if (embeddedInPane && currentAsset != null) {
      detailBody = buildScrollableDetail(currentAsset);
    } else {
      detailBody = asyncBody(asset, (a) {
        if (a == null) return const Center(child: Text('账户不存在或已删除'));
        return buildScrollableDetail(a);
      });
    }

    if (embeddedInPane) {
      return Material(
        color: theme.colorScheme.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 52,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: _buildTitleRow(
                        context,
                        currentAsset,
                        isPaneBar: true,
                      ),
                    ),
                    if (currentAsset != null)
                      _AssetMenu(
                        asset: currentAsset,
                        key: const Key('asset-menu'),
                        embeddedInPane: true,
                        onDeleted: widget.onDeleted,
                      ),
                  ],
                ),
              ),
            ),
            Expanded(child: detailBody),
          ],
        ),
      );
    }

    final isDesktop = DesktopAdaptive.isDesktop(context);
    final isDesktopModal =
        isDesktop &&
        ModalRoute.of(context) is PopupRoute &&
        Navigator.of(context).canPop();

    return DesktopModalEscapeScope(
      enabled: isDesktopModal,
      child: Scaffold(
        appBar: AppBar(
          leading: isDesktopModal ? const CloseButton() : null,
          title: _buildTitleRow(context, asset.value, isPaneBar: false),
          actions: [
            if (asset.value != null)
              _AssetMenu(asset: asset.value!, key: const Key('asset-menu')),
          ],
        ),
        body: isDesktop
            ? Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 820),
                  child: detailBody,
                ),
              )
            : detailBody,
      ),
    );
  }
}

/// Unified 4-row dual-metric compact header card shared by both Fund Accounts
/// (`资金账户`) and Credit Accounts (`信用账户`) so switching accounts in
/// mobile or PC master-detail has zero layout jump or visual disconnect.
class _UnifiedAssetHeaderCard extends ConsumerWidget {
  const _UnifiedAssetHeaderCard({
    required this.asset,
    required this.totalRecordCount,
    this.isDefaultAccount = false,
    this.embeddedInPane = false,
    required this.onCreditRepay,
  });

  final Asset asset;
  final int totalRecordCount;
  final bool isDefaultAccount;
  final bool embeddedInPane;
  final ValueChanged<BigInt> onCreditRepay;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final credit = asset.type == AssetType.credit;
    final debt = asset.type == AssetType.debt;
    final info = credit ? CreditInfo.parse(asset.creditInfo) : null;
    final extra = credit ? AssetExtra.parse(asset.extraInfo) : null;

    final status = switch (asset.status) {
      AssetStatus.hidden => '已隐藏',
      AssetStatus.settled => '已结清',
      _ => null,
    };
    final countedInNetWorth = debt
        ? asset.isEffectiveAsset == 0
        : asset.isEffectiveAsset == 1;
    final accountTypeLabel = credit
        ? '信用账户'
        : debt
        ? '借贷账户'
        : '资金账户';

    // Credit limit & interest-free calculations (synchronous fallback avoids
    // loading spinner flashes when switching cards in desktop split view).
    SharedLimitResult? sharedLimit;
    var ifcDays = 0;
    var hasActiveTemp = false;
    var totalInstallments = BigInt.zero;
    if (credit && info != null && extra != null) {
      final now = DateTime.now();
      final nowMs = now.millisecondsSinceEpoch;
      hasActiveTemp = extra.activeTempAmount(nowMs) > BigInt.zero;
      totalInstallments = calculateTotalUncreditedInstallments(
        info.installments,
      );
      ifcDays = calculateInterestFreeDays(creditInfo: info, today: now);
      final asyncShared = ref.watch(creditSharedLimitProvider(asset)).value;
      if (asyncShared != null) {
        sharedLimit = asyncShared;
      } else {
        final singleLimit =
            asset.initMoneyMinor + extra.activeTempAmount(nowMs);
        final dispBal = calculateCardDisplayBalance(
          asset.balanceMinor,
          info.installments,
        );
        sharedLimit = SharedLimitResult(
          effectiveTotalLimit: singleLimit,
          usableLimit: singleLimit + dispBal,
          groupDisplayBalance: dispBal,
          isShared: info.sharedLimitAssetId != null,
          isPrimary: info.sharedLimitAssetId == null,
        );
      }
    }

    // Current-month inflow/outflow & foreign currency conversion for Fund Accounts.
    var monthInflow = BigInt.zero;
    var monthOutflow = BigInt.zero;
    String? fxBaseSummary;
    if (!credit && !debt) {
      final now = DateTime.now();
      final groups = ref.watch(assetMonthGroupsProvider(asset.id));
      final currMonth = groups
          .where((g) => g.year == now.year && g.month == now.month)
          .firstOrNull;
      if (currMonth != null) {
        monthInflow = currMonth.inflow;
        monthOutflow = currMonth.outflow;
      }

      final normCurr = normalizeCurrency(asset.currency);
      if (normCurr != null && normCurr != baseCurrency) {
        final currencies = ref.watch(currenciesProvider).value ?? const [];
        final rates = RateTable({
          for (final c in currencies) c.code: c.rateToAnchor,
        });
        final converted = rates.convert(
          asset.balanceMinor,
          normCurr,
          baseCurrency,
        );
        fxBaseSummary = '折合 $baseCurrency ${formatMinor(converted)}';
      }
    }

    final actionButtons = <Widget>[
      if (credit)
        FilledButton.icon(
          key: const Key('credit-repay'),
          style: FilledButton.styleFrom(
            visualDensity: VisualDensity.compact,
            minimumSize: const Size(0, 36),
            padding: const EdgeInsets.symmetric(horizontal: 10),
          ),
          icon: const Icon(Icons.payments_outlined, size: 17),
          label: const FittedBox(
            fit: BoxFit.scaleDown,
            child: Text('还款', maxLines: 1, softWrap: false),
          ),
          onPressed: () {
            final repayAmount = asset.balanceMinor.isNegative
                ? -asset.balanceMinor
                : BigInt.zero;
            onCreditRepay(repayAmount);
          },
        ),
      if (!debt)
        credit
            ? OutlinedButton.icon(
                key: const Key('asset-detail-new-record'),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  minimumSize: const Size(0, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
                icon: const Icon(Icons.edit_note, size: 17),
                label: const FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text('记一笔', maxLines: 1, softWrap: false),
                ),
                onPressed: () => _pushRouteOrModal(
                  context,
                  '/record/new?asset=${asset.id}',
                  () => RecordEditorPage(initialAsset: asset.id),
                  maxWidth: 900,
                  maxHeight: 740,
                ),
              )
            : FilledButton.icon(
                key: const Key('asset-detail-new-record'),
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  minimumSize: const Size(0, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
                icon: const Icon(Icons.edit_note, size: 17),
                label: const FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text('记一笔', maxLines: 1, softWrap: false),
                ),
                onPressed: () => _pushRouteOrModal(
                  context,
                  '/record/new?asset=${asset.id}',
                  () => RecordEditorPage(initialAsset: asset.id),
                  maxWidth: 900,
                  maxHeight: 740,
                ),
              ),
      if (!credit && !debt)
        OutlinedButton.icon(
          key: const Key('asset-detail-deposits'),
          style: OutlinedButton.styleFrom(
            visualDensity: VisualDensity.compact,
            minimumSize: const Size(0, 36),
            padding: const EdgeInsets.symmetric(horizontal: 10),
          ),
          icon: const Icon(Icons.lock_clock_outlined, size: 17),
          label: const FittedBox(
            fit: BoxFit.scaleDown,
            child: Text('定期存款', maxLines: 1, softWrap: false),
          ),
          onPressed: () => _pushRouteOrModal(
            context,
            '/deposits?assetId=${asset.id}',
            () => FixedDepositPage(initialAssetId: asset.id),
            maxWidth: 860,
            maxHeight: 740,
          ),
        ),
      if (credit)
        OutlinedButton.icon(
          key: const Key('asset-detail-installments'),
          style: OutlinedButton.styleFrom(
            visualDensity: VisualDensity.compact,
            minimumSize: const Size(0, 36),
            padding: const EdgeInsets.symmetric(horizontal: 10),
          ),
          icon: const Icon(Icons.calendar_view_month_outlined, size: 17),
          label: const FittedBox(
            fit: BoxFit.scaleDown,
            child: Text('分期管理', maxLines: 1, softWrap: false),
          ),
          onPressed: () => _pushRouteOrModal(
            context,
            '/installments',
            () => const InstallmentPage(),
            maxWidth: 860,
            maxHeight: 740,
          ),
        ),
      if (debt)
        FilledButton.icon(
          key: const Key('asset-detail-debt'),
          style: FilledButton.styleFrom(
            visualDensity: VisualDensity.compact,
            minimumSize: const Size(0, 36),
            padding: const EdgeInsets.symmetric(horizontal: 12),
          ),
          icon: const Icon(Icons.swap_horiz_outlined, size: 17),
          label: const FittedBox(
            fit: BoxFit.scaleDown,
            child: Text('借贷详情', maxLines: 1, softWrap: false),
          ),
          onPressed: () => _pushRouteOrModal(
            context,
            '/debts/${asset.id}',
            () => DebtDetailPage(debtId: asset.id),
            maxWidth: 680,
            maxHeight: 740,
            replaceIfPageCanPop: true,
            embeddedInPane: embeddedInPane,
          ),
        ),
    ];

    final remarkText = asset.remark != null && asset.remark!.trim().isNotEmpty
        ? asset.remark!.trim()
        : null;

    final cardColor = isDark
        ? scheme.surfaceContainerLow
        : Color.lerp(
            scheme.surfaceContainerLow,
            scheme.surfaceContainer,
            0.55,
          )!;

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      color: cardColor,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Row 1: Avatar + Identity Tags + Optional Interest-Free Badge
            Row(
              children: [
                AssetIconAvatar(
                  iconKey: asset.icon,
                  colorHex: asset.color,
                  name: asset.name,
                  assetType: asset.type,
                  subType: asset.subType,
                  size: 36,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        accountTypeLabel,
                        style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (asset.currency != null &&
                          asset.currency!.trim().isNotEmpty)
                        _HeaderMetaPill(label: asset.currency!.trim()),
                      if (status != null) _HeaderMetaPill(label: status),
                      if (!countedInNetWorth)
                        const _HeaderMetaPill(label: '不计入总资产'),
                      if (isDefaultAccount)
                        _HeaderMetaPill(
                          key: const Key('asset-detail-default-chip'),
                          label: '默认账户',
                          bgColor: scheme.secondaryContainer,
                          fgColor: scheme.onSecondaryContainer,
                        ),
                      if (credit && ifcDays > 0)
                        _HeaderMetaPill(
                          label: '今日享 $ifcDays 天免息期',
                          bgColor: scheme.primaryContainer,
                          fgColor: scheme.onPrimaryContainer,
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Row 2: Symmetrical Dual-Column Core Metrics
            if (credit && sharedLimit != null)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 11,
                    child: _HeaderMetricBlock(
                      label: asset.balanceMinor > BigInt.zero
                          ? '当前溢存款'
                          : '当前欠款',
                      valueKey: const Key('credit-current-debt'),
                      value: formatMinor(asset.balanceMinor.abs()),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 11,
                    child: _HeaderMetricBlock(
                      label: sharedLimit.isShared ? '共享剩余额度' : '可用额度',
                      valueKey: const Key('credit-usable-limit'),
                      value: formatMinor(sharedLimit.usableLimit),
                    ),
                  ),
                ],
              )
            else if (!debt)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 11,
                    child: _HeaderMetricBlock(
                      label: '当前余额',
                      valueKey: const Key('asset-detail-balance'),
                      value: formatMinor(asset.balanceMinor),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 11,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '本月流入 / 流出',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Container(
                          height: 30,
                          alignment: Alignment.centerLeft,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Row(
                              key: const Key('asset-detail-month-flow'),
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  '+${formatMinor(monthInflow)}',
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    color: isDark
                                        ? Colors.green.shade300
                                        : Colors.green.shade700,
                                  ),
                                ),
                                Text(
                                  ' / ',
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    color: scheme.outline,
                                  ),
                                ),
                                Text(
                                  '-${formatMinor(monthOutflow)}',
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              )
            else
              _HeaderMetricBlock(
                label: '当前余额',
                valueKey: const Key('asset-detail-balance'),
                value: formatMinor(asset.balanceMinor),
              ),

            const SizedBox(height: 8),

            // Row 3: Compact Single-Line Metadata Summary
            if (credit && info != null && sharedLimit != null)
              Wrap(
                spacing: 12,
                runSpacing: 2,
                children: [
                  Text(
                    '${hasActiveTemp ? '总额度(含临额)' : '总额度'} ${formatMinor(sharedLimit.effectiveTotalLimit)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  Text(
                    info.configured
                        ? '账单日 ${creditDayLabel(info.billDay)} · 还款日 ${info.repaymentAfterBillDay ? '账单日后 ${info.repaymentDay} 天' : creditDayLabel(info.repaymentDay)}'
                        : '尚未设置账单日与还款日',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  if (totalInstallments > BigInt.zero)
                    Text(
                      '分期未入账 ${formatMinor(totalInstallments)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.error,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  if (remarkText != null)
                    Text(
                      remarkText,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              )
            else
              Wrap(
                spacing: 12,
                runSpacing: 2,
                children: [
                  if (fxBaseSummary != null)
                    Text(
                      fxBaseSummary,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  Text(
                    '累计 $totalRecordCount 笔流水',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  if (remarkText != null)
                    Text(
                      remarkText,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),

            // Row 4: Unified Primary + Secondary Action Buttons
            if (actionButtons.isNotEmpty) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  for (var i = 0; i < actionButtons.length; i++) ...[
                    if (i > 0) const SizedBox(width: 8),
                    Expanded(child: actionButtons[i]),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _HeaderMetaPill extends StatelessWidget {
  const _HeaderMetaPill({
    super.key,
    required this.label,
    this.bgColor,
    this.fgColor,
  });

  final String label;
  final Color? bgColor;
  final Color? fgColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bgColor ?? scheme.surfaceContainerHighest.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        maxLines: 1,
        softWrap: false,
        style: theme.textTheme.labelSmall?.copyWith(
          color: fgColor ?? scheme.onSurfaceVariant,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _HeaderMetricBlock extends StatelessWidget {
  const _HeaderMetricBlock({
    required this.label,
    required this.value,
    this.valueKey,
  });

  final String label;
  final String value;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 2),
        Container(
          height: 30,
          alignment: Alignment.centerLeft,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              key: valueKey,
              maxLines: 1,
              softWrap: false,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
                height: 1.2,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Pinned 48dp single-row control bar shared across Fund, Credit, and Debt
/// accounts:
/// - Left: 34dp dual-tab capsule (`[流水明细 | 账期账单]` on credit accounts,
///   `[流水明细 | 月度账单]` on fund accounts); tonal `明细 · N 笔` badge at the
///   same height on debt accounts.
/// - Right: on flow view (`activeTab == 0`), calendar quick-jump button
///   (non-debt) + `对账模式` toggle; on statement view (`activeTab == 1`),
///   shared 34dp `StickyStatementYearSwitcher`.
class _StickyDetailControlBarDelegate extends SliverPersistentHeaderDelegate {
  const _StickyDetailControlBarDelegate({
    required this.isCredit,
    required this.isDebt,
    required this.activeTab,
    required this.totalRecordCount,
    required this.hasPendingRepayment,
    required this.reconMode,
    required this.hasActiveFilter,
    required this.selectedStatementYear,
    required this.colorScheme,
    required this.textTheme,
    required this.onTabChanged,
    required this.onReconChanged,
    required this.onOpenPeriodPicker,
    required this.onStatementYearChanged,
  });

  final bool isCredit;
  final bool isDebt;
  final int activeTab;
  final int totalRecordCount;
  final bool hasPendingRepayment;
  final bool reconMode;
  final bool hasActiveFilter;
  final int selectedStatementYear;
  final ColorScheme colorScheme;
  final TextTheme textTheme;
  final ValueChanged<int> onTabChanged;
  final ValueChanged<bool> onReconChanged;
  final VoidCallback? onOpenPeriodPicker;
  final ValueChanged<int> onStatementYearChanged;

  @override
  double get minExtent => 48.0;

  @override
  double get maxExtent => 48.0;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final hasTabs = !isDebt;
    final showReconControl = isDebt || activeTab == 0;

    return Material(
      key: const Key('asset-sticky-control-bar'),
      color: colorScheme.surface,
      child: Container(
        height: 48.0,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: colorScheme.outlineVariant.withValues(
                alpha: overlapsContent || shrinkOffset > 0 ? 0.65 : 0.35,
              ),
              width: 0.6,
            ),
          ),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 380;
            return Row(
              children: [
                Flexible(
                  child: hasTabs
                      ? _SectionTabs(
                          flowsKey: isCredit
                              ? const Key('credit-tab-flows')
                              : const Key('fund-tab-flows'),
                          statementsKey: isCredit
                              ? const Key('credit-tab-statements')
                              : const Key('fund-tab-statements'),
                          statementsLabel: isCredit ? '账期账单' : '月度账单',
                          activeTab: activeTab,
                          hasPendingRepayment: isCredit && hasPendingRepayment,
                          compact: compact,
                          onTabChanged: onTabChanged,
                        )
                      : Container(
                          height: 34,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          decoration: BoxDecoration(
                            color: colorScheme.surfaceContainerHighest
                                .withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.receipt_long_outlined,
                                size: 15,
                                color: colorScheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    '明细 · $totalRecordCount 笔',
                                    maxLines: 1,
                                    softWrap: false,
                                    style: textTheme.labelLarge?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                ),
                SizedBox(width: compact ? 6 : 8),
                if (showReconControl)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!isDebt && onOpenPeriodPicker != null) ...[
                        Tooltip(
                          message: isCredit ? '按账期筛选' : '按月份筛选',
                          child: Material(
                            color: hasActiveFilter
                                ? colorScheme.primaryContainer
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(8),
                            clipBehavior: Clip.antiAlias,
                            child: InkWell(
                              key: const Key('asset-flow-period-picker-btn'),
                              borderRadius: BorderRadius.circular(8),
                              onTap: onOpenPeriodPicker,
                              child: SizedBox(
                                width: 30,
                                height: 30,
                                child: Icon(
                                  Icons.calendar_month_outlined,
                                  size: 18,
                                  color: hasActiveFilter
                                      ? colorScheme.onPrimaryContainer
                                      : colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ),
                        ),
                        SizedBox(width: compact ? 4 : 6),
                      ],
                      Text(
                        '对账模式',
                        maxLines: 1,
                        softWrap: false,
                        style: textTheme.labelMedium?.copyWith(
                          color: reconMode
                              ? colorScheme.primary
                              : colorScheme.onSurfaceVariant,
                          fontWeight: reconMode
                              ? FontWeight.w600
                              : FontWeight.w500,
                        ),
                      ),
                      SizedBox(width: compact ? 2 : 4),
                      SizedBox(
                        height: compact ? 30 : 32,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Switch(
                            key: const Key('reconciliation-switch'),
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            value: reconMode,
                            onChanged: onReconChanged,
                          ),
                        ),
                      ),
                    ],
                  )
                else
                  StickyStatementYearSwitcher(
                    selectedYear: selectedStatementYear,
                    compact: compact,
                    onYearChanged: onStatementYearChanged,
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _StickyDetailControlBarDelegate oldDelegate) {
    return isCredit != oldDelegate.isCredit ||
        isDebt != oldDelegate.isDebt ||
        activeTab != oldDelegate.activeTab ||
        totalRecordCount != oldDelegate.totalRecordCount ||
        hasPendingRepayment != oldDelegate.hasPendingRepayment ||
        reconMode != oldDelegate.reconMode ||
        hasActiveFilter != oldDelegate.hasActiveFilter ||
        selectedStatementYear != oldDelegate.selectedStatementYear ||
        colorScheme != oldDelegate.colorScheme ||
        textTheme != oldDelegate.textTheme;
  }
}

class _SectionTabs extends StatelessWidget {
  const _SectionTabs({
    required this.flowsKey,
    required this.statementsKey,
    required this.statementsLabel,
    required this.activeTab,
    required this.hasPendingRepayment,
    required this.compact,
    required this.onTabChanged,
  });

  final Key flowsKey;
  final Key statementsKey;
  final String statementsLabel;
  final int activeTab;
  final bool hasPendingRepayment;
  final bool compact;
  final ValueChanged<int> onTabChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    Widget segment({
      required Key key,
      required int index,
      required String label,
      bool showBadgeDot = false,
    }) {
      final selected = activeTab == index;
      final bg = selected
          ? (isDark ? scheme.secondaryContainer : scheme.surface)
          : Colors.transparent;
      final fg = selected
          ? (isDark ? scheme.onSecondaryContainer : scheme.onSurface)
          : scheme.onSurfaceVariant;

      return Flexible(
        child: Material(
          color: bg,
          elevation: selected && !isDark ? 0.5 : 0,
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: key,
            onTap: () => onTabChanged(index),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: compact ? 7 : 10),
              child: Center(
                widthFactor: 1.0,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        maxLines: 1,
                        softWrap: false,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: fg,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w500,
                        ),
                      ),
                      if (showBadgeDot) ...[
                        const SizedBox(width: 4),
                        Container(
                          key: const Key('credit-tab-pending-dot'),
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: scheme.error,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      height: 34,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          segment(key: flowsKey, index: 0, label: '流水明细'),
          const SizedBox(width: 2),
          segment(
            key: statementsKey,
            index: 1,
            label: statementsLabel,
            showBadgeDot: hasPendingRepayment,
          ),
        ],
      ),
    );
  }
}

/// Route that opens a transfer from the default repay account into [card].
String repayRoute(Asset card, BigInt amount) {
  final from = AssetExtra.parse(card.extraInfo).repayAssetId;
  return Uri(
    path: '/record/new',
    queryParameters: {
      'type': '${RecordType.transfer}',
      'to': '${card.id}',
      'from': ?from?.toString(),
      if (amount > BigInt.zero) 'amount': formatMinor(amount),
      'remark': '信用账户还款',
    },
  ).toString();
}

enum _Action { trend, edit, adjust, hide, unhide, settle, unsettle, delete }

class _AssetMenu extends ConsumerStatefulWidget {
  const _AssetMenu({
    super.key,
    required this.asset,
    this.embeddedInPane = false,
    this.onDeleted,
  });

  final Asset asset;
  final bool embeddedInPane;
  final VoidCallback? onDeleted;

  @override
  ConsumerState<_AssetMenu> createState() => _AssetMenuState();
}

class _AssetMenuState extends ConsumerState<_AssetMenu> {
  final ids = CommandIds();
  int _actionSeq = 0;

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _run(_Action action) async {
    final a = widget.asset;
    try {
      final service = await ref.read(ledgerServiceProvider.future);
      switch (action) {
        case _Action.trend:
          if (mounted) {
            await _pushRouteOrModal(
              context,
              '/stats/trend?assetId=${a.id}',
              () => AssetTrendPage(initialAssetId: a.id),
              maxWidth: 860,
              maxHeight: 740,
            );
          }
        case _Action.edit:
          if (mounted) {
            await _pushRouteOrModal(
              context,
              '/assets/${a.id}/edit',
              () => AssetEditorPage(assetId: a.id),
            );
          }
        case _Action.adjust:
          await _adjust(a);
        case _Action.hide ||
            _Action.unhide ||
            _Action.settle ||
            _Action.unsettle:
          final seq = _actionSeq++;
          if (a.type == AssetType.debt && action == _Action.unsettle) {
            final debtService = await ref.read(debtServiceProvider.future);
            await debtService.reopenDebt(
              commandId: ids.forPayload(['reopen-debt', a.id, seq]),
              debtId: a.id,
            );
          } else {
            final status = switch (action) {
              _Action.hide => AssetStatus.hidden,
              _Action.settle => AssetStatus.settled,
              _ => AssetStatus.active,
            };
            await service.setAssetStatus(
              commandId: ids.forPayload(['status', a.id, status, seq]),
              assetId: a.id,
              status: status,
            );
          }
        case _Action.delete:
          if (!mounted) return;
          final ok = await confirm(
            context,
            title: '删除“${a.name}”？',
            message: '只有没有任何账单的账户可以删除。',
            ok: '删除',
          );
          if (!ok) return;
          await service.deleteAsset(
            commandId: ids.forPayload(['delete', a.id]),
            assetId: a.id,
          );
          if (mounted) {
            if (widget.embeddedInPane) {
              widget.onDeleted?.call();
            } else {
              final route = ModalRoute.of(context);
              if (route != null && route.settings is! Page) {
                await Navigator.of(context).maybePop();
              } else if (GoRouter.maybeOf(context)?.canPop() ?? false) {
                context.pop();
              } else {
                await Navigator.of(context).maybePop();
              }
            }
          }
      }
    } catch (e) {
      _toast(safeMessage(e));
    }
  }

  Future<void> _adjust(Asset asset) async {
    if (!mounted) return;
    final credit = asset.type == AssetType.credit;
    final initialText = formatMinor(
      credit ? -asset.balanceMinor : asset.balanceMinor,
    );
    final value = await showDialog<String>(
      context: context,
      builder: (_) => _AdjustBalanceDialog(
        assetName: asset.name,
        isCredit: credit,
        initialText: initialText,
      ),
    );
    if (value == null || !mounted) return;
    final text = value.trim();
    final negative = text.startsWith('-');
    var target = _parseAmount(negative ? text.substring(1) : text);
    if (negative) target = -target;
    if (credit) target = -target;
    final db = await ref.read(databaseProvider.future);
    final bookId = await _readCurrentBookId(db);
    final service = LedgerService(db);
    final seq = _actionSeq++;
    final opTimeMs = DateTime.now().millisecondsSinceEpoch;
    await service.adjustBalance(
      commandId: ids.forPayload([
        'adjust',
        asset.id,
        target.toJson(),
        opTimeMs,
        seq,
      ]),
      assetId: asset.id,
      target: target,
      bookId: bookId,
      recordTime: opTimeMs,
    );
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.asset;
    return PopupMenuButton<_Action>(
      onSelected: (v) => _run(v),
      itemBuilder: (_) => [
        const PopupMenuItem(
          key: Key('menu-trend'),
          value: _Action.trend,
          child: Text('资产趋势'),
        ),
        const PopupMenuItem(value: _Action.edit, child: Text('编辑账户')),
        const PopupMenuItem(
          key: Key('menu-adjust'),
          value: _Action.adjust,
          child: Text('调整余额'),
        ),
        if (a.status == AssetStatus.hidden)
          const PopupMenuItem(value: _Action.unhide, child: Text('取消隐藏'))
        else
          const PopupMenuItem(value: _Action.hide, child: Text('隐藏账户')),
        if (a.status == AssetStatus.settled)
          const PopupMenuItem(value: _Action.unsettle, child: Text('恢复为正常'))
        else
          const PopupMenuItem(value: _Action.settle, child: Text('标记为已结清')),
        const PopupMenuItem(value: _Action.delete, child: Text('删除账户')),
      ],
    );
  }
}

class _AdjustBalanceDialog extends StatefulWidget {
  const _AdjustBalanceDialog({
    required this.assetName,
    required this.isCredit,
    required this.initialText,
  });

  final String assetName;
  final bool isCredit;
  final String initialText;

  @override
  State<_AdjustBalanceDialog> createState() => _AdjustBalanceDialogState();
}

class _AdjustBalanceDialogState extends State<_AdjustBalanceDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = DesktopAdaptive.isDesktop(context);
    Widget field = TextField(
      key: const Key('adjust-amount'),
      controller: _controller,
      autofocus: true,
      keyboardType: const TextInputType.numberWithOptions(
        decimal: true,
        signed: true,
      ),
      decoration: InputDecoration(
        border: isDesktop ? const OutlineInputBorder() : null,
        helperText: widget.isCredit
            ? '填当前实际欠款（溢存款填负数）；会生成一条“余额变更”记录'
            : '会生成一条“余额变更”记录',
      ),
    );
    if (isDesktop) {
      field = ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 360, maxWidth: 420),
        child: field,
      );
    }
    return AlertDialog(
      title: Text('调整“${widget.assetName}”${widget.isCredit ? '欠款' : '余额'}'),
      content: field,
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('adjust-save'),
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('保存'),
        ),
      ],
    );
  }
}
