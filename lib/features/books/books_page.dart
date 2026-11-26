import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/adaptive.dart';
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
      builder: (dialogCtx) {
        final isDesktop = DesktopAdaptive.isDesktop(dialogCtx);
        final formFields = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const Key('book-name'),
              controller: nameController,
              autofocus: true,
              decoration: isDesktop
                  ? const InputDecoration(
                      labelText: '账本名称',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 15,
                      ),
                    )
                  : const InputDecoration(labelText: '账本名称'),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('book-start-day'),
              controller: dayController,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: isDesktop
                  ? const InputDecoration(
                      labelText: '月起始日 (1-28)',
                      helperText: '账期统计从每月该日开始',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 15,
                      ),
                    )
                  : const InputDecoration(
                      labelText: '月起始日 (1-28)',
                      helperText: '账期统计从每月该日开始',
                    ),
            ),
          ],
        );
        return AlertDialog(
          title: const Text('新建账本'),
          content: isDesktop
              ? ConstrainedBox(
                  constraints: const BoxConstraints(
                    minWidth: 360,
                    maxWidth: 420,
                  ),
                  child: formFields,
                )
              : formFields,
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
        );
      },
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
      builder: (dialogCtx) {
        final isDesktop = DesktopAdaptive.isDesktop(dialogCtx);
        final formFields = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const Key('edit-book-name'),
              controller: nameController,
              autofocus: true,
              decoration: isDesktop
                  ? const InputDecoration(
                      labelText: '账本名称',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 15,
                      ),
                    )
                  : const InputDecoration(labelText: '账本名称'),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('edit-book-start-day'),
              controller: dayController,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: isDesktop
                  ? const InputDecoration(
                      labelText: '月起始日 (1-28)',
                      helperText: '账期统计从每月该日开始',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 15,
                      ),
                    )
                  : const InputDecoration(
                      labelText: '月起始日 (1-28)',
                      helperText: '账期统计从每月该日开始',
                    ),
            ),
          ],
        );
        return AlertDialog(
          title: Text('编辑“${book.name}”'),
          content: isDesktop
              ? ConstrainedBox(
                  constraints: const BoxConstraints(
                    minWidth: 360,
                    maxWidth: 420,
                  ),
                  child: formFields,
                )
              : formFields,
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
        );
      },
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
    final isDesktop = DesktopAdaptive.isDesktop(context);
    final isPopupModal = isDesktop && ModalRoute.of(context) is PopupRoute;

    return Scaffold(
      appBar: AppBar(
        leading: isPopupModal ? const CloseButton() : null,
        title: const Text('账本管理'),
        actions: isDesktop
            ? [
                TallySoftButton.icon(
                  key: const Key('add-book'),
                  compact: true,
                  onPressed: _addBook,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('新建账本'),
                ),
                const SizedBox(width: 12),
              ]
            : null,
      ),
      body: asyncBody(booksAsync, (books) {
        final currentBookId = currentBookIdAsync.value ?? 1;
        if (books.isEmpty) {
          return const TallyEmptyState(
            icon: Icons.menu_book_outlined,
            title: '暂无账本',
            subtitle: '按生活、旅行或专项创建独立账本，清晰分开管理收支',
          );
        }

        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        final cardColor = theme.brightness == Brightness.dark
            ? scheme.surfaceContainerLow
            : Color.lerp(
                scheme.surfaceContainerLow,
                scheme.surfaceContainer,
                0.55,
              )!;
        final cardShape = RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        );

        final listView = ReorderableListView.builder(
          padding: isDesktop
              ? const EdgeInsets.symmetric(vertical: 8)
              : const EdgeInsets.fromLTRB(0, 8, 0, 96),
          buildDefaultDragHandles: false,
          itemCount: books.length,
          onReorderItem: (oldIndex, newIndex) =>
              _reorderBooks(books, oldIndex, newIndex),
          itemBuilder: (context, index) {
            final b = books[index];
            return Card(
              key: ValueKey(b.id),
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
              elevation: 0,
              surfaceTintColor: Colors.transparent,
              color: cardColor,
              clipBehavior: Clip.antiAlias,
              shape: cardShape,
              child: ListTile(
                contentPadding: const EdgeInsets.only(left: 16, right: 12),
                leading: Icon(
                  b.id == currentBookId
                      ? Icons.bookmark
                      : Icons.bookmark_outline,
                  color: b.id == currentBookId ? scheme.primary : null,
                ),
                title: Row(
                  children: [
                    Flexible(
                      child: Text(
                        b.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (b.id == currentBookId) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.primaryContainer,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '当前',
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onPrimaryContainer,
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
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                        onPressed: () => _setCurrentBook(b.id),
                        child: const Text('切到此本'),
                      ),
                    PopupMenuButton<String>(
                      key: Key('book-menu-${b.id}'),
                      padding: const EdgeInsets.all(4),
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
                    ReorderableDragStartListener(
                      index: index,
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(Icons.drag_handle),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
        if (!isDesktop) return listView;
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: listView,
          ),
        );
      }),
      floatingActionButton: isDesktop
          ? null
          : FloatingActionButton.extended(
              key: const Key('add-book'),
              heroTag: 'fab-add-book',
              onPressed: _addBook,
              icon: const Icon(Icons.add),
              label: const Text('新建账本'),
            ),
    );
  }
}
