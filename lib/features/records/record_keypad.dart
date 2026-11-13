import 'package:flutter/material.dart';

import '../../core/failure.dart';
import '../../data/db/database.dart';
import '../../domain/rules/record_keypad_calc.dart';
import '../common/catalog_icons.dart' as catalog_icons;

/// Visual icon + accent color resolved for a [RecordCategory], delegating to
/// the shared `catalog_icons.dart` visual system.
final class CategoryVisualSpec {
  const CategoryVisualSpec({required this.icon, required this.color});

  final IconData icon;
  final Color color;
}

/// Resolves semantic icon + color for [category] via `catalog_icons.dart`,
/// honoring custom `icon` and `colorFill` set in `CategoriesPage` as well as
/// optional parent category inheritance.
CategoryVisualSpec resolveCategoryVisual(
  RecordCategory category, {
  String? parentIconKey,
  String? parentColorHex,
}) {
  final effectiveColor =
      (category.colorFill != null && category.colorFill!.trim().isNotEmpty)
      ? category.colorFill
      : parentColorHex;
  final resolved = catalog_icons.resolveCategoryVisual(
    iconKey: category.icon,
    parentIconKey: parentIconKey,
    colorHex: effectiveColor,
    name: category.name,
    type: category.type,
  );
  return CategoryVisualSpec(icon: resolved.icon, color: resolved.color);
}

/// Resolves semantic icon for an [Asset] account pill / transfer card via
/// `catalog_icons.dart`.
IconData resolveAccountIcon(Asset? asset) {
  if (asset == null) return Icons.account_balance_wallet_outlined;
  return catalog_icons
      .resolveAssetVisual(
        iconKey: asset.icon,
        colorHex: asset.color,
        name: asset.name,
        assetType: asset.type,
        subType: asset.subType,
      )
      .icon;
}

bool _isBinaryOpChar(String ch) =>
    ch == '+' || ch == '-' || ch == '×' || ch == '÷';

bool _isSegmentValid(String seg) {
  if (seg.isEmpty || seg == '.') return true;
  final dotIdx = seg.indexOf('.');
  if (dotIdx >= 0) {
    if (seg.lastIndexOf('.') != dotIdx) return false;
    if (seg.length - dotIdx - 1 > defaultMaxKeypadDecimals) return false;
  }
  try {
    final minor = BigRational.parseDecimal(seg).toMinorHalfUp();
    return minor <= maxKeypadAmountMinor;
  } on Failure {
    return false;
  }
}

bool _isActiveOperandValid(String expr) {
  final clean = sanitizeKeypadExpression(expr);
  if (clean.isEmpty) return true;
  final start = (clean.startsWith('-') || clean.startsWith('+')) ? 1 : 0;
  var lastOp = -1;
  for (var i = clean.length - 1; i >= start; i--) {
    if (_isBinaryOpChar(clean[i])) {
      lastOp = i;
      break;
    }
  }
  final seg = clean.substring(lastOp >= 0 ? lastOp + 1 : start);
  return _isSegmentValid(seg);
}

bool _areAllOperandsValid(String expr) {
  final clean = sanitizeKeypadExpression(expr);
  if (clean.isEmpty) return true;
  final start = (clean.startsWith('-') || clean.startsWith('+')) ? 1 : 0;
  var segStart = start;
  for (var i = start; i <= clean.length; i++) {
    final isEnd = i == clean.length;
    final ch = isEnd ? '' : clean[i];
    if (isEnd || _isBinaryOpChar(ch)) {
      if (!_isSegmentValid(clean.substring(segStart, i))) {
        return false;
      }
      segStart = i + 1;
    }
  }
  return true;
}

