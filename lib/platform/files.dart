import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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

const String fileBridgeChannelName = 'dev.tallyisle/files';

typedef PickBytesHandler =
    Future<SelectedBytes> Function(List<String>? allowedExtensions);
typedef SaveBytesHandler =
    Future<void> Function(
      String suggestedName,
      Uint8List bytes,
      String? mimeType,
    );
typedef ShareBytesHandler =
    Future<void> Function(
      String fileName,
      Uint8List bytes,
      String? mimeType,
      String? subject,
    );

/// OS chooser & system share boundary (ADR-008).
///
/// Null/cancel never turns into a successful write.
class FileAccess {
  const FileAccess({
    MethodChannel? channel,
    bool? isWebOverride,
    PickBytesHandler? onPickBytes,
    SaveBytesHandler? onSaveBytes,
    ShareBytesHandler? onShareBytes,
  }) : _channel = channel,
       _isWebOverride = isWebOverride,
       _onPickBytes = onPickBytes,
       _onSaveBytes = onSaveBytes,
       _onShareBytes = onShareBytes;

  final MethodChannel? _channel;
  final bool? _isWebOverride;
  final PickBytesHandler? _onPickBytes;
  final SaveBytesHandler? _onSaveBytes;
  final ShareBytesHandler? _onShareBytes;

  MethodChannel get _effectiveChannel =>
      _channel ?? const MethodChannel(fileBridgeChannelName);

  bool get _isWeb => _isWebOverride ?? kIsWeb;

  bool get _isAndroidNative =>
      !_isWeb && defaultTargetPlatform == TargetPlatform.android;

  bool get _isIOSNative =>
      !_isWeb && defaultTargetPlatform == TargetPlatform.iOS;

  bool get _usesNativeFileChannel => _isAndroidNative || _isIOSNative;

  Capability get saveLocationCapability {
    if (_onSaveBytes != null) {
      return const Capability(CapabilityState.available, '自定义保存处理器已接入');
    }
    if (_isAndroidNative) {
      return const Capability(
        CapabilityState.available,
        'Android SAF 文件保存（ACTION_CREATE_DOCUMENT）已接入',
      );
    }
    if (_isIOSNative) {
      return const Capability(
        CapabilityState.available,
        'iOS 系统文件导出（UIActivityViewController / 存储到“文件”）已接入',
      );
    }
    if (_isWeb) {
      return const Capability(
        CapabilityState.unsupported,
        '当前 Web 环境暂不支持另存为位置 API',
      );
    }
    return const Capability(
      CapabilityState.available,
      '桌面保存位置 API 已接入，实际对话框/权限仍需在目标桌面验证',
    );
  }

  Capability get shareCapability {
    if (_onShareBytes != null) {
      return const Capability(CapabilityState.available, '自定义分享处理器已接入');
    }
    if (_isAndroidNative) {
      return const Capability(
        CapabilityState.available,
        'Android 系统文件分享（FileProvider + ACTION_SEND）已接入',
      );
    }
    if (_isIOSNative) {
      return const Capability(
        CapabilityState.available,
        'iOS 系统文件分享（UIActivityViewController）已接入',
      );
    }
    return const Capability(
      CapabilityState.unsupported,
      '当前平台不支持直接系统分享，请使用另存为文件',
    );
  }

  Future<SelectedBytes> pickBytes({List<String>? allowedExtensions}) async {
    if (_onPickBytes != null) {
      return _onPickBytes(allowedExtensions);
    }
    try {
      // On Android SAF, file_selector maps extensions via MimeTypeMap, which
      // drops unknown extensions (.penny/.tally/.yi2a/.db) or narrows MIME
      // filters so .db (paired with .zip) and vendor-typed WeChat/Alipay .csv
      // files become unselectable. On iOS, file_selector_ios requires UTIs and
      // throws ArgumentError on extension-only XTypeGroups unless empty groups
      // (`public.data`) are passed. Desktop platforms natively filter by
      // file extensions.
      final groups =
          _usesNativeFileChannel ||
              allowedExtensions == null ||
              allowedExtensions.isEmpty
          ? const <XTypeGroup>[]
          : <XTypeGroup>[XTypeGroup(extensions: allowedExtensions)];
      final file = await openFile(acceptedTypeGroups: groups);
      if (file == null) throw const Failure(FailureCode.cancelled, '已取消选择');
      return SelectedBytes(file.name, await file.readAsBytes());
    } on Failure {
      rethrow;
    } catch (_) {
      throw const Failure(FailureCode.permissionDenied, '无法读取所选文件');
    }
  }

