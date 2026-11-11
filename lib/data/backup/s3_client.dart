import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../core/failure.dart';
import '../../domain/rules/cloud_sync_rules.dart';
import '../../domain/rules/s3_sigv4_rules.dart';
import '../../domain/rules/tally_backup.dart';
import '../../platform/files.dart';
import 'webdav_client.dart';

/// User-configured S3-compatible object storage endpoint & backup policy.
final class S3Config {
  const S3Config({
    this.endpoint = '',
    this.region = defaultS3Region,
    this.bucket = '',
    this.accessKeyId = '',
    this.secretAccessKey = '',
    this.remotePrefix = defaultS3RemotePrefix,
    this.forcePathStyle = true,
    this.keepCount = defaultWebDavKeepCount,
    this.autoBackupEnabled = false,
    this.autoBackupIntervalHours = defaultAutoBackupIntervalHours,
    this.includeAttachments = true,
  });

  const S3Config.unconfigured() : this();

  final String endpoint;
  final String region;
  final String bucket;
  final String accessKeyId;
  final String secretAccessKey;
  final String remotePrefix;
  final bool forcePathStyle;
  final int keepCount;
  final bool autoBackupEnabled;
  final int autoBackupIntervalHours;
  final bool includeAttachments;

  String get effectiveRegion =>
      region.trim().isEmpty ? defaultS3Region : region.trim();

  String get normalizedPrefix {
    try {
      return normalizeS3Prefix(remotePrefix);
    } on Failure {
      return defaultS3RemotePrefix;
    }
  }

