import 'dart:convert';
import 'dart:math';

import '../../core/failure.dart';

/// `ti_preference` key storing serialized [McpServerConfig] JSON (`F-039`).
const String prefKeyMcpServerConfig = 'mcp_server_config';

/// Default localhost port for TallyIsle's embedded Streamable HTTP MCP server.
const int defaultMcpPort = 39179;

/// Minimum allowed non-privileged TCP port for user configuration.
const int minMcpPort = 1024;

/// Maximum allowed TCP port.
const int maxMcpPort = 65535;

/// Hard upper bound (`1 MiB`) on incoming HTTP request bodies (`HTTP 413`).
const int maxMcpRequestBodyBytes = 1024 * 1024;

/// Supported MCP Streamable HTTP protocol versions (newest first).
const List<String> supportedMcpProtocolVersions = <String>[
  '2025-06-18',
  '2025-03-26',
  '2024-11-05',
];

/// Default negotiated MCP protocol version when client sends an unknown version.
const String defaultMcpProtocolVersion = '2025-03-26';

/// Capability tier required by an individual MCP tool.
enum McpToolTier {
  /// Read-only query tools (available in all permission tiers).
  read,

  /// Non-destructive append/create tools (`readAppend` and `fullAccess`).
  append,

  /// Mutating/destructive tools (`fullAccess` only).
  full,
}

/// User-selectable permission boundary for external AI Agents (`F-039`).
enum McpPermissionTier {
  readOnly('read_only', '仅只读'),
  readAppend('read_append', '查询 + 新增'),
  fullAccess('full_access', '完整读写');

  const McpPermissionTier(this.wireName, this.label);

  final String wireName;
  final String label;

  String get key => wireName;

  String get description => switch (this) {
    McpPermissionTier.readOnly => '仅开放账本、账户、流水、预算与统计只读查询，拦截全部写入与删改工具。',
    McpPermissionTier.readAppend =>
      '开放只读查询及新建账单、待确认草稿、便签、心愿、分类/标签，禁止修改或删除已有数据。',
    McpPermissionTier.fullAccess => '开放全部查询、新增、改单、退款、报销、预算配置与删单能力，请仅授权可信智能体。',
  };

  bool get canAppend =>
      this == McpPermissionTier.readAppend ||
      this == McpPermissionTier.fullAccess;

  bool get canFullMutate => this == McpPermissionTier.fullAccess;

  bool allows(McpToolTier toolTier) => switch (toolTier) {
    McpToolTier.read => true,
    McpToolTier.append => canAppend,
    McpToolTier.full => canFullMutate,
  };

  static McpPermissionTier fromWire(Object? raw) {
    if (raw is String) {
      final normalized = raw.trim().toLowerCase();
      for (final tier in values) {
        if (tier.wireName == normalized ||
            tier.name.toLowerCase() == normalized) {
          return tier;
        }
      }
    }
    return McpPermissionTier.readAppend;
  }
}

/// Minimum required [McpPermissionTier] for a [McpToolTier].
McpPermissionTier minimumTierForTool(McpToolTier toolTier) =>
    switch (toolTier) {
      McpToolTier.read => McpPermissionTier.readOnly,
      McpToolTier.append => McpPermissionTier.readAppend,
      McpToolTier.full => McpPermissionTier.fullAccess,
    };

