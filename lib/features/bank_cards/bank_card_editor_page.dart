import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/adaptive.dart';
import '../../app/providers.dart';
import '../../core/failure.dart';
import '../../data/db/database.dart';
import '../../data/tools/bank_card_service.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/template_card_rules.dart';
import '../common/catalog_icons.dart';
import '../common/common.dart';
import '../common/desktop_modal_page.dart';
import 'bank_card_providers.dart';

Color? parseCardColorOrNull(String? hex) {
  final cleanHex = tryParseBankCardVisualMeta(hex).colorHex;
  if (cleanHex == null) return null;
  final trimmed = cleanHex.trim();
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
  const BankCardEditorPage({
    super.key,
    this.cardId,
    @visibleForTesting this.debugInitialIconKey,
  });

  final int? cardId;
  final String? debugInitialIconKey;

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
  String? _explicitColorHex;
  String? _manualIconKey;
  int _cardAssetId = noRef;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  bool get _editing => widget.cardId != null;

  static String? _sanitizeIconKeyForPreview(String? raw) {
    if (raw == null) return null;
    final cleaned = raw
        .replaceAll('|', '')
        .replaceAll(RegExp(r'[\s\x00-\x1F]'), '')
        .trim();
    if (cleaned.isEmpty || cleaned == assetTextIconPrefix) return null;
    return cleaned.length > 96 ? cleaned.substring(0, 96) : cleaned;
  }

  /// Non-throwing visual metadata encoder for live UI preview inside `build()`.
  String? _encodedCardColorMeta() {
    String? safeColor;
    final rawColor = _explicitColorHex?.trim();
    if (rawColor != null && rawColor.isNotEmpty) {
      try {
        safeColor = encodeBankCardVisualMeta(colorHex: rawColor);
      } on Object {
        safeColor = null;
      }
    }
    final safeIcon = _sanitizeIconKeyForPreview(_manualIconKey);
    if (safeIcon == null) return safeColor;
    try {
      return encodeBankCardVisualMeta(colorHex: safeColor, iconKey: safeIcon);
    } on Object {
      return safeColor;
    }
  }

  /// Strict visual metadata encoder validated during `_submit()`.
  String? _strictEncodedCardColorMeta() {
    final rawIcon = _manualIconKey?.trim();
    if (rawIcon != null && rawIcon.isNotEmpty) {
      if (rawIcon.contains('|') ||
          rawIcon.length > 96 ||
          RegExp(r'[\s\x00-\x1F]').hasMatch(rawIcon)) {
        throw const Failure(FailureCode.validation, '卡片图标标识无效');
      }
    }
    return encodeBankCardVisualMeta(
      colorHex: _explicitColorHex,
      iconKey: rawIcon,
    );
  }

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
          final meta = tryParseBankCardVisualMeta(card.cardColor);
          _cardType = card.cardType;
          _nameController.text = card.cardName;
          _noController.text = formatCardNumberGrouped(card.cardNo);
          _ownerController.text = card.cardOwner;
          _remarkController.text = card.remark;
          _explicitColorHex = meta.colorHex;
          _manualIconKey = meta.iconKey;
          _cardAssetId = card.cardAssetId;
        }
      }
      if (widget.debugInitialIconKey != null) {
        _manualIconKey = widget.debugInitialIconKey;
      }
    } catch (e) {
      _error = safeMessage(e);
    }
    if (mounted) {
      setState(() => _loading = false);
    }
  }

  Future<void> _pickCardIcon() async {
    final safeInitialColor = parseCardColorOrNull(_explicitColorHex) == null
        ? null
        : _explicitColorHex?.trim();
    final picked = await showBankCardVisualPicker(
      context,
      initialIcon: _sanitizeIconKeyForPreview(_manualIconKey),
      initialColor: safeInitialColor,
      cardType: _cardType,
      previewName: _nameController.text.trim(),
    );
    if (picked == null || !mounted) return;
    setState(() {
      final chosenColor = picked.colorHex.trim();
      _explicitColorHex = chosenColor.isEmpty
          ? null
          : chosenColor.toUpperCase();
      if (picked.icon.isEmpty) {
        _manualIconKey = null;
      } else {
        _manualIconKey = picked.icon;
      }
    });
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
      final encodedCardColor = _strictEncodedCardColorMeta();
      final draft = BankCardDraft(
        cardType: _cardType,
        cardName: _nameController.text,
        cardNo: _noController.text,
        cardOwner: _ownerController.text,
        remark: _remarkController.text,
        cardColor: encodedCardColor,
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

    final isDesktop = DesktopAdaptive.isDesktop(context);

    return PopScope(
      canPop: !_busy,
      child: DesktopModalEscapeScope(
        enabled: isDesktop,
        child: Scaffold(
          key: const Key('bank_card_editor_page'),
          appBar: AppBar(
            leading: isDesktop ? const CloseButton() : null,
            scrolledUnderElevation: isDesktop ? 0 : null,
            title: Text(_editing ? '编辑银行卡' : '添加银行卡'),
          ),
          bottomNavigationBar: SafeArea(
            child: Padding(
              padding: isDesktop
                  ? const EdgeInsets.fromLTRB(20, 8, 20, 14)
                  : const EdgeInsets.fromLTRB(16, 8, 16, 12),
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
                      padding: isDesktop
                          ? const EdgeInsets.fromLTRB(20, 12, 20, 16)
                          : const EdgeInsets.all(16),
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
                          onChanged: (_) => setState(() {}),
                          decoration: const InputDecoration(
                            labelText: '银行与卡片名称（如：招商银行储蓄卡）',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Builder(
                          builder: (context) {
                            final theme = Theme.of(context);
                            final cardVisual = resolveBankCardVisual(
                              cardColorMeta: _encodedCardColorMeta(),
                              cardName: _nameController.text.trim(),
                              cardType: _cardType,
                            );
                            return InkWell(
                              key: const Key('bank_card_icon_picker_trigger'),
                              borderRadius: BorderRadius.circular(12),
                              onTap: _busy ? null : _pickCardIcon,
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
                                    BankCardIconAvatar(
                                      cardColorMeta: _encodedCardColorMeta(),
                                      cardName: _nameController.text.trim(),
                                      cardType: _cardType,
                                      size: 38,
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            '银行行标',
                                            style: theme.textTheme.bodyMedium,
                                          ),
                                          Text(
                                            cardVisual.isAutoMatched
                                                ? '${cardVisual.visual.label}（按名称智能关联）· 点击更换'
                                                : '${cardVisual.visual.label}（手动指定）· 点击更换或恢复自动',
                                            style: theme.textTheme.bodySmall
                                                ?.copyWith(
                                                  color:
                                                      theme.colorScheme.outline,
                                                ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const Icon(Icons.chevron_right),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                        const SizedBox(height: 12),
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
                        Builder(
                          builder: (context) {
                            final theme = Theme.of(context);
                            final isDark = theme.brightness == Brightness.dark;
                            final luhnBgColor = luhn.passesLuhn
                                ? (isDark
                                      ? Colors.green.shade900.withValues(
                                          alpha: 0.45,
                                        )
                                      : Colors.green.withValues(alpha: 0.14))
                                : theme.colorScheme.surfaceContainerHighest;
                            final luhnFgColor = luhn.passesLuhn
                                ? (isDark
                                      ? Colors.green.shade300
                                      : Colors.green.shade700)
                                : theme.colorScheme.onSurfaceVariant;
                            return Row(
                              children: [
                                Flexible(
                                  child: Container(
                                    key: const Key('editor_luhn_badge'),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: luhnBgColor,
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
                                          color: luhnFgColor,
                                        ),
                                        const SizedBox(width: 4),
                                        Flexible(
                                          child: Text(
                                            luhn.badgeLabel,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: theme.textTheme.labelSmall
                                                ?.copyWith(color: luhnFgColor),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                if (groupedPreview.isNotEmpty) ...[
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      groupedPreview,
                                      key: const Key('editor_grouped_preview'),
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.bodySmall,
                                    ),
                                  ),
                                ],
                              ],
                            );
                          },
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
                              vertical: 14,
                            ),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<int>(
                              key: const Key('bank_card_asset_dropdown'),
                              isExpanded: true,
                              isDense: true,
                              style: Theme.of(context).textTheme.bodyLarge,
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
                                  : (v) => setState(
                                      () => _cardAssetId = v ?? noRef,
                                    ),
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
                              selected: _explicitColorHex == null,
                              onSelected: _busy
                                  ? null
                                  : (_) => setState(
                                      () => _explicitColorHex = null,
                                    ),
                            ),
                            for (final (hex, label) in presetBankCardColors)
                              ChoiceChip(
                                key: Key('card_color_$hex'),
                                avatar: CircleAvatar(
                                  backgroundColor: parseCardColorOrNull(hex),
                                  radius: 8,
                                ),
                                label: Text(label),
                                selected:
                                    _explicitColorHex?.toUpperCase() == hex,
                                onSelected: _busy
                                    ? null
                                    : (_) => setState(
                                        () => _explicitColorHex = hex,
                                      ),
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
      ),
    );
  }
}
