import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../domain/rules/currency_rates.dart';
import '../common/common.dart';

/// Currencies and manual exchange rates (`/currencies`).
class CurrenciesPage extends ConsumerStatefulWidget {
  const CurrenciesPage({super.key});
  @override
  ConsumerState<CurrenciesPage> createState() => _CurrenciesPageState();
}

class _CurrenciesPageState extends ConsumerState<CurrenciesPage> {
  final ids = CommandIds();

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
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
        commandId: ids.forPayload(['save', code, name, symbol, price]),
        code: code,
        name: name,
        symbol: symbol,
        price: price,
      );
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
        commandId: ids.forPayload(['delete', c.code]),
        code: c.code,
      );
    } catch (e) {
      _toast(safeMessage(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final currencies = ref.watch(currenciesProvider);
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
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('汇率由你手动维护（帐屿不联网获取汇率）。外币账户与外币账单都按这里的汇率折算成人民币统计。'),
            ),
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
