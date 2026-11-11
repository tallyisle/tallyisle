import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../core/failure.dart';
import '../../domain/rules/tally_backup.dart';
import '../../platform/files.dart';

typedef BackupProgressCallback =
    void Function(int transferredBytes, int totalBytes);

/// Summary metadata for a single `.tally` backup entry (local or WebDAV, §1.6).
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

/// Pluggable backup storage target boundary (ADR-017: Local File / WebDAV).
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
/// `PUT + HEAD Content-Length` fallback when `MOVE` returns `405`/`501`),
/// `GET`, and `DELETE` (R4, R6, ADR-017).
final class WebDavClient {
  WebDavClient(
    this.config, {
    HttpClient Function()? httpClientFactory,
    this.nowMs,
  }) : _httpClientFactory = httpClientFactory ?? _defaultHttpClient;

  final WebDavConfig config;
  final HttpClient Function() _httpClientFactory;
  final int Function()? nowMs;

  static const int _uploadChunkSize = 32 * 1024;
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
    () => HttpClient()..connectionTimeout = const Duration(seconds: 20),
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
    if (statusCode >= 500 && statusCode != 501) {
      throw Failure(
        FailureCode.remoteUnavailable,
        '$action失败（远端服务器状态码 $statusCode）',
      );
    }
  }

  /// Ensures the configured remote WebDAV folder hierarchy exists (`PROPFIND` + `MKCOL`).
  Future<void> ensureRemoteDirectory() => _withClient(_ensureRemoteDirectoryOn);

  Future<void> _ensureRemoteDirectoryOn(HttpClient client) async {
    final dirUri = _directoryUri();
    final checkReq = await client.openUrl('PROPFIND', dirUri);
    checkReq.headers.set(HttpHeaders.authorizationHeader, _basicAuthHeader);
    checkReq.headers.set('Depth', '0');
    checkReq.headers.set(
      HttpHeaders.contentTypeHeader,
      'application/xml; charset=utf-8',
    );
    final bodyBytes = utf8.encode(_propfindBody);
    checkReq.contentLength = bodyBytes.length;
    checkReq.add(bodyBytes);
    final checkRes = await checkReq.close();
    await checkRes.drain<void>();
    _checkAuthAndStorageStatus(checkRes.statusCode, action: '检查远端目录');
    if (checkRes.statusCode == 200 || checkRes.statusCode == 207) {
      return;
    }

    final segments = _remoteDirSegments();
    final current = <String>[];
    for (final seg in segments) {
      current.add(seg);
      final colUri = _directoryUri(current);
      final mkReq = await client.openUrl('MKCOL', colUri);
      mkReq.headers.set(HttpHeaders.authorizationHeader, _basicAuthHeader);
      mkReq.contentLength = 0;
      final mkRes = await mkReq.close();
      await mkRes.drain<void>();
      _checkAuthAndStorageStatus(mkRes.statusCode, action: '创建远端目录');
      // 201 Created, or 200/204/301/405 when intermediate collection already exists.
      if (mkRes.statusCode != 201 &&
          mkRes.statusCode != 200 &&
          mkRes.statusCode != 204 &&
          mkRes.statusCode != 301 &&
          mkRes.statusCode != 405) {
        throw Failure(
          FailureCode.remoteUnavailable,
          '创建 WebDAV 远端目录失败（状态码 ${mkRes.statusCode}）',
        );
      }
    }
  }

  /// Verifies WebDAV reachability, credentials, directory creation, and write
  /// permission (§1.2).
  Future<void> testConnection() => _withClient((client) async {
    await _ensureRemoteDirectoryOn(client);
    final probeUri = _fileUri(_probeFileName);
    final probeBytes = utf8.encode('tallyisle-webdav-probe');
    await _putBytesOn(client, probeUri, Uint8List.fromList(probeBytes));
    await _deleteUriOn(client, probeUri, ignoreNotFound: true);
  });

  /// Lists `.tally` / `.tallyzip` backups in the remote directory via
  /// `PROPFIND` (`Depth: 1`), excluding temporary `.tmp` uploads (§1.6, R4).
  Future<List<BackupFileMetadata>> listBackups() => _withClient((client) async {
    final dirUri = _directoryUri();
    final req = await client.openUrl('PROPFIND', dirUri);
    req.headers.set(HttpHeaders.authorizationHeader, _basicAuthHeader);
    req.headers.set('Depth', '1');
    req.headers.set(
      HttpHeaders.contentTypeHeader,
      'application/xml; charset=utf-8',
    );
    final reqBytes = utf8.encode(_propfindBody);
    req.contentLength = reqBytes.length;
    req.add(reqBytes);

    final res = await req.close();
    final xmlBody = await utf8.decoder.bind(res).join();
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
    await _ensureRemoteDirectoryOn(client);

    final tmpUri = _fileUri('$cleanName.tmp');
    final finalUri = _fileUri(cleanName);

    await _putBytesOn(client, tmpUri, bytes, onProgress: onProgress);

    final moveReq = await client.openUrl('MOVE', tmpUri);
    moveReq.headers.set(HttpHeaders.authorizationHeader, _basicAuthHeader);
    moveReq.headers.set('Destination', finalUri.toString());
    moveReq.headers.set('Overwrite', 'T');
    moveReq.contentLength = 0;
    final moveRes = await moveReq.close();
    await moveRes.drain<void>();

    if (moveRes.statusCode == 200 ||
        moveRes.statusCode == 201 ||
        moveRes.statusCode == 204) {
      final ts =
          _parseTimestampFromFileName(cleanName) ??
          (nowMs?.call() ?? DateTime.now().millisecondsSinceEpoch);
      return BackupFileMetadata(
        fileName: cleanName,
        sizeBytes: bytes.length,
        modifiedAtMs: ts,
      );
    }

    if (moveRes.statusCode == 405 || moveRes.statusCode == 501) {
      await _deleteUriOn(client, tmpUri, ignoreNotFound: true);
      await _putBytesOn(client, finalUri, bytes, onProgress: onProgress);
      await _verifyHeadContentLengthOn(client, finalUri, bytes.length);
      final ts =
          _parseTimestampFromFileName(cleanName) ??
          (nowMs?.call() ?? DateTime.now().millisecondsSinceEpoch);
      return BackupFileMetadata(
        fileName: cleanName,
        sizeBytes: bytes.length,
        modifiedAtMs: ts,
      );
    }

    await _deleteUriOn(client, tmpUri, ignoreNotFound: true);
    _checkAuthAndStorageStatus(moveRes.statusCode, action: '原子重命名远端备份');
    throw Failure(
      FailureCode.remoteUnavailable,
      'WebDAV 两阶段提交 MOVE 失败（状态码 ${moveRes.statusCode}）',
    );
  });

  /// Downloads a `.tally` backup from WebDAV and verifies `Content-Length` if
  /// returned by the server.
  Future<Uint8List> downloadBackup(
    String fileName, {
    BackupProgressCallback? onProgress,
  }) => _withClient((client) async {
    final uri = _fileUri(fileName);
    final req = await client.getUrl(uri);
    req.headers.set(HttpHeaders.authorizationHeader, _basicAuthHeader);
    final res = await req.close();
    if (res.statusCode == 404) {
      await res.drain<void>();
      throw const Failure(FailureCode.storageUnavailable, '远端备份文件不存在');
    }
    _checkAuthAndStorageStatus(res.statusCode, action: '下载远端备份');
    if (res.statusCode != 200) {
      await res.drain<void>();
      throw Failure(
        FailureCode.remoteUnavailable,
        '下载 WebDAV 备份失败（状态码 ${res.statusCode}）',
      );
    }

    final expectedLength = res.contentLength;
    final builder = BytesBuilder(copy: false);
    var received = 0;
    await for (final chunk in res) {
      builder.add(chunk);
      received += chunk.length;
      if (expectedLength > 0) {
        onProgress?.call(received, expectedLength);
      }
    }
    if (expectedLength >= 0 && received != expectedLength) {
      throw const Failure(
        FailureCode.remoteUnavailable,
        '下载中断：远端备份字节长度与响应头不一致',
      );
    }
    return builder.takeBytes();
  });

  /// Deletes a remote backup file from WebDAV (§1.8).
  Future<void> deleteBackup(String fileName) => _withClient((client) async {
    await _deleteUriOn(client, _fileUri(fileName), ignoreNotFound: true);
  });

  /// Prunes older remote backups exceeding [keepCount] (defaults to
  /// `config.keepCount`, §6.2). Returns the list of deleted filenames.
  Future<List<String>> pruneOldBackups({int? keepCount}) async {
    final effectiveKeep = keepCount ?? config.keepCount;
    if (effectiveKeep <= 0) return const <String>[];
    final current = await listBackups();
    final toDelete = selectBackupsToPrune(
      current.map((e) => e.toRetentionItem()),
      keepCount: effectiveKeep,
    );
    for (final name in toDelete) {
      await deleteBackup(name);
    }
    return toDelete;
  }

  Future<void> _putBytesOn(
    HttpClient client,
    Uri uri,
    Uint8List bytes, {
    BackupProgressCallback? onProgress,
  }) async {
    final req = await client.putUrl(uri);
    req.headers.set(HttpHeaders.authorizationHeader, _basicAuthHeader);
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/octet-stream');
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
        offset = end;
        onProgress?.call(offset, bytes.length);
      }
    }

    final res = await req.close();
    await res.drain<void>();
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
    int expectedLength,
  ) async {
    final req = await client.openUrl('HEAD', uri);
    req.headers.set(HttpHeaders.authorizationHeader, _basicAuthHeader);
    final res = await req.close();
    await res.drain<void>();
    _checkAuthAndStorageStatus(res.statusCode, action: '校验远端备份长度');
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Failure(
        FailureCode.remoteUnavailable,
        'WebDAV HEAD 校验失败（状态码 ${res.statusCode}）',
      );
    }
    final contentLengthHeader = res.headers.value(
      HttpHeaders.contentLengthHeader,
    );
    final remoteLength = contentLengthHeader != null
        ? int.tryParse(contentLengthHeader.trim())
        : (res.contentLength >= 0 ? res.contentLength : null);
    if (remoteLength == null || remoteLength != expectedLength) {
      throw const Failure(
        FailureCode.remoteUnavailable,
        'WebDAV 远端文件 Content-Length 校验不一致，已拒绝确认上传',
      );
    }
  }

  Future<void> _deleteUriOn(
    HttpClient client,
    Uri uri, {
    required bool ignoreNotFound,
  }) async {
    final req = await client.deleteUrl(uri);
    req.headers.set(HttpHeaders.authorizationHeader, _basicAuthHeader);
    final res = await req.close();
    await res.drain<void>();
    if (ignoreNotFound && res.statusCode == 404) {
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

  /// Parses WebDAV `207 Multi-Status` XML responses namespace-agnostically.
  static List<BackupFileMetadata> parsePropfindBackups(
    String xml, {
    required String collectionPath,
  }) {
    final responseBlocks = RegExp(
      r'<(?:[A-Za-z0-9_-]+:)?response\b[^>]*>([\s\S]*?)</(?:[A-Za-z0-9_-]+:)?response>',
      caseSensitive: false,
    ).allMatches(xml);

    final normalizedCollection = _stripTrailingSlash(
      Uri.decodeFull(collectionPath),
    );
    final items = <BackupFileMetadata>[];
    final seenNames = <String>{};

    for (final match in responseBlocks) {
      final block = match.group(1) ?? '';
      if (RegExp(
        r'<(?:[A-Za-z0-9_-]+:)?collection\b',
        caseSensitive: false,
      ).hasMatch(block)) {
        continue;
      }

      final rawHref = _extractTagText(block, 'href');
      if (rawHref == null || rawHref.isEmpty) continue;
      final hrefPath = Uri.tryParse(rawHref)?.path ?? rawHref;
      final decodedPath = _stripTrailingSlash(Uri.decodeFull(hrefPath));
      if (decodedPath.isEmpty || decodedPath == normalizedCollection) {
        continue;
      }

      final slashIdx = decodedPath.lastIndexOf('/');
      final fileName = slashIdx >= 0
          ? decodedPath.substring(slashIdx + 1)
          : decodedPath;
      if (!_isSupportedBackupFileName(fileName)) continue;
      if (!seenNames.add(fileName)) continue;

      final sizeText = _extractTagText(block, 'getcontentlength');
      final sizeBytes = int.tryParse(sizeText?.trim() ?? '') ?? 0;

      final lastModText = _extractTagText(block, 'getlastmodified');
      final modifiedAtMs =
          _parseHttpOrIsoTimestamp(lastModText) ??
          _parseTimestampFromFileName(fileName) ??
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

  static bool _isSupportedBackupFileName(String fileName) {
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
    return raw
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'");
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

  static int? _parseTimestampFromFileName(String fileName) {
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

/// [BackupTarget] backed by [WebDavClient] (ADR-017).
final class WebDavBackupTarget implements BackupTarget {
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
    await _client.pruneOldBackups();
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
}