  Future<void> saveBytes(
    String suggestedName,
    Uint8List bytes, {
    String? mimeType,
  }) async {
    if (_onSaveBytes != null) {
      await _onSaveBytes(suggestedName, bytes, mimeType);
      return;
    }
    if (saveLocationCapability.state != CapabilityState.available) {
      throw Failure(
        FailureCode.unsupportedCapability,
        saveLocationCapability.reason,
      );
    }
    if (_usesNativeFileChannel) {
      try {
        await _effectiveChannel.invokeMethod<void>('saveBytes', {
          'suggestedName': suggestedName,
          'bytes': bytes,
          'mimeType': mimeType ?? _guessMimeType(suggestedName),
        });
        return;
      } on PlatformException catch (e) {
        if (e.code == 'CANCELLED') {
          throw const Failure(FailureCode.cancelled, '已取消保存');
        }
        throw Failure(FailureCode.storageUnavailable, e.message ?? '文件未完成保存');
      } on MissingPluginException {
        throw Failure(
          FailureCode.unsupportedCapability,
          _isIOSNative ? '当前环境未挂载 iOS 原生文件保存通道' : '当前环境未挂载 Android 原生文件保存通道',
        );
      } catch (_) {
        throw const Failure(FailureCode.storageUnavailable, '文件未完成保存');
      }
    }

    try {
      final location = await getSaveLocation(suggestedName: suggestedName);
      if (location == null) throw const Failure(FailureCode.cancelled, '已取消保存');
      await XFile.fromData(
        bytes,
        name: suggestedName,
        mimeType: mimeType ?? _guessMimeType(suggestedName),
      ).saveTo(location.path);
    } on Failure {
      rethrow;
    } catch (_) {
      throw const Failure(FailureCode.storageUnavailable, '文件未完成保存');
    }
  }

  Future<void> shareBytes(
    String fileName,
    Uint8List bytes, {
    String? mimeType,
    String? subject,
  }) async {
    if (_onShareBytes != null) {
      await _onShareBytes(fileName, bytes, mimeType, subject);
      return;
    }
    if (shareCapability.state != CapabilityState.available) {
      throw Failure(FailureCode.unsupportedCapability, shareCapability.reason);
    }
    try {
      await _effectiveChannel.invokeMethod<void>('shareBytes', {
        'fileName': fileName,
        'bytes': bytes,
        'mimeType': mimeType ?? _guessMimeType(fileName),
        'subject': subject,
      });
    } on PlatformException catch (e) {
      if (e.code == 'CANCELLED') {
        throw const Failure(FailureCode.cancelled, '已取消分享');
      }
      throw Failure(FailureCode.storageUnavailable, e.message ?? '无法调起系统分享');
    } on MissingPluginException {
      throw Failure(
        FailureCode.unsupportedCapability,
        _isIOSNative ? '当前环境未挂载 iOS 原生系统分享通道' : '当前环境未挂载 Android 原生系统分享通道',
      );
    } catch (_) {
      throw const Failure(FailureCode.storageUnavailable, '无法调起系统分享');
    }
  }

  static String _guessMimeType(String fileName) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.csv')) return 'text/csv';
    if (lower.endsWith('.json') || lower.endsWith('.ya2i')) {
      return 'application/json';
    }
    if (lower.endsWith('.zip')) return 'application/zip';
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    return 'application/octet-stream';
  }
}
