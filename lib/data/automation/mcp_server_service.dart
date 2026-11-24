import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../../core/app_version.dart';
import '../../core/failure.dart';
import '../../domain/rules/mcp_rules.dart';
import '../db/database.dart';
import '../db/failures.dart';
import 'mcp_http_binding.dart';
import 'mcp_tool_dispatcher.dart';

/// Live runtime telemetry of the embedded Streamable HTTP MCP listener (`F-039`).
final class McpRuntimeStatus {
  const McpRuntimeStatus({
    this.isRunning = false,
    this.boundHost = '127.0.0.1',
    this.port = defaultMcpPort,
    this.lanIps = const <String>[],
    this.requestCount = 0,
    this.lastRequestAtMs,
    this.lastError,
    this.isPlatformSupported = true,
  });

  final bool isRunning;
  final String boundHost;
  final int port;
  final List<String> lanIps;
  final int requestCount;
  final int? lastRequestAtMs;
  final String? lastError;
  final bool isPlatformSupported;

  String get loopbackEndpointUrl => 'http://127.0.0.1:$port/mcp';

  List<String> get lanEndpointUrls => <String>[
    for (final ip in lanIps) 'http://$ip:$port/mcp',
  ];

  String get preferredClientEndpointUrl =>
      (boundHost == '0.0.0.0' && lanIps.isNotEmpty)
      ? 'http://${lanIps.first}:$port/mcp'
      : loopbackEndpointUrl;

  McpRuntimeStatus copyWith({
    bool? isRunning,
    String? boundHost,
    int? port,
    List<String>? lanIps,
    int? requestCount,
    int? lastRequestAtMs,
    String? lastError,
    bool clearError = false,
    bool? isPlatformSupported,
  }) => McpRuntimeStatus(
    isRunning: isRunning ?? this.isRunning,
    boundHost: boundHost ?? this.boundHost,
    port: port ?? this.port,
    lanIps: lanIps ?? this.lanIps,
    requestCount: requestCount ?? this.requestCount,
    lastRequestAtMs: lastRequestAtMs ?? this.lastRequestAtMs,
    lastError: clearError ? null : (lastError ?? this.lastError),
    isPlatformSupported: isPlatformSupported ?? this.isPlatformSupported,
  );
}

/// Manages `McpServerConfig` in `ti_preference`, binds/rebinds/closes the
/// embedded Streamable HTTP listener, enforces Bearer auth & `1 MiB` payload
/// limits, and broadcasts [McpRuntimeStatus] (`F-039`).
final class McpServerService {
  McpServerService(
    this.db, {
    McpHttpBinding? httpBinding,
    McpToolDispatcher? dispatcher,
    this.bindPortOverride,
  }) : _binding = httpBinding ?? createMcpHttpBinding(),
       _dispatcher = dispatcher ?? McpToolDispatcher(db) {
    _status = McpRuntimeStatus(isPlatformSupported: _binding.isSupported);
  }

  final AppDatabase db;
  final McpHttpBinding _binding;
  final McpToolDispatcher _dispatcher;

  /// Optional port override (e.g. `0` in tests to bind an OS ephemeral port).
  final int? bindPortOverride;

  final StreamController<McpRuntimeStatus> _statusController =
      StreamController<McpRuntimeStatus>.broadcast();

  late McpRuntimeStatus _status;
  McpServerConfig? _activeConfig;
  BoundMcpHttpServer? _server;
  Future<McpServerConfig>? _initConfigFuture;
  Future<void> _lifecycleChain = Future<void>.value();
  bool _disposed = false;

  McpRuntimeStatus get currentStatus => _status;

  bool get isPlatformSupported => _binding.isSupported;

  /// Yields the current [McpRuntimeStatus] immediately and streams subsequent changes.
  Stream<McpRuntimeStatus> watchRuntimeStatus() async* {
    yield _status;
    yield* _statusController.stream;
  }

  void _emitStatus(McpRuntimeStatus next) {
    _status = next;
    if (!_disposed && !_statusController.isClosed) {
      _statusController.add(next);
    }
  }

  /// Loads [McpServerConfig] from `ti_preference` (`mcp_server_config`).
  ///
  /// Automatically persists the initial CSPRNG `authToken` on first read so it
  /// remains stable across app restarts and UI refreshes.
  Future<McpServerConfig> getConfig() {
    final inflight = _initConfigFuture;
    if (inflight != null) return inflight;
    final future = _loadAndEnsurePersisted().whenComplete(() {
      _initConfigFuture = null;
    });
    _initConfigFuture = future;
    return future;
  }

