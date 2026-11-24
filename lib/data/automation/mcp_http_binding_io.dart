import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../core/failure.dart';
import 'mcp_http_binding.dart';

final class _IoBoundMcpHttpServer implements BoundMcpHttpServer {
  _IoBoundMcpHttpServer({
    required HttpServer server,
    required this.host,
    required void Function(HttpRequest request) onHttpRequest,
  }) : _server = server,
       _subscription = server.listen(onHttpRequest, onError: (_) {});

  final HttpServer _server;
  final StreamSubscription<HttpRequest> _subscription;

  @override
  final String host;

  @override
  int get port => _server.port;

  @override
  Future<void> close({bool force = false}) async {
    await _subscription.cancel();
    await _server.close(force: force);
  }
}

final class _IoMcpHttpBinding implements McpHttpBinding {
  const _IoMcpHttpBinding();

  @override
  bool get isSupported => true;

  @override
  Future<BoundMcpHttpServer> bind({
    required String host,
    required int port,
    required Future<McpHttpResponseData> Function(McpHttpRequestContext request)
    onRequest,
  }) async {
    final HttpServer server;
    try {
      server = await HttpServer.bind(host, port);
    } on SocketException catch (e) {
      throw Failure(
        FailureCode.remoteUnavailable,
        '端口 $port 绑定失败（可能已被占用）：${e.message}',
      );
    }
    server.autoCompress = false;
    return _IoBoundMcpHttpServer(
      server: server,
      host: host,
      onHttpRequest: (HttpRequest req) =>
          unawaited(_handleHttpRequest(req, onRequest)),
    );
  }

  Future<void> _handleHttpRequest(
    HttpRequest request,
    Future<McpHttpResponseData> Function(McpHttpRequestContext request)
    onRequest,
  ) async {
    try {
      final headers = <String, String>{};
      request.headers.forEach((name, values) {
        if (values.isNotEmpty) {
          headers[name.toLowerCase()] = values.join(', ');
        }
      });

      Future<Uint8List> readWithLimit(int maxBytes) async {
        final declaredLen = request.contentLength;
        if (declaredLen > maxBytes) {
          throw McpPayloadTooLargeException(maxBytes);
        }
        final builder = BytesBuilder(copy: false);
        var total = 0;
        await for (final chunk in request) {
          total += chunk.length;
          if (total > maxBytes) {
            throw McpPayloadTooLargeException(maxBytes);
          }
          builder.add(chunk);
        }
        return builder.takeBytes();
      }

      final ctx = McpHttpRequestContext(
        method: request.method.toUpperCase(),
        path: request.uri.path,
        headers: headers,
        readBodyWithLimit: readWithLimit,
      );
      final responseData = await onRequest(ctx);
      final res = request.response..statusCode = responseData.statusCode;
      for (final entry in responseData.headers.entries) {
        res.headers.set(entry.key, entry.value);
      }
      final body = responseData.body;
      if (body != null && body.isNotEmpty) {
        final encoded = utf8.encode(body);
        res.contentLength = encoded.length;
        res.add(encoded);
      } else {
        res.contentLength = 0;
      }
      await res.close();
    } catch (_) {
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {}
    }
  }

  @override
  Future<List<String>> listLocalIpv4Addresses() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      final seen = <String>{};
      final out = <String>[];
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (addr.isLoopback || addr.isLinkLocal) continue;
          final ip = addr.address.trim();
          if (ip.isEmpty || ip == '127.0.0.1' || ip == '0.0.0.0') continue;
          if (seen.add(ip)) {
            out.add(ip);
          }
        }
      }
      out.sort((a, b) {
        final rankCmp = _lanAddressRank(a).compareTo(_lanAddressRank(b));
        return rankCmp != 0 ? rankCmp : a.compareTo(b);
      });
      return out;
    } catch (_) {
      return const <String>[];
    }
  }

  static int _lanAddressRank(String ip) {
    if (ip.startsWith('192.168.')) return 0;
    if (ip.startsWith('10.')) return 1;
    final parts = ip.split('.');
    if (parts.length == 4 && parts[0] == '172') {
      final second = int.tryParse(parts[1]) ?? -1;
      if (second >= 16 && second <= 31) return 2;
    }
    return 3;
  }
}

McpHttpBinding createPlatformMcpHttpBinding() => const _IoMcpHttpBinding();
