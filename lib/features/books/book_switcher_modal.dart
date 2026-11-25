import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/adaptive.dart';
import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../budget/budget_providers.dart' show budgetOffsetProvider;

/// Opens the account book switcher (`切换账本`) using a centered compact dialog
/// on desktop and a bottom sheet on mobile, then switches the active book and
/// resets period offsets when a new book is chosen.
Future<void> showBookSwitcher(
  BuildContext context,
  WidgetRef ref, {
  String mobileManageLabel = '账本管理',
}) async {
  final q = await ref.read(queriesProvider.future);
  final books = await q.getBooks();
  final currentId = await q.getCurrentBookId();
  if (!context.mounted || !(ModalRoute.of(context)?.isCurrent ?? true)) {
    return;
  }

  final isDesktop = DesktopAdaptive.isDesktop(context);
  final int? picked;
  if (isDesktop) {
    picked = await showDialog<int>(
      context: context,
      builder: (dialogCtx) => _DesktopBookSwitcherDialog(
        books: books,
        currentId: currentId,
        onManageBooks: () {
          Navigator.of(dialogCtx).pop();
          if (context.mounted) {
            context.push('/books');
          }
        },
      ),
    );
  } else {
    picked = await showModalBottomSheet<int>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: [
                  Text('切换账本', style: Theme.of(sheetCtx).textTheme.titleMedium),
                  const Spacer(),
                  TextButton.icon(
                    key: const Key('book-picker-manage'),
                    onPressed: () {
                      Navigator.pop(sheetCtx);
                      if (context.mounted) {
                        context.push('/books');
                      }
                    },
                    icon: const Icon(Icons.settings_outlined, size: 18),
                    label: Text(mobileManageLabel),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 8),
                children: [
                  for (final b in books)
                    ListTile(
                      key: Key('book-option-${b.id}'),
                      title: Text(b.name),
                      trailing: b.id == currentId
                          ? const Icon(Icons.check)
                          : null,
                      onTap: () => Navigator.pop(sheetCtx, b.id),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  if (picked == null || !context.mounted) return;
  await q.setCurrentBook(picked);
  if (!context.mounted) return;
  ref.read(periodOffsetProvider.notifier).reset();
  ref.read(budgetOffsetProvider.notifier).reset();
}

class _DesktopBookSwitcherDialog extends StatelessWidget {
  const _DesktopBookSwitcherDialog({
    required this.books,
    required this.currentId,
    required this.onManageBooks,
  });

  final List<AccountBook> books;
  final int currentId;
  final VoidCallback onManageBooks;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Dialog(
      key: const Key('desktop-book-switcher-dialog'),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360, maxHeight: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 12, 10),
              child: Row(
                children: [
                  Icon(Icons.book_outlined, size: 20, color: scheme.primary),
                  const SizedBox(width: 8),
                  Text(
                    '切换账本',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    key: const Key('book-picker-manage'),
                    onPressed: onManageBooks,
                    icon: const Icon(Icons.settings_outlined, size: 17),
                    label: const Text('账本管理'),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(8, 2, 8, 8),
                itemCount: books.length,
                itemBuilder: (ctx, index) {
                  final b = books[index];
                  final selected = b.id == currentId;
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: ListTile(
                      key: Key('book-option-${b.id}'),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      selected: selected,
                      selectedTileColor: scheme.secondaryContainer.withValues(
                        alpha: 0.65,
                      ),
                      title: Text(
                        b.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                      trailing: selected
                          ? Icon(
                              Icons.check_rounded,
                              size: 18,
                              color: scheme.primary,
                            )
                          : null,
                      onTap: () => Navigator.of(ctx).pop(b.id),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
