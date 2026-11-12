import 'dart:async';

import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/failure.dart';
import '../../core/money.dart';
import '../../data/db/database.dart';
import '../../data/ledger/ledger_service.dart';
import '../../data/repo/ledger_queries.dart';
import '../../domain/ledger/record_extra.dart';
import '../../domain/ledger/record_relations.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/asset_overview.dart'
    show RateTable, normalizeCurrency;
import '../../domain/rules/currency_rates.dart';
import '../../domain/rules/record_keypad_calc.dart';
import '../attachments/attachment_providers.dart';
import '../automation/automation_providers.dart'
    show widgetSnapshotServiceProvider;
import '../budget/budget_widgets.dart';
import '../categories/categories_page.dart';
import '../common/catalog_icons.dart';
import '../common/common.dart';
import '../receipt/diy_toolbar_settings_page.dart';
import '../receipt/receipt_diy_providers.dart';
import '../receipt/record_receipt_dialog.dart' show BillLocationEditorDialog;
import '../tags/tags_page.dart';
import '../templates/template_providers.dart';
import '../templates/templates_page.dart'
    show FrequentRemarkChips, TemplatePrefill, TemplateQuickBar, TemplatesPage;
import 'record_keypad.dart';

/// Original keyboard upper bound (`docs/reference/ledger-catalog.md` §5).
final maxAmount = Money.parse('88888888888.00');

final amountInputFormatters = <TextInputFormatter>[
  FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
];

final _keypadExpressionFormatters = <TextInputFormatter>[
  TextInputFormatter.withFunction((oldValue, newValue) {
    final normalized = newValue.text
        .replaceAll('*', '×')
        .replaceAll('/', '÷')
        .replaceAll('−', '-');
    if (!RegExp(r'^[0-9.+\-×÷]*$').hasMatch(normalized)) {
      return oldValue;
    }
    if (normalized == newValue.text) return newValue;
    return newValue.copyWith(
      text: normalized,
      selection: TextSelection.collapsed(
        offset: newValue.selection.end.clamp(0, normalized.length),
      ),
    );
  }),
];

Money parseAmount(String text) {
  final t = text.trim();
  if (t.isEmpty) return Money.zero();
  final normalized = t.endsWith('.') ? t.substring(0, t.length - 1) : t;
  final money = Money.parse(
    normalized.startsWith('.') ? '0$normalized' : normalized,
  );
  if (money.units > maxAmount.units) {
    throw const Failure(FailureCode.validation, '金额不能超过 88888888888.00');
  }
  return money;
}

class RecordEditorPage extends ConsumerStatefulWidget {
  const RecordEditorPage({
    super.key,
    this.recordId,
    this.initialType,
    this.initialCategory,
    this.initialTemplateId,
    this.initialAsset,
    this.initialFrom,
    this.initialTo,
    this.initialAmount,
    this.initialRemark,
  });

  final String? recordId;
  final int? initialType;
  final int? initialCategory;
  final int? initialTemplateId;

  /// Prefill for new bills (e.g. "还款" from a credit card opens a transfer).
  final int? initialAsset;
  final int? initialFrom;
  final int? initialTo;
  final String? initialAmount;
  final String? initialRemark;

  @override
  ConsumerState<RecordEditorPage> createState() => _RecordEditorPageState();
}

class _RecordEditorPageState extends ConsumerState<RecordEditorPage> {
  final amount = TextEditingController();
  final converted = TextEditingController();
  final discount = TextEditingController();
  final fee = TextEditingController();
  final remark = TextEditingController();
  final _discountFocus = FocusNode();
  final ids = CommandIds();
  final imageIds = CommandIds();
  final remarkIds = CommandIds();

  int _draftNonce = 0;
  int? _resolvedBookId;
  int type = RecordType.expense;
  int? categoryId;
  int? parentCatId;
  Set<String> selectedTagIds = {};
  List<String> imageNames = const <String>[];
  BillLocationInfo? location;
  int assetId = noRef, fromAssetId = noRef, toAssetId = noRef;

  /// Currency the amount is entered in; null = the account currency.
  String? sourceCurrency;

  /// The user typed the converted amount themselves (stop auto-filling).
  bool convertedEdited = false;
  bool feeFromTarget = false;
  bool excludeBudget = false, excludeExIn = false;
  bool _attachmentsExpanded = false;
  bool _keypadVisible = true;
  DateTime time = DateTime.now();
  LedgerRecord? original;
  bool loading = true, busy = false;
  String? error;

  bool get editing => widget.recordId != null;

  /// Direct one-shot lookup of the active book id on [db] (`ti_preference`
  /// `'current_book_id'` -> fallback first `account_book` row -> `1`), avoiding
  /// cold-start `StreamProvider.future` waits.
  Future<int> _readCurrentBookId(AppDatabase db) async {
    final pref = await (db.select(
      db.preferences,
    )..where((t) => t.key.equals('current_book_id'))).getSingleOrNull();
    final parsed = int.tryParse(pref?.value ?? '');
    if (parsed != null && parsed > 0) {
      final exists = await (db.select(
        db.accountBooks,
      )..where((t) => t.id.equals(parsed))).getSingleOrNull();
      if (exists != null) return parsed;
    }
    final firstBook =
        await (db.select(db.accountBooks)
              ..orderBy([
                (t) => OrderingTerm.asc(t.sort),
                (t) => OrderingTerm.asc(t.id),
              ])
              ..limit(1))
            .getSingleOrNull();
    return firstBook?.id ?? 1;
  }

  String _currencyOf(int id) {
    if (id == noRef) return baseCurrency;
    final assets = ref.read(assetsProvider).value ?? const <Asset>[];
    final a = assets.where((x) => x.id == id).firstOrNull;
    return normalizeCurrency(a?.currency) ?? baseCurrency;
  }

  /// (entered currency, booked currency) for the current form.
  (String, String) _currencies() {
    if (type == RecordType.transfer) {
      return (_currencyOf(fromAssetId), _currencyOf(toAssetId));
    }
    final ac = _currencyOf(assetId);
    return (sourceCurrency ?? ac, ac);
  }

  /// Fills [converted] from manual rates using exact calculator evaluation
  /// unless the user edited [converted] manually.
  void _autoConvert() {
    if (convertedEdited) return;
    final (sc, ac) = _currencies();
    if (sc == ac) {
      converted.text = '';
      return;
    }
    final rates = ref.read(rateTableProvider).value;
    final text = amount.text.trim();
    if (rates == null || text.isEmpty) {
      converted.text = '';
      return;
    }
    try {
      final minor = evaluateKeypadExpression(text).clampedMinor;
      converted.text = formatMinor(rates.convert(minor, sc, ac));
    } on Failure {
      converted.text = '';
    }
  }

