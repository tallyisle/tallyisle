import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/domain/rules/wish_note_rules.dart';

void main() {
  group('Wish domain rules (F-014)', () {
    test(
      'parseWishAmount and validateWishInput enforce exact Money/BigInt bounds (R1)',
      () {
        final zero = parseWishAmount('0');
        expect(zero.storageMinor, BigInt.zero);

        final exact = parseWishAmount('  1999.99 ');
        expect(exact.storageMinor, BigInt.from(199999));

        // Above 2^53 minor units: proves zero IEEE-754 double precision loss
        final huge = parseWishAmount('90071992547409.93');
        expect(huge.storageMinor, BigInt.parse('9007199254740993'));

        expect(
          () => parseWishAmount(''),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.validation,
            ),
          ),
        );
        expect(
          () => parseWishAmount('-0.01'),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.validation,
            ),
          ),
        );
        expect(
          () => parseWishAmount('12.345'),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.scaleMismatch,
            ),
          ),
        );

        // Content 1..100 rune boundaries
        final maxContent = '愿' * 100;
        final ok100 = validateWishInput(
          content: '  $maxContent  ',
          value: Money.minor(BigInt.from(52000)),
          targetDateMs: -1, // legacy 33->34 sentinel normalizes to 0
          icon: '  gift ',
        );
        expect(ok100.content, maxContent);
        expect(ok100.valueMinor, BigInt.from(52000));
        expect(ok100.targetDateMs, 0);
        expect(ok100.icon, 'gift');

        expect(
          () => validateWishInput(content: '   ', value: Money.zero()),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.validation,
            ),
          ),
        );
        expect(
          () => validateWishInput(content: '愿' * 101, value: Money.zero()),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.validation,
            ),
          ),
        );
        expect(
          () => validateWishInput(
            content: '测试',
            value: Money.minor(BigInt.from(-1)),
          ),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.validation,
            ),
          ),
        );
        expect(
          () => validateWishInput(
            content: '测试',
            value: Money.zero(),
            targetDateMs: -2,
          ),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.validation,
            ),
          ),
        );
      },
    );

    test(
      'normalizeWishRealizedDate enforces R2 realized/reopen invariants',
      () {
        expect(
          normalizeWishRealizedDate(
            isRealized: false,
            realizedDateMs: 1770000000000,
            fallbackNowMs: 1770000000000,
          ),
          0,
        );
        expect(
          normalizeWishRealizedDate(
            isRealized: true,
            realizedDateMs: 1770000000000,
            fallbackNowMs: 1770000099999,
          ),
          1770000000000,
        );
        expect(
          normalizeWishRealizedDate(
            isRealized: true,
            realizedDateMs: 0,
            fallbackNowMs: 1770000099999,
          ),
          1770000099999,
        );
      },
    );

    test(
      'evaluateWishDeadline computes local calendar countdown, due-today, overdue, and legacy sentinels (R3)',
      () {
        final nowLateNight = DateTime(
          2026,
          5,
          10,
          23,
          50,
        ).millisecondsSinceEpoch;
        final tomorrowEarly = DateTime(
          2026,
          5,
          11,
          0,
          5,
        ).millisecondsSinceEpoch;
        final upcoming = evaluateWishDeadline(
          targetDateMs: tomorrowEarly,
          nowMs: nowLateNight,
        );
        expect(upcoming.status, WishDeadlineStatus.upcoming);
        expect(upcoming.remainingDays, 1);
        expect(upcoming.overdueDays, 0);
        expect(upcoming.label, '剩余 1 天');

        final nowEvening = DateTime(2026, 5, 10, 18, 0).millisecondsSinceEpoch;
        final sameDayMorning = DateTime(
          2026,
          5,
          10,
          8,
          0,
        ).millisecondsSinceEpoch;
        final dueToday = evaluateWishDeadline(
          targetDateMs: sameDayMorning,
          nowMs: nowEvening,
        );
        expect(dueToday.status, WishDeadlineStatus.dueToday);
        expect(dueToday.isDueToday, isTrue);
        expect(dueToday.label, '今天到期');

        final twoDaysAgo = DateTime(2026, 5, 8, 0, 0).millisecondsSinceEpoch;
        final overdue = evaluateWishDeadline(
          targetDateMs: twoDaysAgo,
          nowMs: nowEvening,
        );
        expect(overdue.status, WishDeadlineStatus.overdue);
        expect(overdue.isOverdue, isTrue);
        expect(overdue.overdueDays, 2);
        expect(overdue.label, '已逾期 2 天');

        // Realized wishes do not report overdue badges
        final realizedPast = evaluateWishDeadline(
          targetDateMs: twoDaysAgo,
          nowMs: nowEvening,
          isRealized: true,
        );
        expect(realizedPast.status, WishDeadlineStatus.realized);
        expect(realizedPast.isOverdue, isFalse);
        expect(realizedPast.overdueDays, 0);
        expect(realizedPast.label, isNull);

        // Unset (0) and legacy (-1) sentinels
        for (final sentinel in [0, -1]) {
          final unset = evaluateWishDeadline(
            targetDateMs: sentinel,
            nowMs: nowEvening,
          );
          expect(unset.status, WishDeadlineStatus.unset);
          expect(unset.hasTargetDate, isFalse);
          expect(unset.label, isNull);
        }
      },
    );

    test('summarizeWishes and stable sorting follow R4 golden vectors', () {
      final wishes = [
        WishEntry(
          id: 'w-b',
          content: '心愿B',
          valueMinor: BigInt.from(199999),
          createDate: 1000,
          sort: 0,
        ),
        WishEntry(
          id: 'w-a',
          content: '心愿A',
          valueMinor: BigInt.from(1),
          createDate: 1000,
          sort: 0,
        ),
        WishEntry(
          id: 'w-top',
          content: '置顶心愿',
          valueMinor: BigInt.zero,
          createDate: 500,
          sort: -1,
        ),
        WishEntry(
          id: 'w-r1',
          content: '已实现旧',
          valueMinor: BigInt.from(20000),
          createDate: 800,
          isRealized: true,
          realizedDate: 2000,
          sort: 0,
        ),
        WishEntry(
          id: 'w-r2',
          content: '已实现新',
          valueMinor: BigInt.from(32050),
          createDate: 700,
          isRealized: true,
          realizedDate: 3000,
          sort: 5,
        ),
      ];

      final summary = summarizeWishes(
        wishes,
        isRealizedOf: (w) => w.isRealized,
        valueMinorOf: (w) => w.valueMinor,
      );
      expect(summary.unrealizedCount, 3);
      expect(summary.realizedCount, 2);
      expect(summary.unrealizedTotalMinor, BigInt.from(200000));
      expect(summary.unrealizedTotal().decimal, '2000.00');
      expect(summary.realizedTotalMinor, BigInt.from(52050));
      expect(summary.realizedTotal().decimal, '520.50');

      final sorted = sortWishes(
        wishes,
        isRealizedOf: (w) => w.isRealized,
        realizedDateOf: (w) => w.realizedDate,
        sortOf: (w) => w.sort,
        createDateOf: (w) => w.createDate,
        idOf: (w) => w.id,
      );
      expect(sorted.map((w) => w.id).toList(), [
        'w-top',
        'w-a',
        'w-b',
        'w-r2',
        'w-r1',
      ]);

      expect(nextTopWishSort(const []), 0);
      expect(nextTopWishSort([2, -1, 0]), -2);
    });
  });

  group('Note domain rules (F-015)', () {
    test(
      'validateNoteInput, snippet surrogate safety, search, and sorting (R5, R6)',
      () {
        final valid = validateNoteInput(
          title: '   ',
          content: '第一行\n  第二行保留缩进',
        );
        expect(valid.title, isNull);
        expect(valid.content, '第一行\n  第二行保留缩进');

        expect(
          () => validateNoteInput(title: '标题', content: ' \n\t '),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.validation,
            ),
          ),
        );
        expect(
          () => validateNoteInput(title: '标' * 101, content: '正文'),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.validation,
            ),
          ),
        );

        // Surrogate-safe Emoji truncation (never splits UTF-16 surrogate pairs)
        expect(buildNoteSnippet('🎉🎊🎈🎁🎂', maxChars: 3), '🎉🎊🎈…');
        expect(buildNoteSnippet('  🎉🎊\n\n🎈🎁🎂  ', maxChars: 4), '🎉🎊 🎈…');
        expect(
          resolveNoteDisplayTitle(title: '  ', content: '\n  购物清单：牛奶面包 \n第二行'),
          '购物清单：牛奶面包',
        );

        // Case-insensitive search across title and content
        expect(
          matchesNoteSearch(
            title: 'Flutter 读书笔记',
            content: 'Clean Architecture Summary',
            query: 'clean',
          ),
          isTrue,
        );
        expect(
          matchesNoteSearch(
            title: 'Flutter 读书笔记',
            content: 'Clean Architecture Summary',
            query: 'FLUTTER',
          ),
          isTrue,
        );
        expect(
          matchesNoteSearch(
            title: 'Flutter 读书笔记',
            content: 'Clean Architecture Summary',
            query: 'kotlin',
          ),
          isFalse,
        );

        // Active & trash predicates (including legacy -1 active sentinel)
        expect(isNoteActive(0), isTrue);
        expect(isNoteActive(-1), isTrue);
        expect(isNoteTrashed(0), isFalse);
        expect(isNoteTrashed(1770000000000), isTrue);

        final activeSorted = sortActiveNotes(
          const [
            NoteEntry(id: 1, content: 'a', createTime: 100, updateTime: 200),
            NoteEntry(id: 2, content: 'b', createTime: 100, updateTime: 200),
            NoteEntry(id: 3, content: 'c', createTime: 90, updateTime: 300),
          ],
          updateTimeOf: (n) => n.updateTime,
          createTimeOf: (n) => n.createTime,
          idOf: (n) => n.id,
        );
        expect(activeSorted.map((n) => n.id).toList(), [3, 2, 1]);

        final trashSorted = sortTrashedNotes(
          const [
            NoteEntry(
              id: 10,
              content: 'x',
              createTime: 100,
              updateTime: 500,
              trashTime: 1000,
            ),
            NoteEntry(
              id: 11,
              content: 'y',
              createTime: 100,
              updateTime: 200,
              trashTime: 2000,
            ),
          ],
          trashTimeOf: (n) => n.trashTime,
          updateTimeOf: (n) => n.updateTime,
          idOf: (n) => n.id,
        );
        expect(trashSorted.map((n) => n.id).toList(), [11, 10]);
      },
    );
  });
}
