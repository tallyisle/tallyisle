import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../common/common.dart';

class BooksPage extends ConsumerStatefulWidget {
  const BooksPage({super.key});

  @override
  ConsumerState<BooksPage> createState() => _BooksPageState();
}

class _BooksPageState extends ConsumerState<BooksPage> {
  final _ids = CommandIds();

  Future<void> _addBook() async {
    final nameController = TextEditingController();
    final dayController = TextEditingController(text: '1');
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('新建账本'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const Key('book-name'),
              controller: nameController,
              autofocus: true,
              decoration: const InputDecoration(labelText: '账本名称'),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('book-start-day'),
              controller: dayController,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: '月起始日 (1-28)',
                helperText: '账期统计从每月该日开始',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('book-save'),
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('创建'),
          ),
        ],
      ),
    );

    if (ok != true || !mounted) return;
    try {
      final name = nameController.text.trim();
      final day = int.tryParse(dayController.text) ?? 1;
      final service = await ref.read(catalogServiceProvider.future);
      await service.createBook(
        commandId: _ids.forPayload(['add-book', name, day]),
        name: name,
        startDay: day,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
    }
  }

  Future<void> _editBook(AccountBook book) async {
    final nameController = TextEditingController(text: book.name);
    final dayController = TextEditingController(text: '${book.startDay}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text('编辑“${book.name}”'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const Key('edit-book-name'),
              controller: nameController,
              autofocus: true,
              decoration: const InputDecoration(labelText: '账本名称'),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('edit-book-start-day'),
              controller: dayController,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: '月起始日 (1-28)',
                helperText: '账期统计从每月该日开始',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('edit-book-save'),
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );

    if (ok != true || !mounted) return;
    try {
      final name = nameController.text.trim();
      final day = int.tryParse(dayController.text) ?? 1;
      final service = await ref.read(catalogServiceProvider.future);
      await service.updateBook(
        commandId: _ids.forPayload(['update-book', book.id, name, day]),
        bookId: book.id,
        name: name,
        startDay: day,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
    }
  }

  Future<void> _deleteBook(AccountBook book) async {
    final confirmed = await confirm(
      context,
      title: '删除账本',
      message: '确定删除账本“${book.name}”吗？若该账本下已有账单，将无法删除。',
      ok: '删除',
    );
    if (!confirmed || !mounted) return;
    try {
      final service = await ref.read(catalogServiceProvider.future);
      await service.deleteBook(
        commandId: _ids.forPayload(['delete-book', book.id]),
        bookId: book.id,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('账本“${book.name}”已删除')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
    }
  }

  Future<void> _setCurrentBook(int bookId) async {
    try {
      final service = await ref.read(catalogServiceProvider.future);
      await service.setCurrentBook(
        commandId: _ids.forPayload(['set-current-book', bookId]),
        bookId: bookId,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
    }
  }

  Future<void> _reorderBooks(
    List<AccountBook> books,
    int oldIndex,
    int newIndex,
  ) async {
    final updated = List<AccountBook>.from(books);
    final item = updated.removeAt(oldIndex);
    updated.insert(newIndex, item);
    try {
      final service = await ref.read(catalogServiceProvider.future);
      await service.reorderBooks(
        commandId: _ids.forPayload([
          'reorder-books',
          updated.map((b) => b.id).toList(),
        ]),
        bookIds: updated.map((b) => b.id).toList(),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final booksAsync = ref.watch(booksProvider);
    final currentBookIdAsync = ref.watch(currentBookIdProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('账本管理')),
      body: asyncBody(booksAsync, (books) {
        final currentBookId = currentBookIdAsync.value ?? 1;
        if (books.isEmpty) {
          return const Center(child: Text('暂无账本'));
        }

        return ReorderableListView(
          onReorderItem: (oldIndex, newIndex) =>
              _reorderBooks(books, oldIndex, newIndex),
          children: [
            for (final b in books)
              ListTile(
                key: ValueKey(b.id),
                leading: Icon(
                  b.id == currentBookId
                      ? Icons.bookmark
                      : Icons.bookmark_outline,
                  color: b.id == currentBookId
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
                title: Row(
                  children: [
                    Text(b.name),
                    if (b.id == currentBookId) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '当前',
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(
                              context,
                            ).colorScheme.onPrimaryContainer,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                subtitle: Text('每月 ${b.startDay} 日起始'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (b.id != currentBookId)
                      TextButton(
                        key: Key('book-set-current-${b.id}'),
                        onPressed: () => _setCurrentBook(b.id),
                        child: const Text('切到此本'),
                      ),
                    PopupMenuButton<String>(
                      key: Key('book-menu-${b.id}'),
                      onSelected: (val) {
                        if (val == 'edit') {
                          _editBook(b);
                        } else if (val == 'delete') {
                          _deleteBook(b);
                        }
                      },
                      itemBuilder: (context) => [
                        const PopupMenuItem(value: 'edit', child: Text('编辑')),
                        const PopupMenuItem(value: 'delete', child: Text('删除')),
                      ],
                    ),
                    const Icon(Icons.drag_handle),
                  ],
                ),
              ),
          ],
        );
      }),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('add-book'),
        heroTag: 'fab-add-book',
        onPressed: _addBook,
        icon: const Icon(Icons.add),
        label: const Text('新建账本'),
      ),
    );
  }
}
