import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../core/failure.dart';
import '../../domain/rules/cloud_sync_rules.dart';
import '../../domain/rules/s3_sigv4_rules.dart';
import '../../domain/rules/tally_backup.dart';
import '../../platform/files.dart';

typedef BackupProgressCallback =
    void Function(int transferredBytes, int totalBytes);

/// Summary metadata for a single `.tally` backup entry (local, WebDAV, or S3, §1.6).
final class BackupFileMetadata {
  const BackupFileMetadata({
    required this.fileName,
    required this.sizeBytes,
    required this.modifiedAtMs,
    this.manifest,
  });

  final String fileName;
  final int sizeBytes;
  final int modifiedAtMs;
  final TallyManifest? manifest;

  BackupRetentionItem toRetentionItem() =>
      BackupRetentionItem(fileName: fileName, modifiedAtMs: modifiedAtMs);
}

/// Pluggable backup storage target boundary (ADR-017: Local File / WebDAV / S3).
abstract interface class BackupTarget {
  String get id;
  String get label;
  Capability get capability;

  Future<List<BackupFileMetadata>> listBackups();

  Future<BackupFileMetadata> writeBackup(
    String fileName,
    Uint8List bytes, {
    BackupProgressCallback? onProgress,
  });

  Future<Uint8List> readBackup(
    String fileName, {
    BackupProgressCallback? onProgress,
  });

  Future<void> deleteBackup(String fileName);
}

/// Metadata returned by a lightweight remote object existence check (`HEAD` / list).
final class CloudSyncObjectHead {
  const CloudSyncObjectHead({this.sizeBytes});

  final int? sizeBytes;
}

/// Unified relative-path object operations used by multi-device snapshot sync
/// across both WebDAV and S3 backends.
abstract interface class CloudSyncObjectStore {
  String get targetFingerprint;

  Future<Uint8List?> getObjectOrNull(
    String relativePath, {
    BackupProgressCallback? onProgress,
  });

  Future<Uint8List> getObject(
    String relativePath, {
    BackupProgressCallback? onProgress,
  });

  Future<void> putObject(
    String relativePath,
    Uint8List bytes, {
    String contentType = 'application/octet-stream',
    BackupProgressCallback? onProgress,
  });

  Future<void> deleteObject(String relativePath);

  Future<Set<String>> listRelativeFileNames(String relativeDir);
}

/// Lightweight existence / metadata check for [CloudSyncObjectStore] without
/// downloading full snapshot payloads.
extension CloudSyncObjectStoreHeadExtension on CloudSyncObjectStore {
  Future<CloudSyncObjectHead?> headObject(String relativePath) async {
    final self = this;
    if (self is WebDavBackupTarget) {
      return self.headObject(relativePath);
    }
    final segments = validateCloudRelativeSegments(relativePath);
    final parentDir = segments.length > 1
        ? segments.sublist(0, segments.length - 1).join('/')
        : '';
    final names = await listRelativeFileNames(parentDir);
    if (!names.contains(segments.last)) {
      return null;
    }
    return const CloudSyncObjectHead();
  }
}

/// User-configured WebDAV endpoint and backup policy settings (§1.1, §1.5, §6.2, §6.3).
final class WebDavConfig {
  const WebDavConfig({
    this.serverUrl = '',
    this.username = '',
    this.password = '',
    this.remoteDirectory = '/TallyIsle',
    this.keepCount = defaultWebDavKeepCount,
    this.autoBackupEnabled = false,
    this.autoBackupIntervalHours = defaultAutoBackupIntervalHours,
    this.includeAttachments = true,
  });

  const WebDavConfig.unconfigured() : this();

  final String serverUrl;
  final String username;
  final String password;
  final String remoteDirectory;
  final int keepCount;
  final bool autoBackupEnabled;
  final int autoBackupIntervalHours;
  final bool includeAttachments;

  bool get isConfigured {
    final trimmedUrl = serverUrl.trim();
    if (trimmedUrl.isEmpty || username.trim().isEmpty || password.isEmpty) {
      return false;
    }
    final uri = Uri.tryParse(trimmedUrl);
    if (uri == null || !uri.hasAuthority || uri.host.isEmpty) {
      return false;
    }
    return uri.scheme == 'http' || uri.scheme == 'https';
  }

  Capability get capability => isConfigured
      ? const Capability(CapabilityState.available, '已配置')
      : const Capability(CapabilityState.unconfigured, '未配置');

  int get autoBackupCooldownMs =>
      (autoBackupIntervalHours <= 0
          ? defaultAutoBackupIntervalHours
          : autoBackupIntervalHours) *
      60 *
      60 *
      1000;

  String get targetFingerprint {
    var cleanUrl = serverUrl.trim().toLowerCase();
    while (cleanUrl.length > 1 && cleanUrl.endsWith('/')) {
      cleanUrl = cleanUrl.substring(0, cleanUrl.length - 1);
    }
    final cleanDirSegments = <String>[
      for (final seg in remoteDirectory.trim().split('/'))
        if (seg.isNotEmpty && seg != '.' && seg != '..') seg,
    ];
    final cleanDir = '/${cleanDirSegments.join('/')}';
    return sha256Hex(
      utf8.encode(
        'webdav|$cleanUrl|$cleanDir|${username.trim().toLowerCase()}',
      ),
    );
  }

  WebDavConfig copyWith({
    String? serverUrl,
    String? username,
    String? password,
    String? remoteDirectory,
    int? keepCount,
    bool? autoBackupEnabled,
    int? autoBackupIntervalHours,
    bool? includeAttachments,
  }) => WebDavConfig(
    serverUrl: serverUrl ?? this.serverUrl,
    username: username ?? this.username,
    password: password ?? this.password,
    remoteDirectory: remoteDirectory ?? this.remoteDirectory,
    keepCount: keepCount ?? this.keepCount,
    autoBackupEnabled: autoBackupEnabled ?? this.autoBackupEnabled,
    autoBackupIntervalHours:
        autoBackupIntervalHours ?? this.autoBackupIntervalHours,
    includeAttachments: includeAttachments ?? this.includeAttachments,
  );

  Map<String, Object> toJson() => <String, Object>{
    'server_url': serverUrl.trim(),
    'username': username.trim(),
    'password': password,
    'remote_directory': remoteDirectory.trim().isEmpty
        ? '/TallyIsle'
        : remoteDirectory.trim(),
    'keep_count': keepCount,
    'auto_backup_enabled': autoBackupEnabled,
    'auto_backup_interval_hours': autoBackupIntervalHours,
    'include_attachments': includeAttachments,
  };

