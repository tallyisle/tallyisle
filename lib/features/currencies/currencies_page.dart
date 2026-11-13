import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/failure.dart';
import '../../data/catalog/currency_service.dart';
import '../../data/catalog/exchange_rate_provider.dart';
import '../../data/db/database.dart';
import '../../domain/rules/asset_overview.dart' show normalizeCurrency;
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
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _CurrencyDialog(existing: existing, used: used),
    );
    if (saved == true) {
      _completedGeneration++;
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

class _CurrencyDialog extends ConsumerStatefulWidget {
  const _CurrencyDialog({this.existing, required this.used});
  final Currency? existing;
  final Set<String> used;
  @override
  ConsumerState<_CurrencyDialog> createState() => _CurrencyDialogState();
}

class _CurrencyDialogState extends ConsumerState<_CurrencyDialog> {
  final _ids = CommandIds();
  int _cmdGen = 0;
  int _autoFetchRequestId = 0;

  late final _searchController = TextEditingController();
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

  String _searchQuery = '';
  FetchedExchangeRates? _cachedRates;
  Future<FetchedExchangeRates>? _inFlightFetch;
  bool _fetching = false;
  bool _saving = false;
  bool _nameManuallyEdited = false;
  bool _symbolManuallyEdited = false;
  bool _priceManuallyEdited = false;
  String? _fetchedForCode;
  String? _fetchedRateToAnchor;
  String? _fetchedDisplayPrice;
  String? _fetchedSourceLabel;
  String? _statusHelper;
  String? error;

  @override
  void dispose() {
    _searchController.dispose();
    code.dispose();
    name.dispose();
    symbol.dispose();
    price.dispose();
    super.dispose();
  }

  Future<FetchedExchangeRates> _ensureRatesFetched({
    required bool enableIfDisabled,
    bool forceRefresh = false,
  }) {
    if (!forceRefresh && _cachedRates != null) {
      return Future<FetchedExchangeRates>.value(_cachedRates!);
    }
    if (!forceRefresh && _inFlightFetch != null) {
      return _inFlightFetch!;
    }

    Future<FetchedExchangeRates> doFetch() async {
      if (mounted) {
        setState(() => _fetching = true);
      }
      try {
        final service = await ref.read(currencyServiceProvider.future);
        var settings = await service.getOnlineRateSettings();
        if (!settings.enabled) {
          if (!enableIfDisabled) {
            throw const Failure(
              FailureCode.unsupportedCapability,
              offlineExchangeRateCapabilityReason,
            );
          }
          settings = await service.saveOnlineRateSettings(
            commandId: _ids.forPayload([
              'dialog-enable-online-rates',
              _cmdGen++,
              settings.toJson(),
            ]),
            settings: settings.copyWith(enabled: true),
          );
          if (mounted) {
            ref.invalidate(onlineRateSettingsProvider);
            ref.invalidate(exchangeRateProviderInstanceProvider);
          }
        }
        final provider = HttpExchangeRateProvider(
          settings: settings,
          httpClientFactory: ref.read(onlineRateHttpClientFactoryProvider),
          nowMs: service.db.nowMs,
        );
        final fetched = await service.fetchLiveExchangeRates(
          provider: provider,
        );
        _cachedRates = fetched;
        if (mounted) {
          ref.invalidate(onlineRateSettingsProvider);
        }
        return fetched;
      } finally {
        _inFlightFetch = null;
        if (mounted) {
          setState(() => _fetching = false);
        }
      }
    }

    final future = doFetch();
    _inFlightFetch = future;
    return future;
  }

  Future<({String rateToAnchor, String displayPrice, String sourceLabel})?>
  _fetchAndApplyForCode(
    String targetCode, {
    required bool enableIfDisabled,
    required bool isManualTrigger,
    bool forceRefresh = false,
    required int requestId,
  }) async {
    try {
      final fetched = await _ensureRatesFetched(
        enableIfDisabled: enableIfDisabled,
        forceRefresh: forceRefresh,
      );
      if (!mounted) return null;
      if (!isManualTrigger &&
          (requestId != _autoFetchRequestId ||
              _priceManuallyEdited ||
              normalizeCurrency(code.text) != targetCode)) {
        return null;
      }
      final hit = CurrencyService.lookupFetchedRate(fetched, targetCode);
      if (hit == null) {
        final msg = '未查询到 $targetCode 的在线汇率，请手动填写汇率';
        setState(() {
          if (isManualTrigger) {
            error = msg;
          } else {
            _statusHelper = msg;
          }
        });
        return null;
      }
      setState(() {
        price.text = hit.displayPrice;
        _priceManuallyEdited = false;
        _fetchedForCode = targetCode;
        _fetchedRateToAnchor = hit.rateToAnchor;
        _fetchedDisplayPrice = hit.displayPrice;
        _fetchedSourceLabel = hit.sourceLabel;
        error = null;
        _statusHelper = null;
      });
      return hit;
    } catch (e) {
      if (!mounted) return null;
      if (!isManualTrigger &&
          (requestId != _autoFetchRequestId ||
              _priceManuallyEdited ||
              normalizeCurrency(code.text) != targetCode)) {
        return null;
      }
      final msg = safeMessage(e);
      setState(() {
        if (isManualTrigger) {
          error = msg;
        } else {
          _statusHelper = '$msg，可手动填写汇率';
        }
      });
      return null;
    }
  }

  Future<void> _autoFetchIfEnabled(String targetCode) async {
    final reqId = ++_autoFetchRequestId;
    try {
      final service = await ref.read(currencyServiceProvider.future);
      if (!mounted || reqId != _autoFetchRequestId) return;
      final settings = await service.getOnlineRateSettings();
      if (!mounted || reqId != _autoFetchRequestId) return;
      if (!settings.enabled) return;
      if (_priceManuallyEdited || normalizeCurrency(code.text) != targetCode) {
        return;
      }
      await _fetchAndApplyForCode(
        targetCode,
        enableIfDisabled: false,
        isManualTrigger: false,
        requestId: reqId,
      );
    } catch (_) {
      // Silent background guard; user can always type rate manually.
    }
  }

  void _selectWorldCurrency(WorldCurrencySpec spec) {
    final targetCode = spec.code;
    setState(() {
      code.text = targetCode;
      name.text = spec.name;
      symbol.text = spec.symbol;
      _nameManuallyEdited = false;
      _symbolManuallyEdited = false;
      error = null;
      _statusHelper = null;
      _priceManuallyEdited = false;
      _fetchedForCode = null;
      _fetchedRateToAnchor = null;
      _fetchedDisplayPrice = null;
      _fetchedSourceLabel = null;
      if (_cachedRates != null) {
        final hit = CurrencyService.lookupFetchedRate(
          _cachedRates!,
          targetCode,
        );
        if (hit != null) {
          price.text = hit.displayPrice;
          _fetchedForCode = targetCode;
          _fetchedRateToAnchor = hit.rateToAnchor;
          _fetchedDisplayPrice = hit.displayPrice;
          _fetchedSourceLabel = hit.sourceLabel;
        } else {
          price.text = '';
          _statusHelper = '未查询到 $targetCode 的在线汇率，请手动填写汇率';
        }
      } else {
        price.text = '';
      }
    });
    if (_cachedRates == null) {
      unawaited(_autoFetchIfEnabled(targetCode));
    }
  }

  void _pickPreset(String? value) {
    final spec = findWorldCurrency(value);
    if (spec != null) {
      _selectWorldCurrency(spec);
      return;
    }
    final p = presetCurrencies.where((e) => e.$1 == value).firstOrNull;
    if (p == null) return;
    _selectWorldCurrency(
      WorldCurrencySpec(code: p.$1, name: p.$2, symbol: p.$3),
    );
  }

  void _onCodeChanged(String raw) {
    final c = normalizeCurrency(raw);
    final spec = widget.existing == null ? findWorldCurrency(c) : null;
    setState(() {
      error = null;
      _statusHelper = null;
      if (widget.existing == null) {
        if (!_nameManuallyEdited) {
          name.text = spec?.name ?? '';
        }
        if (!_symbolManuallyEdited) {
          symbol.text = spec?.symbol ?? '';
        }
      }
      if (c != _fetchedForCode) {
        if (!_priceManuallyEdited && widget.existing == null) {
          price.text = '';
        }
        _fetchedForCode = null;
        _fetchedRateToAnchor = null;
        _fetchedDisplayPrice = null;
        _fetchedSourceLabel = null;
      }
      if (!_priceManuallyEdited &&
          c != null &&
          c != baseCurrency &&
          RegExp(r'^[A-Z]{3,8}$').hasMatch(c) &&
          _cachedRates != null) {
        final hit = CurrencyService.lookupFetchedRate(_cachedRates!, c);
        if (hit != null) {
          price.text = hit.displayPrice;
          _fetchedForCode = c;
          _fetchedRateToAnchor = hit.rateToAnchor;
          _fetchedDisplayPrice = hit.displayPrice;
          _fetchedSourceLabel = hit.sourceLabel;
        } else {
          _statusHelper = '未查询到 $c 的在线汇率，请手动填写汇率';
        }
      }
    });
    if (!_priceManuallyEdited &&
        _cachedRates == null &&
        c != null &&
        c != baseCurrency &&
        RegExp(r'^[A-Z]{3,8}$').hasMatch(c)) {
      unawaited(_autoFetchIfEnabled(c));
    }
  }

  void _onPriceChanged(String raw) {
    final trimmed = raw.trim();
    setState(() {
      error = null;
      if (trimmed.isEmpty) {
        _priceManuallyEdited = false;
        _fetchedForCode = null;
        _fetchedRateToAnchor = null;
        _fetchedDisplayPrice = null;
        _fetchedSourceLabel = null;
      } else if (trimmed != _fetchedDisplayPrice) {
        _priceManuallyEdited = true;
      }
    });
  }

  void _autoFillPresetMetadataIfNeeded(String? normalizedCode) {
    if (normalizedCode == null) return;
    final spec = findWorldCurrency(normalizedCode);
    if (spec != null) {
      if (name.text.trim().isEmpty) {
        name.text = spec.name;
      }
      if (symbol.text.trim().isEmpty) {
        symbol.text = spec.symbol;
      }
      return;
    }
    if (name.text.trim().isNotEmpty) return;
    final preset = presetCurrencies
        .where((p) => p.$1 == normalizedCode)
        .firstOrNull;
    if (preset == null) return;
    name.text = preset.$2;
    if (symbol.text.trim().isEmpty) {
      symbol.text = preset.$3;
    }
  }

  Future<void> _onFetchOnlinePressed() async {
    if (_fetching || _saving) return;
    final c = normalizeCurrency(code.text);
    if (c == null || !RegExp(r'^[A-Z]{3,8}$').hasMatch(c)) {
      setState(() => error = '请先选择常用币种或输入 3–8 位币种代码');
      return;
    }
    if (c == baseCurrency) {
      setState(() => error = '人民币是本位币，汇率固定为 1');
      return;
    }
    setState(() {
      _autoFillPresetMetadataIfNeeded(c);
      error = null;
      _statusHelper = null;
      _priceManuallyEdited = false;
    });

    final cachedHit = _cachedRates == null
        ? null
        : CurrencyService.lookupFetchedRate(_cachedRates!, c);
    final forceRefresh =
        cachedHit != null && price.text.trim() == cachedHit.displayPrice;

    await _fetchAndApplyForCode(
      c,
      enableIfDisabled: true,
      isManualTrigger: true,
      forceRefresh: forceRefresh,
      requestId: ++_autoFetchRequestId,
    );
  }

  Future<void> _persistAndClose({
    required String code,
    required String name,
    required String symbol,
    required String price,
    String? rateToAnchorOverride,
    String? onlineSyncSource,
  }) async {
    setState(() {
      _saving = true;
      error = null;
    });
    try {
      final service = await ref.read(currencyServiceProvider.future);
      await service.saveCurrency(
        commandId: _ids.forPayload([
          'save-currency-dialog',
          _cmdGen,
          code,
          name,
          symbol,
          price,
          rateToAnchorOverride,
          onlineSyncSource,
        ]),
        code: code,
        name: name,
        symbol: symbol,
        price: price,
        rateToAnchorOverride: rateToAnchorOverride,
        onlineSyncSource: onlineSyncSource,
      );
      _cmdGen++;
      if (!mounted) return;
      if (onlineSyncSource != null && onlineSyncSource.isNotEmpty) {
        ref.invalidate(onlineRateSettingsProvider);
      }
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        error = safeMessage(e);
      });
    }
  }

  Future<void> _onSave() async {
    if (_saving) return;
    final normalizedCode = normalizeCurrency(code.text);
    setState(() {
      _autoFillPresetMetadataIfNeeded(normalizedCode);
    });
    if (normalizedCode == null ||
        !RegExp(r'^[A-Z]{3,8}$').hasMatch(normalizedCode)) {
      setState(() => error = '币种代码须为 3–8 位英文字母');
      return;
    }
    if (normalizedCode == baseCurrency) {
      setState(() => error = '人民币是本位币，汇率固定为 1');
      return;
    }
    final trimmedName = name.text.trim();
    if (trimmedName.isEmpty || trimmedName.length > 30) {
      setState(() => error = '币种名称须为 1–30 字');
      return;
    }

    final trimmedPrice = price.text.trim();
    if (trimmedPrice.isNotEmpty) {
      try {
        rateToAnchorFromPrice(trimmedPrice);
      } catch (e) {
        setState(() => error = safeMessage(e));
        return;
      }
      final useFetchedExact =
          !_priceManuallyEdited &&
          _fetchedForCode == normalizedCode &&
          _fetchedDisplayPrice == trimmedPrice &&
          _fetchedRateToAnchor != null;
      await _persistAndClose(
        code: normalizedCode,
        name: trimmedName,
        symbol: symbol.text.trim(),
        price: trimmedPrice,
        rateToAnchorOverride: useFetchedExact ? _fetchedRateToAnchor : null,
        onlineSyncSource: useFetchedExact ? _fetchedSourceLabel : null,
      );
      return;
    }

    // Price was left empty -> auto-fetch if online rates enabled, or prompt 1-tap opt-in!
    final service = await ref.read(currencyServiceProvider.future);
    if (!mounted) return;
    final settings = await service.getOnlineRateSettings();
    if (!mounted) return;

    if (settings.enabled) {
      final hit = await _fetchAndApplyForCode(
        normalizedCode,
        enableIfDisabled: false,
        isManualTrigger: true,
        requestId: ++_autoFetchRequestId,
      );
      if (!mounted || hit == null) return;
      await _persistAndClose(
        code: normalizedCode,
        name: trimmedName,
        symbol: symbol.text.trim(),
        price: hit.displayPrice,
        rateToAnchorOverride: hit.rateToAnchor,
        onlineSyncSource: hit.sourceLabel,
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('自动联网获取汇率？'),
        content: Text('尚未填写汇率，是否开启联网汇率并自动获取 $normalizedCode 的最新人民币汇率后保存？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('手动填写'),
          ),
          FilledButton(
            key: const Key('confirm-online-fetch-save'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('联网获取并保存'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;

    final hit = await _fetchAndApplyForCode(
      normalizedCode,
      enableIfDisabled: true,
      isManualTrigger: true,
      requestId: ++_autoFetchRequestId,
    );
    if (!mounted || hit == null) return;
    await _persistAndClose(
      code: normalizedCode,
      name: trimmedName,
      symbol: symbol.text.trim(),
      price: hit.displayPrice,
      rateToAnchorOverride: hit.rateToAnchor,
      onlineSyncSource: hit.sourceLabel,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final editing = widget.existing != null;
    final allUnused = editing
        ? const <WorldCurrencySpec>[]
        : searchWorldCurrencies('', excludeCodes: widget.used);
    final isSearching = _searchQuery.trim().isNotEmpty;
    final List<WorldCurrencySpec> chipItems;
    if (editing) {
      chipItems = const <WorldCurrencySpec>[];
    } else if (isSearching) {
      chipItems = searchWorldCurrencies(
        _searchQuery,
        excludeCodes: widget.used,
      );
    } else {
      final popularUnused = allUnused.where((c) => c.popular).toList();
      chipItems = popularUnused.isNotEmpty
          ? popularUnused
          : allUnused.take(16).toList();
    }
    final selectedCode = normalizeCurrency(code.text);
    final displayCode = selectedCode ?? '外币';
    final helperText = _fetching
        ? '正在联网获取最新汇率…'
        : (!_priceManuallyEdited && _fetchedSourceLabel != null)
        ? '实时汇率来源：$_fetchedSourceLabel'
        : _statusHelper;

    return AlertDialog(
      title: Text(editing ? '修改汇率' : '添加币种'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!editing) ...[
                TextField(
                  key: const Key('currency-search-input'),
                  controller: _searchController,
                  enabled: !_saving,
                  onChanged: (v) => setState(() => _searchQuery = v),
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 18),
                    prefixIconConstraints: const BoxConstraints(
                      minWidth: 34,
                      minHeight: 34,
                    ),
                    suffixIcon: _searchQuery.isEmpty
                        ? null
                        : IconButton(
                            key: const Key('currency-search-clear'),
                            tooltip: '清空搜索',
                            icon: const Icon(Icons.close, size: 16),
                            visualDensity: VisualDensity.compact,
                            onPressed: _saving
                                ? null
                                : () => setState(() {
                                    _searchController.clear();
                                    _searchQuery = '';
                                  }),
                          ),
                    hintText: '搜索全球 150+ 币种（如：土耳其 / 里拉 / TRY）',
                  ),
                ),
                const SizedBox(height: 8),
                if (chipItems.isEmpty && isSearching)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      '未找到匹配的内置币种，可直接在下方填写代码与名称',
                      key: const Key('currency-search-empty'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                else if (chipItems.isNotEmpty) ...[
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: isSearching ? 120 : 84,
                    ),
                    child: SingleChildScrollView(
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final p in chipItems)
                            ChoiceChip(
                              key: Key('currency-preset-chip-${p.code}'),
                              label: Text('${p.name} ${p.code}'),
                              selected: selectedCode == p.code,
                              showCheckmark: false,
                              visualDensity: VisualDensity.compact,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                              ),
                              labelStyle: theme.textTheme.labelSmall,
                              onSelected: _saving
                                  ? null
                                  : (_) => _selectWorldCurrency(p),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                ],
                if (allUnused.isNotEmpty)
                  DropdownButtonFormField<String>(
                    key: const Key('currency-preset'),
                    isExpanded: true,
                    menuMaxHeight: 320,
                    decoration: const InputDecoration(
                      labelText: '更多常用币种',
                      isDense: true,
                    ),
                    items: [
                      for (final p in allUnused)
                        DropdownMenuItem(
                          value: p.code,
                          child: Text(
                            '${p.name}（${p.code}）',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: _saving ? null : _pickPreset,
                  ),
              ],
              TextField(
                key: const Key('currency-code'),
                controller: code,
                enabled: !editing && !_saving,
                textCapitalization: TextCapitalization.characters,
                onChanged: _onCodeChanged,
                decoration: const InputDecoration(
                  labelText: '代码（如 USD / TRY）',
                  isDense: true,
                ),
              ),
              TextField(
                key: const Key('currency-name'),
                controller: name,
                enabled: !_saving,
                onChanged: (v) {
                  _nameManuallyEdited = v.trim().isNotEmpty;
                  if (error != null) setState(() => error = null);
                },
                decoration: const InputDecoration(
                  labelText: '名称',
                  isDense: true,
                ),
              ),
              TextField(
                key: const Key('currency-symbol'),
                controller: symbol,
                enabled: !_saving,
                onChanged: (v) {
                  _symbolManuallyEdited = v.trim().isNotEmpty;
                },
                decoration: const InputDecoration(
                  labelText: '符号（可选）',
                  isDense: true,
                ),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('currency-price'),
                      controller: price,
                      enabled: !_saving,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      onChanged: _onPriceChanged,
                      decoration: InputDecoration(
                        isDense: true,
                        labelText: editing ? '汇率' : '汇率（留空或点右侧可自动联网获取）',
                        prefixText: '1 $displayCode = ',
                        suffixText: 'CNY',
                        helperText: helperText,
                        helperMaxLines: 2,
                        errorText: error,
                        errorMaxLines: 2,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: OutlinedButton.icon(
                      key: const Key('currency-fetch-online-btn'),
                      onPressed: (_fetching || _saving)
                          ? null
                          : _onFetchOnlinePressed,
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        visualDensity: VisualDensity.compact,
                      ),
                      icon: _fetching
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.cloud_download_outlined, size: 16),
                      label: const Text('联网获取'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('currency-save'),
          onPressed: _saving ? null : _onSave,
          child: Text(_saving ? '保存中…' : '保存'),
        ),
      ],
    );
  }
}
