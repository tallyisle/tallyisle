import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, FileSystemException, Process;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

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

/// Platform persistence mode for user-authorized external backup directories.
enum ExternalBackupDirMode {
  path,
  androidSafTree,
  appleBookmark,
  ohosDownload;

  static ExternalBackupDirMode? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    for (final mode in ExternalBackupDirMode.values) {
      if (mode.name == raw) return mode;
    }
    return null;
  }
}

/// Persistent binding metadata for an external `.tally` backup directory
/// surviving app uninstall/reinstall across all 6 target platforms.
@immutable
final class ExternalBackupDirBinding {
  const ExternalBackupDirBinding({
    required this.mode,
    required this.locator,
    required this.displayPath,
    required this.boundAtMs,
  });

  final ExternalBackupDirMode mode;
  final String locator;
  final String displayPath;
  final int boundAtMs;

  Map<String, Object?> toJson() => <String, Object?>{
    'mode': mode.name,
    'locator': locator,
    'displayPath': displayPath,
    'boundAtMs': boundAtMs,
  };

  String encode() => jsonEncode(toJson());

  factory ExternalBackupDirBinding.fromJson(Map<String, Object?> json) {
    final mode = ExternalBackupDirMode.tryParse(json['mode'] as String?);
    final locator = (json['locator'] as String?)?.trim() ?? '';
    if (mode == null || locator.isEmpty) {
      throw const Failure(FailureCode.corruptData, '外部备份目录绑定记录格式无效');
    }
    final rawDisplay = (json['displayPath'] as String?)?.trim() ?? '';
    final rawBoundAt = json['boundAtMs'];
    final boundAtMs = switch (rawBoundAt) {
      final int v => v,
      final String s => int.tryParse(s) ?? 0,
      _ => 0,
    };
    return ExternalBackupDirBinding(
      mode: mode,
      locator: locator,
      displayPath: rawDisplay.isEmpty ? locator : rawDisplay,
      boundAtMs: boundAtMs,
    );
  }

  static ExternalBackupDirBinding? tryDecode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        return ExternalBackupDirBinding.fromJson(decoded);
      }
    } catch (_) {}
    return null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ExternalBackupDirBinding &&
          other.mode == mode &&
          other.locator == locator &&
          other.displayPath == displayPath &&
          other.boundAtMs == boundAtMs;

  @override
  int get hashCode => Object.hash(mode, locator, displayPath, boundAtMs);
}

/// Lightweight directory listing entry returned by [FileAccess.listExternalDirectoryFiles].
@immutable
final class ExternalBackupFileEntry {
  const ExternalBackupFileEntry({
    required this.fileName,
    required this.sizeBytes,
    required this.modifiedAtMs,
  });

  final String fileName;
  final int sizeBytes;
  final int modifiedAtMs;