  factory WebDavConfig.fromJson(Map<String, Object?> json) => WebDavConfig(
    serverUrl: (json['server_url'] as String?) ?? '',
    username: (json['username'] as String?) ?? '',
    password: (json['password'] as String?) ?? '',
    remoteDirectory: (json['remote_directory'] as String?) ?? '/TallyIsle',
    keepCount: (json['keep_count'] as int?) ?? defaultWebDavKeepCount,
    autoBackupEnabled: (json['auto_backup_enabled'] as bool?) ?? false,
    autoBackupIntervalHours:
        (json['auto_backup_interval_hours'] as int?) ??
        defaultAutoBackupIntervalHours,
    includeAttachments: (json['include_attachments'] as bool?) ?? true,
  );
}

/// Pure `dart:io` [HttpClient] WebDAV client supporting Basic Auth,
/// `PROPFIND`, recursive `MKCOL`, two-phase `.tmp -> MOVE` atomic upload (with
/// direct in-place `PUT + HEAD Content-Length` fallback when `MOVE` returns
/// `409`/`412`/`405`/`501`/`502`/`400`), `GET`, and `DELETE` (R4, R6, ADR-017).
final class WebDavClient {
  WebDavClient(
    this.config, {
    HttpClient Function()? httpClientFactory,
    this.nowMs,
    this.controlTimeout = const Duration(seconds: 25),
    this.transferTimeout = const Duration(seconds: 90),
    this.staleHeadRetryDelay = const Duration(milliseconds: 80),
  }) : _httpClientFactory = httpClientFactory ?? _defaultHttpClient;

  final WebDavConfig config;
  final HttpClient Function() _httpClientFactory;
  final int Function()? nowMs;
  final Duration controlTimeout;
  final Duration transferTimeout;
  final Duration staleHeadRetryDelay;

  final Set<String> _verifiedCollectionPaths = <String>{};

  static const int _uploadChunkSize = 32 * 1024;
  static const int _smallPayloadVerifyMaxBytes = 256 * 1024;
  static const String _probeFileName = '.tallyisle_write_probe.tmp';
  static const String _propfindBody =
      '<?xml version="1.0" encoding="utf-8"?>'
      '<d:propfind xmlns:d="DAV:">'
      '<d:prop>'
      '<d:displayname/>'
      '<d:getcontentlength/>'
      '<d:getlastmodified/>'
      '<d:resourcetype/>'
      '</d:prop>'
      '</d:propfind>';

