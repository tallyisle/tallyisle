import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/adaptive.dart';
import '../../domain/ledger/asset_json.dart' show endOfMonthDay;
import 'tally_button.dart';
import 'tally_card.dart';

/// Borderless/ring 12dp [OutlineInputBorder] subclass whose [isOutline] is
/// `false`, so Flutter's [InputDecorator] places floating `labelText` cleanly
/// inside the 12dp tonal fill box (matching [TallySelectField]) while painting
/// a complete 12dp rounded-rectangle focus/error ring with no bottom underline
/// and no top cutout gap.
class TallyFilledInputBorder extends OutlineInputBorder {
  const TallyFilledInputBorder({
    super.borderSide = BorderSide.none,
    super.borderRadius = const BorderRadius.all(
      Radius.circular(kTallyNestedRadius),
    ),
    super.gapPadding = 0.0,
  });

  @override
  bool get isOutline => false;

  @override
  TallyFilledInputBorder copyWith({
    BorderSide? borderSide,
    BorderRadius? borderRadius,
    double? gapPadding,
  }) => TallyFilledInputBorder(
    borderSide: borderSide ?? this.borderSide,
    borderRadius: borderRadius ?? this.borderRadius,
    gapPadding: gapPadding ?? this.gapPadding,
  );

  @override
  TallyFilledInputBorder scale(double t) => TallyFilledInputBorder(
    borderSide: borderSide.scale(t),
    borderRadius: borderRadius * t,
    gapPadding: gapPadding * t,
  );

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) {
    if (a is OutlineInputBorder) {
      return TallyFilledInputBorder(
        borderRadius: BorderRadius.lerp(a.borderRadius, borderRadius, t)!,
        borderSide: BorderSide.lerp(a.borderSide, borderSide, t),
        gapPadding: a.gapPadding + (gapPadding - a.gapPadding) * t,
      );
    }
    return super.lerpFrom(a, t);
  }

  @override
  ShapeBorder? lerpTo(ShapeBorder? b, double t) {
    if (b is OutlineInputBorder) {
      return TallyFilledInputBorder(
        borderRadius: BorderRadius.lerp(borderRadius, b.borderRadius, t)!,
        borderSide: BorderSide.lerp(borderSide, b.borderSide, t),
        gapPadding: gapPadding + (b.gapPadding - gapPadding) * t,
      );
    }
    return super.lerpTo(b, t);
  }

  @override
  void paint(
    Canvas canvas,
    Rect rect, {
    double? gapStart,
    double gapExtent = 0.0,
    double gapPercentage = 0.0,
    TextDirection? textDirection,
  }) {
    if (borderSide.style == BorderStyle.none || borderSide.width <= 0.0) {
      return;
    }
    final paint = borderSide.toPaint();
    final outer = borderRadius.resolve(textDirection).toRRect(rect);
    final center = outer.inflate(borderSide.strokeOffset / 2);
    canvas.drawRRect(center, paint);
  }
}

/// Global borderless 12dp tonal [InputDecorationTheme] for [TextField] and
/// [TextFormField] inputs across mobile and desktop.
InputDecorationTheme tallyInputDecorationTheme(
  ColorScheme s, {
  required bool isDesktop,
}) {
  const borderless = TallyFilledInputBorder();
  final focused = TallyFilledInputBorder(
    borderSide: BorderSide(
      color: s.primary.withValues(alpha: 0.65),
      width: 1.2,
    ),
  );
  final error = TallyFilledInputBorder(
    borderSide: BorderSide(color: s.error, width: 1.2),
  );
  return InputDecorationTheme(
    filled: true,
    fillColor: tallyNestedSurfaceColor(s),
    border: borderless,
    enabledBorder: borderless,
    disabledBorder: borderless,
    focusedBorder: focused,
    errorBorder: error,
    focusedErrorBorder: error,
    contentPadding: EdgeInsets.symmetric(
      horizontal: 14,
      vertical: isDesktop ? 8 : 7,
    ),
  );
}

