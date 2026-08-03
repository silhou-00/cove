import 'dart:math';

import 'package:app/domain/services/gamification.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Gamification.xpForCompletion (§17)', () {
    test('always returns one of the fixed xpOptions', () {
      final random = Random(7);
      for (var i = 0; i < 100; i++) {
        expect(
          Gamification.xpOptions,
          contains(Gamification.xpForCompletion(random)),
        );
      }
    });

    test('a seeded Random is deterministic', () {
      expect(
        Gamification.xpForCompletion(Random(42)),
        Gamification.xpForCompletion(Random(42)),
      );
    });
  });

  group('Gamification.levelForXp (§17 level curve)', () {
    test('starts at level 1 with zero XP', () {
      expect(Gamification.levelForXp(0), 1);
    });

    test('stays at level 1 just below the level-2 threshold', () {
      expect(Gamification.levelForXp(99), 1);
    });

    test('reaches level 2 exactly at its threshold', () {
      expect(Gamification.levelForXp(100), 2);
    });

    test('reaches every level exactly at its own threshold', () {
      for (final entry in Gamification.levelThresholds.entries) {
        expect(Gamification.levelForXp(entry.value), entry.key);
      }
    });

    test('caps at maxLevel, never higher, far past the top threshold', () {
      expect(Gamification.levelForXp(1000000), Gamification.maxLevel);
    });
  });

  group('Gamification.overduePenalty (§17 addendum)', () {
    test('is the configured rate of current XP, rounded', () {
      expect(Gamification.overduePenalty(1000), 25);
      expect(Gamification.overduePenalty(101), 3);
    });

    test('floors at the current XP itself, never exceeding it', () {
      expect(Gamification.overduePenalty(1), lessThanOrEqualTo(1));
      expect(Gamification.overduePenalty(0), 0);
    });
  });
}