  static ExternalBackupFileEntry? tryFromChannelMap(Map<Object?, Object?> map) {
    final rawName = map['fileName'];
    if (rawName is! String || rawName.trim().isEmpty) return null;
    final rawSize = map['sizeBytes'];
    final sizeBytes = switch (rawSize) {
      final int v when v >= 0 => v,
      final double d when d >= 0 => d.floor(),
      final String s => int.tryParse(s) ?? 0,
      _ => 0,
    };
    final rawModified = map['modifiedAtMs'];
    final modifiedAtMs = switch (rawModified) {
      final int v when v >= 0 => v,
      final double d when d >= 0 => d.floor(),
      final String s => int.tryParse(s) ?? 0,
      _ => 0,
    };
    return ExternalBackupFileEntry(
      fileName: rawName.trim(),
      sizeBytes: sizeBytes,
      modifiedAtMs: modifiedAtMs,
    );
  }
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
typedef PickBackupDirectoryHandler =
    Future<ExternalBackupDirBinding> Function(String? initialDirectory);
typedef CheckDirectoryAccessibleHandler =
    Future<bool> Function(ExternalBackupDirBinding binding);
typedef ListDirectoryFilesHandler =
    Future<List<ExternalBackupFileEntry>> Function(
      ExternalBackupDirBinding binding,
    );
typedef WriteDirectoryFileHandler =
    Future<void> Function(
      ExternalBackupDirBinding binding,
      String fileName,
      Uint8List bytes,
    );
typedef ReadDirectoryFileHandler =
    Future<Uint8List> Function(
      ExternalBackupDirBinding binding,
      String fileName,
    );
typedef DeleteDirectoryFileHandler =
    Future<void> Function(ExternalBackupDirBinding binding, String fileName);
typedef OpenBackupDirectoryHandler =
    Future<void> Function(ExternalBackupDirBinding binding);

/// OS chooser & system share boundary (ADR-008).
///
/// Null/cancel never turns into a successful write.
class FileAccess {
  const FileAccess({
    MethodChannel? channel,
    bool? isWebOverride,
    bool? isOhosOverride,
    PickBytesHandler? onPickBytes,
    SaveBytesHandler? onSaveBytes,
    ShareBytesHandler? onShareBytes,
    OpenExternalUrlHandler? onOpenExternalUrl,
    PickBackupDirectoryHandler? onPickBackupDirectory,
    CheckDirectoryAccessibleHandler? onCheckDirectoryAccessible,
    ListDirectoryFilesHandler? onListDirectoryFiles,
    WriteDirectoryFileHandler? onWriteDirectoryFile,
    ReadDirectoryFileHandler? onReadDirectoryFile,
    DeleteDirectoryFileHandler? onDeleteDirectoryFile,
    OpenBackupDirectoryHandler? onOpenBackupDirectory,
  }) : _channel = channel,
       _isWebOverride = isWebOverride,
       _isOhosOverride = isOhosOverride,
       _onPickBytes = onPickBytes,
       _onSaveBytes = onSaveBytes,
       _onShareBytes = onShareBytes,
       _onOpenExternalUrl = onOpenExternalUrl,
       _onPickBackupDirectory = onPickBackupDirectory,
       _onCheckDirectoryAccessible = onCheckDirectoryAccessible,
       _onListDirectoryFiles = onListDirectoryFiles,
       _onWriteDirectoryFile = onWriteDirectoryFile,
       _onReadDirectoryFile = onReadDirectoryFile,
       _onDeleteDirectoryFile = onDeleteDirectoryFile,
       _onOpenBackupDirectory = onOpenBackupDirectory;

  final MethodChannel? _channel;
  final bool? _isWebOverride;
  final bool? _isOhosOverride;
  final PickBytesHandler? _onPickBytes;
  final SaveBytesHandler? _onSaveBytes;
  final ShareBytesHandler? _onShareBytes;
  final OpenExternalUrlHandler? _onOpenExternalUrl;
  final PickBackupDirectoryHandler? _onPickBackupDirectory;
  final CheckDirectoryAccessibleHandler? _onCheckDirectoryAccessible;
  final ListDirectoryFilesHandler? _onListDirectoryFiles;
  final WriteDirectoryFileHandler? _onWriteDirectoryFile;
  final ReadDirectoryFileHandler? _onReadDirectoryFile;
  final DeleteDirectoryFileHandler? _onDeleteDirectoryFile;
  final OpenBackupDirectoryHandler? _onOpenBackupDirectory;

  bool get hasCustomDirectoryCheckHandler =>
      _onCheckDirectoryAccessible != null;
  bool get hasCustomDirectoryWriteHandler => _onWriteDirectoryFile != null;
  bool get hasCustomDirectoryReadHandler => _onReadDirectoryFile != null;

  MethodChannel get _effectiveChannel =>
      _channel ?? const MethodChannel(fileBridgeChannelName);

  bool get _isWeb => _isWebOverride ?? kIsWeb;

  bool get _isAndroidNative =>
      !_isWeb && defaultTargetPlatform == TargetPlatform.android;

  bool get _isIOSNative =>
      !_isWeb && defaultTargetPlatform == TargetPlatform.iOS;

  bool get _isWindowsNative =>
      !_isWeb && defaultTargetPlatform == TargetPlatform.windows;

