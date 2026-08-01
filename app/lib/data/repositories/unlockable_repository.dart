import 'package:drift/drift.dart';

import '../../domain/services/cosmetics.dart';
import '../db/database.dart';
import '../db/tables.dart';
import 'settings_repository.dart';

/// Cosmetic unlocks (§17) — the `Unlockables` table only tracks *unlock*
/// state; visual data (sprite/palette/accent) comes from the static
/// [Cosmetics] catalog, and *equip* state (which slot holds what, which
/// accent/skin is active) lives in [SettingsRepository], matching how
/// every other user pick in this app is stored.
class UnlockableRepository {
  UnlockableRepository(this._db, this._settings);

  final AppDatabase _db;
  final SettingsRepository _settings;

  /// Populates the fixed catalog rows on first run. Idempotent — a no-op
  /// once they exist, so it's safe to call on every app launch rather
  /// than only from a migration (keeps `database.dart` free of a
  /// dependency on the domain-layer catalog; see that file's v5->v6
  /// migration comment).
  Future<void> seedIfEmpty() async {
    final existing = await _db.select(_db.unlockables).get();
    if (existing.isNotEmpty) return;
    for (final def in Cosmetics.catalog) {
      await _db
          .into(_db.unlockables)
          .insert(
            UnlockablesCompanion.insert(
              id: def.id,
              type: _dbType(def.type),
              name: def.name,
              unlockLevel: def.unlockLevel,
            ),
          );
    }
  }

  /// Marks every still-locked row whose `unlockLevel` is now reached as
  /// unlocked. Called by `XpRepository.awardForCompletion` right after an
  /// XP grant changes the level — never re-locks (§17 positive-only).
  Future<void> autoUnlock(int level, {DateTime? now}) async {
    final newlyUnlocked =
        await (_db.select(_db.unlockables)..where(
              (t) =>
                  t.unlockLevel.isSmallerOrEqualValue(level) &
                  t.unlockedAt.isNull(),
            ))
            .get();
    for (final row in newlyUnlocked) {
      await (_db.update(
        _db.unlockables,
      )..where((t) => t.id.equals(row.id))).write(
        UnlockablesCompanion(unlockedAt: Value(now ?? DateTime.now())),
      );
    }
  }

  Stream<List<Unlockable>> watchAll() => _db.select(_db.unlockables).watch();

  Future<bool> _isUnlocked(String id) async {
    final row = await (_db.select(
      _db.unlockables,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row?.unlockedAt != null;
  }

  Future<List<String?>> getEquippedSlots() => Future.wait([
    _settings.getEquippedSlot(1),
    _settings.getEquippedSlot(2),
    _settings.getEquippedSlot(3),
  ]);

  /// Combines [watchAll] (unlock state) with the equipped-slot Settings
  /// rows into one stream the header cluster and Settings' Unlocks list
  /// both watch — refreshes on either an unlock or an equip change.
  Stream<List<String?>> watchEquippedSlots() async* {
    await for (final _ in watchAll()) {
      yield await getEquippedSlots();
    }
  }

  /// Settings' Unlocks list quick-equips into slot 1 — the header
  /// cluster's tap-to-cycle (see [cycleSlot]) is how slots 2 and 3 get
  /// filled, so there's no need for a slot picker here.
  Future<void> equipToSlotOne(String id) async {
    final def = Cosmetics.byIdOrNull(id);
    if (def == null || !def.isSlottable) return;
    if (!await _isUnlocked(id)) return;
    await _settings.setEquippedSlot(1, id);
  }

  /// Cycles [slot] (1-3) to the next unlocked pet/furniture item — tapping
  /// a slot in the header cluster, matching the design handoff's
  /// `cycleSlot`. All three slots draw from the same combined pool now
  /// (flexible slots), not type-restricted per slot.
  Future<void> cycleSlot(int slot) async {
    final rows = await _db.select(_db.unlockables).get();
    final unlockedIds = rows
        .where(
          (r) =>
              r.unlockedAt != null &&
              (r.type == UnlockableType.pet ||
                  r.type == UnlockableType.furniture),
        )
        .map((r) => r.id)
        .toList();
    if (unlockedIds.isEmpty) return;
    final current = await _settings.getEquippedSlot(slot);
    final currentIndex = unlockedIds.indexOf(current ?? '');
    final next = unlockedIds[(currentIndex + 1) % unlockedIds.length];
    await _settings.setEquippedSlot(slot, next);
  }

  Future<void> equipAccent(String id) async {
    final def = Cosmetics.byIdOrNull(id);
    if (def == null || def.type != CosmeticType.accentTheme) return;
    if (!await _isUnlocked(id)) return;
    await _settings.setActiveAccentThemeId(id);
  }

  Future<void> equipWidgetSkin(String id) async {
    final def = Cosmetics.byIdOrNull(id);
    if (def == null || def.type != CosmeticType.widgetSkin) return;
    if (!await _isUnlocked(id)) return;
    await _settings.setActiveWidgetSkinId(id);
  }

  UnlockableType _dbType(CosmeticType type) => switch (type) {
    CosmeticType.accentTheme => UnlockableType.accentTheme,
    CosmeticType.widgetSkin => UnlockableType.widgetSkin,
    CosmeticType.pet => UnlockableType.pet,
    CosmeticType.furniture => UnlockableType.furniture,
  };
}
