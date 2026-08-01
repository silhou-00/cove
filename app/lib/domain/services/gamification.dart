import 'dart:math';

/// XP, levels — §17. Deliberately deviates from §17's original priority/
/// estimate/on-time-weighted formula: XP per completion is a flat random
/// pick from [xpOptions], with no tie to priority (priority stays purely
/// organizational, per an explicit product decision), and a daily cap
/// replaces the weighting itself as the anti-farming mechanism (§17
/// originally deferred any anti-farming mechanism as unnecessary for a
/// single-player system — revisited and built in anyway on request).
///
/// Kept as a pure, DB-free service — same reasoning as every other
/// `domain/services/` file — so the reward table and level curve are
/// unit-testable without touching `XpRepository`.
class Gamification {
  const Gamification._();

  /// Deliberately round, mid-value-weighted-by-count-only numbers, not
  /// tied to any item attribute — every completion (subject to
  /// [dailyXpCap]) has an equal chance at any of these.
  static const xpOptions = [5, 10, 15, 20, 25];

  /// Only the first [dailyXpCap] XP-eligible completions in a calendar
  /// day actually grant XP — the 6th+ still completes the task
  /// (or occurrence) normally, just silently for 0 XP, same treatment as
  /// cancelling an item.
  static const dailyXpCap = 5;

  /// Cumulative XP required to *reach* each level (level 1 starts at 0).
  /// Front-loaded so early levels come fast — unchanged from §17's
  /// original curve even though the reward formula underneath it
  /// changed, since retuning it wasn't asked for.
  static const levelThresholds = {
    2: 100,
    3: 225,
    4: 375,
    5: 550,
    6: 750,
    7: 975,
    8: 1225,
    9: 1500,
    10: 1800,
  };

  static const maxLevel = 10;

  /// A random pick from [xpOptions] — [random] is injectable so tests can
  /// pass a seeded `Random` instead of the wall-clock-seeded default.
  static int xpForCompletion([Random? random]) =>
      xpOptions[(random ?? Random()).nextInt(xpOptions.length)];

  /// The level [totalXp] currently sits at — derived, never stored, so it
  /// can't desync from the underlying XP log. Caps at [maxLevel]; §17
  /// doesn't define a curve beyond level 10.
  static int levelForXp(int totalXp) {
    var level = 1;
    for (final entry in levelThresholds.entries) {
      if (totalXp >= entry.value && entry.key > level) level = entry.key;
    }
    return level;
  }
}