/// Generates a 64-character lowercase hex Bearer token (256-bit entropy) using
/// `Random.secure()` CSPRNG.
String generateMcpAuthToken([Random? random]) {
  final rng = random ?? Random.secure();
  final buffer = StringBuffer();
  for (var i = 0; i < 32; i++) {
    final byte = rng.nextInt(256);
    buffer.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

/// Returns `true` when [port] is a valid non-privileged TCP port (`1024..65535`).
bool isValidMcpPort(int port) => port >= minMcpPort && port <= maxMcpPort;

/// Validates [port] (`1024..65535`), throwing a validation [Failure] otherwise.
int validateMcpPort(int port) {
  if (!isValidMcpPort(port)) {
    throw const Failure(FailureCode.validation, '端口号须在 1024 到 65535 之间');
  }
  return port;
}

/// Validates a human-readable port input string (`1024..65535`).
int parseAndValidateMcpPort(String raw) {
  final parsed = int.tryParse(raw.trim());
  if (parsed == null) {
    throw const Failure(FailureCode.validation, '请输入有效的整数端口号（1024–65535）');
  }
  return validateMcpPort(parsed);
}

bool _isValidStoredToken(String? raw) {
  if (raw == null) return false;
  final trimmed = raw.trim();
  if (trimmed.length < 32 || trimmed.length > 256) return false;
  for (final unit in trimmed.codeUnits) {
    if (unit <= 32 || unit >= 127) return false;
  }
  return true;
}

/// Persistent configuration for TallyIsle's embedded MCP server (`F-039`).
///
/// Stored exclusively as JSON in `ti_preference` (`key = 'mcp_server_config'`)
/// with ZERO database DDL changes.
final class McpServerConfig {
  McpServerConfig({
    this.enabled = false,
    this.port = defaultMcpPort,
    this.bindLan = false,
    bool requireAuth = true,
    String? authToken,
    this.permissionTier = McpPermissionTier.readAppend,
  }) : requireAuth = bindLan || requireAuth,
       authToken = _isValidStoredToken(authToken)
           ? authToken!.trim()
           : generateMcpAuthToken();

  final bool enabled;
  final int port;
  final bool bindLan;

  /// Whether Bearer token authentication is required.
  /// Always coerced to `true` whenever [bindLan] is `true`.
  final bool requireAuth;

  /// 64-character hex secret token generated via CSPRNG.
  final String authToken;

  /// Active tool exposure & execution boundary.
  final McpPermissionTier permissionTier;

  /// Effective bind address: `'0.0.0.0'` when [bindLan] is enabled, otherwise
  /// loopback `'127.0.0.1'`.
  String get bindAddress => bindLan ? '0.0.0.0' : '127.0.0.1';

  /// Effective auth gate: always `true` when [bindLan] is `true`.
  bool get effectiveRequireAuth => bindLan || requireAuth;

  /// Validates configuration invariants before persisting.
  void validate() {
    validateMcpPort(port);
    if (!_isValidStoredToken(authToken)) {
      throw const Failure(FailureCode.validation, 'MCP 访问令牌长度或格式无效');
    }
  }

  McpServerConfig copyWith({
    bool? enabled,
    int? port,
    bool? bindLan,
    bool? requireAuth,
    String? authToken,
    McpPermissionTier? permissionTier,
  }) {
    final nextBindLan = bindLan ?? this.bindLan;
    final nextRequireAuth = nextBindLan
        ? true
        : (requireAuth ?? this.requireAuth);
    return McpServerConfig(
      enabled: enabled ?? this.enabled,
      port: port ?? this.port,
      bindLan: nextBindLan,
      requireAuth: nextRequireAuth,
      authToken: authToken ?? this.authToken,
      permissionTier: permissionTier ?? this.permissionTier,
    );
  }

  Map<String, Object> toJson() => <String, Object>{
    'version': 1,
    'enabled': enabled,
    'port': port,
    'bind_lan': bindLan,
    'require_auth': effectiveRequireAuth,
    'auth_token': authToken,
    'permission_tier': permissionTier.wireName,
  };

  String encode() => jsonEncode(toJson());

  factory McpServerConfig.fromJson(
    Map<String, Object?> json, {
    String Function()? tokenGenerator,
  }) {
    final enabled = json['enabled'] == true;
    final rawPort = switch (json['port']) {
      final int p => p,
      final num n => n.toInt(),
      final String s => int.tryParse(s.trim()),
      _ => null,
    };
    final port = (rawPort != null && isValidMcpPort(rawPort))
        ? rawPort
        : defaultMcpPort;
    final bindLan = (json['bind_lan'] ?? json['bindLan']) == true;
    final rawRequireAuth = json['require_auth'] ?? json['requireAuth'];
    final requireAuth = bindLan
        ? true
        : (rawRequireAuth is bool ? rawRequireAuth : true);
    final rawToken = (json['auth_token'] ?? json['authToken']) as String?;
    final token = _isValidStoredToken(rawToken)
        ? rawToken!.trim()
        : (tokenGenerator != null ? tokenGenerator() : generateMcpAuthToken());
    final tier = McpPermissionTier.fromWire(
      json['permission_tier'] ?? json['permissionTier'],
    );
    return McpServerConfig(
      enabled: enabled,
      port: port,
      bindLan: bindLan,
      requireAuth: requireAuth,
      authToken: token,
      permissionTier: tier,
    );
  }

  /// Decodes stored JSON from `ti_preference`, returning a valid default config
  /// when [raw] is null, empty, or malformed.
  ///
  /// Also reports via `(config, needsPersist)` in [decodeWithPersistenceCheck]
  /// whether `ti_preference` was missing/corrupt or lacked a valid token.
  static McpServerConfig decode(
    String? raw, {
    String Function()? tokenGenerator,
  }) => decodeWithPersistenceCheck(raw, tokenGenerator: tokenGenerator).$1;

  static (McpServerConfig, bool) decodeWithPersistenceCheck(
    String? raw, {
    String Function()? tokenGenerator,
  }) {
    if (raw == null || raw.trim().isEmpty) {
      return (
        McpServerConfig(
          authToken: tokenGenerator != null
              ? tokenGenerator()
              : generateMcpAuthToken(),
        ),
        true,
      );
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return (
          McpServerConfig(
            authToken: tokenGenerator != null
                ? tokenGenerator()
                : generateMcpAuthToken(),
          ),
          true,
        );
      }
      final map = <String, Object?>{
        for (final e in decoded.entries) '${e.key}': e.value,
      };
      final rawToken = (map['auth_token'] ?? map['authToken']) as String?;
      final hadValidToken = _isValidStoredToken(rawToken);
      final cfg = McpServerConfig.fromJson(map, tokenGenerator: tokenGenerator);
      return (cfg, !hadValidToken);
    } on FormatException {
      return (
        McpServerConfig(
          authToken: tokenGenerator != null
              ? tokenGenerator()
              : generateMcpAuthToken(),
        ),
        true,
      );
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is McpServerConfig &&
          other.enabled == enabled &&
          other.port == port &&
          other.bindLan == bindLan &&
          other.requireAuth == requireAuth &&
          other.authToken == authToken &&
          other.permissionTier == permissionTier);

  @override
  int get hashCode => Object.hash(
    enabled,
    port,
    bindLan,
    requireAuth,
    authToken,
    permissionTier,
  );
}

/// Constant-time UTF-8 byte comparison to prevent timing side-channel leaks
/// when verifying Bearer tokens over LAN.
bool constantTimeTokenEquals(String expected, String provided) {
  final a = utf8.encode(expected);
  final b = utf8.encode(provided);
  if (a.isEmpty) return false;
  var diff = a.length ^ b.length;
  final maxLen = a.length > b.length ? a.length : b.length;
  for (var i = 0; i < maxLen; i++) {
    final byteA = i < a.length ? a[i] : 0;
    final byteB = i < b.length ? b[i] : 0;
    diff |= byteA ^ byteB;
  }
  return diff == 0;
}

/// Extracts a Bearer token from HTTP request headers (case-insensitive).
///
/// Accepts either:
/// - `Authorization: Bearer <token>`
/// - `X-MCP-Token: <token>`
String? extractMcpAuthToken(Map<String, String> headers) {
  String? headerValue(String targetLower) {
    final direct = headers[targetLower];
    if (direct != null) return direct;
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == targetLower) {
        return entry.value;
      }
    }
    return null;
  }

  final auth = headerValue('authorization')?.trim();
  if (auth != null && auth.isNotEmpty) {
    final match = RegExp(
      r'^bearer\s+(.+)$',
      caseSensitive: false,
    ).firstMatch(auth);
    if (match != null) {
      final token = match.group(1)!.trim();
      if (token.isNotEmpty) return token;
    }
  }

  final fallback = headerValue('x-mcp-token')?.trim();
  if (fallback != null && fallback.isNotEmpty) {
    return fallback;
  }
  return null;
}

