import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/app/app.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/catalog/catalog_service.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/data/repo/search_queries.dart';
import 'package:tallyisle/domain/model/codes.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets(
    'Tags closed loop: color picker, bill count badges, TagRankingsPage, TagDetailStatsPage, RecordDetailPage tag jump, StatsPage card, and SearchPage tag filter without duplicates',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: const TallyIsleApp(),
        ),
      );

      Future<void> settle() async {
        for (var i = 0; i < 12; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
      }

      await settle();

      // 1. Navigate to "我的" -> "标签管理" (/tags)
      await tester.tap(find.text('更多'));
      await settle();
      await tester.tap(find.byKey(const Key('me-tags')));
      await settle();
      expect(find.text('标签管理'), findsOneWidget);

      // Create tag group "2026日本旅行" with color #1E88E5
      await tester.tap(find.byKey(const Key('add-tag')));
      await settle();
      await tester.enterText(find.byKey(const Key('tag-name')), '2026日本旅行');
      await tester.tap(find.text('作为一级标签组'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('tag-color-#1E88E5')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('tag-save')));
      await settle();
      expect(find.text('2026日本旅行'), findsOneWidget);

      final allAfterGrp = await db.select(db.tags).get();
      final grpTag = allAfterGrp.singleWhere((t) => t.name == '2026日本旅行');
      expect(grpTag.color, '#1E88E5');
      expect(grpTag.parent, 1);

      // Create child tag "机票" (#E53935) and "酒店" (#8E24AA) under "2026日本旅行"
      await tester.tap(find.byKey(Key('add-subtag-${grpTag.tagId}')));
      await settle();
      await tester.enterText(find.byKey(const Key('tag-name')), '机票');
      await tester.tap(find.byKey(const Key('tag-color-#E53935')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('tag-save')));
      await settle();

      await tester.tap(find.byKey(Key('add-subtag-${grpTag.tagId}')));
      await settle();
      await tester.enterText(find.byKey(const Key('tag-name')), '酒店');
      await tester.tap(find.byKey(const Key('tag-color-#8E24AA')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('tag-save')));
      await settle();

      // Create standalone tag "聚餐" (#43A047)
      await tester.tap(find.byKey(const Key('add-tag')));
      await settle();
      await tester.enterText(find.byKey(const Key('tag-name')), '聚餐');
      await tester.tap(find.byKey(const Key('tag-color-#43A047')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('tag-save')));
      await settle();

      final createdTags = await db.select(db.tags).get();
      final flightTag = createdTags.singleWhere((t) => t.name == '机票');
      final hotelTag = createdTags.singleWhere((t) => t.name == '酒店');
      final partyTag = createdTags.singleWhere((t) => t.name == '聚餐');
      expect(flightTag.color, '#E53935');
      expect(hotelTag.color, '#8E24AA');
      expect(partyTag.color, '#43A047');

      // 2. Record tagged bills (including a bill 90 days ago with TWO child tags of the same group!)
      final cats = await db.select(db.recordCategories).get();
      final trafficCat = cats.firstWhere((c) => c.name == '交通');
      final foodCat = cats.firstWhere((c) => c.name == '餐饮');
      final incomeCat = cats.firstWhere((c) => c.type == 1);

      final ledger = LedgerService(db);
      final now = DateTime.now();
      final threeMonthsAgo = DateTime(now.year, now.month - 3, 10, 12, 0);
      final todayNoon = DateTime(now.year, now.month, now.day, 12, 0);

      final bill1Id = await ledger.saveRecord(
        commandId: 'cmd-bill-1',
        draft: RecordDraft(
          type: RecordType.expense,
          money: Money.parse('3200.00'),
          bookId: 1,
          recordTime: threeMonthsAgo.millisecondsSinceEpoch,
          categoryId: trafficCat.id,
          remark: '往返机票与首晚住宿',
          tagIds: [flightTag.tagId, hotelTag.tagId],
        ),
      );

      final bill2Id = await ledger.saveRecord(
        commandId: 'cmd-bill-2',
        draft: RecordDraft(
          type: RecordType.expense,
          money: Money.parse('480.00'),
          bookId: 1,
          recordTime: todayNoon.millisecondsSinceEpoch,
          categoryId: foodCat.id,
          remark: '老友火锅',
          tagIds: [partyTag.tagId, hotelTag.tagId],
        ),
      );

      await ledger.saveRecord(
        commandId: 'cmd-bill-3',
        draft: RecordDraft(
          type: RecordType.income,
          money: Money.parse('200.00'),
          bookId: 1,
          recordTime: todayNoon.millisecondsSinceEpoch + 1000,
          categoryId: incomeCat.id,
          remark: '机票退税返现',
          tagIds: [flightTag.tagId],
        ),
      );

      await ledger.saveRecord(
        commandId: 'cmd-bill-4',
        draft: RecordDraft(
          type: RecordType.expense,
          money: Money.parse('35.00'),
          bookId: 1,
          recordTime: todayNoon.millisecondsSinceEpoch + 2000,
          categoryId: foodCat.id,
          remark: '无标签早餐',
        ),
      );

      await settle();

      // 3. Verify reactive distinct bill count badges on TagsPage
      expect(
        tester
            .widget<Text>(
              find.descendant(
                of: find.byKey(Key('tag-count-${grpTag.tagId}')),
                matching: find.byType(Text),
              ),
            )
            .data,
        '3 笔',
      );
      expect(
        tester
            .widget<Text>(
              find.descendant(
                of: find.byKey(Key('tag-count-${flightTag.tagId}')),
                matching: find.byType(Text),
              ),
            )
            .data,
        '2 笔',
      );
      expect(
        tester
            .widget<Text>(
              find.descendant(
                of: find.byKey(Key('tag-count-${hotelTag.tagId}')),
                matching: find.byType(Text),
              ),
            )
            .data,
        '2 笔',
      );
      expect(
        tester
            .widget<Text>(
              find.descendant(
                of: find.byKey(Key('tag-count-${partyTag.tagId}')),
                matching: find.byType(Text),
              ),
            )
            .data,
        '1 笔',
      );

      // 4. Open TagRankingsPage via AppBar button ('tags-stats-btn')
      await tester.tap(find.byKey(const Key('tags-stats-btn')));
      await settle();
      expect(find.byKey(const Key('tag-rankings-page')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('tag-rankings-total-amount')))
            .data,
        '¥3680.00',
      );
      expect(
        find.byKey(Key('tag-ranking-row-${hotelTag.tagId}')),
        findsOneWidget,
      );
      expect(
        find.byKey(Key('tag-ranking-row-${flightTag.tagId}')),
        findsOneWidget,
      );
      expect(
        find.byKey(Key('tag-ranking-row-${partyTag.tagId}')),
        findsOneWidget,
      );

      // Pop back to TagsPage
      await tester.tap(find.byType(BackButton));
      await settle();

      // 5. Tap parent tag group "2026日本旅行" -> TagDetailStatsPage defaults to 全部时间
      await tester.tap(find.byKey(const Key('tag-2026日本旅行')));
      await settle();
      expect(find.byKey(const Key('tag-detail-stats-page')), findsOneWidget);
      expect(find.text('标签组 · 含 2 个子标签'), findsOneWidget);
      // Group summary deduplicates bill1 (3200 + 480 = 3680, NOT 3200*2 + 480!)
      expect(
        tester
            .widget<Text>(find.byKey(const Key('tag-detail-total-expense')))
            .data,
        '¥3680.00',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('tag-detail-total-income')))
            .data,
        '¥200.00',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('tag-detail-net-balance')))
            .data,
        '-¥3480.00',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('tag-detail-bill-count')))
            .data,
        '3 笔',
      );

      // Switch to 按月 -> only current-month bills (bill2 480 + bill3 200 = 2 笔)
      await tester.tap(find.byKey(const Key('tag-detail-mode-month')));
      await settle();
      expect(
        tester
            .widget<Text>(find.byKey(const Key('tag-detail-bill-count')))
            .data,
        '2 笔',
      );
      // Switch back to 全部 -> all 3 bills including 3-month-old bill1
      await tester.tap(find.byKey(const Key('tag-detail-mode-all')));
      await settle();
      expect(
        tester
            .widget<Text>(find.byKey(const Key('tag-detail-bill-count')))
            .data,
        '3 笔',
      );

      // Tap child breakdown chip "#机票" -> drills into child tag detail
      await tester.tap(find.byKey(Key('tag-detail-child-${flightTag.tagId}')));
      await settle();
      expect(
        tester
            .widget<Text>(find.byKey(const Key('tag-detail-total-expense')))
            .data,
        '¥3200.00',
      );

      // Scroll down if needed and tap bill1 row -> navigates to RecordDetailPage
      final bill1Finder = find.byKey(Key('tag-detail-bill-$bill1Id'));
      await tester.scrollUntilVisible(
        bill1Finder,
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await settle();
      await tester.tap(bill1Finder);
      await settle();
      expect(find.text('账单详情'), findsOneWidget);
      expect(find.text('往返机票与首晚住宿'), findsOneWidget);

      // 6. On RecordDetailPage, tap clickable ActionChip for tag "酒店" -> jumps to #酒店 TagDetailStatsPage!
      final hotelChipFinder = find.byKey(Key('detail-tag-${hotelTag.tagId}'));
      await tester.scrollUntilVisible(
        hotelChipFinder,
        150,
        scrollable: find.byType(Scrollable).last,
      );
      await settle();
      await tester.tap(hotelChipFinder);
      await settle();
      expect(find.text('#酒店'), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('tag-detail-total-expense')))
            .data,
        '¥3680.00',
      );

      // Pop back to shell root ("我的"), then check "统计" tab Tag Overview Card
      while (find.byType(BackButton).evaluate().isNotEmpty) {
        await tester.tap(find.byType(BackButton).first);
        await settle();
      }

      await tester.tap(find.text('统计'));
      await settle();
      expect(find.byKey(const Key('stats-tag-overview-card')), findsOneWidget);
      expect(
        find.byKey(Key('stats-tag-row-${hotelTag.tagId}')),
        findsOneWidget,
      );
      expect(
        find.byKey(Key('stats-tag-row-${partyTag.tagId}')),
        findsOneWidget,
      );

      // 7. Navigate to Home ("明细") -> SearchPage (/search) and filter by multiple tags without duplicates
      await tester.tap(find.text('明细'));
      await settle();
      await tester.tap(find.byKey(const Key('home-search-button')));
      await settle();

      // Initially untagged bill4 ("无标签早餐") is visible
      expect(find.textContaining('无标签早餐'), findsOneWidget);

      // Expand filter panel and select BOTH "机票" and "酒店"
      await tester.tap(find.byKey(const Key('search-filter-toggle')));
      await settle();

      final flightFilterChip = find.byKey(
        Key('search-tag-chip-${flightTag.tagId}'),
      );
      final hotelFilterChip = find.byKey(
        Key('search-tag-chip-${hotelTag.tagId}'),
      );
      await tester.ensureVisible(flightFilterChip);
      await settle();
      await tester.tap(flightFilterChip);
      await settle();
      await tester.tap(hotelFilterChip);
      await settle();

      // Collapse filter panel to inspect full record list
      await tester.tap(find.byKey(const Key('search-filter-toggle')));
      await settle();

      // Untagged bill4 is excluded, and bill1 (carrying BOTH selected tags) appears EXACTLY ONCE!
      expect(find.textContaining('无标签早餐'), findsNothing);
      expect(find.byKey(Key('search-record-$bill1Id')), findsOneWidget);
      expect(find.byKey(Key('search-record-$bill2Id')), findsOneWidget);

      // Re-open filter panel and reset filters
      await tester.tap(find.byKey(const Key('search-filter-toggle')));
      await settle();
      final resetBtn = find.byKey(const Key('search-reset-filters'));
      await tester.ensureVisible(resetBtn);
      await settle();
      await tester.tap(resetBtn);
      await settle();
      await tester.tap(find.byKey(const Key('search-filter-toggle')));
      await settle();
      expect(find.textContaining('无标签早餐'), findsOneWidget);

      // Clean up Drift streams
      await tester.pumpWidget(const SizedBox());
      await settle();
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(() => db.close());
    },
  );

  testWidgets(
    'SearchQueries SQL EXISTS deduplication, tag color edit/clear, and StatsPage cold-start _pickBook guard',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final catalog = CatalogService(db);
      final ledger = LedgerService(db);
      final search = SearchQueries(db);

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: const TallyIsleApp(),
        ),
      );

      Future<void> settle() async {
        for (var i = 0; i < 10; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 50));
        }
      }

      await settle();

      // Create second book and tags + multi-tag bill
      await catalog.createBook(commandId: 'mk-book-2', name: '副业账本');
      final t1 = await catalog.createTag(
        commandId: 'mk-t1',
        name: '设备',
        color: '#E53935',
      );
      final t2 = await catalog.createTag(
        commandId: 'mk-t2',
        name: '办公',
        color: '#1E88E5',
      );
      final cats = await db.select(db.recordCategories).get();
      final catId = cats.firstWhere((c) => c.accountBookId == 1).id;
      final recId = await ledger.saveRecord(
        commandId: 'mk-rec-1',
        draft: RecordDraft(
          type: RecordType.expense,
          money: Money.parse('99.50'),
          bookId: 1,
          recordTime: DateTime.now().millisecondsSinceEpoch,
          categoryId: catId,
          remark: '双标签键盘',
          tagIds: [t1, t2],
        ),
      );

      // Verify SearchFilter.hasAdvancedFilters and SQL EXISTS non-duplication
      const plainFilter = SearchFilter(bookId: 1);
      expect(plainFilter.hasAdvancedFilters, isFalse);
      final tagFilter = SearchFilter(bookId: 1, tagIds: {t1, t2});
      expect(tagFilter.hasAdvancedFilters, isTrue);

      final hits = await search.searchRecords(tagFilter);
      expect(hits.map((r) => r.recordId).toList(), [recId]);

      // Cold-start StatsPage _pickBook 5x rapid-tap re-entrancy guard
      await tester.tap(find.text('统计'));
      await settle();
      final switcher = find.byKey(const Key('stats-book-switcher'));
      for (var i = 0; i < 5; i++) {
        await tester.tap(switcher, warnIfMissed: false);
      }
      await settle();
      expect(find.text('管理账本…'), findsOneWidget);
      await tester.tap(find.text('副业账本').last);
      await settle();
      expect(find.text('副业账本'), findsOneWidget);

      // Edit tag color on TagsPage and clear to default
      await tester.tap(find.text('更多'));
      await settle();
      await tester.tap(find.byKey(const Key('me-tags')));
      await settle();
      await tester.tap(find.byKey(Key('tag-menu-$t1')));
      await settle();
      await tester.tap(find.text('编辑').last);
      await settle();
      await tester.tap(find.byKey(const Key('tag-color-clear')));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byKey(const Key('edit-tag-save')));
      await settle();

      final updatedT1 = await (db.select(
        db.tags,
      )..where((t) => t.tagId.equals(t1))).getSingle();
      expect(updatedT1.color, '');

      await tester.pumpWidget(const SizedBox());
      await settle();
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(() => db.close());
    },
  );
}