/// Global borderless 10dp tonal [ChipThemeData] for [Chip], [ChoiceChip],
/// [FilterChip], [ActionChip], and [InputChip].
ChipThemeData tallyChipTheme(ColorScheme s, {required bool isDesktop}) =>
    ChipThemeData(
      side: BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      showCheckmark: false,
      checkmarkColor: s.onPrimaryContainer,
      backgroundColor: tallyNestedSurfaceColor(s),
      selectedColor: tallySoftButtonFillColor(s),
      secondarySelectedColor: tallySoftButtonFillColor(s),
      disabledColor: s.onSurface.withValues(alpha: 0.06),
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      selectedShadowColor: Colors.transparent,
      elevation: 0,
      pressElevation: 0,
      padding: EdgeInsets.symmetric(
        horizontal: isDesktop ? 10 : 8,
        vertical: isDesktop ? 4 : 2,
      ),
    );

/// Global borderless 12dp tonal [SegmentedButtonThemeData] with soft primary
/// tint for the active segment and nested surface fill for inactive segments.
SegmentedButtonThemeData tallySegmentedButtonTheme(
  ColorScheme s, {
  required bool isDesktop,
}) => SegmentedButtonThemeData(
  style: ButtonStyle(
    side: const WidgetStatePropertyAll<BorderSide>(BorderSide.none),
    shape: WidgetStatePropertyAll<OutlinedBorder>(
      RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kTallyNestedRadius),
      ),
    ),
    elevation: const WidgetStatePropertyAll<double>(0),
    surfaceTintColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
    shadowColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
    backgroundColor: WidgetStateProperty.resolveWith<Color>((states) {
      if (states.contains(WidgetState.disabled)) {
        return s.onSurface.withValues(alpha: 0.05);
      }
      if (states.contains(WidgetState.selected)) {
        return tallySoftButtonFillColor(s);
      }
      return tallyNestedSurfaceColor(s);
    }),
    foregroundColor: WidgetStateProperty.resolveWith<Color>((states) {
      if (states.contains(WidgetState.disabled)) {
        return s.onSurface.withValues(alpha: 0.38);
      }
      if (states.contains(WidgetState.selected)) {
        return s.onPrimaryContainer;
      }
      return s.onSurfaceVariant;
    }),
    iconColor: WidgetStateProperty.resolveWith<Color>((states) {
      if (states.contains(WidgetState.disabled)) {
        return s.onSurface.withValues(alpha: 0.38);
      }
      if (states.contains(WidgetState.selected)) {
        return s.brightness == Brightness.dark
            ? s.onPrimaryContainer
            : s.primary;
      }
      return s.onSurfaceVariant;
    }),
    visualDensity: isDesktop ? VisualDensity.standard : VisualDensity.compact,
    minimumSize: WidgetStatePropertyAll<Size>(Size(0, isDesktop ? 38 : 36)),
    padding: WidgetStatePropertyAll<EdgeInsetsGeometry>(
      EdgeInsets.symmetric(horizontal: 10, vertical: isDesktop ? 6 : 0),
    ),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  ),
);

/// Declarative option item for [TallySelectField] and
/// [showTallySelectSheetOrDialog].
class TallySelectOption<T> {
  const TallySelectOption({
    required this.value,
    required this.label,
    this.subtitle,
    this.leading,
    this.searchKeywords,
    this.enabled = true,
    this.optionKey,
  });

  final T value;
  final String label;
  final String? subtitle;
  final Widget? leading;
  final String? searchKeywords;
  final bool enabled;
  final Key? optionKey;
}

/// Borderless 12dp tonal selector field replacing Material [DropdownButton] /
/// [DropdownButtonFormField]. Opens a centered [Dialog] on desktop and a
/// modal bottom sheet on mobile.
class TallySelectField<T> extends StatelessWidget {
  const TallySelectField({
    super.key,
    this.label,
    this.value,
    this.options = const [],
    this.onChanged,
    this.hintText,
    this.helperText,
    this.errorText,
    this.leading,
    this.displayText,
    this.onCustomTap,
    this.enabled = true,
    this.searchable = false,
    this.sheetTitle,
    this.isDense = false,
  });

  final String? label;
  final T? value;
  final List<TallySelectOption<T>> options;
  final ValueChanged<T>? onChanged;
  final String? hintText;
  final String? helperText;
  final String? errorText;
  final Widget? leading;
  final String? displayText;
  final VoidCallback? onCustomTap;
  final bool enabled;
  final bool searchable;
  final String? sheetTitle;
  final bool isDense;

  TallySelectOption<T>? _findSelectedOption() {
    for (final opt in options) {
      if (opt.value == value) return opt;
    }
    return null;
  }

