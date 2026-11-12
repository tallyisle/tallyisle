import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show AppExitResponse, PointerDeviceKind;

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:tallyisle/app/app.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/backup/s3_client.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/cloud_sync_rules.dart';
import 'package:tallyisle/domain/rules/s3_sigv4_rules.dart';
import 'package:tallyisle/domain/rules/tally_backup.dart';
import 'package:tallyisle/features/backup/backup_providers.dart';
import 'package:tallyisle/features/currencies/currency_rate_providers.dart';
import 'package:tallyisle/features/reminder/reminder_providers.dart';
import 'package:tallyisle/platform/notifications.dart';

final class _LoopbackS3Server {
  _LoopbackS3Server._(this._server);

  final HttpServer _server;
  final Map<String, Uint8List> objects = <String, Uint8List>{};
  final Map<String, DateTime> modifiedAt = <String, DateTime>{};
  int _tick = 0;

  static const String bucket = 'enh-sync-bucket';
  static const String accessKey = 'AKIA_ENH_INTEGRATION';
  static const String secretKey = 'enh_integration_s3_secret_key';

  String get endpoint => 'http://127.0.0.1:${_server.port}';

  static Future<_LoopbackS3Server> start() async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final s = _LoopbackS3Server._(http);
    http.listen(s._handle);
    return s;
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    try {
      await _handleInner(req);
    } catch (_) {
      try {
        await req.response.close();
      } catch (_) {}
    }
  }

  Future<void> _handleInner(HttpRequest req) async {
    final builder = BytesBuilder(copy: false);
    await for (final c in req) {
      builder.add(c);
    }
    final body = builder.takeBytes();

    final auth = req.headers.value(HttpHeaders.authorizationHeader) ?? '';
    final amzDate = req.headers.value('x-amz-date') ?? '';
    final contentSha = req.headers.value('x-amz-content-sha256') ?? '';
    if (amzDate.length < 16 || contentSha != sha256Hex(body)) {
      req.response.statusCode = HttpStatus.forbidden;
      await req.response.close();
      return;
    }

    final segs = <String>[
      for (final s in req.uri.pathSegments)
        if (s.isNotEmpty) s,
    ];
    if (segs.isEmpty || segs.first != bucket) {
      req.response.statusCode = HttpStatus.notFound;
      req.response.write('<Error><Code>NoSuchBucket</Code></Error>');
      await req.response.close();
      return;
    }
    final key = segs.skip(1).join('/');

    final parsedAmzUtc = DateTime.parse(
      '${amzDate.substring(0, 4)}-${amzDate.substring(4, 6)}-${amzDate.substring(6, 8)}'
      'T${amzDate.substring(9, 11)}:${amzDate.substring(11, 13)}:${amzDate.substring(13, 15)}Z',
    );
    final signedHeadersMatch = RegExp(
      r'SignedHeaders=([^,]+)',
    ).firstMatch(auth);
    final extra = <String, String>{};
    if (signedHeadersMatch != null) {
      for (final h in signedHeadersMatch.group(1)!.split(';')) {
        if (h == 'host' || h == 'x-amz-date' || h == 'x-amz-content-sha256') {
          continue;
        }
        final v = req.headers.value(h);
        if (v != null) extra[h] = v;
      }
    }
    final expectedSigned = signS3Request(
      method: req.method,
      target: resolveS3RequestTarget(
        endpoint: endpoint,
        bucket: bucket,
        objectKey: key,
        forcePathStyle: true,
        queryParameters: req.uri.queryParameters,
      ),
      accessKeyId: accessKey,
      secretAccessKey: secretKey,
      region: 'auto',
      payloadBytes: body,
      timestampUtc: parsedAmzUtc,
      extraHeaders: extra,
    );
    if (auth != expectedSigned.authorization) {
      req.response.statusCode = HttpStatus.forbidden;
      await req.response.close();
      return;
    }

    if (req.method == 'GET' &&
        key.isEmpty &&
        req.uri.queryParameters['list-type'] == '2') {
      final prefix = req.uri.queryParameters['prefix'] ?? '';
      final xml = StringBuffer(
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<ListBucketResult><IsTruncated>false</IsTruncated>',
      );
      for (final e in objects.entries) {
        if (!e.key.startsWith(prefix)) continue;
        final mod = (modifiedAt[e.key] ?? DateTime.utc(2026, 11, 11, 12))
            .toIso8601String();
        xml.write(
          '<Contents>'
          '<Key>${e.key}</Key>'
          '<LastModified>$mod</LastModified>'
          '<Size>${e.value.length}</Size>'
          '</Contents>',
        );
      }
      xml.write('</ListBucketResult>');
      req.response.statusCode = HttpStatus.ok;
      req.response.write(xml.toString());
      await req.response.close();
      return;
    }

    switch (req.method) {
      case 'PUT':
        objects[key] = body;
        modifiedAt[key] = DateTime.utc(2026, 11, 11, 12, 0, ++_tick);
        req.response.statusCode = HttpStatus.ok;
        await req.response.close();
      case 'GET':
        final data = objects[key];
        if (data == null) {
          req.response.statusCode = HttpStatus.notFound;
        } else {
          req.response.statusCode = HttpStatus.ok;
          req.response.contentLength = data.length;
          req.response.add(data);
        }
        await req.response.close();
      case 'DELETE':
        objects.remove(key);
        modifiedAt.remove(key);
        req.response.statusCode = HttpStatus.noContent;
        await req.response.close();
      default:
        req.response.statusCode = HttpStatus.methodNotAllowed;
        await req.response.close();
    }
  }
}

