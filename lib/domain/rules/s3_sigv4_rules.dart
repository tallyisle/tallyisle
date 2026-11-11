import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../core/failure.dart';
import 'tally_backup.dart';

const String defaultS3Region = 'auto';
const String defaultS3RemotePrefix = 'TallyIsle';
const String s3EmptyPayloadSha256 =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

/// Encodes [input] according to AWS Signature Version 4 URI canonicalization
/// rules (RFC 3986 unreserved `A-Z a-z 0-9 - _ . ~` left literal, all other
/// UTF-8 bytes encoded as uppercase `%XX`, `/` encoded iff [encodeSlash]).
String s3UriEncode(String input, {bool encodeSlash = true}) {
  if (input.isEmpty) return '';
  final bytes = utf8.encode(input);
  final sb = StringBuffer();
  for (final b in bytes) {
    final isUnreserved =
        (b >= 0x41 && b <= 0x5A) || // A-Z
        (b >= 0x61 && b <= 0x7A) || // a-z
        (b >= 0x30 && b <= 0x39) || // 0-9
        b == 0x2D || // -
        b == 0x5F || // _
        b == 0x2E || // .
        b == 0x7E; // ~
    if (isUnreserved || (!encodeSlash && b == 0x2F)) {
      sb.writeCharCode(b);
    } else {
      sb.write('%');
      sb.write(b.toRadixString(16).toUpperCase().padLeft(2, '0'));
    }
  }
  return sb.toString();
}

/// Formats [when] as UTC ISO-8601 basic timestamp `YYYYMMDDTHHMMSSZ` (`x-amz-date`).
String formatAmzDate(DateTime when) {
  final u = when.toUtc();
  String p2(int v) => v.toString().padLeft(2, '0');
  final y = u.year.toString().padLeft(4, '0');
  return '$y${p2(u.month)}${p2(u.day)}T${p2(u.hour)}${p2(u.minute)}${p2(u.second)}Z';
}

/// Formats [when] as UTC `YYYYMMDD` credential scope date stamp.
String formatAmzDateStamp(DateTime when) {
  final u = when.toUtc();
  String p2(int v) => v.toString().padLeft(2, '0');
  final y = u.year.toString().padLeft(4, '0');
  return '$y${p2(u.month)}${p2(u.day)}';
}

/// Builds a sorted AWS SigV4 Canonical Query String from [queryParameters].
String buildCanonicalQueryString(Map<String, String> queryParameters) {
  if (queryParameters.isEmpty) return '';
  final pairs = <(String, String)>[
    for (final entry in queryParameters.entries)
      (
        s3UriEncode(entry.key, encodeSlash: true),
        s3UriEncode(entry.value, encodeSlash: true),
      ),
  ];
  pairs.sort((a, b) {
    final byKey = a.$1.compareTo(b.$1);
    return byKey != 0 ? byKey : a.$2.compareTo(b.$2);
  });
  return [for (final p in pairs) '${p.$1}=${p.$2}'].join('&');
}