  bool get _isLinuxNative =>
      !_isWeb && defaultTargetPlatform == TargetPlatform.linux;

  bool get _isMacOSNative =>
      !_isWeb && defaultTargetPlatform == TargetPlatform.macOS;

  bool get _isOhosNative =>
      !_isWeb && (_isOhosOverride ?? (defaultTargetPlatform.name == 'ohos'));

  bool get _usesNativeFileChannel =>
      _isAndroidNative || _isIOSNative || _isOhosNative;

  bool get _usesNativeBackupDirChannel =>
      _isAndroidNative || _isIOSNative || _isMacOSNative || _isOhosNative;

  static Future<T> _runRootIo<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    Zone.root.run(() async {
      try {
        completer.complete(await action());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

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
        'iOS 系统文件保存（UIDocumentPickerViewController 存储到“文件”）已接入',
      );
    }
    if (_isOhosNative) {
      return const Capability(
        CapabilityState.available,
        'HarmonyOS 系统文件保存（DocumentViewPicker）已接入',
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
    if (_isOhosNative) {
      return const Capability(
        CapabilityState.available,
        'HarmonyOS 系统文件分享（ShareKit）已接入',
      );
    }
    return const Capability(
      CapabilityState.unsupported,
      '当前平台不支持直接系统分享，请使用另存为文件',
    );
  }

  Capability get externalBackupDirCapability {
    if (_onPickBackupDirectory != null) {
      return const Capability(CapabilityState.available, '自定义备份目录选择器已接入');
    }
    if (_isWeb) {
      return const Capability(
        CapabilityState.unsupported,
        '当前 Web 环境暂不支持绑定外部备份目录',
      );
    }
    if (_isAndroidNative) {
      return const Capability(
        CapabilityState.available,
        'Android SAF 持久目录授权（ACTION_OPEN_DOCUMENT_TREE）已接入',
      );
    }
    if (_isIOSNative) {
      return const Capability(
        CapabilityState.available,
        'iOS“文件”目录安全书签（Security-Scoped Bookmark）已接入',
      );
    }
    if (_isOhosNative) {
      return const Capability(
        CapabilityState.available,
        'HarmonyOS 公共下载应用专属目录（DOWNLOAD 模式）已接入',
      );
    }
    if (_isMacOSNative) {
      return const Capability(
        CapabilityState.available,
        'macOS 沙盒持久目录安全书签（NSOpenPanel + Bookmark）已接入',
      );
    }
    if (_isWindowsNative || _isLinuxNative) {
      return const Capability(CapabilityState.available, '桌面系统文件夹选择器已接入');
    }
    return const Capability(CapabilityState.unsupported, '当前平台暂不支持绑定外部备份目录');
  }

  Capability get openDirectoryCapability {
    if (_onOpenBackupDirectory != null) {
      return const Capability(CapabilityState.available, '自定义打开目录处理器已接入');
    }
    if (_isWindowsNative || _isLinuxNative || _isMacOSNative) {
      return const Capability(CapabilityState.available, '桌面系统文件管理器已接入');
    }
    return const Capability(CapabilityState.unsupported, '当前平台不支持直接打开系统文件夹窗口');
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
          _isOhosNative
              ? '当前环境未挂载 HarmonyOS 原生文件保存通道'
              : (_isIOSNative
                    ? '当前环境未挂载 iOS 原生文件保存通道'
                    : '当前环境未挂载 Android 原生文件保存通道'),
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
        _isOhosNative
            ? '当前环境未挂载 HarmonyOS 原生系统分享通道'
            : (_isIOSNative
                  ? '当前环境未挂载 iOS 原生系统分享通道'
                  : '当前环境未挂载 Android 原生系统分享通道'),
      );
    } catch (_) {
      throw const Failure(FailureCode.storageUnavailable, '无法调起系统分享');
    }
  }

