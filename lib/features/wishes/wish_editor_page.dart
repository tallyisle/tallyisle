import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/failure.dart';
import '../../domain/rules/wish_note_rules.dart';
import '../common/common.dart';
import 'wish_providers.dart';

const _uuid = Uuid();

/// Create / edit page for a Wish (`F-014`).
class WishEditorPage extends ConsumerStatefulWidget {
  const WishEditorPage({this.wishId, super.key});

  final String? wishId;

  @override
  ConsumerState<WishEditorPage> createState() => _WishEditorPageState();
}

class _WishEditorPageState extends ConsumerState<WishEditorPage> {
  final _contentCtrl = TextEditingController();
  final _amountCtrl = TextEditingController(text: '0.00');
  final _sortCtrl = TextEditingController();
  final _ids = CommandIds();

  DateTime? _targetDate;
  String? _selectedIcon = 'star';

  bool _loading = true;
  bool _busy = false;
  String? _error;

  bool get _editing => widget.wishId != null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!_editing) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final service = await ref.read(wishServiceProvider.future);
      final existing = await service.getWish(widget.wishId!);
      if (existing == null) {
        throw const Failure(FailureCode.conflict, '心愿不存在或已删除');
      }
      _contentCtrl.text = existing.content;
      _amountCtrl.text = formatMinor(existing.valueMinor);
      _sortCtrl.text = '${existing.sort}';
      _selectedIcon = existing.icon;
      if (existing.targetDate > 0) {
        final dt = DateTime.fromMillisecondsSinceEpoch(existing.targetDate);
        _targetDate = DateTime(dt.year, dt.month, dt.day);
      } else {
        _targetDate = null;
      }
    } catch (e) {
      _error = safeMessage(e);
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _contentCtrl.dispose();
    _amountCtrl.dispose();
    _sortCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickTargetDate() async {
    final now = DateTime.now();
    final initial = _targetDate ?? DateTime(now.year, now.month, now.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100, 12, 31),
    );
    if (picked != null && mounted) {
      setState(() {
        _targetDate = DateTime(picked.year, picked.month, picked.day);
      });
    }
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final value = parseWishAmount(_amountCtrl.text);
      final sortText = _sortCtrl.text.trim();
      int? parsedSort;
      if (sortText.isNotEmpty) {
        parsedSort = int.tryParse(sortText);
        if (parsedSort == null) {
          throw const Failure(FailureCode.validation, '排序值须为整数');
        }
      }
      final targetMs = _targetDate == null
          ? unsetWishTargetDate
          : DateTime(
              _targetDate!.year,
              _targetDate!.month,
              _targetDate!.day,
            ).millisecondsSinceEpoch;

      final service = await ref.read(wishServiceProvider.future);
      final payload = [
        _editing ? 'edit' : 'new',
        widget.wishId,
        _contentCtrl.text,
        value.toJson(),
        targetMs,
        _selectedIcon,
        parsedSort,
      ];
      final commandId = _ids.forPayload(payload);

      if (_editing) {
        await service.updateWish(
          commandId: commandId,
          id: widget.wishId!,
          content: _contentCtrl.text,
          value: value,
          targetDate: targetMs,
          icon: _selectedIcon,
          sort: parsedSort,
        );
      } else {
        await service.createWish(
          commandId: commandId,
          content: _contentCtrl.text,
          value: value,
          targetDate: targetMs,
          icon: _selectedIcon,
          sort: parsedSort,
        );
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _error = safeMessage(e));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _deleteCurrent() async {
    if (!_editing || _busy) return;
    final ok = await confirm(
      context,
      title: '确认删除此心愿？',
      message: '删除后不可恢复。',
      ok: '删除',
    );
    if (!ok || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final service = await ref.read(wishServiceProvider.future);
      await service.deleteWish(commandId: _uuid.v4(), id: widget.wishId!);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = safeMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasCustomLegacyIcon =
        _selectedIcon != null &&
        _selectedIcon!.trim().isNotEmpty &&
        !presetWishIcons.any((o) => o.key == _selectedIcon!.trim());

    return Scaffold(
      key: const Key('wish_editor_page'),
      appBar: AppBar(
        title: Text(_editing ? '编辑心愿' : '新建心愿'),
        actions: [
          if (_editing)
            IconButton(
              key: const Key('editor_delete_wish'),
              tooltip: '删除心愿',
              onPressed: _busy ? null : _deleteCurrent,
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
      body: _loading
          ? const Loading()
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_error != null) ...[
                  Container(
                    key: const Key('wish_editor_error'),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                TextField(
                  key: const Key('wish_content_input'),
                  controller: _contentCtrl,
                  maxLength: maxWishContentLength,
                  decoration: const InputDecoration(
                    labelText: '心愿内容',
                    hintText: '例如：降噪耳机、海岛旅行',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('wish_amount_input'),
                  controller: _amountCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: '目标金额（元）',
                    prefixText: '¥ ',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                Text('心愿图标', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final option in presetWishIcons)
                      ChoiceChip(
                        key: Key('wish_icon_chip_${option.key}'),
                        avatar: Icon(wishIconData(option.key), size: 18),
                        label: Text(option.label),
                        selected: _selectedIcon == option.key,
                        onSelected: (_) =>
                            setState(() => _selectedIcon = option.key),
                      ),
                    if (hasCustomLegacyIcon)
                      ChoiceChip(
                        key: const Key('wish_icon_chip_legacy'),
                        avatar: const Icon(Icons.auto_awesome, size: 18),
                        label: Text('原图标 (${_selectedIcon!})'),
                        selected: true,
                        onSelected: (_) {},
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Card(
                  margin: EdgeInsets.zero,
                  child: ListTile(
                    leading: const Icon(Icons.event_outlined),
                    title: const Text('目标日期（可选）'),
                    subtitle: Text(
                      _targetDate == null ? '未设置' : formatDate(_targetDate!),
                      key: const Key('wish_target_date_text'),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_targetDate != null)
                          IconButton(
                            key: const Key('wish_clear_target_date'),
                            tooltip: '清除目标日期',
                            onPressed: () => setState(() => _targetDate = null),
                            icon: const Icon(Icons.clear),
                          ),
                        TextButton(
                          key: const Key('wish_pick_target_date'),
                          onPressed: _pickTargetDate,
                          child: Text(_targetDate == null ? '选择日期' : '修改'),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  key: const Key('wish_sort_input'),
                  controller: _sortCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                    signed: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: '排序权重（可选，数值越小越靠前）',
                    hintText: '留空则默认置顶',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
      bottomNavigationBar: _loading
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: FilledButton.icon(
                  key: const Key('save_wish_button'),
                  onPressed: _busy ? null : _save,
                  icon: const Icon(Icons.check),
                  label: Text(_busy ? '保存中…' : '保存心愿'),
                ),
              ),
            ),
    );
  }
}
