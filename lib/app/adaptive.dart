import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Desktop window width breakpoint where bottom navigation switches to a
/// compact `76px` left navigation rail.
const double kDesktopMediumBreakpoint = 720.0;

/// Desktop window width breakpoint where the left rail expands to the `208px`
/// full sidebar and main workspaces unlock Master-Detail two-column layouts.
const double kDesktopExpandedBreakpoint = 1080.0;

/// Three-tier responsive window width classification used on desktop platforms.
enum DesktopWindowSizeClass {
  /// `< 720px`: Narrow utility window; smoothly falls back to 5-slot bottom bar.
  compact,

  /// `720px .. 1079px`: Medium window; uses compact `76px` icon rail.
  medium,

  /// `>= 1080px` (includes default `1280×800`): Expanded widescreen desktop.
  expanded,
}

/// Pure classifier mapping logical viewport [width] to [DesktopWindowSizeClass].
DesktopWindowSizeClass classifyDesktopWindowWidth(double width) {
  if (width >= kDesktopExpandedBreakpoint) {
    return DesktopWindowSizeClass.expanded;
  }
  if (width >= kDesktopMediumBreakpoint) {
    return DesktopWindowSizeClass.medium;
  }
  return DesktopWindowSizeClass.compact;
}

/// Returns `true` when [platform] is a desktop operating system
/// (`Windows`, `Linux`, or `macOS`).
///
/// Mobile and non-desktop targets (`Android`, `iOS`, `HarmonyOS` / `ohos`,
/// `Fuchsia`) resolve to `false`. Uses a wildcard arm so this switch compiles
/// cleanly on both `CPF-Flutter` (which adds `TargetPlatform.ohos`) and
/// upstream official Flutter.
bool isDesktopTargetPlatform(TargetPlatform platform) {
  return switch (platform) {
    TargetPlatform.linux ||
    TargetPlatform.windows ||
    TargetPlatform.macOS => true,
    _ => false,
  };
}

/// Returns `true` when [platform] is HarmonyOS (`TargetPlatform.ohos`), using
/// `.name` comparison for bidirectional upstream Flutter compatibility.
bool isOhosTargetPlatform(TargetPlatform platform) => platform.name == 'ohos';

/// Returns `true` when [platform] supports native Android `AppWidget` home
/// screen widgets (`F-034`).
bool isAndroidAppWidgetSupportedPlatform(TargetPlatform platform) =>
    platform == TargetPlatform.android;

/// Returns `true` when [platform] supports native mobile home-screen widgets:
/// Android `AppWidget` or HarmonyOS Form Kit service cards (`F-034`).
bool isMobileHomeWidgetSupportedPlatform(TargetPlatform platform) =>
    platform == TargetPlatform.android || isOhosTargetPlatform(platform);

/// Returns `true` when [platform] ships a built-in offline OCR engine
/// (Android ML Kit Chinese / iOS Vision / HarmonyOS CoreVisionKit).
bool isNativeOfflineOcrSupportedPlatform(TargetPlatform platform) =>
    platform == TargetPlatform.android ||
    platform == TargetPlatform.iOS ||
    isOhosTargetPlatform(platform);

/// Returns `true` when [platform] supports Android `AccessibilityService`
/// payment notification/window capture (`F-020`).
bool isAndroidAccessibilitySupportedPlatform(TargetPlatform platform) =>
    platform == TargetPlatform.android;

/// Optional test override for desktop mode (`null` defers to [TargetPlatform]).
final desktopModeOverrideProvider = Provider<bool?>((ref) => null);

/// Inherited scope injected at the root of `TallyIsleApp` so any descendant
/// page, dialog, or popup can query desktop mode without requiring a `WidgetRef`.
class DesktopAdaptiveScope extends InheritedWidget {
  const DesktopAdaptiveScope({
    super.key,
    required this.isDesktop,
    required super.child,
  });

  final bool isDesktop;

  static DesktopAdaptiveScope? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<DesktopAdaptiveScope>();
  }

  @override
  bool updateShouldNotify(DesktopAdaptiveScope oldWidget) =>
      isDesktop != oldWidget.isDesktop;
}

/// Unified dual-axis adaptive query helper (`Platform` × `Viewport Width`).
///
/// Mobile (`Android` / `iOS` / `HarmonyOS`) always resolves [isDesktop] to
/// `false`, guaranteeing zero visual or behavioral changes on phones and tablets.
abstract final class DesktopAdaptive {
  /// Whether desktop UI & keyboard-first ergonomics are active.
  static bool isDesktop(BuildContext context) {
    final scoped = DesktopAdaptiveScope.maybeOf(context);
    if (scoped != null) {
      return scoped.isDesktop;
    }
    return isDesktopTargetPlatform(Theme.of(context).platform);
  }

  /// Whether the active platform is HarmonyOS (`TargetPlatform.ohos`).
  static bool isOhos(BuildContext context) =>
      isOhosTargetPlatform(Theme.of(context).platform);

  /// Whether native Android `AppWidget` home-screen widgets are supported in
  /// the current UI context (`false` on desktop, HarmonyOS, and iOS).
  static bool supportsAndroidAppWidgets(BuildContext context) =>
      !isDesktop(context) &&
      isAndroidAppWidgetSupportedPlatform(Theme.of(context).platform);

  /// Whether native mobile home-screen widgets (Android AppWidget / HarmonyOS
  /// service cards) are supported (`false` on desktop and iOS).
  static bool supportsMobileHomeWidgets(BuildContext context) =>
      !isDesktop(context) &&
      isMobileHomeWidgetSupportedPlatform(Theme.of(context).platform);

  /// Whether the active platform uses macOS modifier conventions (`⌘` / `⌥`).
  static bool isMacOS(BuildContext context) =>
      Theme.of(context).platform == TargetPlatform.macOS;

  /// Human-readable primary shortcut modifier label (`⌘` on macOS, `Ctrl` elsewhere).
  static String primaryModifierLabel(BuildContext context) =>
      isMacOS(context) ? '⌘' : 'Ctrl';

  /// Human-readable secondary shortcut modifier label (`⌥` on macOS, `Alt` elsewhere).
  static String altModifierLabel(BuildContext context) =>
      isMacOS(context) ? '⌥' : 'Alt';

  /// Current [DesktopWindowSizeClass] based on `MediaQuery.sizeOf(context).width`.
  static DesktopWindowSizeClass sizeClassOf(BuildContext context) =>
      classifyDesktopWindowWidth(MediaQuery.sizeOf(context).width);

  /// Returns `true` when running on desktop and viewport width `>= 720px`.
  static bool useSideNavigation(BuildContext context) =>
      isDesktop(context) &&
      sizeClassOf(context) != DesktopWindowSizeClass.compact;

  /// Returns `true` when running on desktop and viewport width `>= 1080px`.
  static bool isExpandedDesktop(BuildContext context) =>
      isDesktop(context) &&
      sizeClassOf(context) == DesktopWindowSizeClass.expanded;
}
