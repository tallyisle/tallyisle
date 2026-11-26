import 'dart:async';
import 'dart:math' as math;

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
import '../../data/ledger/ledger_service.dart';
import '../../data/repo/ledger_queries.dart';
import '../../data/tools/template_remark_service.dart';
import '../../domain/ledger/record_extra.dart';
import '../../domain/ledger/record_relations.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/app_settings_rules.dart';
import '../../domain/rules/asset_overview.dart'
    show RateTable, normalizeCurrency;
import '../../domain/rules/currency_rates.dart';
import '../../domain/rules/record_keypad_calc.dart';
import '../assets/assets_page.dart';
import '../attachments/attachment_providers.dart';
import '../automation/automation_providers.dart'
    show widgetSnapshotServiceProvider;
import '../automation/smart_quick_sheet.dart'
    show SmartQuickPrefillResult, showSmartQuickPrefillDialogOrSheet;
import '../budget/budget_widgets.dart';
import '../categories/categories_page.dart';
import '../common/catalog_icons.dart';
import '../common/common.dart';
import '../common/desktop_modal_page.dart';
import '../receipt/diy_toolbar_settings_page.dart';
import '../receipt/receipt_diy_providers.dart';
import '../receipt/record_receipt_dialog.dart' show BillLocationEditorDialog;
import '../stats/tag_stats_page.dart' show TagColorDot, parseTagColor;
import '../tags/tags_page.dart';
import '../templates/template_providers.dart';
import '../templates/templates_page.dart'
    show RemarksPage, TemplatePrefill, TemplateQuickBar, TemplatesPage;
import 'desktop_record_editor_dialog.dart';
import 'record_datetime_dialog.dart';
import 'record_keypad.dart';

/// Keypad upper bound (`docs/reference/ledger-catalog.md` §5).
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

enum _BottomPanelMode { customKeypad, osKeyboard, frequentRemarks }

const String _followAccountCurrencySentinel = '__FOLLOW_ACCOUNT__';

final class _AggregatedRemark {
  _AggregatedRemark({
    required this.representative,
    required this.totalUsedTimes,
    required this.latestId,
    required this.hasExactCategory,
  });

  Remark representative;
  int totalUsedTimes;
  int latestId;
  bool hasExactCategory;
}

List<Remark> _deduplicateAndSortRemarks(
  Iterable<Remark> rows, {
  int? prioritizeExactCategoryId,
}) {
  final byContent = <String, _AggregatedRemark>{};
  for (final r in rows) {
    final text = r.content.trim();
    if (text.isEmpty) continue;
    final isExact =
        prioritizeExactCategoryId != null &&
        r.recordCatId == prioritizeExactCategoryId;
    final existing = byContent[text];
    if (existing == null) {
      byContent[text] = _AggregatedRemark(
        representative: r,
        totalUsedTimes: r.usedTimes,
        latestId: r.id,
        hasExactCategory: isExact,
      );
    } else {
      existing.totalUsedTimes += r.usedTimes;
      if (r.id > existing.latestId) {
        existing.latestId = r.id;
      }
      final repIsExact =
          prioritizeExactCategoryId != null &&
          existing.representative.recordCatId == prioritizeExactCategoryId;
      final shouldReplaceRep = isExact != repIsExact
          ? isExact
          : (r.usedTimes > existing.representative.usedTimes ||
                (r.usedTimes == existing.representative.usedTimes &&
                    r.id > existing.representative.id));
      if (shouldReplaceRep) {
        existing.representative = r;
      }
      if (isExact) {
        existing.hasExactCategory = true;
      }
    }
  }
  final list = byContent.values.toList()
    ..sort((a, b) {
      if (a.hasExactCategory != b.hasExactCategory) {
        return a.hasExactCategory ? -1 : 1;
      }
      final cmpUsed = b.totalUsedTimes.compareTo(a.totalUsedTimes);
      if (cmpUsed != 0) return cmpUsed;
      return b.latestId.compareTo(a.latestId);
    });
  return [for (final item in list) item.representative];
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
    this.initialRecordTimeMs,
    this.embeddedInDesktopDialog = false,
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
  final int? initialRecordTimeMs;
  final bool embeddedInDesktopDialog;

  @override
  ConsumerState<RecordEditorPage> createState() => _RecordEditorPageState();
}

