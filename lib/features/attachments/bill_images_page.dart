import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/failure.dart';
import '../../data/db/database.dart';
import '../../domain/model/codes.dart';
import '../common/common.dart';
import 'attachment_providers.dart';

String _formatByteSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes ~/ 1024;
  if (kb < 1024) return '$kb KB';
  final mbWhole = kb ~/ 1024;
  final mbTenths = ((kb % 1024) * 10) ~/ 1024;
  return '$mbWhole.$mbTenths MB';
}

/// Reusable horizontal attachment strip for bill editors and detail views (F-022).
///
/// Can operate either:
/// - In **controlled mode** ([imageNames] + [onChanged]) for unsaved drafts; or
/// - In **record-bound mode** ([recordId]) persisting directly via `setRecordImages`.
class BillAttachmentStrip extends ConsumerStatefulWidget {
  const BillAttachmentStrip({
    super.key,
    this.recordId,
    this.imageNames = const <String>[],
    this.onChanged,
    this.readOnly = false,
  });

  final String? recordId;
  final List<String> imageNames;
  final ValueChanged<List<String>>? onChanged;
  final bool readOnly;

  @override
  ConsumerState<BillAttachmentStrip> createState() =>
      _BillAttachmentStripState();
}

class _BillAttachmentStripState extends ConsumerState<BillAttachmentStrip> {
  final _ids = CommandIds();
  bool _busy = false;

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  List<String> _safeParse(String? raw) {
    try {
      return parseRecordImages(raw);
    } on Failure {
      return const <String>[];
    }
  }