/// Applies a single custom keypad key (`'0'`..`'9'`, `'00'`, `'.'`, `'+'`,
/// `'-'`, `'×'`, `'÷'`, `'BACKSPACE'`, `'CLEAR'`) to [current], enforcing:
/// - 2-decimal scale per operand segment,
/// - leading-zero & leading-dot normalization (`'' + '.' -> '0.'`, `'12+' + '.' -> '12+0.'`),
/// - `maxKeypadAmount` (`88888888888.00`) per operand segment via exact [BigRational]/[BigInt],
/// - cursor-aware backspace and range replacement.
TextEditingValue applyCustomKeypadValue(TextEditingValue current, String key) {
  final upper = key.trim().toUpperCase();
  if (upper == 'CLEAR') {
    return const TextEditingValue(
      text: '',
      selection: TextSelection.collapsed(offset: 0),
    );
  }

  final raw = current.text;
  final sel = current.selection;

  if (upper == 'BACKSPACE') {
    if (raw.isEmpty) {
      return const TextEditingValue(
        text: '',
        selection: TextSelection.collapsed(offset: 0),
      );
    }
    if (sel.isValid &&
        !sel.isCollapsed &&
        sel.start >= 0 &&
        sel.end <= raw.length) {
      final replaced = sanitizeKeypadExpression(
        raw.replaceRange(sel.start, sel.end, ''),
      );
      final cleaned = (replaced == '-' || replaced == '+') ? '' : replaced;
      if (!_areAllOperandsValid(cleaned)) return current;
      return TextEditingValue(
        text: cleaned,
        selection: TextSelection.collapsed(
          offset: sel.start.clamp(0, cleaned.length),
        ),
      );
    }
    if (sel.isValid &&
        sel.isCollapsed &&
        sel.baseOffset >= 0 &&
        sel.baseOffset < raw.length) {
      if (sel.baseOffset == 0) return current;
      final pos = sel.baseOffset;
      final deleted = sanitizeKeypadExpression(
        raw.substring(0, pos - 1) + raw.substring(pos),
      );
      final cleaned = (deleted == '-' || deleted == '+') ? '' : deleted;
      if (!_areAllOperandsValid(cleaned)) return current;
      return TextEditingValue(
        text: cleaned,
        selection: TextSelection.collapsed(
          offset: (pos - 1).clamp(0, cleaned.length),
        ),
      );
    }
    final next = applyKeypadKey(raw, 'BACKSPACE');
    return TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
  }

  if (key == '00') {
    final once = applyCustomKeypadValue(current, '0');
    return applyCustomKeypadValue(once, '0');
  }

  final isOp = canonicalKeypadOperator(key.trim()) != null;

  // Replace active range selection when typing a digit or decimal point.
  var baseText = raw;
  var cursorAtMiddle = false;
  var middleOffset = raw.length;
  if (sel.isValid &&
      !sel.isCollapsed &&
      !isOp &&
      sel.start >= 0 &&
      sel.end <= raw.length) {
    baseText = raw.replaceRange(sel.start, sel.end, '');
    middleOffset = sel.start;
    cursorAtMiddle = middleOffset < baseText.length;
  } else if (sel.isValid &&
      sel.isCollapsed &&
      sel.baseOffset >= 0 &&
      sel.baseOffset < raw.length) {
    cursorAtMiddle = true;
    middleOffset = sel.baseOffset;
  }

  if (cursorAtMiddle) {
    final prefix = baseText.substring(0, middleOffset);
    final suffix = baseText.substring(middleOffset);
    final updatedPrefix = applyKeypadKey(prefix, key);
    if (updatedPrefix == sanitizeKeypadExpression(prefix)) {
      return current;
    }
    final combined = sanitizeKeypadExpression('$updatedPrefix$suffix');
    if (_areAllOperandsValid(combined)) {
      return TextEditingValue(
        text: combined,
        selection: TextSelection.collapsed(
          offset: updatedPrefix.length.clamp(0, combined.length),
        ),
      );
    }
    return current;
  }

  final next = applyKeypadKey(baseText, key);
  if (!isOp && !_isActiveOperandValid(next)) {
    return current;
  }
  return TextEditingValue(
    text: next,
    selection: TextSelection.collapsed(offset: next.length),
  );
}

/// Clean 一羽 / 钱迹 style 4×4 custom arithmetic keypad (`254dp` before `SafeArea`
/// bottom inset) for `RecordEditorPage`:
/// - Row 1: `7`, `8`, `9`, `⌫` (tap backspace, long-press clear all)
/// - Row 2: `4`, `5`, `6`, `+` (tap `+`; optional long-press `×` when [enableMultiplyDivide] is true)
/// - Row 3: `1`, `2`, `3`, `−` (tap `-`; optional long-press `÷` when [enableMultiplyDivide] is true)
/// - Row 4: `再记`, `0`, `.`, smart `= / 保存`
class RecordCustomKeypad extends StatelessWidget {
  const RecordCustomKeypad({
    super.key = const Key('record-custom-keypad'),
    required this.amountText,
    required this.enabled,
    required this.busy,
    required this.onKeyTap,
    required this.onBackspace,
    required this.onClearAll,
    required this.onEvaluate,
    required this.onSave,
    this.onSaveAndNew,
    this.enableMultiplyDivide = false,
  });

