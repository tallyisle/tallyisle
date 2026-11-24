import 'dart:async' show unawaited;
import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:tallyisle/app/app.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/catalog/catalog_queries.dart';
import 'package:tallyisle/data/catalog/catalog_service.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/data/tools/bank_card_service.dart';
import 'package:tallyisle/data/tools/template_remark_service.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/template_card_rules.dart';
import 'package:tallyisle/features/backup/backup_providers.dart';
import 'package:tallyisle/features/bank_cards/bank_card_editor_page.dart';
import 'package:tallyisle/features/bank_cards/bank_card_providers.dart';
import 'package:tallyisle/features/bank_cards/bank_cards_page.dart';
import 'package:tallyisle/features/categories/categories_page.dart';
import 'package:tallyisle/features/category_transfer/category_transfer_page.dart';
import 'package:tallyisle/features/common/desktop_modal_page.dart';
import 'package:tallyisle/features/records/record_editor_page.dart';
import 'package:tallyisle/features/reminder/reminder_providers.dart';
import 'package:tallyisle/features/tags/tags_page.dart';
import 'package:tallyisle/features/templates/templates_page.dart';
import 'package:tallyisle/platform/notifications.dart';

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

(AppDatabase, Future<void> Function()) _openTestDb(WidgetTester tester) {
  final db = AppDatabase(NativeDatabase.memory());
  var closed = false;
  Future<void> closeCleanly() async {
    if (closed) return;
    closed = true;
    await tester.pumpWidget(const SizedBox.shrink());
    await _settle(tester);
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(db.close);
  }

  addTearDown(closeCleanly);
  return (db, closeCleanly);
}

Widget _buildScopedApp(AppDatabase db, Widget home, {double textScale = 1.0}) =>
    ProviderScope(
      retry: (_, _) => null,
      overrides: [databaseProvider.overrideWith((ref) async => db)],
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: home,
      ),
    );