/// Verifies incoming HTTP headers against [config]'s auth settings.
bool verifyMcpRequestAuth({
  required McpServerConfig config,
  required Map<String, String> headers,
}) {
  if (!config.effectiveRequireAuth) return true;
  final provided = extractMcpAuthToken(headers);
  if (provided == null || provided.isEmpty) return false;
  return constantTimeTokenEquals(config.authToken, provided);
}

/// Masks a secret token for safe UI display (`abcd12••••••••••••ef90`).
String maskMcpToken(String token) {
  final trimmed = token.trim();
  if (trimmed.length <= 12) return '••••••••••••';
  return '${trimmed.substring(0, 6)}••••••••••••${trimmed.substring(trimmed.length - 4)}';
}

/// Negotiates the MCP protocol version with the connecting client.
String negotiateMcpProtocolVersion(String? requestedVersion) {
  final trimmed = requestedVersion?.trim();
  if (trimmed != null && supportedMcpProtocolVersions.contains(trimmed)) {
    return trimmed;
  }
  return defaultMcpProtocolVersion;
}

/// Builds a standard MCP client configuration JSON snippet compatible with
/// Claude Code, Cursor, Cherry Studio, Cline, and Streamable HTTP clients.
String buildMcpClientConfigJson({
  required String endpointUrl,
  String? bearerToken,
}) {
  final cleanUrl = endpointUrl.trim();
  if (cleanUrl.isEmpty) {
    throw const Failure(FailureCode.validation, 'MCP 服务地址不能为空');
  }
  final cleanToken = bearerToken?.trim();
  final serverEntry = <String, Object>{
    'type': 'streamable-http',
    'url': cleanUrl,
    if (cleanToken != null && cleanToken.isNotEmpty)
      'headers': <String, String>{'Authorization': 'Bearer $cleanToken'},
  };
  final root = <String, Object>{
    'mcpServers': <String, Object>{'tallyisle': serverEntry},
  };
  return const JsonEncoder.withIndent('  ').convert(root);
}

