import 'dart:async' show unawaited;

import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/adaptive.dart';
import '../../app/providers.dart';
import '../../core/failure.dart';
import '../../core/money.dart';
import '../../data/db/database.dart';
import '../../domain/ledger/record_extra.dart';
import '../../domain/ledger/record_relations.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/asset_overview.dart' show normalizeCurrency;
import '../../domain/rules/currency_rates.dart'
    show baseCurrency, defaultCurrencySymbol;
import '../attachments/attachment_providers.dart';
import '../common/catalog_icons.dart';
import '../common/common.dart';
import '../common/desktop_modal_page.dart';
import '../receipt/record_receipt_dialog.dart' show showRecordReceiptDialog;
import '../stats/tag_stats_page.dart' show TagColorDot, parseTagColor;
import 'desktop_record_editor_dialog.dart';
import 'record_editor_page.dart';
import 'record_labels.dart';

final _maxAmount = Money.parse('88888888888.00');

final _amountInputFormatters = <TextInputFormatter>[
  FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
];

Money _parseAmount(String text) {
  final t = text.trim();
  if (t.isEmpty) return Money.zero();
  final normalized = t.endsWith('.') ? t.substring(0, t.length - 1) : t;
  final money = Money.parse(
    normalized.startsWith('.') ? '0$normalized' : normalized,
  );
  if (money.units > _maxAmount.units) {
    throw const Failure(FailureCode.validation, '金额不能超过 88888888888.00');
  }
  return money;
}

/// Returns `true` when [r] is an auto-generated transfer fee child bill.
bool isGeneratedTransferFeeRecord(LedgerRecord r) {
  if (r.type != RecordType.fee) return false;
  final parentId = RecordRelations.parse(r.relInfo).transferFee?.parentId;
  return parentId != null && parentId.isNotEmpty;
}

/// Returns `true` when [r] can be opened in `RecordEditorPage` (`/record/:id/edit`).
bool isRecordEditable(LedgerRecord r) {
  final rel = RecordRelations.parse(r.relInfo);
  final childOf = rel.refunds?.originId ?? rel.reimbursements?.originId;
  final isChild = childOf != null && childOf.isNotEmpty;
  final isAdvance =
      r.type == RecordType.advanceIncome || r.type == RecordType.advanceExpense;
  final advanceSettled =
      isAdvance && RecordExtra.parse(r.extraInfo).advance != null;
  const specializedM4Types = {
    RecordType.borrowIn,
    RecordType.lendOut,
    RecordType.repay,
    RecordType.collect,
    RecordType.debtInterest,
    RecordType.installmentPrincipal,
    RecordType.depositInterest,
  };
  return !isChild &&
      !advanceSettled &&
      !specializedM4Types.contains(r.type) &&
      const {
        RecordType.expense,
        RecordType.income,
        RecordType.transfer,
        RecordType.reimbursable,
        RecordType.advanceIncome,
        RecordType.advanceExpense,
      }.contains(r.type);
}

class RecordDetailPage extends ConsumerStatefulWidget {
  const RecordDetailPage({
    super.key,
    required this.recordId,
    this.embeddedInPane = false,
    this.onClosePane,
    this.onSelectRelatedRecord,
  });

  final String recordId;
  final bool embeddedInPane;
  final VoidCallback? onClosePane;
  final ValueChanged<String>? onSelectRelatedRecord;

  @override
  ConsumerState<RecordDetailPage> createState() => _RecordDetailPageState();
}

class _RecordDetailPageState extends ConsumerState<RecordDetailPage> {
  final ids = CommandIds();
  int _opSeq = 0;
  bool busy = false;
  String? error;

