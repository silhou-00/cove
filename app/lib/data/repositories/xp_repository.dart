import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../domain/services/gamification.dart';
import '../db/database.dart';
import 'unlockable_repository.dart';

/// XP/levels (§17) — per-transaction log, not a running total (see
/// `XpLogs`' own doc comment for why). `ItemRepository` is the only
/// caller: it decides *when* a completion happened (toggling an item or
/// occurrence done/open); this repository only decides *how much*, and
/// only ever reads/writes `XpLogs`. [_unlockables] is optional so existing
/// tests/call sites that don't care about cosmetic unlocks don't need to
/// wire one up — production always provides it (see `app/providers.dart`).
class XpRepository {
  XpRepository(this._db, [this._unlockables]);

  final AppDatabase _db;
  final UnlockableRepository? _unlockables;
  static const _uuid = Uuid();

  /// Awards XP for completing [itemId] — a no-op past the daily cap
  /// (§17/Gamification), same as cancelling an item awarding 0. [now] and
  /// [random] are injectable for deterministic tests; production callers
  /// leave both null.
  Future<void> awardForCompletion(
    String itemId, {
    DateTime? now,
    math.Random? random,
  }) async {
    final effectiveNow = now ?? DateTime.now();
    final todayStart = DateTime(
      effectiveNow.year,
      effectiveNow.month,
      effectiveNow.day,
    );
    final todayEnd = todayStart.add(const Duration(days: 1));
    final countToday =
        await (_db.select(_db.xpLogs)..where(
              (x) =>
                  x.awardedAt.isBiggerOrEqualValue(todayStart) &
                  x.awardedAt.isSmallerThanValue(todayEnd),
            ))
            .get();
    if (countToday.length >= Gamification.dailyXpCap) return;

    await _db
        .into(_db.xpLogs)
        .insert(
          XpLogsCompanion.insert(
            id: _uuid.v4(),
            itemId: itemId,
            xpAwarded: Gamification.xpForCompletion(random),
            awardedAt: effectiveNow,
          ),
        );

    if (_unlockables != null) {
      await _unlockables.autoUnlock(Gamification.levelForXp(await totalXp()));
    }
  }

  /// Reverses whatever XP was actually granted for [itemId]'s most recent
  /// completion — not a freshly recomputed value, which could drift if
  /// [Gamification.xpOptions] or the cap changed since. Used when
  /// un-completing an item or occurrence (the toggle's reverse
  /// direction). A no-op if the most recent completion was past the
  /// daily cap and never logged anything (nothing to reverse).
  Future<void> reverseForItem(String itemId) async {
    final rows =
        await (_db.select(_db.xpLogs)
              ..where((x) => x.itemId.equals(itemId))
              ..orderBy([
                (x) =>
                    OrderingTerm(expression: x.awardedAt, mode: OrderingMode.desc),
              ])
              ..limit(1))
            .get();
    if (rows.isEmpty) return;
    await (_db.delete(_db.xpLogs)..where((x) => x.id.equals(rows.first.id))).go();
  }

  /// Overdue penalty (§17 addendum, on user request) — a deliberate
  /// exception to the ledger's otherwise positive-only history. Fires
  /// once per item/occurrence (see `ItemRepository.applyOverduePenalties`,
  /// the only caller, which tracks that via `overduePenaltyAppliedAt`).
  /// Logged as a negative `XpLogs` row rather than a direct subtract, so
  /// `totalXp` stays a pure derived sum — same ledger model as every
  /// other XP change, delevel included if the cut crosses a threshold.
  /// [Gamification.overduePenalty] floors the deduction at whatever's
  /// actually banked, so this can never drive the total negative.
  Future<void> applyOverduePenalty(String itemId, {DateTime? now}) async {
    final current = await totalXp();
    final penalty = Gamification.overduePenalty(current);
    if (penalty <= 0) return;
    await _db
        .into(_db.xpLogs)
        .insert(
          XpLogsCompanion.insert(
            id: _uuid.v4(),
            itemId: itemId,
            xpAwarded: -penalty,
            awardedAt: now ?? DateTime.now(),
          ),
        );
  }

  Future<int> totalXp() async {
    final rows = await _db.select(_db.xpLogs).get();
    return rows.fold<int>(0, (sum, row) => sum + row.xpAwarded);
  }

  /// The Agenda header's level gauge (§17) watches this — recomputes on
  /// every `XpLogs` write, never stored, so it can't desync.
  Stream<int> watchTotalXp() {
    return _db.select(_db.xpLogs).watch().map((rows) {
      return rows.fold<int>(0, (sum, row) => sum + row.xpAwarded);
    });
  }

  Stream<int> watchLevel() => watchTotalXp().map(Gamification.levelForXp);
}
