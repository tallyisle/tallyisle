import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show Uint8List, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/adaptive.dart';
import '../../app/providers.dart';
import '../../core/failure.dart';
import '../../core/money.dart';
import '../../data/automation/url_scheme_service.dart'
    show matchCategoryByRef, matchFundingAssetByHint;
import '../../data/db/database.dart';
import '../../data/ledger/ledger_service.dart';
import '../../domain/ledger/record_extra.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/asset_overview.dart'
    show RateTable, normalizeCurrency;
import '../../domain/rules/auto_map_rules.dart';
import '../../domain/rules/currency_rates.dart' show baseCurrency, billSnapshot;
import '../../domain/rules/ocr_bill_rules.dart';
import '../../domain/rules/smart_bill_nlp_rules.dart';
import '../../domain/rules/url_scheme_rules.dart' show parseUrlMoney;
import '../../platform/auto_bill_bridge.dart';
import '../common/common.dart';
import 'automation_providers.dart';

/// Typed in-place prefill payload returned to `RecordEditorPage`.
final class SmartQuickPrefillResult {
  const SmartQuickPrefillResult({
    required this.type,
    required this.money,
    this.discount,
    this.categoryId,
    this.assetId,
    this.toAssetId,
    required this.remark,
    required this.recordTimeMs,
  });

  final int type;
  final Money money;
  final Money? discount;
  final int? categoryId;
  final int? assetId;
  final int? toAssetId;
  final String remark;
  final int recordTimeMs;
}