  Future<McpServerConfig> _loadAndEnsurePersisted() => guardDatabase(() async {
    final row = await (db.select(
      db.preferences,
    )..where((t) => t.key.equals(prefKeyMcpServerConfig))).getSingleOrNull();
    final (config, needsPersist) = McpServerConfig.decodeWithPersistenceCheck(
      row?.value,
    );
    if (needsPersist) {
      await db
          .into(db.preferences)
          .insertOnConflictUpdate(
            PreferencesCompanion.insert(
              key: prefKeyMcpServerConfig,
              value: config.encode(),
            ),
          );
    }
    _activeConfig = config;
    return config;
  });

  /// Watches [McpServerConfig] reactively from `ti_preference`.
  Stream<McpServerConfig> watchConfig() async* {
    final initial = await getConfig();
    yield initial;
    yield* (db.select(db.preferences)
          ..where((t) => t.key.equals(prefKeyMcpServerConfig)))
        .watchSingleOrNull()
        .map((row) {
          final decoded = McpServerConfig.decode(
            row?.value,
            tokenGenerator: () => initial.authToken,
          );
          _activeConfig = decoded;
          return decoded;
        });
  }

  /// Refreshes detected local IPv4 LAN addresses.
  Future<List<String>> refreshLanIps() async {
    final ips = await _binding.listLocalIpv4Addresses();
    _emitStatus(_status.copyWith(lanIps: ips));
    return ips;
  }

  /// Saves [config] into `ti_preference` (with optional idempotent [commandId])
  /// and synchronizes the HTTP listener state.
  Future<McpServerConfig> saveConfig(
    McpServerConfig config, {
    String? commandId,
  }) async {
    config.validate();
    final normalized = config.copyWith();

    await guardDatabase(
      () => db.transaction(() async {
        if (commandId != null) {
          if (commandId.isEmpty || commandId.length > 128) {
            throw const Failure(FailureCode.validation, '提交标识无效');
          }
          final hash = sha256
              .convert(
                utf8.encode(
                  jsonEncode(['mcp-save-cfg-v1', normalized.toJson()]),
                ),
              )
              .toString();
          final prev = await (db.select(
            db.writeCommands,
          )..where((t) => t.commandId.equals(commandId))).getSingleOrNull();
          if (prev != null) {
            if (prev.payloadHash != hash) {
              throw const Failure(FailureCode.conflict, '同一提交标识的内容发生变化');
            }
            return;
          }
          await db
              .into(db.writeCommands)
              .insert(
                WriteCommandsCompanion.insert(
                  commandId: commandId,
                  payloadHash: hash,
                  resultId: prefKeyMcpServerConfig,
                  committedAt: db.nowMs(),
                ),
              );
        }

        await db
            .into(db.preferences)
            .insertOnConflictUpdate(
              PreferencesCompanion.insert(
                key: prefKeyMcpServerConfig,
                value: normalized.encode(),
              ),
            );
      }),
    );

    _activeConfig = normalized;
    await _enqueueLifecycle(() => _applyConfigToServer(normalized));
    return normalized;
  }

  Future<McpServerConfig> setEnabled(bool enabled, {String? commandId}) async {
    final current = await getConfig();
    return saveConfig(current.copyWith(enabled: enabled), commandId: commandId);
  }

  Future<McpServerConfig> setPermissionTier(
    McpPermissionTier tier, {
    String? commandId,
  }) async {
    final current = await getConfig();
    return saveConfig(
      current.copyWith(permissionTier: tier),
      commandId: commandId,
    );
  }

  Future<McpServerConfig> setBindLan(bool bindLan, {String? commandId}) async {
    final current = await getConfig();
    return saveConfig(
      current.copyWith(
        bindLan: bindLan,
        requireAuth: bindLan ? true : current.requireAuth,
      ),
      commandId: commandId,
    );
  }

  Future<McpServerConfig> setPort(int port, {String? commandId}) async {
    validateMcpPort(port);
    final current = await getConfig();
    return saveConfig(current.copyWith(port: port), commandId: commandId);
  }