// ---------------------------------------------------------------------------
// JSON-RPC 2.0 Validation & Framing
// ---------------------------------------------------------------------------

abstract final class JsonRpcErrorCode {
  static const int parseError = -32700;
  static const int invalidRequest = -32600;
  static const int methodNotFound = -32601;
  static const int invalidParams = -32602;
  static const int internalError = -32603;
  static const int unauthorized = -32001;
}

/// Validated JSON-RPC 2.0 request or notification frame.
final class ValidatedJsonRpcRequest {
  const ValidatedJsonRpcRequest({
    required this.id,
    required this.isNotification,
    required this.method,
    required this.params,
  });

  final Object? id;
  final bool isNotification;
  final String method;
  final Map<String, Object?> params;
}

/// Outcome of validating a decoded JSON-RPC 2.0 object.
final class JsonRpcValidationResult {
  const JsonRpcValidationResult._({this.request, this.errorResponse});

  const JsonRpcValidationResult.ok(ValidatedJsonRpcRequest req)
    : this._(request: req);

  const JsonRpcValidationResult.error(Map<String, Object?> err)
    : this._(errorResponse: err);

  final ValidatedJsonRpcRequest? request;
  final Map<String, Object?>? errorResponse;

  bool get isValid => request != null;
}

bool _isValidJsonRpcId(Object? id) {
  if (id == null || id is String || id is int) return true;
  if (id is num) return id.isFinite;
  return false;
}

/// Validates a single decoded JSON value against JSON-RPC 2.0 framing rules.
JsonRpcValidationResult validateJsonRpcObject(Object? decoded) {
  if (decoded is! Map) {
    return JsonRpcValidationResult.error(
      buildJsonRpcError(
        id: null,
        code: JsonRpcErrorCode.invalidRequest,
        message: 'Invalid Request: expected JSON object',
      ),
    );
  }

  final hasId = decoded.containsKey('id');
  final rawId = hasId ? decoded['id'] : null;
  if (hasId && !_isValidJsonRpcId(rawId)) {
    return JsonRpcValidationResult.error(
      buildJsonRpcError(
        id: null,
        code: JsonRpcErrorCode.invalidRequest,
        message: 'Invalid Request: id must be string, number, or null',
      ),
    );
  }

  if (decoded['jsonrpc'] != '2.0') {
    return JsonRpcValidationResult.error(
      buildJsonRpcError(
        id: rawId,
        code: JsonRpcErrorCode.invalidRequest,
        message: 'Invalid Request: jsonrpc must be "2.0"',
      ),
    );
  }

  final method = decoded['method'];
  if (method is! String || method.trim().isEmpty) {
    return JsonRpcValidationResult.error(
      buildJsonRpcError(
        id: rawId,
        code: JsonRpcErrorCode.invalidRequest,
        message: 'Invalid Request: method must be a non-empty string',
      ),
    );
  }

  Map<String, Object?> paramsMap = const <String, Object?>{};
  if (decoded.containsKey('params') && decoded['params'] != null) {
    final rawParams = decoded['params'];
    if (rawParams is Map) {
      paramsMap = <String, Object?>{
        for (final entry in rawParams.entries) '${entry.key}': entry.value,
      };
    } else if (rawParams is List) {
      return JsonRpcValidationResult.error(
        buildJsonRpcError(
          id: rawId,
          code: JsonRpcErrorCode.invalidParams,
          message: 'Invalid params: MCP methods require named object params',
        ),
      );
    } else {
      return JsonRpcValidationResult.error(
        buildJsonRpcError(
          id: rawId,
          code: JsonRpcErrorCode.invalidRequest,
          message: 'Invalid Request: params must be an object',
        ),
      );
    }
  }

  return JsonRpcValidationResult.ok(
    ValidatedJsonRpcRequest(
      id: rawId,
      isNotification: !hasId,
      method: method.trim(),
      params: paramsMap,
    ),
  );
}

/// Builds a JSON-RPC 2.0 success response object.
Map<String, Object?> buildJsonRpcResult({
  required Object? id,
  required Object? result,
}) => <String, Object?>{'jsonrpc': '2.0', 'id': id, 'result': result};

/// Builds a JSON-RPC 2.0 error response object.
Map<String, Object?> buildJsonRpcError({
  required Object? id,
  required int code,
  required String message,
  Object? data,
}) => <String, Object?>{
  'jsonrpc': '2.0',
  'id': id,
  'error': <String, Object?>{
    'code': code,
    'message': message,
    if (data != null) 'data': data,
  },
};