  static HttpClient _defaultHttpClient() => Zone.root.run(
    () => HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 15),
  );

  Uri _validatedBaseUri() {
    if (!config.isConfigured) {
      throw const Failure(FailureCode.validation, 'WebDAV 未配置');
    }
    final uri = Uri.parse(config.serverUrl.trim());
    final cleanSegments = <String>[
      for (final s in uri.pathSegments)
        if (s.isNotEmpty) s,
    ];
    return uri.replace(
      pathSegments: cleanSegments,
      query: null,
      fragment: null,
    );
  }

  List<String> _remoteDirSegments() => <String>[
    for (final s in config.remoteDirectory.trim().split('/'))
      if (s.isNotEmpty && s != '.' && s != '..') s,
  ];

  Uri _directoryUri([List<String>? subSegments]) {
    final base = _validatedBaseUri();
    final allSegments = <String>[
      ...base.pathSegments,
      ...(subSegments ?? _remoteDirSegments()),
      '', // trailing slash for WebDAV collection URIs
    ];
    return base.replace(pathSegments: allSegments);
  }

  Uri _fileUri(String fileName) {
    final cleanName = _validateSafeFileName(fileName);
    final base = _validatedBaseUri();
    final allSegments = <String>[
      ...base.pathSegments,
      ..._remoteDirSegments(),
      cleanName,
    ];
    return base.replace(pathSegments: allSegments);
  }

  Uri _relativePathUri(List<String> relSegments) {
    final base = _validatedBaseUri();
    final allSegments = <String>[
      ...base.pathSegments,
      ..._remoteDirSegments(),
      ...relSegments,
    ];
    return base.replace(pathSegments: allSegments);
  }

  static String _validateSafeFileName(String fileName) {
    final trimmed = fileName.trim();
    if (trimmed.isEmpty ||
        trimmed == '.' ||
        trimmed == '..' ||
        trimmed.contains('/') ||
        trimmed.contains(r'\') ||
        trimmed.contains('\x00')) {
      throw Failure(FailureCode.validation, '非法的远端备份文件名：$fileName');
    }
    return trimmed;
  }

  String get _basicAuthHeader {
    final token = base64Encode(
      utf8.encode('${config.username.trim()}:${config.password}'),
    );
    return 'Basic $token';
  }

  Future<T> _withClient<T>(Future<T> Function(HttpClient client) action) {
    final completer = Completer<T>();
    Zone.root.run(() async {
      final client = _httpClientFactory();
      try {
        final result = await action(client);
        completer.complete(result);
      } on Failure catch (e, st) {
        completer.completeError(e, st);
      } on SocketException catch (_, st) {
        completer.completeError(
          const Failure(
            FailureCode.remoteUnavailable,
            '无法连接 WebDAV 服务器，请检查网络或服务器地址',
          ),
          st,
        );
      } on HandshakeException catch (_, st) {
        completer.completeError(
          const Failure(
            FailureCode.remoteUnavailable,
            'WebDAV TLS 证书握手失败，请检查 HTTPS 配置',
          ),
          st,
        );
      } on HttpException catch (_, st) {
        completer.completeError(
          const Failure(FailureCode.remoteUnavailable, 'WebDAV HTTP 协议响应异常'),
          st,
        );
      } on TimeoutException catch (_, st) {
        completer.completeError(
          const Failure(FailureCode.remoteUnavailable, '连接 WebDAV 服务器超时，请稍后重试'),
          st,
        );
      } catch (_, st) {
        completer.completeError(
          const Failure(FailureCode.remoteUnavailable, 'WebDAV 远端请求未完成'),
          st,
        );
      } finally {
        client.close(force: true);
      }
    });
    return completer.future;
  }

  void _checkAuthAndStorageStatus(int statusCode, {required String action}) {
    if (statusCode == 401 || statusCode == 403) {
      throw const Failure(
        FailureCode.authRequired,
        'WebDAV 认证失败或无目录权限，请检查用户名与应用密码',
      );
    }
    if (statusCode == 507) {
      throw const Failure(FailureCode.storageFull, 'WebDAV 远端存储空间不足');
    }
    if (statusCode >= 500 && statusCode != 501 && statusCode != 502) {
      throw Failure(
        FailureCode.remoteUnavailable,
        '$action失败（远端服务器状态码 $statusCode）',
      );
    }
  }

  Future<int> _propfindCollectionDepth0StatusOn(
    HttpClient client,
    Uri dirUri,
  ) async {
    final checkReq = await client
        .openUrl('PROPFIND', dirUri)
        .timeout(controlTimeout);
    checkReq.headers.set(HttpHeaders.authorizationHeader, _basicAuthHeader);
    checkReq.headers.set('Depth', '0');
    checkReq.headers.set(
      HttpHeaders.contentTypeHeader,
      'application/xml; charset=utf-8',
    );
    final bodyBytes = utf8.encode(_propfindBody);
    checkReq.contentLength = bodyBytes.length;
    checkReq.add(bodyBytes);
    final checkRes = await checkReq.close().timeout(controlTimeout);
    await checkRes.drain<void>().timeout(controlTimeout);
    return checkRes.statusCode;
  }

  /// Ensures the configured remote WebDAV folder hierarchy exists (`PROPFIND` + `MKCOL`).
  Future<void> ensureRemoteDirectory() =>
      _withClient((client) => _ensureCollectionHierarchyOn(client, const []));

  Future<void> _ensureCollectionHierarchyOn(
    HttpClient client,
    List<String> extraSegments, {
    bool forceCheck = false,
  }) async {
    final fullSegments = <String>[..._remoteDirSegments(), ...extraSegments];
    final fullKey = '/${fullSegments.join('/')}';
    if (!forceCheck && _verifiedCollectionPaths.contains(fullKey)) {
      return;
    }

    final dirUri = _directoryUri(fullSegments);
    final checkStatus = await _propfindCollectionDepth0StatusOn(client, dirUri);
    _checkAuthAndStorageStatus(checkStatus, action: '检查远端目录');
    if (checkStatus == 200 || checkStatus == 207) {
      final acc = <String>[];
      for (final seg in fullSegments) {
        acc.add(seg);
        _verifiedCollectionPaths.add('/${acc.join('/')}');
      }
      if (fullSegments.isEmpty) {
        _verifiedCollectionPaths.add('/');
      }
      return;
    }

    final current = <String>[];
    for (final seg in fullSegments) {
      current.add(seg);
      final prefixKey = '/${current.join('/')}';
      if (!forceCheck && _verifiedCollectionPaths.contains(prefixKey)) {
        continue;
      }
      final colUri = _directoryUri(current);
      final mkReq = await client
          .openUrl('MKCOL', colUri)
          .timeout(controlTimeout);
      mkReq.headers.set(HttpHeaders.authorizationHeader, _basicAuthHeader);
      mkReq.contentLength = 0;
      final mkRes = await mkReq.close().timeout(controlTimeout);
      await mkRes.drain<void>().timeout(controlTimeout);
      _checkAuthAndStorageStatus(mkRes.statusCode, action: '创建远端目录');
      if (mkRes.statusCode == 201 ||
          mkRes.statusCode == 200 ||
          mkRes.statusCode == 204 ||
          mkRes.statusCode == 405) {
        _verifiedCollectionPaths.add(prefixKey);
        continue;
      }
      if (mkRes.statusCode == 409) {
        // Some WebDAV gateways (e.g. Alist / cloud-drive bridges) return 409
        // instead of 405 when MKCOL targets an already-existing folder.
        final verifyStatus = await _propfindCollectionDepth0StatusOn(
          client,
          colUri,
        );
        if (verifyStatus == 200 || verifyStatus == 207) {
          _verifiedCollectionPaths.add(prefixKey);
          continue;
        }
      }
      throw Failure(
        FailureCode.remoteUnavailable,
        '创建 WebDAV 远端目录失败（状态码 ${mkRes.statusCode}）',
      );
    }
  }

  /// Verifies WebDAV reachability, credentials, directory creation, and write
  /// permission (§1.2).
  Future<void> testConnection() => _withClient((client) async {
    await _ensureCollectionHierarchyOn(client, const []);
    final probeUri = _fileUri(_probeFileName);
    final probeBytes = utf8.encode('tallyisle-webdav-probe');
    await _putBytesOn(client, probeUri, Uint8List.fromList(probeBytes));
    await _deleteUriOn(client, probeUri, ignoreNotFound: true);
  });

  /// Lists `.tally` / `.tallyzip` backups in the remote directory via
  /// `PROPFIND` (`Depth: 1`), excluding temporary `.tmp` uploads (§1.6, R4).
  Future<List<BackupFileMetadata>> listBackups() => _withClient((client) async {
    final dirUri = _directoryUri();
    final req = await client
        .openUrl('PROPFIND', dirUri)
        .timeout(controlTimeout);
    req.headers.set(HttpHeaders.authorizationHeader, _basicAuthHeader);
    req.headers.set('Depth', '1');
    req.headers.set(
      HttpHeaders.contentTypeHeader,
      'application/xml; charset=utf-8',
    );
    final reqBytes = utf8.encode(_propfindBody);
    req.contentLength = reqBytes.length;
    req.add(reqBytes);

    final res = await req.close().timeout(controlTimeout);
    final xmlBody = await utf8.decoder
        .bind(res.timeout(transferTimeout))
        .join();
    if (res.statusCode == 404) {
      return const <BackupFileMetadata>[];
    }
    _checkAuthAndStorageStatus(res.statusCode, action: '获取远端备份列表');
    if (res.statusCode != 207 && res.statusCode != 200) {
      throw Failure(
        FailureCode.remoteUnavailable,
        '获取 WebDAV 备份列表失败（状态码 ${res.statusCode}）',
      );
    }

    return parsePropfindBackups(xmlBody, collectionPath: dirUri.path);
  });

  /// Uploads [bytes] using two-phase atomic staging (`PUT <file>.tmp` -> `MOVE`
  /// to `<file>`), falling back to direct `PUT` + `HEAD` `Content-Length`
  /// verification when the server returns `405` or `501` on `MOVE` (R4).
  Future<BackupFileMetadata> uploadBackup(
    String fileName,
    Uint8List bytes, {
    BackupProgressCallback? onProgress,
  }) => _withClient((client) async {
    final cleanName = _validateSafeFileName(fileName);
    await _ensureCollectionHierarchyOn(client, const []);

    final tmpUri = _fileUri('$cleanName.tmp');
    final finalUri = _fileUri(cleanName);

    await _atomicPutWithMoveFallbackOn(
      client,
      tmpUri: tmpUri,
      finalUri: finalUri,
      bytes: bytes,
      onProgress: onProgress,
    );

    final ts =
        parseTimestampFromFileName(cleanName) ??
        (nowMs?.call() ?? DateTime.now().millisecondsSinceEpoch);
    return BackupFileMetadata(
      fileName: cleanName,
      sizeBytes: bytes.length,
      modifiedAtMs: ts,
    );
  });

  /// Downloads a `.tally` backup from WebDAV and verifies `Content-Length` if
  /// returned by the server.
  Future<Uint8List> downloadBackup(
    String fileName, {
    BackupProgressCallback? onProgress,
  }) => _withClient((client) async {
    final data = await _getUriBytesOrNullOn(
      client,
      _fileUri(fileName),
      onProgress: onProgress,
    );
    if (data == null) {
      throw const Failure(FailureCode.storageUnavailable, '远端备份文件不存在');
    }
    return data;
  });

  /// Deletes a remote backup file from WebDAV (§1.8).
  Future<void> deleteBackup(String fileName) => _withClient((client) async {
    await _deleteUriOn(client, _fileUri(fileName), ignoreNotFound: true);
  });

  /// Prunes older remote routine backups exceeding [keepCount] (defaults to
  /// `config.keepCount`, §6.2), while protecting `conflict_*` files (R6).
  Future<List<String>> pruneOldBackups({int? keepCount}) async {
    final effectiveKeep = keepCount ?? config.keepCount;
    if (effectiveKeep <= 0) return const <String>[];
    final current = await listBackups();
    final toDelete = selectNonConflictBackupsToPrune(
      current.map((e) => e.toRetentionItem()),
      keepCount: effectiveKeep,
    );
    for (final name in toDelete) {
      await deleteBackup(name);
    }
    return toDelete;
  }

  /// Reads an arbitrary relative object under `remoteDirectory` (e.g. `sync/head.json`),
  /// returning `null` on `404`.
  Future<Uint8List?> getRelativeFileOrNull(
    String relativePath, {
    BackupProgressCallback? onProgress,
  }) => _withClient((client) async {
    final segments = validateCloudRelativeSegments(relativePath);
    return _getUriBytesOrNullOn(
      client,
      _relativePathUri(segments),
      onProgress: onProgress,
    );
  });

  /// Reads an arbitrary relative object under `remoteDirectory`, throwing on `404`.
  Future<Uint8List> getRelativeFile(
    String relativePath, {
    BackupProgressCallback? onProgress,
  }) async {
    final bytes = await getRelativeFileOrNull(
      relativePath,
      onProgress: onProgress,
    );
    if (bytes == null) {
      throw Failure(FailureCode.storageUnavailable, '远端同步对象不存在：$relativePath');
    }
    return bytes;
  }

  /// Writes an arbitrary relative object under `remoteDirectory` using two-phase
  /// `.tmp -> MOVE` atomic commit (with `405`/`501` fallback).
  Future<void> putRelativeFile(
    String relativePath,
    Uint8List bytes, {
    String contentType = 'application/octet-stream',
    BackupProgressCallback? onProgress,
  }) => _withClient((client) async {
    final segments = validateCloudRelativeSegments(relativePath);
    final parentSegments = segments.sublist(0, segments.length - 1);
    await _ensureCollectionHierarchyOn(client, parentSegments);

    final tmpSegments = <String>[...parentSegments, '${segments.last}.tmp'];
    await _atomicPutWithMoveFallbackOn(
      client,
      tmpUri: _relativePathUri(tmpSegments),
      finalUri: _relativePathUri(segments),
      bytes: bytes,
      parentExtraSegments: parentSegments,
      contentType: contentType,
      onProgress: onProgress,
    );
  });

  /// Deletes an arbitrary relative object under `remoteDirectory`.
  Future<void> deleteRelativeFile(String relativePath) =>
      _withClient((client) async {
        final segments = validateCloudRelativeSegments(relativePath);
        await _deleteUriOn(
          client,
          _relativePathUri(segments),
          ignoreNotFound: true,
        );
      });

  /// Lists immediate non-collection, non-`.tmp` file names in [relativeDir].
  Future<Set<String>> listRelativeFileNames(String relativeDir) =>
      _withClient((client) async {
        final subSegments = validateCloudRelativeSegments(
          relativeDir,
          allowEmpty: true,
        );
        final dirUri = _directoryUri(<String>[
          ..._remoteDirSegments(),
          ...subSegments,
        ]);
        final req = await client
            .openUrl('PROPFIND', dirUri)
            .timeout(controlTimeout);
        req.headers.set(HttpHeaders.authorizationHeader, _basicAuthHeader);
        req.headers.set('Depth', '1');
        req.headers.set(
          HttpHeaders.contentTypeHeader,
          'application/xml; charset=utf-8',
        );
        final reqBytes = utf8.encode(_propfindBody);
        req.contentLength = reqBytes.length;
        req.add(reqBytes);

        final res = await req.close().timeout(controlTimeout);
        final xmlBody = await utf8.decoder
            .bind(res.timeout(transferTimeout))
            .join();
        if (res.statusCode == 404) {
          return const <String>{};
        }
        _checkAuthAndStorageStatus(res.statusCode, action: '列举远端同步目录');
        if (res.statusCode != 207 && res.statusCode != 200) {
          throw Failure(
            FailureCode.remoteUnavailable,
            '列举 WebDAV 目录失败（状态码 ${res.statusCode}）',
          );
        }
        return parsePropfindFileNames(xmlBody, collectionPath: dirUri.path);
      });

  Future<int> _sendMoveOn(
    HttpClient client, {
    required Uri tmpUri,
    required Uri finalUri,
  }) async {
    final moveReq = await client
        .openUrl('MOVE', tmpUri)
        .timeout(controlTimeout);
    moveReq.headers.set(HttpHeaders.authorizationHeader, _basicAuthHeader);
    moveReq.headers.set('Destination', finalUri.toString());
    moveReq.headers.set('Overwrite', 'T');
    moveReq.contentLength = 0;
    final moveRes = await moveReq.close().timeout(controlTimeout);
    await moveRes.drain<void>().timeout(controlTimeout);
    return moveRes.statusCode;
  }

  Future<void> _atomicPutWithMoveFallbackOn(
    HttpClient client, {
    required Uri tmpUri,
    required Uri finalUri,
    required Uint8List bytes,
    List<String> parentExtraSegments = const <String>[],
    String contentType = 'application/octet-stream',
    BackupProgressCallback? onProgress,
  }) async {
    await _putBytesOn(
      client,
      tmpUri,
      bytes,
      parentExtraSegments: parentExtraSegments,
      contentType: contentType,
      onProgress: onProgress,
    );

    final moveStatus = await _sendMoveOn(
      client,
      tmpUri: tmpUri,
      finalUri: finalUri,
    );

    if (moveStatus == 200 || moveStatus == 201 || moveStatus == 204) {
      return;
    }

    // Never pre-DELETE `finalUri` before a confirmed overwrite! When `MOVE`
    // (with `Overwrite: T`) returns 409/412/405/501/502/400, clean up `tmpUri`
    // first (freeing server quota without touching live `finalUri`), then fall
    // back directly to standard in-place HTTP `PUT finalUri` + `HEAD` check.
    if (moveStatus == 409 ||
        moveStatus == 412 ||
        moveStatus == 405 ||
        moveStatus == 501 ||
        moveStatus == 502 ||
        moveStatus == 400) {
      try {
        await _deleteUriOn(client, tmpUri, ignoreNotFound: true);
      } catch (_) {
        // Best-effort cleanup of .tmp before direct PUT fallback.
      }
      await _putBytesOn(
        client,
        finalUri,
        bytes,
        parentExtraSegments: parentExtraSegments,
        contentType: contentType,
        onProgress: onProgress,
      );
      await _verifyHeadContentLengthOn(client, finalUri, bytes);
      return;
    }

    try {
      await _deleteUriOn(client, tmpUri, ignoreNotFound: true);
    } catch (_) {}
    _checkAuthAndStorageStatus(moveStatus, action: '原子重命名远端文件');
    throw Failure(
      FailureCode.remoteUnavailable,
      'WebDAV 两阶段提交 MOVE 失败（状态码 $moveStatus）',
    );
  }

  Future<Uint8List?> _getUriBytesOrNullOn(
    HttpClient client,
    Uri uri, {
    BackupProgressCallback? onProgress,
    bool noCache = true,
  }) async {
    final req = await client.getUrl(uri).timeout(controlTimeout);
    req.headers.set(HttpHeaders.authorizationHeader, _basicAuthHeader);
    req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    if (noCache) {
      req.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
    }
    final res = await req.close().timeout(transferTimeout);
    if (res.statusCode == 404 || res.statusCode == 410) {
      await res.drain<void>().timeout(controlTimeout);
      return null;
    }
    _checkAuthAndStorageStatus(res.statusCode, action: '下载远端文件');
    if (res.statusCode != 200) {
      await res.drain<void>().timeout(controlTimeout);
      throw Failure(
        FailureCode.remoteUnavailable,
        '下载 WebDAV 文件失败（状态码 ${res.statusCode}）',
      );
    }

    final expectedLength = res.contentLength;
    final builder = BytesBuilder(copy: false);
    var received = 0;
    await for (final chunk in res.timeout(transferTimeout)) {
      builder.add(chunk);
      received += chunk.length;
      if (expectedLength > 0) {
        onProgress?.call(received, expectedLength);
      }
    }
    if (expectedLength >= 0 &&
        res.compressionState !=
            HttpClientResponseCompressionState.decompressed &&
        received != expectedLength) {
      throw const Failure(FailureCode.remoteUnavailable, '下载中断：远端字节长度与响应头不一致');
    }
    return builder.takeBytes();
  }

  Future<void> _putBytesOn(
    HttpClient client,
    Uri uri,
    Uint8List bytes, {
    List<String> parentExtraSegments = const <String>[],
    String contentType = 'application/octet-stream',
    BackupProgressCallback? onProgress,
    bool retryMissingParent = true,
  }) async {
    final req = await client.putUrl(uri).timeout(controlTimeout);
    req.headers.set(HttpHeaders.authorizationHeader, _basicAuthHeader);
    req.headers.set(HttpHeaders.contentTypeHeader, contentType);
    req.contentLength = bytes.length;

    if (bytes.isEmpty) {
      onProgress?.call(0, 0);
    } else {
      var offset = 0;
      while (offset < bytes.length) {
        final end = offset + _uploadChunkSize < bytes.length
            ? offset + _uploadChunkSize
            : bytes.length;
        req.add(Uint8List.sublistView(bytes, offset, end));
        await req.flush().timeout(transferTimeout);
        offset = end;
        onProgress?.call(offset, bytes.length);
      }
    }

    final res = await req.close().timeout(transferTimeout);
    await res.drain<void>().timeout(controlTimeout);
    if (res.statusCode == 409 && retryMissingParent) {
      // RFC 4918 §9.7.1: 409 on PUT indicates a missing ancestor collection
      // (e.g. cached folder removed externally). Re-verify parent folders and
      // retry PUT once WITHOUT ever deleting the live target URI!
      _verifiedCollectionPaths.clear();
      await _ensureCollectionHierarchyOn(
        client,
        parentExtraSegments,
        forceCheck: true,
      );
      await _putBytesOn(
        client,
        uri,
        bytes,
        parentExtraSegments: parentExtraSegments,
        contentType: contentType,
        onProgress: onProgress,
        retryMissingParent: false,
      );
      return;
    }
    _checkAuthAndStorageStatus(res.statusCode, action: '上传备份文件');
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Failure(
        FailureCode.remoteUnavailable,
        '上传 WebDAV 文件失败（状态码 ${res.statusCode}）',
      );
    }
  }

  Future<void> _verifyHeadContentLengthOn(
    HttpClient client,
    Uri uri,
    Uint8List uploadedBytes,
  ) async {
    final expectedLength = uploadedBytes.length;
    final initialCheck = await _probeHeadLengthOn(client, uri, noCache: false);
    if (initialCheck.skipLengthVerification ||
        initialCheck.remoteLength == null ||
        initialCheck.remoteLength == expectedLength) {
      return;
    }

    // Overwriting an existing WebDAV object (such as `sync/head.json`) via
    // fallback `PUT` can hit a short-lived stale `HEAD` metadata cache on
    // Nutstore / Alist / CDN gateways right at 0ms. Wait briefly and perform a
    // cache-busted verification before declaring a mismatch.
    if (staleHeadRetryDelay > Duration.zero) {
      await Future<void>.delayed(staleHeadRetryDelay);
    }

    if (expectedLength <= _smallPayloadVerifyMaxBytes) {
      final verified = await _verifySmallPayloadViaNoCacheGetOn(
        client,
        uri,
        uploadedBytes,
      );
      if (verified) {
        return;
      }
      throw const Failure(
        FailureCode.remoteUnavailable,
        'WebDAV 远端文件 Content-Length 校验不一致，已拒绝确认上传',
      );
    }

    final retryCheck = await _probeHeadLengthOn(client, uri, noCache: true);
    if (retryCheck.skipLengthVerification ||
        retryCheck.remoteLength == expectedLength) {
      return;
    }
    throw const Failure(
      FailureCode.remoteUnavailable,
      'WebDAV 远端文件 Content-Length 校验不一致，已拒绝确认上传',
    );
  }

  Future<({bool skipLengthVerification, int? remoteLength})> _probeHeadLengthOn(
    HttpClient client,
    Uri uri, {
    required bool noCache,
  }) async {
    final req = await client.openUrl('HEAD', uri).timeout(controlTimeout);
    req.headers.set(HttpHeaders.authorizationHeader, _basicAuthHeader);
    req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    if (noCache) {
      req.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      req.headers.set(HttpHeaders.pragmaHeader, 'no-cache');
    }
    final res = await req.close().timeout(controlTimeout);
    await res.drain<void>().timeout(controlTimeout);
    if (res.statusCode == 405 || res.statusCode == 501) {
      // Lightweight WebDAV server does not implement HEAD; direct PUT succeeded.
      return (skipLengthVerification: true, remoteLength: null);
    }
    _checkAuthAndStorageStatus(res.statusCode, action: '校验远端备份长度');
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Failure(
        FailureCode.remoteUnavailable,
        'WebDAV HEAD 校验失败（状态码 ${res.statusCode}）',
      );
    }
    final contentEncoding = res.headers
        .value(HttpHeaders.contentEncodingHeader)
        ?.trim()
        .toLowerCase();
    if (res.compressionState ==
            HttpClientResponseCompressionState.decompressed ||
        (contentEncoding != null &&
            contentEncoding.isNotEmpty &&
            contentEncoding != 'identity')) {
      return (skipLengthVerification: true, remoteLength: null);
    }
    final contentLengthHeader = res.headers.value(
      HttpHeaders.contentLengthHeader,
    );
    final remoteLength = contentLengthHeader != null
        ? int.tryParse(contentLengthHeader.trim())
        : (res.contentLength >= 0 ? res.contentLength : null);
    return (skipLengthVerification: false, remoteLength: remoteLength);
  }

  Future<bool> _verifySmallPayloadViaNoCacheGetOn(
    HttpClient client,
    Uri uri,
    Uint8List uploadedBytes,
  ) async {
    final req = await client.getUrl(uri).timeout(controlTimeout);
    req.headers.set(HttpHeaders.authorizationHeader, _basicAuthHeader);
    req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    req.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
    req.headers.set(HttpHeaders.pragmaHeader, 'no-cache');
    final res = await req.close().timeout(transferTimeout);
    if (res.statusCode == 404 || res.statusCode == 410) {
      await res.drain<void>().timeout(controlTimeout);
      return false;
    }
    _checkAuthAndStorageStatus(res.statusCode, action: '回读校验远端文件');
    if (res.statusCode != 200) {
      await res.drain<void>().timeout(controlTimeout);
      throw Failure(
        FailureCode.remoteUnavailable,
        '下载 WebDAV 文件失败（状态码 ${res.statusCode}）',
      );
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in res.timeout(transferTimeout)) {
      builder.add(chunk);
    }
    final fetched = builder.takeBytes();
    if (fetched.length != uploadedBytes.length) {
      return false;
    }
    return sha256Hex(fetched) == sha256Hex(uploadedBytes);
  }

  /// Checks whether an arbitrary relative object exists under `remoteDirectory`
  /// via `HEAD` (falling back to `PROPFIND` listing when `HEAD` returns `405`/`501`),
  /// returning `null` on `404`.
  Future<CloudSyncObjectHead?> headRelativeFileOrNull(String relativePath) =>
      _withClient((client) async {
        final segments = validateCloudRelativeSegments(relativePath);
        final uri = _relativePathUri(segments);
        final req = await client.openUrl('HEAD', uri).timeout(controlTimeout);
        req.headers.set(HttpHeaders.authorizationHeader, _basicAuthHeader);
        req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        req.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
        final res = await req.close().timeout(controlTimeout);
        await res.drain<void>().timeout(controlTimeout);
        if (res.statusCode == 404 || res.statusCode == 410) {
          return null;
        }
        if (res.statusCode == 405 || res.statusCode == 501) {
          final parentDir = segments.length > 1
              ? segments.sublist(0, segments.length - 1).join('/')
              : '';
          final names = await listRelativeFileNames(parentDir);
          return names.contains(segments.last)
              ? const CloudSyncObjectHead()
              : null;
        }
        _checkAuthAndStorageStatus(res.statusCode, action: '检查远端同步对象');
        if (res.statusCode < 200 || res.statusCode >= 300) {
          throw Failure(
            FailureCode.remoteUnavailable,
            'WebDAV HEAD 校验失败（状态码 ${res.statusCode}）',
          );
        }
        final contentLengthHeader = res.headers.value(
          HttpHeaders.contentLengthHeader,
        );
        final len = contentLengthHeader != null
            ? int.tryParse(contentLengthHeader.trim())
            : (res.contentLength >= 0 ? res.contentLength : null);
        return CloudSyncObjectHead(sizeBytes: len);
      });

  Future<void> _deleteUriOn(
    HttpClient client,
    Uri uri, {
    required bool ignoreNotFound,
  }) async {
    final req = await client.deleteUrl(uri).timeout(controlTimeout);
    req.headers.set(HttpHeaders.authorizationHeader, _basicAuthHeader);
    final res = await req.close().timeout(controlTimeout);
    await res.drain<void>().timeout(controlTimeout);
    if (ignoreNotFound && (res.statusCode == 404 || res.statusCode == 410)) {
      return;
    }
    _checkAuthAndStorageStatus(res.statusCode, action: '删除远端文件');
    if (res.statusCode != 200 &&
        res.statusCode != 202 &&
        res.statusCode != 204) {
      throw Failure(
        FailureCode.remoteUnavailable,
        '删除 WebDAV 文件失败（状态码 ${res.statusCode}）',
      );
    }
  }

  /// Parses WebDAV `207 Multi-Status` XML responses namespace-agnostically,
  /// extracting properties strictly from `2xx` `<d:propstat>` blocks (`S-08`).
  static List<BackupFileMetadata> parsePropfindBackups(
    String xml, {
    required String collectionPath,
  }) {
    final responseBlocks = RegExp(
      r'<(?:[A-Za-z0-9_-]+:)?response\b[^>]*>([\s\S]*?)</(?:[A-Za-z0-9_-]+:)?response>',
      caseSensitive: false,
    ).allMatches(xml);

    final normalizedCollection = _decodeWebDavPath(collectionPath);
    final items = <BackupFileMetadata>[];
    final seenNames = <String>{};

    for (final match in responseBlocks) {
      final block = match.group(1) ?? '';
      final okPropsXml = _extract2xxPropsXml(block);
      if (okPropsXml == null) continue;
      if (RegExp(
        r'<(?:[A-Za-z0-9_-]+:)?collection\b',
        caseSensitive: false,
      ).hasMatch(okPropsXml)) {
        continue;
      }

      final rawHref = _extractTagText(block, 'href');
      if (rawHref == null || rawHref.isEmpty) continue;
      final decodedPath = _decodeHrefToPath(rawHref);
      if (decodedPath.isEmpty || decodedPath == normalizedCollection) {
        continue;
      }

      final slashIdx = decodedPath.lastIndexOf('/');
      final fileName = slashIdx >= 0
          ? decodedPath.substring(slashIdx + 1)
          : decodedPath;
      if (!isSupportedBackupFileName(fileName)) continue;
      if (!seenNames.add(fileName)) continue;

      final sizeText = _extractTagText(okPropsXml, 'getcontentlength');
      final sizeBytes = int.tryParse(sizeText?.trim() ?? '') ?? 0;

      final lastModText = _extractTagText(okPropsXml, 'getlastmodified');
      final modifiedAtMs =
          _parseHttpOrIsoTimestamp(lastModText) ??
          parseTimestampFromFileName(fileName) ??
          0;

      items.add(
        BackupFileMetadata(
          fileName: fileName,
          sizeBytes: sizeBytes < 0 ? 0 : sizeBytes,
          modifiedAtMs: modifiedAtMs,
        ),
      );
    }

    items.sort((a, b) {
      final byTime = b.modifiedAtMs.compareTo(a.modifiedAtMs);
      if (byTime != 0) return byTime;
      return b.fileName.compareTo(a.fileName);
    });
    return items;
  }

  /// Parses all non-collection, non-`.tmp` immediate filenames from a PROPFIND response.
  static Set<String> parsePropfindFileNames(
    String xml, {
    required String collectionPath,
  }) {
    final responseBlocks = RegExp(
      r'<(?:[A-Za-z0-9_-]+:)?response\b[^>]*>([\s\S]*?)</(?:[A-Za-z0-9_-]+:)?response>',
      caseSensitive: false,
    ).allMatches(xml);

    final normalizedCollection = _decodeWebDavPath(collectionPath);
    final names = <String>{};

    for (final match in responseBlocks) {
      final block = match.group(1) ?? '';
      final okPropsXml = _extract2xxPropsXml(block);
      if (okPropsXml == null) continue;
      if (RegExp(
        r'<(?:[A-Za-z0-9_-]+:)?collection\b',
        caseSensitive: false,
      ).hasMatch(okPropsXml)) {
        continue;
      }
      final rawHref = _extractTagText(block, 'href');
      if (rawHref == null || rawHref.isEmpty) continue;
      final decodedPath = _decodeHrefToPath(rawHref);
      if (decodedPath.isEmpty || decodedPath == normalizedCollection) {
        continue;
      }
      final slashIdx = decodedPath.lastIndexOf('/');
      final fileName = slashIdx >= 0
          ? decodedPath.substring(slashIdx + 1)
          : decodedPath;
      if (fileName.isEmpty || fileName.toLowerCase().endsWith('.tmp')) continue;
      names.add(fileName);
    }
    return names;
  }

  static String? _extract2xxPropsXml(String responseBlock) {
    final propstats = RegExp(
      r'<(?:[A-Za-z0-9_-]+:)?propstat\b[^>]*>([\s\S]*?)</(?:[A-Za-z0-9_-]+:)?propstat>',
      caseSensitive: false,
    ).allMatches(responseBlock).toList();
    if (propstats.isEmpty) {
      final respStatus = _extractTagText(responseBlock, 'status');
      if (respStatus != null && !_is2xxHttpStatusLine(respStatus)) {
        return null;
      }
      return responseBlock;
    }

    final okBuf = StringBuffer();
    var has2xx = false;
    for (final ps in propstats) {
      final psBody = ps.group(1) ?? '';
      final statusText = _extractTagText(psBody, 'status');
      if (statusText != null && !_is2xxHttpStatusLine(statusText)) {
        continue;
      }
      has2xx = true;
      final propMatches = RegExp(
        r'<(?:[A-Za-z0-9_-]+:)?prop\b[^>]*>([\s\S]*?)</(?:[A-Za-z0-9_-]+:)?prop>',
        caseSensitive: false,
      ).allMatches(psBody);
      if (propMatches.isEmpty) {
        okBuf.write(psBody);
      } else {
        for (final pm in propMatches) {
          okBuf.write(pm.group(1) ?? '');
        }
      }
    }
    return has2xx ? okBuf.toString() : null;
  }

  static bool _is2xxHttpStatusLine(String statusText) =>
      RegExp(r'\b2\d\d\b').hasMatch(statusText);

  static String _decodeHrefToPath(String rawHref) {
    var trimmed = rawHref.trim();
    final authorityMatch = RegExp(
      r'^https?://[^/]*',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (authorityMatch != null) {
      trimmed = trimmed.substring(authorityMatch.end);
      if (trimmed.isEmpty) trimmed = '/';
    }
    final qIdx = trimmed.indexOf('?');
    if (qIdx >= 0) trimmed = trimmed.substring(0, qIdx);
    final fIdx = trimmed.indexOf('#');
    if (fIdx >= 0) trimmed = trimmed.substring(0, fIdx);
    return _decodeWebDavPath(trimmed);
  }

  static String _decodeWebDavPath(String rawPath) {
    final decoded = <String>[
      for (final seg in rawPath.split('/')) _safeDecodeUriSegment(seg),
    ].join('/');
    return _stripTrailingSlash(decoded);
  }

  static String _safeDecodeUriSegment(String segment) {
    if (!segment.contains('%')) return segment;
    try {
      return Uri.decodeComponent(segment);
    } on Object {
      return segment.replaceAllMapped(RegExp(r'(?:%[0-9a-fA-F]{2})+'), (match) {
        final encodedRun = match.group(0)!;
        try {
          return Uri.decodeComponent(encodedRun);
        } on Object {
          return encodedRun;
        }
      });
    }
  }

  static bool isSupportedBackupFileName(String fileName) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.tmp')) return false;
    return lower.endsWith('.tally') || lower.endsWith('.tallyzip');
  }

  static String _stripTrailingSlash(String path) =>
      path.length > 1 && path.endsWith('/')
      ? path.substring(0, path.length - 1)
      : path;

  static String? _extractTagText(String xmlBlock, String localName) {
    final pattern = RegExp(
      '<(?:[A-Za-z0-9_-]+:)?$localName\\b[^>]*>([\\s\\S]*?)</(?:[A-Za-z0-9_-]+:)?$localName>',
      caseSensitive: false,
    );
    final raw = pattern.firstMatch(xmlBlock)?.group(1)?.trim();
    if (raw == null) return null;
    return unescapeWebDavXml(raw);
  }

  static String unescapeWebDavXml(String input) {
    return input.replaceAllMapped(
      RegExp(r'&(?:#x([0-9a-fA-F]+)|#([0-9]+)|quot|apos|lt|gt|amp);'),
      (m) {
        final hex = m.group(1);
        if (hex != null) {
          final code = int.tryParse(hex, radix: 16);
          if (code != null && code >= 0 && code <= 0x10FFFF) {
            return String.fromCharCode(code);
          }
          return m.group(0)!;
        }
        final dec = m.group(2);
        if (dec != null) {
          final code = int.tryParse(dec);
          if (code != null && code >= 0 && code <= 0x10FFFF) {
            return String.fromCharCode(code);
          }
          return m.group(0)!;
        }
        return switch (m.group(0)) {
          '&quot;' => '"',
          '&apos;' => "'",
          '&lt;' => '<',
          '&gt;' => '>',
          '&amp;' => '&',
          _ => m.group(0)!,
        };
      },
    );
  }

  static int? _parseHttpOrIsoTimestamp(String? text) {
    if (text == null || text.trim().isEmpty) return null;
    final trimmed = text.trim();
    try {
      return HttpDate.parse(trimmed).millisecondsSinceEpoch;
    } catch (_) {
      return DateTime.tryParse(trimmed)?.millisecondsSinceEpoch;
    }
  }

  static int? parseTimestampFromFileName(String fileName) {
    final m = RegExp(
      r'(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})',
    ).firstMatch(fileName);
    if (m == null) return null;
    final year = int.parse(m.group(1)!);
    final month = int.parse(m.group(2)!);
    final day = int.parse(m.group(3)!);
    final hour = int.parse(m.group(4)!);
    final minute = int.parse(m.group(5)!);
    final second = int.parse(m.group(6)!);
    return DateTime(
      year,
      month,
      day,
      hour,
      minute,
      second,
    ).millisecondsSinceEpoch;
  }
}