/// Opens the Smart Quick recognition UI as a centered [Dialog] on desktop or
/// a rounded modal bottom sheet on mobile, returning a [SmartQuickPrefillResult]
/// to populate `RecordEditorPage` in-place.
Future<SmartQuickPrefillResult?> showSmartQuickPrefillDialogOrSheet(
  BuildContext context,
) {
  if (DesktopAdaptive.isDesktop(context)) {
    return showDialog<SmartQuickPrefillResult>(
      context: context,
      builder: (dialogCtx) {
        final scheme = Theme.of(dialogCtx).colorScheme;
        return Dialog(
          key: const Key('smart_quick_dialog'),
          backgroundColor: scheme.surface,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 540, maxHeight: 720),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 10, 10),
                  child: Row(
                    children: [
                      Icon(
                        Icons.auto_awesome_outlined,
                        size: 20,
                        color: scheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '智能识账速填',
                          style: Theme.of(dialogCtx).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                      CloseButton(
                        onPressed: () => Navigator.of(dialogCtx).pop(),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Flexible(
                  child: _SmartQuickContent(
                    prefillMode: true,
                    onPrefilled: (res) => Navigator.of(dialogCtx).pop(res),
                    onStandaloneDone: () => Navigator.of(dialogCtx).pop(),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  return showModalBottomSheet<SmartQuickPrefillResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    sheetAnimationStyle: AnimationStyle.noAnimation,
    builder: (sheetCtx) {
      final viewInsets = MediaQuery.viewInsetsOf(sheetCtx);
      final maxHeight =
          (MediaQuery.sizeOf(sheetCtx).height - viewInsets.bottom - 72.0).clamp(
            260.0,
            680.0,
          );
      return Padding(
        key: const Key('smart_quick_sheet'),
        padding: EdgeInsets.only(bottom: viewInsets.bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
                child: Row(
                  children: [
                    Icon(
                      Icons.auto_awesome_outlined,
                      size: 20,
                      color: Theme.of(sheetCtx).colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '智能识账速填',
                        style: Theme.of(sheetCtx).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: '关闭',
                      onPressed: () => Navigator.of(sheetCtx).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: _SmartQuickContent(
                  prefillMode: true,
                  onPrefilled: (res) => Navigator.of(sheetCtx).pop(res),
                  onStandaloneDone: () => Navigator.of(sheetCtx).pop(),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// Standalone page mounted at `/automation/smart-bill` for shortcuts, quick
/// tiles, `ACTION_PROCESS_TEXT`, system shares, and `tallyisle://smartbill`.
class SmartQuickBillPage extends ConsumerWidget {
  const SmartQuickBillPage({
    super.key,
    this.initialText,
    this.readClipboardOnOpen = false,
    this.sourceApp,
  });

  final String? initialText;
  final bool readClipboardOnOpen;
  final String? sourceApp;

  void _closeOrGoHome(BuildContext context) {
    final router = GoRouter.maybeOf(context);
    if (router != null) {
      if (context.canPop()) {
        context.pop();
      } else {
        context.go('/');
      }
      return;
    }
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDesktop = DesktopAdaptive.isDesktop(context);
    final body = _SmartQuickContent(
      prefillMode: false,
      initialText: initialText,
      readClipboardOnOpen: readClipboardOnOpen,
      sourceApp: sourceApp,
      consumeSharedQueue: true,
      onStandaloneDone: () => _closeOrGoHome(context),
    );
    return Scaffold(
      key: const Key('smart_quick_bill_page'),
      appBar: AppBar(
        scrolledUnderElevation: isDesktop ? 0 : null,
        title: const Text('智能识账'),
      ),
      body: isDesktop
          ? Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: body,
              ),
            )
          : body,
    );
  }
}

final class _SingleReviewDraft {
  const _SingleReviewDraft({
    required this.type,
    required this.money,
    this.discount,
    required this.recordTimeMs,
    this.categoryId,
    this.assetId,
    this.toAssetId,
    required this.remark,
    required this.merchantKeyword,
    required this.sourceLabel,
  });

  final int type;
  final Money money;
  final Money? discount;
  final int recordTimeMs;
  final int? categoryId;
  final int? assetId;
  final int? toAssetId;
  final String remark;
  final String merchantKeyword;
  final String sourceLabel;
}

class _SmartQuickContent extends ConsumerStatefulWidget {
  const _SmartQuickContent({
    required this.prefillMode,
    this.initialText,
    this.readClipboardOnOpen = false,
    this.sourceApp,
    this.consumeSharedQueue = false,
    this.onPrefilled,
    this.onStandaloneDone,
  });

  final bool prefillMode;
  final String? initialText;
  final bool readClipboardOnOpen;
  final String? sourceApp;
  final bool consumeSharedQueue;
  final ValueChanged<SmartQuickPrefillResult>? onPrefilled;
  final VoidCallback? onStandaloneDone;

  @override
  ConsumerState<_SmartQuickContent> createState() => _SmartQuickContentState();
}

class _SmartQuickContentState extends ConsumerState<_SmartQuickContent> {
  final TextEditingController _textController = TextEditingController();
  final TextEditingController _amountController = TextEditingController();
  final TextEditingController _discountController = TextEditingController();
  final TextEditingController _remarkController = TextEditingController();
  final CommandIds _commandIds = CommandIds();
  int _nonce = 0;

  bool _parsing = false;
  bool _submitting = false;
  String? _error;
  String? _infoMessage;

  // Single-candidate state
  bool _hasSingleCandidate = false;
  int _singleType = RecordType.expense;
  int? _singleCategoryId;
  int? _singleAssetId;
  int? _singleToAssetId;
  int _singleTimeMs = 0;
  String _merchantKeyword = '';
  String _sourceLabel = '';
  bool _learnRule = false;

  // Multi-candidate state
  List<OcrBillCandidate> _multiCandidates = const [];
  int? _defaultBatchAssetId;

  @override
  void initState() {
    super.initState();
    _singleTimeMs = DateTime.now().millisecondsSinceEpoch;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_bootstrapInitialInput());
    });
  }

  @override
  void dispose() {
    _textController.dispose();
    _amountController.dispose();
    _discountController.dispose();
    _remarkController.dispose();
    super.dispose();
  }

  Future<void> _bootstrapInitialInput() async {
    if (widget.consumeSharedQueue) {
      final shared = ref.read(pendingSharedPayloadProvider.notifier).consume();
      if (shared != null) {
        await _processSharedPayload(shared);
        return;
      }
    }
    final initial = widget.initialText?.trim();
    if (initial != null && initial.isNotEmpty) {
      _textController.text = initial;
      await _parseInputText(sourceOverride: widget.sourceApp);
      return;
    }
    // Privacy rule: ONLY read clipboard when explicitly requested (`clipboard=1`).
    if (widget.readClipboardOnOpen) {
      await _pasteFromClipboardAndParse();
    }
  }

  Future<void> _processSharedPayload(AutoBillSharedPayload payload) async {
    switch (payload.kind) {
      case AutoBillSharedPayloadKind.text:
        final text = payload.text?.trim() ?? '';
        if (text.isNotEmpty) {
          _textController.text = text;
          await _parseInputText(sourceOverride: payload.source);
        }
      case AutoBillSharedPayloadKind.image:
        if (payload.imagePaths.isNotEmpty) {
          await _recognizeSharedImageFiles(payload.imagePaths);
        }
      case AutoBillSharedPayloadKind.shortcut:
        break;
    }
  }

  Future<void> _pasteFromClipboardAndParse() async {
    if (_parsing || _submitting) return;
    setState(() {
      _error = null;
      _infoMessage = null;
    });
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (!mounted) return;
      final text = data?.text?.trim() ?? '';
      if (text.isEmpty) {
        setState(() => _error = '剪贴板中暂无可识别的文本内容');
        return;
      }
      _textController.text = text;
      await _parseInputText(sourceOverride: widget.sourceApp);
    } catch (e) {
      if (mounted) setState(() => _error = safeMessage(e));
    }
  }

  Future<void> _pickAndRecognizeImage() async {
    if (_parsing || _submitting) return;
    setState(() {
      _parsing = true;
      _error = null;
      _infoMessage = null;
    });
    try {
      final ocrService = await ref.read(ocrServiceProvider.future);
      final provider = await ocrService.getProvider();
      if (!provider.isConfigured) {
        await provider.recognizeImage(Uint8List(0));
      }
      final fileAccess = ref.read(ocrFileAccessProvider);
      final selected = await fileAccess.pickBytes(
        allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp'],
      );
      await _runImageBytesOcr([(selected.name, selected.bytes)]);
    } on Failure catch (f) {
      if (!mounted) return;
      if (f.code == FailureCode.cancelled) return;
      setState(() => _error = f.message);
    } catch (e) {
      if (mounted) setState(() => _error = safeMessage(e));
    } finally {
      if (mounted) setState(() => _parsing = false);
    }
  }

  Future<void> _recognizeSharedImageFiles(List<String> paths) async {
    if (kIsWeb || paths.isEmpty) return;
    setState(() {
      _parsing = true;
      _error = null;
      _infoMessage = null;
    });
    try {
      final files = <(String, Uint8List)>[];
      for (final path in paths) {
        final f = File(path);
        if (await f.exists()) {
          final bytes = await f.readAsBytes();
          if (bytes.isNotEmpty) {
            files.add((f.uri.pathSegments.lastOrNull ?? 'shared.png', bytes));
          }
        }
      }
      if (files.isEmpty) {
        throw const Failure(FailureCode.validation, '未能读取分享的账单图片，请重新选择图片识别');
      }
      await _runImageBytesOcr(files);
    } catch (e) {
      if (mounted) setState(() => _error = safeMessage(e));
    } finally {
      if (mounted) setState(() => _parsing = false);
    }
  }

  Future<void> _runImageBytesOcr(List<(String, Uint8List)> images) async {
    final ocrService = await ref.read(ocrServiceProvider.future);
    final bookId = ref.read(currentBookIdProvider).value;
    final combinedTexts = <String>[];
    final allCandidates = <OcrBillCandidate>[];

    for (final (name, bytes) in images) {
      final (recognizedText, parsed) = await ocrService
          .recognizeImageToCandidates(bytes, fileName: name, bookId: bookId);
      if (recognizedText.trim().isNotEmpty) {
        combinedTexts.add(recognizedText.trim());
      }
      for (final c in parsed) {
        allCandidates.add(
          OcrBillCandidate(
            index: allCandidates.length,
            type: c.type,
            money: c.money,
            discount: c.discount,
            recordTimeMs: c.recordTimeMs,
            merchant: c.merchant,
            remark: c.remark,
            categoryHint: c.categoryHint,
            accountHint: c.accountHint,
            categoryId: c.categoryId,
            assetId: c.assetId,
            selected: c.selected,
          ),
        );
      }
    }

    final fullText = combinedTexts.join('\n');
    if (mounted) {
      _textController.text = fullText;
    }

    if (allCandidates.length >= 2) {
      if (!mounted) return;
      setState(() {
        _hasSingleCandidate = false;
        _multiCandidates = allCandidates;
        _infoMessage = '已离线识别图片，共提取 ${allCandidates.length} 笔账单';
      });
      return;
    }

    if (allCandidates.length == 1) {
      final single = allCandidates.single;
      _applySingleDraft(
        _SingleReviewDraft(
          type: single.type,
          money: single.money,
          discount: single.discount,
          recordTimeMs: single.recordTimeMs,
          categoryId: single.categoryId,
          assetId: single.assetId,
          remark: single.remark,
          merchantKeyword: single.merchant.trim(),
          sourceLabel: '离线识图',
        ),
        info: '已从图片离线识别出 1 笔账单，请核对后确认',
      );
      return;
    }

    // Fallback: try colloquial/payment/AI single-bill parser on extracted OCR text.
    if (fullText.trim().isNotEmpty) {
      await _parseInputText(sourceOverride: '离线识图');
      return;
    }

    if (!mounted) return;
    setState(() {
      _error = '已提取图片文字，但未识别出有效金额，请在文本框微调后点击识别';
    });
  }

  void _applySingleDraft(_SingleReviewDraft draft, {String? info}) {
    if (!mounted) return;
    final cleanKeyword = draft.merchantKeyword.trim();
    final canDefaultLearn =
        cleanKeyword.isNotEmpty &&
        cleanKeyword != '账单识别' &&
        cleanKeyword != '小票识别' &&
        isAutoMapRuleKey(cleanKeyword);
    setState(() {
      _multiCandidates = const [];
      _hasSingleCandidate = true;
      _singleType = draft.type;
      _singleCategoryId = draft.categoryId;
      _singleAssetId = draft.assetId;
      _singleToAssetId = draft.toAssetId;
      _singleTimeMs = draft.recordTimeMs;
      _merchantKeyword = cleanKeyword;
      _sourceLabel = draft.sourceLabel;
      _learnRule = canDefaultLearn;
      _amountController.text = draft.money.decimal;
      _discountController.text =
          draft.discount != null && !draft.discount!.isZero
          ? draft.discount!.decimal
          : '';
      _remarkController.text = draft.remark;
      _infoMessage = info;
      _error = null;
    });
  }

  Future<void> _parseInputText({String? sourceOverride}) async {
    final raw = _textController.text.trim();
    if (raw.isEmpty) {
      setState(() {
        _error = '请输入一句记账口语（如“早饭买煎饼微信花了9块5”）或粘贴支付通知';
        _infoMessage = null;
      });
      return;
    }
    setState(() {
      _parsing = true;
      _error = null;
      _infoMessage = null;
    });
    try {
      final db = await ref.read(databaseProvider.future);
      final ocrService = await ref.read(ocrServiceProvider.future);
      final autoService = await ref.read(autoBillServiceProvider.future);
      final bookId = ref.read(currentBookIdProvider).value ?? 1;
      final nowMs = db.nowMs();

      // 1. Multi-line ledger screenshot or multi-item note -> checklist mode
      if (raw.contains('\n')) {
        final multi = await ocrService.parseTextToCandidates(
          raw,
          bookId: bookId,
        );
        if (multi.length >= 2) {
          if (!mounted) return;
          setState(() {
            _hasSingleCandidate = false;
            _multiCandidates = multi;
            _infoMessage = '已识别出 ${multi.length} 笔待核对账单';
          });
          return;
        }
      }

      final categories =
          ref.read(categoriesProvider(bookId)).value ??
          await (db.select(
            db.recordCategories,
          )..where((t) => t.accountBookId.equals(bookId))).get();
      final allAssets =
          ref.read(assetsProvider).value ?? await db.select(db.assets).get();
      final links =
          ref.read(assetBooksProvider).value ??
          await db.select(db.assetBooks).get();
      final rules = await autoService.listRules();

      final activeCategoryNames = [
        for (final c in categories)
          if (!c.isHide) c.name,
      ];
      final fundingAssets = [
        for (final a in allAssets)
          if (a.type != AssetType.debt && a.status != AssetStatus.settled) a,
      ];
      final assetNames = [for (final a in fundingAssets) a.name];

      // 2. Payment notification / SMS parser
      final payment = parsePaymentText(
        raw,
        packageOrApp: sourceOverride ?? widget.sourceApp,
        fallbackNowMs: nowMs,
      );
      if (payment != null) {
        final draft = _enrichParsedSingle(
          recordType: payment.recordType,
          money: payment.money,
          discount: payment.discount,
          recordTimeMs: payment.recordTimeMs,
          merchant: payment.merchant,
          accountHint1: payment.accountHint1,
          accountHint2: payment.accountHint2,
          categoryHint: payment.categoryHint,
          sourceApp: payment.sourceApp,
          rawText: raw,
          bookId: bookId,
          rules: rules,
          categories: categories,
          fundingAssets: fundingAssets,
          links: links,
        );
        _applySingleDraft(draft, info: '已识别支付文本（${draft.sourceLabel}）');
        return;
      }

      // 3. Pure-offline colloquial Chinese NLP
      var nlp = parseNaturalLanguageBill(
        raw,
        nowMs: nowMs,
        categoryNames: activeCategoryNames,
        assetNames: assetNames,
      );

      // 4. Optional user-configured AI parser when enabled
      final aiConfig = await autoService.getAiParserConfig();
      if (aiConfig.isConfigured &&
          (!aiConfig.fallbackOnly ||
              nlp == null ||
              nlp.confidence == SmartBillConfidence.low)) {
        try {
          final aiClient = ref.read(aiBillParserClientProvider);
          final aiBills = await aiClient.parseText(
            raw,
            config: aiConfig,
            nowMs: nowMs,
            categoryNames: activeCategoryNames,
            assetNames: assetNames,
          );
          if (aiBills.length >= 2) {
            final multi = <OcrBillCandidate>[];
            for (var i = 0; i < aiBills.length; i++) {
              final b = aiBills[i];
              final enriched = _enrichParsedSingle(
                recordType: b.recordType,
                money: b.money,
                discount: b.discount,
                recordTimeMs: b.recordTimeMs,
                merchant: b.remark,
                accountHint1: b.assetHint,
                accountHint2: b.toAssetHint,
                categoryHint: b.categoryHint,
                sourceApp: 'AI 智能解析',
                rawText: raw,
                bookId: bookId,
                rules: rules,
                categories: categories,
                fundingAssets: fundingAssets,
                links: links,
              );
              multi.add(
                OcrBillCandidate(
                  index: i,
                  type: enriched.type == RecordType.transfer
                      ? RecordType.expense
                      : enriched.type,
                  money: enriched.money,
                  discount: enriched.discount,
                  recordTimeMs: enriched.recordTimeMs,
                  merchant: enriched.merchantKeyword.isEmpty
                      ? 'AI 识账'
                      : enriched.merchantKeyword,
                  remark: enriched.remark,
                  categoryId: enriched.categoryId,
                  assetId: enriched.assetId,
                ),
              );
            }
            if (!mounted) return;
            setState(() {
              _hasSingleCandidate = false;
              _multiCandidates = multi;
              _infoMessage = 'AI 已识别出 ${multi.length} 笔待核对账单';
            });
            return;
          }
          if (aiBills.length == 1) {
            nlp = aiBills.single;
          }
        } on Failure {
          // Gracefully fall back to offline NLP result if AI fails.
        }
      }

      if (nlp != null) {
        final draft = _enrichParsedSingle(
          recordType: nlp.recordType,
          money: nlp.money,
          discount: nlp.discount,
          recordTimeMs: nlp.recordTimeMs,
          merchant: nlp.remark,
          accountHint1: nlp.assetHint,
          accountHint2: nlp.toAssetHint,
          categoryHint: nlp.categoryHint,
          sourceApp: nlp.source == 'ai' ? 'AI 智能解析' : '口语离线识账',
          rawText: raw,
          bookId: bookId,
          rules: rules,
          categories: categories,
          fundingAssets: fundingAssets,
          links: links,
        );
        _applySingleDraft(draft, info: '已识别（${draft.sourceLabel}），请核对后确认');
        return;
      }

      // 5. Final fallback: single receipt line via OCR candidate parser
      final ocrSingle = await ocrService.parseTextToCandidates(
        raw,
        bookId: bookId,
      );
      if (ocrSingle.isNotEmpty) {
        if (ocrSingle.length >= 2) {
          if (!mounted) return;
          setState(() {
            _hasSingleCandidate = false;
            _multiCandidates = ocrSingle;
            _infoMessage = '已识别出 ${ocrSingle.length} 笔待核对账单';
          });
          return;
        }
        final single = ocrSingle.single;
        _applySingleDraft(
          _SingleReviewDraft(
            type: single.type,
            money: single.money,
            discount: single.discount,
            recordTimeMs: single.recordTimeMs,
            categoryId: single.categoryId,
            assetId: single.assetId,
            remark: single.remark,
            merchantKeyword: single.merchant,
            sourceLabel: '账单文本解析',
          ),
        );
        return;
      }

      if (!mounted) return;
      setState(() {
        _error = '未能从内容中提取有效金额，请包含数字或中文金额（如“早饭9块5”或“消费 18.50 元”）';
      });
    } catch (e) {
      if (mounted) setState(() => _error = safeMessage(e));
    } finally {
      if (mounted) setState(() => _parsing = false);
    }
  }

  _SingleReviewDraft _enrichParsedSingle({
    required int recordType,
    required Money money,
    required Money? discount,
    required int recordTimeMs,
    required String merchant,
    required String? accountHint1,
    required String? accountHint2,
    required String? categoryHint,
    required String sourceApp,
    required String rawText,
    required int bookId,
    required List<AutoMapRule> rules,
    required List<RecordCategory> categories,
    required List<Asset> fundingAssets,
    required List<AssetBook> links,
  }) {
    final matched = matchAutoMapRules(rules, [
      merchant,
      ?accountHint1,
      ?accountHint2,
      ?categoryHint,
      sourceApp,
      rawText,
    ]);
    final effectiveType = matched.recordType ?? recordType;
    final wantCatType = effectiveType == RecordType.income
        ? RecordType.income
        : RecordType.expense;
    final dirCats = categories
        .where((c) => !c.isHide && c.type == wantCatType)
        .toList(growable: false);

    int? resolvedCatId;
    if (effectiveType != RecordType.transfer) {
      if (matched.categoryId != null) {
        resolvedCatId = dirCats
            .where((c) => c.id == matched.categoryId)
            .firstOrNull
            ?.id;
      }
      if (resolvedCatId == null && categoryHint != null) {
        resolvedCatId = matchCategoryByRef(dirCats, categoryHint)?.id;
      }
      resolvedCatId ??= dirCats.firstOrNull?.id;
    }

    int? resolvedAssetId;
    if (matched.assetId != null) {
      resolvedAssetId = fundingAssets
          .where((a) => a.id == matched.assetId)
          .firstOrNull
          ?.id;
    }
    resolvedAssetId ??= matchFundingAssetByHint(
      assets: fundingAssets,
      links: links,
      bookId: bookId,
      rawHint: accountHint1 ?? sourceApp,
    )?.id;

    int? resolvedToAssetId;
    if (effectiveType == RecordType.transfer) {
      if (matched.toAssetId != null) {
        resolvedToAssetId = fundingAssets
            .where((a) => a.id == matched.toAssetId)
            .firstOrNull
            ?.id;
      }
      resolvedToAssetId ??= matchFundingAssetByHint(
        assets: fundingAssets,
        links: links,
        bookId: bookId,
        rawHint: accountHint2,
      )?.id;
    }

    final cleanMerchant = merchant.trim();
    final effectiveRemark =
        (matched.remark != null && matched.remark!.trim().isNotEmpty
                ? matched.remark!.trim()
                : cleanMerchant)
            .trim();

    return _SingleReviewDraft(
      type: effectiveType,
      money: money,
      discount: discount,
      recordTimeMs: recordTimeMs,
      categoryId: resolvedCatId,
      assetId: resolvedAssetId,
      toAssetId: resolvedToAssetId,
      remark: effectiveRemark,
      merchantKeyword: cleanMerchant.isNotEmpty
          ? cleanMerchant
          : effectiveRemark,
      sourceLabel: friendlyAutoBillAppName(sourceApp),
    );
  }

  Future<void> _pickDateTime() async {
    final current = DateTime.fromMillisecondsSinceEpoch(_singleTimeMs);
    final date = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (date == null || !mounted) return;
    final tod = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current),
    );
    if (!mounted) return;
    final next = DateTime(
      date.year,
      date.month,
      date.day,
      tod?.hour ?? current.hour,
      tod?.minute ?? current.minute,
    );
    setState(() => _singleTimeMs = next.millisecondsSinceEpoch);
  }

  Future<void> _maybePersistLearnedRule({
    required int bookId,
    required int type,
    required int? categoryId,
    required int? assetId,
    required int? toAssetId,
    required String keyword,
  }) async {
    if (!_learnRule) return;
    final cleanKey = keyword.trim();
    if (cleanKey.isEmpty ||
        cleanKey.length > 100 ||
        !isAutoMapRuleKey(cleanKey)) {
      return;
    }
    final info = AutoMapInfo(
      recordType: type,
      mapCategoryId: type == RecordType.transfer ? null : categoryId,
      mapAssetId: assetId,
      toAssetId: type == RecordType.transfer ? toAssetId : null,
      bookId: bookId,
    );
    if (!info.hasAnyMapping) return;
    try {
      final autoService = await ref.read(autoBillServiceProvider.future);
      final rules = await autoService.listRules();
      final existing = rules
          .where((r) => r.key.trim().toLowerCase() == cleanKey.toLowerCase())
          .firstOrNull;
      final merged = existing == null
          ? info
          : AutoMapInfo(
              raw: existing.info.raw,
              recordType: info.recordType ?? existing.info.recordType,
              mapCategoryId: info.mapCategoryId ?? existing.info.mapCategoryId,
              mapAssetId: info.mapAssetId ?? existing.info.mapAssetId,
              toAssetId: info.toAssetId ?? existing.info.toAssetId,
              bookId: info.bookId ?? existing.info.bookId,
              remark: existing.info.remark,
              allowAutoConfirm: existing.info.allowAutoConfirm,
            );
      await autoService.saveRule(
        commandId: _commandIds.forPayload([
          'smart-quick-learn',
          _nonce++,
          existing?.id,
          cleanKey,
          merged.encode(),
        ]),
        id: existing?.id,
        key: cleanKey,
        info: merged,
      );
      unawaited(autoService.syncNativeConfig());
    } catch (_) {
      // Learning a convenience rule is non-blocking.
    }
  }

  Future<void> _confirmSingle(
    List<RecordCategory> categories,
    List<Asset> assets,
    int bookId,
  ) async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final grossMoney = parseUrlMoney(
        _amountController.text,
        fieldLabel: '金额',
      );
      Money? discount;
      final discRaw = _discountController.text.trim();
      if (discRaw.isNotEmpty && _singleType != RecordType.transfer) {
        final parsedDisc = parseUrlMoney(
          discRaw,
          fieldLabel: '优惠金额',
          allowZero: true,
        );
        if (parsedDisc.units > grossMoney.units) {
          throw const Failure(FailureCode.validation, '优惠金额不能大于账单金额');
        }
        if (!parsedDisc.isZero) discount = parsedDisc;
      }

      final wantCatType = _singleType == RecordType.income
          ? RecordType.income
          : RecordType.expense;
      final dirCats = categories
          .where((c) => !c.isHide && c.type == wantCatType)
          .toList(growable: false);
      final validCatId = _singleType == RecordType.transfer
          ? null
          : (dirCats.any((c) => c.id == _singleCategoryId)
                ? _singleCategoryId
                : dirCats.firstOrNull?.id);
      final validAssetId = assets.any((a) => a.id == _singleAssetId)
          ? _singleAssetId
          : null;
      final validToAssetId = assets.any((a) => a.id == _singleToAssetId)
          ? _singleToAssetId
          : null;

      if (_singleType == RecordType.transfer) {
        if (validAssetId == null || validToAssetId == null) {
          throw const Failure(FailureCode.validation, '转账必须同时选择转出账户与转入账户');
        }
        if (validAssetId == validToAssetId) {
          throw const Failure(FailureCode.validation, '转出账户和转入账户不能相同');
        }
      } else if (validCatId == null) {
        throw const Failure(FailureCode.validation, '请选择账单分类');
      }

      final cleanRemark = _remarkController.text.trim();
      final learnKeyword = _merchantKeyword.trim().isNotEmpty
          ? _merchantKeyword.trim()
          : cleanRemark;

      await _maybePersistLearnedRule(
        bookId: bookId,
        type: _singleType,
        categoryId: validCatId,
        assetId: validAssetId,
        toAssetId: validToAssetId,
        keyword: learnKeyword,
      );

      if (widget.prefillMode) {
        widget.onPrefilled?.call(
          SmartQuickPrefillResult(
            type: _singleType,
            money: grossMoney,
            discount: discount,
            categoryId: validCatId,
            assetId: validAssetId,
            toAssetId: validToAssetId,
            remark: cleanRemark,
            recordTimeMs: _singleTimeMs,
          ),
        );
        return;
      }

      // Standalone mode: write directly through LedgerService with FX snapshot support.
      final db = await ref.read(databaseProvider.future);
      final ledger = await ref.read(ledgerServiceProvider.future);
      final netMoney = discount != null ? grossMoney - discount : grossMoney;
      final primaryAsset = assets
          .where((a) => a.id == validAssetId)
          .firstOrNull;
      final secondaryAsset = _singleType == RecordType.transfer
          ? assets.where((a) => a.id == validToAssetId).firstOrNull
          : null;
      final extra = await _buildCurrencyExtra(
        db: db,
        recordType: _singleType,
        grossMoney: grossMoney,
        netMoney: netMoney,
        primaryAsset: primaryAsset,
        secondaryAsset: secondaryAsset,
      );

      final cmdSeed = _commandIds.forPayload([
        'smart-quick-save',
        _nonce++,
        bookId,
        _singleType,
        grossMoney.toJson(),
        discount?.toJson(),
        validCatId,
        validAssetId,
        validToAssetId,
        cleanRemark,
        _singleTimeMs,
      ]);
      final innerHash = sha256
          .convert(utf8.encode(cmdSeed))
          .toString()
          .substring(0, 48);

      await ledger.saveRecord(
        commandId: 'smart-q:$innerHash',
        draft: RecordDraft(
          type: _singleType,
          money: netMoney,
          bookId: bookId,
          recordTime: _singleTimeMs,
          categoryId: _singleType == RecordType.transfer ? noRef : validCatId!,
          assetId: _singleType == RecordType.transfer
              ? noRef
              : (validAssetId ?? noRef),
          fromAssetId: _singleType == RecordType.transfer
              ? validAssetId!
              : noRef,
          toAssetId: _singleType == RecordType.transfer
              ? validToAssetId!
              : noRef,
          remark: cleanRemark,
          discount: discount,
          extra: extra,
        ),
      );

      final widgetSvc = await ref.read(widgetSnapshotServiceProvider.future);
      await widgetSvc.syncToPlatform();
      ref.invalidate(widgetSnapshotProvider);

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已确认入账 ¥${netMoney.decimal}')));
      widget.onStandaloneDone?.call();
    } catch (e) {
      if (mounted) setState(() => _error = safeMessage(e));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<RecordExtra> _buildCurrencyExtra({
    required AppDatabase db,
    required int recordType,
    required Money grossMoney,
    required Money netMoney,
    required Asset? primaryAsset,
    required Asset? secondaryAsset,
  }) async {
    final extra = RecordExtra();
    final primaryCurrency =
        normalizeCurrency(primaryAsset?.currency) ?? baseCurrency;
    final secondaryCurrency =
        normalizeCurrency(secondaryAsset?.currency) ?? baseCurrency;
    if (recordType == RecordType.transfer) {
      if (primaryCurrency == baseCurrency &&
          secondaryCurrency == baseCurrency) {
        return extra;
      }
      final rows = await db.select(db.currencies).get();
      final rates = RateTable({for (final c in rows) c.code: c.rateToAnchor});
      final targetMinor = primaryCurrency == secondaryCurrency
          ? netMoney.storageMinor
          : rates.convert(
              netMoney.storageMinor,
              primaryCurrency,
              secondaryCurrency,
            );
      extra.currency = billSnapshot(
        source: primaryCurrency,
        sourceMinor: netMoney.storageMinor,
        account: secondaryCurrency,
        assetMinor: targetMinor,
        rates: rates,
      );
      return extra;
    }
    if (primaryCurrency != baseCurrency) {
      final rows = await db.select(db.currencies).get();
      final rates = RateTable({for (final c in rows) c.code: c.rateToAnchor});
      extra.currency = billSnapshot(
        source: primaryCurrency,
        sourceMinor: grossMoney.storageMinor,
        account: primaryCurrency,
        assetMinor: netMoney.storageMinor,
        rates: rates,
      );
    }
    return extra;
  }

  void _updateMultiCandidate(int index, OcrBillCandidate updated) {
    setState(() {
      _multiCandidates = [
        for (final c in _multiCandidates)
          if (c.index == index) updated else c,
      ];
    });
  }

  Future<void> _confirmBatch(int bookId) async {
    final selected = _multiCandidates.where((c) => c.selected).toList();
    if (selected.isEmpty) {
      setState(() => _error = '请至少勾选一笔需要入账的记录');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final ocrService = await ref.read(ocrServiceProvider.future);
      final cmdId = _commandIds.forPayload([
        'smart-quick-batch',
        _nonce++,
        bookId,
        _defaultBatchAssetId,
        for (final c in selected)
          [
            c.index,
            c.type,
            c.money.toJson(),
            c.categoryId,
            c.assetId,
            c.remark,
          ],
      ]);
      final ids = await ocrService.confirmCandidates(
        commandId: cmdId,
        bookId: bookId,
        candidates: _multiCandidates,
        defaultAssetId: _defaultBatchAssetId,
      );
      final widgetSvc = await ref.read(widgetSnapshotServiceProvider.future);
      await widgetSvc.syncToPlatform();
      ref.invalidate(widgetSnapshotProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已成功批量入账 ${ids.length} 笔账单')));
      widget.onStandaloneDone?.call();
    } catch (e) {
      if (mounted) setState(() => _error = safeMessage(e));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.consumeSharedQueue) {
      ref.listen<AutoBillSharedPayload?>(pendingSharedPayloadProvider, (
        _,
        next,
      ) {
        if (next != null) {
          final consumed = ref
              .read(pendingSharedPayloadProvider.notifier)
              .consume();
          if (consumed != null) {
            unawaited(_processSharedPayload(consumed));
          }
        }
      });
    }

    final bookId = ref.watch(currentBookIdProvider).value ?? 1;
    final categories =
        ref.watch(categoriesProvider(bookId)).value ?? const <RecordCategory>[];
    final assets = (ref.watch(assetsProvider).value ?? const <Asset>[])
        .where(
          (a) => a.type != AssetType.debt && a.status != AssetStatus.settled,
        )
        .toList(growable: false);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDesktop = DesktopAdaptive.isDesktop(context);

    final catMap = {for (final c in categories) c.id: c.name};
    final assetMap = {for (final a in assets) a.id: a.name};

    final wantCatType = _singleType == RecordType.income
        ? RecordType.income
        : RecordType.expense;
    final dirCats = categories
        .where((c) => !c.isHide && c.type == wantCatType)
        .toList(growable: false);
    final validSingleCatId = dirCats.any((c) => c.id == _singleCategoryId)
        ? _singleCategoryId
        : dirCats.firstOrNull?.id;
    final validSingleAssetId = assets.any((a) => a.id == _singleAssetId)
        ? _singleAssetId
        : null;
    final validSingleToAssetId = assets.any((a) => a.id == _singleToAssetId)
        ? _singleToAssetId
        : null;
    final validDefaultBatchAssetId =
        assets.any((a) => a.id == _defaultBatchAssetId)
        ? _defaultBatchAssetId
        : null;

    final learnKeywordDisplay = _merchantKeyword.trim().isNotEmpty
        ? _merchantKeyword.trim()
        : _remarkController.text.trim();
    final canShowLearnToggle =
        learnKeywordDisplay.isNotEmpty && isAutoMapRuleKey(learnKeywordDisplay);
    final targetSummary = _singleType == RecordType.transfer
        ? '${assetMap[validSingleAssetId] ?? '转出'} → ${assetMap[validSingleToAssetId] ?? '转入'}'
        : [
            if (validSingleCatId != null && catMap[validSingleCatId] != null)
              catMap[validSingleCatId]!,
            assetMap[validSingleAssetId] ?? '未选账户',
          ].join(' · ');

    final selectedBatchCount = _multiCandidates.where((c) => c.selected).length;

    return SingleChildScrollView(
      key: const Key('smart_quick_list_view'),
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('smart_quick_text_input'),
            controller: _textController,
            maxLines: 2,
            minLines: 1,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) =>
                _parseInputText(sourceOverride: widget.sourceApp),
            decoration: InputDecoration(
              labelText: '输入一句记账口语，或粘贴短信/通知文本',
              hintText: '例：早饭买煎饼微信花了9块5 / 昨天打车32元招行卡',
              border: const OutlineInputBorder(),
              suffixIcon: _textController.text.isNotEmpty
                  ? IconButton(
                      tooltip: '清空输入',
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () => setState(_textController.clear),
                    )
                  : null,
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                key: const Key('smart_quick_parse_button'),
                style: FilledButton.styleFrom(
                  visualDensity: isDesktop ? null : VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
                onPressed: _parsing
                    ? null
                    : () => _parseInputText(sourceOverride: widget.sourceApp),
                icon: const Icon(Icons.auto_awesome, size: 17),
                label: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    _parsing ? '识别中…' : '智能识别',
                    maxLines: 1,
                    softWrap: false,
                  ),
                ),
              ),
              FilledButton.tonalIcon(
                key: const Key('smart_quick_paste_button'),
                style: FilledButton.styleFrom(
                  visualDensity: isDesktop ? null : VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
                onPressed: _parsing ? null : _pasteFromClipboardAndParse,
                icon: const Icon(Icons.content_paste_go_rounded, size: 17),
                label: const FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text('粘贴剪贴板识别', maxLines: 1, softWrap: false),
                ),
              ),
              OutlinedButton.icon(
                key: const Key('smart_quick_pick_image_button'),
                style: OutlinedButton.styleFrom(
                  visualDensity: isDesktop ? null : VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
                onPressed: _parsing ? null : _pickAndRecognizeImage,
                icon: const Icon(Icons.document_scanner_outlined, size: 17),
                label: const FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text('选图离线识账', maxLines: 1, softWrap: false),
                ),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Container(
              key: const Key('smart_quick_error_banner'),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.errorContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                _error!,
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ),
          ],
          if (_infoMessage != null) ...[
            const SizedBox(height: 12),
            Container(
              key: const Key('smart_quick_info_banner'),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: scheme.secondaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                _infoMessage!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSecondaryContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
          if (_hasSingleCandidate) ...[
            const SizedBox(height: 14),
            Card(
              key: const Key('smart_quick_single_card'),
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '核对识别结果',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        if (_sourceLabel.isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.primaryContainer,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              _sourceLabel,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: scheme.onPrimaryContainer,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: SegmentedButton<int>(
                        key: const Key('smart_quick_type_segment'),
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(
                            value: RecordType.expense,
                            label: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text('支出', maxLines: 1, softWrap: false),
                            ),
                          ),
                          ButtonSegment(
                            value: RecordType.income,
                            label: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text('收入', maxLines: 1, softWrap: false),
                            ),
                          ),
                          ButtonSegment(
                            value: RecordType.transfer,
                            label: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text('转账', maxLines: 1, softWrap: false),
                            ),
                          ),
                        ],
                        selected: {_singleType},
                        onSelectionChanged: (s) =>
                            setState(() => _singleType = s.first),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const Key('smart_quick_amount_input'),
                      controller: _amountController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: '金额（元）',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    if (_discountController.text.trim().isNotEmpty &&
                        _singleType != RecordType.transfer) ...[
                      const SizedBox(height: 12),
                      TextField(
                        key: const Key('smart_quick_discount_input'),
                        controller: _discountController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: '优惠减免（元，可选）',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ],
                    if (_singleType != RecordType.transfer) ...[
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: InputDecorator(
                              decoration: const InputDecoration(
                                labelText: '分类',
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 14,
                                ),
                              ),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<int>(
                                  key: const Key(
                                    'smart_quick_category_dropdown',
                                  ),
                                  isExpanded: true,
                                  isDense: true,
                                  style: theme.textTheme.bodyLarge,
                                  value: validSingleCatId,
                                  items: [
                                    for (final c in dirCats)
                                      DropdownMenuItem(
                                        value: c.id,
                                        child: Text(c.name),
                                      ),
                                  ],
                                  onChanged: (v) =>
                                      setState(() => _singleCategoryId = v),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: InputDecorator(
                              decoration: const InputDecoration(
                                labelText: '扣款 / 入账账户',
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 14,
                                ),
                              ),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<int?>(
                                  key: const Key('smart_quick_asset_dropdown'),
                                  isExpanded: true,
                                  isDense: true,
                                  style: theme.textTheme.bodyLarge,
                                  value: validSingleAssetId,
                                  items: [
                                    const DropdownMenuItem<int?>(
                                      value: null,
                                      child: Text('不指定账户'),
                                    ),
                                    for (final a in assets)
                                      DropdownMenuItem<int?>(
                                        value: a.id,
                                        child: Text(a.name),
                                      ),
                                  ],
                                  onChanged: (v) =>
                                      setState(() => _singleAssetId = v),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ] else ...[
                      const SizedBox(height: 12),
                      InputDecorator(
                        decoration: const InputDecoration(
                          labelText: '转出账户',
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 14,
                          ),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<int?>(
                            key: const Key('smart_quick_asset_dropdown'),
                            isExpanded: true,
                            isDense: true,
                            style: theme.textTheme.bodyLarge,
                            value: validSingleAssetId,
                            items: [
                              for (final a in assets)
                                DropdownMenuItem<int?>(
                                  value: a.id,
                                  child: Text(a.name),
                                ),
                            ],
                            onChanged: (v) =>
                                setState(() => _singleAssetId = v),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      InputDecorator(
                        decoration: const InputDecoration(
                          labelText: '转入账户',
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 14,
                          ),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<int?>(
                            key: const Key('smart_quick_to_asset_dropdown'),
                            isExpanded: true,
                            isDense: true,
                            style: theme.textTheme.bodyLarge,
                            value: validSingleToAssetId,
                            items: [
                              for (final a in assets)
                                DropdownMenuItem<int?>(
                                  value: a.id,
                                  child: Text(a.name),
                                ),
                            ],
                            onChanged: (v) =>
                                setState(() => _singleToAssetId = v),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    TextField(
                      key: const Key('smart_quick_remark_input'),
                      controller: _remarkController,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: '备注',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        key: const Key('smart_quick_datetime_button'),
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: _pickDateTime,
                        icon: const Icon(Icons.schedule, size: 16),
                        label: Text(
                          formatDateTime(
                            DateTime.fromMillisecondsSinceEpoch(_singleTimeMs),
                          ),
                        ),
                      ),
                    ),
                    if (canShowLearnToggle) ...[
                      const SizedBox(height: 4),
                      CheckboxListTile(
                        key: const Key('smart_quick_learn_rule_toggle'),
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: _learnRule,
                        onChanged: (v) =>
                            setState(() => _learnRule = v ?? false),
                        title: Text(
                          '记住「$learnKeywordDisplay → $targetSummary」',
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        key: const Key('smart_quick_confirm_button'),
                        onPressed: _submitting
                            ? null
                            : () => _confirmSingle(categories, assets, bookId),
                        icon: Icon(
                          widget.prefillMode
                              ? Icons.edit_note_rounded
                              : Icons.check_circle_outline,
                          size: 18,
                        ),
                        label: Text(
                          _submitting
                              ? '提交中…'
                              : (widget.prefillMode ? '填入记账单' : '确认入账'),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (_multiCandidates.isNotEmpty) ...[
            const SizedBox(height: 14),
            Column(
              key: const Key('smart_quick_multi_section'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '多笔账单核对（已选 $selectedBatchCount / ${_multiCandidates.length} 笔）',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      key: const Key('smart_quick_confirm_batch_button'),
                      style: FilledButton.styleFrom(
                        visualDensity: isDesktop ? null : VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                      ),
                      onPressed: _submitting || selectedBatchCount == 0
                          ? null
                          : () => _confirmBatch(bookId),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          _submitting ? '入账中…' : '批量入账 ($selectedBatchCount)',
                          maxLines: 1,
                          softWrap: false,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                InputDecorator(
                  decoration: const InputDecoration(
                    labelText: '默认资金账户（单笔未指定时生效）',
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 14,
                    ),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<int?>(
                      isExpanded: true,
                      isDense: true,
                      style: theme.textTheme.bodyLarge,
                      value: validDefaultBatchAssetId,
                      items: [
                        const DropdownMenuItem<int?>(
                          value: null,
                          child: Text('不指定默认账户'),
                        ),
                        for (final a in assets)
                          DropdownMenuItem<int?>(
                            value: a.id,
                            child: Text(a.name),
                          ),
                      ],
                      onChanged: (v) =>
                          setState(() => _defaultBatchAssetId = v),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                for (final candidate in _multiCandidates) ...[
                  _MultiCandidateCard(
                    candidate: candidate,
                    categories: categories,
                    assets: assets,
                    prefillMode: widget.prefillMode,
                    onChanged: (next) =>
                        _updateMultiCandidate(candidate.index, next),
                    onFillSingle: widget.prefillMode
                        ? () => widget.onPrefilled?.call(
                            SmartQuickPrefillResult(
                              type: candidate.type,
                              money: candidate.money,
                              discount: candidate.discount,
                              categoryId: candidate.categoryId,
                              assetId:
                                  candidate.assetId ?? _defaultBatchAssetId,
                              remark: candidate.remark,
                              recordTimeMs: candidate.recordTimeMs,
                            ),
                          )
                        : null,
                  ),
                  const SizedBox(height: 8),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _MultiCandidateCard extends StatelessWidget {
  const _MultiCandidateCard({
    required this.candidate,
    required this.categories,
    required this.assets,
    required this.prefillMode,
    required this.onChanged,
    this.onFillSingle,
  });

  final OcrBillCandidate candidate;
  final List<RecordCategory> categories;
  final List<Asset> assets;
  final bool prefillMode;
  final ValueChanged<OcrBillCandidate> onChanged;
  final VoidCallback? onFillSingle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dirCats = categories
        .where((c) => !c.isHide && c.type == candidate.type)
        .toList(growable: false);
    final validCatId = dirCats.any((c) => c.id == candidate.categoryId)
        ? candidate.categoryId
        : dirCats.firstOrNull?.id;
    final validAssetId = assets.any((a) => a.id == candidate.assetId)
        ? candidate.assetId
        : null;

    return Card(
      key: Key('smart_quick_candidate_${candidate.index}'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Checkbox(
                  key: Key('smart_quick_candidate_check_${candidate.index}'),
                  visualDensity: VisualDensity.compact,
                  value: candidate.selected,
                  onChanged: (v) =>
                      onChanged(candidate.copyWith(selected: v ?? false)),
                ),
                ActionChip(
                  visualDensity: VisualDensity.compact,
                  label: Text(
                    candidate.type == RecordType.income ? '收入' : '支出',
                  ),
                  onPressed: () {
                    final nextType = candidate.type == RecordType.income
                        ? RecordType.expense
                        : RecordType.income;
                    final nextCat = categories
                        .where((c) => !c.isHide && c.type == nextType)
                        .firstOrNull
                        ?.id;
                    onChanged(
                      candidate.copyWith(type: nextType, categoryId: nextCat),
                    );
                  },
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    candidate.remark,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '¥${candidate.money.decimal}',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (prefillMode && onFillSingle != null) ...[
                  const SizedBox(width: 6),
                  TextButton(
                    key: Key('smart_quick_candidate_fill_${candidate.index}'),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    onPressed: onFillSingle,
                    child: const Text('填入'),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: '分类',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 14,
                      ),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<int>(
                        isExpanded: true,
                        isDense: true,
                        style: theme.textTheme.bodyLarge,
                        value: validCatId,
                        items: [
                          for (final c in dirCats)
                            DropdownMenuItem(value: c.id, child: Text(c.name)),
                        ],
                        onChanged: (v) =>
                            onChanged(candidate.copyWith(categoryId: v)),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: '账户（可选）',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 14,
                      ),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<int?>(
                        isExpanded: true,
                        isDense: true,
                        style: theme.textTheme.bodyLarge,
                        value: validAssetId,
                        items: [
                          const DropdownMenuItem<int?>(
                            value: null,
                            child: Text('跟随默认'),
                          ),
                          for (final a in assets)
                            DropdownMenuItem<int?>(
                              value: a.id,
                              child: Text(a.name),
                            ),
                        ],
                        onChanged: (v) => onChanged(
                          OcrBillCandidate(
                            index: candidate.index,
                            type: candidate.type,
                            money: candidate.money,
                            discount: candidate.discount,
                            recordTimeMs: candidate.recordTimeMs,
                            merchant: candidate.merchant,
                            remark: candidate.remark,
                            categoryHint: candidate.categoryHint,
                            accountHint: candidate.accountHint,
                            categoryId: validCatId,
                            assetId: v,
                            selected: candidate.selected,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