  Future<ExternalBackupDirBinding> pickExternalBackupDirectory({
    String? initialDirectory,
    int? nowMs,
  }) async {
    if (_onPickBackupDirectory != null) {
      return _onPickBackupDirectory(initialDirectory);
    }
    if (externalBackupDirCapability.state != CapabilityState.available) {
      throw Failure(
        FailureCode.unsupportedCapability,
        externalBackupDirCapability.reason,
      );
    }

    final timestampMs = nowMs ?? DateTime.now().millisecondsSinceEpoch;

    if (_usesNativeBackupDirChannel) {
      try {
        final raw = await _effectiveChannel.invokeMethod<Map<Object?, Object?>>(
          'pickBackupDirectory',
          {'initialDirectory': initialDirectory},
        );
        if (raw == null) {
          throw const Failure(FailureCode.cancelled, '已取消选择备份目录');
        }
        final locator = (raw['locator'] as String?)?.trim() ?? '';
        if (locator.isEmpty) {
          throw const Failure(FailureCode.storageUnavailable, '未能获取有效的备份目录路径');
        }
        final defaultMode = _isAndroidNative
            ? ExternalBackupDirMode.androidSafTree
            : (_isOhosNative
                  ? ExternalBackupDirMode.ohosDownload
                  : ExternalBackupDirMode.appleBookmark);
        final mode =
            ExternalBackupDirMode.tryParse(raw['mode'] as String?) ??
            defaultMode;
        final displayPath = (raw['displayPath'] as String?)?.trim() ?? '';
        return ExternalBackupDirBinding(
          mode: mode,
          locator: locator,
          displayPath: displayPath.isEmpty ? locator : displayPath,
          boundAtMs: timestampMs,
        );
      } on Failure {
        rethrow;
      } on PlatformException catch (e) {
        if (e.code == 'CANCELLED') {
          throw const Failure(FailureCode.cancelled, '已取消选择备份目录');
        }
        throw Failure(
          FailureCode.storageUnavailable,
          e.message ?? '无法绑定所选外部备份目录',
        );
      } on MissingPluginException {
        throw Failure(
          FailureCode.unsupportedCapability,
          _isOhosNative
              ? '当前环境未挂载 HarmonyOS 原生备份目录通道'
              : (_isIOSNative
                    ? '当前环境未挂载 iOS 原生备份目录通道'
                    : (_isMacOSNative
                          ? '当前环境未挂载 macOS 原生备份目录通道'
                          : '当前环境未挂载 Android 原生备份目录通道')),
        );
      } catch (_) {
        throw const Failure(FailureCode.storageUnavailable, '无法绑定所选外部备份目录');
      }
    }

    // Windows / Linux desktop directory chooser via file_selector.
    try {
      final selectedPath = await getDirectoryPath(
        initialDirectory: initialDirectory,
        confirmButtonText: '选择此备份文件夹',
      );
      if (selectedPath == null || selectedPath.trim().isEmpty) {
        throw const Failure(FailureCode.cancelled, '已取消选择备份目录');
      }
      final trimmed = selectedPath.trim();
      return ExternalBackupDirBinding(
        mode: ExternalBackupDirMode.path,
        locator: trimmed,
        displayPath: trimmed,
        boundAtMs: timestampMs,
      );
    } on Failure {
      rethrow;
    } on MissingPluginException {
      throw const Failure(
        FailureCode.unsupportedCapability,
        '当前环境未挂载桌面目录选择器通道',
      );
    } on UnimplementedError {
      throw const Failure(
        FailureCode.unsupportedCapability,
        '当前环境未实现桌面目录选择器通道',
      );
    } catch (_) {
      throw const Failure(FailureCode.storageUnavailable, '无法打开系统文件夹选择器');
    }
  }

  Future<bool> checkExternalDirectoryAccessible(
    ExternalBackupDirBinding binding,
  ) async {
    if (_onCheckDirectoryAccessible != null) {
      return _onCheckDirectoryAccessible(binding);
    }
    if (_isWeb || binding.locator.trim().isEmpty) {
      return false;
    }
    if (binding.mode == ExternalBackupDirMode.path) {
      return _runRootIo(() async {
        try {
          final dir = Directory(binding.locator);
          if (!await dir.exists()) return false;
          await dir.list(followLinks: false).take(1).drain<void>();
          return true;
        } catch (_) {
          return false;
        }
      });
    }

    try {
      final ok = await _effectiveChannel.invokeMethod<bool>(
        'checkDirectoryAccessible',
        {'mode': binding.mode.name, 'locator': binding.locator},
      );
      return ok == true;
    } catch (_) {
      return false;
    }
  }

