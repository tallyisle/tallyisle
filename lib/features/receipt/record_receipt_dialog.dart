import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/failure.dart';
import '../../data/db/database.dart';
import '../../domain/ledger/record_extra.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/asset_overview.dart' show normalizeCurrency;
import '../../domain/rules/currency_rates.dart' show baseCurrency;
import '../../platform/files.dart';
import '../common/common.dart';
import 'receipt_diy_providers.dart';

/// Opens the paper-style receipt share/save dialog for [recordId] (`F-036`).
Future<void> showRecordReceiptDialog(
  BuildContext context, {
  required String recordId,
  LedgerRecord? initialRecord,
}) => showDialog<void>(
  context: context,
  builder: (_) =>
      RecordReceiptDialog(recordId: recordId, initialRecord: initialRecord),
);

/// Paper-style thermal receipt dialog rendered inside a [RepaintBoundary] and
/// exported as PNG via [FileAccess.saveBytes] / [FileAccess.shareBytes] (`F-036`).
class RecordReceiptDialog extends ConsumerStatefulWidget {
  const RecordReceiptDialog({
    super.key,
    required this.recordId,
    this.initialRecord,
  });

  final String recordId;
  final LedgerRecord? initialRecord;

  @override
  ConsumerState<RecordReceiptDialog> createState() =>
      _RecordReceiptDialogState();
}

class _RecordReceiptDialogState extends ConsumerState<RecordReceiptDialog> {
  final _boundaryKey = GlobalKey();
  bool _busy = false;
  String? _feedback;
  bool _feedbackIsError = false;

  static String _catName(List<RecordCategory> cats, int id) {
    final c = cats.where((x) => x.id == id).firstOrNull;
    if (c == null) return '未分类';
    if (c.parentCatId != -1) {
      final p = cats.where((x) => x.id == c.parentCatId).firstOrNull;
      if (p != null) return '${p.name} · ${c.name}';
    }
    return c.name;
  }

  static String _assetLabel(LedgerRecord r, List<Asset> assets) {
    String nameOf(int id) => id == noRef
        ? ''
        : (assets.where((a) => a.id == id).firstOrNull?.name ?? '已删除账户');

    if (r.type == RecordType.transfer ||
        r.type == RecordType.borrowIn ||
        r.type == RecordType.lendOut ||
        r.type == RecordType.repay ||
        r.type == RecordType.collect) {
      final from = nameOf(r.fromAssetId);
      final to = nameOf(r.toAssetId);
      if (from.isNotEmpty && to.isNotEmpty) return '$from → $to';
      return from.isNotEmpty ? from : to;
    }
    if (r.type == RecordType.reimbursable ||
        r.type == RecordType.balanceAdjust) {
      return nameOf(r.fromAssetId);
    }
    return nameOf(r.assetId);
  }

  static String _resolveCurrency(LedgerRecord r, List<Asset> assets) {
    final primaryAssetId = switch (r.type) {
      RecordType.transfer ||
      RecordType.reimbursable ||
      RecordType.balanceAdjust => r.fromAssetId,
      _ => r.assetId,
    };
    if (primaryAssetId == noRef) return baseCurrency;
    final found = assets.where((a) => a.id == primaryAssetId).firstOrNull;
    return normalizeCurrency(found?.currency) ?? baseCurrency;
  }

