import 'dart:io' show Process;

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
typedef OpenExternalUrlHandler = Future<void> Function(String url);

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
    OpenExternalUrlHandler? onOpenExternalUrl,
  }) : _channel = channel,
       _isWebOverride = isWebOverride,
       _onPickBytes = onPickBytes,
       _onSaveBytes = onSaveBytes,
       _onShareBytes = onShareBytes,
       _onOpenExternalUrl = onOpenExternalUrl;

  final MethodChannel? _channel;
  final bool? _isWebOverride;
  final PickBytesHandler? _onPickBytes;
  final SaveBytesHandler? _onSaveBytes;
  final ShareBytesHandler? _onShareBytes;
  final OpenExternalUrlHandler? _onOpenExternalUrl;

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
    return const Capability(CapabilityState.available, '系统文件保存对话框已接入');
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
      final normalizedExts = allowedExtensions == null
          ? const <String>[]
          : allowedExtensions
                .map((e) => e.trim().replaceFirst(RegExp(r'^\.+'), ''))
                .where((e) => e.isNotEmpty)
                .toList(growable: false);
      final groups = _usesNativeFileChannel || normalizedExts.isEmpty
          ? const <XTypeGroup>[]
          : <XTypeGroup>[
              XTypeGroup(
                label: _typeGroupLabelForExtensions(normalizedExts),
                extensions: normalizedExts,
              ),
            ];
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
      final ext = _extractExtension(suggestedName);
      final saveGroups = ext.isEmpty
          ? const <XTypeGroup>[]
          : <XTypeGroup>[
              XTypeGroup(
                label: _typeGroupLabelForExtensions(<String>[ext]),
                extensions: <String>[ext],
              ),
            ];
      final location = await getSaveLocation(
        suggestedName: suggestedName,
        acceptedTypeGroups: saveGroups,
      );
      if (location == null) throw const Failure(FailureCode.cancelled, '已取消保存');
      var savePath = location.path;
      if (ext.isNotEmpty && !savePath.toLowerCase().endsWith('.$ext')) {
        savePath = '$savePath.$ext';
      }
      await XFile.fromData(
        bytes,
        name: suggestedName,
        mimeType: mimeType ?? _guessMimeType(suggestedName),
      ).saveTo(savePath);
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

  Future<void> openExternalUrl(String rawUrl) async {
    final trimmed = rawUrl.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.host.isEmpty) {
      throw const Failure(FailureCode.validation, '仅支持打开 HTTP/HTTPS 网页链接');
    }
    final normalizedUrl = uri.toString();

    if (_onOpenExternalUrl != null) {
      await _onOpenExternalUrl(normalizedUrl);
      return;
    }

    if (_isWeb) {
      throw const Failure(
        FailureCode.unsupportedCapability,
        '当前环境不支持直接打开外部浏览器',
      );
    }

    if (_usesNativeFileChannel) {
      try {
        await _effectiveChannel.invokeMethod<void>('openExternalUrl', {
          'url': normalizedUrl,
        });
        return;
      } on PlatformException catch (e) {
        final message = e.message;
        throw Failure(
          FailureCode.unsupportedCapability,
          message != null && message.isNotEmpty ? message : '无法调起系统浏览器',
        );
      } on MissingPluginException {
        throw Failure(
          FailureCode.unsupportedCapability,
          _isIOSNative ? '当前环境未挂载 iOS 原生浏览器通道' : '当前环境未挂载 Android 原生浏览器通道',
        );
      } catch (_) {
        throw const Failure(FailureCode.unsupportedCapability, '无法调起系统浏览器');
      }
    }

    if (!_isWeb && defaultTargetPlatform == TargetPlatform.macOS) {
      try {
        await _effectiveChannel.invokeMethod<void>('openExternalUrl', {
          'url': normalizedUrl,
        });
        return;
      } on PlatformException catch (e) {
        final message = e.message;
        throw Failure(
          FailureCode.unsupportedCapability,
          message != null && message.isNotEmpty ? message : '无法调起系统浏览器',
        );
      } on MissingPluginException {
        // Fall through to `/usr/bin/open` when native runner channel is absent.
      } catch (_) {
        throw const Failure(FailureCode.unsupportedCapability, '无法调起系统浏览器');
      }
    }

    try {
      final result = switch (defaultTargetPlatform) {
        TargetPlatform.linux => await Process.run('xdg-open', [normalizedUrl]),
        TargetPlatform.macOS => await Process.run('/usr/bin/open', [
          normalizedUrl,
        ]),
        TargetPlatform.windows => await Process.run('powershell', [
          '-NoProfile',
          '-NonInteractive',
          '-WindowStyle',
          'Hidden',
          '-Command',
          "Start-Process -FilePath '${normalizedUrl.replaceAll("'", "''")}'",
        ]),
        _ => throw const Failure(
          FailureCode.unsupportedCapability,
          '当前环境不支持直接打开外部浏览器',
        ),
      };
      if (result.exitCode != 0) {
        throw const Failure(FailureCode.unsupportedCapability, '无法调起系统浏览器');
      }
    } on Failure {
      rethrow;
    } catch (_) {
      throw const Failure(FailureCode.unsupportedCapability, '无法调起系统浏览器');
    }
  }

  static String _extractExtension(String fileName) {
    final trimmed = fileName.trim();
    final dot = trimmed.lastIndexOf('.');
    if (dot <= 0 || dot >= trimmed.length - 1) return '';
    final ext = trimmed.substring(dot + 1).toLowerCase();
    return RegExp(r'^[a-z0-9]+$').hasMatch(ext) ? ext : '';
  }

  static String _typeGroupLabelForExtensions(List<String> extensions) {
    if (extensions.length == 1) {
      return switch (extensions.first.toLowerCase()) {
        'csv' => 'CSV 表格文件 (*.csv)',
        'zip' => '帐屿备份压缩包 (*.zip)',
        'png' => 'PNG 图片 (*.png)',
        'jpg' || 'jpeg' => 'JPEG 图片 (*.jpg)',
        'json' => 'JSON 数据文件 (*.json)',
        'yi2a' => '一羽记账备份文件 (*.yi2a)',
        'penny' => '一羽记账备份文件 (*.penny)',
        'db' => 'SQLite 数据库文件 (*.db)',
        final other => '${other.toUpperCase()} 文件 (*.$other)',
      };
    }
    final joined = extensions.map((e) => '*.${e.toLowerCase()}').join(', ');
    return '支持的文件 ($joined)';
  }

  static String _guessMimeType(String fileName) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.csv')) return 'text/csv';
    if (lower.endsWith('.json') ||
        lower.endsWith('.yi2a') ||
        lower.endsWith('.ya2i')) {
      return 'application/json';
    }
    if (lower.endsWith('.zip')) return 'application/zip';
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    return 'application/octet-stream';
  }
}