/// [BackupTarget] and [CloudSyncObjectStore] backed by [WebDavClient] (ADR-017).
final class WebDavBackupTarget implements BackupTarget, CloudSyncObjectStore {
  WebDavBackupTarget(
    this.config, {
    HttpClient Function()? httpClientFactory,
    int Function()? nowMs,
  }) : _client = WebDavClient(
         config,
         httpClientFactory: httpClientFactory,
         nowMs: nowMs,
       );

  final WebDavConfig config;
  final WebDavClient _client;

  @override
  String get id => 'webdav';

  @override
  String get label => 'WebDAV 云备份';

  @override
  Capability get capability => config.capability;

  @override
  String get targetFingerprint => config.targetFingerprint;

  void _requireConfigured() {
    if (!config.isConfigured) {
      throw const Failure(FailureCode.validation, 'WebDAV 未配置');
    }
  }

  @override
  Future<List<BackupFileMetadata>> listBackups() async {
    _requireConfigured();
    return _client.listBackups();
  }

  @override
  Future<BackupFileMetadata> writeBackup(
    String fileName,
    Uint8List bytes, {
    BackupProgressCallback? onProgress,
  }) async {
    _requireConfigured();
    final uploaded = await _client.uploadBackup(
      fileName,
      bytes,
      onProgress: onProgress,
    );
    if (!isConflictBackupFileName(fileName)) {
      await _client.pruneOldBackups();
    }
    return uploaded;
  }

