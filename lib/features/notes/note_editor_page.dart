import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/failure.dart';
import '../../domain/rules/wish_note_rules.dart';
import '../common/common.dart';
import 'note_providers.dart';

const _uuid = Uuid();

/// Create / edit page for a Note (`F-015`, original route `/bkp/NEAct`).
class NoteEditorPage extends ConsumerStatefulWidget {
  const NoteEditorPage({this.noteId, super.key});

  final int? noteId;

  @override
  ConsumerState<NoteEditorPage> createState() => _NoteEditorPageState();
}

class _NoteEditorPageState extends ConsumerState<NoteEditorPage> {
  final _titleCtrl = TextEditingController();
  final _contentCtrl = TextEditingController();
  final _ids = CommandIds();

  int? _createTimeMs;
  int? _updateTimeMs;

  bool _loading = true;
  bool _busy = false;
  String? _error;

  bool get _editing => widget.noteId != null;

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
      final service = await ref.read(noteServiceProvider.future);
      final existing = await service.getNote(widget.noteId!);
      if (existing == null) {
        throw const Failure(FailureCode.conflict, '便签不存在或已删除');
      }
      _titleCtrl.text = existing.title ?? '';
      _contentCtrl.text = existing.content;
      _createTimeMs = existing.createTime;
      _updateTimeMs = existing.updateTime;
    } catch (e) {
      _error = safeMessage(e);
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _contentCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final service = await ref.read(noteServiceProvider.future);
      final payload = [
        _editing ? 'edit' : 'new',
        widget.noteId,
        _titleCtrl.text,
        _contentCtrl.text,
      ];
      final commandId = _ids.forPayload(payload);

      if (_editing) {
        await service.updateNote(
          commandId: commandId,
          id: widget.noteId!,
          title: _titleCtrl.text,
          content: _contentCtrl.text,
        );
      } else {
        await service.createNote(
          commandId: commandId,
          title: _titleCtrl.text,
          content: _contentCtrl.text,
        );
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = safeMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _moveToTrash() async {
    if (!_editing || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final service = await ref.read(noteServiceProvider.future);
      await service.moveToTrash(commandId: _uuid.v4(), id: widget.noteId!);
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

    return Scaffold(
      key: const Key('note_editor_page'),
      appBar: AppBar(
        title: Text(_editing ? '编辑便签' : '新建便签'),
        actions: [
          if (_editing)
            IconButton(
              key: const Key('editor_trash_note'),
              tooltip: '移入回收站',
              onPressed: _busy ? null : _moveToTrash,
              icon: const Icon(Icons.delete_outline),
            ),
          TextButton(
            key: const Key('save_note_button'),
            onPressed: _busy || _loading ? null : _save,
            child: Text(_busy ? '保存中' : '保存'),
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
                    key: const Key('note_editor_error'),
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
                  key: const Key('note_title_input'),
                  controller: _titleCtrl,
                  maxLength: maxNoteTitleLength,
                  decoration: const InputDecoration(
                    labelText: '标题（可选）',
                    hintText: '输入便签标题…',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('note_content_input'),
                  controller: _contentCtrl,
                  minLines: 8,
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  decoration: const InputDecoration(
                    labelText: '便签正文',
                    hintText: '写下备忘、清单或灵感…',
                    alignLabelWithHint: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                if (_createTimeMs != null && _updateTimeMs != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    '创建于 ${formatDateTime(DateTime.fromMillisecondsSinceEpoch(_createTimeMs!))} · '
                    '最后修改 ${formatDateTime(DateTime.fromMillisecondsSinceEpoch(_updateTimeMs!))}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}
