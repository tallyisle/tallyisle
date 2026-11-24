import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/adaptive.dart';

Widget _buildDesktopModalDialogShell({
  required BuildContext dialogContext,
  required Widget child,
  required double maxWidth,
  required double maxHeight,
}) {
  return Focus(
    autofocus: true,
    onKeyEvent: (_, event) {
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.escape &&
          (ModalRoute.of(dialogContext)?.isCurrent ?? true)) {
        Navigator.of(dialogContext).maybePop();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        key: const Key('desktop-modal-dialog-surface'),
        constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
        child: child,
      ),
    ),
  );
}

/// Centered modal [Page] used on desktop viewports (`maxWidth: 560`,
/// `maxHeight: 700`, `20px` rounded corners, `barrierDismissible: false`) so
/// compact create/edit forms open in-place over the active workspace while
/// transparently forwarding `Navigator.pop(result)` return values.
class DesktopModalDialogPage<T> extends Page<T> {
  const DesktopModalDialogPage({
    required this.child,
    this.maxWidth = 560,
    this.maxHeight = 700,
    this.barrierDismissible = false,
    this.barrierColor = Colors.black54,
    this.barrierLabel,
    super.key,
    super.name,
    super.arguments,
    super.restorationId,
  });

  final Widget child;
  final double maxWidth;
  final double maxHeight;
  final bool barrierDismissible;
  final Color? barrierColor;
  final String? barrierLabel;

  @override
  Route<T> createRoute(BuildContext context) {
    return DialogRoute<T>(
      context: context,
      settings: this,
      barrierDismissible: barrierDismissible,
      barrierColor: barrierColor,
      barrierLabel:
          barrierLabel ??
          MaterialLocalizations.of(context).modalBarrierDismissLabel,
      builder: (dialogContext) => _buildDesktopModalDialogShell(
        dialogContext: dialogContext,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
        child: child,
      ),
    );
  }
}

/// Pushes a centered `560×700` modal [DialogRoute] on the root navigator when
/// running on desktop platforms, or a standard [MaterialPageRoute] on mobile.
Future<T?> pushDesktopModalOrMaterialRoute<T>(
  BuildContext context, {
  required Widget child,
  double maxWidth = 560,
  double maxHeight = 700,
  bool barrierDismissible = false,
}) {
  if (DesktopAdaptive.isDesktop(context)) {
    final nav = Navigator.of(context, rootNavigator: true);
    final navContext = nav.context;
    return nav.push<T>(
      DialogRoute<T>(
        context: navContext,
        barrierDismissible: barrierDismissible,
        barrierColor: Colors.black54,
        barrierLabel: MaterialLocalizations.of(
          navContext,
        ).modalBarrierDismissLabel,
        builder: (dialogContext) => _buildDesktopModalDialogShell(
          dialogContext: dialogContext,
          maxWidth: maxWidth,
          maxHeight: maxHeight,
          child: child,
        ),
      ),
    );
  }
  return Navigator.of(
    context,
  ).push<T>(MaterialPageRoute<T>(builder: (_) => child));
}

/// Returns a [DesktopModalDialogPage] on desktop platforms and a standard
/// full-screen [MaterialPage] on mobile platforms.
Page<T> buildDesktopModalOrMaterialPage<T>({
  required BuildContext context,
  required LocalKey key,
  String? name,
  Object? arguments,
  String? restorationId,
  required Widget child,
  double maxWidth = 560,
  double maxHeight = 700,
}) {
  if (DesktopAdaptive.isDesktop(context)) {
    return DesktopModalDialogPage<T>(
      key: key,
      name: name,
      arguments: arguments,
      restorationId: restorationId,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      child: child,
    );
  }
  return MaterialPage<T>(
    key: key,
    name: name,
    arguments: arguments,
    restorationId: restorationId,
    child: child,
  );
}

/// Handles physical `Escape` key dismissal on desktop editor forms when the
/// enclosing route is topmost (yielding cleanly to child pickers or dialogs).
class DesktopModalEscapeScope extends StatelessWidget {
  const DesktopModalEscapeScope({
    super.key,
    required this.enabled,
    required this.child,
  });

  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return Focus(
      canRequestFocus: false,
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape &&
            (ModalRoute.of(context)?.isCurrent ?? true)) {
          Navigator.of(context).maybePop();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: child,
    );
  }
}
