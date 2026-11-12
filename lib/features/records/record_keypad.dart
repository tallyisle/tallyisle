import 'package:flutter/material.dart';

import '../../data/db/database.dart';
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
