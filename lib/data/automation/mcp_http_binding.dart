import 'dart:typed_data';

import 'mcp_http_binding_stub.dart'
    if (dart.library.io) 'mcp_http_binding_io.dart';

/// Thrown when an incoming HTTP request body exceeds the configured byte limit.
final class McpPayloadTooLargeException implements Exception {
  const McpPayloadTooLargeException(this.maxBytes);

  final int maxBytes;
}

/// Platform-neutral view of an incoming HTTP request handled by `McpServerService`.
final class McpHttpRequestContext {
  const McpHttpRequestContext({
    required this.method,
    required this.path,
    required this.headers,
    required this.readBodyWithLimit,
  });

  final String method;
  final String path;
  final Map<String, String> headers;
  final Future<Uint8List> Function(int maxBytes) readBodyWithLimit;
}

/// Platform-neutral HTTP response returned by `McpServerService`.
final class McpHttpResponseData {
  const McpHttpResponseData({
    required this.statusCode,
    this.headers = const <String, String>{},
    this.body,
  });

  final int statusCode;
  final Map<String, String> headers;
  final String? body;
}

/// Handle to an active bound HTTP listener.
abstract interface class BoundMcpHttpServer {
  String get host;
  int get port;
  Future<void> close({bool force = false});
}

/// Conditional abstraction over `dart:io` `HttpServer` & `NetworkInterface` so
/// Web builds compile cleanly without `dart:io` (`F-039`, ADR-008).
abstract interface class McpHttpBinding {
  bool get isSupported;

  Future<BoundMcpHttpServer> bind({
    required String host,
    required int port,
    required Future<McpHttpResponseData> Function(McpHttpRequestContext request)
    onRequest,
  });

  Future<List<String>> listLocalIpv4Addresses();
}

/// Creates the platform-appropriate [McpHttpBinding].
McpHttpBinding createMcpHttpBinding() => createPlatformMcpHttpBinding();
