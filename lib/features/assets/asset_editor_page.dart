import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/failure.dart';
import '../../core/money.dart';
import '../../data/db/database.dart';
import '../../domain/ledger/asset_json.dart';
import '../../domain/model/codes.dart';
import '../common/catalog_icons.dart';
import '../common/common.dart';

final _maxAssetAmount = Money.parse('88888888888.00');

final _amountInputFormatters = <TextInputFormatter>[
  FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
];

Money _parseAmount(String text) {
  final t = text.trim();
  if (t.isEmpty) return Money.zero();
  final normalized = t.endsWith('.') ? t.substring(0, t.length - 1) : t;
  final money = Money.parse(
    normalized.startsWith('.') ? '0$normalized' : normalized,
  );
  if (money.units > _maxAssetAmount.units) {
    throw const Failure(FailureCode.validation, '金额不能超过 88888888888.00');
  }
  return money;
}

/// Label for a credit-account day setting.
String creditDayLabel(int day) => switch (day) {
  endOfMonthDay => '月底',
  unsetDay => '未设置',
  _ => '每月 $day 日',
};

/// Creates ([assetId] null) or edits an account. Normal accounts and credit
/// accounts (docs/modules/credit-account.md) share this form.
class AssetEditorPage extends ConsumerStatefulWidget {
  const AssetEditorPage({super.key, this.assetId, this.initialType});
  final int? assetId;
  final int? initialType;
  @override
  ConsumerState<AssetEditorPage> createState() => _AssetEditorPageState();
}

class _AssetEditorPageState extends ConsumerState<AssetEditorPage> {
  final name = TextEditingController();
  final balance = TextEditingController();
  final limit = TextEditingController();
  final remark = TextEditingController();
  final afterDays = TextEditingController(text: '20');
  final ids = CommandIds();

  int type = AssetType.normal;
  String? selectedIcon;
  String? selectedColor;
  bool _userPickedVisual = false;
  String? currency;
  bool counted = true, busy = false, loading = true;
  int billDay = 1;
  int repaymentDay = 20;
  bool repaymentAfter = false;
  bool billDayCounted = true;
  int? repayAssetId;
  CreditInfo creditInfo = CreditInfo();
  AssetExtra extra = AssetExtra();
  Asset? original;
  String? error;

  bool get editing => widget.assetId != null;
  bool get isCredit => type == AssetType.credit;

  @override
  void initState() {
    super.initState();
    type = widget.initialType ?? AssetType.normal;
    _loadExisting();
  }

  Future<void> _loadExisting() async {
    try {
      if (editing) {
        final id = widget.assetId!;
        final db = await ref.read(databaseProvider.future);
        final existing = await (db.select(
          db.assets,
        )..where((a) => a.id.equals(id))).getSingleOrNull();
        if (existing == null) {
          throw const Failure(FailureCode.conflict, '账户不存在或已删除');
        }
        original = existing;
        type = existing.type;
        name.text = existing.name;
        selectedIcon = existing.icon.isEmpty ? null : existing.icon;
        selectedColor = existing.color;
        remark.text = existing.remark ?? '';
        currency = existing.currency;
        counted = existing.type == AssetType.debt
            ? existing.isEffectiveAsset == 0
            : existing.isEffectiveAsset == 1;
        creditInfo = CreditInfo.parse(existing.creditInfo);
        extra = AssetExtra.parse(existing.extraInfo);
        if (isCredit) {
          limit.text = formatMinor(existing.initMoneyMinor);
          if (creditInfo.billDay != unsetDay) billDay = creditInfo.billDay;
          repaymentAfter = creditInfo.repaymentAfterBillDay;
          if (repaymentAfter) {
            afterDays.text = '${creditInfo.repaymentDay}';
          } else if (creditInfo.repaymentDay != unsetDay) {
            repaymentDay = creditInfo.repaymentDay;
          }
          billDayCounted = creditInfo.billDayCounted;
          repayAssetId = extra.repayAssetId;
        }
      }
    } catch (e) {
      error = safeMessage(e);
    }
    if (mounted) setState(() => loading = false);
  }

  @override
  void dispose() {
    name.dispose();
    balance.dispose();
    limit.dispose();
    remark.dispose();
    afterDays.dispose();
    super.dispose();
  }

  AssetVisual _currentVisual() {
    var effectiveIcon = selectedIcon;
    var effectiveColor = selectedColor;
    if (editing && !_userPickedVisual && original != null) {
      final origDefault = resolveAssetVisual(
        name: original!.name,
        assetType: original!.type,
        subType: original!.subType,
      );
      final nameChanged = name.text.trim() != original!.name;
      if (nameChanged &&
          (original!.icon.isEmpty || original!.icon == origDefault.iconKey) &&
          (original!.color == null ||
              original!.color!.toUpperCase() ==
                  origDefault.colorHex.toUpperCase())) {
        effectiveIcon = null;
        effectiveColor = null;
      }
    }
    return resolveAssetVisual(
      iconKey: effectiveIcon,
      colorHex: effectiveColor,
      name: name.text.trim(),
      assetType: type,
      subType: original?.subType,
    );
  }