  Future<List<ExternalBackupFileEntry>> listExternalDirectoryFiles(
    ExternalBackupDirBinding binding,
  ) async {
    if (_onListDirectoryFiles != null) {
      return _onListDirectoryFiles(binding);
    }
    if (_isWeb) {
      throw const Failure(
        FailureCode.unsupportedCapability,
        '当前 Web 环境不支持访问外部备份目录',
      );
    }
    if (binding.mode == ExternalBackupDirMode.path) {
      return _runRootIo(() async {
        try {
          final dir = Directory(binding.locator);
          if (!await dir.exists()) {
            throw const Failure(
              FailureCode.storageUnavailable,
              '外部备份目录不存在或不可访问',
            );
          }
          final entries = <ExternalBackupFileEntry>[];
          await for (final entity in dir.list(followLinks: false)) {
            if (entity is! File) continue;
            final name = p.basename(entity.path);
            if (name.toLowerCase().endsWith('.tmp')) continue;
            final stat = await entity.stat();
            entries.add(
              ExternalBackupFileEntry(
                fileName: name,
                sizeBytes: stat.size,
                modifiedAtMs: stat.modified.millisecondsSinceEpoch,
              ),
            );
          }
          return entries;
        } on Failure {
          rethrow;
        } catch (_) {
          throw const Failure(FailureCode.storageUnavailable, '无法读取外部备份目录');
        }
      });
    }

    try {
      final rawList = await _effectiveChannel.invokeMethod<List<Object?>>(
        'listDirectoryBackups',
        {'mode': binding.mode.name, 'locator': binding.locator},
      );
      if (rawList == null) return const <ExternalBackupFileEntry>[];
      final items = <ExternalBackupFileEntry>[];
      for (final item in rawList) {
        if (item is Map<Object?, Object?>) {
          final parsed = ExternalBackupFileEntry.tryFromChannelMap(item);
          if (parsed != null &&
              !parsed.fileName.toLowerCase().endsWith('.tmp')) {
            items.add(parsed);
          }
        }
      }
      return items;
    } on PlatformException catch (e) {
      throw Failure(FailureCode.storageUnavailable, e.message ?? '无法读取外部备份目录');
    } on MissingPluginException {
      throw const Failure(FailureCode.unsupportedCapability, '当前环境未挂载原生备份目录通道');
    } catch (_) {
      throw const Failure(FailureCode.storageUnavailable, '无法读取外部备份目录');
    }
  }

  Future<void> writeExternalDirectoryFile(
    ExternalBackupDirBinding binding,
    String fileName,
    Uint8List bytes,
  ) async {
    final cleanName = _validateSafeFileName(fileName);
    if (_onWriteDirectoryFile != null) {
      await _onWriteDirectoryFile(binding, cleanName, bytes);
      return;
    }
    if (_isWeb) {
      throw const Failure(
        FailureCode.unsupportedCapability,
        '当前 Web 环境不支持写入外部备份目录',
      );
    }
    if (binding.mode == ExternalBackupDirMode.path) {
      await _runRootIo(() async {
        final dir = Directory(binding.locator);
        if (!await dir.exists()) {
          throw const Failure(FailureCode.storageUnavailable, '外部备份目录不存在或不可访问');
        }
        final tmpFile = File(p.join(dir.path, '$cleanName.tmp'));
        final finalFile = File(p.join(dir.path, cleanName));
        try {
          await tmpFile.writeAsBytes(bytes, flush: true);
          if (await finalFile.exists()) {
            await finalFile.delete();
          }
          await tmpFile.rename(finalFile.path);
        } catch (_) {
          try {
            if (await tmpFile.exists()) await tmpFile.delete();
          } catch (_) {}
          throw const Failure(FailureCode.storageUnavailable, '写入外部备份文件失败');
        }
      });
      return;
    }

    try {
      await _effectiveChannel.invokeMethod<void>('writeDirectoryBackup', {
        'mode': binding.mode.name,
        'locator': binding.locator,
        'fileName': cleanName,
        'bytes': bytes,
      });
    } on PlatformException catch (e) {
      throw Failure(FailureCode.storageUnavailable, e.message ?? '写入外部备份文件失败');
    } on MissingPluginException {
      throw const Failure(FailureCode.unsupportedCapability, '当前环境未挂载原生备份目录通道');
    } catch (_) {
      throw const Failure(FailureCode.storageUnavailable, '写入外部备份文件失败');
    }
  }

