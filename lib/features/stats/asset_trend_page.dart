import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/asset_overview.dart' show normalizeCurrency;
import '../../domain/rules/asset_trend.dart';
import 'asset_trend_providers.dart';

/// Asset trend analysis page (F-030 / docs/modules/asset-trend.md).
class AssetTrendPage extends ConsumerStatefulWidget {
  const AssetTrendPage({super.key, this.initialAssetId});

  final int? initialAssetId;

  @override
  ConsumerState<AssetTrendPage> createState() => _AssetTrendPageState();
}

class _AssetTrendPageState extends ConsumerState<AssetTrendPage> {
  int? _selectedChartIndex;
  bool _showLiabilitiesInCard1 = false;
  bool _initializedFromProps = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.initialAssetId != null && !_initializedFromProps) {
        _initializedFromProps = true;
        ref
            .read(trendFilterProvider.notifier)
            .setFilter(AssetTrendFilter.singleAsset(widget.initialAssetId!));
      } else if (!_initializedFromProps) {
        _initializedFromProps = true;
        // Check preference for default year mode
        ref.read(assetTrendQueriesProvider.future).then((q) async {
          final mode = await q.getAssetTrendMode();
          if (mounted) {
            if (mode == '1') {
              ref.read(trendSelectedYearProvider.notifier).setYear(null);
            } else {
              ref
                  .read(trendSelectedYearProvider.notifier)
                  .setYear(DateTime.now().year);
            }
          }
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final filter = ref.watch(trendFilterProvider);
    final perspective = ref.watch(trendPerspectiveProvider);
    final selectedYear = ref.watch(trendSelectedYearProvider);
    final useOriginalCurrency = ref.watch(trendUseOriginalCurrencyProvider);

    final accountsAsync = ref.watch(trendAccountsProvider);
    final accounts = accountsAsync.value ?? const [];
    final distribution = ref.watch(assetDistributionProvider);
    final trendResult = ref.watch(assetTrendResultProvider);

    TrendAccount? singleAccount;
    if (filter is AssetTrendFilterSingleAsset) {
      for (final a in accounts) {
        if (a.id == filter.assetId) {
          singleAccount = a;
          break;
        }
      }
    }

    final isForeignCurrency =
        singleAccount != null &&
        singleAccount.currency != null &&
        normalizeCurrency(singleAccount.currency) != 'CNY';

    final pageTitle = _buildPageTitle(filter, singleAccount);

    return Scaffold(
      appBar: AppBar(
        title: Text(pageTitle),
        actions: [
          IconButton(
            key: const Key('trend-filter-button'),
            tooltip: '筛选账户范围',
            icon: const Icon(Icons.tune),
            onPressed: () => _showScopePickerDialog(context, accounts, filter),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          children: [
            // 1. Top Year Filter Row
            _buildYearSelector(context, selectedYear),
            const SizedBox(height: 12),

            // 2. Perspective SegmentedButton or Foreign Currency Switch
            if (filter is! AssetTrendFilterSingleAsset)
              _buildPerspectiveSegment(context, perspective)
            else if (isForeignCurrency)
              _buildCurrencySwitchRow(
                context,
                singleAccount,
                useOriginalCurrency,
              ),
            const SizedBox(height: 16),

            // 3. Card 1: Real-time Asset Distribution
            if (distribution != null)
              _buildDistributionCard(context, distribution)
            else
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: CircularProgressIndicator(),
                ),
              ),
            const SizedBox(height: 16),

            // 4. Card 2: Trend Line Chart
            if (trendResult != null)
              _buildTrendChartCard(context, trendResult, perspective)
            else
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: CircularProgressIndicator(),
                ),
              ),
            const SizedBox(height: 16),

            // 5. Card 3: Monthly Flow Table
            if (trendResult != null)
              _buildFlowTableCard(context, trendResult)
            else
              const SizedBox.shrink(),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  String _buildPageTitle(AssetTrendFilter filter, TrendAccount? singleAccount) {
    return switch (filter) {
      AssetTrendFilterAllEffective() => '资产趋势',
      AssetTrendFilterCategory(:final categoryCode) => switch (categoryCode) {
        AssetType.normal => '普通资金趋势',
        AssetType.credit => '信用账户趋势',
        AssetType.debtLend => '借出债权趋势',
        AssetType.debtBorrow => '借入债务趋势',
        _ => '分类资产趋势',
      },
      AssetTrendFilterCustomGroup(:final groupName) => '$groupName 趋势',
      AssetTrendFilterSingleAsset() =>
        singleAccount != null ? '${singleAccount.name} 趋势' : '单账户趋势',
    };
  }

  Widget _buildYearSelector(BuildContext context, int? selectedYear) {
    final currentYear = DateTime.now().year;
    final years = <int?>[
      null, // "所有时间"
      for (var y = currentYear; y >= 2008; y--) y,
    ];

    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: years.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final year = years[index];
          final isSelected = selectedYear == year;
          final label = year == null ? '所有时间' : '$year年';
          final key = year == null
              ? const Key('trend-year-all')
              : Key('trend-year-$year');

          return ChoiceChip(
            key: key,
            label: Text(label),
            selected: isSelected,
            onSelected: (selected) {
              if (selected) {
                ref.read(trendSelectedYearProvider.notifier).setYear(year);
                final mode = year == null ? '1' : '0';
                ref
                    .read(assetTrendQueriesProvider.future)
                    .then((q) => q.setAssetTrendMode(mode));
                setState(() => _selectedChartIndex = null);
              }
            },
          );
        },
      ),
    );
  }

  Widget _buildPerspectiveSegment(
    BuildContext context,
    AssetTrendPerspective current,
  ) {
    return Center(
      child: SegmentedButton<AssetTrendPerspective>(
        segments: const [
          ButtonSegment(
            value: AssetTrendPerspective.netWorth,
            label: Text('净资产', key: Key('trend-perspective-netWorth')),
          ),
          ButtonSegment(
            value: AssetTrendPerspective.totalAsset,
            label: Text('总资产', key: Key('trend-perspective-totalAsset')),
          ),
          ButtonSegment(
            value: AssetTrendPerspective.totalLiability,
            label: Text('总负债', key: Key('trend-perspective-totalLiability')),
          ),
        ],
        selected: {current},
        onSelectionChanged: (selected) {
          if (selected.isNotEmpty) {
            ref
                .read(trendPerspectiveProvider.notifier)
                .setPerspective(selected.first);
            setState(() => _selectedChartIndex = null);
          }
        },
      ),
    );
  }

  Widget _buildCurrencySwitchRow(
    BuildContext context,
    TrendAccount account,
    bool useOriginal,
  ) {
    final originalSymbol = currencySymbolOf(account.currency);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '显示币种：${useOriginal ? "$originalSymbol (${account.currency})" : "¥ (折算本币)"}',
            ),
            Row(
              children: [
                const Text('折算本币'),
                Switch(
                  key: const Key('trend-currency-switch'),
                  value: useOriginal,
                  onChanged: (val) {
                    ref
                        .read(trendUseOriginalCurrencyProvider.notifier)
                        .setUseOriginalCurrency(val);
                  },
                ),
                Text('原币 ($originalSymbol)'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDistributionCard(
    BuildContext context,
    AssetDistributionResult dist,
  ) {
    final theme = Theme.of(context);
    final isLiab = _showLiabilitiesInCard1;
    final items = isLiab ? dist.liabilityItems : dist.positiveItems;
    final totalMinor = isLiab
        ? dist.liabilityTotalMinor
        : dist.positiveTotalMinor;
    final totalLabel = isLiab ? '总负债' : '总资产';

    const colors = [
      Color(0xFF3F51B5),
      Color(0xFF2196F3),
      Color(0xFF009688),
      Color(0xFF4CAF50),
      Color(0xFFFF9800),
      Color(0xFF9C27B0),
      Color(0xFFE91E63),
      Color(0xFF795548),
      Color(0xFF607D8B),
    ];

    return Card(
      key: const Key('trend-card-distribution'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '资产状况',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('资产')),
                    ButtonSegment(value: true, label: Text('负债')),
                  ],
                  selected: {isLiab},
                  onSelectionChanged: (set) {
                    setState(() => _showLiabilitiesInCard1 = set.first);
                  },
                ),
              ],
            ),
            const SizedBox(height: 16),
            Center(
              child: SizedBox(
                width: 180,
                height: 180,
                child: CustomPaint(
                  painter: _DonutChartPainter(
                    items: items,
                    colors: colors,
                    totalMinor: totalMinor,
                    totalLabel: totalLabel,
                    textColor: theme.colorScheme.onSurface,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (items.isEmpty)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    '暂无相关${isLiab ? "负债" : "资产"}记录',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              )
            else
              ...List.generate(items.length, (idx) {
                final item = items[idx];
                final color = colors[idx % colors.length];
                final pct = (item.ratio * 100).toStringAsFixed(1);
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          item.name,
                          style: theme.textTheme.bodyMedium,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        '$pct%',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        '¥${Money.minor(item.amountMinor).decimal}',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }

  Widget _buildTrendChartCard(
    BuildContext context,
    AssetTrendResult result,
    AssetTrendPerspective perspective,
  ) {
    final theme = Theme.of(context);
    final cardTitle = result.isCredit
        ? '欠款趋势'
        : switch (perspective) {
            AssetTrendPerspective.netWorth => '净资产趋势',
            AssetTrendPerspective.totalAsset => '总资产趋势',
            AssetTrendPerspective.totalLiability => '总负债趋势',
          };

    final points = result.chartPoints;

    return Card(
      key: const Key('trend-card-chart'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  cardTitle,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (_selectedChartIndex != null &&
                    _selectedChartIndex! >= 0 &&
                    _selectedChartIndex! < points.length)
                  Text(
                    points[_selectedChartIndex!].yearMonth,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 220,
              width: double.infinity,
              child: GestureDetector(
                onTapDown: (details) =>
                    _handleChartTouch(details.localPosition, points),
                onHorizontalDragUpdate: (details) =>
                    _handleChartTouch(details.localPosition, points),
                child: CustomPaint(
                  painter: _LineChartPainter(
                    points: points,
                    selectedIndex: _selectedChartIndex,
                    isCredit: result.isCredit,
                    symbol: result.currencySymbol,
                    lineColor: theme.colorScheme.primary,
                    gridColor: theme.colorScheme.outlineVariant,
                    textColor: theme.colorScheme.onSurfaceVariant,
                    surfaceColor: theme.colorScheme.surface,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _handleChartTouch(Offset pos, List<TrendPoint> points) {
    if (points.isEmpty) return;
    const paddingLeft = 40.0;
    const paddingRight = 16.0;
    final chartWidth = context.size?.width ?? 320.0;
    final availableWidth = chartWidth - paddingLeft - paddingRight - 32;

    if (pos.dx < paddingLeft) {
      setState(() => _selectedChartIndex = 0);
      return;
    }
    if (pos.dx > paddingLeft + availableWidth) {
      setState(() => _selectedChartIndex = points.length - 1);
      return;
    }

    final ratio = (pos.dx - paddingLeft) / availableWidth;
    final index = (ratio * (points.length - 1)).round().clamp(
      0,
      points.length - 1,
    );
    setState(() => _selectedChartIndex = index);
  }

  Widget _buildFlowTableCard(BuildContext context, AssetTrendResult result) {
    final theme = Theme.of(context);
    final rows = result.tableRows;

    return Card(
      key: const Key('trend-card-flow'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '资产流水',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            if (rows.isEmpty)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('暂无月度流水明细'),
                ),
              )
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: rows.length,
                separatorBuilder: (_, __) => const Divider(height: 16),
                itemBuilder: (context, index) {
                  final row = rows[index];
                  final formattedBal = formatTrendBalance(
                    row.balanceMinor,
                    isCredit: result.isCredit,
                    symbol: result.currencySymbol,
                  );
                  final inflowStr = Money.minor(row.inflowMinor).decimal;
                  final outflowStr = Money.minor(row.outflowMinor).decimal;

                  return Row(
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                row.yearMonth,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              if (row.isCarriedForward)
                                Padding(
                                  padding: const EdgeInsets.only(left: 4),
                                  child: Text(
                                    '(结转)',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.outline,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Text(
                                '流入：${result.currencySymbol}$inflowStr',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: Colors.green.shade700,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '流出：${result.currencySymbol}$outflowStr',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: Colors.red.shade700,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      const Spacer(),
                      Text(
                        formattedBal,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  void _showScopePickerDialog(
    BuildContext context,
    List<TrendAccount> accounts,
    AssetTrendFilter currentFilter,
  ) {
    final customGroups = accounts
        .where((a) => a.groupName != null && a.groupName!.isNotEmpty)
        .map((a) => a.groupName!)
        .toSet()
        .toList();

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          maxChildSize: 0.9,
          minChildSize: 0.4,
          builder: (context, scrollController) {
            return ListView(
              controller: scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade400,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  '选择目标账户范围',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),

                // 1. 全部有效净资产
                ListTile(
                  leading: const Icon(Icons.account_balance),
                  title: const Text('全部有效净资产 (默认)'),
                  selected: currentFilter is AssetTrendFilterAllEffective,
                  onTap: () {
                    ref
                        .read(trendFilterProvider.notifier)
                        .setFilter(const AssetTrendFilter.allEffective());
                    Navigator.pop(context);
                  },
                ),
                const Divider(),

                // 2. 内置分类
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: Text(
                    '按内置分类',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.account_balance_wallet),
                  title: const Text('普通资金账户'),
                  selected:
                      currentFilter is AssetTrendFilterCategory &&
                      currentFilter.categoryCode == AssetType.normal,
                  onTap: () {
                    ref
                        .read(trendFilterProvider.notifier)
                        .setFilter(
                          const AssetTrendFilter.assetCategory(
                            AssetType.normal,
                          ),
                        );
                    Navigator.pop(context);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.credit_card),
                  title: const Text('信用卡'),
                  selected:
                      currentFilter is AssetTrendFilterCategory &&
                      currentFilter.categoryCode == AssetType.credit,
                  onTap: () {
                    ref
                        .read(trendFilterProvider.notifier)
                        .setFilter(
                          const AssetTrendFilter.assetCategory(
                            AssetType.credit,
                          ),
                        );
                    Navigator.pop(context);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.arrow_upward),
                  title: const Text('借出债权'),
                  selected:
                      currentFilter is AssetTrendFilterCategory &&
                      currentFilter.categoryCode == AssetType.debtLend,
                  onTap: () {
                    ref
                        .read(trendFilterProvider.notifier)
                        .setFilter(
                          const AssetTrendFilter.assetCategory(
                            AssetType.debtLend,
                          ),
                        );
                    Navigator.pop(context);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.arrow_downward),
                  title: const Text('借入债务'),
                  selected:
                      currentFilter is AssetTrendFilterCategory &&
                      currentFilter.categoryCode == AssetType.debtBorrow,
                  onTap: () {
                    ref
                        .read(trendFilterProvider.notifier)
                        .setFilter(
                          const AssetTrendFilter.assetCategory(
                            AssetType.debtBorrow,
                          ),
                        );
                    Navigator.pop(context);
                  },
                ),
                const Divider(),

                // 3. 自定义分组
                if (customGroups.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    child: Text(
                      '按自定义分组',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  for (final g in customGroups)
                    ListTile(
                      leading: const Icon(Icons.folder_outlined),
                      title: Text(g),
                      selected:
                          currentFilter is AssetTrendFilterCustomGroup &&
                          currentFilter.groupName == g,
                      onTap: () {
                        ref
                            .read(trendFilterProvider.notifier)
                            .setFilter(AssetTrendFilter.customGroup(g));
                        Navigator.pop(context);
                      },
                    ),
                  const Divider(),
                ],

                // 4. 单个账户（含隐藏账户）
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: Text(
                    '单个账户',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                for (final a in accounts)
                  ListTile(
                    leading: Icon(
                      a.isCredit
                          ? Icons.credit_card
                          : Icons.account_balance_wallet_outlined,
                    ),
                    title: Text(a.name),
                    subtitle: a.status == AssetStatus.hidden
                        ? const Text(
                            '已隐藏',
                            style: TextStyle(color: Colors.orange),
                          )
                        : (a.currency != null ? Text(a.currency!) : null),
                    trailing: Text(
                      a.isCredit
                          ? formatTrendBalance(a.balanceMinor, isCredit: true)
                          : '¥${Money.minor(a.balanceMinor).decimal}',
                    ),
                    selected:
                        currentFilter is AssetTrendFilterSingleAsset &&
                        currentFilter.assetId == a.id,
                    onTap: () {
                      ref
                          .read(trendFilterProvider.notifier)
                          .setFilter(AssetTrendFilter.singleAsset(a.id));
                      Navigator.pop(context);
                    },
                  ),
              ],
            );
          },
        );
      },
    );
  }
}

/// CustomPaint ring distribution chart.
class _DonutChartPainter extends CustomPainter {
  const _DonutChartPainter({
    required this.items,
    required this.colors,
    required this.totalMinor,
    required this.totalLabel,
    required this.textColor,
  });

  final List<AssetDistributionItem> items;
  final List<Color> colors;
  final BigInt totalMinor;
  final String totalLabel;
  final Color textColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 12;
    const strokeWidth = 24.0;

    final basePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..color = Colors.grey.withValues(alpha: 0.2);

    canvas.drawCircle(center, radius, basePaint);

    if (items.isNotEmpty && totalMinor > BigInt.zero) {
      var startAngle = -math.pi / 2;
      for (var i = 0; i < items.length; i++) {
        final item = items[i];
        final sweepAngle = 2 * math.pi * item.ratio;
        if (sweepAngle <= 0) continue;

        final color = colors[i % colors.length];
        final arcPaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..color = color;

        canvas.drawArc(
          Rect.fromCircle(center: center, radius: radius),
          startAngle,
          sweepAngle,
          false,
          arcPaint,
        );
        startAngle += sweepAngle;
      }
    }

    // Center text
    final textPainter = TextPainter(
      text: TextSpan(
        children: [
          TextSpan(
            text: '$totalLabel\n',
            style: TextStyle(
              color: textColor.withValues(alpha: 0.7),
              fontSize: 13,
            ),
          ),
          TextSpan(
            text: '¥${Money.minor(totalMinor).decimal}',
            style: TextStyle(
              color: textColor,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width - 60);

    textPainter.paint(
      canvas,
      Offset(
        center.dx - textPainter.width / 2,
        center.dy - textPainter.height / 2,
      ),
    );
  }

  @override
  bool shouldRepaint(covariant _DonutChartPainter oldDelegate) => true;
}

/// CustomPaint line chart with interactive point selection and bubble tooltip.
class _LineChartPainter extends CustomPainter {
  const _LineChartPainter({
    required this.points,
    required this.selectedIndex,
    required this.isCredit,
    required this.symbol,
    required this.lineColor,
    required this.gridColor,
    required this.textColor,
    required this.surfaceColor,
  });

  final List<TrendPoint> points;
  final int? selectedIndex;
  final bool isCredit;
  final String symbol;
  final Color lineColor;
  final Color gridColor;
  final Color textColor;
  final Color surfaceColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;

    const paddingLeft = 48.0;
    const paddingRight = 16.0;
    const paddingTop = 28.0;
    const paddingBottom = 28.0;

    final width = size.width - paddingLeft - paddingRight;
    final height = size.height - paddingTop - paddingBottom;

    final balances = points
        .map((p) => p.balanceMinor.toDouble() / 100.0)
        .toList();
    var minBal = balances.reduce(math.min);
    var maxBal = balances.reduce(math.max);

    if (minBal == maxBal) {
      if (minBal > 0) {
        minBal = 0;
      } else if (minBal < 0) {
        maxBal = 0;
      } else {
        maxBal = 100;
        minBal = 0;
      }
    }

    final range = maxBal - minBal;
    double yFor(double bal) {
      return (size.height - paddingBottom) - ((bal - minBal) / range) * height;
    }

    double xFor(int index) {
      if (points.length <= 1) return paddingLeft + width / 2;
      return paddingLeft + (index / (points.length - 1)) * width;
    }

    // 1. Draw Grid Lines (3 lines)
    final gridPaint = Paint()
      ..color = gridColor.withValues(alpha: 0.5)
      ..strokeWidth = 1;

    for (var i = 0; i <= 2; i++) {
      final yBal = minBal + (range / 2) * i;
      final y = yFor(yBal);
      canvas.drawLine(
        Offset(paddingLeft, y),
        Offset(size.width - paddingRight, y),
        gridPaint,
      );

      final labelPainter = TextPainter(
        text: TextSpan(
          text: yBal.toStringAsFixed(0),
          style: TextStyle(
            color: textColor.withValues(alpha: 0.6),
            fontSize: 10,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      labelPainter.paint(
        canvas,
        Offset(
          paddingLeft - labelPainter.width - 6,
          y - labelPainter.height / 2,
        ),
      );
    }

    // 2. Draw Zero Axis if in range
    if (minBal < 0 && maxBal > 0) {
      final zeroY = yFor(0);
      final zeroPaint = Paint()
        ..color = gridColor
        ..strokeWidth = 1.5;
      canvas.drawLine(
        Offset(paddingLeft, zeroY),
        Offset(size.width - paddingRight, zeroY),
        zeroPaint,
      );
    }

    // 3. Draw Line Path and Area Fill
    final linePath = Path();
    final fillPath = Path();

    linePath.moveTo(xFor(0), yFor(balances[0]));
    fillPath.moveTo(xFor(0), size.height - paddingBottom);
    fillPath.lineTo(xFor(0), yFor(balances[0]));

    for (var i = 1; i < points.length; i++) {
      linePath.lineTo(xFor(i), yFor(balances[i]));
      fillPath.lineTo(xFor(i), yFor(balances[i]));
    }

    fillPath.lineTo(xFor(points.length - 1), size.height - paddingBottom);
    fillPath.close();

    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          lineColor.withValues(alpha: 0.25),
          lineColor.withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromLTWH(0, paddingTop, size.width, height));
    canvas.drawPath(fillPath, fillPaint);

    final linePaint = Paint()
      ..color = lineColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(linePath, linePaint);

    // 4. Draw Points & X-axis Labels
    final dotPaint = Paint()..color = lineColor;
    final dotInnerPaint = Paint()..color = surfaceColor;

    for (var i = 0; i < points.length; i++) {
      final x = xFor(i);
      final y = yFor(balances[i]);

      canvas.drawCircle(Offset(x, y), 4, dotPaint);
      canvas.drawCircle(Offset(x, y), 2, dotInnerPaint);

      // Month label below
      final label = points[i].month.toString().padLeft(2, '0');
      final xPainter = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(color: textColor, fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      xPainter.paint(
        canvas,
        Offset(x - xPainter.width / 2, size.height - paddingBottom + 6),
      );
    }

    // 5. Selected Point Highlight & Tooltip Bubble
    if (selectedIndex != null &&
        selectedIndex! >= 0 &&
        selectedIndex! < points.length) {
      final selIdx = selectedIndex!;
      final selX = xFor(selIdx);
      final selY = yFor(balances[selIdx]);
      final selPoint = points[selIdx];

      // Vertical dashed guide line
      final guidePaint = Paint()
        ..color = lineColor.withValues(alpha: 0.6)
        ..strokeWidth = 1.5;
      canvas.drawLine(
        Offset(selX, paddingTop),
        Offset(selX, size.height - paddingBottom),
        guidePaint,
      );

      // Outer halo
      canvas.drawCircle(
        Offset(selX, selY),
        7,
        Paint()..color = lineColor.withValues(alpha: 0.3),
      );
      canvas.drawCircle(Offset(selX, selY), 5, Paint()..color = lineColor);

      // Tooltip Text
      final formatted = formatTrendBalance(
        selPoint.balanceMinor,
        isCredit: isCredit,
        symbol: symbol,
      );
      final tipSpan = TextSpan(
        text: '${selPoint.yearMonth}\n$formatted',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      );
      final tipPainter = TextPainter(
        text: tipSpan,
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      )..layout();

      const bubblePaddingH = 8.0;
      const bubblePaddingV = 4.0;
      final bubbleW = tipPainter.width + bubblePaddingH * 2;
      final bubbleH = tipPainter.height + bubblePaddingV * 2;

      var bubbleX = selX - bubbleW / 2;
      var bubbleY = selY - bubbleH - 10;

      // Keep inside bounds
      if (bubbleX < paddingLeft) bubbleX = paddingLeft;
      if (bubbleX + bubbleW > size.width - paddingRight) {
        bubbleX = size.width - paddingRight - bubbleW;
      }
      if (bubbleY < 0) bubbleY = selY + 12;

      final bubbleRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(bubbleX, bubbleY, bubbleW, bubbleH),
        const Radius.circular(6),
      );

      final bubblePaint = Paint()..color = const Color(0xFF263238);
      canvas.drawRRect(bubbleRect, bubblePaint);

      tipPainter.paint(
        canvas,
        Offset(bubbleX + bubblePaddingH, bubbleY + bubblePaddingV),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _LineChartPainter oldDelegate) => true;
}

/// Lightweight overview card for embedding in the Stats overview page.
class AssetTrendOverviewCard extends ConsumerWidget {
  const AssetTrendOverviewCard({super.key, this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final dist = ref.watch(assetDistributionProvider);

    final netWorth = dist?.netAssetMinor ?? BigInt.zero;
    final totalAsset = dist?.positiveTotalMinor ?? BigInt.zero;
    final totalLiability = dist?.liabilityTotalMinor ?? BigInt.zero;

    final ratio = totalAsset > BigInt.zero
        ? (netWorth.toDouble() / totalAsset.toDouble()).clamp(0.0, 1.0)
        : 0.0;
    // Cap at 0.98 if between 0.98 and 1.0 to preserve ring gap
    final visualRatio = (ratio > 0.98 && ratio < 1.0) ? 0.98 : ratio;

    return Card(
      key: const Key('trend-overview-card'),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '总净资产',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '¥${Money.minor(netWorth).decimal}',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Text(
                          '总资产 ¥${Money.minor(totalAsset).decimal}',
                          style: theme.textTheme.bodySmall,
                        ),
                        if (totalLiability > BigInt.zero) ...[
                          const SizedBox(width: 12),
                          Text(
                            '总负债 ¥${Money.minor(totalLiability).decimal}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.error,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 48,
                height: 48,
                child: CustomPaint(
                  painter: _MiniRingProgressPainter(
                    ratio: visualRatio,
                    primaryColor: theme.colorScheme.primary,
                    trackColor: theme.colorScheme.surfaceContainerHighest,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniRingProgressPainter extends CustomPainter {
  const _MiniRingProgressPainter({
    required this.ratio,
    required this.primaryColor,
    required this.trackColor,
  });

  final double ratio;
  final Color primaryColor;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 4;
    const strokeWidth = 6.0;

    final trackPaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    canvas.drawCircle(center, radius, trackPaint);

    if (ratio > 0) {
      final progPaint = Paint()
        ..color = primaryColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round;

      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2,
        2 * math.pi * ratio,
        false,
        progPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _MiniRingProgressPainter oldDelegate) => true;
}