  Future<void> _handleTap(BuildContext context) async {
    FocusManager.instance.primaryFocus?.unfocus();
    if (onCustomTap != null) {
      onCustomTap!();
      return;
    }
    if (onChanged == null || options.isEmpty) return;
    final picked = await showTallySelectSheetOrDialog<T>(
      context,
      title: sheetTitle ?? label ?? hintText ?? '请选择',
      options: options,
      currentValue: value,
      searchable: searchable,
    );
    if (picked != null && context.mounted) {
      onChanged!(picked.value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDesktop = DesktopAdaptive.isDesktop(context);
    final selectedOption = _findSelectedOption();
    final hasCustomText = displayText != null && displayText!.isNotEmpty;
    final hasValueText = hasCustomText || selectedOption != null;
    final resolvedText = hasCustomText
        ? displayText!
        : (selectedOption?.label ?? hintText ?? '');
    final isPlaceholder = !hasValueText;
    final hasLabel = label != null && label!.trim().isNotEmpty;
    final hasError = errorText != null && errorText!.trim().isNotEmpty;
    final hasHelper =
        !hasError && helperText != null && helperText!.trim().isNotEmpty;
    final interactive = enabled && (onChanged != null || onCustomTap != null);
    final effectiveLeading = leading ?? selectedOption?.leading;

    final densityDy = theme.visualDensity.baseSizeAdjustment.dy;
    final minHeight = hasLabel
        ? (isDense
              ? (isDesktop ? 42.0 : 40.0)
              : math.max(44.0, (isDesktop ? 56.0 : 54.0) + densityDy))
        : (isDense
              ? (isDesktop ? 38.0 : 36.0)
              : math.max(36.0, (isDesktop ? 40.0 : 38.0) + densityDy));

    final fillColor = enabled
        ? tallyNestedSurfaceColor(scheme)
        : scheme.onSurface.withValues(alpha: 0.05);

    final labelColor = !enabled
        ? scheme.onSurface.withValues(alpha: 0.38)
        : (hasError ? scheme.error : scheme.onSurfaceVariant);

    final valueColor = !enabled
        ? scheme.onSurface.withValues(alpha: 0.38)
        : (isPlaceholder ? scheme.onSurfaceVariant : scheme.onSurface);

    final chevronColor = !enabled
        ? scheme.onSurface.withValues(alpha: 0.38)
        : scheme.onSurfaceVariant;

    const hPad = 12.0;
    final vPad = hasLabel
        ? (isDense
              ? 4.0
              : math.max(4.0, (isDesktop ? 8.0 : 7.0) + densityDy / 2.0))
        : (isDense
              ? 6.0
              : math.max(5.0, (isDesktop ? 8.0 : 7.0) + densityDy / 2.0));

    final fieldBox = Material(
      color: fillColor,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kTallyNestedRadius),
        side: hasError
            ? BorderSide(color: scheme.error, width: 1.2)
            : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: BorderRadius.circular(kTallyNestedRadius),
        onTap: interactive ? () => _handleTap(context) : null,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: minHeight),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: hPad, vertical: vPad),
            child: Row(
              children: [
                if (effectiveLeading != null) ...[
                  ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: 40,
                      maxHeight: 40,
                    ),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: effectiveLeading,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (hasLabel) ...[
                        Text(
                          label!,
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            height: 1.15,
                            color: labelColor,
                          ),
                        ),
                        const SizedBox(height: 2),
                      ],
                      Text(
                        resolvedText,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style:
                            (isDense
                                    ? theme.textTheme.bodyMedium
                                    : theme.textTheme.bodyLarge)
                                ?.copyWith(height: 1.25, color: valueColor),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 20,
                  color: chevronColor,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (!hasError && !hasHelper) {
      return fieldBox;
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        fieldBox,
        Padding(
          padding: const EdgeInsets.only(left: 14, right: 14, top: 6),
          child: Text(
            hasError ? errorText! : helperText!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: hasError ? scheme.error : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

/// Shows an adaptive option picker: centered 18dp [Dialog] on desktop and a
/// 20dp modal bottom sheet with `AnimationStyle.noAnimation` on mobile.
///
/// Returns `({T value})` when an option is selected, or `null` when dismissed,
/// so nullable option values (`TallySelectField<int?>`) round-trip cleanly.
Future<({T value})?> showTallySelectSheetOrDialog<T>(
  BuildContext context, {
  required String title,
  required List<TallySelectOption<T>> options,
  T? currentValue,
  bool searchable = false,
  String searchHint = '搜索选项…',
}) {
  final isDesktop = DesktopAdaptive.isDesktop(context);
  if (isDesktop) {
    return showDialog<({T value})>(
      context: context,
      builder: (dialogContext) {
        final scheme = Theme.of(dialogContext).colorScheme;
        return Dialog(
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          backgroundColor: scheme.surfaceContainerHigh,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 24,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440, maxHeight: 540),
            child: _TallySelectContent<T>(
              title: title,
              options: options,
              currentValue: currentValue,
              searchable: searchable,
              searchHint: searchHint,
              showCloseButton: true,
            ),
          ),
        );
      },
    );
  }

  final screenHeight = MediaQuery.sizeOf(context).height;
  return showModalBottomSheet<({T value})>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    sheetAnimationStyle: AnimationStyle.noAnimation,
    elevation: 0,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    constraints: BoxConstraints(maxHeight: screenHeight * 0.72),
    builder: (sheetContext) {
      final viewInsetsBottom = MediaQuery.viewInsetsOf(sheetContext).bottom;
      final safeBottom = MediaQuery.paddingOf(sheetContext).bottom;
      return Padding(
        padding: EdgeInsets.only(
          bottom: math.max(viewInsetsBottom, safeBottom),
        ),
        child: _TallySelectContent<T>(
          title: title,
          options: options,
          currentValue: currentValue,
          searchable: searchable,
          searchHint: searchHint,
          showCloseButton: false,
        ),
      );
    },
  );
}

class _TallySelectContent<T> extends StatefulWidget {
  const _TallySelectContent({
    required this.title,
    required this.options,
    required this.currentValue,
    required this.searchable,
    required this.searchHint,
    required this.showCloseButton,
  });

  final String title;
  final List<TallySelectOption<T>> options;
  final T? currentValue;
  final bool searchable;
  final String searchHint;
  final bool showCloseButton;

  @override
  State<_TallySelectContent<T>> createState() => _TallySelectContentState<T>();
}

class _TallySelectContentState<T> extends State<_TallySelectContent<T>> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  bool get _showSearch => widget.searchable || widget.options.length > 15;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<TallySelectOption<T>> _filteredOptions() {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return widget.options;
    return widget.options
        .where((opt) {
          if (opt.label.toLowerCase().contains(q)) return true;
          if (opt.subtitle != null && opt.subtitle!.toLowerCase().contains(q)) {
            return true;
          }
          if (opt.searchKeywords != null &&
              opt.searchKeywords!.toLowerCase().contains(q)) {
            return true;
          }
          return false;
        })
        .toList(growable: false);
  }

  Widget _buildOptionTile(
    BuildContext context,
    TallySelectOption<T> opt,
    ColorScheme scheme,
    ThemeData theme,
  ) {
    final isSelected = opt.value == widget.currentValue;
    final enabled = opt.enabled;
    final bgColor = isSelected
        ? tallySoftButtonFillColor(scheme)
        : Colors.transparent;
    final fgColor = !enabled
        ? scheme.onSurface.withValues(alpha: 0.38)
        : (isSelected ? scheme.onPrimaryContainer : scheme.onSurface);
    final subColor = !enabled
        ? scheme.onSurface.withValues(alpha: 0.30)
        : (isSelected
              ? scheme.onPrimaryContainer.withValues(alpha: 0.78)
              : scheme.onSurfaceVariant);

    return Material(
      color: bgColor,
      borderRadius: BorderRadius.circular(kTallyNestedRadius),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: opt.optionKey,
        borderRadius: BorderRadius.circular(kTallyNestedRadius),
        onTap: enabled
            ? () => Navigator.of(context).pop((value: opt.value))
            : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          child: Row(
            children: [
              if (opt.leading != null) ...[
                Opacity(opacity: enabled ? 1.0 : 0.45, child: opt.leading),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      opt.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: fgColor,
                        fontWeight: isSelected
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                    if (opt.subtitle != null && opt.subtitle!.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        opt.subtitle!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: subColor,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (isSelected) ...[
                const SizedBox(width: 8),
                Icon(
                  Icons.check_rounded,
                  size: 20,
                  color: scheme.brightness == Brightness.dark
                      ? scheme.onPrimaryContainer
                      : scheme.primary,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final filtered = _filteredOptions();
    final borderlessInput = OutlineInputBorder(
      borderRadius: BorderRadius.circular(kTallyNestedRadius),
      borderSide: BorderSide.none,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            18,
            widget.showCloseButton ? 12 : 0,
            widget.showCloseButton ? 10 : 18,
            8,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (widget.showCloseButton) const CloseButton(),
            ],
          ),
        ),
        if (_showSearch)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              key: const Key('tally-select-search-input'),
              controller: _searchController,
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                hintText: widget.searchHint,
                filled: true,
                fillColor: tallyNestedSurfaceColor(scheme),
                border: borderlessInput,
                enabledBorder: borderlessInput,
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(kTallyNestedRadius),
                  borderSide: BorderSide(
                    color: scheme.primary.withValues(alpha: 0.65),
                    width: 1.2,
                  ),
                ),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.clear_rounded, size: 18),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _query = '');
                        },
                      ),
              ),
            ),
          ),
        if (filtered.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: Center(
              child: Text(
                '无匹配选项',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          )
        else if (filtered.length <= 35)
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < filtered.length; i++) ...[
                    if (i > 0) const SizedBox(height: 4),
                    _buildOptionTile(context, filtered[i], scheme, theme),
                  ],
                ],
              ),
            ),
          )
        else
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
              itemCount: filtered.length,
              separatorBuilder: (_, _) => const SizedBox(height: 4),
              itemBuilder: (context, index) =>
                  _buildOptionTile(context, filtered[index], scheme, theme),
            ),
          ),
      ],
    );
  }
}

