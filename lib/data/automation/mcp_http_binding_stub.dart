import '../../core/failure.dart';
import 'mcp_http_binding.dart';

final class _UnsupportedMcpHttpBinding implements McpHttpBinding {
  const _UnsupportedMcpHttpBinding();

  @override
  bool get isSupported => false;

  @override
  Future<BoundMcpHttpServer> bind({
    required String host,
    required int port,
    required Future<McpHttpResponseData> Function(McpHttpRequestContext request)
    onRequest,
  }) => Future<BoundMcpHttpServer>.error(
    const Failure(FailureCode.unsupportedCapability, '当前浏览器环境不支持启动本地 MCP 监听服务'),
  );

  @override
  Future<List<String>> listLocalIpv4Addresses() async => const <String>[];
}

McpHttpBinding createPlatformMcpHttpBinding() =>
    const _UnsupportedMcpHttpBinding();