  Future<Uint8List> readExternalDirectoryFile(
    ExternalBackupDirBinding binding,
    String fileName,
  ) async {
    final cleanName = _validateSafeFileName(fileName);
    if (_onReadDirectoryFile != null) {
      return _onReadDirectoryFile(binding, cleanName);
    }
    if (_isWeb) {
      throw const Failure(
        FailureCode.unsupportedCapability,
        '当前 Web 环境不支持读取外部备份目录',
      );
    }
    if (binding.mode == ExternalBackupDirMode.path) {
      return _runRootIo(() async {
        try {
          final file = File(p.join(binding.locator, cleanName));
          if (!await file.exists()) {
            throw const Failure(FailureCode.storageUnavailable, '外部备份文件不存在');
          }
          return await file.readAsBytes();
        } on Failure {
          rethrow;
        } on FileSystemException {
          throw const Failure(FailureCode.storageUnavailable, '无法读取外部备份文件');
        } catch (_) {
          throw const Failure(FailureCode.storageUnavailable, '无法读取外部备份文件');
        }
      });
    }

    try {
      final bytes = await _effectiveChannel
          .invokeMethod<Uint8List>('readDirectoryBackup', {
            'mode': binding.mode.name,
            'locator': binding.locator,
            'fileName': cleanName,
          });
      if (bytes == null) {
        throw const Failure(FailureCode.storageUnavailable, '外部备份文件不存在');
      }
      return bytes;
    } on Failure {
      rethrow;
    } on PlatformException catch (e) {
      throw Failure(FailureCode.storageUnavailable, e.message ?? '无法读取外部备份文件');
    } on MissingPluginException {
      throw const Failure(FailureCode.unsupportedCapability, '当前环境未挂载原生备份目录通道');
    } catch (_) {
      throw const Failure(FailureCode.storageUnavailable, '无法读取外部备份文件');
    }
  }

  Future<void> deleteExternalDirectoryFile(
    ExternalBackupDirBinding binding,
    String fileName,
  ) async {
    final cleanName = _validateSafeFileName(fileName);
    if (_onDeleteDirectoryFile != null) {
      await _onDeleteDirectoryFile(binding, cleanName);
      return;
    }
    if (_isWeb) {
      throw const Failure(
        FailureCode.unsupportedCapability,
        '当前 Web 环境不支持删除外部备份文件',
      );
    }
    if (binding.mode == ExternalBackupDirMode.path) {
      await _runRootIo(() async {
        try {
          final file = File(p.join(binding.locator, cleanName));
          if (await file.exists()) {
            await file.delete();
          }
        } catch (_) {
          throw const Failure(FailureCode.storageUnavailable, '删除外部备份文件失败');
        }
      });
      return;
    }

    try {
      await _effectiveChannel.invokeMethod<void>('deleteDirectoryBackup', {
        'mode': binding.mode.name,
        'locator': binding.locator,
        'fileName': cleanName,
      });
    } on PlatformException catch (e) {
      throw Failure(FailureCode.storageUnavailable, e.message ?? '删除外部备份文件失败');
    } on MissingPluginException {
      throw const Failure(FailureCode.unsupportedCapability, '当前环境未挂载原生备份目录通道');
    } catch (_) {
      throw const Failure(FailureCode.storageUnavailable, '删除外部备份文件失败');
    }
  }