  Future<McpServerConfig> setRequireAuth(
    bool requireAuth, {
    String? commandId,
  }) async {
    final current = await getConfig();
    if (current.bindLan && !requireAuth) {
      throw const Failure(FailureCode.validation, '开启局域网监听时必须启用 Bearer 令牌鉴权');
    }
    return saveConfig(
      current.copyWith(requireAuth: requireAuth),
      commandId: commandId,
    );
  }

  Future<McpServerConfig> regenerateAuthToken({String? commandId}) async {
    final current = await getConfig();
    final nextToken = generateMcpAuthToken();
    return saveConfig(
      current.copyWith(authToken: nextToken),
      commandId: commandId,
    );
  }

  /// Synchronizes the running HTTP server with the config persisted in SQLite.
  Future<void> syncWithStoredConfig() async {
    if (_disposed) return;
    final config = await getConfig();
    await _enqueueLifecycle(() => _applyConfigToServer(config));
  }

  /// Stops any active HTTP listener without altering persisted `enabled` flag.
  Future<void> stop() => _enqueueLifecycle(() async {
    final existing = _server;
    _server = null;
    if (existing != null) {
      await existing.close(force: true);
    }
    final cfg = _activeConfig;
    _emitStatus(
      _status.copyWith(
        isRunning: false,
        boundHost: cfg?.bindAddress ?? _status.boundHost,
        port: cfg?.port ?? _status.port,
      ),
    );
  });

