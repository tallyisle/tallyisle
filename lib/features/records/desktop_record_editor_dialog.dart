import 'package:flutter/material.dart';

import 'record_editor_page.dart';

/// Default width constraint for the desktop centered record editor modal dialog.
const double kDesktopRecordDialogMaxWidth = 600.0;

/// Default height constraint for the desktop centered record editor modal dialog.
const double kDesktopRecordDialogMaxHeight = 740.0;

/// Inherited marker indicating that a descendant [RecordEditorPage] is hosted
/// inside the desktop centered modal dialog shell.
class DesktopRecordDialogScope extends InheritedWidget {
  const DesktopRecordDialogScope({super.key, required super.child});

  static bool isEmbedded(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DesktopRecordDialogScope>() !=
      null;

  @override
  bool updateShouldNotify(DesktopRecordDialogScope oldWidget) => false;
}

Widget _buildDesktopRecordDialogShell(
  BuildContext dialogContext, {
  required Widget child,
  double maxWidth = kDesktopRecordDialogMaxWidth,
  double maxHeight = kDesktopRecordDialogMaxHeight,
}) {
  final scheme = Theme.of(dialogContext).colorScheme;
  return Dialog(
    key: const Key('desktop-record-editor-dialog'),
    insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
    backgroundColor: scheme.surface,
    surfaceTintColor: Colors.transparent,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(20)),
      side: BorderSide.none,
    ),
    clipBehavior: Clip.antiAlias,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
      child: ScaffoldMessenger(child: DesktopRecordDialogScope(child: child)),
    ),
  );
}

/// Builds an imperative [DialogRoute] hosting [RecordEditorPage] in desktop
/// modal dialog mode (`600×740`, `20px` borderless rounded corners,
/// `barrierDismissible: false`).
DialogRoute<String> createDesktopRecordEditorDialogRoute(
  BuildContext context, {
  String? recordId,
  int? initialType,
  int? initialCategory,
  int? initialTemplateId,
  int? initialAssetId,
  int? initialFrom,
  int? initialTo,
  String? initialAmount,
  String? initialRemark,
  int? initialRecordTimeMs,
}) {
  return DialogRoute<String>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => _buildDesktopRecordDialogShell(
      dialogContext,
      child: RecordEditorPage(
        embeddedInDesktopDialog: true,
        recordId: recordId,
        initialType: initialType,
        initialCategory: initialCategory,
        initialTemplateId: initialTemplateId,
        initialAsset: initialAssetId,
        initialFrom: initialFrom,
        initialTo: initialTo,
        initialAmount: initialAmount,
        initialRemark: initialRemark,
        initialRecordTimeMs: initialRecordTimeMs,
      ),
    ),
  );
}

/// Opens the desktop centered borderless modal dialog (`600px` max width) for
/// creating or editing a ledger record, returning the saved `recordId` or `null`
/// if dismissed.
Future<String?> showDesktopRecordEditorDialog(
  BuildContext context, {
  String? recordId,
  int? initialType,
  int? initialCategory,
  int? initialTemplateId,
  int? initialAssetId,
  int? initialFrom,
  int? initialTo,
  String? initialAmount,
  String? initialRemark,
  int? initialRecordTimeMs,
  bool useRootNavigator = true,
}) {
  final navContext = Navigator.of(
    context,
    rootNavigator: useRootNavigator,
  ).context;
  return Navigator.of(navContext, rootNavigator: useRootNavigator).push<String>(
    createDesktopRecordEditorDialogRoute(
      navContext,
      recordId: recordId,
      initialType: initialType,
      initialCategory: initialCategory,
      initialTemplateId: initialTemplateId,
      initialAssetId: initialAssetId,
      initialFrom: initialFrom,
      initialTo: initialTo,
      initialAmount: initialAmount,
      initialRemark: initialRemark,
      initialRecordTimeMs: initialRecordTimeMs,
    ),
  );
}

/// Declarative [Page] wrapper for `go_router` `pageBuilder` routes
/// (`/record/new`, `/record/:id/edit`) on desktop platforms.
class DesktopRecordDialogPage<T> extends Page<T> {
  const DesktopRecordDialogPage({
    super.key,
    super.name,
    super.arguments,
    super.restorationId,
    this.child,
    this.recordId,
    this.initialType,
    this.initialCategory,
    this.initialTemplateId,
    this.initialAssetId,
    this.initialFrom,
    this.initialTo,
    this.initialAmount,
    this.initialRemark,
    this.initialRecordTimeMs,
    this.maxWidth = kDesktopRecordDialogMaxWidth,
    this.maxHeight = kDesktopRecordDialogMaxHeight,
    this.barrierDismissible = false,
  });

  final Widget? child;
  final String? recordId;
  final int? initialType;
  final int? initialCategory;
  final int? initialTemplateId;
  final int? initialAssetId;
  final int? initialFrom;
  final int? initialTo;
  final String? initialAmount;
  final String? initialRemark;
  final int? initialRecordTimeMs;
  final double maxWidth;
  final double maxHeight;
  final bool barrierDismissible;

  @override
  Route<T> createRoute(BuildContext context) {
    final effectiveChild =
        child ??
        RecordEditorPage(
          embeddedInDesktopDialog: true,
          recordId: recordId,
          initialType: initialType,
          initialCategory: initialCategory,
          initialTemplateId: initialTemplateId,
          initialAsset: initialAssetId,
          initialFrom: initialFrom,
          initialTo: initialTo,
          initialAmount: initialAmount,
          initialRemark: initialRemark,
          initialRecordTimeMs: initialRecordTimeMs,
        );
    return DialogRoute<T>(
      context: context,
      settings: this,
      barrierDismissible: barrierDismissible,
      builder: (dialogContext) => _buildDesktopRecordDialogShell(
        dialogContext,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
        child: effectiveChild,
      ),
    );
  }
}