final class _LoopbackRateServer {
  _LoopbackRateServer._(this._server);

  final HttpServer _server;
  final List<String> requestedPaths = <String>[];
  String usdQuote = '0.138888888889'; // 1 USD = 7.2 CNY

  String get url => 'http://127.0.0.1:${_server.port}/cny-rates.json';

  static Future<_LoopbackRateServer> start() async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final s = _LoopbackRateServer._(http);
    http.listen((req) async {
      s.requestedPaths.add(req.uri.toString());
      req.response.statusCode = HttpStatus.ok;
      req.response.headers.contentType = ContentType.json;
      req.response.write(
        '{"result":"success","base_code":"CNY","rates":{"USD":"${s.usdQuote}"}}',
      );
      await req.response.close();
    });
    return s;
  }

  Future<void> close() => _server.close(force: true);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 80; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump(const Duration(milliseconds: 60));
    final busyBackup = find
        .byKey(const Key('webdav_transfer_progress'))
        .evaluate()
        .isNotEmpty;
    final busyS3 = find
        .byKey(const Key('s3_config_busy'))
        .evaluate()
        .isNotEmpty;
    if (!busyBackup && !busyS3 && i >= 6) {
      break;
    }
  }
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<void> _goBack(WidgetTester tester) async {
  await tester.tap(find.byType(BackButton).last);
  await _settle(tester);
}

