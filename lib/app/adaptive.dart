import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Desktop window width breakpoint where bottom navigation switches to a
/// compact `76px` left navigation rail.
const double kDesktopMediumBreakpoint = 720.0;

/// Desktop window width breakpoint where the left rail expands to the `208px`
/// full sidebar and main workspaces unlock Master-Detail two-column layouts.
const double kDesktopExpandedBreakpoint = 1080.0;

/// Logical shortest-side breakpoint above which mobile / foldable screens
/// (`Android`, `iOS` / `iPadOS`, `HarmonyOS`) enter tablet adaptive workspace
/// mode (`shortestSide > 600.0`).
///
/// Using strict `>` keeps standard phone landscape viewports (`<= 600dp` short
/// side, as well as default `800×600` widget test surfaces) in phone mode while
/// unlocking adaptive navigation and Master-Detail workspaces on real tablets
/// and unfolded foldables.
const double kTabletShortestSideBreakpoint = 600.0;

/// Three-tier responsive window width classification used on desktop and tablet
/// adaptive workspaces.
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

/// Returns `true` when [platform] is a non-desktop target (`Android`, `iOS` /
/// `iPadOS`, `HarmonyOS`, etc.) and [viewportSize] has
/// `shortestSide > kTabletShortestSideBreakpoint`.
bool isMobileTabletViewport({
  required TargetPlatform platform,
  required Size viewportSize,
}) =>
    !isDesktopTargetPlatform(platform) &&
    viewportSize.shortestSide > kTabletShortestSideBreakpoint;

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

/// Unified dual-axis adaptive query helper (`Platform Ergonomics` × `Viewport`).
///
/// - [isDesktop] identifies true desktop keyboard/mouse operating systems
///   (`Windows` / `Linux` / `macOS`, or test override), preserving touch
///   `RecordKeypad`, drag-reorder, biometrics, home-screen widgets, offline OCR,
///   and Android Accessibility auto-bill on all mobile/tablet targets.
/// - [isTablet] and [useAdaptiveWorkspace] unlock responsive side navigation,
///   centered modal dialogs, and Master-Detail split panes on large-screen
///   `Android` / `iPadOS` / `HarmonyOS` tablets and unfolded foldables.
abstract final class DesktopAdaptive {
  /// Whether desktop OS & keyboard-first ergonomics are active.
  static bool isDesktop(BuildContext context) {
    final scoped = DesktopAdaptiveScope.maybeOf(context);
    if (scoped != null) {
      return scoped.isDesktop;
    }
    return isDesktopTargetPlatform(Theme.of(context).platform);
  }

  /// Whether the current viewport is a mobile/foldable tablet workspace
  /// (`!isDesktop` and `shortestSide > 600dp`).
  static bool isTablet(BuildContext context) =>
      !isDesktop(context) &&
      MediaQuery.sizeOf(context).shortestSide > kTabletShortestSideBreakpoint;

  /// Whether desktop or tablet adaptive multi-pane workspace shells apply.
  static bool useAdaptiveWorkspace(BuildContext context) =>
      isDesktop(context) || isTablet(context);

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

  /// Returns `true` when running in an adaptive workspace (desktop or tablet)
  /// and viewport width `>= 720px`.
  static bool useSideNavigation(BuildContext context) =>
      useAdaptiveWorkspace(context) &&
      sizeClassOf(context) != DesktopWindowSizeClass.compact;

  /// Returns `true` when running in an adaptive workspace (desktop or tablet)
  /// and viewport width `>= 1080px`.
  static bool isExpandedWorkspace(BuildContext context) =>
      useAdaptiveWorkspace(context) &&
      sizeClassOf(context) == DesktopWindowSizeClass.expanded;

  /// Alias of [isExpandedWorkspace] unlocking widescreen Master-Detail layouts
  /// (`>= 1080px`) on both desktop and landscape tablets.
  static bool isExpandedDesktop(BuildContext context) =>
      isExpandedWorkspace(context);

  /// Returns `true` when compact forms and record editors should open as
  /// centered modal dialogs (always on desktop, and on medium/expanded tablets
  /// `>= 720px`; compact split-screen tablets `< 720px` fall back to full page).
  static bool useCenteredModalDialog(BuildContext context) =>
      isDesktop(context) ||
      (isTablet(context) &&
          sizeClassOf(context) != DesktopWindowSizeClass.compact);
}
