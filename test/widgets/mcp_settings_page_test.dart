import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/data/automation/mcp_http_binding.dart';
import 'package:tallyisle/data/automation/mcp_server_service.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/domain/rules/app_settings_rules.dart';
import 'package:tallyisle/domain/rules/mcp_rules.dart';
import 'package:tallyisle/features/automation/automation_providers.dart';
import 'package:tallyisle/features/automation/mcp_settings_page.dart';

final class _FakeBoundServer implements BoundMcpHttpServer {
  _FakeBoundServer({required this.host, required this.port});

  @override
  final String host;

  @override
  final int port;

  bool closed = false;

  @override
  Future<void> close({bool force = false}) async {
    closed = true;
  }
}

final class _FakeMcpHttpBinding implements McpHttpBinding {
  final List<_FakeBoundServer> boundServers = <_FakeBoundServer>[];

  @override
  bool get isSupported => true;

  @override
  Future<BoundMcpHttpServer> bind({
    required String host,
    required int port,
    required Future<McpHttpResponseData> Function(McpHttpRequestContext request)
    onRequest,
  }) async {
    final server = _FakeBoundServer(host: host, port: port == 0 ? 39179 : port);
    boundServers.add(server);
    return server;
  }

  @override
  Future<List<String>> listLocalIpv4Addresses() async => const <String>[
    '192.168.1.88',
  ];
}

