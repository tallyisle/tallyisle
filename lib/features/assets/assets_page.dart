import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/failure.dart';
import '../../data/db/database.dart';
import '../../domain/model/codes.dart';
import '../common/common.dart';
import '../records/record_editor_page.dart';

/// Account list. The full asset overview (net worth rules, credit, debt) is
/// M2 (docs/modules/asset-overview.md); this page sums ordinary accounts only.
class AssetsPage extends ConsumerWidget {
  const AssetsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final assets = ref.watch(assetsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('资产')),
      body: asyncBody(assets, (list) {
        final visible = list
            .where((a) => a.status != AssetStatus.hidden)
            .toList();
        if (visible.isEmpty) {
          return const Center(child: Text('还没有账户，点右下角添加'));
        }
        final total = visible
            .where((a) => a.type == AssetType.normal && a.isEffectiveAsset == 1)
            .fold(BigInt.zero, (s, a) => s + a.balanceMinor);
        return ListView(
          children: [
            ListTile(
              title: const Text('账户合计'),
              trailing: Text(
                formatMinor(total),
                key: const Key('assets-total'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            const Divider(),
            for (final a in visible)
              ListTile(
                key: Key('asset-${a.name}'),
                leading: const Icon(Icons.account_balance_wallet_outlined),
                title: Text(a.name),
                subtitle: a.remark == null || a.remark!.isEmpty
                    ? null
                    : Text(a.remark!),
                trailing: Text(formatMinor(a.balanceMinor)),
                onTap: () => _adjust(context, ref, a),
              ),
            const SizedBox(height: 96),
          ],
        );
      }),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('add-asset'),
        heroTag: 'fab-assets',
        onPressed: () => context.push('/assets/new'),
        icon: const Icon(Icons.add),
        label: const Text('添加账户'),
      ),
    );
  }

  Future<void> _adjust(BuildContext context, WidgetRef ref, Asset asset) async {
    final controller = TextEditingController(
      text: formatMinor(asset.balanceMinor),
    );
    final ids = CommandIds();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('调整“${asset.name}”余额'),
        content: TextField(
          key: const Key('adjust-amount'),
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(
            decimal: true,
            signed: true,
          ),
          decoration: const InputDecoration(
            helperText: '会生成一条“余额变更”记录',
            prefixText: '¥ ',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null) return;
    try {
      final text = value.trim();
      final negative = text.startsWith('-');
      var target = parseAmount(negative ? text.substring(1) : text);
      if (negative) target = -target;
      final service = await ref.read(ledgerServiceProvider.future);
      final bookId = await ref.read(currentBookIdProvider.future);
      await service.adjustBalance(
        commandId: ids.forPayload([asset.id, target.toJson()]),
        assetId: asset.id,
        target: target,
        bookId: bookId,
      );
    } on Failure catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }
}

class AssetEditorPage extends ConsumerStatefulWidget {
  const AssetEditorPage({super.key});
  @override
  ConsumerState<AssetEditorPage> createState() => _AssetEditorPageState();
}

class _AssetEditorPageState extends ConsumerState<AssetEditorPage> {
  final name = TextEditingController();
  final balance = TextEditingController();
  final remark = TextEditingController();
  final ids = CommandIds();
  bool counted = true, busy = false;
  String? error;

  @override
  void dispose() {
    name.dispose();
    balance.dispose();
    remark.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final initial = parseAmount(balance.text);
      final service = await ref.read(ledgerServiceProvider.future);
      await service.createAsset(
        commandId: ids.forPayload([
          name.text,
          initial.toJson(),
          remark.text,
          counted,
        ]),
        name: name.text,
        initial: initial,
        remark: remark.text.trim().isEmpty ? null : remark.text.trim(),
        countedInNetWorth: counted,
      );
      if (mounted) context.pop();
    } catch (e) {
      if (mounted) setState(() => error = safeMessage(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('添加账户')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          key: const Key('asset-name'),
          controller: name,
          enabled: !busy,
          decoration: const InputDecoration(
            labelText: '账户名称',
            hintText: '如：现金、银行卡',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('asset-balance'),
          controller: balance,
          enabled: !busy,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: amountInputFormatters,
          decoration: const InputDecoration(
            labelText: '当前余额',
            prefixText: '¥ ',
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
          onChanged: busy ? null : (v) => setState(() => counted = v),
        ),
        if (error != null)
          Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        const SizedBox(height: 8),
        FilledButton(
          key: const Key('asset-save'),
          onPressed: busy ? null : _save,
          child: Text(busy ? '保存中…' : '保存'),
        ),
      ],
    ),
  );
}