  Future<void> _pickVisual() async {
    final current = _currentVisual();
    final picked = await showAssetVisualPicker(
      context,
      initialIcon: current.iconKey,
      initialColor: _userPickedVisual || (selectedColor?.isNotEmpty ?? false)
          ? current.colorHex
          : null,
      assetType: type,
      subType: original?.subType,
      previewName: name.text.trim(),
    );
    if (picked == null || !mounted) return;
    setState(() {
      selectedIcon = picked.icon;
      selectedColor = picked.colorHex;
      _userPickedVisual = true;
    });
  }

  Future<void> _save() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      Money? creditLimit;
      String? creditJson = original?.creditInfo;
      String? extraJson = original?.extraInfo;
      if (isCredit) {
        creditLimit = _parseAmount(limit.text);
        final days = int.tryParse(afterDays.text.trim());
        if (repaymentAfter && (days == null || days < 0 || days > 60)) {
          throw const Failure(FailureCode.validation, '“账单日后天数”须为 0–60');
        }
        creditInfo
          ..billDay = billDay
          ..repaymentAfterBillDay = repaymentAfter
          ..repaymentDay = repaymentAfter ? days! : repaymentDay
          ..billDayCounted = billDayCounted;
        extra.repayAssetId = repayAssetId;
        creditJson = creditInfo.encode();
        extraJson = extra.encode();
      }
      final visual = _currentVisual();
      final service = await ref.read(ledgerServiceProvider.future);
      final rem = remark.text.trim().isEmpty ? null : remark.text.trim();
      if (editing) {
        await service.updateAsset(
          commandId: ids.forPayload([
            'edit',
            widget.assetId,
            name.text,
            visual.iconKey,
            visual.colorHex,
            rem,
            currency,
            counted,
            creditLimit?.toJson(),
            creditJson,
            extraJson,
          ]),
          assetId: widget.assetId!,
          name: name.text,
          icon: visual.iconKey,
          color: visual.colorHex,
          remark: rem,
          groupName: original?.groupName,
          currency: currency,
          countedInNetWorth: counted,
          limit: creditLimit,
          creditInfo: creditJson,
          extraInfo: extraJson,
        );
      } else {
        // Credit accounts: the user enters the current debt as a positive number.
        var initial = _parseAmount(balance.text);
        if (isCredit) initial = -initial;
        await service.createAsset(
          commandId: ids.forPayload([
            'create',
            type,
            name.text,
            visual.iconKey,
            visual.colorHex,
            initial.toJson(),
            rem,
            currency,
            counted,
            creditLimit?.toJson(),
            creditJson,
            extraJson,
          ]),
          name: name.text,
          initial: initial,
          type: type,
          icon: visual.iconKey,
          color: visual.colorHex,
          remark: rem,
          currency: currency,
          countedInNetWorth: counted,
          limit: creditLimit,
          creditInfo: creditJson,
          extraInfo: extraJson,
        );
      }
      if (mounted) context.pop();
    } catch (e) {
      if (mounted) setState(() => error = safeMessage(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  List<DropdownMenuItem<int>> _dayItems() => [
    for (var d = 1; d <= 28; d++)
      DropdownMenuItem(value: d, child: Text('每月 $d 日')),
    const DropdownMenuItem(value: endOfMonthDay, child: Text('月底')),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final currencies = ref.watch(currenciesProvider).value ?? const [];
    final assets = (ref.watch(assetsProvider).value ?? const <Asset>[])
        .where((a) => a.type != AssetType.credit && a.id != widget.assetId)
        .toList();
    final visual = _currentVisual();
    final titleText = isCredit
        ? (editing ? '编辑信用账户' : '新建信用账户')
        : (editing ? '编辑账户' : '新建账户');

    return Scaffold(
      appBar: AppBar(title: Text(titleText)),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton(
            key: const Key('asset-save'),
            onPressed: busy || loading ? null : _save,
            child: Text(busy ? '保存中…' : '保存'),
          ),
        ),
      ),
      body: loading
          ? const Loading()
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (!editing)
                      SegmentedButton<int>(
                        segments: const [
                          ButtonSegment(
                            value: AssetType.normal,
                            label: Text('普通账户'),
                            icon: Icon(Icons.account_balance_wallet_outlined),
                          ),
                          ButtonSegment(
                            value: AssetType.credit,
                            label: Text('信用账户'),
                            icon: Icon(Icons.credit_card),
                          ),
                        ],
                        selected: {type},
                        onSelectionChanged: busy
                            ? null
                            : (s) => setState(() {
                                type = s.first;
                                if (!_userPickedVisual) {
                                  selectedIcon = null;
                                  selectedColor = null;
                                }
                              }),
                      ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const Key('asset-name'),
                      controller: name,
                      enabled: !busy,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        labelText: '账户名称',
                        hintText: isCredit
                            ? '如：招行信用卡、花呗、白条'
                            : '如：现金、招行储蓄卡、微信钱包、支付宝',
                      ),
                    ),
                    const SizedBox(height: 12),
                    InkWell(
                      key: const Key('asset-visual-picker-trigger'),
                      borderRadius: BorderRadius.circular(12),
                      onTap: busy ? null : _pickVisual,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: theme.colorScheme.outlineVariant,
                          ),
                        ),
                        child: Row(
                          children: [
                            AssetIconAvatar(
                              iconKey: visual.iconKey,
                              colorHex: visual.colorHex,
                              name: visual.label,
                              assetType: type,
                              subType: original?.subType,
                              size: 40,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '账户图标与颜色',
                                    style: theme.textTheme.bodyMedium,
                                  ),
                                  Text(
                                    '${visual.label} · 点击更换图标或配色',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.outline,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const Icon(Icons.chevron_right),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (!editing)
                      TextField(
                        key: const Key('asset-balance'),
                        controller: balance,
                        enabled: !busy,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: _amountInputFormatters,
                        decoration: InputDecoration(
                          labelText: isCredit ? '当前欠款' : '当前余额',
                          helperText: isCredit ? '没有欠款就留空或填 0' : null,
                        ),
                      )
                    else
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(isCredit ? '当前欠款/溢存' : '当前余额'),
                        subtitle: const Text('修改余额请在账户详情里使用“调整余额”'),
                        trailing: Text(
                          formatMinor(original?.balanceMinor ?? BigInt.zero),
                        ),
                      ),
                    if (isCredit) ...[
                      const SizedBox(height: 12),
                      TextField(
                        key: const Key('credit-limit'),
                        controller: limit,
                        enabled: !busy,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: _amountInputFormatters,
                        decoration: const InputDecoration(labelText: '信用额度'),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<int>(
                        key: const Key('bill-day'),
                        initialValue: billDay,
                        decoration: const InputDecoration(labelText: '账单日'),
                        items: _dayItems(),
                        onChanged: busy
                            ? null
                            : (v) => setState(() => billDay = v ?? 1),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('账单日当天的消费计入本期账单'),
                        value: billDayCounted,
                        onChanged: busy
                            ? null
                            : (v) => setState(() => billDayCounted = v),
                      ),
                      SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(value: false, label: Text('固定还款日')),
                          ButtonSegment(value: true, label: Text('账单日后 N 天')),
                        ],
                        selected: {repaymentAfter},
                        onSelectionChanged: busy
                            ? null
                            : (s) => setState(() => repaymentAfter = s.first),
                      ),
                      const SizedBox(height: 8),
                      if (repaymentAfter)
                        TextField(
                          key: const Key('repay-after-days'),
                          controller: afterDays,
                          enabled: !busy,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: '账单日后天数',
                            suffixText: '天',
                          ),
                        )
                      else
                        DropdownButtonFormField<int>(
                          key: const Key('repay-day'),
                          initialValue: repaymentDay,
                          decoration: const InputDecoration(labelText: '还款日'),
                          items: _dayItems(),
                          onChanged: busy
                              ? null
                              : (v) => setState(() => repaymentDay = v ?? 1),
                        ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<int>(
                        initialValue: assets.any((a) => a.id == repayAssetId)
                            ? repayAssetId
                            : noRef,
                        decoration: const InputDecoration(
                          labelText: '默认还款账户（可选）',
                        ),
                        items: [
                          const DropdownMenuItem(
                            value: noRef,
                            child: Text('不设置'),
                          ),
                          for (final a in assets)
                            DropdownMenuItem(value: a.id, child: Text(a.name)),
                        ],
                        onChanged: busy
                            ? null
                            : (v) => setState(
                                () => repayAssetId = v == noRef ? null : v,
                              ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: currency ?? '',
                      decoration: const InputDecoration(labelText: '币种'),
                      items: [
                        const DropdownMenuItem(
                          value: '',
                          child: Text('本位币（人民币）'),
                        ),
                        for (final c in currencies)
                          if (c.code != 'CNY')
                            DropdownMenuItem(
                              value: c.code,
                              child: Text('${c.name}（${c.code}）'),
                            ),
                      ],
                      onChanged: busy
                          ? null
                          : (v) => setState(
                              () => currency = (v == null || v.isEmpty)
                                  ? null
                                  : v,
                            ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: remark,
                      enabled: !busy,
                      decoration: const InputDecoration(labelText: '备注（可选）'),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('计入总资产'),
                      value: counted,
                      onChanged: busy
                          ? null
                          : (v) => setState(() => counted = v),
                    ),
                    if (error != null)
                      Text(
                        error!,
                        key: const Key('asset-error'),
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                  ],
                ),
              ),
            ),
    );
  }
}