  @override
  void didUpdateWidget(covariant RecordDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.recordId != widget.recordId) {
      busy = false;
      error = null;
    }
  }

  String _resolveOriginCurrency(LedgerRecord r, List<Asset> allAssets) {
    final snap = RecordExtra.parse(r.extraInfo).currency;
    final ac = normalizeCurrency(snap?.assetCode);
    if (ac != null) return ac;
    final aid = r.type == RecordType.reimbursable ? r.fromAssetId : r.assetId;
    if (aid != noRef) {
      final a = allAssets.where((x) => x.id == aid).firstOrNull;
      final c = normalizeCurrency(a?.currency);
      if (c != null) return c;
    }
    return baseCurrency;
  }

  String _symbolForCurrency(String code) {
    final currencies = ref.read(currenciesProvider).value ?? const <Currency>[];
    for (final c in currencies) {
      if (normalizeCurrency(c.code) == code && c.symbol.trim().isNotEmpty) {
        return c.symbol.trim();
      }
    }
    return defaultCurrencySymbol(code);
  }

  Future<List<Asset>> _loadEligibleAssets() async {
    final cached = ref.read(assetsProvider).value;
    final allAssets =
        cached ??
        await () async {
          final db = await ref.read(databaseProvider.future);
          return (db.select(db.assets)..orderBy([
                (a) => OrderingTerm.asc(a.sort),
                (a) => OrderingTerm.asc(a.id),
              ]))
              .get();
        }();
    return allAssets
        .where(
          (a) => a.status != AssetStatus.settled && a.type != AssetType.debt,
        )
        .toList();
  }

  bool _isImperativeRoute(BuildContext context) {
    final route = ModalRoute.of(context);
    return route != null && route.settings is! Page;
  }

  Future<void> _popDetailRoute() async {
    if (widget.embeddedInPane) {
      widget.onClosePane?.call();
      return;
    }
    if (_isImperativeRoute(context)) {
      await Navigator.of(context).maybePop();
      return;
    }
    final router = GoRouter.maybeOf(context);
    if (router != null && context.canPop()) {
      context.pop();
    } else {
      await Navigator.of(context).maybePop();
    }
  }

  Future<void> _openRelatedRecord(String relatedId) async {
    if (widget.embeddedInPane && widget.onSelectRelatedRecord != null) {
      widget.onSelectRelatedRecord!(relatedId);
      return;
    }
    if (_isImperativeRoute(context)) {
      await pushDesktopModalOrMaterialRoute<void>(
        context,
        maxWidth: 560,
        maxHeight: 740,
        barrierDismissible: true,
        child: RecordDetailPage(recordId: relatedId),
      );
      return;
    }
    if (GoRouter.maybeOf(context) != null) {
      await context.push('/record/$relatedId');
    } else {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => RecordDetailPage(recordId: relatedId),
        ),
      );
    }
  }

  void _openFeeParentRecord(String feeParent) {
    if (widget.embeddedInPane && widget.onSelectRelatedRecord != null) {
      widget.onSelectRelatedRecord!(feeParent);
      return;
    }
    final route = ModalRoute.of(context);
    if (route != null && route.settings is! Page) {
      final nav = Navigator.of(context);
      final navContext = nav.context;
      if (DesktopAdaptive.isDesktop(context) || route is PopupRoute) {
        final dismissible = route is PopupRoute
            ? route.barrierDismissible
            : true;
        unawaited(
          nav.pushReplacement<void, Object?>(
            DialogRoute<void>(
              context: navContext,
              barrierDismissible: dismissible,
              barrierColor: Colors.black54,
              barrierLabel: MaterialLocalizations.of(
                navContext,
              ).modalBarrierDismissLabel,
              builder: (dialogContext) => Focus(
                autofocus: true,
                onKeyEvent: (_, event) {
                  if (event is KeyDownEvent &&
                      event.logicalKey == LogicalKeyboardKey.escape &&
                      (ModalRoute.of(dialogContext)?.isCurrent ?? true)) {
                    Navigator.of(dialogContext).maybePop();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: Dialog(
                  insetPadding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 24,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: ConstrainedBox(
                    key: const Key('desktop-modal-dialog-surface'),
                    constraints: const BoxConstraints(
                      maxWidth: 560,
                      maxHeight: 740,
                    ),
                    child: RecordDetailPage(recordId: feeParent),
                  ),
                ),
              ),
            ),
          ),
        );
      } else {
        unawaited(
          nav.pushReplacement<void, Object?>(
            MaterialPageRoute<void>(
              builder: (_) => RecordDetailPage(recordId: feeParent),
            ),
          ),
        );
      }
      return;
    }

    final router = GoRouter.maybeOf(context);
    if (router != null) {
      final hasMultipleMatches =
          router.routerDelegate.currentConfiguration.matches.length > 1;
      if (hasMultipleMatches && context.canPop()) {
        context.pushReplacement('/record/$feeParent');
      } else {
        context.push('/record/$feeParent');
      }
      return;
    }

    unawaited(
      Navigator.of(context).pushReplacement<void, Object?>(
        MaterialPageRoute<void>(
          builder: (_) => RecordDetailPage(recordId: feeParent),
        ),
      ),
    );
  }

  void _openEditRecord(String recordId) {
    if (_isImperativeRoute(context)) {
      if (DesktopAdaptive.isDesktop(context)) {
        unawaited(showDesktopRecordEditorDialog(context, recordId: recordId));
      } else {
        unawaited(
          Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => RecordEditorPage(recordId: recordId),
            ),
          ),
        );
      }
      return;
    }
    if (GoRouter.maybeOf(context) != null) {
      unawaited(context.push('/record/$recordId/edit'));
    } else {
      unawaited(
        Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => RecordEditorPage(recordId: recordId),
          ),
        ),
      );
    }
  }

  Future<void> _delete(LedgerRecord r) async {
    final ok = await confirm(
      context,
      title: '删除这笔账单？',
      message: r.type == RecordType.transfer
          ? '转账及其手续费会一并删除，账户余额会恢复。'
          : '删除后账户余额会恢复。',
      ok: '删除',
    );
    if (!ok || !mounted) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final service = await ref.read(ledgerServiceProvider.future);
      await service.deleteRecord(
        commandId: ids.forPayload(['delete', r.recordId]),
        recordId: r.recordId,
      );
      if (mounted) {
        await _popDetailRoute();
      }
    } catch (e) {
      if (mounted) setState(() => error = safeMessage(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _addLink(LedgerRecord r, {required bool refund}) async {
    final allAssets = await _loadEligibleAssets();
    if (!mounted) return;
    final originCurrency = _resolveOriginCurrency(r, allAssets);
    final sameCurrencyAssets = allAssets
        .where(
          (a) =>
              (normalizeCurrency(a.currency) ?? baseCurrency) == originCurrency,
        )
        .toList();
    final currencySymbol = _symbolForCurrency(originCurrency);
    final input = await showDialog<(Money, int)>(
      context: context,
      builder: (_) => _LinkDialog(
        title: refund ? '添加退款' : '登记报销款',
        assets: sameCurrencyAssets,
        initialAsset: refund
            ? (r.type == RecordType.reimbursable ? r.fromAssetId : r.assetId)
            : noRef,
        currencySymbol: currencySymbol,
      ),
    );
    if (input == null || !mounted) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final service = await ref.read(ledgerServiceProvider.future);
      final (amount, assetId) = input;
      final seq = _opSeq++;
      final opTimeMs = DateTime.now().millisecondsSinceEpoch;
      final payload = [
        refund,
        r.recordId,
        amount.toJson(),
        assetId,
        opTimeMs,
        seq,
      ];
      if (refund) {
        await service.addRefund(
          commandId: ids.forPayload(payload),
          originId: r.recordId,
          amount: amount,
          assetId: assetId,
          recordTime: opTimeMs,
        );
      } else {
        await service.addReimbursement(
          commandId: ids.forPayload(payload),
          originId: r.recordId,
          amount: amount,
          assetId: assetId,
          recordTime: opTimeMs,
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = safeMessage(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _settleAdvance(LedgerRecord r) async {
    final allAssets = await _loadEligibleAssets();
    if (!mounted) return;
    final originCurrency = _resolveOriginCurrency(r, allAssets);
    final sameCurrencyAssets = allAssets
        .where(
          (a) =>
              (normalizeCurrency(a.currency) ?? baseCurrency) == originCurrency,
        )
        .toList();
    final currencySymbol = _symbolForCurrency(originCurrency);
    final input = await showDialog<(Money, int, bool)>(
      context: context,
      builder: (_) => _SettleAdvanceDialog(
        isIncome: r.type == RecordType.advanceIncome,
        defaultAmount: formatMinor(r.moneyMinor),
        assets: sameCurrencyAssets,
        initialAsset: r.assetId,
        currencySymbol: currencySymbol,
      ),
    );
    if (input == null || !mounted) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final service = await ref.read(ledgerServiceProvider.future);
      final (amount, assetId, finish) = input;
      final seq = _opSeq++;
      final opTimeMs = DateTime.now().millisecondsSinceEpoch;
      final settledId = await service.settleAdvance(
        commandId: ids.forPayload([
          'settle-advance',
          r.recordId,
          amount.toJson(),
          assetId,
          finish,
          opTimeMs,
          seq,
        ]),
        originId: r.recordId,
        amount: amount,
        assetId: assetId,
        recordTime: opTimeMs,
        finish: finish,
      );
      if (mounted) {
        await _openRelatedRecord(settledId);
      }
    } catch (e) {
      if (mounted) setState(() => error = safeMessage(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget _buildTagActionChip(BuildContext context, Tag t) {
    final tint = parseTagColor(t.color);
    return ActionChip(
      key: Key('detail-tag-${t.tagId}'),
      avatar: tint != null ? TagColorDot(colorHex: t.color, size: 8) : null,
      backgroundColor: tint?.withValues(alpha: 0.14),
      side: tint == null
          ? null
          : BorderSide(color: tint.withValues(alpha: 0.45)),
      label: Text(t.name),
      onPressed: () {
        final router = GoRouter.maybeOf(context);
        if (router == null) return;
        final route = ModalRoute.of(context);
        if (route is PopupRoute && route.settings is! Page) {
          Navigator.of(context).pop();
        }
        router.push('/stats/tag/${t.tagId}');
      },
    );
  }

  Widget _buildAccountTrailing(List<Asset> assets, int id) {
    final asset = id == noRef
        ? null
        : assets.where((a) => a.id == id).firstOrNull;
    if (asset == null) {
      return Text(assetName(assets, id));
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 180),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AssetIconAvatar(
            iconKey: asset.icon,
            colorHex: asset.color,
            name: asset.name,
            assetType: asset.type,
            subType: asset.subType,
            size: 24,
          ),
          const SizedBox(width: 8),
          Flexible(child: Text(asset.name, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final record = ref.watch(recordProvider(widget.recordId));
    final assets = ref.watch(assetsProvider).value ?? const <Asset>[];
    final tags =
        ref.watch(recordTagsProvider(widget.recordId)).value ?? const [];

    Widget? buildReceiptAction() {
      if (record.value == null) return null;
      return IconButton(
        key: const Key('open-receipt-button'),
        tooltip: '生成小票',
        icon: const Icon(Icons.receipt_long_outlined),
        onPressed: busy
            ? null
            : () => showRecordReceiptDialog(
                context,
                recordId: record.value!.recordId,
                initialRecord: record.value,
              ),
      );
    }

    final detailBody = asyncBody(record, (r) {
      if (r == null) return const Center(child: Text('账单不存在或已删除'));
      final categories =
          ref.watch(categoriesProvider(r.accountBookId)).value ?? const [];
      final label = recordLabel(r, categories, assets);
      final feeParent = r.type == RecordType.fee
          ? RecordRelations.parse(r.relInfo).transferFee?.parentId
          : null;
      final generated = feeParent != null && feeParent.isNotEmpty;
      final rel = RecordRelations.parse(r.relInfo);
      final childOf = rel.refunds?.originId ?? rel.reimbursements?.originId;
      final isChild = childOf != null && childOf.isNotEmpty;
      final isAdvance =
          r.type == RecordType.advanceIncome ||
          r.type == RecordType.advanceExpense;
      final advanceSettled =
          isAdvance && RecordExtra.parse(r.extraInfo).advance != null;
      final editable = isRecordEditable(r);
      final refundable =
          !isChild &&
          r.moneyMinor > BigInt.zero &&
          const {
            RecordType.expense,
            RecordType.income,
            RecordType.reimbursable,
          }.contains(r.type);
      final refunded = (rel.refunds?.children ?? const <LinkedBill>[]).fold(
        BigInt.zero,
        (s, c) => s + c.amount,
      );
      final reimbursed = (rel.reimbursements?.children ?? const <LinkedBill>[])
          .fold(BigInt.zero, (s, c) => s + c.amount);
      final cat = r.recordCatId == noRef
          ? null
          : categories.where((c) => c.id == r.recordCatId).firstOrNull;
      final parentCat = (cat != null && cat.parentCatId != noRef)
          ? categories.where((c) => c.id == cat.parentCatId).firstOrNull
          : null;
      final catDisplayName = cat == null
          ? null
          : (parentCat != null ? '${parentCat.name} · ${cat.name}' : cat.name);
      final catColor =
          (cat?.colorFill != null && cat!.colorFill!.trim().isNotEmpty)
          ? cat.colorFill
          : parentCat?.colorFill;
      final isRefund =
          (r.type == RecordType.expense || r.type == RecordType.income) &&
          r.moneyMinor < BigInt.zero;

      return ListView(
        padding: widget.embeddedInPane
            ? const EdgeInsets.fromLTRB(16, 16, 16, 24)
            : const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Card(
            key: const Key('detail-header-card'),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  RecordTypeIconAvatar(
                    recordType: r.type,
                    subType: r.subType,
                    isRefund: isRefund,
                    categoryName: catDisplayName,
                    categoryIcon: cat?.icon,
                    parentCategoryIcon: parentCat?.icon,
                    categoryColor: catColor,
                    size: 46,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(RecordType.names[r.type] ?? '账单'),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(
                            label.amount,
                            key: const Key('detail-amount'),
                            maxLines: 1,
                            softWrap: false,
                            style: theme.textTheme.displaySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Card(
            key: const Key('detail-fields-card'),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ListTile(
                    title: const Text('分类/说明'),
                    trailing: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 180),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          RecordTypeIconAvatar(
                            recordType: r.type,
                            subType: r.subType,
                            isRefund: isRefund,
                            categoryName: catDisplayName,
                            categoryIcon: cat?.icon,
                            parentCategoryIcon: parentCat?.icon,
                            categoryColor: catColor,
                            size: 24,
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              label.title,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (r.type == RecordType.transfer) ...[
                    ListTile(
                      title: const Text('转出'),
                      trailing: _buildAccountTrailing(assets, r.fromAssetId),
                    ),
                    ListTile(
                      title: const Text('转入'),
                      trailing: _buildAccountTrailing(assets, r.toAssetId),
                    ),
                  ] else if (r.type == RecordType.borrowIn ||
                      r.type == RecordType.collect ||
                      (r.type == RecordType.debtInterest &&
                          r.subType == RecordDirection.income)) ...[
                    ListTile(
                      title: const Text('借贷项目'),
                      trailing: _buildAccountTrailing(assets, r.fromAssetId),
                    ),
                    ListTile(
                      title: const Text('资金账户'),
                      trailing: _buildAccountTrailing(assets, r.toAssetId),
                    ),
                  ] else if (r.type == RecordType.lendOut ||
                      r.type == RecordType.repay ||
                      (r.type == RecordType.debtInterest &&
                          r.subType == RecordDirection.expense)) ...[
                    ListTile(
                      title: const Text('资金账户'),
                      trailing: _buildAccountTrailing(assets, r.fromAssetId),
                    ),
                    ListTile(
                      title: const Text('借贷项目'),
                      trailing: _buildAccountTrailing(assets, r.toAssetId),
                    ),
                  ] else
                    ListTile(
                      title: const Text('账户'),
                      trailing: _buildAccountTrailing(
                        assets,
                        r.type == RecordType.reimbursable ||
                                r.type == RecordType.balanceAdjust
                            ? r.fromAssetId
                            : r.assetId,
                      ),
                    ),
                  ListTile(
                    title: const Text('时间'),
                    trailing: Text(
                      formatDateTime(
                        DateTime.fromMillisecondsSinceEpoch(r.recordTime),
                      ),
                    ),
                  ),
                  if (isAdvance)
                    _DetailRow(
                      label: '状态',
                      value: advanceSettled ? '已结算' : '待结算（暂不计入收支与余额）',
                    ),
                  if (tags.isNotEmpty)
                    ListTile(
                      title: const Text('标签'),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final t in tags)
                              _buildTagActionChip(context, t),
                          ],
                        ),
                      ),
                    ),
                  if (r.discountMinor != null && r.discountMinor! > BigInt.zero)
                    ListTile(
                      key: const Key('detail-discount-tile'),
                      title: const Text('优惠'),
                      trailing: Text(formatMinor(r.discountMinor!)),
                    ),
                  if (r.remark.isNotEmpty)
                    ListTile(title: const Text('备注'), subtitle: Text(r.remark)),
                  ...() {
                    BillLocationInfo? loc;
                    try {
                      loc = RecordExtra.parse(r.extraInfo).location;
                    } on Failure {
                      loc = null;
                    }
                    List<String> attached = const <String>[];
                    try {
                      attached = parseRecordImages(r.images);
                    } on Failure {
                      attached = const <String>[];
                    }
                    return <Widget>[
                      if (loc != null && !loc.isEmpty)
                        ListTile(
                          key: const Key('detail-location-tile'),
                          title: const Text('地点'),
                          subtitle: Text(
                            loc.detailAddress == null
                                ? loc.displayLabel
                                : '${loc.displayLabel}（${loc.detailAddress}）',
                          ),
                        ),
                      if (attached.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          child: BillAttachmentStrip(
                            key: const Key('detail-attachment-strip'),
                            recordId: r.recordId,
                            readOnly: true,
                          ),
                        ),
                    ];
                  }(),
                ],
              ),
            ),
          ),
          if (r.excludeExIn ||
              r.excludeBudget ||
              refunded > BigInt.zero ||
              r.type == RecordType.reimbursable) ...[
            const SizedBox(height: 10),
            Card(
              key: const Key('detail-links-card'),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (r.excludeExIn) const ListTile(title: Text('不计入收支')),
                    if (r.excludeBudget) const ListTile(title: Text('不计入预算')),
                    if (refunded > BigInt.zero)
                      ListTile(
                        title: const Text('已退款'),
                        trailing: Text(
                          formatMinor(refunded),
                          key: const Key('refunded'),
                        ),
                      ),
                    if (r.type == RecordType.reimbursable)
                      ListTile(
                        title: const Text('已报销'),
                        subtitle: Text(
                          '待报销 ${formatMinor((r.moneyMinor - refunded - reimbursed) < BigInt.zero ? BigInt.zero : r.moneyMinor - refunded - reimbursed)}',
                        ),
                        trailing: Text(
                          formatMinor(reimbursed),
                          key: const Key('reimbursed'),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
          if (isChild) ...[
            const SizedBox(height: 12),
            TallySoftButton(
              onPressed: () => unawaited(_openRelatedRecord(childOf)),
              child: const Text('查看原账单'),
            ),
          ],
          if (error != null)
            Text(error!, style: TextStyle(color: theme.colorScheme.error)),
          const SizedBox(height: 16),
          if (generated)
            TallySoftButton(
              key: const Key('view-fee-parent'),
              onPressed: () => _openFeeParentRecord(feeParent),
              child: const Text('这是转账手续费，查看所属转账'),
            )
          else ...[
            if (isAdvance && !advanceSettled) ...[
              TallySoftButton(
                key: const Key('settle-advance'),
                onPressed: busy ? null : () => _settleAdvance(r),
                child: const Text('结算转为正式账单'),
              ),
              const SizedBox(height: 10),
            ],
            if (refundable) ...[
              TallySoftButton(
                key: const Key('add-refund'),
                onPressed: busy ? null : () => _addLink(r, refund: true),
                child: const Text('退款'),
              ),
              const SizedBox(height: 10),
            ],
            if (r.type == RecordType.reimbursable) ...[
              TallySoftButton(
                key: const Key('add-reimbursement'),
                onPressed: busy ? null : () => _addLink(r, refund: false),
                child: const Text('登记报销款'),
              ),
              const SizedBox(height: 10),
            ],
            if (editable) ...[
              TallySoftButton(
                key: const Key('edit'),
                onPressed: busy ? null : () => _openEditRecord(r.recordId),
                child: const Text('编辑'),
              ),
              const SizedBox(height: 10),
            ],
            TextButton(
              key: const Key('delete'),
              onPressed: busy ? null : () => _delete(r),
              child: Text(busy ? '删除中…' : '删除'),
            ),
          ],
        ],
      );
    });

    if (widget.embeddedInPane) {
      final receiptAction = buildReceiptAction();
      return Material(
        color: theme.colorScheme.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 52,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '账单详情',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    ?receiptAction,
                    IconButton(
                      key: const Key('close-record-detail-pane'),
                      tooltip: '关闭详情 (Esc)',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: widget.onClosePane,
                    ),
                  ],
                ),
              ),
            ),
            Expanded(child: detailBody),
          ],
        ),
      );
    }

    final receiptAction = buildReceiptAction();
    final isDesktop = DesktopAdaptive.isDesktop(context);
    final route = ModalRoute.of(context);
    final isImperative = route != null && route.settings is! Page;
    final canPopModal = isImperative
        ? Navigator.of(context).canPop()
        : ((GoRouter.maybeOf(context)?.canPop() ?? false) ||
              Navigator.of(context).canPop());
    final isDesktopModal = isDesktop && route is PopupRoute && canPopModal;
    return Scaffold(
      appBar: AppBar(
        leading: isDesktopModal
            ? CloseButton(onPressed: () => unawaited(_popDetailRoute()))
            : null,
        title: const Text('账单详情'),
        actions: [?receiptAction],
      ),
      body: isDesktop
          ? Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: detailBody,
              ),
            )
          : detailBody,
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 56),
            child: Text(label, style: theme.textTheme.bodyLarge),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LinkDialog extends StatefulWidget {
  const _LinkDialog({
    required this.title,
    required this.assets,
    required this.initialAsset,
    this.currencySymbol = '¥',
  });
  final String title;
  final List<Asset> assets;
  final int initialAsset;
  final String currencySymbol;
  @override
  State<_LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends State<_LinkDialog> {
  final amount = TextEditingController();
  late int assetId = widget.assets.any((a) => a.id == widget.initialAsset)
      ? widget.initialAsset
      : noRef;
  String? error;

  @override
  void dispose() {
    amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = DesktopAdaptive.isDesktop(context);
    Widget content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          key: const Key('link-amount'),
          controller: amount,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: _amountInputFormatters,
          decoration: InputDecoration(
            labelText: '金额',
            prefixText: '${widget.currencySymbol} ',
            errorText: error,
          ),
        ),
        const SizedBox(height: 12),
        TallySelectField<int>(
          label: '入账账户',
          value: assetId,
          options: [
            const TallySelectOption<int>(value: noRef, label: '不选账户'),
            for (final a in widget.assets)
              TallySelectOption<int>(value: a.id, label: a.name),
          ],
          onChanged: (v) => setState(() => assetId = v),
        ),
      ],
    );
    content = SizedBox(
      width: isDesktop ? 380 : double.maxFinite,
      child: SingleChildScrollView(child: content),
    );
    return AlertDialog(
      title: Text(widget.title),
      content: content,
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('link-save'),
          onPressed: () {
            try {
              final money = _parseAmount(amount.text);
              if (money.units <= BigInt.zero) {
                setState(() => error = '金额须大于 0');
                return;
              }
              Navigator.pop(context, (money, assetId));
            } catch (e) {
              setState(() => error = safeMessage(e));
            }
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _SettleAdvanceDialog extends StatefulWidget {
  const _SettleAdvanceDialog({
    required this.isIncome,
    required this.defaultAmount,
    required this.assets,
    required this.initialAsset,
    this.currencySymbol = '¥',
  });
  final bool isIncome;
  final String defaultAmount;
  final List<Asset> assets;
  final int initialAsset;
  final String currencySymbol;
  @override
  State<_SettleAdvanceDialog> createState() => _SettleAdvanceDialogState();
}

class _SettleAdvanceDialogState extends State<_SettleAdvanceDialog> {
  late final amount = TextEditingController(text: widget.defaultAmount);
  late int assetId = widget.assets.any((a) => a.id == widget.initialAsset)
      ? widget.initialAsset
      : noRef;
  bool finish = true;
  String? error;

  @override
  void dispose() {
    amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = DesktopAdaptive.isDesktop(context);
    Widget content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          key: const Key('settle-amount'),
          controller: amount,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: _amountInputFormatters,
          decoration: InputDecoration(
            labelText: '实际结算金额',
            prefixText: '${widget.currencySymbol} ',
            errorText: error,
          ),
        ),
        const SizedBox(height: 12),
        TallySelectField<int>(
          label: widget.isIncome ? '收款账户' : '扣款账户',
          value: assetId,
          options: [
            const TallySelectOption<int>(value: noRef, label: '不选账户'),
            for (final a in widget.assets)
              TallySelectOption<int>(value: a.id, label: a.name),
          ],
          onChanged: (v) => setState(() => assetId = v),
        ),
        if (isDesktop) const SizedBox(height: 6),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('结清本笔预收/预支'),
          subtitle: const Text('取消勾选则按部分结算保留剩余待结金额'),
          value: finish,
          onChanged: (v) => setState(() => finish = v ?? true),
        ),
      ],
    );
    content = SizedBox(
      width: isDesktop ? 380 : double.maxFinite,
      child: SingleChildScrollView(child: content),
    );
    return AlertDialog(
      title: Text(widget.isIncome ? '结算预收款' : '结算预支款'),
      content: content,
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('settle-save'),
          onPressed: () {
            try {
              final money = _parseAmount(amount.text);
              if (money.units <= BigInt.zero) {
                setState(() => error = '结算金额须大于 0');
                return;
              }
              Navigator.pop(context, (money, assetId, finish));
            } catch (e) {
              setState(() => error = safeMessage(e));
            }
          },
          child: const Text('确认结算'),
        ),
      ],
    );
  }
}