  Future<void> openBackupDirectory(ExternalBackupDirBinding binding) async {
    if (_onOpenBackupDirectory != null) {
      await _onOpenBackupDirectory(binding);
      return;
    }
    if (openDirectoryCapability.state != CapabilityState.available) {
      throw Failure(
        FailureCode.unsupportedCapability,
        openDirectoryCapability.reason,
      );
    }
    if (_isMacOSNative) {
      try {
        await _effectiveChannel.invokeMethod<void>('openBackupDirectory', {
          'mode': binding.mode.name,
          'locator': binding.locator,
          'displayPath': binding.displayPath,
        });
        return;
      } on PlatformException catch (e) {
        throw Failure(
          FailureCode.storageUnavailable,
          e.message ?? '无法在访达中打开备份目录',
        );
      } on MissingPluginException {
        // Fall through to `/usr/bin/open` when native runner channel is absent.
      } catch (_) {
        throw const Failure(FailureCode.storageUnavailable, '无法在访达中打开备份目录');
      }
    }

    final targetPath = binding.mode == ExternalBackupDirMode.path
        ? binding.locator.trim()
        : binding.displayPath.trim();
    if (targetPath.isEmpty) {
      throw const Failure(FailureCode.validation, '备份目录路径为空');
    }

    await _runRootIo(() async {
      if (!await Directory(targetPath).exists()) {
        throw const Failure(FailureCode.storageUnavailable, '外部备份目录不存在或不可访问');
      }
      try {
        if (_isWindowsNative) {
          await Process.run('explorer.exe', <String>[targetPath]);
          return;
        }
        final result = switch (defaultTargetPlatform) {
          TargetPlatform.linux => await Process.run('xdg-open', <String>[
            targetPath,
          ]),
          TargetPlatform.macOS => await Process.run('/usr/bin/open', <String>[
            targetPath,
          ]),
          _ => throw const Failure(
            FailureCode.unsupportedCapability,
            '当前平台不支持直接打开系统文件夹窗口',
          ),
        };
        if (result.exitCode != 0) {
          throw const Failure(FailureCode.unsupportedCapability, '无法调起系统文件管理器');
        }
      } on Failure {
        rethrow;
      } catch (_) {
        throw const Failure(FailureCode.unsupportedCapability, '无法调起系统文件管理器');
      }
    });
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
          _isOhosNative
              ? '当前环境未挂载 HarmonyOS 原生浏览器通道'
              : (_isIOSNative
                    ? '当前环境未挂载 iOS 原生浏览器通道'
                    : '当前环境未挂载 Android 原生浏览器通道'),
        );
      } catch (_) {
        throw const Failure(FailureCode.unsupportedCapability, '无法调起系统浏览器');
      }
    }

    if (_isMacOSNative) {
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

    if (_isWindowsNative) {
      try {
        final launched = await _effectiveChannel.invokeMethod<bool>(
          'openExternalUrl',
          {'url': normalizedUrl},
        );
        if (launched != true) {
          throw const Failure(FailureCode.unsupportedCapability, '无法调起系统浏览器');
        }
        return;
      } on Failure {
        rethrow;
      } on PlatformException catch (e) {
        final message = e.message;
        throw Failure(
          FailureCode.unsupportedCapability,
          message != null && message.isNotEmpty ? message : '无法调起系统浏览器',
        );
      } on MissingPluginException {
        throw const Failure(
          FailureCode.unsupportedCapability,
          '当前环境未挂载 Windows 原生浏览器通道',
        );
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

  static String _validateSafeFileName(String fileName) {
    final trimmed = fileName.trim();
    if (trimmed.isEmpty ||
        trimmed == '.' ||
        trimmed == '..' ||
        trimmed.contains('/') ||
        trimmed.contains(r'\') ||
        trimmed.contains('\x00')) {
      throw Failure(FailureCode.validation, '非法的备份文件名：$fileName');
    }
    return trimmed;
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
        'tally' || 'tallyzip' => '帐屿备份文件 (*.tally)',
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
