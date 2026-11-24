import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/app_version.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/automation/mcp_server_service.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/debt/debt_service.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/domain/ledger/record_extra.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/mcp_rules.dart';

final class _RawHttpReply {
  const _RawHttpReply({
    required this.statusCode,
    required this.headers,
    required this.body,
  });

  final int statusCode;
  final Map<String, String> headers;
  final String body;
}

Future<_RawHttpReply> _sendHttp({
  required HttpClient client,
  required String method,
  required Uri uri,
  Map<String, String> headers = const <String, String>{},
  List<int>? bodyBytes,
}) async {
  final req = await client.openUrl(method, uri);
  headers.forEach(req.headers.set);
  if (bodyBytes != null) {
    req.contentLength = bodyBytes.length;
    req.add(bodyBytes);
  }
  final res = await req.close();
  final respHeaders = <String, String>{};
  res.headers.forEach((k, v) {
    if (v.isNotEmpty) respHeaders[k.toLowerCase()] = v.join(', ');
  });
  final text = await utf8.decoder.bind(res).join();
  return _RawHttpReply(
    statusCode: res.statusCode,
    headers: respHeaders,
    body: text,
  );
}

Future<List<(String, String)>> _readSchemaSnapshot(AppDatabase db) async {
  final rows = await db
      .customSelect(
        "SELECT name, COALESCE(sql, '') AS sql FROM sqlite_master "
        "WHERE type IN ('table', 'index', 'trigger', 'view') "
        "AND name NOT LIKE 'sqlite_%' "
        'ORDER BY type, name',
      )
      .get();
  return <(String, String)>[
    for (final r in rows) (r.read<String>('name'), r.read<String>('sql')),
  ];
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test(
    'Embedded Streamable HTTP MCP Server: handshake, auth 401, 413 cap, tier gates, exact BigInt ledger writes, drafts, and zero-DDL check',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final httpClient = HttpClient();
      McpServerService? service;

      try {
        // Capture baseline SQLite schema BEFORE touching McpServerService.
        final baselineSchema = await _readSchemaSnapshot(db);
        final tableCountRow = await db
            .customSelect(
              "SELECT COUNT(*) AS n FROM sqlite_master "
              "WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
            )
            .getSingle();
        expect(tableCountRow.read<int>('n'), 24);

        final ledger = LedgerService(db);
        final cardAssetId = await ledger.createAsset(
          commandId: 'seed-asset-card',
          name: '招商储蓄卡',
          initial: Money.parse('1000.00'),
        );
        final walletAssetId = await ledger.createAsset(
          commandId: 'seed-asset-wallet',
          name: '微信零钱',
          initial: Money.parse('200.00'),
        );

        service = McpServerService(db, bindPortOverride: 0);

        // First getConfig() auto-persists generated 64-hex token in ti_preference.
        final initialCfg = await service.getConfig();
        expect(initialCfg.enabled, isFalse);
        expect(initialCfg.authToken, hasLength(64));
        final secondService = McpServerService(db, bindPortOverride: 0);
        final secondCfg = await secondService.getConfig();
        expect(secondCfg.authToken, initialCfg.authToken);
        await secondService.dispose();

        // Enable MCP server on 127.0.0.1 ephemeral port.
        await service.setEnabled(true, commandId: 'enable-mcp-1');
        final status = service.currentStatus;
        expect(status.isRunning, isTrue);
        expect(status.boundHost, '127.0.0.1');
        expect(status.port, greaterThan(0));

        final token = (await service.getConfig()).authToken;
        final mcpUri = Uri.parse('http://127.0.0.1:${status.port}/mcp');
        final healthUri = Uri.parse('http://127.0.0.1:${status.port}/health');

        Map<String, String> authHeaders([String? customToken]) =>
            <String, String>{
              'content-type': 'application/json',
              'authorization': 'Bearer ${customToken ?? token}',
            };

        Future<Map<String, Object?>> postRpc(
          Map<String, Object?> rpcBody, {
          String? customToken,
        }) async {
          final reply = await _sendHttp(
            client: httpClient,
            method: 'POST',
            uri: mcpUri,
            headers: authHeaders(customToken),
            bodyBytes: utf8.encode(jsonEncode(rpcBody)),
          );
          expect(reply.statusCode, 200);
          return jsonDecode(reply.body) as Map<String, Object?>;
        }

        // 1. Health check (200), unauthenticated POST /mcp (401), wrong token (401)
        final healthReply = await _sendHttp(
          client: httpClient,
          method: 'GET',
          uri: healthUri,
        );
        expect(healthReply.statusCode, 200);
        expect(
          (jsonDecode(healthReply.body) as Map)['service'],
          'tallyisle-mcp',
        );

        final unauthReply = await _sendHttp(
          client: httpClient,
          method: 'POST',
          uri: mcpUri,
          headers: const <String, String>{'content-type': 'application/json'},
          bodyBytes: utf8.encode('{"jsonrpc":"2.0","id":1,"method":"ping"}'),
        );
        expect(unauthReply.statusCode, 401);
        expect(unauthReply.headers['www-authenticate'], contains('Bearer'));

        final wrongTokenReply = await _sendHttp(
          client: httpClient,
          method: 'POST',
          uri: mcpUri,
          headers: authHeaders('wrong-token-value'),
          bodyBytes: utf8.encode('{"jsonrpc":"2.0","id":1,"method":"ping"}'),
        );
        expect(wrongTokenReply.statusCode, 401);

        // X-MCP-Token header also authenticates cleanly.
        final xTokenReply = await _sendHttp(
          client: httpClient,
          method: 'POST',
          uri: mcpUri,
          headers: <String, String>{
            'content-type': 'application/json',
            'x-mcp-token': token,
          },
          bodyBytes: utf8.encode('{"jsonrpc":"2.0","id":99,"method":"ping"}'),
        );
        expect(xTokenReply.statusCode, 200);

        // GET /mcp -> 405, DELETE /mcp -> 200, >1 MiB body -> 413
        final getMcpReply = await _sendHttp(
          client: httpClient,
          method: 'GET',
          uri: mcpUri,
          headers: authHeaders(),
        );
        expect(getMcpReply.statusCode, 405);

        final deleteMcpReply = await _sendHttp(
          client: httpClient,
          method: 'DELETE',
          uri: mcpUri,
          headers: authHeaders(),
        );
        expect(deleteMcpReply.statusCode, 200);

        final oversizedBytes = List<int>.filled(
          maxMcpRequestBodyBytes + 128,
          0x20,
        );
        final tooLargeReply = await _sendHttp(
          client: httpClient,
          method: 'POST',
          uri: mcpUri,
          headers: authHeaders(),
          bodyBytes: oversizedBytes,
        );
        expect(tooLargeReply.statusCode, 413);

        // 2. MCP Handshake: initialize + notifications/initialized (202 Accepted)
        for (final ver in const <String>[
          '2025-06-18',
          '2025-03-26',
          '2024-11-05',
        ]) {
          final initRes = await postRpc(<String, Object?>{
            'jsonrpc': '2.0',
            'id': 'init-$ver',
            'method': 'initialize',
            'params': <String, Object?>{
              'protocolVersion': ver,
              'capabilities': const <String, Object?>{},
              'clientInfo': const <String, Object?>{
                'name': 'test-agent',
                'version': '1.0.0',
              },
            },
          });
          final result = initRes['result']! as Map<String, Object?>;
          expect(result['protocolVersion'], ver);
          expect(result['serverInfo'], <String, Object?>{
            'name': 'tallyisle-mcp',
            'version': appVersionName,
          });
          expect(result['capabilities'], <String, Object?>{
            'tools': <String, Object?>{'listChanged': false},
            'resources': const <String, Object?>{},
          });
        }

        final notifReply = await _sendHttp(
          client: httpClient,
          method: 'POST',
          uri: mcpUri,
          headers: authHeaders(),
          bodyBytes: utf8.encode(
            jsonEncode(const <String, Object?>{
              'jsonrpc': '2.0',
              'method': 'notifications/initialized',
            }),
          ),
        );
        expect(notifReply.statusCode, 202);
        expect(notifReply.body, isEmpty);

        // 3. Resources list & read
        final resList = await postRpc(const <String, Object?>{
          'jsonrpc': '2.0',
          'id': 2,
          'method': 'resources/list',
        });
        final resources =
            (resList['result']! as Map<String, Object?>)['resources']!
                as List<Object?>;
        expect(resources, hasLength(3));

        for (final uri in const <String>[
          'tallyisle://overview',
          'tallyisle://books',
          'tallyisle://assets',
        ]) {
          final resRead = await postRpc(<String, Object?>{
            'jsonrpc': '2.0',
            'id': 'read-$uri',
            'method': 'resources/read',
            'params': <String, Object?>{'uri': uri},
          });
          final contents =
              (resRead['result']! as Map<String, Object?>)['contents']!
                  as List<Object?>;
          final text =
              (contents.single! as Map<String, Object?>)['text']! as String;
          expect(jsonDecode(text), isA<Map<String, Object?>>());
        }

        // 4. Permission tier enforcement: readOnly -> 7 tools, blocks create_record
        await service.setPermissionTier(McpPermissionTier.readOnly);
        final roList = await postRpc(const <String, Object?>{
          'jsonrpc': '2.0',
          'id': 10,
          'method': 'tools/list',
        });
        final roTools =
            (roList['result']! as Map<String, Object?>)['tools']!
                as List<Object?>;
        expect(roTools, hasLength(7));

        final blockedAppend = await postRpc(const <String, Object?>{
          'jsonrpc': '2.0',
          'id': 11,
          'method': 'tools/call',
          'params': <String, Object?>{
            'name': 'create_record',
            'arguments': <String, Object?>{
              'amount': '50.00',
              'category': '餐饮',
              'asset': '招商储蓄卡',
            },
          },
        });
        expect((blockedAppend['result']! as Map)['isError'], isTrue);
        expect(await db.select(db.records).get(), isEmpty);

        // 5. readAppend -> 12 tools, allows create_record & create_record_draft, blocks delete_record
        await service.setPermissionTier(McpPermissionTier.readAppend);
        final raList = await postRpc(const <String, Object?>{
          'jsonrpc': '2.0',
          'id': 20,
          'method': 'tools/list',
        });
        expect(
          ((raList['result']! as Map<String, Object?>)['tools']! as List),
          hasLength(12),
        );

        final createCall = await postRpc(const <String, Object?>{
          'jsonrpc': '2.0',
          'id': 21,
          'method': 'tools/call',
          'params': <String, Object?>{
            'name': 'create_record',
            'arguments': <String, Object?>{
              'type': 'expense',
              'amount': '38.55',
              'category': '餐饮',
              'asset': '招商储蓄卡',
              'remark': 'AI 记午餐',
              'record_time': '2026-11-24 12:30:00',
              'command_id': 'mcp-idempotent-1',
            },
          },
        });
        final createRes = createCall['result']! as Map<String, Object?>;
        expect(createRes['isError'], isFalse);
        final createdPayload =
            jsonDecode(
                  ((createRes['content']! as List).first as Map)['text']
                      as String,
                )
                as Map<String, Object?>;
        final createdRecordId = createdPayload['record_id']! as String;
        expect(createdPayload['money_minor'], '3855');
        expect(createdPayload['asset_balance_minor'], '96145');
        expect(createdPayload['asset_balance_decimal'], '961.45');

        // Idempotent retry with identical command_id must not double-deduct!
        final retryCall = await postRpc(const <String, Object?>{
          'jsonrpc': '2.0',
          'id': 22,
          'method': 'tools/call',
          'params': <String, Object?>{
            'name': 'create_record',
            'arguments': <String, Object?>{
              'type': 'expense',
              'amount': '38.55',
              'category': '餐饮',
              'asset': '招商储蓄卡',
              'remark': 'AI 记午餐',
              'record_time': '2026-11-24 12:30:00',
              'command_id': 'mcp-idempotent-1',
            },
          },
        });
        final retryPayload =
            (retryCall['result']! as Map<String, Object?>)['structuredContent']!
                as Map<String, Object?>;
        expect(retryPayload['record_id'], createdRecordId);
        final cardAfterRetry = await (db.select(
          db.assets,
        )..where((t) => t.id.equals(cardAssetId))).getSingle();
        expect(cardAfterRetry.balanceMinor, BigInt.from(96145));

        // Transfer with fee in readAppend
        final transferCall = await postRpc(const <String, Object?>{
          'jsonrpc': '2.0',
          'id': 23,
          'method': 'tools/call',
          'params': <String, Object?>{
            'name': 'create_record',
            'arguments': <String, Object?>{
              'type': 'transfer',
              'amount': '100.00',
              'fee': '1.20',
              'from_asset': '招商储蓄卡',
              'to_asset': '微信零钱',
              'remark': '充值零钱',
            },
          },
        });
        expect((transferCall['result']! as Map)['isError'], isFalse);
        final cardAfterTransfer = await (db.select(
          db.assets,
        )..where((t) => t.id.equals(cardAssetId))).getSingle();
        final walletAfterTransfer = await (db.select(
          db.assets,
        )..where((t) => t.id.equals(walletAssetId))).getSingle();
        // 96145 - 10000 - 120 = 86025; 20000 + 10000 = 30000
        expect(cardAfterTransfer.balanceMinor, BigInt.from(86025));
        expect(walletAfterTransfer.balanceMinor, BigInt.from(30000));

        // create_record_draft writes KEY_DRAFT into auto_map without touching balance
        final draftCall = await postRpc(const <String, Object?>{
          'jsonrpc': '2.0',
          'id': 24,
          'method': 'tools/call',
          'params': <String, Object?>{
            'name': 'create_record_draft',
            'arguments': <String, Object?>{
              'amount': '19.90',
              'category': '购物',
              'asset': '微信零钱',
              'remark': '待核对咖啡豆',
            },
          },
        });
        expect((draftCall['result']! as Map)['isError'], isFalse);
        final draftRows = await db.select(db.autoMaps).get();
        expect(draftRows, hasLength(1));
        expect(draftRows.single.key, 'KEY_DRAFT');
        final walletAfterDraft = await (db.select(
          db.assets,
        )..where((t) => t.id.equals(walletAssetId))).getSingle();
        expect(walletAfterDraft.balanceMinor, BigInt.from(30000));

        // create_note, create_wish, create_category_or_tag in readAppend
        final noteRes = await postRpc(const <String, Object?>{
          'jsonrpc': '2.0',
          'id': 25,
          'method': 'tools/call',
          'params': <String, Object?>{
            'name': 'create_note',
            'arguments': <String, Object?>{
              'title': '月度复盘',
              'content': '控制外卖支出',
            },
          },
        });
        final noteId =
            ((noteRes['result']! as Map)['structuredContent']! as Map)['id']
                as int;

        final wishRes = await postRpc(const <String, Object?>{
          'jsonrpc': '2.0',
          'id': 26,
          'method': 'tools/call',
          'params': <String, Object?>{
            'name': 'create_wish',
            'arguments': <String, Object?>{
              'content': '降噪耳机',
              'value': '1599.00',
            },
          },
        });
        expect((wishRes['result']! as Map)['isError'], isFalse);

        final tagRes = await postRpc(const <String, Object?>{
          'jsonrpc': '2.0',
          'id': 27,
          'method': 'tools/call',
          'params': <String, Object?>{
            'name': 'create_category_or_tag',
            'arguments': <String, Object?>{'kind': 'tag', 'name': 'AI标签'},
          },
        });
        expect((tagRes['result']! as Map)['isError'], isFalse);

        // Full-access tool blocked in readAppend with clear isError: true
        final blockedFull = await postRpc(<String, Object?>{
          'jsonrpc': '2.0',
          'id': 28,
          'method': 'tools/call',
          'params': <String, Object?>{
            'name': 'delete_record',
            'arguments': <String, Object?>{'record_id': createdRecordId},
          },
        });
        expect((blockedFull['result']! as Map)['isError'], isTrue);

        // 6. fullAccess -> all 20 tools + refund, reimbursement, budget, delete
        await service.setPermissionTier(McpPermissionTier.fullAccess);
        final faList = await postRpc(const <String, Object?>{
          'jsonrpc': '2.0',
          'id': 30,
          'method': 'tools/list',
        });
        expect(
          ((faList['result']! as Map<String, Object?>)['tools']! as List),
          hasLength(20),
        );

        final refundCall = await postRpc(<String, Object?>{
          'jsonrpc': '2.0',
          'id': 31,
          'method': 'tools/call',
          'params': <String, Object?>{
            'name': 'record_refund',
            'arguments': <String, Object?>{
              'origin_id': createdRecordId,
              'amount': '8.55',
              'remark': '菜品退差价',
            },
          },
        });
        expect((refundCall['result']! as Map)['isError'], isFalse);
        final cardAfterRefund = await (db.select(
          db.assets,
        )..where((t) => t.id.equals(cardAssetId))).getSingle();
        // 86025 + 855 = 86880
        expect(cardAfterRefund.balanceMinor, BigInt.from(86880));

        // Reimbursable + record_reimbursement
        final reimbBillCall = await postRpc(const <String, Object?>{
          'jsonrpc': '2.0',
          'id': 32,
          'method': 'tools/call',
          'params': <String, Object?>{
            'name': 'create_record',
            'arguments': <String, Object?>{
              'type': 'reimbursable',
              'amount': '200.00',
              'category': '交通',
              'from_asset': '招商储蓄卡',
              'remark': '出差打车垫付',
            },
          },
        });
        final reimbOriginId =
            ((reimbBillCall['result']! as Map)['structuredContent']!
                    as Map)['record_id']
                as String;

        final reimbSettleCall = await postRpc(<String, Object?>{
          'jsonrpc': '2.0',
          'id': 33,
          'method': 'tools/call',
          'params': <String, Object?>{
            'name': 'record_reimbursement',
            'arguments': <String, Object?>{
              'origin_id': reimbOriginId,
              'amount': '150.00',
              'asset': '招商储蓄卡',
            },
          },
        });
        expect((reimbSettleCall['result']! as Map)['isError'], isFalse);

        // Upsert & read budget
        final budgetUpsert = await postRpc(const <String, Object?>{
          'jsonrpc': '2.0',
          'id': 34,
          'method': 'tools/call',
          'params': <String, Object?>{
            'name': 'upsert_budget',
            'arguments': <String, Object?>{
              'section': '2026-11',
              'category': '餐饮',
              'amount': '1500.00',
            },
          },
        });
        final budgetId =
            ((budgetUpsert['result']! as Map)['structuredContent']!
                    as Map)['budget_id']
                as int;

        // Exercise all 7 read tools cleanly
        for (final (id, toolName, toolArgs)
            in <(int, String, Map<String, Object?>)>[
              (40, 'get_overview', const <String, Object?>{}),
              (41, 'list_catalog', const <String, Object?>{}),
              (
                42,
                'query_records',
                const <String, Object?>{
                  'start_date': '2026-11-01',
                  'end_date': '2026-11-30',
                  'limit': 20,
                },
              ),
              (
                43,
                'get_record_detail',
                <String, Object?>{'record_id': createdRecordId},
              ),
              (
                44,
                'get_statistics',
                const <String, Object?>{
                  'start_date': '2026-11-01',
                  'end_date': '2026-11-30',
                },
              ),
              (
                45,
                'get_budgets',
                const <String, Object?>{'section': '2026-11'},
              ),
              (46, 'list_plans_and_notes', const <String, Object?>{}),
            ]) {
          final r = await postRpc(<String, Object?>{
            'jsonrpc': '2.0',
            'id': id,
            'method': 'tools/call',
            'params': <String, Object?>{
              'name': toolName,
              'arguments': toolArgs,
            },
          });
          expect((r['result']! as Map)['isError'], isFalse, reason: toolName);
        }

        // Update & trash note, delete budget, update & delete record
        final updNote = await postRpc(<String, Object?>{
          'jsonrpc': '2.0',
          'id': 50,
          'method': 'tools/call',
          'params': <String, Object?>{
            'name': 'update_note',
            'arguments': <String, Object?>{'id': noteId, 'content': '更新后的复盘内容'},
          },
        });
        expect((updNote['result']! as Map)['isError'], isFalse);

        final trashNote = await postRpc(<String, Object?>{
          'jsonrpc': '2.0',
          'id': 51,
          'method': 'tools/call',
          'params': <String, Object?>{
            'name': 'trash_note',
            'arguments': <String, Object?>{'id': noteId},
          },
        });
        expect((trashNote['result']! as Map)['isError'], isFalse);

        final delBudget = await postRpc(<String, Object?>{
          'jsonrpc': '2.0',
          'id': 52,
          'method': 'tools/call',
          'params': <String, Object?>{
            'name': 'delete_budget',
            'arguments': <String, Object?>{'budget_id': budgetId},
          },
        });
        expect((delBudget['result']! as Map)['isError'], isFalse);

        final updRec = await postRpc(<String, Object?>{
          'jsonrpc': '2.0',
          'id': 53,
          'method': 'tools/call',
          'params': <String, Object?>{
            'name': 'update_record',
            'arguments': <String, Object?>{
              'record_id': createdRecordId,
              'amount': '40.00',
              'remark': 'AI 修改午餐金额',
            },
          },
        });
        expect((updRec['result']! as Map)['isError'], isFalse);

        final delRec = await postRpc(<String, Object?>{
          'jsonrpc': '2.0',
          'id': 54,
          'method': 'tools/call',
          'params': <String, Object?>{
            'name': 'delete_record',
            'arguments': <String, Object?>{'record_id': createdRecordId},
          },
        });
        expect((delRec['result']! as Map)['isError'], isFalse);

        expect(service.currentStatus.requestCount, greaterThanOrEqualTo(20));
        expect(service.currentStatus.lastRequestAtMs, isNotNull);

        // 7. Strict sqlite_master zero-DDL verification
        final postSchema = await _readSchemaSnapshot(db);
        expect(postSchema, equals(baselineSchema));
      } finally {
        httpClient.close(force: true);
        await service?.dispose();
        await db.close();
      }
    },
  );

  test(
    'MCP update_record & create_record audit regressions: FX snapshot integrity (1a/1b/1c) and non-editable specialized record types (2)',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final httpClient = HttpClient();
      McpServerService? service;

      try {
        // Seed USD currency: 1 USD = 8 CNY -> rate_to_anchor = 0.125
        await db
            .into(db.currencies)
            .insertOnConflictUpdate(
              CurrenciesCompanion.insert(
                code: 'USD',
                name: '美元',
                symbol: r'$',
                rateToAnchor: '0.125',
                anchorCode: 'CNY',
              ),
            );

        final ledger = LedgerService(db);
        final usdCardId = await ledger.createAsset(
          commandId: 'fx-seed-usd',
          name: '美元卡',
          initial: Money.parse('500.00', currency: 'USD'),
          currency: 'USD',
        );
        final cnyCardId = await ledger.createAsset(
          commandId: 'fx-seed-cny1',
          name: '招行卡',
          initial: Money.parse('1000.00'),
        );
        final cnyWalletId = await ledger.createAsset(
          commandId: 'fx-seed-cny2',
          name: '零钱包',
          initial: Money.parse('500.00'),
        );

        service = McpServerService(db, bindPortOverride: 0);
        await service.saveConfig(
          (await service.getConfig()).copyWith(
            enabled: true,
            permissionTier: McpPermissionTier.fullAccess,
          ),
        );
        final token = (await service.getConfig()).authToken;
        final mcpUri = Uri.parse(
          'http://127.0.0.1:${service.currentStatus.port}/mcp',
        );

        Future<Map<String, Object?>> callTool(
          String name,
          Map<String, Object?> args,
        ) async {
          final reply = await _sendHttp(
            client: httpClient,
            method: 'POST',
            uri: mcpUri,
            headers: <String, String>{
              'content-type': 'application/json',
              'authorization': 'Bearer $token',
            },
            bodyBytes: utf8.encode(
              jsonEncode(<String, Object?>{
                'jsonrpc': '2.0',
                'id': 'audit-$name',
                'method': 'tools/call',
                'params': <String, Object?>{'name': name, 'arguments': args},
              }),
            ),
          );
          expect(reply.statusCode, 200);
          return (jsonDecode(reply.body) as Map<String, Object?>)['result']!
              as Map<String, Object?>;
        }

        // --- Bug 1c (L-07): Cross-currency transfer preserves historical rate on remark edit ---
        final txCreate = await callTool('create_record', <String, Object?>{
          'type': 'transfer',
          'amount': '100.00',
          'from_asset': '美元卡',
          'to_asset': '招行卡',
          'remark': '结汇',
        });
        expect(txCreate['isError'], isFalse);
        final txId =
            (txCreate['structuredContent']! as Map)['record_id']! as String;
        // 美元卡: 500 - 100 = 400.00 USD; 招行卡: 1000 + 800 = 1800.00 CNY
        expect(
          (await (db.select(
            db.assets,
          )..where((t) => t.id.equals(usdCardId))).getSingle()).balanceMinor,
          BigInt.from(40000),
        );
        expect(
          (await (db.select(
            db.assets,
          )..where((t) => t.id.equals(cnyCardId))).getSingle()).balanceMinor,
          BigInt.from(180000),
        );

        // Change USD rate to 1 USD = 10 CNY (0.1), then edit ONLY remark
        await (db.update(db.currencies)..where((t) => t.code.equals('USD')))
            .write(const CurrenciesCompanion(rateToAnchor: Value('0.1')));
        final txRemarkEdit = await callTool('update_record', <String, Object?>{
          'record_id': txId,
          'remark': '结汇（仅改备注）',
        });
        expect(txRemarkEdit['isError'], isFalse);
        // Historical +800.00 CNY must be preserved (no drift to +1000.00 CNY)
        expect(
          (await (db.select(
            db.assets,
          )..where((t) => t.id.equals(cnyCardId))).getSingle()).balanceMinor,
          BigInt.from(180000),
        );

        // --- Bug 1a: Switching foreign -> CNY transfer source clears CurrencySnapshot ---
        final txSwitchToCny = await callTool('update_record', <String, Object?>{
          'record_id': txId,
          'from_asset': '零钱包',
        });
        expect(txSwitchToCny['isError'], isFalse);
        // 美元卡 restored to 500.00 USD; 零钱包: 500 - 100 = 400.00 CNY; 招行卡: 1000 + 100 = 1100.00 CNY
        expect(
          (await (db.select(
            db.assets,
          )..where((t) => t.id.equals(usdCardId))).getSingle()).balanceMinor,
          BigInt.from(50000),
        );
        expect(
          (await (db.select(
            db.assets,
          )..where((t) => t.id.equals(cnyWalletId))).getSingle()).balanceMinor,
          BigInt.from(40000),
        );
        expect(
          (await (db.select(
            db.assets,
          )..where((t) => t.id.equals(cnyCardId))).getSingle()).balanceMinor,
          BigInt.from(110000),
        );
        final switchedTxRow = await (db.select(
          db.records,
        )..where((t) => t.recordId.equals(txId))).getSingle();
        expect(RecordExtra.parse(switchedTxRow.extraInfo).currency, isNull);

        // --- Bug 1b: Foreign expense discount edit & account switch with unchanged numeric amount ---
        final fxExpCreate = await callTool('create_record', <String, Object?>{
          'type': 'expense',
          'amount': '50.00',
          'category': '餐饮',
          'asset': '美元卡',
          'remark': '海外晚餐',
        });
        expect(fxExpCreate['isError'], isFalse);
        final fxExpId =
            (fxExpCreate['structuredContent']! as Map)['record_id']! as String;

        // Edit discount on USD bill without changing amount
        final fxDiscEdit = await callTool('update_record', <String, Object?>{
          'record_id': fxExpId,
          'discount': '5.00',
        });
        expect(fxDiscEdit['isError'], isFalse);
        final afterDiscRow = await (db.select(
          db.records,
        )..where((t) => t.recordId.equals(fxExpId))).getSingle();
        final afterDiscSnap = RecordExtra.parse(
          afterDiscRow.extraInfo,
        ).currency!;
        expect(afterDiscSnap.sourceCode, 'USD');
        expect(afterDiscSnap.sourceGross, BigInt.from(5500));
        expect(afterDiscSnap.assetNet, BigInt.from(5000));
        expect(afterDiscRow.discountMinor, BigInt.from(500));

        // Switch asset from USD to CNY without changing numeric amount (50.00)
        final fxSwitchAsset = await callTool('update_record', <String, Object?>{
          'record_id': fxExpId,
          'asset': '招行卡',
        });
        expect(fxSwitchAsset['isError'], isFalse);
        final afterAssetSwitchRow = await (db.select(
          db.records,
        )..where((t) => t.recordId.equals(fxExpId))).getSingle();
        expect(
          RecordExtra.parse(afterAssetSwitchRow.extraInfo).currency,
          isNull,
        );
        // 美元卡 restored to 500.00 USD; 招行卡: 1100 - 50 = 1050.00 CNY
        expect(
          (await (db.select(
            db.assets,
          )..where((t) => t.id.equals(usdCardId))).getSingle()).balanceMinor,
          BigInt.from(50000),
        );
        expect(
          (await (db.select(
            db.assets,
          )..where((t) => t.id.equals(cnyCardId))).getSingle()).balanceMinor,
          BigInt.from(105000),
        );

        // --- Bug 2: Reject non-editable specialized record types in create_record & update_record ---
        final badCreate = await callTool('create_record', <String, Object?>{
          'type': 'balance_adjust',
          'amount': '10.00',
        });
        expect(badCreate['isError'], isTrue);

        final badCreateFee = await callTool('create_record', <String, Object?>{
          'type': 'fee',
          'amount': '2.00',
        });
        expect(badCreateFee['isError'], isTrue);

        // Balance adjustment record (type=4) cannot be overwritten via update_record
        final adjRecordId = await ledger.adjustBalance(
          commandId: 'seed-adj-1',
          assetId: cnyWalletId,
          target: Money.parse('420.00'),
          bookId: 1,
        );
        expect(adjRecordId, isNotNull);
        final badUpdateAdj = await callTool('update_record', <String, Object?>{
          'record_id': adjRecordId,
          'type': 'expense',
          'amount': '10.00',
          'category': '餐饮',
        });
        expect(badUpdateAdj['isError'], isTrue);
        final adjRowAfter = await (db.select(
          db.records,
        )..where((t) => t.recordId.equals(adjRecordId!))).getSingle();
        expect(adjRowAfter.type, RecordType.balanceAdjust);

        // Debt principal record (type=5 borrowIn) cannot be overwritten via update_record
        final debtService = DebtService(db);
        await debtService.createDebt(
          commandId: 'seed-debt-1',
          bookId: 1,
          subType: AssetType.debtBorrow,
          name: '张三',
          principal: Money.parse('300.00'),
          fundingAssetId: cnyWalletId,
          startDate: DateTime(2026, 11, 24, 10).millisecondsSinceEpoch,
        );
        final borrowRec = await (db.select(
          db.records,
        )..where((t) => t.type.equals(RecordType.borrowIn))).getSingle();
        final badUpdateDebt = await callTool('update_record', <String, Object?>{
          'record_id': borrowRec.recordId,
          'type': 'expense',
          'amount': '50.00',
          'category': '餐饮',
        });
        expect(badUpdateDebt['isError'], isTrue);
        final borrowRowAfter = await (db.select(
          db.records,
        )..where((t) => t.recordId.equals(borrowRec.recordId))).getSingle();
        expect(borrowRowAfter.type, RecordType.borrowIn);
        expect(borrowRowAfter.moneyMinor, BigInt.from(30000));
      } finally {
        httpClient.close(force: true);
        await service?.dispose();
        await db.close();
      }
    },
  );
}