Future<T> _pumpFuture<T>(
  WidgetTester tester,
  Future<T> Function() action,
) async {
  var done = false;
  Object? error;
  StackTrace? stack;
  late T result;
  unawaited(
    action().then(
      (value) {
        result = value;
        done = true;
      },
      onError: (Object e, StackTrace st) {
        error = e;
        stack = st;
        done = true;
      },
    ),
  );
  for (var i = 0; i < 120 && !done; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  if (!done) {
    throw TimeoutException('_pumpFuture timed out');
  }
  if (error != null) {
    Error.throwWithStackTrace(error!, stack!);
  }
  return result;
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets(
    'TallyIsleApp end-to-end S3 multi-device sync: Device A configures S3 (/backup/s3) & pushes, and Device B refreshes UI live on resume without restart',
    (tester) async {
      final prevOverrides = HttpOverrides.current;
      HttpOverrides.global = null;

      late final AppDatabase dbA;
      late final AppDatabase dbB;
      await tester.runAsync(() async {
        dbA = AppDatabase(NativeDatabase.memory());
        dbB = AppDatabase(NativeDatabase.memory());
      });
      final schedulerA = InMemoryReminderScheduler();
      final schedulerB = InMemoryReminderScheduler();
      final s3Server = (await tester.runAsync(_LoopbackS3Server.start))!;
      final tempRoot = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('enh_s3_multi_device_'),
      ))!;

      var closed = false;
      Future<void> cleanUp() async {
        if (closed) return;
        closed = true;
        HttpOverrides.global = prevOverrides;
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(schedulerA.dispose);
        await tester.runAsync(schedulerB.dispose);
        await tester.runAsync(s3Server.close);
        await tester.runAsync(dbA.close);
        await tester.runAsync(dbB.close);
        await tester.runAsync(() async {
          if (await tempRoot.exists()) {
            await tempRoot.delete(recursive: true);
          }
        });
      }

      addTearDown(cleanUp);

      // Seed Device A with an account and an expense bill.
      await tester.runAsync(() async {
        final books = await dbA.select(dbA.accountBooks).get();
        final bookId = books.first.id;
        final cats = await dbA.select(dbA.recordCategories).get();
        final expenseCat = cats.firstWhere((c) => c.type == RecordType.expense);
        final ledgerA = LedgerService(dbA);
        final assetId = await ledgerA.createAsset(
          commandId: 'enh-devA-asset',
          name: '招行工资卡',
          type: AssetType.normal,
          initial: Money.parse('3712.50'),
        );
        await ledgerA.saveRecord(
          commandId: 'enh-devA-record',
          draft: RecordDraft(
            bookId: bookId,
            type: RecordType.expense,
            money: Money.parse('32.00'),
            categoryId: expenseCat.id,
            assetId: assetId,
            recordTime: DateTime.now().millisecondsSinceEpoch,
            remark: '精品手冲咖啡',
          ),
        );
      });

      var deviceAHttpCalls = 0;
      await tester.pumpWidget(
        ProviderScope(
          key: const ValueKey('device-A-scope'),
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => dbA),
            reminderSchedulerProvider.overrideWithValue(schedulerA),
            backupLocalDirectoryOverrideProvider.overrideWithValue(
              () async => Directory(p.join(tempRoot.path, 'devA_local')),
            ),
            backupAttachmentsDirectoryOverrideProvider.overrideWithValue(
              () async => Directory(p.join(tempRoot.path, 'devA_att')),
            ),
            backupHttpClientFactoryProvider.overrideWithValue(() {
              deviceAHttpCalls++;
              return HttpClient();
            }),
          ],
          child: const TallyIsleApp(),
        ),
      );
      await _settle(tester);

      // Default unconfigured state performs zero network I/O.
      expect(deviceAHttpCalls, 0);

      // Navigate MePage -> 云同步与备份 -> 配置 S3 (/backup/s3)
      await tester.tap(find.text('更多'));
      await _settle(tester);
      await tester.scrollUntilVisible(
        find.byKey(const Key('me-backup')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await _settle(tester);
      await tester.tap(find.byKey(const Key('me-backup')));
      await _settle(tester);
      expect(find.byKey(const Key('backup_page')), findsOneWidget);

      final backupCtxA = tester.element(find.byKey(const Key('backup_page')));
      unawaited(GoRouter.of(backupCtxA).push('/backup/s3'));
      await _settle(tester);
      expect(find.byKey(const Key('s3_config_page')), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('s3_endpoint_input')),
        s3Server.endpoint,
      );
      await tester.enterText(find.byKey(const Key('s3_region_input')), 'auto');
      await tester.enterText(
        find.byKey(const Key('s3_bucket_input')),
        _LoopbackS3Server.bucket,
      );
      await tester.enterText(
        find.byKey(const Key('s3_access_key_input')),
        _LoopbackS3Server.accessKey,
      );
      await tester.enterText(
        find.byKey(const Key('s3_secret_key_input')),
        _LoopbackS3Server.secretKey,
      );

      final testBtnA = find.byKey(const Key('s3_test_connection_button'));
      await tester.ensureVisible(testBtnA);
      await _settle(tester);
      await tester.tap(testBtnA);
      await _settle(tester);
      expect(find.byKey(const Key('s3_test_result_banner')), findsOneWidget);
      expect(find.textContaining('连接成功'), findsOneWidget);

      final saveBtnA = find.byKey(const Key('s3_save_config_button'));
      await tester.ensureVisible(saveBtnA);
      await _settle(tester);
      await tester.tap(saveBtnA);
      await _settle(tester);
      expect(find.byKey(const Key('backup_page')), findsOneWidget);

      // Push Device A snapshot to S3
      final syncNowBtnA = find.byKey(const Key('cloud_sync_now_button'));
      await tester.ensureVisible(syncNowBtnA);
      await _settle(tester);
      await tester.tap(syncNowBtnA);
      await _settle(tester);
      expect(find.textContaining('已推送最新快照至云端（版本 r1）'), findsWidgets);

      // Now mount Device B (fresh empty DB) on TallyIsleApp.
      await tester.pumpWidget(
        ProviderScope(
          key: const ValueKey('device-B-scope'),
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => dbB),
            reminderSchedulerProvider.overrideWithValue(schedulerB),
            backupLocalDirectoryOverrideProvider.overrideWithValue(
              () async => Directory(p.join(tempRoot.path, 'devB_local')),
            ),
            backupAttachmentsDirectoryOverrideProvider.overrideWithValue(
              () async => Directory(p.join(tempRoot.path, 'devB_att')),
            ),
            backupHttpClientFactoryProvider.overrideWithValue(HttpClient.new),
          ],
          child: const TallyIsleApp(),
        ),
      );
      await _settle(tester);

      // Before sync, Device B has no '招行工资卡'.
      await tester.tap(find.text('资产'));
      await _settle(tester);
      expect(find.text('招行工资卡'), findsNothing);

      // Configure S3 on Device B via MePage -> 云同步与备份 -> 配置 S3, leaving autoSyncEnabled ON (default),
      // then return to AssetsPage and trigger AppLifecycleState.resumed to verify live foreground pull!
      await tester.tap(find.text('更多'));
      await _settle(tester);
      await tester.scrollUntilVisible(
        find.byKey(const Key('me-backup')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await _settle(tester);
      await tester.tap(find.byKey(const Key('me-backup')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('open_s3_config_button')));
      await _settle(tester);

      await tester.enterText(
        find.byKey(const Key('s3_endpoint_input')),
        s3Server.endpoint,
      );
      await tester.enterText(find.byKey(const Key('s3_region_input')), 'auto');
      await tester.enterText(
        find.byKey(const Key('s3_bucket_input')),
        _LoopbackS3Server.bucket,
      );
      await tester.enterText(
        find.byKey(const Key('s3_access_key_input')),
        _LoopbackS3Server.accessKey,
      );
      await tester.enterText(
        find.byKey(const Key('s3_secret_key_input')),
        _LoopbackS3Server.secretKey,
      );
      final saveBtnB = find.byKey(const Key('s3_save_config_button'));
      await tester.ensureVisible(saveBtnB);
      await _settle(tester);
      await tester.tap(saveBtnB);
      await _settle(tester);

      // Enable automatic multi-device cloud sync on Device B (`auto_cloud_sync_switch`).
      final autoSyncSwitchB = find.byKey(const Key('auto_cloud_sync_switch'));
      await tester.ensureVisible(autoSyncSwitchB);
      await _settle(tester);
      await tester.tap(autoSyncSwitchB);
      await _settle(tester);

      await _goBack(tester);
      await tester.tap(find.text('资产'));
      await _settle(tester);
      expect(find.text('招行工资卡'), findsNothing);

      // Foreground resume triggers TallyIsleApp._runLifecycleSync -> runSilentCloudSyncIfNeeded -> live UI refresh!
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _settle(tester);

      expect(find.text('招行工资卡'), findsOneWidget);
      expect(find.textContaining('3680.50'), findsWidgets);

      await tester.tap(find.text('明细'));
      await _settle(tester);
      expect(
        tester.widget<Text>(find.byKey(const Key('sum-expense'))).data,
        '32.00',
      );
      expect(find.textContaining('精品手冲咖啡'), findsOneWidget);

      await cleanUp();
    },
  );

  testWidgets(
    'TallyIsleApp end-to-end third-party import hub & opt-in live exchange rates: MePage -> 第三方数据导入 (/migration) and 币种与汇率 (/currencies)',
    (tester) async {
      final prevOverrides = HttpOverrides.current;
      HttpOverrides.global = null;

      var clockMs = DateTime(2026, 11, 11, 14, 0).millisecondsSinceEpoch;
      late final AppDatabase db;
      await tester.runAsync(() async {
        db = AppDatabase(NativeDatabase.memory(), nowMs: () => clockMs);
      });
      final scheduler = InMemoryReminderScheduler();
      final rateServer = (await tester.runAsync(_LoopbackRateServer.start))!;
      final tempRoot = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('enh_rates_migration_'),
      ))!;

      var closed = false;
      Future<void> cleanUp() async {
        if (closed) return;
        closed = true;
        HttpOverrides.global = prevOverrides;
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(scheduler.dispose);
        await tester.runAsync(rateServer.close);
        await tester.runAsync(db.close);
        await tester.runAsync(() async {
          if (await tempRoot.exists()) {
            await tempRoot.delete(recursive: true);
          }
        });
      }

      addTearDown(cleanUp);

      var rateClientFactoryCalls = 0;
      var backupClientFactoryCalls = 0;

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            reminderSchedulerProvider.overrideWithValue(scheduler),
            backupLocalDirectoryOverrideProvider.overrideWithValue(
              () async => Directory(p.join(tempRoot.path, 'local')),
            ),
            backupAttachmentsDirectoryOverrideProvider.overrideWithValue(
              () async => Directory(p.join(tempRoot.path, 'att')),
            ),
            backupHttpClientFactoryProvider.overrideWithValue(() {
              backupClientFactoryCalls++;
              return HttpClient();
            }),
            onlineRateHttpClientFactoryProvider.overrideWithValue(() {
              rateClientFactoryCalls++;
              return HttpClient();
            }),
          ],
          child: const TallyIsleApp(),
        ),
      );
      await _settle(tester);

      // 1. Default privacy guarantee: startup + pause + resume make ZERO HTTP calls.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _settle(tester);
      expect(rateClientFactoryCalls, 0);
      expect(backupClientFactoryCalls, 0);
      expect(rateServer.requestedPaths, isEmpty);

      // 2. Navigate MePage -> 第三方数据导入 (/migration)
      await tester.tap(find.text('更多'));
      await _settle(tester);
      await tester.scrollUntilVisible(
        find.byKey(const Key('me-migration')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await _settle(tester);
      expect(find.text('第三方数据导入'), findsOneWidget);
      await tester.tap(find.byKey(const Key('me-migration')));
      await _settle(tester);

      expect(find.byKey(const Key('migration_page')), findsOneWidget);
      expect(find.text('第三方数据导入'), findsWidgets);
      expect(
        find.byKey(const Key('migration_unity_banner_card')),
        findsOneWidget,
      );
      expect(find.text('一羽记账备份全量迁入'), findsOneWidget);
      expect(
        find.byKey(const Key('legacy_import_penny_button')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('export_ya2i_save_button')), findsNothing);
      expect(find.byKey(const Key('export_ya2i_share_button')), findsNothing);
      expect(find.textContaining('导出 .ya2i'), findsNothing);

      await tester.dragUntilVisible(
        find.byKey(const Key('migration_import_yi2a_button')),
        find.byType(ListView),
        const Offset(0, -140),
      );
      await _settle(tester);
      expect(
        find.byKey(const Key('migration_import_yi2a_button')),
        findsOneWidget,
      );

      await tester.dragUntilVisible(
        find.byKey(const Key('migration_restore_lan_button')),
        find.byType(ListView),
        const Offset(0, -140),
      );
      await _settle(tester);
      expect(
        find.byKey(const Key('migration_restore_lan_button')),
        findsOneWidget,
      );

      await tester.dragUntilVisible(
        find.byKey(const Key('third_party_extensible_note_card')),
        find.byType(ListView),
        const Offset(0, -160),
      );
      await _settle(tester);
      expect(find.text('电子账单与更多记账软件导入'), findsOneWidget);
      expect(
        find.byKey(const Key('third_party_csv_shortcut_card')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('third_party_extensible_note_card')),
        findsOneWidget,
      );

      // Verify shortcut navigation from 第三方数据导入 -> /import/csv and back
      await tester.ensureVisible(find.byKey(const Key('go_csv_import_button')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('go_csv_import_button')));
      await _settle(tester);
      expect(find.byKey(const Key('csv_import_page')), findsOneWidget);
      await _goBack(tester);
      expect(find.byKey(const Key('migration_page')), findsOneWidget);

      await _goBack(tester);

      // 3. Navigate MePage -> 币种与汇率 (/currencies)
      await tester.scrollUntilVisible(
        find.byKey(const Key('me-currencies')),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      await _settle(tester);
      await tester.tap(find.byKey(const Key('me-currencies')));
      await _settle(tester);

      final enableSwitch = find.byKey(const Key('online-rate-enable-switch'));
      expect(enableSwitch, findsOneWidget);
      expect(tester.widget<SwitchListTile>(enableSwitch).value, isFalse);
      expect(find.textContaining('默认离线（未开启联网汇率）'), findsOneWidget);
      expect(rateClientFactoryCalls, 0);
      expect(rateServer.requestedPaths, isEmpty);

      // Add USD manually while offline (still 0 network calls)
      await tester.tap(find.byKey(const Key('add-currency')));
      await _settle(tester);
      await tester.enterText(find.byKey(const Key('currency-code')), 'USD');
      await tester.enterText(find.byKey(const Key('currency-name')), '美元');
      await tester.enterText(find.byKey(const Key('currency-price')), '8.00');
      await tester.tap(find.byKey(const Key('currency-save')));
      await _settle(tester);
      expect(find.textContaining('1 USD = 8 CNY'), findsOneWidget);
      expect(rateClientFactoryCalls, 0);

      // Opt-in to online rate sync, configure loopback endpoint, and sync now
      await tester.tap(enableSwitch);
      await _settle(tester);
      expect(rateClientFactoryCalls, 0);

      await tester.tap(find.byKey(const Key('online-rate-source-btn')));
      await _settle(tester);
      await tester.enterText(
        find.byKey(const Key('online-rate-custom-url-input')),
        rateServer.url,
      );
      await tester.tap(find.byKey(const Key('online-rate-save-source')));
      await _settle(tester);

      await tester.tap(find.byKey(const Key('online-rate-sync-now')));
      await _settle(tester);

      expect(rateClientFactoryCalls, 1);
      expect(rateServer.requestedPaths, ['/cny-rates.json']);
      expect(find.textContaining('1 USD = 7.2 CNY'), findsOneWidget);

      // Advance clock by 25 hours, update quote on loopback server, and verify
      // TallyIsleApp._runLifecycleSync auto-refreshes rate on foreground resume!
      rateServer.usdQuote = '0.142857142857'; // 1 USD = 7 CNY
      clockMs += const Duration(hours: 25).inMilliseconds;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _settle(tester);

      expect(rateClientFactoryCalls, 2);
      expect(find.textContaining('1 USD = 7 CNY'), findsOneWidget);

      await cleanUp();
    },
  );

  testWidgets(
    'TallyIsleApp bookkeeping idle-debounce: db.tableUpdates() coalesces writes and triggers local .tally backup + S3 r1 push after idle window',
    (tester) async {
      final prevOverrides = HttpOverrides.current;
      HttpOverrides.global = null;

      var clockMs = DateTime(2026, 11, 12, 10, 0).millisecondsSinceEpoch;
      final db = AppDatabase(NativeDatabase.memory(), nowMs: () => clockMs);
      final reminderScheduler = InMemoryReminderScheduler();
      final s3Server = (await tester.runAsync(_LoopbackS3Server.start))!;
      final tempRoot = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('enh_idle_debounce_'),
      ))!;
      final localBkDir = Directory(p.join(tempRoot.path, 'local_bk'));
      final attDir = Directory(p.join(tempRoot.path, 'att'));

      var closed = false;
      Future<void> cleanUp() async {
        if (closed) return;
        closed = true;
        HttpOverrides.global = prevOverrides;
        await tester.pumpWidget(const SizedBox());
        await _settle(tester);
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(reminderScheduler.dispose);
        await tester.runAsync(s3Server.close);
        await tester.runAsync(db.close);
        await tester.runAsync(() async {
          if (await tempRoot.exists()) {
            await tempRoot.delete(recursive: true);
          }
        });
      }

      addTearDown(cleanUp);

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            reminderSchedulerProvider.overrideWithValue(reminderScheduler),
            backupLocalDirectoryOverrideProvider.overrideWithValue(
              () async => localBkDir,
            ),
            backupAttachmentsDirectoryOverrideProvider.overrideWithValue(
              () async => attDir,
            ),
            backupHttpClientFactoryProvider.overrideWithValue(HttpClient.new),
          ],
          child: const TallyIsleApp(),
        ),
      );
      await _settle(tester);

      // Configure loopback S3 + opt-in syncOnIdle (3 min) & backupOnIdle (5 min).
      final container = ProviderScope.containerOf(
        tester.element(find.byType(Scaffold).first),
      );
      final backupService = container
          .read(tallyBackupServiceProvider)
          .requireValue;
      await _pumpFuture(tester, () async {
        await backupService.saveS3Config(
          S3Config(
            endpoint: s3Server.endpoint,
            region: 'auto',
            bucket: _LoopbackS3Server.bucket,
            accessKeyId: _LoopbackS3Server.accessKey,
            secretAccessKey: _LoopbackS3Server.secretKey,
            remotePrefix: 'TallyIsle',
          ),
        );
        await backupService.setAutoArchiveBackupEnabled(false);
        await backupService.updateCloudSyncTriggers(
          syncOnStartup: false,
          syncOnExit: false,
          syncOnIdle: true,
          idleMinutes: 3,
          syncOnSchedule: false,
        );
        await backupService.saveLocalAutoBackupPolicy(
          const LocalAutoBackupPolicy(
            backupOnIdle: true,
            idleMinutes: 5,
            keepCount: 10,
          ),
        );
      });
      await _settle(tester);

      // Preference writes alone must NOT trigger business idle backup/sync.
      expect(s3Server.objects['TallyIsle/sync/head.json'], isNull);
      expect(await tester.runAsync(localBkDir.exists), isFalse);

      // Insert bookkeeping asset + expense record -> emits db.tableUpdates() on business tables!
      await _pumpFuture(tester, () async {
        final books = await db.select(db.accountBooks).get();
        final cats = await db.select(db.recordCategories).get();
        final expenseCat = cats.firstWhere((c) => c.type == RecordType.expense);
        final ledger = LedgerService(db);
        final assetId = await ledger.createAsset(
          commandId: 'idle-e2e-asset',
          name: '静置测试账户',
          type: AssetType.normal,
          initial: Money.parse('1000.00'),
        );
        await ledger.saveRecord(
          commandId: 'idle-e2e-record',
          draft: RecordDraft(
            bookId: books.first.id,
            type: RecordType.expense,
            money: Money.parse('45.80'),
            categoryId: expenseCat.id,
            assetId: assetId,
            recordTime: clockMs,
            remark: '静置防抖自动同步晚餐',
          ),
        );
      });
      await _settle(tester);

      // Before idle window elapses (2 minutes < 3 min cloud & 5 min local): nothing fired yet.
      clockMs += const Duration(minutes: 2).inMilliseconds;
      await tester.pump(const Duration(minutes: 2));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      expect(s3Server.objects['TallyIsle/sync/head.json'], isNull);
      expect(await tester.runAsync(localBkDir.exists), isFalse);

      // Advance past full 5-minute idle window: both cloud sync (3 min) and local backup (5 min) fire!
      clockMs += const Duration(minutes: 4).inMilliseconds;
      await tester.pump(const Duration(minutes: 4));
      await _settle(tester);

      final headBytes = s3Server.objects['TallyIsle/sync/head.json'];
      expect(headBytes, isNotNull);
      final head = CloudSyncHead.fromJson(
        jsonDecode(utf8.decode(headBytes!)) as Map<String, Object?>,
      );
      expect(head.revision, 1);
      expect(head.recordCount, 1);
      expect(s3Server.objects['TallyIsle/sync/latest_db.tally'], isNotNull);

      final localFiles = (await tester.runAsync(
        () =>
            localBkDir.list().where((e) => e.path.endsWith('.tally')).toList(),
      ))!;
      expect(localFiles, hasLength(1));

      await cleanUp();
    },
  );

  testWidgets(
    'TallyIsleApp desktop onExitRequested guard saves exit local .tally backup & pushes exit cloud snapshot before returning AppExitResponse.exit',
    (tester) async {
      final prevOverrides = HttpOverrides.current;
      HttpOverrides.global = null;

      final clockMs = DateTime(2026, 11, 12, 18, 30).millisecondsSinceEpoch;
      final db = AppDatabase(NativeDatabase.memory(), nowMs: () => clockMs);
      final reminderScheduler = InMemoryReminderScheduler();
      final s3Server = (await tester.runAsync(_LoopbackS3Server.start))!;
      final tempRoot = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('enh_desktop_exit_'),
      ))!;
      final localBkDir = Directory(p.join(tempRoot.path, 'local_bk'));
      final attDir = Directory(p.join(tempRoot.path, 'att'));

      var closed = false;
      Future<void> cleanUp() async {
        if (closed) return;
        closed = true;
        HttpOverrides.global = prevOverrides;
        await tester.pumpWidget(const SizedBox());
        await _settle(tester);
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(reminderScheduler.dispose);
        await tester.runAsync(s3Server.close);
        await tester.runAsync(db.close);
        await tester.runAsync(() async {
          if (await tempRoot.exists()) {
            await tempRoot.delete(recursive: true);
          }
        });
      }

      addTearDown(cleanUp);

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            reminderSchedulerProvider.overrideWithValue(reminderScheduler),
            backupLocalDirectoryOverrideProvider.overrideWithValue(
              () async => localBkDir,
            ),
            backupAttachmentsDirectoryOverrideProvider.overrideWithValue(
              () async => attDir,
            ),
            backupHttpClientFactoryProvider.overrideWithValue(HttpClient.new),
          ],
          child: const TallyIsleApp(),
        ),
      );
      await _settle(tester);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(Scaffold).first),
      );
      final backupService = container
          .read(tallyBackupServiceProvider)
          .requireValue;
      await _pumpFuture(tester, () async {
        await backupService.saveS3Config(
          S3Config(
            endpoint: s3Server.endpoint,
            region: 'auto',
            bucket: _LoopbackS3Server.bucket,
            accessKeyId: _LoopbackS3Server.accessKey,
            secretAccessKey: _LoopbackS3Server.secretKey,
            remotePrefix: 'TallyIsle',
          ),
        );
        await backupService.setAutoArchiveBackupEnabled(false);
        await backupService.updateCloudSyncTriggers(
          syncOnStartup: false,
          syncOnExit: true,
          syncOnIdle: false,
          syncOnSchedule: false,
        );
        await backupService.saveLocalAutoBackupPolicy(
          const LocalAutoBackupPolicy(backupOnExit: true, keepCount: 10),
        );

        final books = await db.select(db.accountBooks).get();
        final cats = await db.select(db.recordCategories).get();
        final expenseCat = cats.firstWhere((c) => c.type == RecordType.expense);
        final ledger = LedgerService(db);
        final assetId = await ledger.createAsset(
          commandId: 'exit-e2e-asset',
          name: '桌面现金账户',
          type: AssetType.normal,
          initial: Money.parse('600.00'),
        );
        await ledger.saveRecord(
          commandId: 'exit-e2e-record',
          draft: RecordDraft(
            bookId: books.first.id,
            type: RecordType.expense,
            money: Money.parse('19.90'),
            categoryId: expenseCat.id,
            assetId: assetId,
            recordTime: clockMs,
            remark: '关窗前自动备份同步测试',
          ),
        );
      });
      await _settle(tester);

      expect(s3Server.objects['TallyIsle/sync/head.json'], isNull);
      expect(await tester.runAsync(localBkDir.exists), isFalse);

      // Simulate desktop window close request via WidgetsBinding.instance.handleRequestAppExit().
      final exitResponse = await _pumpFuture(
        tester,
        WidgetsBinding.instance.handleRequestAppExit,
      );
      await _settle(tester);

      expect(exitResponse, AppExitResponse.exit);

      final headBytes = s3Server.objects['TallyIsle/sync/head.json'];
      expect(headBytes, isNotNull);
      final head = CloudSyncHead.fromJson(
        jsonDecode(utf8.decode(headBytes!)) as Map<String, Object?>,
      );
      expect(head.revision, 1);
      expect(head.recordCount, 1);

      final localFiles = (await tester.runAsync(
        () =>
            localBkDir.list().where((e) => e.path.endsWith('.tally')).toList(),
      ))!;
      expect(localFiles, hasLength(1));

      await cleanUp();
    },
  );

  testWidgets(
    'TallyIsleApp desktop widescreen (1280x800) renders centered maxWidth 960 shell without overflow and supports mouse drag scrolling',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final db = AppDatabase(NativeDatabase.memory());
      final reminderScheduler = InMemoryReminderScheduler();
      final tempRoot = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('enh_widescreen_'),
      ))!;

      var closed = false;
      Future<void> cleanUp() async {
        if (closed) return;
        closed = true;
        await tester.pumpWidget(const SizedBox());
        await _settle(tester);
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(reminderScheduler.dispose);
        await tester.runAsync(db.close);
        await tester.runAsync(() async {
          if (await tempRoot.exists()) {
            await tempRoot.delete(recursive: true);
          }
        });
      }

      addTearDown(cleanUp);

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            reminderSchedulerProvider.overrideWithValue(reminderScheduler),
            backupLocalDirectoryOverrideProvider.overrideWithValue(
              () async => Directory(p.join(tempRoot.path, 'local')),
            ),
            backupAttachmentsDirectoryOverrideProvider.overrideWithValue(
              () async => Directory(p.join(tempRoot.path, 'att')),
            ),
          ],
          child: const TallyIsleApp(),
        ),
      );
      await _settle(tester);
      expect(tester.takeException(), isNull);

      final shellFinder = find.byKey(const Key('desktop_widescreen_shell'));
      final frameFinder = find.byKey(const Key('desktop_widescreen_frame'));
      expect(shellFinder, findsOneWidget);
      expect(frameFinder, findsOneWidget);
      expect(tester.getSize(shellFinder), const Size(1280, 800));
      expect(tester.getSize(frameFinder), const Size(960, 800));
      expect(tester.getTopLeft(frameFinder).dx, 160.0);

      for (final tabLabel in const <String>['统计', '资产', '更多']) {
        await tester.tap(find.text(tabLabel));
        await _settle(tester);
        expect(tester.takeException(), isNull);
      }

      // Verify mouse drag scrolling works cleanly on MePage at 1280x800
      final scrollable = find.byType(Scrollable).first;
      final startOffset = tester
          .state<ScrollableState>(scrollable)
          .position
          .pixels;
      await tester.drag(
        scrollable,
        const Offset(0, -240),
        kind: PointerDeviceKind.mouse,
      );
      await _settle(tester);
      expect(
        tester.state<ScrollableState>(scrollable).position.pixels,
        greaterThan(startOffset),
      );
      expect(tester.takeException(), isNull);

      await cleanUp();
    },
  );
}
