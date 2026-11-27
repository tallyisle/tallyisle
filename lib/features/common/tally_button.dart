import 'package:flutter/material.dart';

import '../../app/adaptive.dart';
import 'tally_card.dart';

/// Soft tonal fill color used by secondary / functional action buttons.
Color tallySoftButtonFillColor(ColorScheme s) => s.brightness == Brightness.dark
    ? Color.lerp(s.surfaceContainerHigh, s.primaryContainer, 0.42)!
    : Color.lerp(s.surfaceContainerLowest, s.primaryContainer, 0.55)!;

/// Borderless 12dp rounded-rectangle style for soft tonal action buttons.
ButtonStyle tallySoftButtonStyle(
  ColorScheme s, {
  bool compact = false,
  bool isDesktop = false,
  EdgeInsetsGeometry? padding,
  Size? minimumSize,
}) => FilledButton.styleFrom(
  elevation: 0,
  shadowColor: Colors.transparent,
  surfaceTintColor: Colors.transparent,
  backgroundColor: tallySoftButtonFillColor(s),
  foregroundColor: s.onPrimaryContainer,
  iconColor: s.brightness == Brightness.dark ? s.onPrimaryContainer : s.primary,
  disabledBackgroundColor: s.onSurface.withValues(alpha: 0.06),
  disabledForegroundColor: s.onSurface.withValues(alpha: 0.38),
  disabledIconColor: s.onSurface.withValues(alpha: 0.38),
  minimumSize: minimumSize ?? Size(0, compact ? 34 : (isDesktop ? 40 : 42)),
  padding:
      padding ??
      EdgeInsets.symmetric(
        horizontal: compact ? 10 : 14,
        vertical: compact ? 6 : 10,
      ),
  tapTargetSize: compact ? MaterialTapTargetSize.shrinkWrap : null,
  visualDensity: compact ? VisualDensity.compact : VisualDensity.standard,
  textStyle: const TextStyle(fontWeight: FontWeight.w600),
  shape: RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(kTallyNestedRadius),
  ),
);

/// Global primary solid [FilledButtonThemeData] for form submit and dialog
/// confirmation actions (keeps M3 primary fill, unifies 12dp corner radius).
FilledButtonThemeData tallyPrimaryButtonTheme(
  ColorScheme s, {
  required bool isDesktop,
}) => FilledButtonThemeData(
  style: FilledButton.styleFrom(
    elevation: 0,
    shadowColor: Colors.transparent,
    surfaceTintColor: Colors.transparent,
    minimumSize: Size(0, isDesktop ? 40 : 42),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    visualDensity: VisualDensity.standard,
    textStyle: const TextStyle(fontWeight: FontWeight.w600),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(kTallyNestedRadius),
    ),
  ),
);

/// Global fallback [OutlinedButtonThemeData] mapping remaining outlined buttons
/// to borderless 12dp soft primary-tinted blocks.
OutlinedButtonThemeData tallySoftOutlinedButtonTheme(
  ColorScheme s, {
  required bool isDesktop,
}) => OutlinedButtonThemeData(
  style: OutlinedButton.styleFrom(
    elevation: 0,
    shadowColor: Colors.transparent,
    surfaceTintColor: Colors.transparent,
    side: BorderSide.none,
    backgroundColor: tallySoftButtonFillColor(s),
    foregroundColor: s.onPrimaryContainer,
    iconColor: s.brightness == Brightness.dark
        ? s.onPrimaryContainer
        : s.primary,
    disabledBackgroundColor: s.onSurface.withValues(alpha: 0.06),
    disabledForegroundColor: s.onSurface.withValues(alpha: 0.38),
    disabledIconColor: s.onSurface.withValues(alpha: 0.38),
    minimumSize: Size(0, isDesktop ? 40 : 42),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    visualDensity: VisualDensity.standard,
    textStyle: const TextStyle(fontWeight: FontWeight.w600),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(kTallyNestedRadius),
    ),
  ),
);

/// Global [TextButtonThemeData] aligned to the 12dp rounded-rectangle radius
/// and matching `40dp` (desktop) / `42dp` (mobile) height with [TallySoftButton].
TextButtonThemeData tallyTextButtonTheme(
  ColorScheme s, {
  bool isDesktop = false,
}) => TextButtonThemeData(
  style: TextButton.styleFrom(
    minimumSize: Size(0, isDesktop ? 40 : 42),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    visualDensity: VisualDensity.standard,
    textStyle: const TextStyle(fontWeight: FontWeight.w600),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(kTallyNestedRadius),
    ),
  ),
);

/// Global [FloatingActionButtonThemeData] aligned to the 16dp card radius.
FloatingActionButtonThemeData tallyFabTheme(ColorScheme s) =>
    FloatingActionButtonThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kTallyCardRadius),
      ),
    );

/// Borderless 12dp soft tonal action button that directly subclasses
/// [FilledButton] so `widget is FilledButton` remains `true`.
class TallySoftButton extends FilledButton {
  const TallySoftButton({
    super.key,
    required super.onPressed,
    super.onLongPress,
    super.style,
    super.focusNode,
    super.autofocus = false,
    super.clipBehavior,
    this.compact = false,
    this.padding,
    this.minimumSize,
    required Widget super.child,
  });

  TallySoftButton.icon({
    super.key,
    required super.onPressed,
    super.onLongPress,
    super.style,
    super.focusNode,
    super.autofocus = false,
    super.clipBehavior,
    this.compact = false,
    this.padding,
    this.minimumSize,
    required Widget icon,
    required Widget label,
  }) : super(
         child: _TallySoftButtonWithIconChild(icon: icon, label: label),
       );

  final bool compact;
  final EdgeInsetsGeometry? padding;
  final Size? minimumSize;

  @override
  ButtonStyle defaultStyleOf(BuildContext context) {
    final base = super.defaultStyleOf(context);
    final theme = Theme.of(context);
    return tallySoftButtonStyle(
          theme.colorScheme,
          compact: compact,
          isDesktop: DesktopAdaptive.isDesktop(context),
          padding: padding,
          minimumSize: minimumSize,
        )
        .copyWith(
          mouseCursor: base.mouseCursor,
          textStyle: WidgetStatePropertyAll<TextStyle?>(
            theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600) ??
                const TextStyle(fontWeight: FontWeight.w600),
          ),
        )
        .merge(base);
  }

  @override
  ButtonStyle? themeStyleOf(BuildContext context) => null;
}

class _TallySoftButtonWithIconChild extends StatelessWidget {
  const _TallySoftButtonWithIconChild({
    required this.icon,
    required this.label,
  });

  final Widget icon;
  final Widget label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      icon,
      const SizedBox(width: 8),
      Flexible(child: label),
    ],
  );
}
