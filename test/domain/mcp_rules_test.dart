import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/domain/rules/mcp_rules.dart';

void main() {
  group('McpPermissionTier & McpServerConfig (F-039)', () {
    test('exposes canonical preference key and permission tier matrix', () {
      expect(prefKeyMcpServerConfig, 'mcp_server_config');
      expect(McpPermissionTier.readOnly.wireName, 'read_only');
      expect(McpPermissionTier.readOnly.label, '仅只读');
      expect(McpPermissionTier.readAppend.wireName, 'read_append');
      expect(McpPermissionTier.readAppend.label, '查询 + 新增');
      expect(McpPermissionTier.fullAccess.wireName, 'full_access');
      expect(McpPermissionTier.fullAccess.label, '完整读写');

      expect(McpPermissionTier.readOnly.allows(McpToolTier.read), isTrue);
      expect(McpPermissionTier.readOnly.allows(McpToolTier.append), isFalse);
      expect(McpPermissionTier.readOnly.allows(McpToolTier.full), isFalse);

      expect(McpPermissionTier.readAppend.allows(McpToolTier.read), isTrue);
      expect(McpPermissionTier.readAppend.allows(McpToolTier.append), isTrue);
      expect(McpPermissionTier.readAppend.allows(McpToolTier.full), isFalse);

      expect(McpPermissionTier.fullAccess.allows(McpToolTier.read), isTrue);
      expect(McpPermissionTier.fullAccess.allows(McpToolTier.append), isTrue);
      expect(McpPermissionTier.fullAccess.allows(McpToolTier.full), isTrue);

      expect(
        McpPermissionTier.fromWire('unknown_value'),
        McpPermissionTier.readAppend,
      );
      expect(
        McpPermissionTier.fromWire('FULL_ACCESS'),
        McpPermissionTier.fullAccess,
      );
    });

    test(
      'default config is disabled, loopback-only, auth-enabled, 64-hex token',
      () {
        final cfg = McpServerConfig();
        expect(cfg.enabled, isFalse);
        expect(cfg.port, 39179);
        expect(cfg.bindLan, isFalse);
        expect(cfg.bindAddress, '127.0.0.1');
        expect(cfg.requireAuth, isTrue);
        expect(cfg.effectiveRequireAuth, isTrue);
        expect(cfg.permissionTier, McpPermissionTier.readAppend);
        expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(cfg.authToken), isTrue);
      },
    );

    test('enforces requireAuth == true whenever bindLan == true', () {
      final direct = McpServerConfig(bindLan: true, requireAuth: false);
      expect(direct.bindAddress, '0.0.0.0');
      expect(direct.requireAuth, isTrue);
      expect(direct.effectiveRequireAuth, isTrue);

      final copied = McpServerConfig(
        bindLan: false,
        requireAuth: false,
      ).copyWith(bindLan: true);
      expect(copied.requireAuth, isTrue);

      final fromJson = McpServerConfig.fromJson(const <String, Object?>{
        'bind_lan': true,
        'require_auth': false,
        'port': 40123,
      });
      expect(fromJson.bindLan, isTrue);
      expect(fromJson.requireAuth, isTrue);
      expect(fromJson.port, 40123);
    });

    test('validates TCP port boundaries (1024..65535)', () {
      expect(isValidMcpPort(1023), isFalse);
      expect(isValidMcpPort(1024), isTrue);
      expect(isValidMcpPort(39179), isTrue);
      expect(isValidMcpPort(65535), isTrue);
      expect(isValidMcpPort(65536), isFalse);

      expect(() => validateMcpPort(80), throwsA(isA<Failure>()));
      expect(() => parseAndValidateMcpPort('abc'), throwsA(isA<Failure>()));
      expect(parseAndValidateMcpPort(' 39179 '), 39179);
    });

    test(
      'JSON round-trip and decodeWithPersistenceCheck preserve token stability',
      () {
        final deterministicToken = generateMcpAuthToken(Random(42));
        expect(deterministicToken, hasLength(64));

        final (
          fresh,
          needsPersistFresh,
        ) = McpServerConfig.decodeWithPersistenceCheck(
          null,
          tokenGenerator: () => deterministicToken,
        );
        expect(needsPersistFresh, isTrue);
        expect(fresh.authToken, deterministicToken);

        final encoded = fresh
            .copyWith(
              enabled: true,
              port: 45000,
              permissionTier: McpPermissionTier.readOnly,
            )
            .encode();
        final (reloaded, needsPersistReloaded) =
            McpServerConfig.decodeWithPersistenceCheck(encoded);
        expect(needsPersistReloaded, isFalse);
        expect(reloaded.enabled, isTrue);
        expect(reloaded.port, 45000);
        expect(reloaded.authToken, deterministicToken);
        expect(reloaded.permissionTier, McpPermissionTier.readOnly);
      },
    );
  });

  group('Token Security & Client Config Builder', () {
    test(
      'constantTimeTokenEquals handles matching, mismatching, and length diffs',
      () {
        const token =
            '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
        expect(constantTimeTokenEquals(token, token), isTrue);
        expect(
          constantTimeTokenEquals(
            token,
            '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdee',
          ),
          isFalse,
        );
        expect(constantTimeTokenEquals(token, 'short'), isFalse);
        expect(constantTimeTokenEquals('', ''), isFalse);
      },
    );

    test(
      'extractMcpAuthToken supports Authorization Bearer and X-MCP-Token',
      () {
        expect(
          extractMcpAuthToken(const <String, String>{
            'Authorization': 'Bearer secret-token-123',
          }),
          'secret-token-123',
        );
        expect(
          extractMcpAuthToken(const <String, String>{
            'authorization': 'bearer   another_token  ',
          }),
          'another_token',
        );
        expect(
          extractMcpAuthToken(const <String, String>{
            'X-MCP-Token': 'header-fallback-token',
          }),
          'header-fallback-token',
        );
        expect(
          extractMcpAuthToken(const <String, String>{
            'Authorization': 'Basic dXNlcjpwYXNz',
          }),
          isNull,
        );
      },
    );

    test(
      'buildMcpClientConfigJson outputs standard mcpServers.tallyisle JSON',
      () {
        final withAuth =
            jsonDecode(
                  buildMcpClientConfigJson(
                    endpointUrl: 'http://127.0.0.1:39179/mcp',
                    bearerToken: 'tok_abc123',
                  ),
                )
                as Map<String, Object?>;
        final servers = withAuth['mcpServers']! as Map<String, Object?>;
        final tally = servers['tallyisle']! as Map<String, Object?>;
        expect(tally['type'], 'streamable-http');
        expect(tally['url'], 'http://127.0.0.1:39179/mcp');
        expect(tally['headers'], <String, Object?>{
          'Authorization': 'Bearer tok_abc123',
        });

        final noAuth =
            jsonDecode(
                  buildMcpClientConfigJson(
                    endpointUrl: 'http://127.0.0.1:39179/mcp',
                  ),
                )
                as Map<String, Object?>;
        final tallyNoAuth =
            (noAuth['mcpServers']! as Map<String, Object?>)['tallyisle']!
                as Map<String, Object?>;
        expect(tallyNoAuth.containsKey('headers'), isFalse);
      },
    );
  });

  group('JSON-RPC 2.0 & Protocol Negotiation', () {
    test('negotiateMcpProtocolVersion echoes supported versions', () {
      expect(negotiateMcpProtocolVersion('2025-06-18'), '2025-06-18');
      expect(negotiateMcpProtocolVersion('2025-03-26'), '2025-03-26');
      expect(negotiateMcpProtocolVersion('2024-11-05'), '2024-11-05');
      expect(negotiateMcpProtocolVersion('1999-01-01'), '2025-03-26');
      expect(negotiateMcpProtocolVersion(null), '2025-03-26');
    });

    test(
      'validateJsonRpcObject accepts valid requests & notifications and rejects malformed frames',
      () {
        final okReq = validateJsonRpcObject(const <String, Object?>{
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'tools/list',
        });
        expect(okReq.isValid, isTrue);
        expect(okReq.request!.isNotification, isFalse);
        expect(okReq.request!.id, 1);

        final okNotif = validateJsonRpcObject(const <String, Object?>{
          'jsonrpc': '2.0',
          'method': 'notifications/initialized',
        });
        expect(okNotif.isValid, isTrue);
        expect(okNotif.request!.isNotification, isTrue);

        final badVersion = validateJsonRpcObject(const <String, Object?>{
          'jsonrpc': '1.0',
          'id': 'a',
          'method': 'ping',
        });
        expect(badVersion.isValid, isFalse);
        expect(
          (badVersion.errorResponse!['error']! as Map)['code'],
          JsonRpcErrorCode.invalidRequest,
        );

        final arrayParams = validateJsonRpcObject(const <String, Object?>{
          'jsonrpc': '2.0',
          'id': 2,
          'method': 'tools/call',
          'params': <Object>[1, 2],
        });
        expect(arrayParams.isValid, isFalse);
        expect(
          (arrayParams.errorResponse!['error']! as Map)['code'],
          JsonRpcErrorCode.invalidParams,
        );
      },
    );
  });
}