  void _applyTemplatePrefill(TemplatePrefill prefill) {
    setState(() {
      type = prefill.type;
      categoryId = prefill.categoryId;
      parentCatId = prefill.parentCategoryId;
      assetId = prefill.assetId;
      fromAssetId = prefill.fromAssetId;
      toAssetId = prefill.toAssetId;
      amount.text = prefill.amountText;
      fee.text = prefill.feeText;
      feeFromTarget = prefill.feeFromTarget;
      remark.text = prefill.remark;
      excludeBudget = prefill.excludeBudget;
      excludeExIn = prefill.excludeExIn;
      selectedTagIds = prefill.tagIds.toSet();
      sourceCurrency = prefill.sourceCurrency;
      convertedEdited = false;
      _autoConvert();
    });
  }

  Future<void> _pickLocation() async {
    final res = await showDialog<BillLocationInfo>(
      context: context,
      builder: (_) => BillLocationEditorDialog(initial: location),
    );
    if (res == null || !mounted) return;
    setState(() => location = res.isEmpty ? null : res);
  }

  @override
  void initState() {
    super.initState();
    type = widget.initialType ?? RecordType.expense;
    categoryId = widget.initialCategory;
    assetId = widget.initialAsset ?? noRef;
    fromAssetId = widget.initialFrom ?? noRef;
    toAssetId = widget.initialTo ?? noRef;
    if (widget.initialAmount != null) amount.text = widget.initialAmount!;
    if (widget.initialRemark != null) remark.text = widget.initialRemark!;
    unawaited(_load());
  }

  Future<void> _loadExisting(AppDatabase db, String id) async {
    final r = await (db.select(
      db.records,
    )..where((t) => t.recordId.equals(id))).getSingleOrNull();
    if (r == null) {
      throw const Failure(FailureCode.conflict, '账单不存在或已删除');
    }
    if (!const {
      RecordType.expense,
      RecordType.income,
      RecordType.transfer,
      RecordType.reimbursable,
      RecordType.advanceIncome,
      RecordType.advanceExpense,
    }.contains(r.type)) {
      throw const Failure(FailureCode.validation, '该类型账单不支持在此编辑，请前往对应功能模块管理');
    }

    final feeRow = await LedgerQueries(db).feeChildOf(r.recordId);
    final tagRows = await (db.select(
      db.tagRecords,
    )..where((t) => t.recordId.equals(r.recordId))).get();

    original = r;
    _resolvedBookId = r.accountBookId;
    type = r.type;
    categoryId = r.recordCatId == noRef ? null : r.recordCatId;
    assetId = r.type == RecordType.reimbursable ? r.fromAssetId : r.assetId;
    fromAssetId = r.fromAssetId;
    toAssetId = r.toAssetId;
    amount.text = formatMinor(r.moneyMinor);
    if (r.discountMinor != null && r.discountMinor! > BigInt.zero) {
      discount.text = formatMinor(r.discountMinor!);
    }
    remark.text = r.remark;
    excludeBudget = r.excludeBudget;
    excludeExIn = r.excludeExIn;
    time = DateTime.fromMillisecondsSinceEpoch(r.recordTime);
    try {
      imageNames = parseRecordImages(r.images);
    } on Failure {
      imageNames = const <String>[];
    }
    _attachmentsExpanded = imageNames.isNotEmpty;

    final parsedExtra = RecordExtra.parse(r.extraInfo);
    try {
      location = parsedExtra.location;
    } on Failure {
      location = null;
    }
    final snap = parsedExtra.currency;
    if (snap != null && snap.isValid && snap.assetNet != null) {
      final sc = normalizeCurrency(snap.sourceCode) ?? baseCurrency;
      final ac = normalizeCurrency(snap.assetCode) ?? baseCurrency;
      if (r.type == RecordType.transfer) {
        if (sc != ac) {
          converted.text = formatMinor(snap.assetNet!);
          convertedEdited = true;
        }
      } else if (sc != ac) {
        sourceCurrency = sc;
        amount.text = formatMinor(snap.sourceGross);
        converted.text = formatMinor(snap.assetNet!);
        convertedEdited = true;
      }
    }
    if (feeRow != null) {
      fee.text = formatMinor(feeRow.moneyMinor);
      feeFromTarget =
          RecordRelations.parse(r.relInfo).transferFee?.feeFromTarget ?? false;
      if (feeRow.recordTime == r.recordTime + 1) {
        time = DateTime.fromMillisecondsSinceEpoch(r.recordTime);
      } else {
        time = DateTime.fromMillisecondsSinceEpoch(feeRow.recordTime);
      }
    }
    selectedTagIds = {for (final row in tagRows) row.tagId};
  }

  Future<void> _load() async {
    try {
      final db = await ref.read(databaseProvider.future);
      if (editing) {
        await _loadExisting(db, widget.recordId!);
      } else {
        _resolvedBookId = await _readCurrentBookId(db);
        if (widget.initialTemplateId != null) {
          final tplSvc = await ref.read(templateRemarkServiceProvider.future);
          final prefill = await tplSvc.buildTemplatePrefill(
            widget.initialTemplateId!,
          );
          if (mounted) _applyTemplatePrefill(prefill);
        }
      }
    } catch (e) {
      error = safeMessage(e);
    }
    if (mounted) setState(() => loading = false);
  }

  @override
  void dispose() {
    amount.dispose();
    converted.dispose();
    discount.dispose();
    fee.dispose();
    remark.dispose();
    _discountFocus.dispose();
    super.dispose();
  }