/// Shows a 7-column calendar-day grid (`1..28`) plus a full-width bottom
/// `'月底（每月最后一天）'` option returning [endOfMonthDay].
///
/// Uses a centered 18dp [Dialog] on desktop and a modal bottom sheet with
/// `AnimationStyle.noAnimation` on mobile.
Future<int?> showCreditDayPickerSheetOrDialog(
  BuildContext context, {
  required String title,
  required int currentDay,
}) {
  final isDesktop = DesktopAdaptive.isDesktop(context);
  if (isDesktop) {
    return showDialog<int>(
      context: context,
      builder: (dialogContext) {
        final scheme = Theme.of(dialogContext).colorScheme;
        return Dialog(
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          backgroundColor: scheme.surfaceContainerHigh,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 24,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: _CreditDayPickerContent(
              title: title,
              currentDay: currentDay,
              showCloseButton: true,
            ),
          ),
        );
      },
    );
  }

  final screenHeight = MediaQuery.sizeOf(context).height;
  return showModalBottomSheet<int>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    sheetAnimationStyle: AnimationStyle.noAnimation,
    elevation: 0,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    constraints: BoxConstraints(
      maxHeight: math.max(360.0, screenHeight * 0.78),
    ),
    builder: (sheetContext) {
      final safeBottom = MediaQuery.paddingOf(sheetContext).bottom;
      return Padding(
        padding: EdgeInsets.only(bottom: safeBottom),
        child: _CreditDayPickerContent(
          title: title,
          currentDay: currentDay,
          showCloseButton: false,
        ),
      );
    },
  );
}

