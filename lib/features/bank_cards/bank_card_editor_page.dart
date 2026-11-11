import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../data/tools/bank_card_service.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/template_card_rules.dart';
import '../common/common.dart';
import 'bank_card_providers.dart';

Color? parseCardColorOrNull(String? hex) {
  if (hex == null) return null;
  final trimmed = hex.trim();
  if (trimmed.isEmpty) return null;
  final digits = trimmed.startsWith('#') ? trimmed.substring(1) : trimmed;
  if (digits.length == 6) {
    final v = int.tryParse('FF$digits', radix: 16);
    return v == null ? null : Color(v);
  }
  if (digits.length == 8) {
    final v = int.tryParse(digits, radix: 16);
    return v == null ? null : Color(v);
  }
  return null;
}

/// Add / edit page for `BankCard` (`F-023`).
class BankCardEditorPage extends ConsumerStatefulWidget {
  const BankCardEditorPage({super.key, this.cardId});

  final int? cardId;

  @override
  ConsumerState<BankCardEditorPage> createState() => _BankCardEditorPageState();
}

class _BankCardEditorPageState extends ConsumerState<BankCardEditorPage> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _noController = TextEditingController();
  final TextEditingController _ownerController = TextEditingController();
  final TextEditingController _remarkController = TextEditingController();
  final CommandIds _ids = CommandIds();

  int _cardType = BankCardType.debit;
  String? _cardColor;
  int _cardAssetId = noRef;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  bool get _editing => widget.cardId != null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      if (_editing) {
        final svc = await ref.read(bankCardServiceProvider.future);
        final card = await svc.getBankCard(widget.cardId!);
        if (card == null) {
          _error = '银行卡记录不存在或已删除';
        } else {
          _cardType = card.cardType;
          _nameController.text = card.cardName;
          _noController.text = formatCardNumberGrouped(card.cardNo);
          _ownerController.text = card.cardOwner;
          _remarkController.text = card.remark;
          _cardColor = card.cardColor;
          _cardAssetId = card.cardAssetId;
        }
      }
    } catch (e) {
      _error = safeMessage(e);
    }
    if (mounted) {
      setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _noController.dispose();
    _ownerController.dispose();
    _remarkController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final draft = BankCardDraft(
        cardType: _cardType,
        cardName: _nameController.text,
        cardNo: _noController.text,
        cardOwner: _ownerController.text,
        remark: _remarkController.text,
        cardColor: _cardColor,
        cardAssetId: _cardAssetId,
      );
      final svc = await ref.read(bankCardServiceProvider.future);
      final savedId = await svc.saveBankCard(
        commandId: _ids.forPayload(<Object?>[widget.cardId, ...draft.payload]),
        cardId: widget.cardId,
        draft: draft,
      );
      if (!mounted) return;
      Navigator.of(context).maybePop(savedId);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = safeMessage(e));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final assets = (ref.watch(assetsProvider).value ?? const <Asset>[])
        .where((a) => a.type != AssetType.debt)
        .toList();
    final validAssetId = assets.any((a) => a.id == _cardAssetId)
        ? _cardAssetId
        : noRef;
    final luhn = inspectCardLuhn(_noController.text);
    final groupedPreview = formatCardNumberGrouped(_noController.text);

    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        key: const Key('bank_card_editor_page'),
        appBar: AppBar(title: Text(_editing ? '编辑银行卡' : '添加银行卡')),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: FilledButton(
              key: const Key('save_bank_card_button'),
              onPressed: _busy || _loading ? null : _submit,
              child: Text(_busy ? '保存中…' : '保存'),
            ),
          ),
        ),
        body: _loading
            ? const Loading()
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Wrap(
                        spacing: 8,
                        children: [
                          ChoiceChip(
                            key: const Key('bank_card_type_0'),
                            label: const Text('储蓄卡'),
                            selected: _cardType == BankCardType.debit,
                            onSelected: _busy
                                ? null
                                : (_) => setState(
                                    () => _cardType = BankCardType.debit,
                                  ),
                          ),
                          ChoiceChip(
                            key: const Key('bank_card_type_1'),
                            label: const Text('信用卡'),
                            selected: _cardType == BankCardType.credit,
                            onSelected: _busy
                                ? null
                                : (_) => setState(
                                    () => _cardType = BankCardType.credit,
                                  ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        key: const Key('bank_card_name_input'),
                        controller: _nameController,
                        enabled: !_busy,
                        maxLength: maxBankCardNameLength,
                        decoration: const InputDecoration(
                          labelText: '银行与卡片名称（如：招商银行储蓄卡）',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        key: const Key('bank_card_no_input'),
                        controller: _noController,
                        enabled: !_busy,
                        keyboardType: TextInputType.number,
                        inputFormatters: <TextInputFormatter>[
                          FilteringTextInputFormatter.allow(
                            RegExp(r'[0-9\s\-]'),
                          ),
                        ],
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          labelText: '银行卡号',
                          hintText: '支持输入或粘贴带空格/连字符的卡号',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Container(
                            key: const Key('editor_luhn_badge'),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: luhn.passesLuhn
                                  ? Colors.green.withValues(alpha: 0.14)
                                  : Theme.of(
                                      context,
                                    ).colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  luhn.passesLuhn
                                      ? Icons.verified_outlined
                                      : Icons.info_outline,
                                  size: 16,
                                  color: luhn.passesLuhn
                                      ? Colors.green.shade700
                                      : Theme.of(
                                          context,
                                        ).colorScheme.onSurfaceVariant,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  luhn.badgeLabel,
                                  style: Theme.of(context).textTheme.labelSmall,
                                ),
                              ],
                            ),
                          ),
                          if (groupedPreview.isNotEmpty) ...[
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                groupedPreview,
                                key: const Key('editor_grouped_preview'),
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        key: const Key('bank_card_owner_input'),
                        controller: _ownerController,
                        enabled: !_busy,
                        maxLength: maxBankCardOwnerLength,
                        decoration: const InputDecoration(
                          labelText: '持卡人（可选）',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 8),
                      InputDecorator(
                        decoration: const InputDecoration(
                          labelText: '关联资产账户（可选）',
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<int>(
                            key: const Key('bank_card_asset_dropdown'),
                            isExpanded: true,
                            isDense: true,
                            value: validAssetId,
                            items: [
                              const DropdownMenuItem<int>(
                                value: noRef,
                                child: Text('不关联账户'),
                              ),
                              for (final a in assets)
                                DropdownMenuItem<int>(
                                  value: a.id,
                                  child: Text(a.name),
                                ),
                            ],
                            onChanged: _busy
                                ? null
                                : (v) =>
                                      setState(() => _cardAssetId = v ?? noRef),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '卡片配色',
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          ChoiceChip(
                            key: const Key('card_color_default'),
                            label: const Text('默认'),
                            selected: _cardColor == null,
                            onSelected: _busy
                                ? null
                                : (_) => setState(() => _cardColor = null),
                          ),
                          for (final (hex, label) in presetBankCardColors)
                            ChoiceChip(
                              key: Key('card_color_$hex'),
                              avatar: CircleAvatar(
                                backgroundColor: parseCardColorOrNull(hex),
                                radius: 8,
                              ),
                              label: Text(label),
                              selected: _cardColor?.toUpperCase() == hex,
                              onSelected: _busy
                                  ? null
                                  : (_) => setState(() => _cardColor = hex),
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        key: const Key('bank_card_remark_input'),
                        controller: _remarkController,
                        enabled: !_busy,
                        maxLength: maxBankCardRemarkLength,
                        maxLines: 2,
                        decoration: const InputDecoration(
                          labelText: '开户支行 / 备注（可选）',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            _error!,
                            key: const Key('bank_card_form_error'),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}