class _RecordEditorPageState extends ConsumerState<RecordEditorPage>
    with WidgetsBindingObserver {
  final amount = TextEditingController();
  final converted = TextEditingController();
  final discount = TextEditingController();
  final fee = TextEditingController();
  final remark = TextEditingController();
  late final FocusNode _amountFocus = FocusNode(
    debugLabel: 'record-editor-amount',
    onKeyEvent: _handleAmountFieldKeyEvent,
  );
  late final FocusNode _remarkFocus = FocusNode(
    debugLabel: 'record-editor-remark',
    onKeyEvent: _handleAuxFieldKeyEvent,
  );
  late final FocusNode _feeFocus = FocusNode(
    debugLabel: 'record-editor-fee',
    onKeyEvent: _handleAuxFieldKeyEvent,
  );
  late final FocusNode _desktopScopeFocus = FocusNode(
    debugLabel: 'record-editor-desktop-scope',
    onKeyEvent: _handleDesktopScopeKeyEvent,
  );
  final ids = CommandIds();
  final imageIds = CommandIds();
  final remarkIds = CommandIds();
  final diyStyleIds = CommandIds();

  int _draftNonce = 0;
  int _diyStyleSeq = 0;
  int _inFlightStyleSaves = 0;
  Future<void> _diyStyleSaveChain = Future<void>.value();
  RecordDatePickerStyle? _localDatePickerStyle;
  RecordTimePickerStyle? _localTimePickerStyle;
  int? _resolvedBookId;
  int? _initialCategoriesBookId;
  List<RecordCategory> _initialCategories = const <RecordCategory>[];
  List<Asset> _initialAssets = const <Asset>[];
  List<AssetBook> _initialAssetBooks = const <AssetBook>[];
  static const List<int> _creatableRecordTypes = <int>[
    RecordType.expense,
    RecordType.income,
    RecordType.transfer,
    RecordType.reimbursable,
    RecordType.advanceExpense,
    RecordType.advanceIncome,
  ];

  int type = RecordType.expense;
  bool _userTouchedType = false;
  int? categoryId;
  int? parentCatId;
  bool _userTouchedCategory = false;
  bool _userTouchedAsset = false;
  int? _middleActivePointer;
  int? _lastBlockedMiddlePointer;
  Offset? _middlePointerDownPos;
  Duration? _middlePointerDownTime;
  Offset _middleTotalDelta = Offset.zero;
  double _middleDragDx = 0.0;
  bool _middleSwipeBlockedByChild = false;
  bool _middleDragHandledByArena = false;
  Set<String> selectedTagIds = {};
  List<String> imageNames = const <String>[];
  BillLocationInfo? location;
  int assetId = noRef, fromAssetId = noRef, toAssetId = noRef;

  /// Currency the amount is entered in; null = follow the selected account currency.
  String? sourceCurrency;

  /// The user typed the converted amount themselves (stop auto-filling).
  bool convertedEdited = false;

  /// True while preserving an existing FX bill's loaded converted amount until
  /// the user edits amount/discount/currency/account.
  bool _preservingLoadedConversion = false;
  int _pickerReorderSeq = 0;
  bool feeFromTarget = false;
  bool excludeBudget = false, excludeExIn = false;
  bool _attachmentsExpanded = false;
  bool _savedAndResetBanner = false;
  bool _remarksShowAllScope = false;
  _BottomPanelMode _panelMode = _BottomPanelMode.customKeypad;
  bool _desktopKeypadExpanded = false;
  bool _desktopRemarksExpanded = false;
  bool _didAutoFocusDesktopAmount = false;
  bool _imeWasVisible = false;
  DateTime time = DateTime.now();
  LedgerRecord? original;
  bool loading = true, busy = false;
  String? error;

  bool get editing => widget.recordId != null;

  bool get _isDesktopActive => mounted && DesktopAdaptive.isDesktop(context);

  bool get _isEmbeddedInDesktopDialog =>
      widget.embeddedInDesktopDialog ||
      (mounted && DesktopRecordDialogScope.isEmbedded(context));

  bool get _isImperativeDialogRoute {
    if (!mounted) return false;
    final route = ModalRoute.of(context);
    return route is PopupRoute && route.settings is! Page;
  }

  bool get _isTopmostRoute =>
      mounted && (ModalRoute.of(context)?.isCurrent ?? true);

  bool get _canSubmitNow => !busy && !loading && (!editing || original != null);

  bool get _hasOsKeyboardFieldFocus =>
      _remarkFocus.hasFocus || _feeFocus.hasFocus;

  void _setAmountText(String text) {
    amount.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _unfocusOsKeyboardFields() {
    if (_remarkFocus.hasFocus) _remarkFocus.unfocus();
    if (_feeFocus.hasFocus) _feeFocus.unfocus();
  }

  void _ensureInitialDesktopFocusScheduled() {
    if (_didAutoFocusDesktopAmount || loading || busy || !_isDesktopActive) {
      return;
    }
    _didAutoFocusDesktopAmount = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || busy || loading || _hasOsKeyboardFieldFocus) return;
      if (!_amountFocus.hasFocus) {
        _amountFocus.requestFocus();
      }
    });
  }

  void _focusDesktopAmountIfIdle() {
    if (!_isDesktopActive ||
        !_isTopmostRoute ||
        busy ||
        loading ||
        _hasOsKeyboardFieldFocus) {
      return;
    }
    if (!_amountFocus.hasFocus) {
      _amountFocus.requestFocus();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_isTopmostRoute ||
          busy ||
          loading ||
          _hasOsKeyboardFieldFocus) {
        return;
      }
      if (!_amountFocus.hasFocus) {
        _amountFocus.requestFocus();
      }
    });
  }

  void _closeEditor([String? result]) {
    _unfocusOsKeyboardFields();
    if (_isImperativeDialogRoute) {
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop(result);
      }
      return;
    }
    final router = GoRouter.maybeOf(context);
    if (router != null) {
      if (context.canPop()) {
        context.pop(result);
      } else {
        context.go('/');
      }
    } else if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop(result);
    }
  }

  void _toggleDesktopKeypadPanel() {
    if (busy) return;
    setState(() {
      _desktopKeypadExpanded = !_desktopKeypadExpanded;
      if (_desktopKeypadExpanded) {
        _desktopRemarksExpanded = false;
      }
    });
    _focusDesktopAmountIfIdle();
  }

  void _toggleDesktopRemarksPanel() {
    if (busy) return;
    setState(() {
      _desktopRemarksExpanded = !_desktopRemarksExpanded;
      if (_desktopRemarksExpanded) {
        _desktopKeypadExpanded = false;
      }
    });
    if (!_desktopRemarksExpanded) {
      _focusDesktopAmountIfIdle();
    }
  }

  static bool _isEnterKey(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter;

  bool _isPrimarySubmitModifierPressed(HardwareKeyboard hw) {
    if (hw.isAltPressed) return false;
    if (DesktopAdaptive.isMacOS(context)) {
      return hw.isControlPressed || hw.isMetaPressed;
    }
    return hw.isControlPressed && !hw.isMetaPressed;
  }

  static String? _mapDesktopKeyToKeypadToken(
    KeyEvent event,
    HardwareKeyboard hw,
  ) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return null;
    }
    if (hw.isControlPressed || hw.isMetaPressed || hw.isAltPressed) {
      return null;
    }
    final key = event.logicalKey;
    final shift = hw.isShiftPressed;

    if (shift) {
      if (key == LogicalKeyboardKey.equal ||
          key == LogicalKeyboardKey.add ||
          key == LogicalKeyboardKey.numpadAdd ||
          event.character == '+') {
        return '+';
      }
      if (key == LogicalKeyboardKey.digit8 ||
          key == LogicalKeyboardKey.asterisk ||
          key == LogicalKeyboardKey.numpadMultiply ||
          event.character == '*') {
        return '×';
      }
      return null;
    }

    return switch (key) {
      LogicalKeyboardKey.digit0 || LogicalKeyboardKey.numpad0 => '0',
      LogicalKeyboardKey.digit1 || LogicalKeyboardKey.numpad1 => '1',
      LogicalKeyboardKey.digit2 || LogicalKeyboardKey.numpad2 => '2',
      LogicalKeyboardKey.digit3 || LogicalKeyboardKey.numpad3 => '3',
      LogicalKeyboardKey.digit4 || LogicalKeyboardKey.numpad4 => '4',
      LogicalKeyboardKey.digit5 || LogicalKeyboardKey.numpad5 => '5',
      LogicalKeyboardKey.digit6 || LogicalKeyboardKey.numpad6 => '6',
      LogicalKeyboardKey.digit7 || LogicalKeyboardKey.numpad7 => '7',
      LogicalKeyboardKey.digit8 || LogicalKeyboardKey.numpad8 => '8',
      LogicalKeyboardKey.digit9 || LogicalKeyboardKey.numpad9 => '9',
      LogicalKeyboardKey.period || LogicalKeyboardKey.numpadDecimal => '.',
      LogicalKeyboardKey.add || LogicalKeyboardKey.numpadAdd => '+',
      LogicalKeyboardKey.minus || LogicalKeyboardKey.numpadSubtract => '-',
      LogicalKeyboardKey.asterisk || LogicalKeyboardKey.numpadMultiply => '×',
      LogicalKeyboardKey.slash || LogicalKeyboardKey.numpadDivide => '/',
      LogicalKeyboardKey.backspace => '⌫',
      LogicalKeyboardKey.delete => event is KeyDownEvent ? 'CLEAR' : null,
      LogicalKeyboardKey.equal ||
      LogicalKeyboardKey.numpadEqual => event is KeyDownEvent ? '=' : null,
      _ => switch (event.character) {
        '+' => '+',
        '-' || '−' => '-',
        '*' => '×',
        '/' => '/',
        '.' => '.',
        '=' => event is KeyDownEvent ? '=' : null,
        _ => null,
      },
    };
  }

  void _cycleDesktopFieldFocus({required bool reverse}) {
    if (busy || loading) return;
    final ring = <FocusNode>[
      _amountFocus,
      if (type == RecordType.transfer) _feeFocus,
      _remarkFocus,
    ];
    final currentIdx = ring.indexWhere((n) => n.hasFocus);
    final int nextIdx;
    if (currentIdx < 0) {
      nextIdx = reverse ? ring.length - 1 : 0;
    } else if (reverse) {
      nextIdx = (currentIdx - 1 + ring.length) % ring.length;
    } else {
      nextIdx = (currentIdx + 1) % ring.length;
    }
    final target = ring[nextIdx];
    target.requestFocus();
    if (identical(target, _remarkFocus)) {
      remark.selection = TextSelection.collapsed(offset: remark.text.length);
    } else if (identical(target, _feeFocus)) {
      fee.selection = TextSelection.collapsed(offset: fee.text.length);
    } else if (identical(target, _amountFocus)) {
      amount.selection = TextSelection.collapsed(offset: amount.text.length);
    }
  }

  void _triggerDesktopEnter() {
    if (!_canSubmitNow) return;
    if (hasOperator(amount.text)) {
      _evaluateInPlace();
      return;
    }
    unawaited(_save(stayAndReset: false));
  }

  void _triggerDesktopSaveAndAgain() {
    if (!_canSubmitNow) return;
    unawaited(_save(stayAndReset: true));
  }

  void _applyDesktopKeypadToken(String token) {
    if (busy || loading) return;
    if (token == '=') {
      _evaluateInPlace();
      return;
    }
    ScaffoldMessenger.maybeOf(context)?.clearSnackBars();
    _unfocusOsKeyboardFields();
    final nextValue = applyCustomKeypadValue(
      amount.value,
      token,
      allowMultiplyDivide: true,
    );
    setState(() {
      error = null;
      _savedAndResetBanner = false;
      if (_desktopRemarksExpanded) {
        _desktopRemarksExpanded = false;
      }
      amount.value = nextValue;
      if (_preservingLoadedConversion) {
        _preservingLoadedConversion = false;
        convertedEdited = false;
      }
      _autoConvert();
    });
    if (!_amountFocus.hasFocus) {
      _amountFocus.requestFocus();
    }
  }

  KeyEventResult _handleSharedDesktopShortcuts(
    KeyEvent event, {
    required bool isTextFieldComposing,
  }) {
    if (!_isDesktopActive || !_isTopmostRoute) {
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final hw = HardwareKeyboard.instance;
    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.escape &&
        !hw.isControlPressed &&
        !hw.isAltPressed &&
        !hw.isMetaPressed &&
        !hw.isShiftPressed) {
      if (isTextFieldComposing) return KeyEventResult.ignored;
      if (!busy) {
        _closeEditor();
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.tab &&
        !hw.isControlPressed &&
        !hw.isAltPressed &&
        !hw.isMetaPressed) {
      if (isTextFieldComposing) return KeyEventResult.ignored;
      _cycleDesktopFieldFocus(reverse: hw.isShiftPressed);
      return KeyEventResult.handled;
    }

    if (_isEnterKey(key) &&
        _isPrimarySubmitModifierPressed(hw) &&
        !hw.isShiftPressed) {
      _triggerDesktopSaveAndAgain();
      return KeyEventResult.handled;
    }

    if (_isEnterKey(key) &&
        !hw.isControlPressed &&
        !hw.isMetaPressed &&
        !hw.isAltPressed &&
        !hw.isShiftPressed) {
      if (isTextFieldComposing) return KeyEventResult.ignored;
      _triggerDesktopEnter();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  KeyEventResult _handleAmountFieldKeyEvent(FocusNode node, KeyEvent event) {
    if (!_isDesktopActive || !_isTopmostRoute) {
      return KeyEventResult.ignored;
    }
    final shared = _handleSharedDesktopShortcuts(
      event,
      isTextFieldComposing: false,
    );
    if (shared != KeyEventResult.ignored) {
      return shared;
    }
    final token = _mapDesktopKeyToKeypadToken(event, HardwareKeyboard.instance);
    if (token != null) {
      _applyDesktopKeypadToken(token);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _handleAuxFieldKeyEvent(FocusNode node, KeyEvent event) {
    if (!_isDesktopActive || !_isTopmostRoute) {
      return KeyEventResult.ignored;
    }
    final activeCtrl = identical(node, _feeFocus) ? fee : remark;
    final composing =
        activeCtrl.value.composing.isValid &&
        !activeCtrl.value.composing.isCollapsed;
    return _handleSharedDesktopShortcuts(
      event,
      isTextFieldComposing: composing,
    );
  }

  KeyEventResult _handleDesktopScopeKeyEvent(FocusNode node, KeyEvent event) {
    if (!_isDesktopActive || !_isTopmostRoute || _hasOsKeyboardFieldFocus) {
      return KeyEventResult.ignored;
    }
    final shared = _handleSharedDesktopShortcuts(
      event,
      isTextFieldComposing: false,
    );
    if (shared != KeyEventResult.ignored) {
      return shared;
    }
    final token = _mapDesktopKeyToKeypadToken(event, HardwareKeyboard.instance);
    if (token != null) {
      _applyDesktopKeypadToken(token);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _activateCustomKeypad() {
    if (busy) return;
    _imeWasVisible = false;
    _unfocusOsKeyboardFields();
    if (_isDesktopActive) {
      if (_desktopRemarksExpanded) {
        setState(() => _desktopRemarksExpanded = false);
      }
      if (!_amountFocus.hasFocus) {
        _amountFocus.requestFocus();
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !busy && !_hasOsKeyboardFieldFocus) {
          if (!_amountFocus.hasFocus) {
            _amountFocus.requestFocus();
          }
        }
      });
      return;
    }
    unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
    if (_panelMode != _BottomPanelMode.customKeypad) {
      setState(() => _panelMode = _BottomPanelMode.customKeypad);
    }
    if (!_amountFocus.hasFocus) {
      _amountFocus.requestFocus();
    }
  }

  void _toggleFrequentRemarksPanel() {
    if (busy) return;
    if (_isDesktopActive) {
      _toggleDesktopRemarksPanel();
      return;
    }
    if (_panelMode == _BottomPanelMode.frequentRemarks) {
      _activateCustomKeypad();
      return;
    }
    _imeWasVisible = false;
    setState(() => _panelMode = _BottomPanelMode.frequentRemarks);
    _unfocusOsKeyboardFields();
    if (_amountFocus.hasFocus) _amountFocus.unfocus();
    unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
  }

  @override
  void didChangeMetrics() {
    if (!mounted) return;
    final view = View.maybeOf(context);
    if (view == null) return;
    final imeBottom = view.viewInsets.bottom / view.devicePixelRatio;
    if (_hasOsKeyboardFieldFocus && imeBottom > 40) {
      _imeWasVisible = true;
    } else if (_imeWasVisible && imeBottom <= 0) {
      // Android System Back gesture or IME '⌄' hide key closed the soft keyboard
      // without firing onSubmitted/unfocus: restore custom keypad automatically.
      _imeWasVisible = false;
      _activateCustomKeypad();
    }
  }

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

  static int? _categoryTypeForRecordType(int targetType) {
    if (targetType == RecordType.transfer) return null;
    return (targetType == RecordType.income ||
            targetType == RecordType.advanceIncome)
        ? RecordType.income
        : RecordType.expense;
  }

  static RecordCategory? _firstTopCategoryForType(
    int targetType,
    List<RecordCategory> cats,
  ) {
    final wantCatType = _categoryTypeForRecordType(targetType);
    if (wantCatType == null) return null;
    for (final c in cats) {
      if (c.type == wantCatType &&
          !c.isHide &&
          (c.parentCatId == noRef || c.parentCatId == -1)) {
        return c;
      }
    }
    return null;
  }

  Future<DiyToolbarConfig> _resolveLatestDiyConfig(AppDatabase db) async {
    final row = await (db.select(
      db.preferences,
    )..where((t) => t.key.equals(prefKeyRecordDiyToolbar))).getSingleOrNull();
    if (row != null) {
      return DiyToolbarConfig.decode(row.value);
    }
    final fromProvider = mounted
        ? ref.read(diyToolbarConfigProvider).value
        : null;
    return fromProvider ?? DiyToolbarConfig.defaults();
  }

  Future<int> _resolveDefaultRecordType(AppDatabase db) async {
    final row = await (db.select(
      db.preferences,
    )..where((t) => t.key.equals(appSettingsPreferenceKey))).getSingleOrNull();
    if (row != null) {
      try {
        return AppSettings.parse(row.value).defaultRecordType;
      } on Failure {
        // Fall back to provider or expense default.
      }
    }
    final fromProvider = mounted
        ? ref.read(appSettingsProvider).value?.defaultRecordType
        : null;
    if (fromProvider != null &&
        allowedDefaultRecordTypes.contains(fromProvider)) {
      return fromProvider;
    }
    return RecordType.expense;
  }

  void _persistDateTimePickerStyles({
    required RecordDatePickerStyle datePickerStyle,
    required RecordTimePickerStyle timePickerStyle,
  }) {
    if (!mounted) return;
    final providerSnapshot = ref.read(diyToolbarConfigProvider).value;
    final serviceFuture = ref.read(billAttachmentServiceProvider.future);
    final seq = _diyStyleSeq++;
    _inFlightStyleSaves++;
    _diyStyleSaveChain = _diyStyleSaveChain.then((_) async {
      try {
        final service = await serviceFuture;
        DiyToolbarConfig base;
        try {
          base = await service.getDiyToolbarConfig();
        } catch (_) {
          base = providerSnapshot ?? DiyToolbarConfig.defaults();
        }
        final updated = base.copyWithStyles(
          datePickerStyle: datePickerStyle,
          timePickerStyle: timePickerStyle,
        );
        await service.saveDiyToolbarConfig(
          commandId: diyStyleIds.forPayload([
            'editor-dt-style',
            seq,
            updated.toJson(),
          ]),
          config: updated,
        );
      } catch (_) {
        // Non-blocking date/time picker style preference persistence.
      } finally {
        _inFlightStyleSaves--;
      }
    });
  }

  static Map<int, Set<int>> _buildAssetBookBindings(Iterable<AssetBook> links) {
    final bound = <int, Set<int>>{};
    for (final l in links) {
      bound.putIfAbsent(l.assetId, () => <int>{}).add(l.bookId);
    }
    return bound;
  }

  static bool _isAssetVisibleInBook(
    int candidateId,
    int? bookId,
    Map<int, Set<int>> assetBookBindings,
  ) {
    final bound = assetBookBindings[candidateId];
    if (bound == null || bound.isEmpty) return true;
    return bookId != null && bound.contains(bookId);
  }

  static bool _isSelectableBookAsset(
    int candidateId, {
    required int? bookId,
    required Iterable<Asset> assets,
    required Map<int, Set<int>> assetBookBindings,
  }) {
    if (candidateId == noRef || candidateId <= 0) return false;
    final asset = assets.where((a) => a.id == candidateId).firstOrNull;
    if (asset == null) return false;
    if (asset.status != AssetStatus.active || asset.type == AssetType.debt) {
      return false;
    }
    return _isAssetVisibleInBook(asset.id, bookId, assetBookBindings);
  }

  static int _computeEffectiveDefaultAccountId({
    required DiyToolbarConfig config,
    required int? bookId,
    required Iterable<Asset> assets,
    required Map<int, Set<int>> assetBookBindings,
  }) {
    if (bookId == null) return noRef;
    return resolveEffectiveDefaultAccountId(
      config: config,
      bookId: bookId,
      assets: assets.map((a) => (id: a.id, type: a.type, status: a.status)),
      assetBookBindings: assetBookBindings,
    );
  }

  ({int assetId, int fromAssetId, int toAssetId, bool changed})
  _computeReconciledCreateModeAccounts({
    required int? bookId,
    required Iterable<Asset> latestAssets,
    required Map<int, Set<int>> latestBindings,
    required DiyToolbarConfig latestConfig,
    int? previousEffectiveDefaultId,
  }) {
    bool isEligible(int id) => _isSelectableBookAsset(
      id,
      bookId: bookId,
      assets: latestAssets,
      assetBookBindings: latestBindings,
    );

    final effectiveDefaultId = _computeEffectiveDefaultAccountId(
      config: latestConfig,
      bookId: bookId,
      assets: latestAssets,
      assetBookBindings: latestBindings,
    );

    var nextAssetId = assetId;
    var nextFromAssetId = fromAssetId;
    var nextToAssetId = toAssetId;

    if (nextToAssetId != noRef && !isEligible(nextToAssetId)) {
      nextToAssetId = noRef;
    }

    if (nextFromAssetId != noRef && !isEligible(nextFromAssetId)) {
      nextFromAssetId =
          (!_userTouchedAsset &&
              effectiveDefaultId != noRef &&
              effectiveDefaultId != nextToAssetId)
          ? effectiveDefaultId
          : noRef;
    } else if (!_userTouchedAsset && type == RecordType.transfer) {
      final shouldApplyDefault =
          nextFromAssetId == noRef ||
          (previousEffectiveDefaultId != null &&
              previousEffectiveDefaultId != noRef &&
              nextFromAssetId == previousEffectiveDefaultId);
      if (shouldApplyDefault) {
        nextFromAssetId =
            (effectiveDefaultId != noRef && effectiveDefaultId != nextToAssetId)
            ? effectiveDefaultId
            : noRef;
      }
    }
    if (nextFromAssetId != noRef && nextFromAssetId == nextToAssetId) {
      nextFromAssetId = noRef;
    }

    if (nextAssetId != noRef && !isEligible(nextAssetId)) {
      nextAssetId = !_userTouchedAsset ? effectiveDefaultId : noRef;
    } else if (!_userTouchedAsset && type != RecordType.transfer) {
      final shouldApplyDefault =
          nextAssetId == noRef ||
          (previousEffectiveDefaultId != null &&
              previousEffectiveDefaultId != noRef &&
              nextAssetId == previousEffectiveDefaultId);
      if (shouldApplyDefault) {
        nextAssetId = effectiveDefaultId;
      }
    }

    final changed =
        nextAssetId != assetId ||
        nextFromAssetId != fromAssetId ||
        nextToAssetId != toAssetId;
    return (
      assetId: nextAssetId,
      fromAssetId: nextFromAssetId,
      toAssetId: nextToAssetId,
      changed: changed,
    );
  }

  Future<void> _refreshAndReconcileAccountsFromDb() async {
    if (!mounted || editing) return;
    try {
      final db = await ref.read(databaseProvider.future);
      final latestAssets = await LedgerQueries(db).getAssets();
      final latestAssetBooks = await db.select(db.assetBooks).get();
      final latestBookId = await _readCurrentBookId(db);
      final latestConfig = await _resolveLatestDiyConfig(db);
      if (!mounted || editing) return;
      _resolvedBookId = latestBookId;
      _initialAssets = latestAssets;
      _initialAssetBooks = latestAssetBooks;
      final reconciled = _computeReconciledCreateModeAccounts(
        bookId: latestBookId,
        latestAssets: latestAssets,
        latestBindings: _buildAssetBookBindings(latestAssetBooks),
        latestConfig: latestConfig,
      );
      if (reconciled.changed) {
        setState(() {
          assetId = reconciled.assetId;
          fromAssetId = reconciled.fromAssetId;
          toAssetId = reconciled.toAssetId;
          convertedEdited = false;
          _autoConvert();
        });
      } else {
        setState(() {
          _autoConvert();
        });
      }
    } catch (_) {
      // Non-blocking post-navigation catalog sync.
    }
  }

  String _currencyOf(int id) {
    if (id == noRef) return baseCurrency;
    final assets = ref.read(assetsProvider).value ?? _initialAssets;
    final a = assets.where((x) => x.id == id).firstOrNull;
    return normalizeCurrency(a?.currency) ?? baseCurrency;
  }

  String _symbolForCurrency(String code, List<Currency> currencies) {
    final norm = normalizeCurrency(code) ?? baseCurrency;
    final fromDb = currencies.where((c) => c.code == norm).firstOrNull;
    if (fromDb != null && fromDb.symbol.trim().isNotEmpty) {
      return fromDb.symbol.trim();
    }
    return defaultCurrencySymbol(norm);
  }

  /// (entered currency, booked currency) for the current form.
  (String, String) _currencies() {
    if (type == RecordType.transfer) {
      return (_currencyOf(fromAssetId), _currencyOf(toAssetId));
    }
    final ac = _currencyOf(assetId);
    return (sourceCurrency ?? ac, ac);
  }

  BigInt _currentDiscountMinor() {
    if (type != RecordType.expense && type != RecordType.income) {
      return BigInt.zero;
    }
    final raw = discount.text.trim();
    if (raw.isEmpty) return BigInt.zero;
    try {
      final parsed = parseAmount(raw);
      return parsed.storageMinor > BigInt.zero
          ? parsed.storageMinor
          : BigInt.zero;
    } on Failure {
      return BigInt.zero;
    }
  }

  BigInt _netSourceMinorFromGross(BigInt grossMinor) {
    final disc = _currentDiscountMinor();
    if (disc <= BigInt.zero) return grossMinor;
    return grossMinor > disc ? grossMinor - disc : BigInt.zero;
  }

  /// Fills [converted] from manual rates using exact calculator evaluation
  /// (after subtracting discount for expense/income) unless the user edited
  /// [converted] manually.
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
      final grossMinor = evaluateKeypadExpression(text).clampedMinor;
      final netMinor = _netSourceMinorFromGross(grossMinor);
      converted.text = formatMinor(rates.convert(netMinor, sc, ac));
    } on Failure {
      converted.text = '';
    }
  }

  String _previewConvertedAmount(String sc, String ac) {
    final explicit = converted.text.trim();
    if (explicit.isNotEmpty) {
      try {
        return parseAmount(explicit).decimal;
      } on Failure {
        return explicit;
      }
    }
    final rates = ref.read(rateTableProvider).value;
    final text = amount.text.trim();
    if (rates == null || text.isEmpty) return '0.00';
    try {
      final grossMinor = evaluateKeypadExpression(text).clampedMinor;
      final netMinor = _netSourceMinorFromGross(grossMinor);
      return formatMinor(rates.convert(netMinor, sc, ac));
    } on Failure {
      return '0.00';
    }
  }

  void _applyTemplatePrefill(
    TemplatePrefill prefill, {
    RecordCategory? fallbackFirstCategory,
    bool? autoSelectFirstOverride,
    DiyToolbarConfig? diyConfigOverride,
  }) {
    final effectiveConfig =
        diyConfigOverride ??
        ref.read(diyToolbarConfigProvider).value ??
        DiyToolbarConfig.defaults();
    final currentBookId =
        original?.accountBookId ??
        ref.read(currentBookIdProvider).value ??
        _resolvedBookId ??
        (prefill.bookExists ? prefill.bookId : null);
    RecordCategory? resolvedFallback = fallbackFirstCategory;
    if (prefill.categoryId == null && prefill.type != RecordType.transfer) {
      final autoSelectEnabled =
          autoSelectFirstOverride ??
          effectiveConfig.isEnabled(DiyToolbarAction.autoSelectFirstCategory);
      if (autoSelectEnabled && resolvedFallback == null) {
        final currentCats = currentBookId == null
            ? const <RecordCategory>[]
            : (ref.read(categoriesProvider(currentBookId)).value ??
                  (currentBookId == _initialCategoriesBookId
                      ? _initialCategories
                      : const <RecordCategory>[]));
        resolvedFallback = _firstTopCategoryForType(prefill.type, currentCats);
      }
    }

    final currentAssets = ref.read(assetsProvider).value ?? _initialAssets;
    final currentAssetBooks =
        ref.read(assetBooksProvider).value ?? _initialAssetBooks;
    final bindings = _buildAssetBookBindings(currentAssetBooks);
    final effectiveDefaultId = editing
        ? noRef
        : _computeEffectiveDefaultAccountId(
            config: effectiveConfig,
            bookId: currentBookId,
            assets: currentAssets,
            assetBookBindings: bindings,
          );

    int nextAssetId = noRef;
    int nextFromAssetId = noRef;
    int nextToAssetId = noRef;
    bool nextUserTouchedAsset = false;

    if (prefill.type == RecordType.transfer) {
      final validFrom = _isSelectableBookAsset(
        prefill.fromAssetId,
        bookId: currentBookId,
        assets: currentAssets,
        assetBookBindings: bindings,
      );
      final validTo = _isSelectableBookAsset(
        prefill.toAssetId,
        bookId: currentBookId,
        assets: currentAssets,
        assetBookBindings: bindings,
      );
      nextToAssetId = validTo ? prefill.toAssetId : noRef;
      if (validFrom && prefill.fromAssetId != nextToAssetId) {
        nextFromAssetId = prefill.fromAssetId;
        nextUserTouchedAsset = true;
      } else {
        nextFromAssetId =
            (effectiveDefaultId != noRef && effectiveDefaultId != nextToAssetId)
            ? effectiveDefaultId
            : noRef;
        nextUserTouchedAsset = validTo;
      }
    } else {
      final validAsset = _isSelectableBookAsset(
        prefill.assetId,
        bookId: currentBookId,
        assets: currentAssets,
        assetBookBindings: bindings,
      );
      if (validAsset) {
        nextAssetId = prefill.assetId;
        nextUserTouchedAsset = true;
      } else {
        nextAssetId = effectiveDefaultId;
        nextUserTouchedAsset = false;
      }
    }

    setState(() {
      type = prefill.type;
      _userTouchedType = true;
      if (prefill.type == RecordType.transfer) {
        categoryId = null;
        parentCatId = null;
        _userTouchedCategory = false;
      } else if (prefill.categoryId != null) {
        categoryId = prefill.categoryId;
        parentCatId = prefill.parentCategoryId;
        _userTouchedCategory = true;
      } else {
        categoryId = resolvedFallback?.id;
        parentCatId = resolvedFallback?.id;
        _userTouchedCategory = false;
      }
      _remarksShowAllScope = false;
      assetId = nextAssetId;
      fromAssetId = nextFromAssetId;
      toAssetId = nextToAssetId;
      _userTouchedAsset = nextUserTouchedAsset;
      _setAmountText(prefill.amountText);
      fee.text = prefill.feeText;
      feeFromTarget = prefill.feeFromTarget;
      remark.text = prefill.remark;
      excludeBudget = prefill.excludeBudget;
      excludeExIn = prefill.excludeExIn;
      selectedTagIds = prefill.tagIds.toSet();
      sourceCurrency = prefill.type == RecordType.transfer
          ? null
          : prefill.sourceCurrency;
      if (_panelMode == _BottomPanelMode.frequentRemarks &&
          prefill.type == RecordType.transfer) {
        _panelMode = _BottomPanelMode.customKeypad;
      }
      convertedEdited = false;
      _autoConvert();
    });
  }

  Future<void> _openSmartQuickPrefill() async {
    if (busy || editing) return;
    _unfocusOsKeyboardFields();
    final prefill = await showSmartQuickPrefillDialogOrSheet(context);
    if (!mounted) return;
    if (prefill == null) {
      _focusDesktopAmountIfIdle();
      return;
    }
    _applySmartQuickPrefill(prefill);
    _activateCustomKeypad();
  }

  void _applySmartQuickPrefill(SmartQuickPrefillResult prefill) {
    final effectiveConfig =
        ref.read(diyToolbarConfigProvider).value ?? DiyToolbarConfig.defaults();
    final currentBookId =
        original?.accountBookId ??
        ref.read(currentBookIdProvider).value ??
        _resolvedBookId;
    final currentCats = currentBookId == null
        ? const <RecordCategory>[]
        : (ref.read(categoriesProvider(currentBookId)).value ??
              (currentBookId == _initialCategoriesBookId
                  ? _initialCategories
                  : const <RecordCategory>[]));
    final currentAssets = ref.read(assetsProvider).value ?? _initialAssets;
    final currentAssetBooks =
        ref.read(assetBooksProvider).value ?? _initialAssetBooks;
    final bindings = _buildAssetBookBindings(currentAssetBooks);
    final effectiveDefaultId = _computeEffectiveDefaultAccountId(
      config: effectiveConfig,
      bookId: currentBookId,
      assets: currentAssets,
      assetBookBindings: bindings,
    );

    int? nextCategoryId;
    int? nextParentCatId;
    var nextUserTouchedCategory = false;
    if (prefill.type != RecordType.transfer) {
      final matchedCat = prefill.categoryId == null
          ? null
          : currentCats.where((c) => c.id == prefill.categoryId).firstOrNull;
      if (matchedCat != null) {
        nextCategoryId = matchedCat.id;
        nextParentCatId =
            (matchedCat.parentCatId != noRef && matchedCat.parentCatId != -1)
            ? matchedCat.parentCatId
            : matchedCat.id;
        nextUserTouchedCategory = true;
      } else {
        final fallback = _firstTopCategoryForType(prefill.type, currentCats);
        nextCategoryId = fallback?.id;
        nextParentCatId = fallback?.id;
      }
    }

    var nextAssetId = noRef;
    var nextFromAssetId = noRef;
    var nextToAssetId = noRef;
    var nextUserTouchedAsset = false;

    if (prefill.type == RecordType.transfer) {
      final fromCandidate = prefill.assetId ?? noRef;
      final toCandidate = prefill.toAssetId ?? noRef;
      final validFrom = _isSelectableBookAsset(
        fromCandidate,
        bookId: currentBookId,
        assets: currentAssets,
        assetBookBindings: bindings,
      );
      final validTo = _isSelectableBookAsset(
        toCandidate,
        bookId: currentBookId,
        assets: currentAssets,
        assetBookBindings: bindings,
      );
      nextToAssetId = validTo ? toCandidate : noRef;
      if (validFrom && fromCandidate != nextToAssetId) {
        nextFromAssetId = fromCandidate;
        nextUserTouchedAsset = true;
      } else {
        nextFromAssetId =
            (effectiveDefaultId != noRef && effectiveDefaultId != nextToAssetId)
            ? effectiveDefaultId
            : noRef;
        nextUserTouchedAsset = validTo;
      }
    } else {
      final candidate = prefill.assetId ?? noRef;
      final validAsset = _isSelectableBookAsset(
        candidate,
        bookId: currentBookId,
        assets: currentAssets,
        assetBookBindings: bindings,
      );
      if (validAsset) {
        nextAssetId = candidate;
        nextUserTouchedAsset = true;
      } else {
        nextAssetId = effectiveDefaultId;
        nextUserTouchedAsset = false;
      }
    }

    setState(() {
      type = prefill.type;
      _userTouchedType = true;
      categoryId = nextCategoryId;
      parentCatId = nextParentCatId;
      _userTouchedCategory = nextUserTouchedCategory;
      assetId = nextAssetId;
      fromAssetId = nextFromAssetId;
      toAssetId = nextToAssetId;
      _userTouchedAsset = nextUserTouchedAsset;
      _setAmountText(prefill.money.decimal);
      discount.text =
          (prefill.discount != null &&
              !prefill.discount!.isZero &&
              (prefill.type == RecordType.expense ||
                  prefill.type == RecordType.income))
          ? prefill.discount!.decimal
          : '';
      remark.text = prefill.remark;
      time = DateTime.fromMillisecondsSinceEpoch(prefill.recordTimeMs);
      if (_panelMode == _BottomPanelMode.frequentRemarks &&
          prefill.type == RecordType.transfer) {
        _panelMode = _BottomPanelMode.customKeypad;
      }
      _preservingLoadedConversion = false;
      convertedEdited = false;
      _savedAndResetBanner = false;
      error = null;
      _autoConvert();
    });
  }

  Future<void> _pickLocation() async {
    _unfocusOsKeyboardFields();
    final res = await showDialog<BillLocationInfo>(
      context: context,
      builder: (_) => BillLocationEditorDialog(initial: location),
    );
    if (res == null || !mounted) return;
    setState(() => location = res.isEmpty ? null : res);
  }

  Future<void> _openDiscountDialog({
    required String currencyCode,
    required String currencySymbol,
  }) async {
    _unfocusOsKeyboardFields();
    BigInt? maxGrossMinor;
    final rawAmt = amount.text.trim();
    if (rawAmt.isNotEmpty) {
      try {
        final eval = evaluateKeypadExpression(rawAmt);
        if (!eval.dividedByZero && !eval.isNegative) {
          maxGrossMinor = eval.clampedMinor;
        }
      } on Failure {
        maxGrossMinor = null;
      }
    }
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _DiscountEditDialog(
        initialText: discount.text,
        currencyCode: currencyCode,
        currencySymbol: currencySymbol,
        maxGrossMinor: maxGrossMinor,
      ),
    );
    if (!mounted) return;
    if (result != null) {
      setState(() {
        discount.text = result;
        if (_preservingLoadedConversion) {
          _preservingLoadedConversion = false;
          convertedEdited = false;
        }
        _autoConvert();
        _savedAndResetBanner = false;
      });
    }
    if (!_hasOsKeyboardFieldFocus &&
        _panelMode == _BottomPanelMode.osKeyboard) {
      _activateCustomKeypad();
    }
  }

  Future<void> _openConversionDialog({
    required String sc,
    required String ac,
    required List<Currency> currencies,
  }) async {
    _unfocusOsKeyboardFields();
    final rates = ref.read(rateTableProvider).value;
    final discMinor = _currentDiscountMinor();
    final res = await showDialog<({String text, bool edited})>(
      context: context,
      builder: (_) => _ConversionEditDialog(
        initialText: converted.text.trim().isNotEmpty
            ? converted.text.trim()
            : _previewConvertedAmount(sc, ac),
        initialEdited: convertedEdited,
        isTransfer: type == RecordType.transfer,
        sourceCurrency: sc,
        sourceSymbol: _symbolForCurrency(sc, currencies),
        targetCurrency: ac,
        amountText: amount.text,
        discountMinor: discMinor,
        rates: rates,
      ),
    );
    if (!mounted) return;
    if (res != null) {
      setState(() {
        _preservingLoadedConversion = false;
        converted.text = res.text;
        convertedEdited = res.edited && res.text.isNotEmpty;
        if (!convertedEdited) {
          _autoConvert();
        }
        _savedAndResetBanner = false;
      });
    }
    if (!_hasOsKeyboardFieldFocus &&
        _panelMode == _BottomPanelMode.osKeyboard) {
      _activateCustomKeypad();
    }
  }

  void _onAmountFocusChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _onOsKeyboardFieldFocusChanged() {
    if (!mounted) return;
    if (_hasOsKeyboardFieldFocus) {
      final view = View.maybeOf(context);
      final imeBottom = view == null
          ? 0.0
          : view.viewInsets.bottom / view.devicePixelRatio;
      if (imeBottom > 40) {
        _imeWasVisible = true;
      }
      setState(() => _panelMode = _BottomPanelMode.osKeyboard);
      if (_feeFocus.hasFocus && !_isDesktopActive) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final feeCtx = _feeFocus.context;
          if (mounted && _feeFocus.hasFocus && feeCtx != null) {
            unawaited(
              Scrollable.ensureVisible(
                feeCtx,
                alignment: 0.5,
                duration: Duration.zero,
              ),
            );
          }
        });
      }
    } else {
      _imeWasVisible = false;
      setState(() {
        if (_panelMode == _BottomPanelMode.osKeyboard) {
          _panelMode = _BottomPanelMode.customKeypad;
        }
      });
    }
  }

  void _showCalcError(String message) {
    if (!mounted) return;
    final mq = MediaQuery.of(context);
    final double slotHeight;
    if (_isDesktopActive) {
      slotHeight = _desktopKeypadExpanded
          ? RecordCustomKeypad.desktopDefaultPanelHeight + 48.0
          : 52.0;
    } else {
      slotHeight = math.max(
        RecordCustomKeypad.panelHeight + mq.padding.bottom,
        mq.viewInsets.bottom,
      );
    }
    final targetMargin = slotHeight + 118.0;
    final bottomMargin = mq.size.height - mq.padding.top > targetMargin + 96
        ? targetMargin
        : 8.0;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          margin: EdgeInsets.fromLTRB(16, 0, 16, bottomMargin),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  void _onKeypadKey(String key) {
    if (busy) return;
    ScaffoldMessenger.maybeOf(context)?.clearSnackBars();
    _unfocusOsKeyboardFields();
    final nextValue = applyCustomKeypadValue(amount.value, key);
    setState(() {
      error = null;
      _savedAndResetBanner = false;
      _panelMode = _BottomPanelMode.customKeypad;
      amount.value = nextValue;
      if (_preservingLoadedConversion) {
        _preservingLoadedConversion = false;
        convertedEdited = false;
      }
      _autoConvert();
    });
    if (!_amountFocus.hasFocus) {
      _amountFocus.requestFocus();
    }
  }

  void _evaluateInPlace() {
    if (busy) return;
    final hadFocus = _amountFocus.hasFocus;
    try {
      final res = evaluateKeypadExpression(amount.text);
      if (res.dividedByZero) {
        _showCalcError('算式无效或除数不能为 0');
        return;
      }
      if (res.isNegative) {
        _showCalcError('计算结果不能小于 0');
        return;
      }
      if (res.exceededMax) {
        _showCalcError('金额不能超过 88888888888.00');
        return;
      }
      final evaluated = res.money;
      ScaffoldMessenger.maybeOf(context)?.clearSnackBars();
      setState(() {
        error = null;
        _savedAndResetBanner = false;
        _setAmountText(evaluated.decimal);
        if (_preservingLoadedConversion) {
          _preservingLoadedConversion = false;
          convertedEdited = false;
        }
        _autoConvert();
      });
    } on Failure {
      _showCalcError('算式无效或除数不能为 0');
    } finally {
      if (hadFocus && !_amountFocus.hasFocus && mounted) {
        _amountFocus.requestFocus();
      }
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _amountFocus.addListener(_onAmountFocusChanged);
    _remarkFocus.addListener(_onOsKeyboardFieldFocusChanged);
    _feeFocus.addListener(_onOsKeyboardFieldFocusChanged);
    if (!editing &&
        widget.initialType == null &&
        widget.initialCategory == null) {
      final cachedDefaultType = ref
          .read(appSettingsProvider)
          .value
          ?.defaultRecordType;
      if (cachedDefaultType != null &&
          allowedDefaultRecordTypes.contains(cachedDefaultType)) {
        type = cachedDefaultType;
      } else {
        type = RecordType.expense;
      }
    } else {
      type = widget.initialType ?? RecordType.expense;
    }
    categoryId = widget.initialCategory;
    assetId = widget.initialAsset ?? noRef;
    fromAssetId = widget.initialFrom ?? noRef;
    toAssetId = widget.initialTo ?? noRef;
    if (!editing &&
        type == RecordType.transfer &&
        fromAssetId == noRef &&
        widget.initialFrom == null &&
        widget.initialAsset != null) {
      fromAssetId = widget.initialAsset!;
      assetId = noRef;
    }
    _userTouchedAsset =
        widget.initialAsset != null ||
        widget.initialFrom != null ||
        widget.initialTo != null;
    if (widget.initialAmount != null) _setAmountText(widget.initialAmount!);
    if (widget.initialRemark != null) remark.text = widget.initialRemark!;
    if (!editing && widget.initialRecordTimeMs != null) {
      time = DateTime.fromMillisecondsSinceEpoch(widget.initialRecordTimeMs!);
    }
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
    final discMinor =
        (r.type == RecordType.expense || r.type == RecordType.income) &&
            r.discountMinor != null &&
            r.discountMinor! > BigInt.zero
        ? r.discountMinor!
        : BigInt.zero;
    _setAmountText(formatMinor(r.moneyMinor + discMinor));
    if (discMinor > BigInt.zero) {
      discount.text = formatMinor(discMinor);
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
          _preservingLoadedConversion = true;
        }
      } else if (sc != ac) {
        sourceCurrency = sc;
        _setAmountText(formatMinor(snap.sourceGross));
        converted.text = formatMinor(snap.assetNet!);
        convertedEdited = true;
        _preservingLoadedConversion = true;
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
      final loadedAssets = await LedgerQueries(db).getAssets();
      final loadedAssetBooks = await db.select(db.assetBooks).get();
      _initialAssets = loadedAssets;
      _initialAssetBooks = loadedAssetBooks;
      if (editing) {
        await _loadExisting(db, widget.recordId!);
        if (_resolvedBookId != null) {
          final cats = await LedgerQueries(db).getCategories(_resolvedBookId!);
          _initialCategoriesBookId = _resolvedBookId;
          _initialCategories = cats;
        }
      } else {
        _resolvedBookId = await _readCurrentBookId(db);
        final cats = await LedgerQueries(db).getCategories(_resolvedBookId!);
        _initialCategoriesBookId = _resolvedBookId;
        _initialCategories = cats;
        final diyConfig = await _resolveLatestDiyConfig(db);
        if (widget.initialTemplateId != null) {
          final prefill = await TemplateRemarkService(
            db,
          ).buildTemplatePrefill(widget.initialTemplateId!);
          final autoSelect = diyConfig.isEnabled(
            DiyToolbarAction.autoSelectFirstCategory,
          );
          final fallbackCat =
              autoSelect &&
                  prefill.categoryId == null &&
                  prefill.type != RecordType.transfer
              ? _firstTopCategoryForType(prefill.type, cats)
              : null;
          if (mounted) {
            _applyTemplatePrefill(
              prefill,
              fallbackFirstCategory: fallbackCat,
              autoSelectFirstOverride: autoSelect,
              diyConfigOverride: diyConfig,
            );
          }
        } else {
          if (widget.initialType == null && !_userTouchedType) {
            if (widget.initialCategory != null) {
              final targetCat = cats
                  .where((c) => c.id == widget.initialCategory)
                  .firstOrNull;
              if (targetCat != null && targetCat.type == RecordType.income) {
                type = RecordType.income;
              }
            } else {
              final resolvedDefaultType = await _resolveDefaultRecordType(db);
              if (mounted && !_userTouchedType) {
                type = resolvedDefaultType;
                if (type == RecordType.transfer) {
                  categoryId = null;
                  parentCatId = null;
                  if (fromAssetId == noRef &&
                      widget.initialFrom == null &&
                      widget.initialAsset != null) {
                    fromAssetId = widget.initialAsset!;
                    assetId = noRef;
                  }
                }
              }
            }
          }
          if (widget.initialCategory == null &&
              type != RecordType.transfer &&
              categoryId == null &&
              !_userTouchedCategory) {
            if (diyConfig.isEnabled(DiyToolbarAction.autoSelectFirstCategory)) {
              final first = _firstTopCategoryForType(type, cats);
              if (first != null &&
                  mounted &&
                  categoryId == null &&
                  !_userTouchedCategory &&
                  type != RecordType.transfer) {
                categoryId = first.id;
                parentCatId = first.id;
              }
            }
          }
          if (mounted) {
            final bindings = _buildAssetBookBindings(loadedAssetBooks);
            final reconciled = _computeReconciledCreateModeAccounts(
              bookId: _resolvedBookId,
              latestAssets: loadedAssets,
              latestBindings: bindings,
              latestConfig: diyConfig,
            );
            assetId = reconciled.assetId;
            fromAssetId = reconciled.fromAssetId;
            toAssetId = reconciled.toAssetId;
            _autoConvert();
          }
        }
      }
    } catch (e) {
      error = safeMessage(e);
    }
    if (mounted) setState(() => loading = false);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _amountFocus.removeListener(_onAmountFocusChanged);
    _remarkFocus.removeListener(_onOsKeyboardFieldFocusChanged);
    _feeFocus.removeListener(_onOsKeyboardFieldFocusChanged);
    amount.dispose();
    converted.dispose();
    discount.dispose();
    fee.dispose();
    remark.dispose();
    _amountFocus.dispose();
    _remarkFocus.dispose();
    _feeFocus.dispose();
    _desktopScopeFocus.dispose();
    super.dispose();
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
      final evalRes = evaluateKeypadExpression(amount.text);
      if (evalRes.dividedByZero) {
        throw const Failure(FailureCode.validation, '算式无效或除数不能为 0');
      }
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
      if (effectiveDiscount != null &&
          effectiveDiscount.storageMinor > money.storageMinor) {
        throw const Failure(FailureCode.validation, '优惠金额不能大于原金额');
      }
      final netSourceMinor = effectiveDiscount != null
          ? money.storageMinor - effectiveDiscount.storageMinor
          : money.storageMinor;
      final netSourceMoney = Money.minor(netSourceMinor);

      final effectiveDiyConfig = await _resolveLatestDiyConfig(db);
      if (!editing) {
        final liveAssets = await LedgerQueries(db).getAssets();
        final liveAssetBooks = await db.select(db.assetBooks).get();
        _initialAssets = liveAssets;
        _initialAssetBooks = liveAssetBooks;
        final reconciledBeforeSave = _computeReconciledCreateModeAccounts(
          bookId: bookId,
          latestAssets: liveAssets,
          latestBindings: _buildAssetBookBindings(liveAssetBooks),
          latestConfig: effectiveDiyConfig,
        );
        if (reconciledBeforeSave.changed) {
          assetId = reconciledBeforeSave.assetId;
          fromAssetId = reconciledBeforeSave.fromAssetId;
          toAssetId = reconciledBeforeSave.toAssetId;
          convertedEdited = false;
          _preservingLoadedConversion = false;
          _autoConvert();
        }
      }

      // Multi-currency (`ledger-catalog.md` §4 `curr`) via direct DB read.
      // L-01: Keypad enters gross; discount applies to expense/income so
      // same-currency books netSource and cross-currency converts netSource.
      final (sc, ac) = _currencies();
      var booked = type == RecordType.transfer ? money : netSourceMoney;
      if (sc != ac) {
        final currencyRows = await db.select(db.currencies).get();
        final rates = RateTable({
          for (final c in currencyRows) c.code: c.rateToAnchor,
        });
        final text = converted.text.trim();
        final target = text.isEmpty
            ? Money.minor(rates.convert(netSourceMinor, sc, ac))
            : parseAmount(text);
        if (netSourceMinor > BigInt.zero && target.units <= BigInt.zero) {
          throw const Failure(FailureCode.validation, '折算金额须大于 0');
        }
        if (type != RecordType.transfer) booked = target;
        extra.currency = billSnapshot(
          source: sc,
          sourceMinor: money.storageMinor,
          account: ac,
          assetMinor: target.storageMinor,
          discountMinor: effectiveDiscount?.storageMinor,
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
          assetMinor: booked.storageMinor,
          discountMinor: effectiveDiscount?.storageMinor,
          rates: rates,
        );
      } else {
        extra.currency = null;
      }

      // L-07: Preserve historical FX `bm` when editing non-amount fields.
      if (old != null && old.type == type) {
        final oldSnap = RecordExtra.parse(old.extraInfo).currency;
        final newSnap = extra.currency;
        final oldDisc = old.discountMinor ?? BigInt.zero;
        final newDisc = effectiveDiscount?.storageMinor ?? BigInt.zero;
        if (oldSnap != null &&
            oldSnap.isValid &&
            newSnap != null &&
            newSnap.isValid &&
            normalizeCurrency(oldSnap.sourceCode) ==
                normalizeCurrency(newSnap.sourceCode) &&
            oldSnap.sourceGross == newSnap.sourceGross &&
            normalizeCurrency(oldSnap.assetCode) ==
                normalizeCurrency(newSnap.assetCode) &&
            (oldSnap.assetNet ?? old.moneyMinor) ==
                (newSnap.assetNet ?? booked.storageMinor) &&
            oldDisc == newDisc) {
          extra.currency = oldSnap;
        }
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

      final remarksEnabled = effectiveDiyConfig.isEnabled(
        DiyToolbarAction.frequentRemarks,
      );

      if (remarksEnabled &&
          type != RecordType.transfer &&
          draft.remark.isNotEmpty) {
        try {
          await TemplateRemarkService(db).recordRemarkUsage(
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
            ref.invalidate(remarksForCategoryProvider(noRef));
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
      if (stayAndReset) {
        if (!editing) {
          RecordCategory? nextAutoFirstCat;
          final resetToFirstCat =
              type != RecordType.transfer &&
              effectiveDiyConfig.isEnabled(
                DiyToolbarAction.autoSelectFirstCategory,
              );
          if (resetToFirstCat) {
            final currentCategories =
                (mounted ? ref.read(categoriesProvider(bookId)).value : null) ??
                await LedgerQueries(db).getCategories(bookId);
            nextAutoFirstCat = _firstTopCategoryForType(
              type,
              currentCategories,
            );
          }
          final refreshedAssets = await LedgerQueries(db).getAssets();
          final refreshedAssetBooks = await db.select(db.assetBooks).get();
          final refreshedBindings = _buildAssetBookBindings(
            refreshedAssetBooks,
          );
          final resetToDefaultAccount =
              effectiveDiyConfig.autoSelectDefaultAccount;
          final nextDefaultAccountId = _computeEffectiveDefaultAccountId(
            config: effectiveDiyConfig,
            bookId: bookId,
            assets: refreshedAssets,
            assetBookBindings: refreshedBindings,
          );
          final initialAssetStillEligible =
              widget.initialAsset != null &&
              _isSelectableBookAsset(
                widget.initialAsset!,
                bookId: bookId,
                assets: refreshedAssets,
                assetBookBindings: refreshedBindings,
              );
          if (!mounted) return;
          setState(() {
            busy = false;
            _draftNonce++;
            _initialAssets = refreshedAssets;
            _initialAssetBooks = refreshedAssetBooks;
            _setAmountText('');
            converted.clear();
            convertedEdited = false;
            _preservingLoadedConversion = false;
            discount.clear();
            fee.clear();
            feeFromTarget = false;
            remark.clear();
            selectedTagIds.clear();
            excludeBudget = false;
            excludeExIn = false;
            sourceCurrency = null;
            imageNames = const <String>[];
            location = null;
            _attachmentsExpanded = false;
            _remarksShowAllScope = false;
            if (resetToFirstCat) {
              categoryId = nextAutoFirstCat?.id;
              parentCatId = nextAutoFirstCat?.id;
              _userTouchedCategory = false;
            }
            _userTouchedAsset = initialAssetStillEligible;
            if (initialAssetStillEligible) {
              if (type == RecordType.transfer) {
                toAssetId = noRef;
                fromAssetId =
                    _isSelectableBookAsset(
                      fromAssetId,
                      bookId: bookId,
                      assets: refreshedAssets,
                      assetBookBindings: refreshedBindings,
                    )
                    ? fromAssetId
                    : widget.initialAsset!;
                assetId = noRef;
              } else {
                assetId =
                    _isSelectableBookAsset(
                      assetId,
                      bookId: bookId,
                      assets: refreshedAssets,
                      assetBookBindings: refreshedBindings,
                    )
                    ? assetId
                    : widget.initialAsset!;
                fromAssetId = noRef;
                toAssetId = noRef;
              }
            } else if (resetToDefaultAccount) {
              if (type == RecordType.transfer) {
                toAssetId = noRef;
                fromAssetId = nextDefaultAccountId;
                assetId = noRef;
              } else {
                assetId = nextDefaultAccountId;
                fromAssetId = noRef;
                toAssetId = noRef;
              }
            } else {
              if (assetId != noRef &&
                  !_isSelectableBookAsset(
                    assetId,
                    bookId: bookId,
                    assets: refreshedAssets,
                    assetBookBindings: refreshedBindings,
                  )) {
                assetId = noRef;
              }
              if (fromAssetId != noRef &&
                  !_isSelectableBookAsset(
                    fromAssetId,
                    bookId: bookId,
                    assets: refreshedAssets,
                    assetBookBindings: refreshedBindings,
                  )) {
                fromAssetId = noRef;
              }
              if (toAssetId != noRef &&
                  !_isSelectableBookAsset(
                    toAssetId,
                    bookId: bookId,
                    assets: refreshedAssets,
                    assetBookBindings: refreshedBindings,
                  )) {
                toAssetId = noRef;
              }
              if (fromAssetId != noRef && fromAssetId == toAssetId) {
                toAssetId = noRef;
              }
            }
            _autoConvert();
            _panelMode = _BottomPanelMode.customKeypad;
            _desktopRemarksExpanded = false;
            _savedAndResetBanner = true;
            error = null;
          });
          _activateCustomKeypad();
          return;
        }

        final nextDefaultType = await _resolveDefaultRecordType(db);
        if (!mounted) return;
        _unfocusOsKeyboardFields();
        if (_isImperativeDialogRoute) {
          unawaited(
            Navigator.of(context).pushReplacement(
              createDesktopRecordEditorDialogRoute(
                context,
                initialType: nextDefaultType,
              ),
            ),
          );
          return;
        }
        final router = GoRouter.maybeOf(context);
        if (router != null) {
          final nextLocation = nextDefaultType == RecordType.expense
              ? '/record/new'
              : '/record/new?type=$nextDefaultType';
          final canReplace =
              router.routerDelegate.currentConfiguration.matches.length > 1 &&
              context.canPop();
          if (canReplace) {
            context.pushReplacement(nextLocation);
          } else {
            unawaited(context.push(nextLocation));
          }
        } else {
          unawaited(
            Navigator.of(context).pushReplacement(
              MaterialPageRoute<void>(
                builder: (_) => RecordEditorPage(initialType: nextDefaultType),
              ),
            ),
          );
        }
        return;
      }

      _closeEditor(id);
    } catch (e) {
      if (mounted) setState(() => error = safeMessage(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _pickTime() async {
    _unfocusOsKeyboardFields();
    var diyConfig = ref.read(diyToolbarConfigProvider).value;
    if (diyConfig == null) {
      try {
        final service = await ref.read(billAttachmentServiceProvider.future);
        diyConfig = await service.getDiyToolbarConfig();
      } catch (_) {
        diyConfig = DiyToolbarConfig.defaults();
      }
    }
    if (!mounted) return;
    final effectiveDateStyle =
        _localDatePickerStyle ?? diyConfig.datePickerStyle;
    final effectiveTimeStyle =
        _localTimePickerStyle ?? diyConfig.timePickerStyle;
    final res = await showRecordDateTimeDialog(
      context: context,
      initialDateTime: time,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100, 12, 31),
      initialDateWheelStyle: effectiveDateStyle == RecordDatePickerStyle.wheel,
      initialTimeDialStyle: effectiveTimeStyle == RecordTimePickerStyle.dial,
      onStyleChanged: ({required dateWheelStyle, required timeDialStyle}) {
        final nextDateStyle = dateWheelStyle
            ? RecordDatePickerStyle.wheel
            : RecordDatePickerStyle.calendar;
        final nextTimeStyle = timeDialStyle
            ? RecordTimePickerStyle.dial
            : RecordTimePickerStyle.wheel;
        _localDatePickerStyle = nextDateStyle;
        _localTimePickerStyle = nextTimeStyle;
        _persistDateTimePickerStyles(
          datePickerStyle: nextDateStyle,
          timePickerStyle: nextTimeStyle,
        );
      },
    );
    if (!mounted) return;
    if (res != null) {
      setState(() {
        time = res.dateTime;
        _savedAndResetBanner = false;
      });
    }
    if (!_hasOsKeyboardFieldFocus &&
        _panelMode != _BottomPanelMode.frequentRemarks) {
      _activateCustomKeypad();
    }
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
    if (_isDesktopActive) {
      unawaited(
        pushDesktopModalOrMaterialRoute<void>(
          context,
          maxWidth: 820,
          maxHeight: 720,
          child: const CategoriesPage(),
        ),
      );
      return;
    }
    if (!_isImperativeDialogRoute && GoRouter.maybeOf(context) != null) {
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
    if (_isDesktopActive) {
      unawaited(
        pushDesktopModalOrMaterialRoute<void>(
          context,
          maxWidth: 780,
          maxHeight: 700,
          child: const TagsPage(),
        ),
      );
      return;
    }
    if (!_isImperativeDialogRoute && GoRouter.maybeOf(context) != null) {
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
    if (_isDesktopActive) {
      unawaited(
        pushDesktopModalOrMaterialRoute<void>(
          context,
          maxWidth: 820,
          maxHeight: 720,
          child: const TemplatesPage(),
        ),
      );
      return;
    }
    if (!_isImperativeDialogRoute && GoRouter.maybeOf(context) != null) {
      unawaited(context.push('/templates'));
    } else {
      unawaited(
        Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const TemplatesPage())),
      );
    }
  }

  void _openRemarksManager() {
    _unfocusOsKeyboardFields();
    if (_isDesktopActive) {
      unawaited(
        pushDesktopModalOrMaterialRoute<void>(
          context,
          maxWidth: 820,
          maxHeight: 720,
          child: RemarksPage(initialCategoryId: categoryId),
        ),
      );
      return;
    }
    if (!_isImperativeDialogRoute && GoRouter.maybeOf(context) != null) {
      unawaited(
        context.push(
          categoryId == null ? '/remarks' : '/remarks?categoryId=$categoryId',
        ),
      );
    } else {
      unawaited(
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => RemarksPage(initialCategoryId: categoryId),
          ),
        ),
      );
    }
  }

  Widget? _buildRemarkSuffixIcon({required bool remarksEnabled}) {
    final cs = Theme.of(context).colorScheme;
    final hasText = remark.text.isNotEmpty;
    final clearBtn = hasText
        ? TextFieldTapRegion(
            child: ExcludeFocus(
              child: IconButton(
                key: const Key('editor-remark-clear-btn'),
                tooltip: '清空备注',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 26,
                  height: 26,
                ),
                icon: const Icon(Icons.cancel, size: 16),
                onPressed: busy
                    ? null
                    : () => setState(() {
                        remark.clear();
                        _savedAndResetBanner = false;
                      }),
              ),
            ),
          )
        : null;

    final showRemarksToggle = remarksEnabled && type != RecordType.transfer;
    final inRemarksMode = _isDesktopActive
        ? _desktopRemarksExpanded
        : (_panelMode == _BottomPanelMode.frequentRemarks);
    final remarksToggleBtn = showRemarksToggle
        ? TextFieldTapRegion(
            child: ExcludeFocus(
              child: IconButton(
                key: const Key('editor-remarks-toggle-btn'),
                tooltip: inRemarksMode
                    ? (_isDesktopActive ? '收起常用备注' : '切换数字键盘')
                    : '常用备注',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 28,
                  height: 28,
                ),
                icon: Icon(
                  inRemarksMode
                      ? Icons.dialpad_rounded
                      : Icons.speaker_notes_outlined,
                  size: 18,
                  color: inRemarksMode ? cs.primary : cs.onSurfaceVariant,
                ),
                onPressed: busy ? null : _toggleFrequentRemarksPanel,
              ),
            ),
          )
        : null;

    if (clearBtn == null && remarksToggleBtn == null) return null;
    if (clearBtn != null && remarksToggleBtn != null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [clearBtn, remarksToggleBtn],
      );
    }
    return clearBtn ?? remarksToggleBtn;
  }

  Future<void> _openAssetsManager() {
    if (!_isImperativeDialogRoute && GoRouter.maybeOf(context) != null) {
      return context.push<void>('/assets/manage');
    }
    if (_isDesktopActive) {
      return pushDesktopModalOrMaterialRoute<void>(
        context,
        maxWidth: 860,
        maxHeight: 740,
        child: const AssetsPage(standaloneManagement: true),
      );
    }
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const AssetsPage(standaloneManagement: true),
      ),
    );
  }

  Future<void> _openAccountPickerSheet({
    required String title,
    required List<Asset> assets,
    required int currentId,
    required bool allowNone,
    int defaultAccountId = noRef,
    required ValueChanged<int> onSelected,
  }) async {
    _unfocusOsKeyboardFields();
    final isDesktop = _isDesktopActive;
    var openedManager = false;
    var didReorder = false;

    Future<void> persistReorder(List<int> orderedIds) async {
      final service = await ref.read(ledgerServiceProvider.future);
      final seq = ++_pickerReorderSeq;
      await service.reorderAssets(
        commandId: ids.forPayload(['picker-reorder', orderedIds, seq]),
        orderedAssetIds: orderedIds,
      );
      didReorder = true;
    }

    final int? chosen;
    if (isDesktop) {
      chosen = await showDialog<int>(
        context: context,
        builder: (dialogCtx) {
          return Dialog(
            key: const Key('desktop-account-picker-dialog'),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420, maxHeight: 520),
              child: _AccountPickerBody(
                title: title,
                initialAssets: assets,
                currentId: currentId,
                allowNone: allowNone,
                defaultAccountId: defaultAccountId,
                isDesktop: true,
                onSelect: (id) => Navigator.of(dialogCtx).pop(id),
                onOpenManager: () {
                  openedManager = true;
                  Navigator.of(dialogCtx).pop();
                },
                onClose: () => Navigator.of(dialogCtx).pop(),
                onReorderPersist: persistReorder,
              ),
            ),
          );
        },
      );
    } else {
      chosen = await showModalBottomSheet<int>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        sheetAnimationStyle: AnimationStyle.noAnimation,
        builder: (sheetCtx) {
          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(sheetCtx).height * 0.65,
              ),
              child: _AccountPickerBody(
                title: title,
                initialAssets: assets,
                currentId: currentId,
                allowNone: allowNone,
                defaultAccountId: defaultAccountId,
                isDesktop: false,
                onSelect: (id) => Navigator.pop(sheetCtx, id),
                onOpenManager: () {
                  openedManager = true;
                  Navigator.pop(sheetCtx);
                },
                onReorderPersist: persistReorder,
              ),
            ),
          );
        },
      );
    }
    if (!mounted) return;
    if (openedManager) {
      await _openAssetsManager();
      if (!mounted) return;
      await _refreshAndReconcileAccountsFromDb();
      if (!mounted) return;
      _focusDesktopAmountIfIdle();
      return;
    }
    if (didReorder) {
      await _refreshAndReconcileAccountsFromDb();
      if (!mounted) return;
    }
    if (chosen != null) {
      onSelected(chosen);
    }
    _focusDesktopAmountIfIdle();
  }

  Future<void> _openTagPickerSheet(List<Tag> tags) async {
    _unfocusOsKeyboardFields();
    if (_isDesktopActive) {
      await showDialog<void>(
        context: context,
        builder: (dialogCtx) {
          return Dialog(
            key: const Key('desktop-tag-picker-dialog'),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420, maxHeight: 500),
              child: StatefulBuilder(
                builder: (dialogCtx, setDialogState) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 16, 16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Text(
                              '选择标签',
                              style: Theme.of(dialogCtx).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                            const Spacer(),
                            TextButton.icon(
                              key: const Key('manage-tags-sheet-btn'),
                              onPressed: () {
                                Navigator.of(dialogCtx).pop();
                                _openTagsManager();
                              },
                              icon: const Icon(Icons.sell_outlined, size: 16),
                              label: const Text('管理标签'),
                            ),
                            CloseButton(
                              onPressed: () => Navigator.of(dialogCtx).pop(),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        if (tags.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 20),
                            child: Text(
                              '暂无可用标签，可点击右上角“管理标签”新建。',
                              textAlign: TextAlign.center,
                            ),
                          )
                        else
                          Flexible(
                            child: SingleChildScrollView(
                              child: Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  for (final t in tags)
                                    FilterChip(
                                      key: Key('tag-${t.name}'),
                                      avatar:
                                          t.color != null && t.color!.isNotEmpty
                                          ? TagColorDot(
                                              colorHex: t.color,
                                              size: 8,
                                            )
                                          : null,
                                      selectedColor: parseTagColor(
                                        t.color,
                                      )?.withValues(alpha: 0.22),
                                      label: Text(t.name),
                                      selected: selectedTagIds.contains(
                                        t.tagId,
                                      ),
                                      onSelected: (sel) {
                                        setState(() {
                                          if (sel) {
                                            selectedTagIds.add(t.tagId);
                                          } else {
                                            selectedTagIds.remove(t.tagId);
                                          }
                                        });
                                        setDialogState(() {});
                                      },
                                    ),
                                ],
                              ),
                            ),
                          ),
                        const SizedBox(height: 14),
                        FilledButton.tonal(
                          onPressed: () => Navigator.of(dialogCtx).pop(),
                          child: const Text('完成'),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          );
        },
      );
      if (mounted) {
        _focusDesktopAmountIfIdle();
      }
      return;
    }

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
    if (type == RecordType.transfer) return;
    _unfocusOsKeyboardFields();
    final ac = _currencyOf(assetId);
    final String? chosen;
    if (_isDesktopActive) {
      chosen = await showDialog<String>(
        context: context,
        builder: (dialogCtx) {
          final cs = Theme.of(dialogCtx).colorScheme;
          return Dialog(
            key: const Key('desktop-currency-picker-dialog'),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420, maxHeight: 520),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 10, 10),
                    child: Row(
                      children: [
                        Text(
                          '选择记账币种',
                          style: Theme.of(dialogCtx).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const Spacer(),
                        CloseButton(
                          onPressed: () => Navigator.of(dialogCtx).pop(),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      children: [
                        ListTile(
                          key: const Key('currency-option-follow-account'),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          leading: CircleAvatar(
                            radius: 15,
                            backgroundColor: cs.primaryContainer,
                            child: Icon(
                              Icons.account_balance_wallet_outlined,
                              size: 15,
                              color: cs.onPrimaryContainer,
                            ),
                          ),
                          title: Text('跟随账户币种（当前：$ac）'),
                          subtitle: const Text(
                            '切换资产账户时自动同步该账户币种',
                            style: TextStyle(fontSize: 12),
                          ),
                          trailing: sourceCurrency == null
                              ? Icon(Icons.check_rounded, color: cs.primary)
                              : null,
                          onTap: () => Navigator.of(
                            dialogCtx,
                          ).pop(_followAccountCurrencySentinel),
                        ),
                        const SizedBox(height: 4),
                        for (final c in currencies)
                          ListTile(
                            key: Key('currency-option-${c.code}'),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
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
                            trailing: sourceCurrency == c.code
                                ? Icon(Icons.check_rounded, color: cs.primary)
                                : null,
                            onTap: () => Navigator.of(dialogCtx).pop(c.code),
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
    } else {
      chosen = await showModalBottomSheet<String>(
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
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text(
                      '选择记账币种',
                      style: Theme.of(sheetCtx).textTheme.titleMedium,
                    ),
                  ),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        ListTile(
                          key: const Key('currency-option-follow-account'),
                          leading: CircleAvatar(
                            radius: 15,
                            backgroundColor: cs.primaryContainer,
                            child: Icon(
                              Icons.account_balance_wallet_outlined,
                              size: 15,
                              color: cs.onPrimaryContainer,
                            ),
                          ),
                          title: Text('跟随账户币种（当前：$ac）'),
                          subtitle: const Text(
                            '切换资产账户时自动同步该账户币种',
                            style: TextStyle(fontSize: 12),
                          ),
                          trailing: sourceCurrency == null
                              ? Icon(Icons.check_rounded, color: cs.primary)
                              : null,
                          onTap: () => Navigator.pop(
                            sheetCtx,
                            _followAccountCurrencySentinel,
                          ),
                        ),
                        const SizedBox(height: 4),
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
                            trailing: sourceCurrency == c.code
                                ? Icon(Icons.check_rounded, color: cs.primary)
                                : null,
                            onTap: () => Navigator.pop(sheetCtx, c.code),
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
    }
    if (!mounted) return;
    if (chosen != null) {
      setState(() {
        sourceCurrency = chosen == _followAccountCurrencySentinel
            ? null
            : chosen;
        convertedEdited = false;
        _autoConvert();
      });
    }
    _focusDesktopAmountIfIdle();
  }

  @override
  Widget build(BuildContext context) {
    final bookId =
        original?.accountBookId ??
        ref.watch(currentBookIdProvider).value ??
        _resolvedBookId;
    final categories = bookId == null
        ? const <RecordCategory>[]
        : (ref.watch(categoriesProvider(bookId)).value ??
              (bookId == _initialCategoriesBookId
                  ? _initialCategories
                  : const <RecordCategory>[]));
    final rawAssets = ref.watch(assetsProvider).value ?? _initialAssets;
    final rawAssetBooks =
        ref.watch(assetBooksProvider).value ?? _initialAssetBooks;
    final assetBookBindings = _buildAssetBookBindings(rawAssetBooks);
    final preservedEditAssetIds = <int>{
      if (editing && original != null) ...[
        if (original!.assetId != noRef) original!.assetId,
        if (original!.fromAssetId != noRef) original!.fromAssetId,
        if (original!.toAssetId != noRef) original!.toAssetId,
      ],
    };
    final assets = rawAssets.where((a) {
      if (preservedEditAssetIds.contains(a.id)) {
        return a.type != AssetType.debt;
      }
      return a.status == AssetStatus.active &&
          a.type != AssetType.debt &&
          _isAssetVisibleInBook(a.id, bookId, assetBookBindings);
    }).toList();
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
    final effectiveDefaultAccountId = editing
        ? noRef
        : _computeEffectiveDefaultAccountId(
            config: diyConfig,
            bookId: bookId,
            assets: rawAssets,
            assetBookBindings: assetBookBindings,
          );

    void reconcileCreateModeAccountsFromLiveCatalog({
      required List<Asset> latestAssets,
      required List<AssetBook> latestAssetBooks,
      int? latestBookId,
      DiyToolbarConfig? prevConfig,
      DiyToolbarConfig? latestConfig,
    }) {
      if (loading || editing) return;
      final currentBookId =
          latestBookId ??
          original?.accountBookId ??
          ref.read(currentBookIdProvider).value ??
          _resolvedBookId;
      final latestBindings = _buildAssetBookBindings(latestAssetBooks);
      final currentCfg =
          latestConfig ??
          ref.read(diyToolbarConfigProvider).value ??
          DiyToolbarConfig.defaults();
      final prevEffective = prevConfig == null
          ? null
          : _computeEffectiveDefaultAccountId(
              config: prevConfig,
              bookId: currentBookId,
              assets: latestAssets,
              assetBookBindings: latestBindings,
            );
      _initialAssets = latestAssets;
      _initialAssetBooks = latestAssetBooks;
      final reconciled = _computeReconciledCreateModeAccounts(
        bookId: currentBookId,
        latestAssets: latestAssets,
        latestBindings: latestBindings,
        latestConfig: currentCfg,
        previousEffectiveDefaultId: prevEffective,
      );
      if (reconciled.changed) {
        setState(() {
          assetId = reconciled.assetId;
          fromAssetId = reconciled.fromAssetId;
          toAssetId = reconciled.toAssetId;
          convertedEdited = false;
          _autoConvert();
        });
      }
    }

    ref.listen<AsyncValue<List<Asset>>>(assetsProvider, (_, next) {
      if (!next.hasValue) return;
      reconcileCreateModeAccountsFromLiveCatalog(
        latestAssets: next.value!,
        latestAssetBooks:
            ref.read(assetBooksProvider).value ?? _initialAssetBooks,
      );
    });

    ref.listen<AsyncValue<List<AssetBook>>>(assetBooksProvider, (_, next) {
      if (!next.hasValue) return;
      reconcileCreateModeAccountsFromLiveCatalog(
        latestAssets: ref.read(assetsProvider).value ?? _initialAssets,
        latestAssetBooks: next.value!,
      );
    });

    ref.listen<AsyncValue<int>>(currentBookIdProvider, (_, next) {
      if (!next.hasValue) return;
      _resolvedBookId = next.value;
      reconcileCreateModeAccountsFromLiveCatalog(
        latestAssets: ref.read(assetsProvider).value ?? _initialAssets,
        latestAssetBooks:
            ref.read(assetBooksProvider).value ?? _initialAssetBooks,
        latestBookId: next.value,
      );
    });

    ref.listen<AsyncValue<AppSettings>>(appSettingsProvider, (prev, next) {
      if (editing ||
          widget.initialType != null ||
          widget.initialTemplateId != null ||
          widget.initialCategory != null ||
          _userTouchedType ||
          _userTouchedCategory ||
          amount.text.isNotEmpty ||
          remark.text.isNotEmpty) {
        return;
      }
      if (prev?.hasValue == true || !next.hasValue) return;
      final nextDefaultType = next.value!.defaultRecordType;
      if (!allowedDefaultRecordTypes.contains(nextDefaultType) ||
          nextDefaultType == type) {
        return;
      }
      if (!loading) {
        _switchRecordTypeTo(
          nextDefaultType,
          categories: categories,
          diyConfig: diyConfig,
          effectiveDefaultAccountId: effectiveDefaultAccountId,
          markUserTouchedType: false,
        );
      } else {
        setState(() {
          type = nextDefaultType;
          if (type == RecordType.transfer &&
              fromAssetId == noRef &&
              widget.initialFrom == null &&
              widget.initialAsset != null) {
            fromAssetId = widget.initialAsset!;
            assetId = noRef;
          }
        });
      }
    });

    ref.listen<AsyncValue<DiyToolbarConfig>>(diyToolbarConfigProvider, (
      prev,
      next,
    ) {
      if (_inFlightStyleSaves == 0 && next.hasValue) {
        _localDatePickerStyle = null;
        _localTimePickerStyle = null;
      }
      final wasEnabled =
          prev?.value?.isEnabled(DiyToolbarAction.autoSelectFirstCategory) ??
          false;
      final nowEnabled =
          next.value?.isEnabled(DiyToolbarAction.autoSelectFirstCategory) ??
          false;
      if (!wasEnabled &&
          nowEnabled &&
          !loading &&
          !editing &&
          type != RecordType.transfer &&
          categoryId == null &&
          !_userTouchedCategory) {
        final currentBookId =
            original?.accountBookId ??
            ref.read(currentBookIdProvider).value ??
            _resolvedBookId;
        final currentCats = currentBookId == null
            ? const <RecordCategory>[]
            : (ref.read(categoriesProvider(currentBookId)).value ??
                  (currentBookId == _initialCategoriesBookId
                      ? _initialCategories
                      : const <RecordCategory>[]));
        final first = _firstTopCategoryForType(type, currentCats);
        if (first != null) {
          setState(() {
            categoryId = first.id;
            parentCatId = first.id;
            _remarksShowAllScope = false;
          });
        }
      }
      if (!loading && !editing && next.hasValue) {
        reconcileCreateModeAccountsFromLiveCatalog(
          latestAssets: ref.read(assetsProvider).value ?? _initialAssets,
          latestAssetBooks:
              ref.read(assetBooksProvider).value ?? _initialAssetBooks,
          prevConfig: prev?.value,
          latestConfig: next.value!,
        );
      }
    });

    if (!loading && !editing) {
      final hasStaleHeldAsset =
          (assetId != noRef && !assets.any((a) => a.id == assetId)) ||
          (fromAssetId != noRef && !assets.any((a) => a.id == fromAssetId)) ||
          (toAssetId != noRef && !assets.any((a) => a.id == toAssetId));
      if (hasStaleHeldAsset) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || loading || editing) return;
          reconcileCreateModeAccountsFromLiveCatalog(
            latestAssets: ref.read(assetsProvider).value ?? _initialAssets,
            latestAssetBooks:
                ref.read(assetBooksProvider).value ?? _initialAssetBooks,
          );
        });
      }
    }

    final isDesktop = DesktopAdaptive.isDesktop(context);
    final embeddedInDialog = _isEmbeddedInDesktopDialog;
    final canSubmit = !busy && !loading && (!editing || original != null);
    final canPopRoute =
        embeddedInDialog ||
        (GoRouter.maybeOf(context)?.canPop() ?? false) ||
        Navigator.of(context).canPop();

    if (isDesktop && !loading) {
      _ensureInitialDesktopFocusScheduled();
    }

    Widget buildEditorContent() {
      final column = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Zone 1: Compact Type Bar (primary tabs + secondary pills)
          _buildTypeSwitcherBar(
            context,
            categories: categories,
            diyConfig: diyConfig,
            effectiveDefaultAccountId: effectiveDefaultAccountId,
          ),
          // Zone 2 + Zone 3: Scrollable middle zone + unified bottom dock & slot
          Expanded(
            child: LayoutBuilder(
              builder: (context, areaConstraints) {
                return _buildMiddleAndBottomZones(
                  context,
                  areaConstraints: areaConstraints,
                  bookId: bookId,
                  categories: categories,
                  assets: assets,
                  tags: tags,
                  currencies: currencies,
                  diyConfig: diyConfig,
                  effectiveDefaultAccountId: effectiveDefaultAccountId,
                  canSubmit: canSubmit,
                );
              },
            ),
          ),
        ],
      );
      if (isDesktop && embeddedInDialog) {
        return column;
      }
      return Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: isDesktop ? 620 : 680),
          child: column,
        ),
      );
    }

    final scaffold = Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        toolbarHeight: 48,
        leading: canPopRoute
            ? (isDesktop && embeddedInDialog
                  ? CloseButton(
                      key: const Key('desktop-editor-close-btn'),
                      onPressed: busy ? null : _closeEditor,
                    )
                  : BackButton(onPressed: busy ? null : _closeEditor))
            : null,
        title: Text(editing ? '编辑账单' : '记一笔'),
        actions: [
          if (!editing && diyConfig.isEnabled(DiyToolbarAction.templates))
            IconButton(
              key: const Key('editor-templates-btn'),
              tooltip: '账单模板',
              icon: const Icon(Icons.bookmarks_outlined, size: 21),
              onPressed: busy ? null : _openTemplatesManager,
            ),
          if (!editing)
            IconButton(
              key: const Key('record_editor_smart_fill_button'),
              visualDensity: VisualDensity.compact,
              tooltip: '智能识账速填',
              icon: const Icon(Icons.auto_awesome_outlined, size: 21),
              onPressed: busy ? null : _openSmartQuickPrefill,
            ),
          IconButton(
            key: const Key('editor-diy-toolbar-btn'),
            tooltip: '记账工具栏自定义',
            icon: const Icon(Icons.tune, size: 21),
            onPressed: busy
                ? null
                : () {
                    if (_isDesktopActive) {
                      unawaited(
                        pushDesktopModalOrMaterialRoute<void>(
                          context,
                          maxWidth: 760,
                          maxHeight: 700,
                          child: const DiyToolbarSettingsPage(),
                        ),
                      );
                    } else if (!_isImperativeDialogRoute &&
                        GoRouter.maybeOf(context) != null) {
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
      body: loading ? const Loading() : buildEditorContent(),
    );

    return PopScope(
      canPop:
          !busy && (isDesktop || _panelMode == _BottomPanelMode.customKeypad),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !busy && !isDesktop) {
          _activateCustomKeypad();
        }
      },
      child: isDesktop
          ? Focus(focusNode: _desktopScopeFocus, child: scaffold)
          : scaffold,
    );
  }

  int _countVisibleToolbarPills(
    DiyToolbarConfig diyConfig,
    List<Currency> currencies,
  ) {
    var count = 1 + (type != RecordType.transfer ? 1 : 0);
    for (final item in diyConfig.items) {
      switch (item.action) {
        case DiyToolbarAction.tags:
          if (item.enabled || selectedTagIds.isNotEmpty) count++;
        case DiyToolbarAction.discount:
          if ((type == RecordType.expense || type == RecordType.income) &&
              (item.enabled || discount.text.trim().isNotEmpty)) {
            count++;
          }
        case DiyToolbarAction.images:
          if (item.enabled || imageNames.isNotEmpty) count++;
        case DiyToolbarAction.location:
          if (item.enabled || (location != null && !location!.isEmpty)) {
            count++;
          }
        case DiyToolbarAction.currency:
          if (type != RecordType.transfer) {
            final (sc, acctCurr) = _currencies();
            if ((item.enabled && currencies.length > 1) ||
                (sourceCurrency != null && sc != acctCurr)) {
              count++;
            }
          }
        case DiyToolbarAction.excludeExIn:
          if (type != RecordType.transfer && (item.enabled || excludeExIn)) {
            count++;
          }
        case DiyToolbarAction.excludeBudget:
          if (type != RecordType.transfer && (item.enabled || excludeBudget)) {
            count++;
          }
        case DiyToolbarAction.templates:
        case DiyToolbarAction.frequentRemarks:
        case DiyToolbarAction.keypadMultiplyDivide:
        case DiyToolbarAction.autoSelectFirstCategory:
          break;
      }
    }
    return count;
  }

  Widget _buildMiddleAndBottomZones(
    BuildContext context, {
    required BoxConstraints areaConstraints,
    required int? bookId,
    required List<RecordCategory> categories,
    required List<Asset> assets,
    required List<Tag> tags,
    required List<Currency> currencies,
    required DiyToolbarConfig diyConfig,
    required int effectiveDefaultAccountId,
    required bool canSubmit,
  }) {
    final isDesktop = DesktopAdaptive.isDesktop(context);
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final mediaQuery = MediaQuery.of(context);
    final trayColor = isDark
        ? cs.surfaceContainerLowest
        : cs.surfaceContainerLow;

    if (isDesktop) {
      final rawTextScale = MediaQuery.textScalerOf(context).scale(1.0);
      final textScale = rawTextScale.clamp(1.0, 2.0);
      final scaleDelta = textScale - 1.0;
      final compactViewport = areaConstraints.maxHeight < 580.0;
      final minMiddleZoneHeight = areaConstraints.maxHeight < 260.0
          ? (areaConstraints.maxHeight * 0.45).clamp(0.0, 120.0)
          : (compactViewport
                ? (scaleDelta > 0.05 ? 124.0 : 132.0)
                : math.min(
                    186.0,
                    math.max(146.0, areaConstraints.maxHeight * 0.26),
                  ));
      final maxDockHeight = math.max(
        0.0,
        areaConstraints.maxHeight - minMiddleZoneHeight,
      );

      final (sc, ac) = _currencies();
      final showBudgetHint =
          bookId != null &&
          categoryId != null &&
          !excludeBudget &&
          (type == RecordType.expense ||
              type == RecordType.income ||
              type == RecordType.reimbursable);
      final showAttachments =
          (_attachmentsExpanded || imageNames.isNotEmpty) &&
          (diyConfig.isEnabled(DiyToolbarAction.images) ||
              imageNames.isNotEmpty);
      final pillCount = _countVisibleToolbarPills(diyConfig, currencies);
      final innerWidth = math.max(200.0, areaConstraints.maxWidth - 24.0);
      final avgPillWidth = 78.0 * textScale;
      final pillRows = pillCount <= 1
          ? 1
          : ((pillCount * avgPillWidth) / innerWidth).ceil().clamp(1, 4);
      final singlePillHeight = scaleDelta > 0.02
          ? math.max(24.0, (7.0 + 17.5 * textScale).ceilToDouble())
          : 24.0;
      final minPillToolbarVisibleHeight = math.max(
        30.0,
        singlePillHeight + 6.0,
      );

      final summaryAmountReserve =
          43.0 +
          28.0 * scaleDelta +
          (hasPendingOperator(amount.text) ? 15.0 * textScale + 2.0 : 0.0) +
          (sc != ac ? 17.0 * textScale + 2.0 : 0.0);
      final budgetBannerReserve = showBudgetHint
          ? (12.0 + 18.0 * textScale)
          : 0.0;
      final savedBannerReserve = (_savedAndResetBanner && error == null)
          ? (26.0 + 16.0 * scaleDelta)
          : 0.0;
      double errorBannerReserve = 0.0;
      if (error != null) {
        final errorAvailW = math.max(120.0, areaConstraints.maxWidth - 68.0);
        final estErrorW = error!.runes.length * 12.5 * textScale;
        final isTwoLineError =
            error!.contains('\n') || estErrorW > errorAvailW * 0.80;
        errorBannerReserve = isTwoLineError
            ? (14.0 + 36.0 * textScale)
            : (12.0 + 18.0 * textScale);
      }
      final remarkRowReserve =
          (scaleDelta > 0.02
              ? (20.0 + 18.0 * textScale).ceilToDouble()
              : 38.0) +
          6.0;

      final showRemarksActionBtn =
          diyConfig.isEnabled(DiyToolbarAction.frequentRemarks) &&
          type != RecordType.transfer;
      final compactActionBar = areaConstraints.maxWidth < 550.0 * textScale;
      final estLeftActionW =
          (41.0 + 39.0 * textScale) +
          (showRemarksActionBtn ? (47.0 + 52.0 * textScale) : 0.0);
      final estRightActionW = compactActionBar
          ? (60.0 + 70.0 * textScale)
          : (60.0 + 220.0 * textScale);
      final actionBarInnerW = math.max(120.0, areaConstraints.maxWidth - 24.0);
      final actionBarWraps =
          (estLeftActionW + 8.0 + estRightActionW) > actionBarInnerW * 0.94;
      final singleActionRowH = scaleDelta > 0.02
          ? math.max(34.0, (14.0 + 19.0 * textScale).ceilToDouble())
          : 34.0;
      final actionBarReserve = actionBarWraps
          ? (15.0 + singleActionRowH * 2.0 + 6.0)
          : (15.0 + singleActionRowH);

      final pinnedDockReserve =
          summaryAmountReserve +
          budgetBannerReserve +
          savedBannerReserve +
          errorBannerReserve +
          remarkRowReserve +
          actionBarReserve +
          (scaleDelta > 0.02 ? 4.0 * scaleDelta : 0.0);
      final pillAndAttachmentReserve =
          (pillRows * singlePillHeight + (pillRows - 1) * 4.0 + 6.0) +
          (showAttachments ? 72.0 : 0.0);
      final idealAvailableForPanel = math.max(
        0.0,
        maxDockHeight - pinnedDockReserve - pillAndAttachmentReserve,
      );
      final hardMaxPanelHeight = math.max(
        0.0,
        maxDockHeight - pinnedDockReserve - minPillToolbarVisibleHeight,
      );

      double? desktopKeypadKeyHeight;
      double desktopPanelSlotHeight = 0.0;
      if (_desktopKeypadExpanded) {
        final maxKeyH = compactViewport
            ? 40.0
            : RecordCustomKeypad.desktopDefaultKeyRowHeight;
        final minStandardPanelH =
            RecordCustomKeypad.desktopPanelHeightForKeyHeight(
              RecordCustomKeypad.desktopMinKeyRowHeight,
            );
        if (idealAvailableForPanel >= minStandardPanelH) {
          desktopKeypadKeyHeight = RecordCustomKeypad.resolveDesktopKeyHeight(
            idealAvailableForPanel,
            maxKeyHeight: maxKeyH,
            minKeyHeight: RecordCustomKeypad.desktopMinKeyRowHeight,
          );
        } else {
          final targetPanelAvail = idealAvailableForPanel > 0
              ? idealAvailableForPanel
              : hardMaxPanelHeight;
          final safeMinKeyH = math.min(
            30.0,
            math.max(22.0, (hardMaxPanelHeight - 25.0) / 4.0),
          );
          desktopKeypadKeyHeight = RecordCustomKeypad.resolveDesktopKeyHeight(
            targetPanelAvail,
            maxKeyHeight: maxKeyH,
            minKeyHeight: safeMinKeyH,
          );
        }
        desktopPanelSlotHeight = math.min(
          RecordCustomKeypad.desktopPanelHeightForKeyHeight(
            desktopKeypadKeyHeight,
          ),
          hardMaxPanelHeight,
        );
      } else if (_desktopRemarksExpanded && type != RecordType.transfer) {
        desktopPanelSlotHeight = math.min(
          compactViewport ? 156.0 : 184.0,
          hardMaxPanelHeight,
        );
      }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _buildScrollableMiddleZone(
              context,
              bookId: bookId,
              categories: categories,
              assets: assets,
              diyConfig: diyConfig,
              effectiveDefaultAccountId: effectiveDefaultAccountId,
            ),
          ),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxDockHeight),
            child: _buildBottomDock(
              context,
              bookId: bookId,
              categories: categories,
              assets: assets,
              tags: tags,
              currencies: currencies,
              diyConfig: diyConfig,
              canSubmit: canSubmit,
              panelSlotHeight: desktopPanelSlotHeight,
              desktopKeypadKeyHeight: desktopKeypadKeyHeight,
              bottomSafePadding: 0.0,
            ),
          ),
        ],
      );
    }

    final imeHeight = mediaQuery.viewInsets.bottom;
    final basePanelHeight =
        RecordCustomKeypad.panelHeight + mediaQuery.padding.bottom;
    final rawTargetSlotHeight = math.max(basePanelHeight, imeHeight);

    final double minMiddleHeight;
    if (areaConstraints.maxHeight >= 240.0) {
      final baseMinMiddle = (areaConstraints.maxHeight * 0.22).clamp(
        84.0,
        132.0,
      );
      minMiddleHeight = imeHeight > 0
          ? math.min(
              baseMinMiddle,
              math.max(84.0, areaConstraints.maxHeight - imeHeight - 112.0),
            )
          : baseMinMiddle;
    } else {
      minMiddleHeight = math
          .max(48.0, areaConstraints.maxHeight * 0.30)
          .clamp(0.0, areaConstraints.maxHeight * 0.45);
    }
    final maxBottomHeight = math.max(
      0.0,
      areaConstraints.maxHeight - minMiddleHeight,
    );

    final minDockHeaderReserve = math.min(112.0, maxBottomHeight * 0.48);
    final maxAllowedSlotHeight = math.max(
      0.0,
      maxBottomHeight - minDockHeaderReserve,
    );
    final targetSlotHeight = math.min(
      rawTargetSlotHeight,
      maxAllowedSlotHeight,
    );
    final panelSlotHeight = math.min(basePanelHeight, targetSlotHeight);
    final extraImeSpacer = math.max(0.0, targetSlotHeight - panelSlotHeight);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: _buildScrollableMiddleZone(
            context,
            bookId: bookId,
            categories: categories,
            assets: assets,
            diyConfig: diyConfig,
            effectiveDefaultAccountId: effectiveDefaultAccountId,
          ),
        ),
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxBottomHeight),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Flexible(
                fit: FlexFit.loose,
                child: _buildBottomDock(
                  context,
                  bookId: bookId,
                  categories: categories,
                  assets: assets,
                  tags: tags,
                  currencies: currencies,
                  diyConfig: diyConfig,
                  canSubmit: canSubmit,
                  panelSlotHeight: panelSlotHeight,
                  bottomSafePadding: mediaQuery.padding.bottom,
                ),
              ),
              if (_panelMode == _BottomPanelMode.osKeyboard)
                Container(
                  key: const Key('editor-bottom-panel-slot'),
                  height: targetSlotHeight,
                  color: trayColor,
                )
              else if (extraImeSpacer > 0)
                Container(height: extraImeSpacer, color: trayColor),
            ],
          ),
        ),
      ],
    );
  }

  void _switchRecordTypeTo(
    int nextType, {
    required List<RecordCategory> categories,
    required DiyToolbarConfig diyConfig,
    required int effectiveDefaultAccountId,
    bool markUserTouchedType = true,
  }) {
    if (busy || editing || type == nextType) return;
    if (_feeFocus.hasFocus && nextType != RecordType.transfer) {
      _feeFocus.unfocus();
    }
    setState(() {
      type = nextType;
      if (markUserTouchedType) {
        _userTouchedType = true;
      }
      _userTouchedCategory = false;
      if (nextType != RecordType.expense && nextType != RecordType.income) {
        discount.clear();
      }
      if (nextType == RecordType.transfer) {
        categoryId = null;
        parentCatId = null;
        sourceCurrency = null;
        convertedEdited = false;
        _desktopRemarksExpanded = false;
        if (_panelMode == _BottomPanelMode.frequentRemarks) {
          _panelMode = _BottomPanelMode.customKeypad;
        }
        if (!_userTouchedAsset && fromAssetId == noRef) {
          fromAssetId =
              (effectiveDefaultAccountId != noRef &&
                  effectiveDefaultAccountId != toAssetId)
              ? effectiveDefaultAccountId
              : noRef;
        }
      } else {
        if (diyConfig.isEnabled(DiyToolbarAction.autoSelectFirstCategory)) {
          final first = _firstTopCategoryForType(nextType, categories);
          categoryId = first?.id;
          parentCatId = first?.id;
        } else {
          categoryId = null;
          parentCatId = null;
        }
        if (!_userTouchedAsset && assetId == noRef) {
          assetId = effectiveDefaultAccountId;
        }
      }
      _remarksShowAllScope = false;
      _autoConvert();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final chipFinder = Key('type-$nextType');
      Element? targetElement;
      void visit(Element el) {
        if (targetElement != null) return;
        if (el.widget.key == chipFinder) {
          targetElement = el;
          return;
        }
        el.visitChildren(visit);
      }

      context.visitChildElements(visit);
      if (targetElement != null) {
        unawaited(
          Scrollable.ensureVisible(
            targetElement!,
            alignment: 0.5,
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
          ),
        );
      }
    });
    _focusDesktopAmountIfIdle();
  }

  void _stepRecordTypeBySwipe(
    int delta, {
    required List<RecordCategory> categories,
    required DiyToolbarConfig diyConfig,
    required int effectiveDefaultAccountId,
  }) {
    if (busy || editing || loading) return;
    final currentIdx = _creatableRecordTypes.indexOf(type);
    if (currentIdx < 0) return;
    final targetIdx = (currentIdx + delta).clamp(
      0,
      _creatableRecordTypes.length - 1,
    );
    if (targetIdx == currentIdx) return;
    _switchRecordTypeTo(
      _creatableRecordTypes[targetIdx],
      categories: categories,
      diyConfig: diyConfig,
      effectiveDefaultAccountId: effectiveDefaultAccountId,
    );
  }

  Widget _buildHorizontalSwipeShield({required Widget child}) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        _lastBlockedMiddlePointer = event.pointer;
        _middleSwipeBlockedByChild = true;
      },
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: (_) {},
        onHorizontalDragUpdate: (_) {},
        onHorizontalDragEnd: (_) {},
        child: child,
      ),
    );
  }

  Widget _buildTypeSwitcherBar(
    BuildContext context, {
    required List<RecordCategory> categories,
    required DiyToolbarConfig diyConfig,
    required int effectiveDefaultAccountId,
  }) {
    final isDesktop = DesktopAdaptive.isDesktop(context);
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final unselectedBg = isDark
        ? cs.surfaceContainerHigh.withAlpha(155)
        : cs.surfaceContainerLow;

    ChoiceChip buildChip(int value, String label, {required bool primary}) {
      final selected = type == value;
      return ChoiceChip(
        key: Key('type-$value'),
        showCheckmark: false,
        visualDensity: isDesktop
            ? VisualDensity.compact
            : (primary
                  ? const VisualDensity(horizontal: -1, vertical: -2)
                  : const VisualDensity(horizontal: -2, vertical: -3)),
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: isDesktop
            ? const EdgeInsets.symmetric(horizontal: 10, vertical: 4)
            : EdgeInsets.symmetric(horizontal: primary ? 8 : 5, vertical: 0),
        shape: const StadiumBorder(),
        side: BorderSide.none,
        selectedColor: primary ? cs.primary : cs.secondaryContainer,
        backgroundColor: unselectedBg,
        labelStyle: TextStyle(
          fontSize: isDesktop ? 13 : (primary ? 13 : 11.5),
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          color: selected
              ? (primary ? cs.onPrimary : cs.onSecondaryContainer)
              : (primary ? cs.onSurface : cs.onSurfaceVariant),
        ),
        label: Text(label),
        selected: selected,
        onSelected: busy || editing
            ? null
            : (_) => _switchRecordTypeTo(
                value,
                categories: categories,
                diyConfig: diyConfig,
                effectiveDefaultAccountId: effectiveDefaultAccountId,
              ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          buildChip(RecordType.expense, '支出', primary: true),
          const SizedBox(width: 6),
          buildChip(RecordType.income, '收入', primary: true),
          const SizedBox(width: 6),
          buildChip(RecordType.transfer, '转账', primary: true),
          const SizedBox(width: 10),
          buildChip(RecordType.reimbursable, '报销', primary: false),
          const SizedBox(width: 6),
          buildChip(RecordType.advanceExpense, '预支', primary: false),
          const SizedBox(width: 6),
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
    required int effectiveDefaultAccountId,
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

    final scrollView = CustomScrollView(
      key: const Key('editor-zone2-scroll'),
      slivers: [
        if (!editing &&
            bookId != null &&
            diyConfig.isEnabled(DiyToolbarAction.templates))
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            sliver: SliverToBoxAdapter(
              child: _buildHorizontalSwipeShield(
                child: TemplateQuickBar(
                  bookId: bookId,
                  recordType: type,
                  enabled: !busy,
                  recordTimeMs: time.millisecondsSinceEpoch,
                  onPrefill: _applyTemplatePrefill,
                  onInstantSaved: (savedId) {
                    if (!mounted) return;
                    _closeEditor(savedId);
                  },
                ),
              ),
            ),
          ),
        if (type == RecordType.transfer)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            sliver: SliverToBoxAdapter(
              child: _buildTransferCard(context, assets, diyConfig: diyConfig),
            ),
          )
        else ...[
          if (subCats.isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              sliver: SliverToBoxAdapter(
                child: _buildHorizontalSwipeShield(
                  child: RecordSubcategoryStrip(
                    parentCategory: selectedParent,
                    subCategories: subCats,
                    selectedCategoryId: categoryId,
                    enabled: !busy,
                    onSelectCategoryId: (id) {
                      setState(() {
                        _userTouchedCategory = true;
                        categoryId = id;
                        _remarksShowAllScope = false;
                      });
                      _focusDesktopAmountIfIdle();
                    },
                  ),
                ),
              ),
            ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
            sliver: RecordCategorySliverGrid(
              categories: topCats,
              selectedParentId: parentCatId,
              enabled: !busy,
              onSelectCategory: (cat) {
                setState(() {
                  _userTouchedCategory = true;
                  parentCatId = cat.id;
                  categoryId = cat.id;
                  _remarksShowAllScope = false;
                });
                _focusDesktopAmountIfIdle();
              },
              onManageCategories: _openCategoriesManager,
            ),
          ),
        ],
      ],
    );

    if (editing) {
      return scrollView;
    }

    void resetMiddleSwipeTracking() {
      _middleActivePointer = null;
      _middlePointerDownPos = null;
      _middlePointerDownTime = null;
      _middleTotalDelta = Offset.zero;
      _middleDragDx = 0.0;
      _middleSwipeBlockedByChild = false;
      _middleDragHandledByArena = false;
    }

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        _middleActivePointer = event.pointer;
        _middlePointerDownPos = event.position;
        _middlePointerDownTime = event.timeStamp;
        _middleTotalDelta = Offset.zero;
        _middleSwipeBlockedByChild = _lastBlockedMiddlePointer == event.pointer;
        _middleDragHandledByArena = false;
      },
      onPointerMove: (event) {
        if (event.pointer != _middleActivePointer) return;
        final start = _middlePointerDownPos;
        if (start != null) {
          _middleTotalDelta = event.position - start;
        }
      },
      onPointerUp: (event) {
        if (event.pointer != _middleActivePointer) return;
        if (_middleDragHandledByArena) {
          // GestureDetector won the arena; let onHorizontalDragEnd/Cancel read
          // _middlePointerDownPos & _middleTotalDelta and reset state there.
          return;
        }
        final start = _middlePointerDownPos;
        final downTime = _middlePointerDownTime;
        final delta = start != null
            ? (event.position - start)
            : _middleTotalDelta;
        final blocked = _middleSwipeBlockedByChild;
        resetMiddleSwipeTracking();
        if (blocked) {
          return;
        }
        final dx = delta.dx;
        final dy = delta.dy;
        if (dx.abs() <= dy.abs() * 1.5) {
          return;
        }
        final elapsedUs = downTime == null
            ? 0
            : (event.timeStamp - downTime).inMicroseconds;
        final vx = elapsedUs > 0 ? dx * 1000000.0 / elapsedUs : 0.0;
        final vy = elapsedUs > 0 ? dy * 1000000.0 / elapsedUs : 0.0;
        final validDistance = dx.abs() > 48.0;
        final validFling =
            dx.abs() > 24.0 &&
            vx.abs() > 360.0 &&
            vx.abs() > vy.abs() * 1.5 &&
            vx.sign == dx.sign;
        if (!validDistance && !validFling) {
          return;
        }
        _stepRecordTypeBySwipe(
          dx < 0 ? 1 : -1,
          categories: categories,
          diyConfig: diyConfig,
          effectiveDefaultAccountId: effectiveDefaultAccountId,
        );
      },
      onPointerCancel: (event) {
        if (event.pointer == _middleActivePointer) {
          resetMiddleSwipeTracking();
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: (_) {
          _middleDragHandledByArena = true;
          _middleDragDx = 0.0;
        },
        onHorizontalDragUpdate: (details) {
          _middleDragDx += details.primaryDelta ?? details.delta.dx;
        },
        onHorizontalDragCancel: () {
          // A child recognizer (e.g. unfocused TextField's eager drag recognizer)
          // may reject our HorizontalDragGestureRecognizer mid-move; keep pointer
          // tracking alive until onPointerUp / onPointerCancel decides.
          _middleDragDx = 0.0;
          _middleDragHandledByArena = false;
        },
        onHorizontalDragEnd: (details) {
          final blocked = _middleSwipeBlockedByChild;
          final dx = _middlePointerDownPos != null
              ? _middleTotalDelta.dx
              : _middleDragDx;
          final dy = _middlePointerDownPos != null ? _middleTotalDelta.dy : 0.0;
          resetMiddleSwipeTracking();
          if (blocked || dx.abs() <= dy.abs() * 1.5) {
            return;
          }
          final vx =
              details.primaryVelocity ?? details.velocity.pixelsPerSecond.dx;
          final vy = details.velocity.pixelsPerSecond.dy;
          final validDistance = dx.abs() > 48.0;
          final validFling =
              dx.abs() > 24.0 &&
              vx.abs() > 360.0 &&
              vx.abs() > vy.abs() * 1.5 &&
              vx.sign == dx.sign;
          if (!validDistance && !validFling) {
            return;
          }
          _stepRecordTypeBySwipe(
            dx < 0 ? 1 : -1,
            categories: categories,
            diyConfig: diyConfig,
            effectiveDefaultAccountId: effectiveDefaultAccountId,
          );
        },
        child: scrollView,
      ),
    );
  }

  Widget _buildTransferCard(
    BuildContext context,
    List<Asset> assets, {
    required DiyToolbarConfig diyConfig,
  }) {
    final cs = Theme.of(context).colorScheme;
    final fromAsset = assets.where((a) => a.id == fromAssetId).firstOrNull;
    final toAsset = assets.where((a) => a.id == toAssetId).firstOrNull;
    final configuredDefaultId = diyConfig.autoSelectDefaultAccount
        ? diyConfig.defaultAccountId
        : noRef;
    final isDesktop = DesktopAdaptive.isDesktop(context);
    final textScale = MediaQuery.textScalerOf(context).scale(1.0);
    final desktopTransferRowHeight = math.max(
      44.0,
      (24.0 + 18.0 * textScale).ceilToDouble(),
    );

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
                      defaultAccountId: configuredDefaultId,
                      onSelected: (v) => setState(() {
                        _userTouchedAsset = true;
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
                          _userTouchedAsset = true;
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
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: isDesktop ? desktopTransferRowHeight : 42,
                ),
                child: Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: (event) {
                    if (_feeFocus.hasFocus) {
                      _lastBlockedMiddlePointer = event.pointer;
                      _middleSwipeBlockedByChild = true;
                    }
                  },
                  child: TextField(
                    key: const Key('fee'),
                    controller: fee,
                    focusNode: _feeFocus,
                    enabled: !busy,
                    enableInteractiveSelection: _feeFocus.hasFocus,
                    scrollPhysics: _feeFocus.hasFocus
                        ? null
                        : const NeverScrollableScrollPhysics(),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    textInputAction: TextInputAction.done,
                    onEditingComplete: () {
                      if (!_isDesktopActive) {
                        _activateCustomKeypad();
                      }
                    },
                    onSubmitted: (_) {
                      if (_isDesktopActive) {
                        _triggerDesktopEnter();
                      } else {
                        _activateCustomKeypad();
                      }
                    },
                    inputFormatters: amountInputFormatters,
                    style: const TextStyle(fontSize: 14),
                    decoration: InputDecoration(
                      labelText: '手续费（可选）',
                      prefixText:
                          '${feeFromTarget ? _currencies().$2 : _currencies().$1} ',
                      isDense: !isDesktop,
                      constraints: isDesktop
                          ? BoxConstraints.tightFor(
                              height: desktopTransferRowHeight,
                            )
                          : null,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: isDesktop ? 10 : 10,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: isDesktop ? desktopTransferRowHeight : null,
              child: FilterChip(
                key: const Key('transfer-fee-side-toggle'),
                visualDensity: isDesktop
                    ? VisualDensity.standard
                    : VisualDensity.compact,
                materialTapTargetSize: isDesktop
                    ? MaterialTapTargetSize.shrinkWrap
                    : null,
                padding: isDesktop
                    ? const EdgeInsets.symmetric(horizontal: 10, vertical: 6)
                    : null,
                label: Text(
                  feeFromTarget ? '转入方扣费' : '转出方扣费',
                  style: const TextStyle(fontSize: 12),
                ),
                selected: feeFromTarget,
                onSelected: busy
                    ? null
                    : (v) => setState(() => feeFromTarget = v),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildBottomDock(
    BuildContext context, {
    required int? bookId,
    required List<RecordCategory> categories,
    required List<Asset> assets,
    required List<Tag> tags,
    required List<Currency> currencies,
    required DiyToolbarConfig diyConfig,
    required bool canSubmit,
    required double panelSlotHeight,
    required double bottomSafePadding,
    double? desktopKeypadKeyHeight,
  }) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final trayColor = isDark
        ? cs.surfaceContainerLowest
        : cs.surfaceContainerLow;
    final (sc, ac) = _currencies();
    final pendingOp = hasPendingOperator(amount.text);
    final remarksEnabled = diyConfig.isEnabled(
      DiyToolbarAction.frequentRemarks,
    );
    final enableMulDiv = diyConfig.isEnabled(
      DiyToolbarAction.keypadMultiplyDivide,
    );

    String? livePreview;
    if (pendingOp) {
      try {
        final previewRes = evaluateKeypadExpression(amount.text);
        if (!previewRes.dividedByZero &&
            !previewRes.isNegative &&
            !previewRes.exceededMax) {
          livePreview = previewRes.formatted;
        }
      } on Failure {
        livePreview = null;
      }
    }

    final lookupAssets = editing
        ? (ref.watch(assetsProvider).value ??
              (_initialAssets.isNotEmpty ? _initialAssets : assets))
        : assets;
    final currentAsset = lookupAssets.where((a) => a.id == assetId).firstOrNull;
    final fromAsset = lookupAssets
        .where((a) => a.id == fromAssetId)
        .firstOrNull;
    final toAsset = lookupAssets.where((a) => a.id == toAssetId).firstOrNull;
    final selectedCat = categoryId == null
        ? null
        : categories.where((c) => c.id == categoryId).firstOrNull;

    final Widget summaryLeft;
    if (type == RecordType.transfer) {
      final transferSummary =
          '${fromAsset?.name ?? '转出账户'} → ${toAsset?.name ?? '转入账户'}';
      summaryLeft = Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: cs.primary,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.swap_horiz_rounded,
              size: 16,
              color: cs.onPrimary,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              transferSummary,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
          ),
        ],
      );
    } else {
      final parentCat = selectedCat == null
          ? null
          : (selectedCat.parentCatId == noRef || selectedCat.parentCatId == -1)
          ? selectedCat
          : categories
                .where((c) => c.id == selectedCat.parentCatId)
                .firstOrNull;
      if (selectedCat != null) {
        final effectiveColorHex =
            (selectedCat.colorFill != null &&
                selectedCat.colorFill!.trim().isNotEmpty)
            ? selectedCat.colorFill
            : parentCat?.colorFill;
        final catLabel = parentCat != null && selectedCat.id != parentCat.id
            ? '${parentCat.name} · ${selectedCat.name}'
            : selectedCat.name;
        summaryLeft = Row(
          children: [
            CategoryIconAvatar(
              iconKey: selectedCat.icon,
              parentIconKey: parentCat?.icon,
              colorHex: effectiveColorHex,
              name: selectedCat.name,
              type: selectedCat.type,
              size: 28,
              selected: true,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                catLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
            ),
          ],
        );
      } else {
        summaryLeft = Row(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.category_outlined,
                size: 15,
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '请选择分类',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w500,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
          ],
        );
      }
    }

    final amountColor =
        type == RecordType.income || type == RecordType.advanceIncome
        ? (isDark ? const Color(0xFF81C784) : const Color(0xFF2E7D32))
        : (type == RecordType.transfer ? cs.primary : cs.onSurface);

    final Widget currencyPrefixWidget;
    if (sc == baseCurrency) {
      currencyPrefixWidget = Text(
        '¥',
        key: const Key('amount-currency-symbol'),
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          color: amount.text.isEmpty ? cs.outlineVariant : amountColor,
        ),
      );
    } else {
      final sym = _symbolForCurrency(sc, currencies);
      currencyPrefixWidget = Container(
        key: const Key('amount-currency-badge'),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: cs.secondaryContainer,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              sc,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: cs.onSecondaryContainer,
              ),
            ),
            if (sym.isNotEmpty && sym != sc) ...[
              const SizedBox(width: 2.5),
              Text(
                sym,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: cs.onSecondaryContainer,
                ),
              ),
            ],
          ],
        ),
      );
    }

    Widget? conversionSummaryWidget;
    if (sc != ac) {
      final acSym = _symbolForCurrency(ac, currencies);
      final convDec = _previewConvertedAmount(sc, ac);
      final String targetLabel;
      if (type == RecordType.transfer) {
        targetLabel = toAsset != null ? '转入${toAsset.name}' : '转入$ac';
      } else if (currentAsset != null) {
        targetLabel = '入账${currentAsset.name}';
      } else {
        final acName =
            currencies.where((c) => c.code == ac).firstOrNull?.name ??
            (ac == baseCurrency ? '人民币' : ac);
        targetLabel = '折算$acName';
      }
      conversionSummaryWidget = Padding(
        padding: const EdgeInsets.only(top: 1),
        child: GestureDetector(
          key: const Key('converted-summary-tap'),
          behavior: HitTestBehavior.opaque,
          onTap: busy
              ? null
              : () => unawaited(
                  _openConversionDialog(sc: sc, ac: ac, currencies: currencies),
                ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    '≈ $acSym $convDec $targetLabel',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: convertedEdited
                          ? cs.primary
                          : cs.onSurfaceVariant.withAlpha(210),
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                const SizedBox(width: 3),
                Icon(
                  Icons.edit_outlined,
                  size: 11,
                  color: convertedEdited ? cs.primary : cs.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      );
    }

    final dockDecoration = BoxDecoration(
      color: isDark ? cs.surfaceContainerLow : cs.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withAlpha(isDark ? 28 : 10),
          blurRadius: 12,
          offset: const Offset(0, -3),
        ),
      ],
    );

    final topBanners = <Widget>[
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

      // Non-blocking save-and-new confirmation banner
      if (_savedAndResetBanner && error == null)
        Container(
          key: const Key('save-and-new-banner'),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          color: cs.primaryContainer.withAlpha(160),
          child: Row(
            children: [
              Icon(
                Icons.check_circle_outline_rounded,
                size: 15,
                color: cs.primary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '已保存，可继续记下一笔',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: cs.onPrimaryContainer,
                  ),
                ),
              ),
              InkWell(
                onTap: () => setState(() => _savedAndResetBanner = false),
                child: Icon(
                  Icons.close,
                  size: 15,
                  color: cs.onPrimaryContainer,
                ),
              ),
            ],
          ),
        ),

      // Validation / conflict error banner
      if (error != null)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
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
    ];

    Widget buildSummaryAmountRow({required bool isDesktopLayout}) {
      return Padding(
        key: const Key('editor-summary-amount-row'),
        padding: isDesktopLayout
            ? const EdgeInsets.fromLTRB(14, 6, 14, 4)
            : const EdgeInsets.fromLTRB(14, 10, 14, 6),
        child: LayoutBuilder(
          builder: (context, rowConstraints) {
            final maxAmountWidth = math.max(
              124.0,
              rowConstraints.maxWidth * 0.62,
            );
            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(child: summaryLeft),
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxAmountWidth),
                  child: GestureDetector(
                    key: const Key('amount-tap-area'),
                    behavior: HitTestBehavior.opaque,
                    onTap: busy ? null : _activateCustomKeypad,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        if (livePreview != null)
                          Text(
                            '= $livePreview',
                            key: const Key('amount-live-preview'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
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
                          mainAxisAlignment: MainAxisAlignment.end,
                          crossAxisAlignment: CrossAxisAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
                          children: [
                            currencyPrefixWidget,
                            SizedBox(width: sc == baseCurrency ? 2 : 5),
                            Flexible(
                              child: IntrinsicWidth(
                                child: TextField(
                                  key: const Key('amount'),
                                  controller: amount,
                                  focusNode: _amountFocus,
                                  enabled: !busy,
                                  readOnly: false,
                                  showCursor: true,
                                  keyboardType: TextInputType.none,
                                  textInputAction: TextInputAction.done,
                                  textAlign: TextAlign.right,
                                  inputFormatters: _keypadExpressionFormatters,
                                  onTapOutside: isDesktopLayout ? (_) {} : null,
                                  onTap: busy ? null : _activateCustomKeypad,
                                  onChanged: (_) {
                                    ScaffoldMessenger.maybeOf(
                                      context,
                                    )?.clearSnackBars();
                                    setState(() {
                                      error = null;
                                      _savedAndResetBanner = false;
                                      if (_preservingLoadedConversion) {
                                        _preservingLoadedConversion = false;
                                        convertedEdited = false;
                                      }
                                      _autoConvert();
                                    });
                                  },
                                  onSubmitted: (_) {
                                    if (hasPendingOperator(amount.text)) {
                                      try {
                                        final res = evaluateKeypadExpression(
                                          amount.text,
                                        );
                                        if (res.dividedByZero) {
                                          _showCalcError('算式无效或除数不能为 0');
                                          return;
                                        }
                                        if (res.isNegative) {
                                          _showCalcError('计算结果不能小于 0');
                                          return;
                                        }
                                        if (res.exceededMax) {
                                          _showCalcError(
                                            '金额不能超过 88888888888.00',
                                          );
                                          return;
                                        }
                                        final next = res.money.decimal;
                                        setState(() {
                                          error = null;
                                          _setAmountText(next);
                                          if (_preservingLoadedConversion) {
                                            _preservingLoadedConversion = false;
                                            convertedEdited = false;
                                          }
                                          _autoConvert();
                                        });
                                      } on Failure catch (e) {
                                        _showCalcError(safeMessage(e));
                                        return;
                                      }
                                    }
                                  },
                                  style: TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.w800,
                                    color: amountColor,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                  decoration: InputDecoration(
                                    isCollapsed: isDesktopLayout,
                                    isDense: !isDesktopLayout,
                                    constraints: isDesktopLayout
                                        ? const BoxConstraints(minHeight: 32)
                                        : null,
                                    hintText: amount.text.isEmpty
                                        ? '0.00'
                                        : null,
                                    hintStyle: TextStyle(
                                      fontSize: 22,
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
                            ),
                          ],
                        ),
                        if (conversionSummaryWidget != null)
                          conversionSummaryWidget,
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      );
    }

    if (DesktopAdaptive.isDesktop(context)) {
      final desktopTextScale = MediaQuery.textScalerOf(
        context,
      ).scale(1.0).clamp(1.0, 2.0);
      final desktopRemarkRowHeight = desktopTextScale > 1.02
          ? (20.0 + 18.0 * desktopTextScale).ceilToDouble()
          : 38.0;
      final remarkSuffix = _buildRemarkSuffixIcon(
        remarksEnabled: remarksEnabled,
      );
      final showAttachmentStrip =
          (_attachmentsExpanded || imageNames.isNotEmpty) &&
          (diyConfig.isEnabled(DiyToolbarAction.images) ||
              imageNames.isNotEmpty);

      return Container(
        key: const Key('editor-bottom-dock'),
        clipBehavior: Clip.antiAlias,
        decoration: dockDecoration,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ...topBanners,
            // Pinned Row 1: Category / Transfer Summary + Amount Bar (never scrolled out!)
            buildSummaryAmountRow(isDesktopLayout: true),
            // Pinned Row 2: Explicit Horizontally-Centered Desktop Remark Row
            Container(
              key: const Key('editor-remark-row'),
              height: desktopRemarkRowHeight,
              margin: const EdgeInsets.fromLTRB(12, 2, 12, 4),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: isDark
                    ? cs.surfaceContainerHighest.withAlpha(115)
                    : cs.surfaceContainerLow,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: busy ? null : () => _remarkFocus.requestFocus(),
                    child: Icon(
                      Icons.edit_note_rounded,
                      size: 18,
                      color: cs.onSurfaceVariant.withAlpha(185),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      key: const Key('remark'),
                      controller: remark,
                      focusNode: _remarkFocus,
                      enabled: !busy,
                      maxLength: 200,
                      textInputAction: TextInputAction.done,
                      onEditingComplete: () {},
                      onSubmitted: (_) => _triggerDesktopEnter(),
                      buildCounter:
                          (
                            _, {
                            required currentLength,
                            required isFocused,
                            required maxLength,
                          }) => null,
                      onChanged: (_) =>
                          setState(() => _savedAndResetBanner = false),
                      textAlignVertical: TextAlignVertical.center,
                      style: const TextStyle(fontSize: 13.5, height: 1.25),
                      decoration: InputDecoration(
                        isCollapsed: true,
                        hintText: '输入备注...',
                        hintStyle: TextStyle(
                          fontSize: 13.5,
                          height: 1.25,
                          color: cs.onSurfaceVariant.withAlpha(160),
                        ),
                        contentPadding: const EdgeInsets.symmetric(vertical: 8),
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                  if (remarkSuffix != null) ...[
                    const SizedBox(width: 4),
                    remarkSuffix,
                  ],
                ],
              ),
            ),
            // Flexible Row 3: Optional Attachment Strip + Compact Pill Toolbar
            Flexible(
              fit: FlexFit.loose,
              child: SingleChildScrollView(
                physics: const ClampingScrollPhysics(),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (showAttachmentStrip)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 2),
                        child: BillAttachmentStrip(
                          key: const Key('record-attachment-strip'),
                          imageNames: imageNames,
                          readOnly: busy,
                          onChanged: (next) =>
                              setState(() => imageNames = next),
                        ),
                      ),
                    _buildPillToolbar(
                      context,
                      assets: assets,
                      tags: tags,
                      currencies: currencies,
                      diyConfig: diyConfig,
                    ),
                  ],
                ),
              ),
            ),
            // Row 4: Optional Compact Adaptive Keypad or Frequent Remarks Panel
            if (panelSlotHeight > 0 &&
                (_desktopKeypadExpanded ||
                    (_desktopRemarksExpanded && type != RecordType.transfer)))
              Container(
                key: const Key('editor-bottom-panel-slot'),
                height: panelSlotHeight,
                color: trayColor,
                child: _desktopRemarksExpanded && type != RecordType.transfer
                    ? _buildFrequentRemarksPanel(
                        context,
                        categories: categories,
                        selectedCategory: selectedCat,
                        bottomSafePadding: 0,
                      )
                    : SingleChildScrollView(
                        physics: const ClampingScrollPhysics(),
                        child: RecordCustomKeypad(
                          amountText: amount.text,
                          enabled: canSubmit,
                          busy: busy,
                          enableMultiplyDivide: true,
                          desktopCompact: true,
                          keyHeightOverride: desktopKeypadKeyHeight,
                          onKeyTap: _onKeypadKey,
                          onBackspace: () => _onKeypadKey('BACKSPACE'),
                          onClearAll: () => _onKeypadKey('CLEAR'),
                          onEvaluate: _evaluateInPlace,
                          onSave: () => unawaited(_save(stayAndReset: false)),
                          onSaveAndNew: () =>
                              unawaited(_save(stayAndReset: true)),
                        ),
                      ),
              ),
            // Pinned Row 5: Desktop Action Bar
            _buildDesktopActionBar(
              context,
              trayColor: trayColor,
              remarksEnabled: remarksEnabled && type != RecordType.transfer,
              pendingOp: pendingOp,
              canSubmit: canSubmit,
            ),
          ],
        ),
      );
    }

    return Container(
      key: const Key('editor-bottom-dock'),
      clipBehavior: Clip.antiAlias,
      decoration: dockDecoration,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            fit: FlexFit.loose,
            child: SingleChildScrollView(
              reverse: true,
              physics: const ClampingScrollPhysics(),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ...topBanners,

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

                  // Row 1: Category / Transfer Summary + Tight Left-Prefixed Amount Bar
                  buildSummaryAmountRow(isDesktopLayout: false),

                  // Row 2: Borderless Tonal Remark Input Row (tags live exclusively in pill toolbar)
                  Container(
                    key: const Key('editor-remark-row'),
                    margin: const EdgeInsets.fromLTRB(12, 2, 12, 6),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(
                      color: isDark
                          ? cs.surfaceContainerHighest.withAlpha(115)
                          : cs.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: TextField(
                      key: const Key('remark'),
                      controller: remark,
                      focusNode: _remarkFocus,
                      enabled: !busy,
                      maxLength: 200,
                      textInputAction: TextInputAction.done,
                      onEditingComplete: () {
                        if (!_isDesktopActive) {
                          _activateCustomKeypad();
                        }
                      },
                      onSubmitted: (_) {
                        if (_isDesktopActive) {
                          _triggerDesktopEnter();
                        } else {
                          _activateCustomKeypad();
                        }
                      },
                      buildCounter:
                          (
                            _, {
                            required currentLength,
                            required isFocused,
                            required maxLength,
                          }) => null,
                      onChanged: (_) =>
                          setState(() => _savedAndResetBanner = false),
                      style: const TextStyle(fontSize: 13.5),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: '输入备注...',
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
                          size: 18,
                          color: cs.onSurfaceVariant.withAlpha(185),
                        ),
                        prefixIconConstraints: const BoxConstraints(
                          minWidth: 26,
                          minHeight: 26,
                        ),
                        suffixIcon: _buildRemarkSuffixIcon(
                          remarksEnabled: remarksEnabled,
                        ),
                        suffixIconConstraints: const BoxConstraints(
                          minWidth: 26,
                          minHeight: 26,
                        ),
                      ),
                    ),
                  ),

                  // Row 3: Persistent Horizontal Scrollable Pill Toolbar (zero height jump!)
                  _buildPillToolbar(
                    context,
                    assets: assets,
                    tags: tags,
                    currencies: currencies,
                    diyConfig: diyConfig,
                  ),
                ],
              ),
            ),
          ),

          // Unified Bottom Panel Slot (Mobile)
          if (_panelMode != _BottomPanelMode.osKeyboard)
            Container(
              key: const Key('editor-bottom-panel-slot'),
              height: panelSlotHeight,
              color: trayColor,
              child: _panelMode == _BottomPanelMode.frequentRemarks
                  ? _buildFrequentRemarksPanel(
                      context,
                      categories: categories,
                      selectedCategory: selectedCat,
                      bottomSafePadding: bottomSafePadding,
                    )
                  : SingleChildScrollView(
                      physics: const ClampingScrollPhysics(),
                      child: Padding(
                        padding: EdgeInsets.only(bottom: bottomSafePadding),
                        child: RecordCustomKeypad(
                          amountText: amount.text,
                          enabled: canSubmit,
                          busy: busy,
                          enableMultiplyDivide: enableMulDiv,
                          onKeyTap: _onKeypadKey,
                          onBackspace: () => _onKeypadKey('BACKSPACE'),
                          onClearAll: () => _onKeypadKey('CLEAR'),
                          onEvaluate: _evaluateInPlace,
                          onSave: () => unawaited(_save(stayAndReset: false)),
                          onSaveAndNew: () =>
                              unawaited(_save(stayAndReset: true)),
                        ),
                      ),
                    ),
            ),
        ],
      ),
    );
  }

  Widget _buildDesktopActionBar(
    BuildContext context, {
    required Color trayColor,
    required bool remarksEnabled,
    required bool pendingOp,
    required bool canSubmit,
  }) {
    final cs = Theme.of(context).colorScheme;
    final modLabel = DesktopAdaptive.primaryModifierLabel(context);
    final fullSaveAndAgainLabel = '再记 ($modLabel+Enter)';
    final fullSaveLabel = pendingOp
        ? '= (Enter)'
        : (busy ? '保存中…' : '保存 (Enter)');
    final compactSaveLabel = pendingOp ? '=' : (busy ? '保存中…' : '保存');

    final leftButtons = <Widget>[
      if (remarksEnabled)
        _DesktopActionToggleChip(
          buttonKey: const Key('desktop-toggle-remarks'),
          icon: Icons.speaker_notes_outlined,
          label: '常用备注',
          active: _desktopRemarksExpanded,
          onTap: busy ? null : _toggleDesktopRemarksPanel,
        ),
      _DesktopActionToggleChip(
        buttonKey: const Key('desktop-toggle-keypad'),
        icon: Icons.calculate_outlined,
        label: '小键盘',
        active: _desktopKeypadExpanded,
        onTap: busy ? null : _toggleDesktopKeypadPanel,
      ),
    ];

    return TextFieldTapRegion(
      child: ExcludeFocus(
        child: LayoutBuilder(
          builder: (context, barConstraints) {
            final textScale = MediaQuery.textScalerOf(
              context,
            ).scale(1.0).clamp(1.0, 2.0);
            final compactBar = barConstraints.maxWidth < 550.0 * textScale;
            final saveAndAgainButton = OutlinedButton(
              key: const Key('desktop-save-and-again'),
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                minimumSize: const Size(0, 34),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                side: BorderSide(
                  color: cs.outlineVariant.withValues(alpha: 0.85),
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: canSubmit ? _triggerDesktopSaveAndAgain : null,
              child: Text(
                compactBar ? '再记' : fullSaveAndAgainLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            );
            final saveButton = FilledButton(
              key: const Key('desktop-save-button'),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                minimumSize: const Size(0, 34),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: canSubmit
                  ? (pendingOp
                        ? _evaluateInPlace
                        : () => unawaited(_save(stayAndReset: false)))
                  : null,
              child: Text(
                compactBar ? compactSaveLabel : fullSaveLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            );
            final rightButtons = <Widget>[
              compactBar
                  ? Tooltip(
                      message: fullSaveAndAgainLabel,
                      child: saveAndAgainButton,
                    )
                  : saveAndAgainButton,
              compactBar
                  ? Tooltip(message: fullSaveLabel, child: saveButton)
                  : saveButton,
            ];

            return Container(
              key: const Key('desktop-editor-action-bar'),
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
              decoration: BoxDecoration(
                color: trayColor,
                border: Border(
                  top: BorderSide(
                    color: cs.outlineVariant.withValues(alpha: 0.35),
                    width: 0.6,
                  ),
                ),
              ),
              child: OverflowBar(
                alignment: MainAxisAlignment.spaceBetween,
                overflowAlignment: OverflowBarAlignment.end,
                spacing: 8,
                overflowSpacing: 6,
                children: [
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: leftButtons,
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    alignment: WrapAlignment.end,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: rightButtons,
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildFrequentRemarksPanel(
    BuildContext context, {
    required List<RecordCategory> categories,
    required RecordCategory? selectedCategory,
    required double bottomSafePadding,
  }) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final trayColor = isDark
        ? cs.surfaceContainerLowest
        : cs.surfaceContainerLow;
    final remarksAsync = ref.watch(allRemarksProvider(null));
    final allBookCatsMap = ref.watch(allBookCategoriesMapProvider).value;
    final knownCategoriesById = <int, RecordCategory>{
      for (final c in categories) c.id: c,
      ...?allBookCatsMap,
    };
    final effectiveSelectedCat =
        selectedCategory ??
        (categoryId == null ? null : knownCategoriesById[categoryId!]);

    final rows = remarksAsync.value;
    var displayedRemarks = const <Remark>[];
    var scopeLabel = effectiveSelectedCat?.name ?? '全部';
    var canToggleScope = false;

    if (rows != null) {
      final allDeduped = _deduplicateAndSortRemarks(rows);
      final allUnique = allDeduped.take(36).toList();

      if (categoryId == null || effectiveSelectedCat == null) {
        displayedRemarks = allUnique;
        scopeLabel = '全部';
      } else {
        final selCat = effectiveSelectedCat;
        final selName = selCat.name.trim();
        final familyCatIds = <int>{categoryId!, noRef};
        if (selCat.parentCatId != noRef && selCat.parentCatId != -1) {
          familyCatIds.add(selCat.parentCatId);
        }
        for (final c in knownCategoriesById.values) {
          if (c.parentCatId == selCat.id || c.name.trim() == selName) {
            familyCatIds.add(c.id);
          }
        }
        final familyDeduped = _deduplicateAndSortRemarks(
          rows.where((r) => familyCatIds.contains(r.recordCatId)),
          prioritizeExactCategoryId: categoryId,
        );
        final familyUnique = familyDeduped.take(36).toList();
        canToggleScope =
            familyUnique.isNotEmpty && allDeduped.length > familyDeduped.length;

        if (familyUnique.isEmpty && allUnique.isNotEmpty) {
          displayedRemarks = allUnique;
          scopeLabel = '全部';
        } else if (_remarksShowAllScope && canToggleScope) {
          displayedRemarks = allUnique;
          scopeLabel = '全部';
        } else {
          displayedRemarks = familyUnique;
          scopeLabel = selCat.name;
        }
      }
    }

    final scopeBadgeBg = cs.secondaryContainer.withAlpha(isDark ? 165 : 150);
    final Widget scopeBadgeWidget = canToggleScope
        ? Material(
            color: scopeBadgeBg,
            shape: const StadiumBorder(side: BorderSide.none),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: const Key('editor-remarks-scope-toggle'),
              onTap: busy
                  ? null
                  : () => setState(
                      () => _remarksShowAllScope = !_remarksShowAllScope,
                    ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        scopeLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: cs.onSecondaryContainer,
                        ),
                      ),
                    ),
                    const SizedBox(width: 3),
                    Icon(
                      Icons.swap_horiz_rounded,
                      size: 12,
                      color: cs.onSecondaryContainer,
                    ),
                  ],
                ),
              ),
            ),
          )
        : Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2.5),
            decoration: ShapeDecoration(
              color: scopeBadgeBg,
              shape: const StadiumBorder(side: BorderSide.none),
            ),
            child: Text(
              scopeLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: cs.onSecondaryContainer,
              ),
            ),
          );

    return TextFieldTapRegion(
      child: ExcludeFocus(
        child: Container(
          key: const Key('editor-frequent-remarks-panel'),
          padding: EdgeInsets.only(bottom: bottomSafePadding),
          decoration: BoxDecoration(color: trayColor),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 6, 8, 4),
                child: Row(
                  children: [
                    Icon(
                      Icons.speaker_notes_outlined,
                      size: 16,
                      color: cs.primary,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '常用备注',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      fit: FlexFit.tight,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: scopeBadgeWidget,
                      ),
                    ),
                    TextButton.icon(
                      key: const Key('editor-remarks-btn'),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      onPressed: busy ? null : _openRemarksManager,
                      icon: const Icon(Icons.settings_outlined, size: 15),
                      label: const Text('管理', style: TextStyle(fontSize: 12)),
                    ),
                    IconButton(
                      key: const Key('editor-remarks-back-keypad-btn'),
                      tooltip: DesktopAdaptive.isDesktop(context)
                          ? '收起常用备注'
                          : '返回数字键盘',
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                        DesktopAdaptive.isDesktop(context)
                            ? Icons.keyboard_arrow_down_rounded
                            : Icons.dialpad_rounded,
                        size: 18,
                      ),
                      onPressed: busy ? null : _activateCustomKeypad,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: remarksAsync.when(
                  loading: () => const Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                  error: (_, _) => Center(
                    child: Text(
                      '常用备注加载失败',
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                  data: (_) {
                    if (displayedRemarks.isEmpty) {
                      return Center(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 4,
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '暂无常用备注，记账后自动统计，也可点击右上角「管理」添加',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 10),
                              FilledButton.tonalIcon(
                                key: const Key('editor-remarks-empty-add-btn'),
                                style: FilledButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                ),
                                onPressed: busy ? null : _openRemarksManager,
                                icon: const Icon(Icons.add_rounded, size: 16),
                                label: const Text(
                                  '去添加',
                                  style: TextStyle(fontSize: 12.5),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }
                    return SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
                      child: Wrap(
                        key: const Key('frequent_remark_chips'),
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final r in displayedRemarks)
                            ActionChip(
                              key: Key('remark_chip_${r.id}'),
                              visualDensity: VisualDensity.compact,
                              side: BorderSide.none,
                              shape: const StadiumBorder(),
                              backgroundColor: isDark
                                  ? cs.surfaceContainerHigh
                                  : cs.surface,
                              avatar: remark.text.trim() == r.content.trim()
                                  ? const Icon(Icons.check, size: 15)
                                  : null,
                              label: Text(
                                r.content,
                                style: const TextStyle(fontSize: 12.5),
                              ),
                              onPressed: busy
                                  ? null
                                  : () {
                                      setState(() {
                                        remark.value = TextEditingValue(
                                          text: r.content,
                                          selection: TextSelection.collapsed(
                                            offset: r.content.length,
                                          ),
                                        );
                                        _savedAndResetBanner = false;
                                      });
                                      _activateCustomKeypad();
                                    },
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
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
    final isDesktop = DesktopAdaptive.isDesktop(context);
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final currentAsset = assets.where((a) => a.id == assetId).firstOrNull;
    final configuredDefaultId = diyConfig.autoSelectDefaultAccount
        ? diyConfig.defaultAccountId
        : noRef;
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
                ? accentColor.withValues(alpha: isDark ? 0.22 : 0.14)
                : cs.secondaryContainer)
          : (isDark
                ? cs.surfaceContainerHighest.withAlpha(115)
                : cs.surfaceContainerLow);
      final textColor = active
          ? (accentColor != null ? cs.onSurface : cs.onSecondaryContainer)
          : cs.onSurface;
      return Padding(
        padding: EdgeInsets.only(right: isDesktop ? 0 : 6),
        child: Material(
          color: bgColor,
          shape: const StadiumBorder(side: BorderSide.none),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: key,
            canRequestFocus: !isDesktop,
            onTap: busy ? null : onTap,
            child: Padding(
              padding: isDesktop
                  ? const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5)
                  : const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
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
              defaultAccountId: configuredDefaultId,
              onSelected: (v) => setState(() {
                _userTouchedAsset = true;
                if (assetId != v && _preservingLoadedConversion) {
                  _preservingLoadedConversion = false;
                  convertedEdited = false;
                }
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

    final (sc, _) = _currencies();
    final scSymbol = _symbolForCurrency(sc, currencies);

    for (final item in diyConfig.items) {
      switch (item.action) {
        case DiyToolbarAction.tags:
          if (item.enabled || selectedTagIds.isNotEmpty) {
            final String tagLabel;
            if (selectedTags.isEmpty) {
              tagLabel = '标签';
            } else if (selectedTags.length == 1) {
              tagLabel = selectedTags.first.name;
            } else {
              tagLabel =
                  '${selectedTags.first.name} +${selectedTags.length - 1}';
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
            final discRaw = discount.text.trim();
            final hasDisc = discRaw.isNotEmpty;
            String discLabel = '优惠';
            if (hasDisc) {
              try {
                discLabel = '优惠 $scSymbol${parseAmount(discRaw).decimal}';
              } on Failure {
                discLabel = '优惠 $scSymbol$discRaw';
              }
            }
            pills.add(
              pill(
                key: const Key('editor-discount-pill'),
                icon: Icons.local_offer_outlined,
                label: discLabel,
                active: hasDisc,
                onTap: () => unawaited(
                  _openDiscountDialog(
                    currencyCode: sc,
                    currencySymbol: scSymbol,
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
          if (type != RecordType.transfer) {
            final (sc, acctCurr) = _currencies();
            if ((item.enabled && currencies.length > 1) ||
                (sourceCurrency != null && sc != acctCurr)) {
              pills.add(
                pill(
                  key: const Key('editor-currency-pill'),
                  icon: Icons.currency_exchange_rounded,
                  label: sc,
                  active: sc != acctCurr,
                  onTap: () => unawaited(_openCurrencyPickerSheet(currencies)),
                ),
              );
            }
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
        case DiyToolbarAction.frequentRemarks:
        case DiyToolbarAction.keypadMultiplyDivide:
        case DiyToolbarAction.autoSelectFirstCategory:
          break;
      }
    }

    if (isDesktop) {
      return ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 30),
        child: Padding(
          key: const Key('editor-pill-toolbar'),
          padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
          child: Wrap(spacing: 5, runSpacing: 4, children: pills),
        ),
      );
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 38),
      child: SingleChildScrollView(
        key: const Key('editor-pill-toolbar'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
        child: Row(children: pills),
      ),
    );
  }
}

class _DiscountEditDialog extends StatefulWidget {
  const _DiscountEditDialog({
    required this.initialText,
    required this.currencyCode,
    required this.currencySymbol,
    this.maxGrossMinor,
  });

  final String initialText;
  final String currencyCode;
  final String currencySymbol;
  final BigInt? maxGrossMinor;

  @override
  State<_DiscountEditDialog> createState() => _DiscountEditDialogState();
}

class _DiscountEditDialogState extends State<_DiscountEditDialog> {
  late final TextEditingController _ctrl;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final trimmed = _ctrl.text.trim();
    if (trimmed.isEmpty) {
      Navigator.of(context).pop('');
      return;
    }
    try {
      final parsed = parseAmount(trimmed);
      if (parsed.isNegative) {
        setState(() => _errorText = '优惠金额不能为负数');
        return;
      }
      if (widget.maxGrossMinor != null &&
          widget.maxGrossMinor! > BigInt.zero &&
          parsed.storageMinor > widget.maxGrossMinor!) {
        setState(() => _errorText = '优惠金额不能大于原金额');
        return;
      }
      Navigator.of(context).pop(parsed.isZero ? '' : parsed.decimal);
    } on Failure catch (e) {
      setState(() => _errorText = safeMessage(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('设置优惠金额'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '记录立减、红包或满减优惠（单位：${widget.currencyCode}）',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('discount'),
            controller: _ctrl,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textInputAction: TextInputAction.done,
            inputFormatters: amountInputFormatters,
            onChanged: (_) {
              if (_errorText != null) setState(() => _errorText = null);
            },
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: '优惠金额',
              hintText: '0.00',
              prefixText: '${widget.currencySymbol} ',
              errorText: _errorText,
              border: const OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        if (widget.initialText.trim().isNotEmpty ||
            _ctrl.text.trim().isNotEmpty)
          TextButton(
            key: const Key('discount-clear-btn'),
            onPressed: () => Navigator.of(context).pop(''),
            child: const Text('清空'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('discount-confirm-btn'),
          onPressed: _submit,
          child: const Text('确定'),
        ),
      ],
    );
  }
}

class _ConversionEditDialog extends StatefulWidget {
  const _ConversionEditDialog({
    required this.initialText,
    required this.initialEdited,
    required this.isTransfer,
    required this.sourceCurrency,
    required this.sourceSymbol,
    required this.targetCurrency,
    required this.amountText,
    this.discountMinor,
    required this.rates,
  });

  final String initialText;
  final bool initialEdited;
  final bool isTransfer;
  final String sourceCurrency;
  final String sourceSymbol;
  final String targetCurrency;
  final String amountText;
  final BigInt? discountMinor;
  final RateTable? rates;

  @override
  State<_ConversionEditDialog> createState() => _ConversionEditDialogState();
}

class _ConversionEditDialogState extends State<_ConversionEditDialog> {
  late final TextEditingController _ctrl;
  late bool _edited;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialText);
    _edited = widget.initialEdited;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _recalcFromRates() {
    final rates = widget.rates;
    final rawAmt = widget.amountText.trim();
    String next = '';
    if (rates != null && rawAmt.isNotEmpty) {
      try {
        final grossMinor = evaluateKeypadExpression(rawAmt).clampedMinor;
        final disc = widget.discountMinor ?? BigInt.zero;
        final netMinor = !widget.isTransfer && disc > BigInt.zero
            ? (grossMinor > disc ? grossMinor - disc : BigInt.zero)
            : grossMinor;
        next = formatMinor(
          rates.convert(netMinor, widget.sourceCurrency, widget.targetCurrency),
        );
      } on Failure {
        next = '';
      }
    }
    setState(() {
      _ctrl.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: next.length),
      );
      _edited = false;
      _errorText = null;
    });
  }

  void _submit() {
    final trimmed = _ctrl.text.trim();
    if (trimmed.isEmpty) {
      Navigator.of(context).pop((text: '', edited: false));
      return;
    }
    try {
      final parsed = parseAmount(trimmed);
      Navigator.of(context).pop((text: parsed.decimal, edited: _edited));
    } on Failure catch (e) {
      setState(() => _errorText = safeMessage(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final srcDisplay = widget.amountText.trim().isEmpty
        ? '0.00'
        : widget.amountText.trim();
    final fieldLabel = widget.isTransfer
        ? '转入金额（${widget.targetCurrency}）'
        : '折合入账（${widget.targetCurrency}）';

    return AlertDialog(
      title: Text(fieldLabel),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '原币金额：${widget.sourceCurrency} ${widget.sourceSymbol} $srcDisplay',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('converted'),
            controller: _ctrl,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textInputAction: TextInputAction.done,
            inputFormatters: amountInputFormatters,
            onChanged: (_) => setState(() {
              _edited = true;
              _errorText = null;
            }),
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: fieldLabel,
              prefixText: '${widget.targetCurrency} ',
              errorText: _errorText,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              key: const Key('auto-convert-btn'),
              onPressed: _recalcFromRates,
              icon: const Icon(Icons.sync_rounded, size: 16),
              label: const Text('按汇率算'),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('converted-confirm-btn'),
          onPressed: _submit,
          child: const Text('确定'),
        ),
      ],
    );
  }
}

class _DesktopActionToggleChip extends StatelessWidget {
  const _DesktopActionToggleChip({
    required this.buttonKey,
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final Key buttonKey;
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = active
        ? cs.secondaryContainer
        : (isDark ? cs.surfaceContainerHigh : cs.surface);
    final fgColor = active ? cs.onSecondaryContainer : cs.onSurfaceVariant;

    return Material(
      color: bgColor,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: buttonKey,
        canRequestFocus: false,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: fgColor),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                  color: fgColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AccountPickerBody extends StatefulWidget {
  const _AccountPickerBody({
    required this.title,
    required this.initialAssets,
    required this.currentId,
    required this.allowNone,
    required this.defaultAccountId,
    required this.isDesktop,
    required this.onSelect,
    required this.onOpenManager,
    this.onClose,
    required this.onReorderPersist,
  });

  final String title;
  final List<Asset> initialAssets;
  final int currentId;
  final bool allowNone;
  final int defaultAccountId;
  final bool isDesktop;
  final ValueChanged<int> onSelect;
  final VoidCallback onOpenManager;
  final VoidCallback? onClose;
  final Future<void> Function(List<int> orderedIds) onReorderPersist;

  @override
  State<_AccountPickerBody> createState() => _AccountPickerBodyState();
}

class _AccountPickerBodyState extends State<_AccountPickerBody> {
  late List<Asset> _items = List<Asset>.of(widget.initialAssets);
  bool _reordering = false;
  bool _savingOrder = false;

  String _subtitleOf(Asset a) {
    final ccy = normalizeCurrency(a.currency) ?? baseCurrency;
    final bal = formatMinor(a.balanceMinor);
    if (a.type == AssetType.credit) {
      return '信用账户 · $ccy · $bal';
    }
    return '$ccy · $bal';
  }

  Widget _buildAccountTitle(BuildContext ctx, Asset a) {
    final isDefault =
        widget.defaultAccountId != noRef &&
        a.id == widget.defaultAccountId &&
        a.status == AssetStatus.active &&
        a.type != AssetType.debt;
    if (!isDefault) {
      return Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis);
    }
    final itemCs = Theme.of(ctx).colorScheme;
    return Row(
      children: [
        Flexible(
          child: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        const SizedBox(width: 6),
        Container(
          key: Key('account-default-badge-${a.id}'),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
          decoration: BoxDecoration(
            color: itemCs.secondaryContainer,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            '默认',
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: itemCs.onSecondaryContainer,
              height: 1.2,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _handleReorder(int oldIndex, int newIndex) async {
    if (oldIndex < 0 ||
        oldIndex >= _items.length ||
        newIndex < 0 ||
        newIndex >= _items.length ||
        oldIndex == newIndex) {
      return;
    }
    final previous = List<Asset>.of(_items);
    final updated = List<Asset>.of(_items);
    final moved = updated.removeAt(oldIndex);
    updated.insert(newIndex, moved);
    setState(() {
      _items = updated;
      _savingOrder = true;
    });
    try {
      await widget.onReorderPersist([for (final a in updated) a.id]);
    } catch (e) {
      if (!mounted) return;
      setState(() => _items = previous);
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(safeMessage(e))));
    } finally {
      if (mounted) {
        setState(() => _savingOrder = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final canReorder = _items.length >= 2;
    final avatarSize = widget.isDesktop ? 34.0 : 36.0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: widget.isDesktop
              ? const EdgeInsets.fromLTRB(20, 14, 10, 10)
              : const EdgeInsets.fromLTRB(16, 0, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: widget.isDesktop
                      ? theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        )
                      : theme.textTheme.titleMedium,
                ),
              ),
              if (canReorder)
                TextButton(
                  key: const Key('toggle-account-picker-reorder-btn'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  onPressed: _savingOrder
                      ? null
                      : () => setState(() => _reordering = !_reordering),
                  child: Text(_reordering ? '完成' : '排序'),
                ),
              TextButton.icon(
                key: const Key('manage-assets-sheet-btn'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                onPressed: _savingOrder ? null : widget.onOpenManager,
                icon: const Icon(Icons.settings_outlined, size: 16),
                label: const Text('管理账户'),
              ),
              if (widget.isDesktop && widget.onClose != null)
                CloseButton(onPressed: widget.onClose),
            ],
          ),
        ),
        if (widget.isDesktop) const SizedBox(height: 4),
        Flexible(
          child: _reordering
              ? ReorderableListView.builder(
                  key: const Key('account-picker-reorder-list'),
                  shrinkWrap: true,
                  buildDefaultDragHandles: false,
                  padding: widget.isDesktop
                      ? const EdgeInsets.symmetric(horizontal: 8, vertical: 6)
                      : EdgeInsets.zero,
                  onReorderStart: (_) {
                    if (!widget.isDesktop) {
                      HapticFeedback.selectionClick();
                    }
                  },
                  proxyDecorator: (child, index, animation) => Material(
                    elevation: 6,
                    color: cs.surface,
                    borderRadius: BorderRadius.circular(12),
                    clipBehavior: Clip.antiAlias,
                    child: child,
                  ),
                  itemCount: _items.length,
                  onReorderItem: (oldIndex, newIndex) =>
                      unawaited(_handleReorder(oldIndex, newIndex)),
                  itemBuilder: (ctx, index) {
                    final a = _items[index];
                    final dragHandle = ReorderableDragStartListener(
                      index: index,
                      child: MouseRegion(
                        cursor: SystemMouseCursors.grab,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 6,
                          ),
                          child: Icon(
                            Icons.drag_handle_rounded,
                            key: Key('account-picker-drag-${a.id}'),
                            size: 20,
                            color: cs.outline,
                          ),
                        ),
                      ),
                    );
                    final tile = ListTile(
                      shape: widget.isDesktop
                          ? RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            )
                          : null,
                      leading: AssetIconAvatar(
                        iconKey: a.icon,
                        colorHex: a.color,
                        name: a.name,
                        assetType: a.type,
                        subType: a.subType,
                        size: avatarSize,
                        selected: widget.currentId == a.id,
                      ),
                      title: _buildAccountTitle(ctx, a),
                      subtitle: Text(
                        _subtitleOf(a),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                      trailing: dragHandle,
                    );
                    if (widget.isDesktop) {
                      return KeyedSubtree(
                        key: ValueKey('picker-account-item-${a.id}'),
                        child: tile,
                      );
                    }
                    return ReorderableDelayedDragStartListener(
                      key: ValueKey('picker-account-item-${a.id}'),
                      index: index,
                      child: tile,
                    );
                  },
                )
              : ListView(
                  shrinkWrap: true,
                  padding: widget.isDesktop
                      ? const EdgeInsets.symmetric(horizontal: 8, vertical: 6)
                      : EdgeInsets.zero,
                  children: [
                    if (widget.allowNone)
                      ListTile(
                        shape: widget.isDesktop
                            ? RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              )
                            : null,
                        leading: Container(
                          width: avatarSize,
                          height: avatarSize,
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
                        trailing: widget.currentId == noRef
                            ? Icon(Icons.check_rounded, color: cs.primary)
                            : null,
                        onTap: () => widget.onSelect(noRef),
                      ),
                    for (final a in _items)
                      ListTile(
                        key: ValueKey('picker-account-row-${a.id}'),
                        shape: widget.isDesktop
                            ? RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              )
                            : null,
                        leading: AssetIconAvatar(
                          iconKey: a.icon,
                          colorHex: a.color,
                          name: a.name,
                          assetType: a.type,
                          subType: a.subType,
                          size: avatarSize,
                          selected: widget.currentId == a.id,
                        ),
                        title: _buildAccountTitle(context, a),
                        subtitle: Text(
                          _subtitleOf(a),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: widget.currentId == a.id
                            ? Icon(Icons.check_rounded, color: cs.primary)
                            : null,
                        onTap: () => widget.onSelect(a.id),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}