  bool get isConfigured {
    final cleanEndpoint = endpoint.trim();
    final cleanBucket = bucket.trim();
    if (cleanEndpoint.isEmpty ||
        cleanBucket.isEmpty ||
        accessKeyId.trim().isEmpty ||
        secretAccessKey.isEmpty) {
      return false;
    }
    if (cleanBucket.contains('/') ||
        cleanBucket.contains(r'\') ||
        cleanBucket.contains(' ') ||
        cleanBucket == '.' ||
        cleanBucket == '..') {
      return false;
    }
    final uri = Uri.tryParse(cleanEndpoint);
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

  String get targetFingerprint => sha256Hex(
    utf8.encode(
      's3|${endpoint.trim().toLowerCase()}|${bucket.trim()}|$normalizedPrefix|$forcePathStyle',
    ),
  );

  S3Config copyWith({
    String? endpoint,
    String? region,
    String? bucket,
    String? accessKeyId,
    String? secretAccessKey,
    String? remotePrefix,
    bool? forcePathStyle,
    int? keepCount,
    bool? autoBackupEnabled,
    int? autoBackupIntervalHours,
    bool? includeAttachments,
  }) => S3Config(
    endpoint: endpoint ?? this.endpoint,
    region: region ?? this.region,
    bucket: bucket ?? this.bucket,
    accessKeyId: accessKeyId ?? this.accessKeyId,
    secretAccessKey: secretAccessKey ?? this.secretAccessKey,
    remotePrefix: remotePrefix ?? this.remotePrefix,
    forcePathStyle: forcePathStyle ?? this.forcePathStyle,
    keepCount: keepCount ?? this.keepCount,
    autoBackupEnabled: autoBackupEnabled ?? this.autoBackupEnabled,
    autoBackupIntervalHours:
        autoBackupIntervalHours ?? this.autoBackupIntervalHours,
    includeAttachments: includeAttachments ?? this.includeAttachments,
  );

  Map<String, Object> toJson() => <String, Object>{
    'endpoint': endpoint.trim(),
    'region': effectiveRegion,
    'bucket': bucket.trim(),
    'access_key_id': accessKeyId.trim(),
    'secret_access_key': secretAccessKey,
    'remote_prefix': normalizedPrefix,
    'force_path_style': forcePathStyle,
    'keep_count': keepCount,
    'auto_backup_enabled': autoBackupEnabled,
    'auto_backup_interval_hours': autoBackupIntervalHours,
    'include_attachments': includeAttachments,
  };

  factory S3Config.fromJson(Map<String, Object?> json) => S3Config(
    endpoint: (json['endpoint'] as String?) ?? '',
    region: (json['region'] as String?) ?? defaultS3Region,
    bucket: (json['bucket'] as String?) ?? '',
    accessKeyId: (json['access_key_id'] as String?) ?? '',
    secretAccessKey: (json['secret_access_key'] as String?) ?? '',
    remotePrefix: (json['remote_prefix'] as String?) ?? defaultS3RemotePrefix,
    forcePathStyle: (json['force_path_style'] as bool?) ?? true,
    keepCount: (json['keep_count'] as int?) ?? defaultWebDavKeepCount,
    autoBackupEnabled: (json['auto_backup_enabled'] as bool?) ?? false,
    autoBackupIntervalHours:
        (json['auto_backup_interval_hours'] as int?) ??
        defaultAutoBackupIntervalHours,
    includeAttachments: (json['include_attachments'] as bool?) ?? true,
  );
}

/// Summary of an object listed under `S3Config.remotePrefix`.
final class S3ObjectMetadata {
  const S3ObjectMetadata({
    required this.relativePath,
    required this.fullKey,
    required this.sizeBytes,
    required this.modifiedAtMs,
    this.etag,
  });

  final String relativePath;
  final String fullKey;
  final int sizeBytes;
  final int modifiedAtMs;
  final String? etag;
}

/// Pure `dart:io` [HttpClient] S3 client using AWS Signature Version 4
/// (`AWS4-HMAC-SHA256`), compatible with AWS S3, Cloudflare R2, Aliyun OSS,
/// Tencent COS, MinIO, and Backblaze B2.
final class S3Client {
  S3Client(this.config, {HttpClient Function()? httpClientFactory, this.nowMs})
    : _httpClientFactory = httpClientFactory ?? _defaultHttpClient;

  final S3Config config;
  final HttpClient Function() _httpClientFactory;
  final int Function()? nowMs;

  static const int _uploadChunkSize = 32 * 1024;
  static const int _maxListPages = 50;
  static const String _probeRelativePath = '.tallyisle_s3_probe.tmp';

  static HttpClient _defaultHttpClient() => Zone.root.run(
    () => HttpClient()..connectionTimeout = const Duration(seconds: 20),
  );

  DateTime _nowUtc() => DateTime.fromMillisecondsSinceEpoch(
    nowMs?.call() ?? DateTime.now().millisecondsSinceEpoch,
    isUtc: true,
  );

  void _requireConfigured() {
    if (!config.isConfigured) {
      throw const Failure(FailureCode.validation, 'S3 对象存储未配置');
    }
    normalizeS3Prefix(config.remotePrefix);
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
            '无法连接 S3 服务器，请检查网络或 Endpoint 地址',
          ),
          st,
        );
      } on HandshakeException catch (_, st) {
        completer.completeError(
          const Failure(
            FailureCode.remoteUnavailable,
            'S3 TLS 证书握手失败，请检查 HTTPS 配置',
          ),
          st,
        );
      } on HttpException catch (_, st) {
        completer.completeError(
          const Failure(FailureCode.remoteUnavailable, 'S3 HTTP 协议响应异常'),
          st,
        );
      } on TimeoutException catch (_, st) {
        completer.completeError(
          const Failure(FailureCode.remoteUnavailable, '连接 S3 服务器超时，请稍后重试'),
          st,
        );
      } catch (_, st) {
        completer.completeError(
          const Failure(FailureCode.remoteUnavailable, 'S3 远端请求未完成'),
          st,
        );
      } finally {
        client.close(force: true);
      }
    });
    return completer.future;
  }

  SignedS3Request _sign({
    required String method,
    String objectKey = '',
    Map<String, String> queryParameters = const <String, String>{},
    Uint8List? payloadBytes,
    Map<String, String> extraHeaders = const <String, String>{},
  }) {
    final target = resolveS3RequestTarget(
      endpoint: config.endpoint,
      bucket: config.bucket,
      objectKey: objectKey,
      forcePathStyle: config.forcePathStyle,
      queryParameters: queryParameters,
    );
    return signS3Request(
      method: method,
      target: target,
      accessKeyId: config.accessKeyId,
      secretAccessKey: config.secretAccessKey,
      region: config.effectiveRegion,
      payloadBytes: payloadBytes,
      timestampUtc: _nowUtc(),
      extraHeaders: extraHeaders,
    );
  }

  void _applySignedHeaders(HttpClientRequest req, SignedS3Request signed) {
    req.followRedirects = false;
    for (final entry in signed.headers.entries) {
      if (entry.key == 'host') {
        req.headers.set(HttpHeaders.hostHeader, entry.value);
      } else {
        req.headers.set(entry.key, entry.value);
      }
    }
  }

  Never _throwForErrorStatus(
    int statusCode,
    String responseBody, {
    required String action,
  }) {
    if (statusCode == 401 || statusCode == 403) {
      if (responseBody.contains('RequestTimeTooSkewed')) {
        throw const Failure(
          FailureCode.authRequired,
          'S3 签名时间偏差过大，请校准本机系统时间后重试',
        );
      }
      throw const Failure(
        FailureCode.authRequired,
        'S3 认证失败或无存储桶权限，请检查密钥、Region 与 Bucket 配置',
      );
    }
    if (statusCode == 404 && responseBody.contains('NoSuchBucket')) {
      throw const Failure(
        FailureCode.storageUnavailable,
        'S3 存储桶（Bucket）不存在，请检查名称与 Endpoint',
      );
    }
    if (statusCode == 507 || responseBody.contains('QuotaExceeded')) {
      throw const Failure(FailureCode.storageFull, 'S3 远端存储空间或配额不足');
    }
    throw Failure(
      FailureCode.remoteUnavailable,
      '$action失败（S3 状态码 $statusCode）',
    );
  }

  /// Downloads an object relative to `config.remotePrefix`, returning `null` on `404`.
  Future<Uint8List?> getObjectOrNull(
    String relativePath, {
    BackupProgressCallback? onProgress,
  }) => _withClient((client) async {
    _requireConfigured();
    final key = joinS3ObjectKey(config.remotePrefix, relativePath);
    return _getObjectKeyOrNullOn(client, key, onProgress: onProgress);
  });

  Future<Uint8List?> _getObjectKeyOrNullOn(
    HttpClient client,
    String objectKey, {
    BackupProgressCallback? onProgress,
  }) async {
    final signed = _sign(method: 'GET', objectKey: objectKey);
    final req = await client.openUrl('GET', signed.target.requestUri);
    _applySignedHeaders(req, signed);
    final res = await req.close();

    if (res.statusCode == 404) {
      final errXml = await utf8.decoder.bind(res).join().catchError((_) => '');
      if (errXml.contains('NoSuchBucket')) {
        _throwForErrorStatus(404, errXml, action: '读取远端对象');
      }
      return null;
    }

    if (res.statusCode != 200) {
      final errXml = await utf8.decoder.bind(res).join().catchError((_) => '');
      _throwForErrorStatus(res.statusCode, errXml, action: '读取远端对象');
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
        '下载中断：S3 对象字节长度与响应头不一致',
      );
    }
    return builder.takeBytes();
  }

  /// Downloads an object relative to `config.remotePrefix`, throwing on `404`.
  Future<Uint8List> getObject(
    String relativePath, {
    BackupProgressCallback? onProgress,
  }) async {
    final data = await getObjectOrNull(relativePath, onProgress: onProgress);
    if (data == null) {
      throw Failure(FailureCode.storageUnavailable, 'S3 远端对象不存在：$relativePath');
    }
    return data;
  }

  /// Uploads [bytes] to an object relative to `config.remotePrefix` via SigV4 `PUT`.
  Future<void> putObject(
    String relativePath,
    Uint8List bytes, {
    String contentType = 'application/octet-stream',
    BackupProgressCallback? onProgress,
  }) => _withClient((client) async {
    _requireConfigured();
    validateCloudRelativeSegments(relativePath);
    final key = joinS3ObjectKey(config.remotePrefix, relativePath);
    await _putObjectKeyOn(
      client,
      key,
      bytes,
      contentType: contentType,
      onProgress: onProgress,
    );
  });

  Future<void> _putObjectKeyOn(
    HttpClient client,
    String objectKey,
    Uint8List bytes, {
    String contentType = 'application/octet-stream',
    BackupProgressCallback? onProgress,
  }) async {
    final signed = _sign(
      method: 'PUT',
      objectKey: objectKey,
      payloadBytes: bytes,
      extraHeaders: <String, String>{'content-type': contentType},
    );
    final req = await client.openUrl('PUT', signed.target.requestUri);
    _applySignedHeaders(req, signed);
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
    if (res.statusCode < 200 || res.statusCode >= 300) {
      final errBody = await utf8.decoder.bind(res).join().catchError((_) => '');
      _throwForErrorStatus(res.statusCode, errBody, action: '上传 S3 对象');
    }
    await res.drain<void>();
  }

  /// Deletes an object relative to `config.remotePrefix`.
  Future<void> deleteObject(
    String relativePath, {
    bool ignoreNotFound = true,
  }) => _withClient((client) async {
    _requireConfigured();
    validateCloudRelativeSegments(relativePath);
    final key = joinS3ObjectKey(config.remotePrefix, relativePath);
    await _deleteObjectKeyOn(client, key, ignoreNotFound: ignoreNotFound);
  });

  Future<void> _deleteObjectKeyOn(
    HttpClient client,
    String objectKey, {
    required bool ignoreNotFound,
  }) async {
    final signed = _sign(method: 'DELETE', objectKey: objectKey);
    final req = await client.openUrl('DELETE', signed.target.requestUri);
    _applySignedHeaders(req, signed);
    req.contentLength = 0;
    final res = await req.close();
    if (ignoreNotFound && res.statusCode == 404) {
      await res.drain<void>();
      return;
    }
    if (res.statusCode != 200 &&
        res.statusCode != 202 &&
        res.statusCode != 204) {
      final errBody = await utf8.decoder.bind(res).join().catchError((_) => '');
      _throwForErrorStatus(res.statusCode, errBody, action: '删除 S3 对象');
    }
    await res.drain<void>();
  }

  /// Lists objects under `config.remotePrefix/[relativePrefix]` via S3
  /// `ListObjectsV2` (`GET ?list-type=2&prefix=...`), following pagination.
  Future<List<S3ObjectMetadata>> listObjects({String relativePrefix = ''}) =>
      _withClient((client) async {
        _requireConfigured();
        final rootPrefix = '${normalizeS3Prefix(config.remotePrefix)}/';
        final queryPrefix = joinS3ObjectKey(
          config.remotePrefix,
          relativePrefix,
          trailingSlash: true,
        );

        final results = <S3ObjectMetadata>[];
        String? continuationToken;

        for (var pageIdx = 0; pageIdx < _maxListPages; pageIdx++) {
          final query = <String, String>{
            'list-type': '2',
            'prefix': queryPrefix,
            if (continuationToken != null)
              'continuation-token': continuationToken,
          };
          final signed = _sign(method: 'GET', queryParameters: query);
          final req = await client.openUrl('GET', signed.target.requestUri);
          _applySignedHeaders(req, signed);
          final res = await req.close();
          final xmlBody = await utf8.decoder.bind(res).join();

          if (res.statusCode != 200) {
            _throwForErrorStatus(res.statusCode, xmlBody, action: '获取 S3 对象列表');
          }

          final page = parseS3ListObjectsV2Xml(xmlBody);
          for (final obj in page.objects) {
            if (!obj.key.startsWith(rootPrefix)) continue;
            final rel = obj.key.substring(rootPrefix.length);
            if (rel.isEmpty || rel.endsWith('/')) continue;
            results.add(
              S3ObjectMetadata(
                relativePath: rel,
                fullKey: obj.key,
                sizeBytes: obj.sizeBytes,
                modifiedAtMs: obj.lastModifiedMs,
                etag: obj.etag,
              ),
            );
          }

          if (!page.isTruncated || page.nextContinuationToken == null) {
            break;
          }
          continuationToken = page.nextContinuationToken;
        }

        return results;
      });

  /// Performs a real write -> read byte verification -> delete probe against
  /// the configured S3 bucket and prefix.
  Future<void> testConnection() => _withClient((client) async {
    _requireConfigured();
    final probeKey = joinS3ObjectKey(config.remotePrefix, _probeRelativePath);
    final probeBytes = Uint8List.fromList(utf8.encode('tallyisle-s3-probe-v1'));
    await _putObjectKeyOn(client, probeKey, probeBytes);
    try {
      final readBack = await _getObjectKeyOrNullOn(client, probeKey);
      if (readBack == null || !_bytesEqual(readBack, probeBytes)) {
        throw const Failure(
          FailureCode.remoteUnavailable,
          'S3 读写探针内容校验不一致，请检查网关或存储桶权限',
        );
      }
    } finally {
      try {
        await _deleteObjectKeyOn(client, probeKey, ignoreNotFound: true);
      } catch (_) {}
    }
  });

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// [BackupTarget] and [CloudSyncObjectStore] backed by [S3Client] (`ADR-017`).
final class S3BackupTarget implements BackupTarget, CloudSyncObjectStore {
  S3BackupTarget(
    this.config, {
    HttpClient Function()? httpClientFactory,
    int Function()? nowMs,
  }) : _client = S3Client(
         config,
         httpClientFactory: httpClientFactory,
         nowMs: nowMs,
       ),
       _nowMs = nowMs;

