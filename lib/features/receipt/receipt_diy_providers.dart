import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/failure.dart';
import '../../domain/rules/receipt_diy_rules.dart';
import '../../platform/files.dart';
import '../attachments/attachment_providers.dart'
    show billAttachmentServiceProvider;

export '../../domain/rules/receipt_diy_rules.dart';

typedef ReceiptPngCapturer = Future<Uint8List> Function(GlobalKey boundaryKey);

Future<Uint8List> defaultCaptureRepaintBoundaryPng(
  GlobalKey boundaryKey,
) async {
  final ctx = boundaryKey.currentContext;
  final renderObject = ctx?.findRenderObject();
  if (renderObject is! RenderRepaintBoundary) {
    throw const Failure(FailureCode.storageUnavailable, '小票画布尚未就绪，请稍后重试');
  }
  final ui.Image image = await renderObject.toImage(pixelRatio: 2.0);
  try {
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null || byteData.lengthInBytes == 0) {
      throw const Failure(FailureCode.storageUnavailable, '生成小票 PNG 图片失败');
    }
    return byteData.buffer.asUint8List(
      byteData.offsetInBytes,
      byteData.lengthInBytes,
    );
  } finally {
    image.dispose();
  }
}

final receiptFileAccessProvider = Provider<FileAccess>(
  (ref) => const FileAccess(),
);

final receiptPngCapturerProvider = Provider<ReceiptPngCapturer>(
  (ref) => defaultCaptureRepaintBoundaryPng,
);

final diyToolbarConfigProvider = StreamProvider<DiyToolbarConfig>((ref) async* {
  final service = await ref.watch(billAttachmentServiceProvider.future);
  yield* service.watchDiyToolbarConfig();
});