ThemeData _buildTestTheme(Brightness brightness) {
  final seedColor = Color(AppSettings.defaults.themeSeedArgb32);
  const segmentedButtonTheme = SegmentedButtonThemeData(
    style: ButtonStyle(
      visualDensity: VisualDensity.compact,
      padding: WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 10, vertical: 0),
      ),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
  );
  return ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: brightness,
    ),
    segmentedButtonTheme: segmentedButtonTheme,
    useMaterial3: true,
  );
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  Future<void> scrollToKey(WidgetTester tester, Key key) async {
    await tester.scrollUntilVisible(
      find.byKey(key),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await settle(tester);
  }

  testWidgets(
    'McpSettingsPage (F-039): toggles listener, permission tiers, LAN auth lock, port dialog, token actions, and copies client JSON',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      String? copiedText;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              final args = call.arguments as Map<Object?, Object?>;
              copiedText = args['text'] as String?;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );

      final db = AppDatabase(NativeDatabase.memory());
      final fakeBinding = _FakeMcpHttpBinding();
      final service = McpServerService(db, httpBinding: fakeBinding);

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            mcpServerServiceProvider.overrideWith((ref) async => service),
          ],
          child: MaterialApp(
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            supportedLocales: const <Locale>[Locale('zh'), Locale('en')],
            theme: _buildTestTheme(Brightness.light),
            home: const McpSettingsPage(),
          ),
        ),
      );
      await settle(tester);

      expect(find.byKey(const Key('mcp_settings_page')), findsOneWidget);
      expect(find.text('MCP 服务'), findsOneWidget);
      expect(find.text('MCP 服务 (AI Agents)'), findsNothing);
      expect(find.text('已停止'), findsOneWidget);

      // Enable server -> status badge updates to 运行中
      await tester.tap(find.byKey(const Key('mcp_enable_switch')));
      await settle(tester);
      expect(find.text('运行中'), findsOneWidget);
      expect(service.currentStatus.isRunning, isTrue);

      // Switch permission tier to 完整读写
      await tester.tap(find.text('完整读写'));
      await settle(tester);
      expect(
        (await tester.runAsync(service.getConfig))!.permissionTier,
        McpPermissionTier.fullAccess,
      );

      // Enable LAN -> forces requireAuth switch locked ON and displays LAN IP
      await scrollToKey(tester, const Key('mcp_bind_lan_switch'));
      await tester.tap(find.byKey(const Key('mcp_bind_lan_switch')));
      await settle(tester);
      final authTile = tester.widget<SwitchListTile>(
        find.byKey(const Key('mcp_require_auth_switch')),
      );
      expect(authTile.value, isTrue);
      expect(authTile.onChanged, isNull);

      // Edit port via dialog
      await scrollToKey(tester, const Key('mcp_port_tile'));
      await tester.tap(find.byKey(const Key('mcp_port_tile')));
      await settle(tester);
      expect(find.byKey(const Key('mcp_port_dialog')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('mcp_port_input')), '45120');
      await tester.tap(find.byKey(const Key('mcp_port_save_button')));
      await settle(tester);
      expect((await tester.runAsync(service.getConfig))!.port, 45120);
      expect(service.currentStatus.port, 45120);

      // Reveal & regenerate token
      final oldToken = (await tester.runAsync(service.getConfig))!.authToken;
      await scrollToKey(tester, const Key('mcp_token_visibility_button'));
      await tester.tap(find.byKey(const Key('mcp_token_visibility_button')));
      await settle(tester);
      expect(find.text(oldToken), findsAtLeastNWidgets(1));

      await scrollToKey(tester, const Key('mcp_token_regenerate_button'));
      await tester.tap(find.byKey(const Key('mcp_token_regenerate_button')));
      await settle(tester);
      await tester.tap(
        find.byKey(const Key('mcp_token_regenerate_confirm_button')),
      );
      await settle(tester);
      final newToken = (await tester.runAsync(service.getConfig))!.authToken;
      expect(newToken, isNot(equals(oldToken)));

      // Copy client config JSON
      await scrollToKey(tester, const Key('mcp_copy_client_config_button'));
      await tester.tap(find.byKey(const Key('mcp_copy_client_config_button')));
      await settle(tester);
      expect(copiedText, isNotNull);
      final parsedJson = jsonDecode(copiedText!) as Map<String, Object?>;
      expect(parsedJson.containsKey('mcpServers'), isTrue);
      final tallyEntry =
          (parsedJson['mcpServers']! as Map<String, Object?>)['tallyisle']!
              as Map<String, Object?>;
      expect(tallyEntry['type'], 'streamable-http');
      expect(tallyEntry['url'], 'http://192.168.1.88:45120/mcp');
      expect(
        (tallyEntry['headers']! as Map)['Authorization'],
        'Bearer $newToken',
      );

      // Scroll down to verify available tools summary card renders cleanly
      await scrollToKey(tester, const Key('mcp_tools_summary_card'));
      expect(find.byKey(const Key('mcp_tools_summary_card')), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      await tester.runAsync(service.dispose);
      await tester.runAsync(db.close);
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets(
    'McpSettingsPage responsive geometry check: zero overflow at 360x640 (1.2x text scale, Light & Dark) and 960x800',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final fakeBinding = _FakeMcpHttpBinding();
      final service = McpServerService(db, httpBinding: fakeBinding);

      for (final viewport in const <Size>[Size(360, 640), Size(960, 800)]) {
        for (final brightness in Brightness.values) {
          await tester.binding.setSurfaceSize(viewport);
          await tester.pumpWidget(
            ProviderScope(
              retry: (_, _) => null,
              overrides: [
                databaseProvider.overrideWith((ref) async => db),
                mcpServerServiceProvider.overrideWith((ref) async => service),
              ],
              child: MaterialApp(
                localizationsDelegates: GlobalMaterialLocalizations.delegates,
                supportedLocales: const <Locale>[Locale('zh'), Locale('en')],
                theme: _buildTestTheme(brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: const TextScaler.linear(1.2)),
                  child: child!,
                ),
                home: const McpSettingsPage(),
              ),
            ),
          );
          await settle(tester);
          expect(tester.takeException(), isNull);

          final listFinder = find.byKey(const Key('mcp_settings_list'));
          for (var step = 0; step < 6; step++) {
            await tester.drag(listFinder, const Offset(0, -260));
            await tester.pump(const Duration(milliseconds: 50));
            expect(tester.takeException(), isNull);
          }
        }
      }

      await tester.binding.setSurfaceSize(null);
      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      await tester.runAsync(service.dispose);
      await tester.runAsync(db.close);
      await tester.pump(const Duration(seconds: 1));
    },
  );
}