  @override
  Future<Uint8List> readBackup(
    String fileName, {
    BackupProgressCallback? onProgress,
  }) async {
    _requireConfigured();
    return _client.downloadBackup(fileName, onProgress: onProgress);
  }

  @override
  Future<void> deleteBackup(String fileName) async {
    _requireConfigured();
    await _client.deleteBackup(fileName);
  }

  @override
  Future<Uint8List?> getObjectOrNull(
    String relativePath, {
    BackupProgressCallback? onProgress,
  }) async {
    _requireConfigured();
    return _client.getRelativeFileOrNull(relativePath, onProgress: onProgress);
  }

  @override
  Future<Uint8List> getObject(
    String relativePath, {
    BackupProgressCallback? onProgress,
  }) async {
    _requireConfigured();
    return _client.getRelativeFile(relativePath, onProgress: onProgress);
  }

  @override
  Future<void> putObject(
    String relativePath,
    Uint8List bytes, {
    String contentType = 'application/octet-stream',
    BackupProgressCallback? onProgress,
  }) async {
    _requireConfigured();
    await _client.putRelativeFile(
      relativePath,
      bytes,
      contentType: contentType,
      onProgress: onProgress,
    );
  }

  @override
  Future<void> deleteObject(String relativePath) async {
    _requireConfigured();
    await _client.deleteRelativeFile(relativePath);
  }

  @override
  Future<Set<String>> listRelativeFileNames(String relativeDir) async {
    _requireConfigured();
    return _client.listRelativeFileNames(relativeDir);
  }

  /// Checks whether [relativePath] exists on WebDAV without downloading its body.
  Future<CloudSyncObjectHead?> headObject(String relativePath) async {
    _requireConfigured();
    return _client.headRelativeFileOrNull(relativePath);
  }
}