class _CreditDayPickerContent extends StatelessWidget {
  const _CreditDayPickerContent({
    required this.title,
    required this.currentDay,
    required this.showCloseButton,
  });

  final String title;
  final int currentDay;
  final bool showCloseButton;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isEndSelected = currentDay == endOfMonthDay;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            18,
            showCloseButton ? 12 : 0,
            showCloseButton ? 10 : 18,
            10,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (showCloseButton) const CloseButton(),
            ],
          ),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var row = 0; row < 4; row++) ...[
                  if (row > 0) const SizedBox(height: 6),
                  Row(
                    children: [
                      for (var col = 0; col < 7; col++) ...[
                        if (col > 0) const SizedBox(width: 6),
                        Expanded(
                          child: _buildDayCell(
                            context,
                            day: row * 7 + col + 1,
                            scheme: scheme,
                            theme: theme,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
                const SizedBox(height: 10),
                Material(
                  color: isEndSelected
                      ? tallySoftButtonFillColor(scheme)
                      : tallyNestedSurfaceColor(scheme),
                  borderRadius: BorderRadius.circular(kTallyNestedRadius),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    key: const Key('credit-day-option-end'),
                    borderRadius: BorderRadius.circular(kTallyNestedRadius),
                    onTap: () => Navigator.of(context).pop(endOfMonthDay),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Flexible(
                            child: Text(
                              '月底（每月最后一天）',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: isEndSelected
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                                color: isEndSelected
                                    ? scheme.onPrimaryContainer
                                    : scheme.onSurface,
                              ),
                            ),
                          ),
                          if (isEndSelected) ...[
                            const SizedBox(width: 8),
                            Icon(
                              Icons.check_rounded,
                              size: 18,
                              color: scheme.brightness == Brightness.dark
                                  ? scheme.onPrimaryContainer
                                  : scheme.primary,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDayCell(
    BuildContext context, {
    required int day,
    required ColorScheme scheme,
    required ThemeData theme,
  }) {
    final isSelected = currentDay == day;
    return Semantics(
      label: '每月 $day 日',
      button: true,
      selected: isSelected,
      excludeSemantics: true,
      child: Material(
        color: isSelected
            ? tallySoftButtonFillColor(scheme)
            : tallyNestedSurfaceColor(scheme),
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: Key('credit-day-option-$day'),
          borderRadius: BorderRadius.circular(10),
          onTap: () => Navigator.of(context).pop(day),
          child: SizedBox(
            height: 42,
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Text(
                    '$day日',
                    maxLines: 1,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: isSelected
                          ? FontWeight.w600
                          : FontWeight.w500,
                      color: isSelected
                          ? scheme.onPrimaryContainer
                          : scheme.onSurface,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Borderless 16dp tonal [Card] (`tallyCardColor(context)`) with optional
/// section [title] / [subtitle] header for grouping editor fields without
/// horizontal dividers.
class TallyFormCard extends StatelessWidget {
  const TallyFormCard({
    super.key,
    this.title,
    this.subtitle,
    this.trailing,
    required this.children,
    this.padding = const EdgeInsets.all(16),
    this.margin = EdgeInsets.zero,
    this.spacing = 0,
  });

  final String? title;
  final String? subtitle;
  final Widget? trailing;
  final List<Widget> children;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasTitle = title != null && title!.trim().isNotEmpty;
    final hasSubtitle = subtitle != null && subtitle!.trim().isNotEmpty;
    final hasHeader = hasTitle || hasSubtitle || trailing != null;

    return Card(
      margin: margin,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      color: tallyCardColor(context),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kTallyCardRadius),
      ),
      child: Padding(
        padding: padding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (hasHeader) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (hasTitle)
                          Text(
                            title!,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        if (hasSubtitle) ...[
                          if (hasTitle) const SizedBox(height: 2),
                          Text(
                            subtitle!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (trailing != null) ...[
                    const SizedBox(width: 8),
                    trailing!,
                  ],
                ],
              ),
              if (children.isNotEmpty) const SizedBox(height: 12),
            ],
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0 && spacing > 0) SizedBox(height: spacing),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}

/// Borderless 12dp nested tonal (`tallyNestedSurfaceColor`) [Material] +
/// [InkWell] row for date/time/visual pickers inside [TallyFormCard].
class TallyFormTile extends StatelessWidget {
  const TallyFormTile({
    super.key,
    this.tileKey,
    this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.enabled = true,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
  });

  final Key? tileKey;
  final Widget? leading;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool enabled;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fillColor = enabled
        ? tallyNestedSurfaceColor(scheme)
        : scheme.onSurface.withValues(alpha: 0.05);
    final titleColor = enabled
        ? scheme.onSurface
        : scheme.onSurface.withValues(alpha: 0.38);
    final subtitleColor = enabled
        ? scheme.onSurfaceVariant
        : scheme.onSurface.withValues(alpha: 0.30);
    final effectiveTrailing =
        trailing ??
        (onTap != null
            ? Icon(Icons.chevron_right_rounded, size: 20, color: subtitleColor)
            : null);

    return Material(
      color: fillColor,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      borderRadius: BorderRadius.circular(kTallyNestedRadius),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: tileKey,
        borderRadius: BorderRadius.circular(kTallyNestedRadius),
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: padding,
          child: Row(
            children: [
              if (leading != null) ...[
                Opacity(opacity: enabled ? 1.0 : 0.45, child: leading),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                        color: titleColor,
                      ),
                    ),
                    if (subtitle != null && subtitle!.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: subtitleColor,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (effectiveTrailing != null) ...[
                const SizedBox(width: 8),
                effectiveTrailing,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