  Future<void> _applyUpdatedList(
    List<String> current,
    List<String> next,
  ) async {
    if (widget.onChanged != null) {
      widget.onChanged!(next);
      return;
    }
    final recordId = widget.recordId;
    if (recordId == null) return;
    setState(() => _busy = true);
    try {
      final service = await ref.read(billAttachmentServiceProvider.future);
      await service.setRecordImages(
        commandId: _ids.forPayload([
          'strip-set-images',
          recordId,
          current,
          next,
        ]),
        recordId: recordId,
        imageNames: next,
      );
      ref.invalidate(orphanAttachmentScanProvider);
    } catch (e) {
      _showSnack(safeMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickAndAdd(List<String> current) async {
    if (current.length >= maxBillImages) {
      _showSnack('单笔账单最多添加 $maxBillImages 张图片');
      return;
    }
    setState(() => _busy = true);
    String? storedName;
    try {
      final service = await ref.read(billAttachmentServiceProvider.future);
      final fileAccess = ref.read(attachmentFileAccessProvider);
      storedName = await service.pickAndSaveImage(fileAccess: fileAccess);
    } on Failure catch (e) {
      if (mounted) setState(() => _busy = false);
      if (e.code == FailureCode.cancelled) return;
      _showSnack(e.message);
      return;
    } catch (e) {
      if (mounted) setState(() => _busy = false);
      _showSnack(safeMessage(e));
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);

    if (current.contains(storedName)) {
      _showSnack('该图片已在当前账单中');
      return;
    }
    await _applyUpdatedList(current, [...current, storedName]);
  }

  @override
  Widget build(BuildContext context) {
    final List<String> names;
    if (widget.recordId != null && widget.onChanged == null) {
      final rec = ref.watch(recordProvider(widget.recordId!)).value;
      names = _safeParse(rec?.images);
    } else {
      names = widget.imageNames;
    }

    final canAdd = !widget.readOnly && names.length < maxBillImages;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Text(
              '图片附件（${names.length}/$maxBillImages）',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            if (_busy) ...[
              const SizedBox(width: 8),
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final name in names)
              _AttachmentThumbTile(
                key: Key('att-thumb-$name'),
                fileName: name,
                onTap: () => _showImagePreviewDialog(context, name),
                onRemove: widget.readOnly || _busy
                    ? null
                    : () => _applyUpdatedList(
                        names,
                        names.where((x) => x != name).toList(),
                      ),
              ),
            if (canAdd)
              InkWell(
                key: const Key('att-strip-add-btn'),
                borderRadius: BorderRadius.circular(8),
                onTap: _busy ? null : () => _pickAndAdd(names),
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.add_photo_alternate_outlined, size: 24),
                      SizedBox(height: 2),
                      Text('添加', style: TextStyle(fontSize: 11)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

Future<void> _showImagePreviewDialog(BuildContext context, String fileName) =>
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
        content: SizedBox(
          width: 300,
          height: 300,
          child: _AttachmentImageBox(fileName: fileName, fit: BoxFit.contain),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );

class _AttachmentThumbTile extends StatelessWidget {
  const _AttachmentThumbTile({
    super.key,
    required this.fileName,
    required this.onTap,
    this.onRemove,
  });

  final String fileName;
  final VoidCallback onTap;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 72,
      height: 72,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: _AttachmentImageBox(
                  fileName: fileName,
                  fit: BoxFit.cover,
                ),
              ),
            ),
          ),
          if (onRemove != null)
            Positioned(
              top: 2,
              right: 2,
              child: InkWell(
                key: Key('att-remove-$fileName'),
                onTap: onRemove,
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: const BoxDecoration(
                    color: Colors.black54,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.close, size: 14, color: Colors.white),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _AttachmentImageBox extends ConsumerWidget {
  const _AttachmentImageBox({required this.fileName, required this.fit});

  final String fileName;
  final BoxFit fit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytesAsync = ref.watch(attachmentBytesProvider(fileName));
    final cs = Theme.of(context).colorScheme;
    return bytesAsync.when(
      loading: () => ColoredBox(
        color: cs.surfaceContainerHighest,
        child: const Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
      error: (_, _) => ColoredBox(
        color: cs.errorContainer,
        child: const Center(child: Icon(Icons.broken_image_outlined)),
      ),
      data: (Uint8List? bytes) {
        if (bytes == null) {
          return ColoredBox(
            color: cs.surfaceContainerHighest,
            child: const Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.broken_image_outlined, size: 22),
                SizedBox(height: 2),
                Text('图片缺失', style: TextStyle(fontSize: 10)),
              ],
            ),
          );
        }
        return Image.memory(
          bytes,
          fit: fit,
          errorBuilder: (_, _, _) => ColoredBox(
            color: cs.secondaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.image_outlined, size: 22),
                  const SizedBox(height: 2),
                  Text(
                    fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 9),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

final class _GalleryEntry {
  const _GalleryEntry({required this.record, required this.fileName});
  final LedgerRecord record;
  final String fileName;
}

/// Monthly gallery & orphan attachment cleanup page (`F-022`, `/bkp/BIMA`).
class BillImagesPage extends ConsumerStatefulWidget {
  const BillImagesPage({super.key});

  @override
  ConsumerState<BillImagesPage> createState() => _BillImagesPageState();
}

class _BillImagesPageState extends ConsumerState<BillImagesPage> {
  final _ids = CommandIds();
  bool _currentBookOnly = false;
  bool _busy = false;
  int _cleanupRunNonce = 0;

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _runOrphanCleanup(OrphanAttachmentScan scan) async {
    final ok = await confirm(
      context,
      title: '清理无用图片缓存',
      message:
          '检测到 ${scan.orphanCount} 个未被任何账单、周期记账或分期引用的图片文件（共 ${_formatByteSize(scan.orphanTotalBytes)}）。确认立即清理？',
      ok: '立即清理',
    );
    if (!ok || !mounted) return;

    setState(() => _busy = true);
    try {
      final service = await ref.read(billAttachmentServiceProvider.future);
      final nonce = _cleanupRunNonce++;
      final res = await service.cleanupOrphanAttachments(
        commandId: _ids.forPayload([
          'ui-orphan-cleanup',
          nonce,
          scan.orphanFileNames,
        ]),
      );
      ref.invalidate(orphanAttachmentScanProvider);
      if (!mounted) return;
      _showSnack(
        '清理完成：已删除 ${res.deletedCount} 个无用文件，释放 ${_formatByteSize(res.freedBytes)}',
      );
    } catch (e) {
      _showSnack(safeMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openEntryDetail(_GalleryEntry entry) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final dt = DateTime.fromMillisecondsSinceEpoch(entry.record.recordTime);
        return AlertDialog(
          title: Text(
            '${RecordType.names[entry.record.type] ?? '账单'} · ${formatMinor(entry.record.moneyMinor.abs())}',
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 280,
                height: 220,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: _AttachmentImageBox(
                    fileName: entry.fileName,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text('时间：${formatDateTime(dt)}'),
              if (entry.record.remark.isNotEmpty)
                Text('备注：${entry.record.remark}'),
            ],
          ),
          actions: [
            TextButton(
              key: const Key('gallery-remove-image-btn'),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(
                '从账单移除',
                style: TextStyle(color: Theme.of(ctx).colorScheme.error),
              ),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
    if (remove != true || !mounted) return;

    setState(() => _busy = true);
    try {
      final service = await ref.read(billAttachmentServiceProvider.future);
      final current = parseRecordImages(entry.record.images);
      final next = current.where((f) => f != entry.fileName).toList();
      await service.setRecordImages(
        commandId: _ids.forPayload([
          'gallery-rm-img',
          entry.record.recordId,
          next,
        ]),
        recordId: entry.record.recordId,
        imageNames: next,
      );
      ref.invalidate(orphanAttachmentScanProvider);
      if (!mounted) return;
      _showSnack('已从账单移除该图片');
    } catch (e) {
      _showSnack(safeMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final activeBookId = ref.watch(currentBookIdProvider).value ?? 1;
    final queryBookId = _currentBookOnly ? activeBookId : null;
    final recordsAsync = ref.watch(recordsWithImagesProvider(queryBookId));
    final scanAsync = ref.watch(orphanAttachmentScanProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('账单图片库'),
        actions: [
          FilterChip(
            key: const Key('bill-images-book-filter'),
            label: Text(_currentBookOnly ? '当前账本' : '全部账本'),
            selected: _currentBookOnly,
            onSelected: (v) => setState(() => _currentBookOnly = v),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Column(
        children: [
          scanAsync.when(
            data: (scan) => Card(
              margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    const Icon(Icons.photo_library_outlined),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '有效关联图片 ${scan.referencedCount} 张'
                        '${scan.missingCount > 0 ? ' · 缺失原图 ${scan.missingCount} 张' : ''}'
                        ' · 无用缓存 ${scan.orphanCount} 个（${_formatByteSize(scan.orphanTotalBytes)}）',
                        key: const Key('bill-images-scan-summary'),
                      ),
                    ),
                    TextButton(
                      key: const Key('bill-images-cleanup-btn'),
                      onPressed: _busy || scan.orphanCount == 0
                          ? null
                          : () => _runOrphanCleanup(scan),
                      child: const Text('清理无用缓存'),
                    ),
                  ],
                ),
              ),
            ),
            loading: () => const LinearProgressIndicator(),
            error: (_, _) => const SizedBox.shrink(),
          ),
          Expanded(
            child: asyncBody(recordsAsync, (records) {
              final groups = <String, List<_GalleryEntry>>{};
              for (final r in records) {
                List<String> files;
                try {
                  files = parseRecordImages(r.images);
                } on Failure {
                  continue;
                }
                if (files.isEmpty) continue;
                final dt = DateTime.fromMillisecondsSinceEpoch(r.recordTime);
                final monthKey = '${dt.year}年${two(dt.month)}月';
                final bucket = groups.putIfAbsent(monthKey, () => []);
                for (final f in files) {
                  bucket.add(_GalleryEntry(record: r, fileName: f));
                }
              }

              if (groups.isEmpty) {
                return const Center(child: Text('暂无带图片的账单记录'));
              }

              final monthKeys = groups.keys.toList();
              return ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: monthKeys.length,
                itemBuilder: (context, sectionIndex) {
                  final monthTitle = monthKeys[sectionIndex];
                  final entries = groups[monthTitle]!;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          '$monthTitle（${entries.length} 张）',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: entries.length,
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3,
                              mainAxisSpacing: 8,
                              crossAxisSpacing: 8,
                            ),
                        itemBuilder: (context, idx) {
                          final entry = entries[idx];
                          return InkWell(
                            key: Key(
                              'gallery-tile-${entry.record.recordId}-${entry.fileName}',
                            ),
                            onTap: () => _openEntryDetail(entry),
                            borderRadius: BorderRadius.circular(8),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  _AttachmentImageBox(
                                    fileName: entry.fileName,
                                    fit: BoxFit.cover,
                                  ),
                                  Positioned(
                                    left: 0,
                                    right: 0,
                                    bottom: 0,
                                    child: Container(
                                      color: Colors.black54,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 3,
                                      ),
                                      child: Text(
                                        formatMinor(
                                          entry.record.moneyMinor.abs(),
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 12),
                    ],
                  );
                },
              );
            }),
          ),
        ],
      ),
    );
  }
}