  final String amountText;
  final bool enabled;
  final bool busy;
  final ValueChanged<String> onKeyTap;
  final VoidCallback onBackspace;
  final VoidCallback onClearAll;
  final VoidCallback onEvaluate;
  final VoidCallback onSave;
  final VoidCallback? onSaveAndNew;
  final bool enableMultiplyDivide;

  static const double keyRowHeight = 56.0;
  static const double gridGap = 6.0;
  static const double panelHeight =
      keyRowHeight * 4 + gridGap * 3 + 12.0; // 254dp

  static const OutlinedBorder _keyShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(12)),
    side: BorderSide.none,
  );

  Color _trayColor(BuildContext context, ColorScheme cs) =>
      Theme.of(context).brightness == Brightness.dark
      ? cs.surfaceContainerLowest
      : cs.surfaceContainerLow;

  Color _digitKeyColor(BuildContext context, ColorScheme cs) =>
      Theme.of(context).brightness == Brightness.dark
      ? cs.surfaceContainerHigh
      : cs.surface;

  Color _utilityKeyColor(BuildContext context, ColorScheme cs) =>
      Theme.of(context).brightness == Brightness.dark
      ? cs.surfaceContainer
      : cs.secondaryContainer.withAlpha(115);

  Color _utilityForegroundColor(BuildContext context, ColorScheme cs) =>
      Theme.of(context).brightness == Brightness.dark
      ? cs.onSurface
      : cs.onSecondaryContainer;

  Widget _buildDigitKey(
    BuildContext context, {
    required Key key,
    required String label,
    String? insertValue,
  }) {
    final cs = Theme.of(context).colorScheme;
    final token = insertValue ?? label;
    return Expanded(
      child: SizedBox(
        height: keyRowHeight,
        child: Material(
          color: _digitKeyColor(context, cs),
          shape: _keyShape,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: key,
            canRequestFocus: false,
            onTap: busy ? null : () => onKeyTap(token),
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w600,
                  height: 1.0,
                  color: busy
                      ? cs.onSurfaceVariant.withAlpha(110)
                      : cs.onSurface,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBackspaceKey(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fgColor = _utilityForegroundColor(context, cs);
    return Expanded(
      child: Tooltip(
        message: '退格（长按清空）',
        child: SizedBox(
          height: keyRowHeight,
          child: Material(
            color: _utilityKeyColor(context, cs),
            shape: _keyShape,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: const Key('keypad-backspace'),
              canRequestFocus: false,
              onTap: busy ? null : onBackspace,
              onLongPress: busy ? null : onClearAll,
              child: Center(
                child: Icon(
                  Icons.backspace_outlined,
                  size: 20,
                  color: busy ? cs.onSurfaceVariant.withAlpha(110) : fgColor,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOperatorKey(
    BuildContext context, {
    required Key key,
    required String label,
    required String op,
    required String longPressLabel,
    required String longPressOp,
    required String baseTooltip,
    required String longPressTooltip,
  }) {
    final cs = Theme.of(context).colorScheme;
    final fgColor = _utilityForegroundColor(context, cs);
    final allowLongPress = enableMultiplyDivide;
    return Expanded(
      child: Tooltip(
        message: allowLongPress ? longPressTooltip : baseTooltip,
        child: SizedBox(
          height: keyRowHeight,
          child: Material(
            color: _utilityKeyColor(context, cs),
            shape: _keyShape,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: key,
              canRequestFocus: false,
              onTap: busy ? null : () => onKeyTap(op),
              onLongPress: !allowLongPress || busy
                  ? null
                  : () => onKeyTap(longPressOp),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Center(
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                        height: 1.0,
                        color: busy
                            ? cs.onSurfaceVariant.withAlpha(110)
                            : fgColor,
                      ),
                    ),
                  ),
                  if (allowLongPress)
                    Positioned(
                      top: 5,
                      right: 7,
                      child: Text(
                        longPressLabel,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          height: 1.0,
                          color: busy
                              ? cs.onSurfaceVariant.withAlpha(75)
                              : fgColor.withAlpha(140),
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

  Widget _buildSaveAndNewKey(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fgColor = _utilityForegroundColor(context, cs);
    final active = enabled && !busy && onSaveAndNew != null;
    return Expanded(
      child: SizedBox(
        height: keyRowHeight,
        child: Material(
          color: _utilityKeyColor(context, cs),
          shape: _keyShape,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: const Key('save-and-new'),
            canRequestFocus: false,
            onTap: active ? onSaveAndNew : null,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  '再记',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    height: 1.0,
                    color: active
                        ? fgColor
                        : cs.onSurfaceVariant.withAlpha(110),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPrimaryActionKey(BuildContext context) {
    final pendingOp = hasPendingOperator(amountText);
    final active = enabled && !busy;

    final button = KeyedSubtree(
      key: const Key('editor-save-btn'),
      child: FilledButton(
        key: const Key('save'),
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(keyRowHeight),
          padding: const EdgeInsets.symmetric(horizontal: 6),
          side: BorderSide.none,
          shape: _keyShape,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        onPressed: active ? (pendingOp ? onEvaluate : onSave) : null,
        child: pendingOp
            ? const Text(
                '=',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  height: 1.0,
                ),
              )
            : Text(
                busy ? '保存中…' : '保存',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
      ),
    );

    return Expanded(
      child: ExcludeFocus(
        child: SizedBox(
          height: keyRowHeight,
          child: pendingOp ? Tooltip(message: '计算结果', child: button) : button,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return TextFieldTapRegion(
      child: ExcludeFocus(
        child: Container(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
          decoration: BoxDecoration(color: _trayColor(context, cs)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Row 1: 7, 8, 9, ⌫
              Row(
                children: [
                  _buildDigitKey(
                    context,
                    key: const Key('keypad-7'),
                    label: '7',
                  ),
                  const SizedBox(width: gridGap),
                  _buildDigitKey(
                    context,
                    key: const Key('keypad-8'),
                    label: '8',
                  ),
                  const SizedBox(width: gridGap),
                  _buildDigitKey(
                    context,
                    key: const Key('keypad-9'),
                    label: '9',
                  ),
                  const SizedBox(width: gridGap),
                  _buildBackspaceKey(context),
                ],
              ),
              const SizedBox(height: gridGap),
              // Row 2: 4, 5, 6, + (optional long-press ×)
              Row(
                children: [
                  _buildDigitKey(
                    context,
                    key: const Key('keypad-4'),
                    label: '4',
                  ),
                  const SizedBox(width: gridGap),
                  _buildDigitKey(
                    context,
                    key: const Key('keypad-5'),
                    label: '5',
                  ),
                  const SizedBox(width: gridGap),
                  _buildDigitKey(
                    context,
                    key: const Key('keypad-6'),
                    label: '6',
                  ),
                  const SizedBox(width: gridGap),
                  _buildOperatorKey(
                    context,
                    key: const Key('editor-op-add'),
                    label: '+',
                    op: '+',
                    longPressLabel: '×',
                    longPressOp: '×',
                    baseTooltip: '加',
                    longPressTooltip: '加（长按输入 ×）',
                  ),
                ],
              ),
              const SizedBox(height: gridGap),
              // Row 3: 1, 2, 3, − (optional long-press ÷)
              Row(
                children: [
                  _buildDigitKey(
                    context,
                    key: const Key('keypad-1'),
                    label: '1',
                  ),
                  const SizedBox(width: gridGap),
                  _buildDigitKey(
                    context,
                    key: const Key('keypad-2'),
                    label: '2',
                  ),
                  const SizedBox(width: gridGap),
                  _buildDigitKey(
                    context,
                    key: const Key('keypad-3'),
                    label: '3',
                  ),
                  const SizedBox(width: gridGap),
                  _buildOperatorKey(
                    context,
                    key: const Key('editor-op-sub'),
                    label: '−',
                    op: '-',
                    longPressLabel: '÷',
                    longPressOp: '÷',
                    baseTooltip: '减',
                    longPressTooltip: '减（长按输入 ÷）',
                  ),
                ],
              ),
              const SizedBox(height: gridGap),
              // Row 4: 再记, 0, ., 保存 / =
              Row(
                children: [
                  _buildSaveAndNewKey(context),
                  const SizedBox(width: gridGap),
                  _buildDigitKey(
                    context,
                    key: const Key('keypad-0'),
                    label: '0',
                  ),
                  const SizedBox(width: gridGap),
                  _buildDigitKey(
                    context,
                    key: const Key('keypad-dot'),
                    label: '.',
                  ),
                  const SizedBox(width: gridGap),
                  _buildPrimaryActionKey(context),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 5-column responsive visual category grid (`SCR-002` Zone 2).
class RecordCategorySliverGrid extends StatelessWidget {
  const RecordCategorySliverGrid({
    super.key,
    required this.categories,
    required this.selectedParentId,
    required this.enabled,
    required this.onSelectCategory,
    required this.onManageCategories,
  });

  final List<RecordCategory> categories;
  final int? selectedParentId;
  final bool enabled;
  final ValueChanged<RecordCategory> onSelectCategory;
  final VoidCallback? onManageCategories;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final totalCount = categories.length + (onManageCategories != null ? 1 : 0);

    return SliverGrid(
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 84,
        mainAxisExtent: 68,
        crossAxisSpacing: 6,
        mainAxisSpacing: 6,
      ),
      delegate: SliverChildBuilderDelegate((context, index) {
        if (index >= categories.length) {
          return InkWell(
            key: const Key('cat-grid-manage'),
            borderRadius: BorderRadius.circular(12),
            onTap: enabled ? onManageCategories : null,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest.withAlpha(150),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.tune_rounded,
                    size: 19,
                    color: cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '管理',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          );
        }

        final cat = categories[index];
        final selected = selectedParentId == cat.id;
        final visual = resolveCategoryVisual(cat);

        return InkWell(
          key: Key('cat-${cat.name}'),
          borderRadius: BorderRadius.circular(12),
          onTap: enabled ? () => onSelectCategory(cat) : null,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              catalog_icons.CategoryIconAvatar(
                iconKey: cat.icon,
                colorHex: cat.colorFill,
                name: cat.name,
                type: cat.type,
                size: 38,
                selected: selected,
              ),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(
                  cat.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: selected ? visual.color : cs.onSurface,
                  ),
                ),
              ),
            ],
          ),
        );
      }, childCount: totalCount),
    );
  }
}

/// Sleek soft-tinted inline secondary category strip (`SCR-002` Zone 2).
class RecordSubcategoryStrip extends StatelessWidget {
  const RecordSubcategoryStrip({
    super.key,
    required this.parentCategory,
    required this.subCategories,
    required this.selectedCategoryId,
    required this.enabled,
    required this.onSelectCategoryId,
  });

  final RecordCategory? parentCategory;
  final List<RecordCategory> subCategories;
  final int? selectedCategoryId;
  final bool enabled;
  final ValueChanged<int> onSelectCategoryId;

  @override
  Widget build(BuildContext context) {
    if (parentCategory == null || subCategories.isEmpty) {
      return const SizedBox.shrink();
    }
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final parentVisual = resolveCategoryVisual(parentCategory!);

    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: parentVisual.color.withAlpha(isDark ? 26 : 18),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ChoiceChip(
            key: const Key('subcat-all'),
            showCheckmark: false,
            side: BorderSide.none,
            shape: const StadiumBorder(),
            backgroundColor: isDark ? cs.surfaceContainerHigh : cs.surface,
            selectedColor: parentVisual.color.withAlpha(isDark ? 64 : 50),
            visualDensity: const VisualDensity(horizontal: -2, vertical: -3),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            label: const Text('不选二级', style: TextStyle(fontSize: 12)),
            selected: selectedCategoryId == parentCategory!.id,
            onSelected: enabled
                ? (_) => onSelectCategoryId(parentCategory!.id)
                : null,
          ),
          for (final sub in subCategories)
            Builder(
              builder: (context) {
                final subSelected = selectedCategoryId == sub.id;
                final subVisual = resolveCategoryVisual(
                  sub,
                  parentIconKey: parentCategory!.icon,
                  parentColorHex: parentCategory!.colorFill,
                );
                return ChoiceChip(
                  key: Key('cat-${sub.name}'),
                  showCheckmark: false,
                  side: BorderSide.none,
                  shape: const StadiumBorder(),
                  backgroundColor: isDark
                      ? cs.surfaceContainerHigh
                      : cs.surface,
                  visualDensity: const VisualDensity(
                    horizontal: -2,
                    vertical: -3,
                  ),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  avatar: Icon(
                    subVisual.icon,
                    size: 13,
                    color: subSelected ? subVisual.color : cs.onSurfaceVariant,
                  ),
                  label: Text(sub.name, style: const TextStyle(fontSize: 12)),
                  selected: subSelected,
                  selectedColor: subVisual.color.withAlpha(isDark ? 68 : 55),
                  labelStyle: TextStyle(
                    color: subSelected ? cs.onSurface : cs.onSurfaceVariant,
                    fontWeight: subSelected ? FontWeight.w600 : FontWeight.w400,
                  ),
                  onSelected: enabled
                      ? (_) => onSelectCategoryId(sub.id)
                      : null,
                );
              },
            ),
        ],
      ),
    );
  }
}