  Future<void> _exportPng(ReceiptViewModel vm, {required bool share}) async {
    setState(() {
      _busy = true;
      _feedback = null;
    });
    try {
      // Ensure current frame is painted before capturing RepaintBoundary.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final capturer = ref.read(receiptPngCapturerProvider);
      final fileAccess = ref.read(receiptFileAccessProvider);
      final pngBytes = await capturer(_boundaryKey);
      if (share) {
        await fileAccess.shareBytes(
          vm.suggestedFileName,
          pngBytes,
          mimeType: 'image/png',
          subject: '帐屿账单小票 ${vm.serialNo}',
        );
      } else {
        await fileAccess.saveBytes(
          vm.suggestedFileName,
          pngBytes,
          mimeType: 'image/png',
        );
      }
      if (!mounted) return;
      setState(() {
        _feedbackIsError = false;
        _feedback = share ? '已调起系统分享' : '小票图片已保存：${vm.suggestedFileName}';
      });
    } on Failure catch (e) {
      if (e.code == FailureCode.cancelled) return;
      if (!mounted) return;
      setState(() {
        _feedbackIsError = true;
        _feedback = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _feedbackIsError = true;
        _feedback = safeMessage(e);
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final recordAsync = ref.watch(recordProvider(widget.recordId));
    final record = recordAsync.value ?? widget.initialRecord;
    if (record == null) {
      if (recordAsync.isLoading) {
        return const Dialog(child: SizedBox(height: 160, child: Loading()));
      }
      return AlertDialog(
        title: const Text('账单小票'),
        content: const Text('该账单不存在或已被删除'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      );
    }

    final books = ref.watch(booksProvider).value ?? const <AccountBook>[];
    final cats =
        ref.watch(allCategoriesProvider(record.accountBookId)).value ??
        const <RecordCategory>[];
    final assets = ref.watch(assetsProvider).value ?? const <Asset>[];
    final tags =
        ref.watch(recordTagsProvider(record.recordId)).value ?? const <Tag>[];

    final bookName =
        books.where((b) => b.id == record.accountBookId).firstOrNull?.name ??
        '日常账本';

    RecordExtra extra;
    try {
      extra = RecordExtra.parse(record.extraInfo);
    } on Failure {
      extra = RecordExtra();
    }

    int attCount = 0;
    try {
      attCount = parseRecordImages(record.images).length;
    } on Failure {
      attCount = 0;
    }

    final vm = buildReceiptViewModel(
      recordId: record.recordId,
      type: record.type,
      subType: record.subType,
      moneyMinor: record.moneyMinor,
      discountMinor: record.discountMinor,
      recordTimeMs: record.recordTime,
      bookName: bookName,
      categoryLabel: _catName(cats, record.recordCatId),
      accountLabel: _assetLabel(record, assets),
      currencyCode: _resolveCurrency(record, assets),
      remark: record.remark,
      excludeBudget: record.excludeBudget,
      excludeExIn: record.excludeExIn,
      tagNames: [for (final t in tags) t.name],
      extra: extra,
      attachmentCount: attCount,
    );

    final fileAccess = ref.watch(receiptFileAccessProvider);
    final saveCap = fileAccess.saveLocationCapability;
    final shareCap = fileAccess.shareCapability;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RepaintBoundary(
                key: _boundaryKey,
                child: RecordReceiptPaperCard(viewModel: vm),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_feedback != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          _feedback!,
                          key: const Key('receipt-feedback-text'),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12,
                            color: _feedbackIsError
                                ? Theme.of(context).colorScheme.error
                                : Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            key: const Key('receipt-save-btn'),
                            onPressed:
                                _busy ||
                                    saveCap.state != CapabilityState.available
                                ? null
                                : () => _exportPng(vm, share: false),
                            icon: const Icon(Icons.save_alt_outlined, size: 18),
                            label: const Text('保存图片'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: FilledButton.icon(
                            key: const Key('receipt-share-btn'),
                            onPressed:
                                _busy ||
                                    shareCap.state != CapabilityState.available
                                ? null
                                : () => _exportPng(vm, share: true),
                            icon: const Icon(Icons.share_outlined, size: 18),
                            label: const Text('分享小票'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    TextButton(
                      key: const Key('receipt-close-btn'),
                      onPressed: _busy ? null : () => Navigator.pop(context),
                      child: const Text('关闭'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Pure visual paper-receipt widget suitable for PNG capture.
class RecordReceiptPaperCard extends StatelessWidget {
  const RecordReceiptPaperCard({super.key, required this.viewModel});

  final ReceiptViewModel viewModel;

  static const _paperBg = Color(0xFFFAF8F2);
  static const _inkPrimary = Color(0xFF222222);
  static const _inkMuted = Color(0xFF66635B);

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: const _SerratedPaperPainter(_paperBg),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 24, 22, 24),
        child: DefaultTextStyle(
          style: const TextStyle(color: _inkPrimary, fontSize: 13),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    viewModel.typeTitle,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: _inkPrimary,
                    ),
                  ),
                  Text(
                    viewModel.serialNo,
                    style: const TextStyle(
                      fontSize: 11,
                      color: _inkMuted,
                      letterSpacing: 0.6,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                viewModel.dateTimeText,
                style: const TextStyle(fontSize: 11, color: _inkMuted),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: _DashedReceiptDivider(),
              ),
              Center(
                child: Column(
                  children: [
                    Text(
                      viewModel.currencyCode,
                      style: const TextStyle(
                        fontSize: 11,
                        color: _inkMuted,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      viewModel.amountText,
                      key: const Key('receipt-amount-text'),
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        color: _inkPrimary,
                      ),
                    ),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: _DashedReceiptDivider(),
              ),
              for (final line in viewModel.lines)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 76,
                        child: Text(
                          line.label,
                          style: const TextStyle(color: _inkMuted),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          line.value,
                          textAlign: TextAlign.right,
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                      ),
                    ],
                  ),
                ),
              if (viewModel.remark.isNotEmpty) ...[
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 10),
                  child: _DashedReceiptDivider(),
                ),
                const Text(
                  '备注',
                  style: TextStyle(fontSize: 11, color: _inkMuted),
                ),
                const SizedBox(height: 4),
                Text(viewModel.remark),
              ],
              if (viewModel.flags.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final flag in viewModel.flags)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          border: Border.all(color: _inkMuted, width: 0.8),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          flag,
                          style: const TextStyle(
                            fontSize: 10,
                            color: _inkMuted,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: _DashedReceiptDivider(),
              ),
              Center(
                child: Text(
                  viewModel.brandStamp,
                  key: const Key('receipt-brand-stamp'),
                  style: const TextStyle(
                    fontSize: 11,
                    color: _inkMuted,
                    letterSpacing: 1.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DashedReceiptDivider extends StatelessWidget {
  const _DashedReceiptDivider();

  @override
  Widget build(BuildContext context) => const SizedBox(
    height: 1,
    width: double.infinity,
    child: CustomPaint(painter: _DashedLinePainter()),
  );
}

class _DashedLinePainter extends CustomPainter {
  const _DashedLinePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFC5C0B3)
      ..strokeWidth = 1;
    const dashWidth = 5.0;
    const dashSpace = 4.0;
    var x = 0.0;
    while (x < size.width) {
      final end = (x + dashWidth).clamp(0.0, size.width);
      canvas.drawLine(Offset(x, 0), Offset(end, 0), paint);
      x += dashWidth + dashSpace;
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _SerratedPaperPainter extends CustomPainter {
  const _SerratedPaperPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const toothWidth = 12.0;
    const toothHeight = 6.0;
    final path = Path()..moveTo(0, toothHeight);

    var x = 0.0;
    while (x < size.width) {
      final mid = (x + toothWidth / 2).clamp(0.0, size.width);
      final next = (x + toothWidth).clamp(0.0, size.width);
      path
        ..lineTo(mid, 0)
        ..lineTo(next, toothHeight);
      x += toothWidth;
    }

    path.lineTo(size.width, size.height - toothHeight);
    x = size.width;
    while (x > 0) {
      final mid = (x - toothWidth / 2).clamp(0.0, size.width);
      final prev = (x - toothWidth).clamp(0.0, size.width);
      path
        ..lineTo(mid, size.height)
        ..lineTo(prev, size.height - toothHeight);
      x -= toothWidth;
    }
    path.close();

    canvas.drawShadow(path, Colors.black26, 6, false);
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _SerratedPaperPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// Reusable dialog for manually entering or clearing `BillLocationInfo` (`F-036`).
class BillLocationEditorDialog extends StatefulWidget {
  const BillLocationEditorDialog({super.key, this.initial});

  final BillLocationInfo? initial;

  @override
  State<BillLocationEditorDialog> createState() =>
      _BillLocationEditorDialogState();
}

class _BillLocationEditorDialogState extends State<BillLocationEditorDialog> {
  late final TextEditingController _simpleController;
  late final TextEditingController _detailController;
  late final TextEditingController _latController;
  late final TextEditingController _lngController;
  String? _error;

  @override
  void initState() {
    super.initState();
    _simpleController = TextEditingController(
      text: widget.initial?.simpleName ?? '',
    );
    _detailController = TextEditingController(text: widget.initial?.name ?? '');
    _latController = TextEditingController(
      text: widget.initial?.latitude?.toString() ?? '',
    );
    _lngController = TextEditingController(
      text: widget.initial?.longitude?.toString() ?? '',
    );
  }

  @override
  void dispose() {
    _simpleController.dispose();
    _detailController.dispose();
    _latController.dispose();
    _lngController.dispose();
    super.dispose();
  }

  void _save() {
    try {
      final latText = _latController.text.trim();
      final lngText = _lngController.text.trim();
      final double? lat = latText.isEmpty ? null : double.tryParse(latText);
      final double? lng = lngText.isEmpty ? null : double.tryParse(lngText);
      if (latText.isNotEmpty && lat == null) {
        setState(() => _error = '纬度格式无效');
        return;
      }
      if (lngText.isNotEmpty && lng == null) {
        setState(() => _error = '经度格式无效');
        return;
      }
      final loc = BillLocationInfo(
        simpleName: _simpleController.text,
        name: _detailController.text,
        latitude: lat,
        longitude: lng,
      );
      Navigator.pop(context, loc);
    } on Failure catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('设置消费地点'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const Key('loc-simple-name'),
              controller: _simpleController,
              decoration: const InputDecoration(labelText: '地点简称（如：人民广场）'),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('loc-detail-name'),
              controller: _detailController,
              decoration: const InputDecoration(labelText: '详细地址（选填）'),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('loc-latitude'),
                    controller: _latController,
                    keyboardType: const TextInputType.numberWithOptions(
                      signed: true,
                      decimal: true,
                    ),
                    decoration: const InputDecoration(labelText: '纬度（选填）'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    key: const Key('loc-longitude'),
                    controller: _lngController,
                    keyboardType: const TextInputType.numberWithOptions(
                      signed: true,
                      decimal: true,
                    ),
                    decoration: const InputDecoration(labelText: '经度（选填）'),
                  ),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('loc-clear-btn'),
          onPressed: () => Navigator.pop(context, BillLocationInfo()),
          child: const Text('清除地点'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('loc-save-btn'),
          onPressed: _save,
          child: const Text('确定'),
        ),
      ],
    );
  }
}