Future<void> _longPressDrag(
  WidgetTester tester,
  Finder target,
  Offset offset, {
  VoidCallback? onDragStarted,
}) async {
  final start = tester.getCenter(target);
  final gesture = await tester.startGesture(start);
  await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
  onDragStarted?.call();
  const steps = 12;
  for (var i = 0; i < steps; i++) {
    await gesture.moveBy(offset / steps.toDouble());
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  await _settle(tester);
}

Future<void> _mouseDragHandle(
  WidgetTester tester,
  Finder handle,
  Offset offset,
) async {
  final start = tester.getCenter(handle);
  final gesture = await tester.startGesture(
    start,
    kind: PointerDeviceKind.mouse,
  );
  await tester.pump(const Duration(milliseconds: 16));
  const steps = 12;
  for (var i = 0; i < steps; i++) {
    await gesture.moveBy(offset / steps.toDouble());
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  await _settle(tester);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets(
    'CategoriesPage mobile: long-press drag reorders top-level & expanded subcategories on both 支出/收入 tabs with haptics, elevated proxy, and TabBarView swipe coexistence',
    variant: TargetPlatformVariant.only(TargetPlatform.android),
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final haptics = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'HapticFeedback.vibrate') {
              haptics.add('${call.arguments}');
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      final (db, closeCleanly) = _openTestDb(tester);
      late RecordCategory foodCat;
      late RecordCategory shopCat;
      late int subBreakfastId;
      late int subCoffeeId;

      await tester.runAsync(() async {
        final svc = CatalogService(db);
        final cats = await CatalogQueries(db).getCategories(1);
        final expTops = cats
            .where((c) => c.type == RecordType.expense && c.parentCatId == -1)
            .toList();
        foodCat = expTops[0];
        shopCat = expTops[1];
        subBreakfastId = await svc.createCategory(
          commandId: 'seed-sub-bf',
          accountBookId: 1,
          name: '早餐包点',
          type: RecordType.expense,
          parentCatId: foodCat.id,
        );
        subCoffeeId = await svc.createCategory(
          commandId: 'seed-sub-cf',
          accountBookId: 1,
          name: '手冲咖啡',
          type: RecordType.expense,
          parentCatId: foodCat.id,
        );
      });

      await tester.pumpWidget(_buildScopedApp(db, const CategoriesPage()));
      await _settle(tester);
      expect(tester.takeException(), isNull);

      // Mobile renders no desktop drag handles and no arrow buttons
      expect(find.byIcon(Icons.drag_handle_rounded), findsNothing);
      expect(find.byIcon(Icons.arrow_upward), findsNothing);
      expect(find.byIcon(Icons.arrow_downward), findsNothing);

      // 1. Reorder subcategories ('手冲咖啡' above '早餐包点') inside expanded '餐饮'
      var sawElevatedProxy = false;
      await _longPressDrag(
        tester,
        find.byKey(const Key('category-手冲咖啡')),
        const Offset(0, -80),
        onDragStarted: () {
          sawElevatedProxy = tester
              .widgetList<Material>(find.byType(Material))
              .any((m) => m.elevation > 0);
        },
      );
      expect(haptics, contains('HapticFeedbackType.selectionClick'));
      expect(sawElevatedProxy, isTrue);

      var dbSubs = await tester.runAsync(() async {
        final cats = await CatalogQueries(db).getCategories(1);
        return cats
            .where((c) => c.parentCatId == foodCat.id)
            .map((c) => c.id)
            .toList();
      });
      expect(dbSubs, <int>[subCoffeeId, subBreakfastId]);

      // Collapse and re-expand '餐饮'
      await tester.tap(find.byKey(Key('toggle-expand-cat-${foodCat.id}')));
      await _settle(tester);
      expect(find.byKey(const Key('category-手冲咖啡')), findsNothing);
      await tester.tap(find.byKey(Key('toggle-expand-cat-${foodCat.id}')));
      await _settle(tester);
      expect(find.byKey(const Key('category-手冲咖啡')), findsOneWidget);

      // 2. Reorder top-level expense categories: drag second top-level above first
      await _longPressDrag(
        tester,
        find.byKey(Key('category-${shopCat.name}')),
        const Offset(0, -220),
      );
      final expTopIdsAfter = await tester.runAsync(() async {
        final cats = await CatalogQueries(db).getCategories(1);
        return cats
            .where((c) => c.type == RecordType.expense && c.parentCatId == -1)
            .map((c) => c.id)
            .toList();
      });
      expect(expTopIdsAfter!.first, shopCat.id);
      expect(expTopIdsAfter[1], foodCat.id);

      // 3. Horizontal swipe switches TabBarView cleanly from 支出分类 -> 收入分类
      final incBefore = await tester.runAsync(() async {
        final cats = await CatalogQueries(db).getCategories(1);
        return cats
            .where((c) => c.type == RecordType.income && c.parentCatId == -1)
            .toList();
      });
      await tester.fling(find.byType(TabBarView), const Offset(-300, 0), 1200);
      await _settle(tester);
      expect(find.byKey(Key('category-${incBefore![0].name}')), findsOneWidget);

      // 4. Reorder top-level income categories on 收入分类 tab
      await _longPressDrag(
        tester,
        find.byKey(Key('category-${incBefore[1].name}')),
        const Offset(0, -90),
      );
      final incAfter = await tester.runAsync(() async {
        final cats = await CatalogQueries(db).getCategories(1);
        return cats
            .where((c) => c.type == RecordType.income && c.parentCatId == -1)
            .map((c) => c.id)
            .toList();
      });
      expect(incAfter!.first, incBefore[1].id);
      expect(incAfter[1], incBefore[0].id);

      await closeCleanly();
    },
  );

  testWidgets(
    'CategoriesPage desktop: grab-cursor drag handles reorder top & sub categories without row click conflict, and B-12 navigates cleanly in MePage dual-pane & PopupRoute modal',
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
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
        () => Directory.systemTemp.createTemp('cat_desk_b12_'),
      ))!;

      late RecordCategory foodCat;
      late RecordCategory shopCat;
      late int subOneId;
      late int subTwoId;

      await tester.runAsync(() async {
        final svc = CatalogService(db);
        final cats = await CatalogQueries(db).getCategories(1);
        final expTops = cats
            .where((c) => c.type == RecordType.expense && c.parentCatId == -1)
            .toList();
        foodCat = expTops[0];
        shopCat = expTops[1];
        subOneId = await svc.createCategory(
          commandId: 'desk-sub-1',
          accountBookId: 1,
          name: '工作午餐',
          type: RecordType.expense,
          parentCatId: foodCat.id,
        );
        subTwoId = await svc.createCategory(
          commandId: 'desk-sub-2',
          accountBookId: 1,
          name: '团队聚餐',
          type: RecordType.expense,
          parentCatId: foodCat.id,
        );
      });

      var closed = false;
      Future<void> cleanUp() async {
        if (closed) return;
        closed = true;
        await tester.pumpWidget(const SizedBox.shrink());
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

      // Navigate to 更多 -> 分类管理 in 1280x800 dual-pane
      await tester.tap(find.byKey(const Key('nav-slot-more')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('me-categories')));
      await _settle(tester);

      final paneFinder = find.byKey(const Key('me-desktop-content-pane'));
      expect(
        find.descendant(of: paneFinder, matching: find.byType(CategoriesPage)),
        findsOneWidget,
      );

      // Verify explicit grab cursor MouseRegion on desktop drag handle
      final subTwoHandle = find.byKey(Key('cat-drag-handle-$subTwoId'));
      expect(subTwoHandle, findsOneWidget);
      final handleMouseRegion = tester.widget<MouseRegion>(
        find
            .ancestor(of: subTwoHandle, matching: find.byType(MouseRegion))
            .first,
      );
      expect(handleMouseRegion.cursor, SystemMouseCursors.grab);

      // Instant mouse drag on subcategory handle reorders subcategories
      await _mouseDragHandle(tester, subTwoHandle, const Offset(0, -70));
      final subOrder = await tester.runAsync(() async {
        final cats = await CatalogQueries(db).getCategories(1);
        return cats
            .where((c) => c.parentCatId == foodCat.id)
            .map((c) => c.id)
            .toList();
      });
      expect(subOrder, <int>[subTwoId, subOneId]);

      // Instant mouse drag on top-level handle reorders top-level categories
      await _mouseDragHandle(
        tester,
        find.byKey(Key('cat-drag-handle-${shopCat.id}')),
        const Offset(0, -200),
      );
      final topOrder = await tester.runAsync(() async {
        final cats = await CatalogQueries(db).getCategories(1);
        return cats
            .where((c) => c.type == RecordType.expense && c.parentCatId == -1)
            .map((c) => c.id)
            .toList();
      });
      expect(topOrder!.first, shopCat.id);
      expect(topOrder[1], foodCat.id);

      // B-12 Case 1: Inside MePage dual-pane (MeEmbeddedNavigationScope != null),
      // clicking categories-transfer-action switches the right stage in-place!
      await tester.tap(find.byKey(const Key('categories-transfer-action')));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(
        find.descendant(
          of: paneFinder,
          matching: find.byType(CategoryTransferPage),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: paneFinder, matching: find.byType(BackButton)),
        findsNothing,
      );

      // B-12 Case 2: Switch MePage right stage to /books, then open CategoriesPage
      // inside a desktop PopupRoute modal WHILE underlying GoRouter path is STILL '/me'!
      await tester.tap(find.byKey(const Key('me-books')));
      await _settle(tester);
      final rootCtx = tester.element(find.byKey(const Key('desktop-sidebar')));
      expect(
        GoRouter.of(rootCtx).routerDelegate.currentConfiguration.uri.path,
        '/me',
      );

      unawaited(
        pushDesktopModalOrMaterialRoute<void>(
          rootCtx,
          maxWidth: 760,
          maxHeight: 720,
          barrierDismissible: true,
          child: const CategoriesPage(),
        ),
      );
      await _settle(tester);
      expect(find.byType(Dialog), findsOneWidget);

      final modalTransferBtn = find.descendant(
        of: find.byType(Dialog),
        matching: find.byKey(const Key('categories-transfer-action')),
      );
      await tester.tap(modalTransferBtn);
      await _settle(tester);
      expect(tester.takeException(), isNull);

      // CategoryTransferPage opened in a modal Dialog over the popup without mutating MePage's /books stage!
      expect(find.byType(Dialog), findsNWidgets(2));
      expect(
        find.descendant(
          of: find.byType(Dialog).last,
          matching: find.byType(CategoryTransferPage),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: paneFinder,
          matching: find.byType(CategoryTransferPage),
        ),
        findsNothing,
      );

      await cleanUp();
    },
  );

  testWidgets(
    'TagsPage dual-platform drag reorder: groups, child tags, and standalone tags reorder cleanly and match RecordEditorPage tag order',
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final (db, closeCleanly) = _openTestDb(tester);
      late String grpAId;
      late String grpBId;
      late String childA1Id;
      late String childA2Id;
      late String childB1Id;
      late String solo1Id;
      late String solo2Id;

      await tester.runAsync(() async {
        final svc = CatalogService(db);
        grpAId = await svc.createTag(
          commandId: 't-ga',
          name: '项目A组',
          isGroup: true,
          color: '#1E88E5',
        );
        childA1Id = await svc.createTag(
          commandId: 't-ca1',
          name: '机票A1',
          parentTagId: grpAId,
        );
        childA2Id = await svc.createTag(
          commandId: 't-ca2',
          name: '酒店A2',
          parentTagId: grpAId,
        );
        grpBId = await svc.createTag(
          commandId: 't-gb',
          name: '家庭B组',
          isGroup: true,
          color: '#43A047',
        );
        childB1Id = await svc.createTag(
          commandId: 't-cb1',
          name: '物业B1',
          parentTagId: grpBId,
        );
        solo1Id = await svc.createTag(commandId: 't-s1', name: '独立甲');
        solo2Id = await svc.createTag(commandId: 't-s2', name: '独立乙');
      });

      await tester.pumpWidget(_buildScopedApp(db, const TagsPage()));
      await _settle(tester);
      expect(tester.takeException(), isNull);

      // 1. Reorder child tags inside 项目A组: drag 酒店A2 above 机票A1
      await _mouseDragHandle(
        tester,
        find.byKey(Key('tag-drag-handle-$childA2Id')),
        const Offset(0, -70),
      );

      // 2. Reorder tag groups: drag 家庭B组 above 项目A组
      await _mouseDragHandle(
        tester,
        find.byKey(Key('tag-drag-handle-$grpBId')),
        const Offset(0, -220),
      );

      // 3. Reorder standalone tags: drag 独立乙 above 独立甲
      await _mouseDragHandle(
        tester,
        find.byKey(Key('tag-drag-handle-$solo2Id')),
        const Offset(0, -70),
      );

      // Verify full canonical sort order in DB:
      // [家庭B组, 物业B1, 项目A组, 酒店A2, 机票A1, 独立乙, 独立甲]
      final dbTagIds = await tester.runAsync(() async {
        final tags = await CatalogQueries(db).getTags();
        return tags.map((t) => t.tagId).toList();
      });
      expect(dbTagIds, <String>[
        grpBId,
        childB1Id,
        grpAId,
        childA2Id,
        childA1Id,
        solo2Id,
        solo1Id,
      ]);

      // Toggle group collapse/expand without triggering stats navigation
      await tester.tap(find.byKey(Key('toggle-expand-tag-$grpAId')));
      await _settle(tester);
      expect(find.byKey(const Key('tag-酒店A2')), findsNothing);
      await tester.tap(find.byKey(Key('toggle-expand-tag-$grpAId')));
      await _settle(tester);
      expect(find.byKey(const Key('tag-酒店A2')), findsOneWidget);

      // Verify RecordEditorPage displays selectable tags in the EXACT reordered sequence:
      // [物业B1, 酒店A2, 机票A1, 独立乙, 独立甲]
      await tester.pumpWidget(_buildScopedApp(db, const RecordEditorPage()));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('editor-tags-pill')));
      await _settle(tester);
      expect(
        find.byKey(const Key('desktop-tag-picker-dialog')),
        findsOneWidget,
      );

      final renderedChipNames = tester
          .widgetList<FilterChip>(
            find.descendant(
              of: find.byKey(const Key('desktop-tag-picker-dialog')),
              matching: find.byType(FilterChip),
            ),
          )
          .map((chip) => (chip.label as Text).data!)
          .toList();
      expect(renderedChipNames, <String>['物业B1', '酒店A2', '机票A1', '独立乙', '独立甲']);

      await closeCleanly();
    },
  );

  testWidgets(
    'TagsPage mobile: long-press drag reorders standalone & child tags with haptic feedback',
    variant: TargetPlatformVariant.only(TargetPlatform.android),
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final (db, closeCleanly) = _openTestDb(tester);
      late String soloFirst;
      late String soloSecond;

      await tester.runAsync(() async {
        final svc = CatalogService(db);
        soloFirst = await svc.createTag(commandId: 'm-s1', name: '通勤地铁');
        soloSecond = await svc.createTag(commandId: 'm-s2', name: '周末露营');
      });

      await tester.pumpWidget(_buildScopedApp(db, const TagsPage()));
      await _settle(tester);
      expect(find.byIcon(Icons.drag_handle_rounded), findsNothing);

      await _longPressDrag(
        tester,
        find.byKey(const Key('tag-周末露营')),
        const Offset(0, -80),
      );

      final dbTagIds = await tester.runAsync(() async {
        final tags = await CatalogQueries(db).getTags();
        return tags.map((t) => t.tagId).toList();
      });
      expect(dbTagIds, <String>[soloSecond, soloFirst]);

      await closeCleanly();
    },
  );

  testWidgets(
    'TemplatesPage dual-platform drag reorder preserves relative slots of non-visible templates when filtered by record type or book',
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
    (tester) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final (db, closeCleanly) = _openTestDb(tester);
      late int tExp1;
      late int tInc1;
      late int tExp2;
      late int tTrf1;
      late int tExp3;
      late int tBook2Exp;

      await tester.runAsync(() async {
        final catalog = CatalogService(db);
        final book2Id = await catalog.createBook(
          commandId: 'tpl-b2',
          name: '副账本',
          startDay: 1,
        );
        final cats = await CatalogQueries(db).getCategories(1);
        final expCat = cats.firstWhere((c) => c.type == RecordType.expense);
        final incCat = cats.firstWhere((c) => c.type == RecordType.income);
        final a1 = await LedgerService(db).createAsset(
          commandId: 'tpl-a1',
          name: '账户甲',
          initial: Money.parse('1000.00'),
        );
        final a2 = await LedgerService(db).createAsset(
          commandId: 'tpl-a2',
          name: '账户乙',
          initial: Money.parse('1000.00'),
        );

        final svc = TemplateRemarkService(db);
        tExp1 = await svc.saveTemplate(
          commandId: 'seed-t1',
          draft: TemplateDraft(
            type: RecordType.expense,
            money: Money.parse('10.00'),
            bookId: 1,
            name: '支出模板一',
            categoryId: expCat.id,
          ),
        );
        tInc1 = await svc.saveTemplate(
          commandId: 'seed-t2',
          draft: TemplateDraft(
            type: RecordType.income,
            money: Money.parse('200.00'),
            bookId: 1,
            name: '收入模板固定槽',
            categoryId: incCat.id,
          ),
        );
        tExp2 = await svc.saveTemplate(
          commandId: 'seed-t3',
          draft: TemplateDraft(
            type: RecordType.expense,
            money: Money.parse('20.00'),
            bookId: 1,
            name: '支出模板二',
            categoryId: expCat.id,
          ),
        );
        tTrf1 = await svc.saveTemplate(
          commandId: 'seed-t4',
          draft: TemplateDraft(
            type: RecordType.transfer,
            money: Money.parse('50.00'),
            bookId: 1,
            name: '转账模板固定槽',
            assetId: a1,
            assetId2: a2,
          ),
        );
        tExp3 = await svc.saveTemplate(
          commandId: 'seed-t5',
          draft: TemplateDraft(
            type: RecordType.expense,
            money: Money.parse('30.00'),
            bookId: 1,
            name: '支出模板三',
            categoryId: expCat.id,
          ),
        );
        tBook2Exp = await svc.saveTemplate(
          commandId: 'seed-t6',
          draft: TemplateDraft(
            type: RecordType.expense,
            money: Money.parse('99.00'),
            bookId: book2Id,
            name: '副账本模板固定槽',
          ),
        );
      });

      await tester.pumpWidget(_buildScopedApp(db, const TemplatesPage()));
      await _settle(tester);

      // Filter to Book 1 ('日常账本') AND type '支出'
      await tester.tap(find.byKey(const Key('templates_book_filter')));
      await _settle(tester);
      await tester.tap(find.text('日常账本').last);
      await _settle(tester);

      await tester.tap(find.byKey(const Key('template_filter_0')));
      await _settle(tester);

      // Only [tExp1, tExp2, tExp3] are visible
      expect(find.text('支出模板一'), findsOneWidget);
      expect(find.text('支出模板二'), findsOneWidget);
      expect(find.text('支出模板三'), findsOneWidget);
      expect(find.text('收入模板固定槽'), findsNothing);
      expect(find.text('转账模板固定槽'), findsNothing);
      expect(find.text('副账本模板固定槽'), findsNothing);

      // Drag 支出模板三 above 支出模板一 -> visible becomes [tExp3, tExp1, tExp2]
      await _mouseDragHandle(
        tester,
        find.byKey(Key('template-drag-handle-$tExp3')),
        const Offset(0, -320),
      );

      // Switch back to 全部账本 + 全部 type and verify non-visible templates kept exact slots!
      await tester.tap(find.byKey(const Key('template_filter_all')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('templates_book_filter')));
      await _settle(tester);
      await tester.tap(find.text('全部账本').last);
      await _settle(tester);

      final allIds = await tester.runAsync(() async {
        final rows = await TemplateRemarkService(db).getTemplates();
        return rows.map((t) => t.id).toList();
      });
      // Original: [tExp1(0), tInc1(1), tExp2(2), tTrf1(3), tExp3(4), tBook2Exp(5)]
      // Permuting slots {0, 2, 4} -> [tExp3, tExp1, tExp2] yields:
      expect(allIds, <int>[tExp3, tInc1, tExp1, tTrf1, tExp2, tBook2Exp]);

      await closeCleanly();
    },
  );

  testWidgets(
    'TemplatesPage mobile: long-press anywhere on template card triggers drag reorder',
    variant: TargetPlatformVariant.only(TargetPlatform.android),
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final (db, closeCleanly) = _openTestDb(tester);
      late int t1;
      late int t2;

      await tester.runAsync(() async {
        final svc = TemplateRemarkService(db);
        t1 = await svc.saveTemplate(
          commandId: 'm-tpl-1',
          draft: TemplateDraft(
            type: RecordType.expense,
            money: Money.parse('12.00'),
            bookId: 1,
            name: '移动端模板甲',
          ),
        );
        t2 = await svc.saveTemplate(
          commandId: 'm-tpl-2',
          draft: TemplateDraft(
            type: RecordType.expense,
            money: Money.parse('28.00'),
            bookId: 1,
            name: '移动端模板乙',
          ),
        );
      });

      await tester.pumpWidget(_buildScopedApp(db, const TemplatesPage()));
      await _settle(tester);
      expect(find.byIcon(Icons.drag_handle_rounded), findsNothing);

      await _longPressDrag(
        tester,
        find.byKey(Key('template_card_$t2')),
        const Offset(0, -180),
      );

      final ids = await tester.runAsync(() async {
        final rows = await TemplateRemarkService(db).getTemplates();
        return rows.map((r) => r.id).toList();
      });
      expect(ids, <int>[t2, t1]);

      await closeCleanly();
    },
  );

  testWidgets(
    'BankCardsPage desktop: grab-cursor drag handle reorders filtered credit cards while preserving debit card slots',
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
    (tester) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final (db, closeCleanly) = _openTestDb(tester);
      late int d1;
      late int c1;
      late int c2;

      await tester.runAsync(() async {
        final svc = BankCardService(db);
        d1 = await svc.saveBankCard(
          commandId: 'desk-bc-d1',
          draft: const BankCardDraft(
            cardType: BankCardType.debit,
            cardName: '桌面储蓄锚点卡',
            cardNo: '6225880111111111',
          ),
        );
        c1 = await svc.saveBankCard(
          commandId: 'desk-bc-c1',
          draft: const BankCardDraft(
            cardType: BankCardType.credit,
            cardName: '桌面信用一卡',
            cardNo: '6225880222222222',
          ),
        );
        c2 = await svc.saveBankCard(
          commandId: 'desk-bc-c2',
          draft: const BankCardDraft(
            cardType: BankCardType.credit,
            cardName: '桌面信用二卡',
            cardNo: '6225880333333333',
          ),
        );
        await svc.reorderBankCards(
          commandId: 'desk-bc-order',
          orderedIds: <int>[d1, c1, c2],
        );
      });

      await tester.pumpWidget(_buildScopedApp(db, const BankCardsPage()));
      await _settle(tester);

      await tester.tap(find.byKey(const Key('card_filter_1')));
      await _settle(tester);

      await _mouseDragHandle(
        tester,
        find.byKey(Key('bank-card-drag-handle-$c2')),
        const Offset(0, -240),
      );

      final ids = await tester.runAsync(() async {
        final cards = await BankCardService(db).getBankCards();
        return cards.map((c) => c.id).toList();
      });
      expect(ids, <int>[d1, c2, c1]);

      await closeCleanly();
    },
  );

  testWidgets(
    'BankCardsPage: 3-page PageView syncs two-way with SegmentedButton, and filtered drag reorder preserves non-visible card slots on mobile & desktop',
    variant: TargetPlatformVariant.only(TargetPlatform.android),
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final (db, closeCleanly) = _openTestDb(tester);
      late int debitA;
      late int creditA;
      late int debitB;
      late int creditB;

      await tester.runAsync(() async {
        final svc = BankCardService(db);
        // Note: saveBankCard prepends new cards with minSort - 1, so we set explicit
        // initial order via reorderBankCards!
        debitA = await svc.saveBankCard(
          commandId: 'bc-1',
          draft: const BankCardDraft(
            cardType: BankCardType.debit,
            cardName: '招行储蓄甲',
            cardNo: '6225880111111111',
          ),
        );
        creditA = await svc.saveBankCard(
          commandId: 'bc-2',
          draft: const BankCardDraft(
            cardType: BankCardType.credit,
            cardName: '招行信用甲',
            cardNo: '6225880222222222',
          ),
        );
        debitB = await svc.saveBankCard(
          commandId: 'bc-3',
          draft: const BankCardDraft(
            cardType: BankCardType.debit,
            cardName: '工行储蓄乙',
            cardNo: '6222020333333333',
          ),
        );
        creditB = await svc.saveBankCard(
          commandId: 'bc-4',
          draft: const BankCardDraft(
            cardType: BankCardType.credit,
            cardName: '建行信用乙',
            cardNo: '6227000444444444',
          ),
        );
        await svc.reorderBankCards(
          commandId: 'bc-init-order',
          orderedIds: <int>[debitA, creditA, debitB, creditB],
        );
      });

      late ProviderContainer container;
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: Builder(
            builder: (context) {
              container = ProviderScope.containerOf(context);
              return const MaterialApp(home: BankCardsPage());
            },
          ),
        ),
      );
      await _settle(tester);

      // Starts on Page 0 (全部 -> null)
      expect(container.read(bankCardFilterProvider), isNull);
      expect(find.text('招行储蓄甲'), findsOneWidget);
      expect(find.text('招行信用甲'), findsOneWidget);

      // 1. Horizontal swipe left -> Page 1 (储蓄卡 -> BankCardType.debit)
      await tester.fling(
        find.byKey(const Key('bank_cards_page_view')),
        const Offset(-320, 0),
        1200,
      );
      await _settle(tester);
      expect(container.read(bankCardFilterProvider), BankCardType.debit);
      expect(find.text('招行储蓄甲'), findsOneWidget);
      expect(find.text('工行储蓄乙'), findsOneWidget);
      expect(find.text('招行信用甲'), findsNothing);

      // 2. Long-press drag on 储蓄卡 tab: move 工行储蓄乙 above 招行储蓄甲
      await _longPressDrag(
        tester,
        find.byKey(Key('bank_card_item_$debitB')),
        const Offset(0, -240),
      );

      // Verify full card order preserved creditA(1) & creditB(3): [debitB, creditA, debitA, creditB]
      final reorderedIds = await tester.runAsync(() async {
        final cards = await BankCardService(db).getBankCards();
        return cards.map((c) => c.id).toList();
      });
      expect(reorderedIds, <int>[debitB, creditA, debitA, creditB]);

      // 3. Horizontal swipe left again -> Page 2 (信用卡 -> BankCardType.credit)
      await tester.fling(
        find.byKey(const Key('bank_cards_page_view')),
        const Offset(-320, 0),
        1200,
      );
      await _settle(tester);
      expect(container.read(bankCardFilterProvider), BankCardType.credit);
      expect(find.text('招行信用甲'), findsOneWidget);
      expect(find.text('建行信用乙'), findsOneWidget);
      expect(find.text('工行储蓄乙'), findsNothing);

      // 4. Tap SegmentedButton '全部' (jumps Page 2 -> Page 0 without intermediate clobber!)
      await tester.tap(find.byKey(const Key('card_filter_all')));
      await _settle(tester);
      expect(container.read(bankCardFilterProvider), isNull);
      expect(find.text('工行储蓄乙'), findsOneWidget);
      expect(find.text('招行信用甲'), findsOneWidget);

      await closeCleanly();
    },
  );

  testWidgets(
    'Zero RenderBox overflow audit across 360x640 @ 1.2x mobile and 520x600 / 900x700 / 1280x800 desktop viewports',
    (tester) async {
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final (db, closeCleanly) = _openTestDb(tester);
      late int cardId;

      await tester.runAsync(() async {
        final catSvc = CatalogService(db);
        final cats = await CatalogQueries(db).getCategories(1);
        final food = cats.firstWhere((c) => c.type == RecordType.expense);
        await catSvc.createCategory(
          commandId: 'ov-sub',
          accountBookId: 1,
          name: '超长二级分类名称压力测试不溢出',
          type: RecordType.expense,
          parentCatId: food.id,
        );
        final grp = await catSvc.createTag(
          commandId: 'ov-grp',
          name: '超长年度差旅项目标签组名称',
          isGroup: true,
          color: '#1565C0',
        );
        await catSvc.createTag(
          commandId: 'ov-child',
          name: '国际长途高铁机票住宿子标签',
          parentTagId: grp,
          color: '#E53935',
        );
        await catSvc.createTag(commandId: 'ov-solo', name: '独立长名称日常消费标签项');
        await TemplateRemarkService(db).saveTemplate(
          commandId: 'ov-tpl',
          draft: TemplateDraft(
            type: RecordType.expense,
            money: Money.parse('1288.88'),
            bookId: 1,
            name: '长标题工作日团队午餐秒记账单模板',
            categoryId: food.id,
            remark: '含备注与标签展示测试',
          ),
        );
        await TemplateRemarkService(db).createRemark(
          commandId: 'ov-rem',
          content: '常用备注多尺寸排版不溢出测试词条',
          recordCatId: food.id,
          usedTimes: 12,
        );
        cardId = await BankCardService(db).saveBankCard(
          commandId: 'ov-card',
          draft: const BankCardDraft(
            cardType: BankCardType.credit,
            cardName: '招商银行经典白金全币种信用卡',
            cardNo: '4111111111111111',
            cardOwner: '欧阳测试持卡人',
            remark: '上海陆家嘴营业部自动还款备注',
            cardColor: '#1565C0|icon:builtin:bank.cmb',
          ),
        );
      });

      final pages = <Widget Function()>[
        () => const CategoriesPage(),
        () => const TagsPage(),
        () => const TemplatesPage(),
        () => const RemarksPage(),
        () => const BankCardsPage(),
        () => BankCardEditorPage(cardId: cardId),
      ];

      // 1. Mobile 360x640 @ 1.2x text scale
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      for (final buildPage in pages) {
        await tester.pumpWidget(
          _buildScopedApp(db, buildPage(), textScale: 1.2),
        );
        await _settle(tester);
        expect(tester.takeException(), isNull);
      }

      // 2. Desktop 520x600, 900x700, 1280x800
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      for (final size in const <Size>[
        Size(520, 600),
        Size(900, 700),
        Size(1280, 800),
      ]) {
        tester.view.physicalSize = size;
        for (final buildPage in pages) {
          await tester.pumpWidget(_buildScopedApp(db, buildPage()));
          await _settle(tester);
          expect(tester.takeException(), isNull);
        }
      }

      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      await closeCleanly();
    },
  );

  testWidgets(
    'CategoriesPage top-level drag toward bottom edge auto-scrolls viewport and reorders below the fold on 390x640',
    variant: TargetPlatformVariant.only(TargetPlatform.android),
    (tester) async {
      tester.view.physicalSize = const Size(390, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final (db, closeCleanly) = _openTestDb(tester);
      late RecordCategory firstExpCat;

      await tester.runAsync(() async {
        final svc = CatalogService(db);
        for (var i = 1; i <= 6; i++) {
          await svc.createCategory(
            commandId: 'autoscroll-cat-$i',
            accountBookId: 1,
            name: '扩展支出分类$i',
            type: RecordType.expense,
          );
        }
        final cats = await CatalogQueries(db).getCategories(1);
        firstExpCat = cats.firstWhere(
          (c) => c.type == RecordType.expense && c.parentCatId == -1,
        );
      });

      await tester.pumpWidget(_buildScopedApp(db, const CategoriesPage()));
      await _settle(tester);

      final reorderListFinder = find.byKey(
        const ValueKey('categories-reorder-top-1-0'),
      );
      final scrollableFinder = find.descendant(
        of: reorderListFinder,
        matching: find.byType(Scrollable),
      );
      final scrollableState = tester.state<ScrollableState>(
        scrollableFinder.first,
      );
      expect(scrollableState.position.maxScrollExtent, greaterThan(200));
      expect(scrollableState.position.pixels, 0);

      // Long-press the first top-level category and drag down to the bottom edge (y = 620)
      final start = tester.getCenter(
        find.byKey(Key('category-${firstExpCat.name}')),
      );
      final gesture = await tester.startGesture(start);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));

      final deltaToBottomEdge = Offset(0, 620 - start.dy);
      for (var i = 0; i < 10; i++) {
        await gesture.moveBy(deltaToBottomEdge / 10.0);
        await tester.pump(const Duration(milliseconds: 16));
      }
      // Hold near bottom edge while EdgeDraggingAutoScroller scrolls down
      for (var i = 0; i < 24; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      final scrolledPixels = scrollableState.position.pixels;
      expect(scrolledPixels, greaterThan(150));

      await gesture.up();
      await _settle(tester);

      final reorderedTopIds = await tester.runAsync(() async {
        final cats = await CatalogQueries(db).getCategories(1);
        return cats
            .where((c) => c.type == RecordType.expense && c.parentCatId == -1)
            .map((c) => c.id)
            .toList();
      });
      final newIdx = reorderedTopIds!.indexOf(firstExpCat.id);
      expect(newIdx, greaterThanOrEqualTo(8));

      await closeCleanly();
    },
  );

  testWidgets(
    'CategoriesPage pushed via imperative MaterialPageRoute inside a GoRouter app opens CategoryTransferPage on top without mutating GoRouter underneath',
    variant: TargetPlatformVariant.only(TargetPlatform.android),
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final (db, closeCleanly) = _openTestDb(tester);
      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(
            path: '/',
            builder: (context, _) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  key: const Key('push-imperative-categories'),
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const CategoriesPage(),
                      ),
                    );
                  },
                  child: const Text('打开分类管理'),
                ),
              ),
            ),
          ),
          GoRoute(
            path: '/categories/transfer',
            builder: (_, _) => const CategoryTransferPage(),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await _settle(tester);

      // Push CategoriesPage via imperative MaterialPageRoute (as RecordEditorPage does on mobile)
      await tester.tap(find.byKey(const Key('push-imperative-categories')));
      await _settle(tester);
      expect(find.byType(CategoriesPage), findsOneWidget);
      expect(router.routerDelegate.currentConfiguration.uri.path, '/');

      // Tap categories-transfer-action -> pushes CategoryTransferPage on top via imperative route!
      await tester.tap(find.byKey(const Key('categories-transfer-action')));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(CategoryTransferPage), findsOneWidget);
      expect(router.routerDelegate.currentConfiguration.uri.path, '/');

      // Popping CategoryTransferPage returns cleanly to imperative CategoriesPage!
      await tester.tap(find.byType(BackButton));
      await _settle(tester);
      expect(find.byType(CategoryTransferPage), findsNothing);
      expect(find.byType(CategoriesPage), findsOneWidget);

      await closeCleanly();
    },
  );
}