  void _handleKeypadTap(String key) {
    if (busy) return;
    final next = applyKeypadKey(amount.text, key);
    setState(() {
      error = null;
      amount.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: next.length),
      );
      _autoConvert();
    });
  }

  Future<void> _save({required bool stayAndReset}) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final db = await ref.read(databaseProvider.future);
      final old = original;
      final int bookId = old != null
          ? old.accountBookId
          : await _readCurrentBookId(db);

      // Auto-evaluate any pending expression (e.g. `12+8` -> `20.00`) or
      // trailing operator (`12.5+` -> `12.50`) before validating & saving.
      final money = confirmKeypadAmount(amount.text);
      if (amount.text.trim().isNotEmpty) {
        amount.value = TextEditingValue(
          text: money.decimal,
          selection: TextSelection.collapsed(offset: money.decimal.length),
        );
      }

      if (type == RecordType.transfer) {
        if (money.units <= BigInt.zero) {
          throw const Failure(FailureCode.validation, '转账金额须大于 0');
        }
      } else {
        if (categoryId == null) {
          throw const Failure(FailureCode.validation, '请选择分类');
        }
        if (type == RecordType.reimbursable ||
            type == RecordType.advanceIncome ||
            type == RecordType.advanceExpense) {
          if (money.units <= BigInt.zero) {
            throw const Failure(FailureCode.validation, '金额须大于 0');
          }
        } else if (money.isZero) {
          if (!mounted) return;
          final ok = await confirm(
            context,
            title: '金额为 0',
            message: '确定保存一笔 0.00 的账单吗？',
          );
          if (!ok || !mounted) return;
        }
      }

      final keepOldExtra = original != null && original!.type == type
          ? original
          : null;
      final extra = RecordExtra.parse(keepOldExtra?.extraInfo);
      extra.location = location;

      final parsedDiscount =
          (type == RecordType.expense || type == RecordType.income) &&
              discount.text.trim().isNotEmpty
          ? parseAmount(discount.text)
          : null;
      final effectiveDiscount = parsedDiscount != null && !parsedDiscount.isZero
          ? parsedDiscount
          : null;

      // Multi-currency (`ledger-catalog.md` §4 `curr`) via direct DB read.
      final (sc, ac) = _currencies();
      var booked = money;
      if (sc != ac) {
        final currencyRows = await db.select(db.currencies).get();
        final rates = RateTable({
          for (final c in currencyRows) c.code: c.rateToAnchor,
        });
        final text = converted.text.trim();
        final target = text.isEmpty
            ? Money.minor(rates.convert(money.storageMinor, sc, ac))
            : parseAmount(text);
        if (!money.isZero && target.units <= BigInt.zero) {
          throw const Failure(FailureCode.validation, '折算金额须大于 0');
        }
        if (type != RecordType.transfer) booked = target;
        extra.currency = billSnapshot(
          source: sc,
          sourceMinor: money.storageMinor,
          account: ac,
          assetMinor: target.storageMinor,
          rates: rates,
        );
      } else if (sc != baseCurrency) {
        final currencyRows = await db.select(db.currencies).get();
        final rates = RateTable({
          for (final c in currencyRows) c.code: c.rateToAnchor,
        });
        extra.currency = billSnapshot(
          source: sc,
          sourceMinor: money.storageMinor,
          account: ac,
          assetMinor: money.storageMinor,
          rates: rates,
        );
      } else {
        extra.currency = null;
      }

      final draft = RecordDraft(
        type: type,
        money: booked,
        bookId: bookId,
        recordTime: time.millisecondsSinceEpoch,
        categoryId: type == RecordType.transfer ? noRef : categoryId!,
        assetId:
            (type == RecordType.transfer || type == RecordType.reimbursable)
            ? noRef
            : assetId,
        fromAssetId: type == RecordType.transfer
            ? fromAssetId
            : (type == RecordType.reimbursable ? assetId : noRef),
        toAssetId: type == RecordType.transfer ? toAssetId : noRef,
        remark: remark.text.trim(),
        excludeBudget: excludeBudget,
        excludeExIn: excludeExIn,
        discount: effectiveDiscount,
        extra: extra,
        relations: RecordRelations.parse(keepOldExtra?.relInfo),
        fee: type == RecordType.transfer ? parseAmount(fee.text) : null,
        feeFromTarget: feeFromTarget,
        tagIds: selectedTagIds.toList(),
      );

      final service = LedgerService(db);
      final id = await service.saveRecord(
        commandId: ids.forPayload([
          _draftNonce,
          widget.recordId,
          ...draft.payload,
        ]),
        recordId: widget.recordId,
        draft: draft,
      );

      List<String> oldImages = const <String>[];
      if (old != null) {
        try {
          oldImages = parseRecordImages(old.images);
        } on Failure {
          oldImages = const <String>[];
        }
      }
      if (imageNames.isNotEmpty || oldImages.isNotEmpty) {
        final attSvc = await ref.read(billAttachmentServiceProvider.future);
        await attSvc.setRecordImages(
          commandId: imageIds.forPayload([
            'editor-images',
            _draftNonce,
            id,
            imageNames,
          ]),
          recordId: id,
          imageNames: imageNames,
        );
      }

      if (type != RecordType.transfer && draft.remark.isNotEmpty) {
        try {
          final remarkSvc = await ref.read(
            templateRemarkServiceProvider.future,
          );
          await remarkSvc.recordRemarkUsage(
            commandId: remarkIds.forPayload([
              'editor-remark-usage',
              _draftNonce,
              id,
              draft.categoryId,
              draft.remark,
            ]),
            recordCatId: draft.categoryId,
            content: draft.remark,
          );
          if (mounted) {
            ref.invalidate(remarksForCategoryProvider(draft.categoryId));
            ref.invalidate(allRemarksProvider);
          }
        } catch (_) {
          // Non-blocking frequent-remark counter update.
        }
      }

      try {
        final widgetSvc = await ref.read(widgetSnapshotServiceProvider.future);
        await widgetSvc.syncToPlatform();
      } catch (_) {
        // Non-blocking desktop widget refresh.
      }

      if (!mounted) return;
      if (stayAndReset && !editing) {
        setState(() {
          _draftNonce++;
          amount.clear();
          converted.clear();
          convertedEdited = false;
          discount.clear();
          fee.clear();
          remark.clear();
          imageNames = const <String>[];
          location = null;
          _attachmentsExpanded = false;
          error = null;
        });
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            const SnackBar(
              content: Text('已保存，可继续记下一笔'),
              duration: Duration(seconds: 2),
            ),
          );
        return;
      }

      final router = GoRouter.maybeOf(context);
      if (router != null) {
        if (context.canPop()) {
          context.pop(id);
        } else {
          context.go('/');
        }
      } else if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop(id);
      }
    } catch (e) {
      if (mounted) setState(() => error = safeMessage(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _pickTime() async {
    final date = await showDatePicker(
      context: context,
      initialDate: time,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (date == null || !mounted) return;
    final clock = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(time),
    );
    if (!mounted) return;
    setState(() {
      time = DateTime(
        date.year,
        date.month,
        date.day,
        clock?.hour ?? time.hour,
        clock?.minute ?? time.minute,
      );
    });
  }

  String _formatDatePillLabel(DateTime dt) {
    final now = DateTime.now();
    final hhmm = '${two(dt.hour)}:${two(dt.minute)}';
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return '今天 $hhmm';
    }
    if (dt.year == now.year) {
      return '${two(dt.month)}-${two(dt.day)} $hhmm';
    }
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} $hhmm';
  }

  void _openCategoriesManager() {
    if (GoRouter.maybeOf(context) != null) {
      unawaited(context.push('/categories'));
    } else {
      unawaited(
        Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const CategoriesPage())),
      );
    }
  }

  void _openTagsManager() {
    if (GoRouter.maybeOf(context) != null) {
      unawaited(context.push('/tags'));
    } else {
      unawaited(
        Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const TagsPage())),
      );
    }
  }

  void _openTemplatesManager() {
    if (GoRouter.maybeOf(context) != null) {
      unawaited(context.push('/templates'));
    } else {
      unawaited(
        Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const TemplatesPage())),
      );
    }
  }

  Future<void> _openAccountPickerSheet({
    required String title,
    required List<Asset> assets,
    required int currentId,
    required bool allowNone,
    required ValueChanged<int> onSelected,
  }) async {
    final chosen = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      sheetAnimationStyle: AnimationStyle.noAnimation,
      builder: (sheetCtx) {
        final cs = Theme.of(sheetCtx).colorScheme;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(sheetCtx).height * 0.65,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Row(
                    children: [
                      Text(
                        title,
                        style: Theme.of(sheetCtx).textTheme.titleMedium,
                      ),
                      const Spacer(),
                      if (GoRouter.maybeOf(context) != null)
                        TextButton.icon(
                          onPressed: () {
                            Navigator.pop(sheetCtx);
                            unawaited(context.push('/assets'));
                          },
                          icon: const Icon(Icons.settings_outlined, size: 16),
                          label: const Text('管理账户'),
                        ),
                    ],
                  ),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      if (allowNone)
                        ListTile(
                          leading: Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: cs.surfaceContainerHighest,
                              shape: BoxShape.circle,
                            ),
                            alignment: Alignment.center,
                            child: Icon(
                              Icons.remove_circle_outline_rounded,
                              size: 18,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                          title: const Text('不选账户'),
                          trailing: currentId == noRef
                              ? Icon(Icons.check_rounded, color: cs.primary)
                              : null,
                          onTap: () => Navigator.pop(sheetCtx, noRef),
                        ),
                      for (final a in assets)
                        ListTile(
                          leading: AssetIconAvatar(
                            iconKey: a.icon,
                            colorHex: a.color,
                            name: a.name,
                            assetType: a.type,
                            subType: a.subType,
                            size: 36,
                            selected: currentId == a.id,
                          ),
                          title: Text(a.name),
                          subtitle: Text(
                            '${normalizeCurrency(a.currency) ?? baseCurrency} · ${formatMinor(a.balanceMinor)}',
                            style: const TextStyle(fontSize: 12),
                          ),
                          trailing: currentId == a.id
                              ? Icon(Icons.check_rounded, color: cs.primary)
                              : null,
                          onTap: () => Navigator.pop(sheetCtx, a.id),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (chosen == null || !mounted) return;
    onSelected(chosen);
  }

  Future<void> _openTagPickerSheet(List<Tag> tags) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      sheetAnimationStyle: AnimationStyle.noAnimation,
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (sheetCtx, setSheetState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Text(
                          '选择标签',
                          style: Theme.of(sheetCtx).textTheme.titleMedium,
                        ),
                        const Spacer(),
                        TextButton.icon(
                          key: const Key('manage-tags-sheet-btn'),
                          onPressed: () {
                            Navigator.pop(sheetCtx);
                            _openTagsManager();
                          },
                          icon: const Icon(Icons.sell_outlined, size: 16),
                          label: const Text('管理标签'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (tags.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Text(
                          '暂无可用标签，可点击右上角“管理标签”新建。',
                          textAlign: TextAlign.center,
                        ),
                      )
                    else
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: MediaQuery.sizeOf(sheetCtx).height * 0.45,
                        ),
                        child: SingleChildScrollView(
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final t in tags)
                                FilterChip(
                                  key: Key('tag-${t.name}'),
                                  label: Text(t.name),
                                  selected: selectedTagIds.contains(t.tagId),
                                  onSelected: (sel) {
                                    setState(() {
                                      if (sel) {
                                        selectedTagIds.add(t.tagId);
                                      } else {
                                        selectedTagIds.remove(t.tagId);
                                      }
                                    });
                                    setSheetState(() {});
                                  },
                                ),
                            ],
                          ),
                        ),
                      ),
                    const SizedBox(height: 12),
                    FilledButton.tonal(
                      onPressed: () => Navigator.pop(sheetCtx),
                      child: const Text('完成'),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _openCurrencyPickerSheet(List<Currency> currencies) async {
    final current = _currencies().$1;
    final chosen = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      sheetAnimationStyle: AnimationStyle.noAnimation,
      builder: (sheetCtx) {
        final cs = Theme.of(sheetCtx).colorScheme;
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  '选择入账币种',
                  style: Theme.of(sheetCtx).textTheme.titleMedium,
                ),
              ),
              for (final c in currencies)
                ListTile(
                  key: Key('currency-option-${c.code}'),
                  leading: CircleAvatar(
                    radius: 15,
                    backgroundColor: cs.secondaryContainer,
                    child: Text(
                      c.symbol,
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSecondaryContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  title: Text('${c.code} · ${c.name}'),
                  trailing: current == c.code
                      ? Icon(Icons.check_rounded, color: cs.primary)
                      : null,
                  onTap: () => Navigator.pop(sheetCtx, c.code),
                ),
            ],
          ),
        );
      },
    );
    if (chosen == null || !mounted) return;
    setState(() {
      sourceCurrency = chosen;
      convertedEdited = false;
      _autoConvert();
    });
  }

  @override
  Widget build(BuildContext context) {
    final bookId =
        original?.accountBookId ??
        ref.watch(currentBookIdProvider).value ??
        _resolvedBookId;
    final categories = bookId == null
        ? const <RecordCategory>[]
        : ref.watch(categoriesProvider(bookId)).value ?? const [];
    final assets = (ref.watch(assetsProvider).value ?? const <Asset>[])
        .where(
          (a) => a.status != AssetStatus.settled && a.type != AssetType.debt,
        )
        .toList();
    final tags = (ref.watch(activeTagsProvider).value ?? const <Tag>[])
        .where((t) => t.parent != 1)
        .toList();
    final currencies =
        [...(ref.watch(currenciesProvider).value ?? const <Currency>[])]..sort(
          (a, b) => a.code == b.code
              ? 0
              : a.code == baseCurrency
              ? -1
              : b.code == baseCurrency
              ? 1
              : a.code.compareTo(b.code),
        );
    ref.watch(rateTableProvider);
    final diyConfig =
        ref.watch(diyToolbarConfigProvider).value ??
        DiyToolbarConfig.defaults();

    final canSubmit = !busy && !loading && (!editing || original != null);

    return PopScope(
      canPop: !busy,
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        appBar: AppBar(
          toolbarHeight: 48,
          title: Text(editing ? '编辑账单' : '记一笔'),
          actions: [
            if (!editing && diyConfig.isEnabled(DiyToolbarAction.templates))
              IconButton(
                key: const Key('editor-templates-btn'),
                tooltip: '账单模板',
                icon: const Icon(Icons.bookmarks_outlined, size: 21),
                onPressed: busy ? null : _openTemplatesManager,
              ),
            IconButton(
              key: const Key('editor-diy-toolbar-btn'),
              tooltip: '记账工具栏自定义',
              icon: const Icon(Icons.tune, size: 21),
              onPressed: busy
                  ? null
                  : () {
                      if (GoRouter.maybeOf(context) != null) {
                        unawaited(context.push('/settings/diy-toolbar'));
                      } else {
                        unawaited(
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const DiyToolbarSettingsPage(),
                            ),
                          ),
                        );
                      }
                    },
            ),
            IconButton(
              key: const Key('editor-quick-save-btn'),
              tooltip: '保存',
              icon: const Icon(Icons.check_rounded, size: 22),
              onPressed: canSubmit
                  ? () => unawaited(_save(stayAndReset: false))
                  : null,
            ),
          ],
        ),
        body: loading
            ? const Loading()
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 680),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Zone 1: Compact Type Bar (primary tabs + secondary pills)
                      _buildTypeSwitcherBar(context),
                      // Zone 2: Scrollable Visual Category Grid or Transfer Card
                      Expanded(
                        child: _buildScrollableMiddleZone(
                          context,
                          bookId: bookId,
                          categories: categories,
                          assets: assets,
                          diyConfig: diyConfig,
                        ),
                      ),
                      // Zone 3: Bottom Integrated Dock + Calculator Keypad
                      _buildBottomDock(
                        context,
                        bookId: bookId,
                        assets: assets,
                        tags: tags,
                        currencies: currencies,
                        diyConfig: diyConfig,
                        canSubmit: canSubmit,
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  Widget _buildTypeSwitcherBar(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    ChoiceChip buildChip(int value, String label, {required bool primary}) {
      final selected = type == value;
      return ChoiceChip(
        key: Key('type-$value'),
        showCheckmark: false,
        visualDensity: primary
            ? const VisualDensity(horizontal: -1, vertical: -2)
            : const VisualDensity(horizontal: -2, vertical: -3),
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: EdgeInsets.symmetric(horizontal: primary ? 8 : 5, vertical: 0),
        shape: const StadiumBorder(),
        side: BorderSide(
          color: selected
              ? Colors.transparent
              : cs.outlineVariant.withAlpha(primary ? 130 : 80),
          width: 0.7,
        ),
        selectedColor: primary ? cs.primary : cs.secondaryContainer,
        backgroundColor: primary
            ? cs.surfaceContainerLow
            : cs.surfaceContainerLowest,
        labelStyle: TextStyle(
          fontSize: primary ? 13 : 11.5,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          color: selected
              ? (primary ? cs.onPrimary : cs.onSecondaryContainer)
              : (primary ? cs.onSurface : cs.onSurfaceVariant),
        ),
        label: Text(label),
        selected: selected,
        onSelected: busy || editing
            ? null
            : (_) => setState(() {
                type = value;
                categoryId = null;
                parentCatId = null;
              }),
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: cs.outlineVariant.withAlpha(100),
            width: 0.6,
          ),
        ),
      ),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          buildChip(RecordType.expense, '支出', primary: true),
          buildChip(RecordType.income, '收入', primary: true),
          buildChip(RecordType.transfer, '转账', primary: true),
          Container(
            width: 1,
            height: 16,
            margin: const EdgeInsets.symmetric(horizontal: 2),
            color: cs.outlineVariant,
          ),
          buildChip(RecordType.reimbursable, '报销', primary: false),
          buildChip(RecordType.advanceExpense, '预支', primary: false),
          buildChip(RecordType.advanceIncome, '预收', primary: false),
        ],
      ),
    );
  }

  Widget _buildScrollableMiddleZone(
    BuildContext context, {
    required int? bookId,
    required List<RecordCategory> categories,
    required List<Asset> assets,
    required DiyToolbarConfig diyConfig,
  }) {
    if (categoryId != null && parentCatId == null) {
      final chosen = categories.where((c) => c.id == categoryId).firstOrNull;
      if (chosen != null) {
        if (chosen.parentCatId == noRef || chosen.parentCatId == -1) {
          parentCatId = chosen.id;
        } else {
          parentCatId = chosen.parentCatId;
        }
      }
    }

    final wantCatType =
        (type == RecordType.income || type == RecordType.advanceIncome)
        ? RecordType.income
        : RecordType.expense;
    final topCats = categories
        .where(
          (c) => c.type == wantCatType && !c.isHide && c.parentCatId == noRef,
        )
        .toList();
    final selectedParent = parentCatId == null
        ? null
        : topCats.where((c) => c.id == parentCatId).firstOrNull;
    final subCats = parentCatId == null
        ? const <RecordCategory>[]
        : categories
              .where((c) => c.parentCatId == parentCatId && !c.isHide)
              .toList();

    return CustomScrollView(
      key: const Key('editor-zone2-scroll'),
      slivers: [
        if (!editing &&
            bookId != null &&
            diyConfig.isEnabled(DiyToolbarAction.templates))
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            sliver: SliverToBoxAdapter(
              child: TemplateQuickBar(
                bookId: bookId,
                recordType: type,
                enabled: !busy,
                recordTimeMs: time.millisecondsSinceEpoch,
                onPrefill: _applyTemplatePrefill,
                onInstantSaved: (savedId) {
                  if (!mounted) return;
                  final router = GoRouter.maybeOf(context);
                  if (router != null) {
                    if (context.canPop()) {
                      context.pop(savedId);
                    } else {
                      context.go('/');
                    }
                  } else if (Navigator.of(context).canPop()) {
                    Navigator.of(context).pop(savedId);
                  }
                },
              ),
            ),
          ),
        if (type == RecordType.transfer)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            sliver: SliverToBoxAdapter(
              child: _buildTransferCard(context, assets),
            ),
          )
        else ...[
          if (subCats.isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              sliver: SliverToBoxAdapter(
                child: RecordSubcategoryStrip(
                  parentCategory: selectedParent,
                  subCategories: subCats,
                  selectedCategoryId: categoryId,
                  enabled: !busy,
                  onSelectCategoryId: (id) => setState(() => categoryId = id),
                ),
              ),
            ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
            sliver: RecordCategorySliverGrid(
              categories: topCats,
              selectedParentId: parentCatId,
              enabled: !busy,
              onSelectCategory: (cat) => setState(() {
                parentCatId = cat.id;
                categoryId = cat.id;
              }),
              onManageCategories: _openCategoriesManager,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildTransferCard(BuildContext context, List<Asset> assets) {
    final cs = Theme.of(context).colorScheme;
    final fromAsset = assets.where((a) => a.id == fromAssetId).firstOrNull;
    final toAsset = assets.where((a) => a.id == toAssetId).firstOrNull;

    Widget accountSlot({
      required Key key,
      required String roleLabel,
      required Asset? asset,
      required String sheetTitle,
      required ValueChanged<int> onPick,
    }) {
      return Expanded(
        child: Material(
          color: cs.surfaceContainerLow,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: key,
            onTap: busy
                ? null
                : () => unawaited(
                    _openAccountPickerSheet(
                      title: sheetTitle,
                      assets: assets,
                      currentId: asset?.id ?? noRef,
                      allowNone: false,
                      onSelected: (v) => setState(() {
                        onPick(v);
                        convertedEdited = false;
                        _autoConvert();
                      }),
                    ),
                  ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      if (asset != null)
                        AssetIconAvatar(
                          iconKey: asset.icon,
                          colorHex: asset.color,
                          name: asset.name,
                          assetType: asset.type,
                          subType: asset.subType,
                          size: 18,
                        )
                      else
                        Icon(
                          Icons.account_balance_wallet_outlined,
                          size: 15,
                          color: cs.primary,
                        ),
                      const SizedBox(width: 4),
                      Text(
                        roleLabel,
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    asset?.name ?? '选择账户',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: asset == null ? cs.outline : cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    asset == null
                        ? '点击选择'
                        : '${normalizeCurrency(asset.currency) ?? baseCurrency} ${formatMinor(asset.balanceMinor)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (assets.length < 2)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: cs.secondaryContainer.withAlpha(110),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Text(
              '转账至少需要两个账户，请先在“资产”页添加账户。',
              style: TextStyle(fontSize: 12),
            ),
          ),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: cs.outlineVariant.withAlpha(140)),
          ),
          child: Row(
            children: [
              accountSlot(
                key: const Key('from'),
                roleLabel: '转出账户',
                asset: fromAsset,
                sheetTitle: '选择转出账户',
                onPick: (v) => fromAssetId = v,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: IconButton.filledTonal(
                  key: const Key('transfer-swap-btn'),
                  tooltip: '互换转出与转入账户',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.swap_horiz_rounded, size: 20),
                  onPressed: busy
                      ? null
                      : () => setState(() {
                          final tmp = fromAssetId;
                          fromAssetId = toAssetId;
                          toAssetId = tmp;
                          convertedEdited = false;
                          _autoConvert();
                        }),
                ),
              ),
              accountSlot(
                key: const Key('to'),
                roleLabel: '转入账户',
                asset: toAsset,
                sheetTitle: '选择转入账户',
                onPick: (v) => toAssetId = v,
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 42,
                child: TextField(
                  key: const Key('fee'),
                  controller: fee,
                  enabled: !busy,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: amountInputFormatters,
                  style: const TextStyle(fontSize: 14),
                  decoration: InputDecoration(
                    labelText: '手续费（可选）',
                    prefixText:
                        '${feeFromTarget ? _currencies().$2 : _currencies().$1} ',
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilterChip(
              key: const Key('transfer-fee-side-toggle'),
              visualDensity: VisualDensity.compact,
              label: Text(
                feeFromTarget ? '转入方扣费' : '转出方扣费',
                style: const TextStyle(fontSize: 12),
              ),
              selected: feeFromTarget,
              onSelected: busy
                  ? null
                  : (v) => setState(() => feeFromTarget = v),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildBottomDock(
    BuildContext context, {
    required int? bookId,
    required List<Asset> assets,
    required List<Tag> tags,
    required List<Currency> currencies,
    required DiyToolbarConfig diyConfig,
    required bool canSubmit,
  }) {
    final cs = Theme.of(context).colorScheme;
    final (sc, ac) = _currencies();
    final pendingOp = hasPendingOperator(amount.text);
    String? livePreview;
    if (pendingOp) {
      try {
        livePreview = evaluateKeypadExpression(amount.text).formatted;
      } on Failure {
        livePreview = null;
      }
    }

    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: cs.surface,
          border: Border(
            top: BorderSide(
              color: cs.outlineVariant.withAlpha(130),
              width: 0.8,
            ),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(10),
              blurRadius: 8,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Live budget hint bar (0px when no budget set)
            if (bookId != null &&
                categoryId != null &&
                (type == RecordType.expense ||
                    type == RecordType.income ||
                    type == RecordType.reimbursable))
              RecordBudgetHintBar(
                bookId: bookId,
                recordTime: time.millisecondsSinceEpoch,
                categoryId: categoryId!,
                excludeBudget: excludeBudget,
              ),

            // Validation / conflict error banner
            if (error != null)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 5,
                ),
                color: cs.errorContainer.withAlpha(180),
                child: Row(
                  children: [
                    Icon(Icons.error_outline, size: 15, color: cs.error),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        error!,
                        key: const Key('form-error'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: cs.error),
                      ),
                    ),
                    InkWell(
                      onTap: () => setState(() => error = null),
                      child: Icon(Icons.close, size: 15, color: cs.error),
                    ),
                  ],
                ),
              ),

            // Foreign-currency conversion row (only when sc != ac)
            if (sc != ac)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
                child: Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 36,
                        child: TextField(
                          key: const Key('converted'),
                          controller: converted,
                          enabled: !busy,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          inputFormatters: amountInputFormatters,
                          style: const TextStyle(fontSize: 13),
                          onChanged: (_) => convertedEdited = true,
                          decoration: InputDecoration(
                            labelText: type == RecordType.transfer
                                ? '转入金额（$ac）'
                                : '折合入账（$ac）',
                            prefixText: '$ac ',
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    TextButton.icon(
                      key: const Key('auto-convert-btn'),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      onPressed: busy
                          ? null
                          : () => setState(() {
                              convertedEdited = false;
                              _autoConvert();
                            }),
                      icon: const Icon(Icons.sync_rounded, size: 15),
                      label: const Text('按汇率算', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ),

            // Collapsible image attachment strip
            if ((_attachmentsExpanded || imageNames.isNotEmpty) &&
                (diyConfig.isEnabled(DiyToolbarAction.images) ||
                    imageNames.isNotEmpty))
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
                child: BillAttachmentStrip(
                  key: const Key('record-attachment-strip'),
                  imageNames: imageNames,
                  readOnly: busy,
                  onChanged: (next) => setState(() => imageNames = next),
                ),
              ),

            // Compact Horizontal Scrollable Pill Toolbar (single 36px strip)
            _buildPillToolbar(
              context,
              assets: assets,
              tags: tags,
              currencies: currencies,
              diyConfig: diyConfig,
            ),

            // Frequent remark chips (0px when empty)
            if (type != RecordType.transfer && categoryId != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: FrequentRemarkChips(
                  categoryId: categoryId!,
                  selectedRemark: remark.text,
                  maxCount: 6,
                  enabled: !busy,
                  onSelectRemark: (value) =>
                      setState(() => remark.text = value),
                ),
              ),

            // Remark + Live Amount Expression Bar
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 8, 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    flex: 5,
                    child: TextField(
                      key: const Key('remark'),
                      controller: remark,
                      enabled: !busy,
                      maxLength: 200,
                      buildCounter:
                          (
                            _, {
                            required currentLength,
                            required isFocused,
                            required maxLength,
                          }) => null,
                      onChanged: (_) => setState(() {}),
                      style: const TextStyle(fontSize: 13.5),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: '点击填写备注...',
                        hintStyle: TextStyle(
                          fontSize: 13,
                          color: cs.onSurfaceVariant.withAlpha(160),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 8,
                        ),
                        border: InputBorder.none,
                        prefixIcon: Icon(
                          Icons.edit_note_rounded,
                          size: 19,
                          color: cs.onSurfaceVariant,
                        ),
                        prefixIconConstraints: const BoxConstraints(
                          minWidth: 26,
                          minHeight: 26,
                        ),
                        suffixIcon:
                            type != RecordType.transfer &&
                                GoRouter.maybeOf(context) != null
                            ? IconButton(
                                key: const Key('editor-remarks-btn'),
                                tooltip: '常用备注管理',
                                visualDensity: VisualDensity.compact,
                                padding: EdgeInsets.zero,
                                icon: const Icon(
                                  Icons.comment_outlined,
                                  size: 17,
                                ),
                                onPressed: busy
                                    ? null
                                    : () => unawaited(
                                        context.push(
                                          categoryId == null
                                              ? '/remarks'
                                              : '/remarks?categoryId=$categoryId',
                                        ),
                                      ),
                              )
                            : null,
                        suffixIconConstraints: const BoxConstraints(
                          minWidth: 30,
                          minHeight: 30,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    flex: 5,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        if (livePreview != null)
                          Text(
                            '= $livePreview',
                            key: const Key('amount-live-preview'),
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: cs.primary,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              sc,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Flexible(
                              child: TextField(
                                key: const Key('amount'),
                                controller: amount,
                                enabled: !busy,
                                readOnly: false,
                                keyboardType: TextInputType.none,
                                textAlign: TextAlign.right,
                                inputFormatters: _keypadExpressionFormatters,
                                onChanged: (_) => setState(_autoConvert),
                                style: TextStyle(
                                  fontSize: 21,
                                  fontWeight: FontWeight.w800,
                                  color:
                                      type == RecordType.income ||
                                          type == RecordType.advanceIncome
                                      ? const Color(0xFF2E7D32)
                                      : (type == RecordType.transfer
                                            ? cs.primary
                                            : cs.onSurface),
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                                decoration: InputDecoration(
                                  isDense: true,
                                  hintText: '0.00',
                                  hintStyle: TextStyle(
                                    fontSize: 21,
                                    fontWeight: FontWeight.w700,
                                    color: cs.outlineVariant,
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(
                                    vertical: 4,
                                  ),
                                  border: InputBorder.none,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    key: const Key('toggle-keypad-btn'),
                    tooltip: _keypadVisible ? '收起数字键盘' : '展开数字键盘',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                    icon: Icon(
                      _keypadVisible
                          ? Icons.keyboard_arrow_down_rounded
                          : Icons.dialpad_rounded,
                      size: 19,
                      color: cs.onSurfaceVariant,
                    ),
                    onPressed: () =>
                        setState(() => _keypadVisible = !_keypadVisible),
                  ),
                ],
              ),
            ),

            // Collapsible 4×4+1 Built-in Calculator Keypad (or compact save bar)
            if (_keypadVisible)
              RecordKeyboard(
                expression: amount.text,
                enabled: canSubmit,
                busy: busy,
                showSaveAndNew: !editing,
                assignSaveKey: true,
                onKeyTap: _handleKeypadTap,
                onSave: canSubmit
                    ? () => unawaited(_save(stayAndReset: false))
                    : null,
                onSaveAndNew: canSubmit && !editing
                    ? () => unawaited(_save(stayAndReset: true))
                    : null,
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
                child: Row(
                  children: [
                    if (!editing) ...[
                      Expanded(
                        child: OutlinedButton(
                          key: const Key('save-and-new'),
                          onPressed: canSubmit
                              ? () => unawaited(_save(stayAndReset: true))
                              : null,
                          child: const Text('再记一笔'),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      flex: 2,
                      child: FilledButton(
                        key: const Key('save'),
                        onPressed: canSubmit
                            ? () => unawaited(_save(stayAndReset: false))
                            : null,
                        child: Text(busy ? '保存中…' : '保存'),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPillToolbar(
    BuildContext context, {
    required List<Asset> assets,
    required List<Tag> tags,
    required List<Currency> currencies,
    required DiyToolbarConfig diyConfig,
  }) {
    final cs = Theme.of(context).colorScheme;
    final currentAsset = assets.where((a) => a.id == assetId).firstOrNull;
    final selectedTags = tags
        .where((t) => selectedTagIds.contains(t.tagId))
        .toList();

    Widget pill({
      Key? key,
      IconData? icon,
      Widget? leading,
      Color? accentColor,
      required String label,
      bool active = false,
      VoidCallback? onTap,
    }) {
      final bgColor = active
          ? (accentColor != null
                ? accentColor.withValues(alpha: 0.14)
                : cs.secondaryContainer)
          : cs.surfaceContainerLow;
      final borderColor = active
          ? (accentColor != null
                ? accentColor.withValues(alpha: 0.45)
                : cs.secondary.withAlpha(110))
          : cs.outlineVariant.withAlpha(110);
      final textColor = active
          ? (accentColor != null ? cs.onSurface : cs.onSecondaryContainer)
          : cs.onSurface;
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: Material(
          color: bgColor,
          shape: StadiumBorder(
            side: BorderSide(color: borderColor, width: 0.7),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: key,
            onTap: busy ? null : onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (leading != null)
                    leading
                  else if (icon != null)
                    Icon(
                      icon,
                      size: 14,
                      color: active ? cs.onSecondaryContainer : cs.primary,
                    ),
                  const SizedBox(width: 4),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                      color: textColor,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final currentAssetVisual = currentAsset == null
        ? null
        : resolveAssetVisual(
            iconKey: currentAsset.icon,
            colorHex: currentAsset.color,
            name: currentAsset.name,
            assetType: currentAsset.type,
            subType: currentAsset.subType,
          );

    final pills = <Widget>[
      if (type != RecordType.transfer)
        pill(
          key: const Key('asset'),
          icon: currentAsset == null
              ? Icons.account_balance_wallet_outlined
              : null,
          leading: currentAsset == null
              ? null
              : AssetIconAvatar(
                  iconKey: currentAsset.icon,
                  colorHex: currentAsset.color,
                  name: currentAsset.name,
                  assetType: currentAsset.type,
                  subType: currentAsset.subType,
                  size: 18,
                  selected: true,
                ),
          accentColor: currentAssetVisual?.color,
          label: currentAsset?.name ?? '不选账户',
          active: currentAsset != null,
          onTap: () => unawaited(
            _openAccountPickerSheet(
              title: '选择账户',
              assets: assets,
              currentId: currentAsset?.id ?? noRef,
              allowNone: true,
              onSelected: (v) => setState(() {
                assetId = v;
                _autoConvert();
              }),
            ),
          ),
        ),
      pill(
        key: const Key('editor-date-pill'),
        icon: Icons.schedule_rounded,
        label: _formatDatePillLabel(time),
        onTap: () => unawaited(_pickTime()),
      ),
    ];

    for (final item in diyConfig.items) {
      switch (item.action) {
        case DiyToolbarAction.tags:
          if (item.enabled || selectedTagIds.isNotEmpty) {
            final String tagLabel;
            if (selectedTags.isEmpty) {
              tagLabel = '#标签';
            } else if (selectedTags.length == 1) {
              tagLabel = '#${selectedTags.first.name}';
            } else {
              tagLabel =
                  '#${selectedTags.first.name} +${selectedTags.length - 1}';
            }
            pills.add(
              pill(
                key: const Key('editor-tags-pill'),
                icon: Icons.tag_rounded,
                label: tagLabel,
                active: selectedTagIds.isNotEmpty,
                onTap: () => unawaited(_openTagPickerSheet(tags)),
              ),
            );
          }

        case DiyToolbarAction.discount:
          if ((type == RecordType.expense || type == RecordType.income) &&
              (item.enabled || discount.text.trim().isNotEmpty)) {
            final hasDisc = discount.text.trim().isNotEmpty;
            pills.add(
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Material(
                  color: hasDisc
                      ? cs.secondaryContainer
                      : cs.surfaceContainerLow,
                  shape: StadiumBorder(
                    side: BorderSide(
                      color: hasDisc
                          ? cs.secondary.withAlpha(110)
                          : cs.outlineVariant.withAlpha(110),
                      width: 0.7,
                    ),
                  ),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: busy ? null : _discountFocus.requestFocus,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.local_offer_outlined,
                            size: 14,
                            color: hasDisc
                                ? cs.onSecondaryContainer
                                : cs.primary,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '优惠',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: hasDisc
                                  ? cs.onSecondaryContainer
                                  : cs.onSurface,
                            ),
                          ),
                          const SizedBox(width: 4),
                          SizedBox(
                            width: 54,
                            child: TextField(
                              key: const Key('discount'),
                              controller: discount,
                              focusNode: _discountFocus,
                              enabled: !busy,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              inputFormatters: amountInputFormatters,
                              onChanged: (_) => setState(() {}),
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: hasDisc
                                    ? cs.onSecondaryContainer
                                    : cs.onSurface,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                              decoration: InputDecoration.collapsed(
                                hintText: '0.00',
                                hintStyle: TextStyle(
                                  fontSize: 11.5,
                                  color: cs.onSurfaceVariant.withAlpha(140),
                                ),
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

        case DiyToolbarAction.images:
          if (item.enabled || imageNames.isNotEmpty) {
            pills.add(
              pill(
                key: const Key('editor-images-pill'),
                icon: Icons.photo_camera_back_outlined,
                label: imageNames.isEmpty ? '图片' : '图片(${imageNames.length})',
                active: _attachmentsExpanded || imageNames.isNotEmpty,
                onTap: () => setState(
                  () => _attachmentsExpanded = !_attachmentsExpanded,
                ),
              ),
            );
          }

        case DiyToolbarAction.location:
          if (item.enabled || (location != null && !location!.isEmpty)) {
            final hasLoc = location != null && !location!.isEmpty;
            pills.add(
              pill(
                key: const Key('record-location-tile'),
                icon: Icons.place_outlined,
                label: hasLoc ? location!.displayLabel : '地点',
                active: hasLoc,
                onTap: () => unawaited(_pickLocation()),
              ),
            );
          }

        case DiyToolbarAction.currency:
          if (type != RecordType.transfer &&
              currencies.length > 1 &&
              (item.enabled || sourceCurrency != null)) {
            final (sc, ac) = _currencies();
            pills.add(
              pill(
                key: const Key('editor-currency-pill'),
                icon: Icons.currency_exchange_rounded,
                label: sc,
                active: sc != ac,
                onTap: () => unawaited(_openCurrencyPickerSheet(currencies)),
              ),
            );
          }

        case DiyToolbarAction.excludeExIn:
          if (type != RecordType.transfer && (item.enabled || excludeExIn)) {
            pills.add(
              pill(
                key: const Key('editor-exclude-exin-pill'),
                icon: excludeExIn
                    ? Icons.visibility_off_outlined
                    : Icons.analytics_outlined,
                label: '不计收支',
                active: excludeExIn,
                onTap: () => setState(() => excludeExIn = !excludeExIn),
              ),
            );
          }

        case DiyToolbarAction.excludeBudget:
          if (type != RecordType.transfer && (item.enabled || excludeBudget)) {
            pills.add(
              pill(
                key: const Key('editor-exclude-budget-pill'),
                icon: excludeBudget
                    ? Icons.do_not_disturb_on_outlined
                    : Icons.pie_chart_outline_rounded,
                label: '不计预算',
                active: excludeBudget,
                onTap: () => setState(() => excludeBudget = !excludeBudget),
              ),
            );
          }

        case DiyToolbarAction.templates:
          break;
      }
    }

    return SizedBox(
      height: 36,
      child: SingleChildScrollView(
        key: const Key('editor-pill-toolbar'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        child: Row(children: pills),
      ),
    );
  }
}
