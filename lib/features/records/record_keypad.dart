import 'package:flutter/material.dart';

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
    final parentVisual = resolveCategoryVisual(parentCategory!);

    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: parentVisual.color.withAlpha(18),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: parentVisual.color.withAlpha(48), width: 0.8),
      ),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ChoiceChip(
            key: const Key('subcat-all'),
            showCheckmark: false,
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
                  selectedColor: subVisual.color.withAlpha(55),
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

/// Built-in 一羽记账-style calculator keypad (`RecordKeyboard`, `SCR-002` Zone 3).
class RecordKeyboard extends StatelessWidget {
  const RecordKeyboard({
    super.key,
    required this.expression,
    required this.enabled,
    required this.busy,
    required this.showSaveAndNew,
    required this.assignSaveKey,
    required this.onKeyTap,
    required this.onSave,
    this.onSaveAndNew,
  });

  final String expression;
  final bool enabled;
  final bool busy;
  final bool showSaveAndNew;
  final bool assignSaveKey;
  final ValueChanged<String> onKeyTap;
  final VoidCallback? onSave;
  final VoidCallback? onSaveAndNew;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final viewportHeight = MediaQuery.sizeOf(context).height;
    final compact = viewportHeight < 520;
    final rowHeight = compact ? 33.0 : 42.0;
    final gap = compact ? 4.0 : 5.0;
    final pendingOp = hasPendingOperator(expression);

    Widget numKey(String label, {Key? key, String? emit}) => _KeypadCell(
      key: key ?? Key('keypad-$label'),
      height: rowHeight,
      backgroundColor: cs.surface,
      foregroundColor: cs.onSurface,
      onTap: enabled ? () => onKeyTap(emit ?? label) : null,
      child: Text(
        label,
        style: TextStyle(
          fontSize: compact ? 16 : 19,
          fontWeight: FontWeight.w600,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );

    Widget opKey(String symbol, {required Key key}) => _KeypadCell(
      key: key,
      height: rowHeight,
      backgroundColor: cs.surfaceContainerHigh,
      foregroundColor: cs.onSurface,
      onTap: enabled ? () => onKeyTap(symbol) : null,
      child: Text(
        symbol,
        style: TextStyle(
          fontSize: compact ? 17 : 20,
          fontWeight: FontWeight.w600,
        ),
      ),
    );

    final primaryHeight = rowHeight * 2 + gap;

    return Container(
      key: const Key('record-keyboard'),
      padding: EdgeInsets.fromLTRB(8, compact ? 4 : 6, 8, compact ? 4 : 6),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLowest,
        border: Border(top: BorderSide(color: cs.outlineVariant, width: 0.6)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Col 1: 7, 4, 1, C
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                numKey('7'),
                SizedBox(height: gap),
                numKey('4'),
                SizedBox(height: gap),
                numKey('1'),
                SizedBox(height: gap),
                _KeypadCell(
                  key: const Key('keypad-clear'),
                  height: rowHeight,
                  backgroundColor: cs.surfaceContainerLow,
                  foregroundColor: cs.onSurfaceVariant,
                  onTap: enabled ? () => onKeyTap('CLEAR') : null,
                  child: Text(
                    '清空',
                    style: TextStyle(
                      fontSize: compact ? 11 : 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: gap),
          // Col 2: 8, 5, 2, 0
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                numKey('8'),
                SizedBox(height: gap),
                numKey('5'),
                SizedBox(height: gap),
                numKey('2'),
                SizedBox(height: gap),
                numKey('0'),
              ],
            ),
          ),
          SizedBox(width: gap),
          // Col 3: 9, 6, 3, .
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                numKey('9'),
                SizedBox(height: gap),
                numKey('6'),
                SizedBox(height: gap),
                numKey('3'),
                SizedBox(height: gap),
                numKey('.', key: const Key('keypad-dot')),
              ],
            ),
          ),
          SizedBox(width: gap),
          // Col 4: ÷, ×, -, +
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                opKey('÷', key: const Key('keypad-div')),
                SizedBox(height: gap),
                opKey('×', key: const Key('keypad-mul')),
                SizedBox(height: gap),
                opKey('-', key: const Key('keypad-sub')),
                SizedBox(height: gap),
                opKey('+', key: const Key('keypad-add')),
              ],
            ),
          ),
          SizedBox(width: gap),
          // Col 5: ⌫, 再记一笔 (or 00 when editing), and double-height = / 保存
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _KeypadCell(
                  key: const Key('keypad-backspace'),
                  height: rowHeight,
                  backgroundColor: cs.surfaceContainerHigh,
                  foregroundColor: cs.onSurface,
                  onTap: enabled ? () => onKeyTap('BACKSPACE') : null,
                  onLongPress: enabled ? () => onKeyTap('CLEAR') : null,
                  child: Icon(
                    Icons.backspace_outlined,
                    size: compact ? 17 : 19,
                  ),
                ),
                SizedBox(height: gap),
                if (showSaveAndNew)
                  _KeypadCell(
                    key: const Key('save-and-new'),
                    height: rowHeight,
                    backgroundColor: cs.secondaryContainer,
                    foregroundColor: cs.onSecondaryContainer,
                    onTap: enabled && !busy ? onSaveAndNew : null,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          '再记一笔',
                          style: TextStyle(
                            fontSize: compact ? 11 : 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  )
                else
                  numKey('00', key: const Key('keypad-00'), emit: '00'),
                SizedBox(height: gap),
                _KeypadCell(
                  key: assignSaveKey ? const Key('save') : null,
                  height: primaryHeight,
                  backgroundColor: pendingOp ? cs.tertiary : cs.primary,
                  foregroundColor: pendingOp ? cs.onTertiary : cs.onPrimary,
                  onTap: enabled && !busy
                      ? (pendingOp ? () => onKeyTap('EQUALS') : onSave)
                      : null,
                  child: Text(
                    pendingOp ? '=' : (busy ? '保存中' : '保存'),
                    style: TextStyle(
                      fontSize: pendingOp
                          ? (compact ? 20 : 24)
                          : (compact ? 13 : 15),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _KeypadCell extends StatelessWidget {
  const _KeypadCell({
    super.key,
    required this.height,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.child,
    this.onTap,
    this.onLongPress,
  });

  final double height;
  final Color backgroundColor;
  final Color foregroundColor;
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: height,
      width: double.infinity,
      child: Material(
        color: onTap == null ? backgroundColor.withAlpha(130) : backgroundColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: cs.outlineVariant.withAlpha(90), width: 0.6),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Center(
            child: IconTheme(
              data: IconThemeData(color: foregroundColor),
              child: DefaultTextStyle.merge(
                style: TextStyle(color: foregroundColor),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
