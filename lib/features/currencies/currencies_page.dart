import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../domain/rules/currency_rates.dart';
import '../../domain/rules/online_rate_rules.dart';
import '../common/common.dart';
import 'currency_rate_providers.dart';

/// Currencies, manual exchange rates, and optional privacy-first online rate
/// sync (`/currencies`, `F-029`, `ADR-017`).
class CurrenciesPage extends ConsumerStatefulWidget {
  const CurrenciesPage({super.key});
  @override
  ConsumerState<CurrenciesPage> createState() => _CurrenciesPageState();
}

class _CurrenciesPageState extends ConsumerState<CurrenciesPage> {
  final ids = CommandIds();
  int _completedGeneration = 0;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_checkAutoSyncOnOpen());
    });
  }

  Future<void> _checkAutoSyncOnOpen() async {
    if (!mounted) return;
    try {
      final service = await ref.read(currencyServiceProvider.future);
      if (!mounted) return;
      final settings = await service.getOnlineRateSettings();
      if (!mounted || !settings.shouldAutoSync(nowMs: service.db.nowMs())) {
        return;
      }
      final provider = await ref.read(
        exchangeRateProviderInstanceProvider.future,
      );
      if (!mounted) return;
      await service.runAutoSyncIfNeeded(provider: provider);
    } catch (_) {
      // Silent background auto-sync never interrupts the user on transient errors.
    }
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _saveOnlineSettings(OnlineRateSettings next) async {
    try {
      final service = await ref.read(currencyServiceProvider.future);
      await service.saveOnlineRateSettings(
        commandId: ids.forPayload([
          'online-settings',
          _completedGeneration,
          next.toJson(),
        ]),
        settings: next,
      );
      _completedGeneration++;
      ref.invalidate(onlineRateSettingsProvider);
      ref.invalidate(exchangeRateProviderInstanceProvider);
    } catch (e) {
      _toast(safeMessage(e));
    }
  }

  Future<void> _syncNow() async {
    if (_syncing) return;
    setState(() => _syncing = true);
    try {
      final service = await ref.read(currencyServiceProvider.future);
      final provider = await ref.read(
        exchangeRateProviderInstanceProvider.future,
      );
      final result = await service.syncOnlineRates(
        commandId: ids.forPayload(['online-sync-now', _completedGeneration]),
        provider: provider,
      );
      _completedGeneration++;
      ref.invalidate(onlineRateSettingsProvider);
      if (result.updatedCount == 0 && result.skippedCodes.isEmpty) {
        _toast('当前暂无已添加的外币币种，请先添加外币后再同步。');
      } else if (result.skippedCodes.isEmpty) {
        _toast('已更新 ${result.updatedCount} 个外币汇率（来源：${result.sourceLabel}）');
      } else {
        _toast(
          '已更新 ${result.updatedCount} 个币种，'
          '${result.skippedCodes.length} 个自定义币种保留手动汇率',
        );
      }
    } catch (e) {
      _toast(safeMessage(e));
    } finally {
      if (mounted) {
        setState(() => _syncing = false);
      }
    }
  }

  Future<void> _configureCustomSource(OnlineRateSettings current) async {
    final nextUrl = await showDialog<String>(
      context: context,
      builder: (_) =>
          _CustomRateSourceDialog(initialUrl: current.customEndpointUrl),
    );
    if (nextUrl == null) return;
    await _saveOnlineSettings(current.copyWith(customEndpointUrl: nextUrl));
    if (!mounted) return;
    _toast(nextUrl.isEmpty ? '已恢复使用内置公共免密钥多源容灾' : '已保存自定义汇率源');
  }

  Future<void> _edit({Currency? existing, required Set<String> used}) async {
    final result = await showDialog<(String, String, String, String)>(
      context: context,
      builder: (_) => _CurrencyDialog(existing: existing, used: used),
    );
    if (result == null) return;
    final (code, name, symbol, price) = result;
    try {
      final service = await ref.read(currencyServiceProvider.future);
      await service.saveCurrency(
        commandId: ids.forPayload([
          'save',
          _completedGeneration,
          code,
          name,
          symbol,
          price,
        ]),
        code: code,
        name: name,
        symbol: symbol,
        price: price,
      );
      _completedGeneration++;
    } catch (e) {
      _toast(safeMessage(e));
    }
  }

  Future<void> _delete(Currency c) async {
    final ok = await confirm(
      context,
      title: '删除币种 ${c.name}（${c.code}）？',
      message: '只有没有账户或账单使用的币种可以删除。',
      ok: '删除',
    );
    if (!ok) return;
    try {
      final service = await ref.read(currencyServiceProvider.future);
      await service.deleteCurrency(
        commandId: ids.forPayload(['delete', _completedGeneration, c.code]),
        code: c.code,
      );
      _completedGeneration++;
    } catch (e) {
      _toast(safeMessage(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final currencies = ref.watch(currenciesProvider);
    final settings =
        ref.watch(onlineRateSettingsProvider).value ??
        OnlineRateSettings.defaults;

    return Scaffold(
      appBar: AppBar(title: const Text('币种与汇率')),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('add-currency'),
        heroTag: 'fab-currency',
        icon: const Icon(Icons.add),
        label: const Text('添加币种'),
        onPressed: () => _edit(
          used: {
            for (final c in currencies.value ?? const <Currency>[]) c.code,
          },
        ),
      ),
      body: asyncBody(currencies, (list) {
        final sorted = [...list]
          ..sort((a, b) {
            if (a.code == baseCurrency) return -1;
            if (b.code == baseCurrency) return 1;
            return a.code.compareTo(b.code);
          });
        final used = {for (final c in list) c.code};
        return ListView(
          children: [
            _buildOnlineRateCard(context, settings),
            for (final c in sorted)
              ListTile(
                key: Key('currency-${c.code}'),
                leading: CircleAvatar(child: Text(c.symbol.characters.first)),
                title: Text('${c.name}（${c.code}）'),
                subtitle: Text(
                  c.code == baseCurrency
                      ? '本位币'
                      : '1 ${c.code} = ${priceFromRateToAnchor(c.rateToAnchor)} CNY'
                            '${c.rateRefreshTime > 0 ? ' · 更新于 ${formatDate(DateTime.fromMillisecondsSinceEpoch(c.rateRefreshTime))}' : ''}',
                ),
                trailing: c.code == baseCurrency
                    ? null
                    : IconButton(
                        tooltip: '删除',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _delete(c),
                      ),
                onTap: c.code == baseCurrency
                    ? null
                    : () => _edit(existing: c, used: used),
              ),
            const SizedBox(height: 96),
          ],
        );
      }),
    );
  }

  Widget _buildOnlineRateCard(
    BuildContext context,
    OnlineRateSettings settings,
  ) {
    final theme = Theme.of(context);
    final lastSyncText = settings.lastSyncedAtMs > 0
        ? '上次同步：${formatDateTime(DateTime.fromMillisecondsSinceEpoch(settings.lastSyncedAtMs))}'
              '${settings.lastSyncSource.isNotEmpty ? ' · 来源：${settings.lastSyncSource}' : ''}'
        : '上次同步：尚未执行在线同步';
    final sourceSummary = settings.hasCustomEndpoint
        ? '当前汇率源：自定义（${settings.customEndpointUrl}）'
        : '当前汇率源：内置公共免密钥多源容灾';

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile(
            key: const Key('online-rate-enable-switch'),
            title: const Text('联网获取汇率'),
            subtitle: const Text(
              '默认关闭，不联网获取任何数据；开启后支持一键刷新与每 24 小时自动同步。历史已记账单的折算快照不受影响。',
            ),
            value: settings.enabled,
            onChanged: _syncing
                ? null
                : (enabled) =>
                      _saveOnlineSettings(settings.copyWith(enabled: enabled)),
          ),
          if (!settings.enabled)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                '$offlineExchangeRateCapabilityReason · 外币账户与新账单按下方手动汇率折算成人民币统计。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          if (settings.enabled) ...[
            const Divider(height: 1),
            SwitchListTile(
              key: const Key('online-rate-auto-switch'),
              title: const Text('自动同步（每 24 小时）'),
              subtitle: const Text('距上次成功同步满 24 小时后自动静默刷新已添加的外币汇率'),
              value: settings.autoSyncOnLaunch,
              onChanged: _syncing
                  ? null
                  : (autoSync) => _saveOnlineSettings(
                      settings.copyWith(autoSyncOnLaunch: autoSync),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(sourceSummary, style: theme.textTheme.bodySmall),
                  const SizedBox(height: 2),
                  Text(
                    lastSyncText,
                    key: const Key('online-rate-last-sync-status'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    key: const Key('online-rate-sync-now'),
                    onPressed: _syncing ? null : _syncNow,
                    icon: _syncing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.sync, size: 18),
                    label: Text(_syncing ? '同步中…' : '立即同步汇率'),
                  ),
                  OutlinedButton.icon(
                    key: const Key('online-rate-source-btn'),
                    onPressed: _syncing
                        ? null
                        : () => _configureCustomSource(settings),
                    icon: const Icon(Icons.tune, size: 18),
                    label: const Text('自定义汇率源'),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _CustomRateSourceDialog extends StatefulWidget {
  const _CustomRateSourceDialog({required this.initialUrl});
  final String initialUrl;

  @override
  State<_CustomRateSourceDialog> createState() =>
      _CustomRateSourceDialogState();
}

class _CustomRateSourceDialogState extends State<_CustomRateSourceDialog> {
  late final TextEditingController _urlController = TextEditingController(
    text: widget.initialUrl,
  );
  String? _error;

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('自定义汇率源'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '留空则使用内置公共免密钥多源容灾；填写 https:// 或 http:// 地址则优先请求该 CNY 基准 JSON 接口。',
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('online-rate-custom-url-input'),
              controller: _urlController,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: 'JSON 接口地址（留空使用默认公共源）',
                hintText: 'https://open.er-api.com/v6/latest/CNY',
                errorText: _error,
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (_urlController.text.trim().isNotEmpty)
          TextButton(
            key: const Key('online-rate-reset-source'),
            onPressed: () => Navigator.pop(context, ''),
            child: const Text('恢复默认'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('online-rate-save-source'),
          onPressed: () {
            try {
              final validated = validateCustomRateEndpointUrl(
                _urlController.text,
              );
              Navigator.pop(context, validated);
            } catch (e) {
              setState(() => _error = safeMessage(e));
            }
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _CurrencyDialog extends StatefulWidget {
  const _CurrencyDialog({this.existing, required this.used});
  final Currency? existing;
  final Set<String> used;
  @override
  State<_CurrencyDialog> createState() => _CurrencyDialogState();
}

class _CurrencyDialogState extends State<_CurrencyDialog> {
  late final code = TextEditingController(text: widget.existing?.code ?? '');
  late final name = TextEditingController(text: widget.existing?.name ?? '');
  late final symbol = TextEditingController(
    text: widget.existing?.symbol ?? '',
  );
  late final price = TextEditingController(
    text: widget.existing == null
        ? ''
        : priceFromRateToAnchor(widget.existing!.rateToAnchor),
  );
  String? error;

  @override
  void dispose() {
    code.dispose();
    name.dispose();
    symbol.dispose();
    price.dispose();
    super.dispose();
  }

  void _pickPreset(String? value) {
    final p = presetCurrencies.where((e) => e.$1 == value).firstOrNull;
    if (p == null) return;
    setState(() {
      code.text = p.$1;
      name.text = p.$2;
      symbol.text = p.$3;
    });
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null;
    final presets = presetCurrencies
        .where((p) => !widget.used.contains(p.$1))
        .toList();
    return AlertDialog(
      title: Text(editing ? '修改汇率' : '添加币种'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!editing && presets.isNotEmpty)
              DropdownButtonFormField<String>(
                key: const Key('currency-preset'),
                decoration: const InputDecoration(labelText: '常用币种'),
                items: [
                  for (final p in presets)
                    DropdownMenuItem(
                      value: p.$1,
                      child: Text('${p.$2}（${p.$1}）'),
                    ),
                ],
                onChanged: _pickPreset,
              ),
            TextField(
              key: const Key('currency-code'),
              controller: code,
              enabled: !editing,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(labelText: '代码（如 USD）'),
            ),
            TextField(
              key: const Key('currency-name'),
              controller: name,
              decoration: const InputDecoration(labelText: '名称'),
            ),
            TextField(
              controller: symbol,
              decoration: const InputDecoration(labelText: '符号（可选）'),
            ),
            TextField(
              key: const Key('currency-price'),
              controller: price,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: '汇率',
                prefixText: '1 ${code.text.isEmpty ? '外币' : code.text} = ',
                suffixText: 'CNY',
                errorText: error,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('currency-save'),
          onPressed: () {
            try {
              rateToAnchorFromPrice(price.text);
            } catch (e) {
              setState(() => error = safeMessage(e));
              return;
            }
            Navigator.pop(context, (
              code.text.trim().toUpperCase(),
              name.text.trim(),
              symbol.text.trim(),
              price.text.trim(),
            ));
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}
