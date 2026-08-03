import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'tables.dart';

part 'database.g.dart';

const _presetAreas = [
  (name: 'School', color: '#6E4C6D', icon: 'school', sortOrder: 0),
  (name: 'Work', color: '#3F6F6A', icon: 'work', sortOrder: 1),
  (name: 'Personal', color: '#A4543A', icon: 'personal', sortOrder: 2),
  (name: 'Projects', color: '#A07A2C', icon: 'projects', sortOrder: 3),
];

@DriftDatabase(
  tables: [
    Profiles,
    Areas,
    Items,
    Occurrences,
    Tags,
    ItemTags,
    ExternalEvents,
    WidgetCaches,
    SyncMetas,
    Settings,
    XpLogs,
    Unlockables,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor]) : super(executor ?? _openConnection());

  @override
  int get schemaVersion => 9;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await seedAreas();
    },
    onUpgrade: (m, from, to) async {
      // v1 -> v2: Archive (§4) — Item.archivedAt (soft-delete/archive
      // timestamp) and Item.sortOrder (manual drag-reorder), plus the
      // new ItemStatus.deleted enum value (no column change needed
      // for that — textEnum is just a TEXT column, a new valid string
      // value doesn't require a migration step).
      if (from < 2) {
        await m.addColumn(items, items.archivedAt);
        await m.addColumn(items, items.sortOrder);
      }
      // v2 -> v3: App lock (§12) — off by default, so existing rows
      // just need the new columns to exist, not backfilled.
      if (from < 3) {
        await m.addColumn(profiles, profiles.appLockEnabled);
        await m.addColumn(profiles, profiles.appLockPinHash);
        await m.addColumn(profiles, profiles.appLockPinSalt);
      }
      // v3 -> v4: per-item reminder offset (§7/§11) replaces the global
      // "Default reminder" Settings row — the column's own DB-level
      // default (60) backfills existing rows via SQLite's ALTER TABLE
      // ADD COLUMN, same as every reminder got under the old global
      // default, so no separate backfill statement is needed.
      if (from < 4) {
        await m.addColumn(items, items.reminderOffsetMinutes);
      }
      // v4 -> v5: gamification (§17) — new table, no existing data to
      // migrate; a fresh install and an upgraded one both just start at
      // 0 total XP / level 1.
      if (from < 5) {
        await m.createTable(xpLogs);
      }
      // v5 -> v6: cosmetic unlocks (§17) — new table, no existing data to
      // migrate. `UnlockableRepository.seedIfEmpty()` populates the fixed
      // catalog rows at app startup, not here, so the catalog can live in
      // one place (`domain/services/cosmetics.dart`) without `database.dart`
      // depending on the domain layer.
      if (from < 6) {
        await m.createTable(unlockables);
      }
      // v6 -> v7: Settings' profile picture — off by default (null shows
      // the initial-letter avatar), so existing rows just need the
      // column to exist.
      if (from < 7) {
        await m.addColumn(profiles, profiles.avatarPath);
      }
      // v7 -> v8: overdue XP penalty (§17 addendum) — a one-off flag per
      // item/occurrence so `ItemRepository.applyOverduePenalties` never
      // re-charges the same instance on a later scan. Off (null) for
      // every existing row; nothing to backfill.
      if (from < 8) {
        await m.addColumn(items, items.overduePenaltyAppliedAt);
        await m.addColumn(occurrences, occurrences.overduePenaltyAppliedAt);
      }
      // v8 -> v9: deadline/time-block categorization for imported Google
      // Calendar events (§9 addendum, on user request). Existing rows
      // default to `false` (time-block-like); the next "Sync now" fully
      // replaces every row anyway (`applyEvents` clears the table first),
      // so nothing meaningful is actually lost by that default.
      if (from < 9) {
        await m.addColumn(externalEvents, externalEvents.isAllDay);
      }
    },
  );

  /// Also called by `ExportRepository.clearAllData()` (§11) — a full
  /// clear routes back to onboarding, whose "Your rooms" step expects
  /// these four presets to already exist (edits them, doesn't create
  /// them), same as a genuinely fresh install.
  Future<void> seedAreas() async {
    const uuid = Uuid();
    for (final preset in _presetAreas) {
      await into(areas).insert(
        AreasCompanion.insert(
          id: uuid.v4(),
          name: preset.name,
          color: preset.color,
          icon: preset.icon,
          sortOrder: preset.sortOrder,
        ),
      );
    }
  }
}

Future<String> databaseFilePath() async {
  final dir = await getApplicationDocumentsDirectory();
  return p.join(dir.path, 'cove.sqlite');
}

QueryExecutor _openConnection() {
  return LazyDatabase(() async {
    final file = File(await databaseFilePath());
    return NativeDatabase.createInBackground(file);
  });
}