  final S3Config config;
  final S3Client _client;
  final int Function()? _nowMs;

  @override
  String get id => 's3';

  @override
  String get label => 'S3 对象存储备份';

  @override
  Capability get capability => config.capability;

  @override
  String get targetFingerprint => config.targetFingerprint;

  void _requireConfigured() {
    if (!config.isConfigured) {
      throw const Failure(FailureCode.validation, 'S3 对象存储未配置');
    }
  }

  static String _validateFlatBackupName(String fileName) {
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

  /// Arbitrary relative-path `GET` (returns `null` on `404`).
  @override
  Future<Uint8List?> getObjectOrNull(
    String relativePath, {
    BackupProgressCallback? onProgress,
  }) => _client.getObjectOrNull(relativePath, onProgress: onProgress);

  /// Arbitrary relative-path `GET` (throws on `404`).
  @override
  Future<Uint8List> getObject(
    String relativePath, {
    BackupProgressCallback? onProgress,
  }) => _client.getObject(relativePath, onProgress: onProgress);

  /// Arbitrary relative-path `PUT`.
  @override
  Future<void> putObject(
    String relativePath,
    Uint8List bytes, {
    String contentType = 'application/octet-stream',
    BackupProgressCallback? onProgress,
  }) => _client.putObject(
    relativePath,
    bytes,
    contentType: contentType,
    onProgress: onProgress,
  );

  /// Arbitrary relative-path `DELETE`.
  @override
  Future<void> deleteObject(String relativePath) =>
      _client.deleteObject(relativePath, ignoreNotFound: true);

  /// Arbitrary relative-prefix `ListObjectsV2`.
  Future<List<S3ObjectMetadata>> listObjects({String relativePrefix = ''}) =>
      _client.listObjects(relativePrefix: relativePrefix);

  /// Real write/read/delete probe.
  Future<void> testConnection() => _client.testConnection();

  @override
  Future<Set<String>> listRelativeFileNames(String relativeDir) async {
    _requireConfigured();
    final dirSegs = validateCloudRelativeSegments(
      relativeDir,
      allowEmpty: true,
    );
    final relPrefix = dirSegs.join('/');
    final objects = await _client.listObjects(relativePrefix: relPrefix);
    final stripPrefix = relPrefix.isEmpty ? '' : '$relPrefix/';
    final names = <String>{};
    for (final obj in objects) {
      if (stripPrefix.isNotEmpty && !obj.relativePath.startsWith(stripPrefix)) {
        continue;
      }
      final tail = stripPrefix.isEmpty
          ? obj.relativePath
          : obj.relativePath.substring(stripPrefix.length);
      if (tail.isEmpty ||
          tail.contains('/') ||
          tail.toLowerCase().endsWith('.tmp')) {
        continue;
      }
      names.add(tail);
    }
    return names;
  }

  @override
  Future<List<BackupFileMetadata>> listBackups() async {
    _requireConfigured();
    final objects = await _client.listObjects();
    final items = <BackupFileMetadata>[];
    for (final obj in objects) {
      if (obj.relativePath.contains('/')) continue;
      if (!WebDavClient.isSupportedBackupFileName(obj.relativePath)) continue;
      final modifiedAtMs = obj.modifiedAtMs > 0
          ? obj.modifiedAtMs
          : (WebDavClient.parseTimestampFromFileName(obj.relativePath) ?? 0);
      items.add(
        BackupFileMetadata(
          fileName: obj.relativePath,
          sizeBytes: obj.sizeBytes,
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

  @override
  Future<BackupFileMetadata> writeBackup(
    String fileName,
    Uint8List bytes, {
    BackupProgressCallback? onProgress,
  }) async {
    _requireConfigured();
    final cleanName = _validateFlatBackupName(fileName);
    await _client.putObject(cleanName, bytes, onProgress: onProgress);
    if (!isConflictBackupFileName(cleanName)) {
      await pruneOldBackups();
    }
    final ts =
        WebDavClient.parseTimestampFromFileName(cleanName) ??
        (_nowMs?.call() ?? DateTime.now().millisecondsSinceEpoch);
    return BackupFileMetadata(
      fileName: cleanName,
      sizeBytes: bytes.length,
      modifiedAtMs: ts,
    );
  }

  /// Prunes older S3 routine backups exceeding [keepCount] while protecting `conflict_*`.
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

  @override
  Future<Uint8List> readBackup(
    String fileName, {
    BackupProgressCallback? onProgress,
  }) async {
    _requireConfigured();
    final cleanName = _validateFlatBackupName(fileName);
    return _client.getObject(cleanName, onProgress: onProgress);
  }

  @override
  Future<void> deleteBackup(String fileName) async {
    _requireConfigured();
    final cleanName = _validateFlatBackupName(fileName);
    await _client.deleteObject(cleanName, ignoreNotFound: true);
  }
}