  /// Permanently stops the HTTP listener and closes internal streams.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _enqueueLifecycle(() async {
      final existing = _server;
      _server = null;
      if (existing != null) {
        await existing.close(force: true);
      }
    });
    await _statusController.close();
  }

  Future<void> _enqueueLifecycle(Future<void> Function() step) {
    final next = _lifecycleChain.then((_) => step());
    _lifecycleChain = next.catchError((_) {});
    return next;
  }

  Future<void> _applyConfigToServer(McpServerConfig config) async {
    if (_disposed) return;
    final lanIps = (config.enabled || config.bindLan)
        ? await _binding.listLocalIpv4Addresses()
        : _status.lanIps;

    if (!config.enabled) {
      final existing = _server;
      _server = null;
      if (existing != null) {
        await existing.close(force: true);
      }
      _emitStatus(
        _status.copyWith(
          isRunning: false,
          boundHost: config.bindAddress,
          port: config.port,
          lanIps: lanIps,
          clearError: true,
        ),
      );
      return;
    }

    if (!_binding.isSupported) {
      _emitStatus(
        _status.copyWith(
          isRunning: false,
          boundHost: config.bindAddress,
          port: config.port,
          lanIps: lanIps,
          lastError: '当前运行环境不支持本地 HTTP 监听服务',
        ),
      );
      return;
    }

    final targetHost = config.bindAddress;
    final desiredPort = bindPortOverride ?? config.port;
    final existing = _server;
    if (existing != null &&
        existing.host == targetHost &&
        (desiredPort == 0 || existing.port == desiredPort)) {
      _emitStatus(
        _status.copyWith(
          isRunning: true,
          boundHost: existing.host,
          port: existing.port,
          lanIps: lanIps,
          clearError: true,
        ),
      );
      return;
    }

    if (existing != null) {
      _server = null;
      await existing.close(force: true);
    }

    try {
      final bound = await _binding.bind(
        host: targetHost,
        port: desiredPort,
        onRequest: _handleHttpRequest,
      );
      if (_disposed) {
        await bound.close(force: true);
        return;
      }
      _server = bound;
      _emitStatus(
        _status.copyWith(
          isRunning: true,
          boundHost: bound.host,
          port: bound.port,
          lanIps: lanIps,
          clearError: true,
        ),
      );
    } on Failure catch (f) {
      _emitStatus(
        _status.copyWith(
          isRunning: false,
          boundHost: targetHost,
          port: config.port,
          lanIps: lanIps,
          lastError: f.message,
        ),
      );
    } catch (_) {
      _emitStatus(
        _status.copyWith(
          isRunning: false,
          boundHost: targetHost,
          port: config.port,
          lanIps: lanIps,
          lastError: '端口 ${config.port} 启动失败，请尝试更换端口',
        ),
      );
    }
  }

  static const Map<String, String> _jsonHeaders = <String, String>{
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
  };

  Future<McpHttpResponseData> _handleHttpRequest(
    McpHttpRequestContext req,
  ) async {
    final normalizedPath = req.path.length > 1 && req.path.endsWith('/')
        ? req.path.substring(0, req.path.length - 1)
        : req.path;

    if (normalizedPath == '/health') {
      if (req.method != 'GET') {
        return const McpHttpResponseData(
          statusCode: 405,
          headers: <String, String>{
            'allow': 'GET',
            'content-type': 'application/json; charset=utf-8',
          },
          body: '{"error":"Method Not Allowed"}',
        );
      }
      return McpHttpResponseData(
        statusCode: 200,
        headers: _jsonHeaders,
        body: jsonEncode(<String, Object>{
          'status': 'ok',
          'service': 'tallyisle-mcp',
          'version': appVersionName,
        }),
      );
    }

    if (normalizedPath != '/mcp') {
      return McpHttpResponseData(
        statusCode: 404,
        headers: _jsonHeaders,
        body: jsonEncode(<String, Object>{'error': 'Not Found'}),
      );
    }

    if (req.method == 'OPTIONS') {
      return const McpHttpResponseData(
        statusCode: 204,
        headers: <String, String>{'allow': 'POST, DELETE, OPTIONS'},
      );
    }

    final config = _activeConfig ?? await getConfig();
    if (!verifyMcpRequestAuth(config: config, headers: req.headers)) {
      return McpHttpResponseData(
        statusCode: 401,
        headers: <String, String>{
          ..._jsonHeaders,
          'www-authenticate': 'Bearer realm="tallyisle-mcp"',
        },
        body: jsonEncode(
          buildJsonRpcError(
            id: null,
            code: JsonRpcErrorCode.unauthorized,
            message: 'Unauthorized: valid Bearer token required',
          ),
        ),
      );
    }

    if (req.method == 'GET') {
      return McpHttpResponseData(
        statusCode: 405,
        headers: <String, String>{
          ..._jsonHeaders,
          'allow': 'POST, DELETE, OPTIONS',
        },
        body: jsonEncode(
          buildJsonRpcError(
            id: null,
            code: JsonRpcErrorCode.invalidRequest,
            message:
                'Method Not Allowed: stateless Streamable HTTP endpoint accepts POST /mcp',
          ),
        ),
      );
    }

    if (req.method == 'DELETE') {
      return McpHttpResponseData(
        statusCode: 200,
        headers: _jsonHeaders,
        body: jsonEncode(<String, Object>{'terminated': true}),
      );
    }

    if (req.method != 'POST') {
      return McpHttpResponseData(
        statusCode: 405,
        headers: <String, String>{
          ..._jsonHeaders,
          'allow': 'POST, DELETE, OPTIONS',
        },
        body: jsonEncode(<String, Object>{'error': 'Method Not Allowed'}),
      );
    }

    final Uint8List bodyBytes;
    try {
      bodyBytes = await req.readBodyWithLimit(maxMcpRequestBodyBytes);
    } on McpPayloadTooLargeException {
      return McpHttpResponseData(
        statusCode: 413,
        headers: _jsonHeaders,
        body: jsonEncode(
          buildJsonRpcError(
            id: null,
            code: JsonRpcErrorCode.invalidRequest,
            message: 'Payload Too Large: maximum body size is 1 MiB',
          ),
        ),
      );
    }

    final String rawBody;
    try {
      rawBody = utf8.decode(bodyBytes);
    } on FormatException {
      return McpHttpResponseData(
        statusCode: 400,
        headers: _jsonHeaders,
        body: jsonEncode(
          buildJsonRpcError(
            id: null,
            code: JsonRpcErrorCode.parseError,
            message: 'Parse error: invalid UTF-8 payload',
          ),
        ),
      );
    }

    final now = db.nowMs();
    _emitStatus(
      _status.copyWith(
        requestCount: _status.requestCount + 1,
        lastRequestAtMs: now,
      ),
    );

    final responsePayload = await _dispatcher.dispatchRawJson(
      rawBody,
      permissionTier: config.permissionTier,
    );
    if (responsePayload == null) {
      return const McpHttpResponseData(
        statusCode: 202,
        headers: <String, String>{'cache-control': 'no-store'},
      );
    }

    return McpHttpResponseData(
      statusCode: 200,
      headers: _jsonHeaders,
      body: jsonEncode(responsePayload),
    );
  }
}
