import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/template_card_rules.dart';
import '../common/common.dart';
import 'bank_card_editor_page.dart';
import 'bank_card_providers.dart';

/// Bank Card Memo Folder page (`F-023`, original `/bkp/BCBAct`).
class BankCardsPage extends ConsumerStatefulWidget {
  const BankCardsPage({super.key});

  @override
  ConsumerState<BankCardsPage> createState() => _BankCardsPageState();
}

class _BankCardsPageState extends ConsumerState<BankCardsPage> {
  final CommandIds _deleteIds = CommandIds();
  bool _busy = false;

  Future<void> _openCreate() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<int>(builder: (_) => const BankCardEditorPage()));
  }

  Future<void> _openEdit(BankCard card) async {
    await Navigator.of(context).push(
      MaterialPageRoute<int>(
        builder: (_) => BankCardEditorPage(cardId: card.id),
      ),
    );
  }

  Future<void> _copyCardNumber(BankCard card) async {
    await Clipboard.setData(ClipboardData(text: card.cardNo));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(const SnackBar(content: Text('已复制卡号')));
  }

  Future<void> _copyFullInfo(BankCard card, String? linkedAssetName) async {
    final fullText = formatBankCardFullInfo(
      cardName: card.cardName,
      cardType: card.cardType,
      cardNo: card.cardNo,
      cardOwner: card.cardOwner,
      remark: card.remark,
      linkedAssetName: linkedAssetName,
    );
    await Clipboard.setData(ClipboardData(text: fullText));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(const SnackBar(content: Text('已复制完整卡片信息')));
  }

  Future<void> _deleteCard(BankCard card) async {
    final ok = await confirm(
      context,
      title: '确认删除银行卡备忘？',
      message: '删除“${card.cardName}”不会影响已关联的资金账户与账单。',
      ok: '删除',
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      final svc = await ref.read(bankCardServiceProvider.future);
      await svc.deleteBankCard(
        commandId: _deleteIds.forPayload(<Object?>['del-card', card.id]),
        cardId: card.id,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(content: Text('已删除银行卡备忘')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(safeMessage(e))));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final filterType = ref.watch(bankCardFilterProvider);
    final maskState = ref.watch(bankCardMaskProvider);
    final cardsAsync = ref.watch(bankCardsProvider(filterType));
    final assets = ref.watch(assetsProvider).value ?? const <Asset>[];
    final assetMap = <int, Asset>{for (final a in assets) a.id: a};

    return Scaffold(
      key: const Key('bank_cards_page'),
      appBar: AppBar(
        title: const Text('银行卡备忘'),
        actions: [
          IconButton(
            key: const Key('toggle_global_card_mask'),
            tooltip: maskState.maskByDefault ? '显示全部卡号' : '隐藏全部卡号',
            icon: Icon(
              maskState.maskByDefault
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
            ),
            onPressed: () =>
                ref.read(bankCardMaskProvider.notifier).toggleGlobal(),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('add_bank_card_fab'),
        onPressed: _openCreate,
        icon: const Icon(Icons.add_card),
        label: const Text('添加银行卡'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Wrap(
                  spacing: 8,
                  children: [
                    for (final (value, label) in const <(int?, String)>[
                      (null, '全部'),
                      (BankCardType.debit, '储蓄卡'),
                      (BankCardType.credit, '信用卡'),
                    ])
                      ChoiceChip(
                        key: Key('card_filter_${value ?? "all"}'),
                        label: Text(label),
                        selected: filterType == value,
                        onSelected: (_) => ref
                            .read(bankCardFilterProvider.notifier)
                            .select(value),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: asyncBody(cardsAsync, (rows) {
                  if (rows.isEmpty) {
                    return Center(
                      key: const Key('bank_cards_empty_state'),
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          '暂无银行卡备忘，点击右下角“添加银行卡”保存常用卡号',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                    );
                  }
                  return ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 88),
                    itemCount: rows.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final card = rows[index];
                      final linkedAsset = card.cardAssetId == noRef
                          ? null
                          : assetMap[card.cardAssetId];
                      final masked = maskState.isCardMasked(card.id);
                      return _BankCardTile(
                        card: card,
                        masked: masked,
                        linkedAssetName: linkedAsset?.name,
                        busy: _busy,
                        onToggleMask: () => ref
                            .read(bankCardMaskProvider.notifier)
                            .toggleCard(card.id),
                        onCopyNumber: () => _copyCardNumber(card),
                        onCopyFull: () =>
                            _copyFullInfo(card, linkedAsset?.name),
                        onEdit: () => _openEdit(card),
                        onDelete: () => _deleteCard(card),
                      );
                    },
                  );
                }),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BankCardTile extends StatelessWidget {
  const _BankCardTile({
    required this.card,
    required this.masked,
    required this.linkedAssetName,
    required this.busy,
    required this.onToggleMask,
    required this.onCopyNumber,
    required this.onCopyFull,
    required this.onEdit,
    required this.onDelete,
  });

  final BankCard card;
  final bool masked;
  final String? linkedAssetName;
  final bool busy;
  final VoidCallback onToggleMask;
  final VoidCallback onCopyNumber;
  final VoidCallback onCopyFull;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final tint = parseCardColorOrNull(card.cardColor);
    final luhn = inspectCardLuhn(card.cardNo);
    final displayNumber = masked
        ? formatCardNumberMasked(card.cardNo)
        : formatCardNumberGrouped(card.cardNo);

    return Card(
      key: Key('bank_card_item_${card.id}'),
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: tint == null
            ? null
            : BoxDecoration(
                border: Border(left: BorderSide(color: tint, width: 6)),
              ),
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    card.cardName,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Chip(
                  visualDensity: VisualDensity.compact,
                  label: Text(BankCardType.labelOf(card.cardType)),
                ),
                const SizedBox(width: 6),
                Container(
                  key: Key('card_luhn_badge_${card.id}'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: luhn.passesLuhn
                        ? Colors.green.withValues(alpha: 0.14)
                        : Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    luhn.passesLuhn ? 'Luhn 校验通过' : '非标准校验号',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: SelectableText(
                    displayNumber,
                    key: Key('card_no_display_${card.id}'),
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      letterSpacing: 1.2,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  key: Key('toggle_card_mask_${card.id}'),
                  tooltip: masked ? '显示完整卡号' : '隐藏卡号',
                  icon: Icon(
                    masked
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  onPressed: onToggleMask,
                ),
              ],
            ),
            if (card.cardOwner.trim().isNotEmpty ||
                linkedAssetName != null ||
                card.remark.trim().isNotEmpty) ...[
              const SizedBox(height: 4),
              Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  if (card.cardOwner.trim().isNotEmpty)
                    Text(
                      '持卡人：${card.cardOwner.trim()}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  if (linkedAssetName != null)
                    Text(
                      '关联账户：$linkedAssetName',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  if (card.remark.trim().isNotEmpty)
                    Text(
                      '备注：${card.remark.trim()}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
              ),
            ],
            const Divider(height: 16),
            Wrap(
              spacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton.icon(
                  key: Key('copy_card_no_${card.id}'),
                  onPressed: onCopyNumber,
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('复制卡号'),
                ),
                TextButton.icon(
                  key: Key('copy_card_full_${card.id}'),
                  onPressed: onCopyFull,
                  icon: const Icon(Icons.assignment_outlined, size: 16),
                  label: const Text('复制完整信息'),
                ),
                IconButton(
                  key: Key('edit_bank_card_${card.id}'),
                  tooltip: '编辑',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: busy ? null : onEdit,
                ),
                IconButton(
                  key: Key('delete_bank_card_${card.id}'),
                  tooltip: '删除',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: busy ? null : onDelete,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
