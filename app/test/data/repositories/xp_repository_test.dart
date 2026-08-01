import 'dart:math';

import 'package:app/data/db/database.dart';
import 'package:app/data/db/tables.dart';
import 'package:app/data/repositories/settings_repository.dart';
import 'package:app/data/repositories/unlockable_repository.dart';
import 'package:app/data/repositories/xp_repository.dart';
import 'package:app/domain/services/gamification.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Always picks the top [Gamification.xpOptions] entry (25) — makes the
/// auto-unlock wiring test below deterministic instead of depending on
/// enough random draws landing high enough to cross a level threshold.
class _MaxRandom implements Random {
  @override
  bool nextBool() => false;

  @override
  double nextDouble() => 0.999;

  @override
  int nextInt(int max) => max - 1;
}

void main() {
  late AppDatabase db;
  late XpRepository repo;

  Future<String> makeItem(String id) async {
    final now = DateTime(2026, 8, 1);
    await db
        .into(db.items)
        .insert(
          ItemsCompanion.insert(
            id: id,
            title: 'Test item $id',
            status: ItemStatus.open,
            createdAt: now,
            updatedAt: now,
          ),
        );
    return id;
  }

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = XpRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('awardForCompletion (§17)', () {
    test('logs one XpLog row worth one of the fixed xpOptions', () async {
      final id = await makeItem('i1');
      await repo.awardForCompletion(id);

      final rows = await db.select(db.xpLogs).get();
      expect(rows, hasLength(1));
      expect(rows.single.itemId, id);
      expect(Gamification.xpOptions, contains(rows.single.xpAwarded));
    });

    test('stops awarding once the daily cap is reached', () async {
      final now = DateTime(2026, 8, 1, 9, 0);
      for (var i = 0; i < Gamification.dailyXpCap; i++) {
        final id = await makeItem('cap-$i');
        await repo.awardForCompletion(id, now: now.add(Duration(minutes: i)));
      }
      // One more completion, same day — should be silently skipped.
      final overCapId = await makeItem('over-cap');
      await repo.awardForCompletion(
        overCapId,
        now: now.add(const Duration(hours: 1)),
      );

      final rows = await db.select(db.xpLogs).get();
      expect(rows, hasLength(Gamification.dailyXpCap));
      expect(rows.any((r) => r.itemId == overCapId), isFalse);
    });

    test('a new calendar day resets the cap', () async {
      final day1 = DateTime(2026, 8, 1, 9, 0);
      for (var i = 0; i < Gamification.dailyXpCap; i++) {
        final id = await makeItem('day1-$i');
        await repo.awardForCompletion(id, now: day1.add(Duration(minutes: i)));
      }
      final day2Id = await makeItem('day2');
      await repo.awardForCompletion(
        day2Id,
        now: DateTime(2026, 8, 2, 9, 0),
      );

      final rows = await db.select(db.xpLogs).get();
      expect(rows, hasLength(Gamification.dailyXpCap + 1));
      expect(rows.any((r) => r.itemId == day2Id), isTrue);
    });
  });

  group('reverseForItem (§17, undo)', () {
    test('deletes the most recent XpLog row for that item', () async {
      final id = await makeItem('i1');
      await repo.awardForCompletion(id, now: DateTime(2026, 8, 1, 9, 0));
      expect(await db.select(db.xpLogs).get(), hasLength(1));

      await repo.reverseForItem(id);
      expect(await db.select(db.xpLogs).get(), isEmpty);
    });

    test('no-ops when the item never actually got an XpLog row', () async {
      final id = await makeItem('i1');
      // Never awarded (e.g. it was past the daily cap) — reversing
      // should just do nothing, not throw.
      await repo.reverseForItem(id);
      expect(await db.select(db.xpLogs).get(), isEmpty);
    });

    test('only removes this item\'s row, not a sibling\'s', () async {
      final a = await makeItem('a');
      final b = await makeItem('b');
      await repo.awardForCompletion(a, now: DateTime(2026, 8, 1, 9, 0));
      await repo.awardForCompletion(b, now: DateTime(2026, 8, 1, 9, 1));

      await repo.reverseForItem(a);

      final rows = await db.select(db.xpLogs).get();
      expect(rows, hasLength(1));
      expect(rows.single.itemId, b);
    });
  });

  group('auto-unlock wiring (§17)', () {
    test('an XP grant that crosses a level threshold unlocks the matching cosmetic', () async {
      final settings = SettingsRepository(db);
      final unlockables = UnlockableRepository(db, settings);
      final repoWithUnlocks = XpRepository(db, unlockables);
      await unlockables.seedIfEmpty();

      // 5 completions x a forced 25 XP = 125, comfortably past the
      // level-2 (100 XP) threshold that unlocks "dawn".
      for (var i = 0; i < Gamification.dailyXpCap; i++) {
        final id = await makeItem('u$i');
        await repoWithUnlocks.awardForCompletion(
          id,
          now: DateTime(2026, 8, 1, 9, i),
          random: _MaxRandom(),
        );
      }

      final dawn = await (db.select(
        db.unlockables,
      )..where((t) => t.id.equals('dawn'))).getSingleOrNull();
      expect(dawn?.unlockedAt, isNotNull);
    });

    test('with no UnlockableRepository provided, awarding XP still works (optional dep)', () async {
      final id = await makeItem('solo');
      await repo.awardForCompletion(id, now: DateTime(2026, 8, 1, 9, 0));
      final rows = await db.select(db.xpLogs).get();
      expect(rows, hasLength(1));
    });
  });

  group('totalXp / watchLevel (§17)', () {
    test('totalXp sums every logged row', () async {
      final a = await makeItem('a');
      final b = await makeItem('b');
      await db
          .into(db.xpLogs)
          .insert(
            XpLogsCompanion.insert(
              id: 'log-a',
              itemId: a,
              xpAwarded: 10,
              awardedAt: DateTime(2026, 8, 1),
            ),
          );
      await db
          .into(db.xpLogs)
          .insert(
            XpLogsCompanion.insert(
              id: 'log-b',
              itemId: b,
              xpAwarded: 15,
              awardedAt: DateTime(2026, 8, 1),
            ),
          );

      expect(await repo.totalXp(), 25);
    });

    test('watchLevel reflects the level curve as XP accumulates', () async {
      final id = await makeItem('a');
      expect(await repo.watchLevel().first, 1);

      await db
          .into(db.xpLogs)
          .insert(
            XpLogsCompanion.insert(
              id: 'log-1',
              itemId: id,
              xpAwarded: 100,
              awardedAt: DateTime(2026, 8, 1),
            ),
          );

      expect(await repo.watchLevel().first, 2);
    });
  });
}
