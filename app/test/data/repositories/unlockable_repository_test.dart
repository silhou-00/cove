import 'package:app/data/db/database.dart';
import 'package:app/data/repositories/settings_repository.dart';
import 'package:app/data/repositories/unlockable_repository.dart';
import 'package:app/domain/services/cosmetics.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late SettingsRepository settings;
  late UnlockableRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    settings = SettingsRepository(db);
    repo = UnlockableRepository(db, settings);
  });

  tearDown(() async {
    await db.close();
  });

  group('seedIfEmpty (§17)', () {
    test('inserts one row per catalog entry, all locked', () async {
      await repo.seedIfEmpty();
      final rows = await db.select(db.unlockables).get();
      expect(rows, hasLength(Cosmetics.catalog.length));
      expect(rows.every((r) => r.unlockedAt == null), isTrue);
    });

    test('is idempotent — a second call does not duplicate rows', () async {
      await repo.seedIfEmpty();
      await repo.seedIfEmpty();
      final rows = await db.select(db.unlockables).get();
      expect(rows, hasLength(Cosmetics.catalog.length));
    });
  });

  group('autoUnlock (§17, positive-only)', () {
    test('unlocks every entry at or below the given level', () async {
      await repo.seedIfEmpty();
      await repo.autoUnlock(5);
      final rows = await db.select(db.unlockables).get();
      for (final row in rows) {
        expect(row.unlockedAt != null, row.unlockLevel <= 5);
      }
    });

    test('never re-locks an entry once unlocked, even if called with a lower level', () async {
      await repo.seedIfEmpty();
      await repo.autoUnlock(10);
      await repo.autoUnlock(1);
      final rows = await db.select(db.unlockables).get();
      expect(rows.every((r) => r.unlockedAt != null), isTrue);
    });
  });

  group('cycleSlot (§17, flexible slots)', () {
    test('a locked pool leaves the slot untouched', () async {
      await repo.seedIfEmpty();
      await repo.cycleSlot(1);
      expect(await settings.getEquippedSlot(1), isNull);
    });

    test('cycles through both pets and furniture in the same pool', () async {
      await repo.seedIfEmpty();
      await repo.autoUnlock(5); // unlocks fox (pet) and lamp (furniture)
      await repo.cycleSlot(1);
      final first = await settings.getEquippedSlot(1);
      expect(first, anyOf('fox', 'lamp'));
      await repo.cycleSlot(1);
      final second = await settings.getEquippedSlot(1);
      expect(second, isNot(first));
      await repo.cycleSlot(1);
      expect(await settings.getEquippedSlot(1), first); // wraps around
    });

    test('slots are independent of each other', () async {
      await repo.seedIfEmpty();
      await repo.autoUnlock(5);
      await repo.cycleSlot(1);
      await repo.cycleSlot(2);
      await repo.cycleSlot(2);
      expect(
        await settings.getEquippedSlot(1),
        isNot(await settings.getEquippedSlot(2)),
      );
    });
  });

  group('equipToSlotOne (§17)', () {
    test('no-ops if the item is locked', () async {
      await repo.seedIfEmpty();
      await repo.equipToSlotOne('fox');
      expect(await settings.getEquippedSlot(1), isNull);
    });

    test('no-ops for a non-slottable type (accent/skin)', () async {
      await repo.seedIfEmpty();
      await repo.autoUnlock(10);
      await repo.equipToSlotOne('dawn');
      expect(await settings.getEquippedSlot(1), isNull);
    });

    test('equips an unlocked pet or furniture item into slot 1', () async {
      await repo.seedIfEmpty();
      await repo.autoUnlock(5);
      await repo.equipToSlotOne('lamp');
      expect(await settings.getEquippedSlot(1), 'lamp');
    });
  });

  group('equipAccent / equipWidgetSkin (§17)', () {
    test('equipAccent no-ops if locked, applies once unlocked', () async {
      await repo.seedIfEmpty();
      await repo.equipAccent('dawn');
      expect(await settings.getActiveAccentThemeId(), isNull);
      await repo.autoUnlock(2);
      await repo.equipAccent('dawn');
      expect(await settings.getActiveAccentThemeId(), 'dawn');
    });

    test('equipWidgetSkin no-ops if locked, applies once unlocked', () async {
      await repo.seedIfEmpty();
      await repo.equipWidgetSkin('outline');
      expect(await settings.getActiveWidgetSkinId(), isNull);
      await repo.autoUnlock(3);
      await repo.equipWidgetSkin('outline');
      expect(await settings.getActiveWidgetSkinId(), 'outline');
    });

    test('rejects the wrong cosmetic type for each method', () async {
      await repo.seedIfEmpty();
      await repo.autoUnlock(10);
      await repo.equipAccent('outline'); // a skin, not an accent
      expect(await settings.getActiveAccentThemeId(), isNull);
      await repo.equipWidgetSkin('dawn'); // an accent, not a skin
      expect(await settings.getActiveWidgetSkinId(), isNull);
    });
  });

  group('watchEquippedSlots (§17)', () {
    test('reflects slot changes', () async {
      await repo.seedIfEmpty();
      await repo.autoUnlock(5);
      await repo.equipToSlotOne('fox');
      final slots = await repo.watchEquippedSlots().first;
      expect(slots, ['fox', null, null]);
    });
  });
}