/// Validates and normalizes an S3 object prefix (e.g. `/TallyIsle/` -> `TallyIsle`).
String normalizeS3Prefix(String rawPrefix) {
  final trimmed = rawPrefix.trim();
  if (trimmed.isEmpty) return defaultS3RemotePrefix;
  if (trimmed.contains(r'\') || trimmed.contains('\x00')) {
    throw Failure(FailureCode.validation, '非法的 S3 对象前缀：$rawPrefix');
  }
  final segments = <String>[];
  for (final seg in trimmed.split('/')) {
    if (seg.isEmpty) continue;
    if (seg == '.' || seg == '..') {
      throw Failure(FailureCode.validation, 'S3 对象前缀禁止包含相对越界段：$rawPrefix');
    }
    segments.add(seg);
  }
  return segments.isEmpty ? defaultS3RemotePrefix : segments.join('/');
}

/// Validates a relative cloud path (no traversal, backslashes, or null bytes)
/// and returns normalized non-empty path segments.
List<String> validateCloudRelativeSegments(
  String relativePath, {
  bool allowEmpty = false,
}) {
  final trimmed = relativePath.trim();
  if (trimmed.contains(r'\') || trimmed.contains('\x00')) {
    throw Failure(FailureCode.validation, '非法的云端相对路径：$relativePath');
  }
  final segments = <String>[];
  for (final seg in trimmed.split('/')) {
    if (seg.isEmpty) continue;
    if (seg == '.' || seg == '..') {
      throw Failure(FailureCode.validation, '云端路径禁止越界访问：$relativePath');
    }
    segments.add(seg);
  }
  if (!allowEmpty && segments.isEmpty) {
    throw const Failure(FailureCode.validation, '云端文件路径不能为空');
  }
  return segments;
}

/// Joins normalized S3 [remotePrefix] and [relativePath] into a full bucket key.
String joinS3ObjectKey(
  String remotePrefix,
  String relativePath, {
  bool trailingSlash = false,
}) {
  final prefix = normalizeS3Prefix(remotePrefix);
  final relSegments = validateCloudRelativeSegments(
    relativePath,
    allowEmpty: true,
  );
  final joined = <String>[prefix, ...relSegments].join('/');
  return trailingSlash ? '$joined/' : joined;
}

/// Resolved wire URI, `Host` header, and canonical components for an S3 request.
final class S3ResolvedTarget {
  const S3ResolvedTarget({
    required this.requestUri,
    required this.hostHeader,
    required this.canonicalUri,
    required this.canonicalQueryString,
  });

  final Uri requestUri;
  final String hostHeader;
  final String canonicalUri;
  final String canonicalQueryString;
}

/// Resolves path-style or virtual-hosted-style S3 endpoint + bucket + object key.
S3ResolvedTarget resolveS3RequestTarget({
  required String endpoint,
  required String bucket,
  String objectKey = '',
  bool forcePathStyle = true,
  Map<String, String> queryParameters = const <String, String>{},
}) {
  final cleanEndpoint = endpoint.trim();
  final baseUri = Uri.tryParse(cleanEndpoint);
  if (baseUri == null ||
      !baseUri.hasAuthority ||
      baseUri.host.isEmpty ||
      (baseUri.scheme != 'http' && baseUri.scheme != 'https')) {
    throw const Failure(FailureCode.validation, '无效的 S3 Endpoint 地址');
  }

  final cleanBucket = bucket.trim();
  if (cleanBucket.isEmpty ||
      cleanBucket.contains('/') ||
      cleanBucket.contains(r'\') ||
      cleanBucket.contains(' ') ||
      cleanBucket == '.' ||
      cleanBucket == '..') {
    throw const Failure(FailureCode.validation, '无效的 S3 Bucket 名称');
  }

  final baseSegments = <String>[
    for (final s in baseUri.pathSegments)
      if (s.isNotEmpty) s,
  ];

  final hasTrailingSlash = objectKey.endsWith('/') && objectKey.length > 1;
  final keySegments = <String>[
    for (final s in objectKey.split('/'))
      if (s.isNotEmpty) s,
  ];
  for (final seg in keySegments) {
    if (seg == '.' || seg == '..' || seg.contains('\x00')) {
      throw Failure(FailureCode.validation, '非法的 S3 对象键：$objectKey');
    }
  }

  final String effectiveHost;
  final List<String> allSegments;
  if (forcePathStyle) {
    effectiveHost = baseUri.host;
    allSegments = <String>[...baseSegments, cleanBucket, ...keySegments];
  } else {
    final lowerHost = baseUri.host.toLowerCase();
    final lowerPrefix = '${cleanBucket.toLowerCase()}.';
    effectiveHost = lowerHost.startsWith(lowerPrefix)
        ? baseUri.host
        : '$cleanBucket.${baseUri.host}';
    allSegments = <String>[...baseSegments, ...keySegments];
  }

  final isDefaultPort =
      !baseUri.hasPort ||
      (baseUri.scheme == 'http' && baseUri.port == 80) ||
      (baseUri.scheme == 'https' && baseUri.port == 443);
  final hostHeader = isDefaultPort
      ? effectiveHost
      : '$effectiveHost:${baseUri.port}';

  final encodedSegments = <String>[
    for (final seg in allSegments) s3UriEncode(seg, encodeSlash: true),
  ];
  final String canonicalUri;
  if (encodedSegments.isEmpty) {
    canonicalUri = '/';
  } else {
    final path = '/${encodedSegments.join('/')}';
    canonicalUri = hasTrailingSlash ? '$path/' : path;
  }

  final canonicalQueryString = buildCanonicalQueryString(queryParameters);
  final fullUrl = canonicalQueryString.isEmpty
      ? '${baseUri.scheme}://$hostHeader$canonicalUri'
      : '${baseUri.scheme}://$hostHeader$canonicalUri?$canonicalQueryString';

  return S3ResolvedTarget(
    requestUri: Uri.parse(fullUrl),
    hostHeader: hostHeader,
    canonicalUri: canonicalUri,
    canonicalQueryString: canonicalQueryString,
  );
}

/// Result of AWS Signature Version 4 request signing (`AWS4-HMAC-SHA256`).
final class SignedS3Request {
  const SignedS3Request({
    required this.target,
    required this.method,
    required this.amzDate,
    required this.dateStamp,
    required this.payloadSha256,
    required this.canonicalRequest,
    required this.stringToSign,
    required this.signature,
    required this.authorization,
    required this.headers,
  });

  final S3ResolvedTarget target;
  final String method;
  final String amzDate;
  final String dateStamp;
  final String payloadSha256;
  final String canonicalRequest;
  final String stringToSign;
  final String signature;
  final String authorization;
  final Map<String, String> headers;
}

List<int> _hmacSha256(List<int> key, String message) =>
    Hmac(sha256, key).convert(utf8.encode(message)).bytes;

String _hmacSha256Hex(List<int> key, String message) =>
    Hmac(sha256, key).convert(utf8.encode(message)).toString();

String _normalizeHeaderValue(String value) =>
    value.trim().replaceAll(RegExp(r'\s+'), ' ');

/// Computes standard AWS Signature Version 4 (`AWS4-HMAC-SHA256`) headers for S3
/// and S3-compatible object stores (R1).
SignedS3Request signS3Request({
  required String method,
  required S3ResolvedTarget target,
  required String accessKeyId,
  required String secretAccessKey,
  String region = defaultS3Region,
  String service = 's3',
  Uint8List? payloadBytes,
  String? payloadSha256Override,
  required DateTime timestampUtc,
  Map<String, String> extraHeaders = const <String, String>{},
}) {
  final cleanMethod = method.trim().toUpperCase();
  final cleanAccessKey = accessKeyId.trim();
  final cleanRegion = region.trim().isEmpty ? defaultS3Region : region.trim();
  if (cleanAccessKey.isEmpty || secretAccessKey.isEmpty) {
    throw const Failure(FailureCode.validation, 'S3 Access Key 与密钥不能为空');
  }

  final amzDate = formatAmzDate(timestampUtc);
  final dateStamp = formatAmzDateStamp(timestampUtc);
  final payloadSha256 =
      payloadSha256Override ??
      (payloadBytes == null || payloadBytes.isEmpty
          ? s3EmptyPayloadSha256
          : sha256Hex(payloadBytes));

  final canonicalMap = <String, String>{
    'host': _normalizeHeaderValue(target.hostHeader),
    'x-amz-content-sha256': payloadSha256,
    'x-amz-date': amzDate,
  };
  for (final entry in extraHeaders.entries) {
    final lowerKey = entry.key.trim().toLowerCase();
    if (lowerKey.isEmpty) continue;
    canonicalMap[lowerKey] = _normalizeHeaderValue(entry.value);
  }

  final sortedHeaderKeys = canonicalMap.keys.toList()..sort();
  final canonicalHeadersBuffer = StringBuffer();
  for (final k in sortedHeaderKeys) {
    canonicalHeadersBuffer.write('$k:${canonicalMap[k]}\n');
  }
  final signedHeaders = sortedHeaderKeys.join(';');

  final canonicalRequest = <String>[
    cleanMethod,
    target.canonicalUri,
    target.canonicalQueryString,
    canonicalHeadersBuffer.toString(),
    signedHeaders,
    payloadSha256,
  ].join('\n');

  final credentialScope = '$dateStamp/$cleanRegion/$service/aws4_request';
  final stringToSign = <String>[
    'AWS4-HMAC-SHA256',
    amzDate,
    credentialScope,
    sha256Hex(utf8.encode(canonicalRequest)),
  ].join('\n');

  final kSecret = utf8.encode('AWS4$secretAccessKey');
  final kDate = _hmacSha256(kSecret, dateStamp);
  final kRegion = _hmacSha256(kDate, cleanRegion);
  final kService = _hmacSha256(kRegion, service);
  final kSigning = _hmacSha256(kService, 'aws4_request');
  final signature = _hmacSha256Hex(kSigning, stringToSign);

  final authorization =
      'AWS4-HMAC-SHA256 Credential=$cleanAccessKey/$credentialScope, '
      'SignedHeaders=$signedHeaders, Signature=$signature';

  final wireHeaders = <String, String>{
    for (final k in sortedHeaderKeys) k: canonicalMap[k]!,
    'Authorization': authorization,
  };

  return SignedS3Request(
    target: target,
    method: cleanMethod,
    amzDate: amzDate,
    dateStamp: dateStamp,
    payloadSha256: payloadSha256,
    canonicalRequest: canonicalRequest,
    stringToSign: stringToSign,
    signature: signature,
    authorization: authorization,
    headers: Map<String, String>.unmodifiable(wireHeaders),
  );
}

/// Single object entry parsed from S3 `ListObjectsV2` (`ListBucketResult`) XML.
final class S3ListedObject {
  const S3ListedObject({
    required this.key,
    required this.sizeBytes,
    required this.lastModifiedMs,
    this.etag,
  });

  final String key;
  final int sizeBytes;
  final int lastModifiedMs;
  final String? etag;
}

/// Parsed page from S3 `GET ?list-type=2` XML response.
final class S3ListObjectsPage {
  const S3ListObjectsPage({
    required this.objects,
    required this.isTruncated,
    this.nextContinuationToken,
  });

  final List<S3ListedObject> objects;
  final bool isTruncated;
  final String? nextContinuationToken;
}

/// Parses S3 `ListObjectsV2` XML (`<ListBucketResult>`) namespace-agnostically.
S3ListObjectsPage parseS3ListObjectsV2Xml(String xml) {
  final isTruncatedRaw = _extractXmlTag(xml, 'IsTruncated');
  final isTruncated = isTruncatedRaw?.toLowerCase() == 'true';
  final nextToken = _extractXmlTag(xml, 'NextContinuationToken');

  final contentBlocks = RegExp(
    r'<(?:[A-Za-z0-9_-]+:)?Contents\b[^>]*>([\s\S]*?)</(?:[A-Za-z0-9_-]+:)?Contents>',
    caseSensitive: false,
  ).allMatches(xml);

  final items = <S3ListedObject>[];
  for (final match in contentBlocks) {
    final block = match.group(1) ?? '';
    final key = _extractXmlTag(block, 'Key');
    if (key == null || key.isEmpty) continue;
    final sizeText = _extractXmlTag(block, 'Size');
    final sizeBytes = int.tryParse(sizeText ?? '') ?? 0;
    final lastModText = _extractXmlTag(block, 'LastModified');
    final lastModifiedMs = lastModText != null
        ? (DateTime.tryParse(lastModText)?.millisecondsSinceEpoch ?? 0)
        : 0;
    final rawEtag = _extractXmlTag(block, 'ETag');
    final cleanEtag = rawEtag?.replaceAll('"', '').trim();

    items.add(
      S3ListedObject(
        key: key,
        sizeBytes: sizeBytes < 0 ? 0 : sizeBytes,
        lastModifiedMs: lastModifiedMs,
        etag: cleanEtag == null || cleanEtag.isEmpty ? null : cleanEtag,
      ),
    );
  }

  return S3ListObjectsPage(
    objects: items,
    isTruncated: isTruncated,
    nextContinuationToken: nextToken == null || nextToken.isEmpty
        ? null
        : nextToken,
  );
}

String? _extractXmlTag(String xmlBlock, String localName) {
  final pattern = RegExp(
    '<(?:[A-Za-z0-9_-]+:)?$localName\\b[^>]*>([\\s\\S]*?)</(?:[A-Za-z0-9_-]+:)?$localName>',
    caseSensitive: false,
  );
  final raw = pattern.firstMatch(xmlBlock)?.group(1);
  if (raw == null) return null;
  return _unescapeXml(raw.trim());
}

String _unescapeXml(String input) {
  return input
      .replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
        final code = int.tryParse(m.group(1)!, radix: 16);
        return code == null ? m.group(0)! : String.fromCharCode(code);
      })
      .replaceAllMapped(RegExp(r'&#([0-9]+);'), (m) {
        final code = int.tryParse(m.group(1)!);
        return code == null ? m.group(0)! : String.fromCharCode(code);
      })
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&');
}
