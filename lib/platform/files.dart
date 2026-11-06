import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import '../core/failure.dart';

enum CapabilityState {
  available,
  permissionRequired,
  unsupported,
  unconfigured,
  failed,
}

final class Capability {
  const Capability(this.state, this.reason);
  final CapabilityState state;
  final String reason;
}

final class SelectedBytes {
  const SelectedBytes(this.name, this.bytes);
  final String name;
  final Uint8List bytes;
}

/// OS chooser boundary. Null/cancel never turns into a successful write.
final class FileAccess {
  Capability get saveLocationCapability {
    if (kIsWeb ||
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      return const Capability(
        CapabilityState.unsupported,
        '当前适配器没有另存为位置 API；SAF、iOS 导出和 Web 下载待对应任务接入',
      );
    }
    return const Capability(
      CapabilityState.available,
      '桌面保存位置 API 已接入，实际对话框/权限仍需在目标桌面验证',
    );
  }

  Future<SelectedBytes> pickBytes() async {
    try {
      final file = await openFile();
      if (file == null) throw const Failure(FailureCode.cancelled, '已取消选择');
      return SelectedBytes(file.name, await file.readAsBytes());
    } on Failure {
      rethrow;
    } catch (_) {
      throw const Failure(FailureCode.permissionDenied, '无法读取所选文件');
    }
  }

  Future<void> saveBytes(String suggestedName, Uint8List bytes) async {
    if (saveLocationCapability.state != CapabilityState.available) {
      throw Failure(
        FailureCode.unsupportedCapability,
        saveLocationCapability.reason,
      );
    }
    try {
      final location = await getSaveLocation(suggestedName: suggestedName);
      if (location == null) throw const Failure(FailureCode.cancelled, '已取消保存');
      await XFile.fromData(bytes, name: suggestedName).saveTo(location.path);
    } on Failure {
      rethrow;
    } catch (_) {
      throw const Failure(FailureCode.storageUnavailable, '文件未完成保存');
    }
  }
}
