import 'package:drift/drift.dart';

/// `deleted` is a soft delete (§4, Archive) — the row stays, only the
/// status changes, so it can be restored. A real, unrecoverable row
/// removal only happens via `ItemRepository.permanentlyDelete`, reachable
/// solely from within the Archive screen.
enum ItemStatus { open, done, cancelled, deleted }

enum ItemPriority { low, medium, high }

enum OccurrenceStatus { open, done, skipped }

/// Single-row profile — no accounts. Local only, never transmitted.
class Profiles extends Table {
  TextColumn get id => text()();
  TextColumn get firstName => text()();
  TextColumn get lastName => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();

  /// Absolute path to a locally-copied image file (Settings' profile
  /// picture) — never the original picked file's own path, which isn't
  /// guaranteed to still exist later. Null shows the initial-letter
  /// avatar instead.
  TextColumn get avatarPath => text().nullable()();

  /// App lock (§12), off by default. `id` is always the fixed string
  /// `'local'` (not per-install-random), so it can't double as the PIN
  /// salt — [appLockPinSalt] is a real random value generated once when
  /// the PIN is first set, not derived from anything else on this row.
  BoolColumn get appLockEnabled =>
      boolean().withDefault(const Constant(false))();
  TextColumn get appLockPinHash => text().nullable()();
  TextColumn get appLockPinSalt => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// User-defined areas — seeded with presets at onboarding, fully
/// editable/deletable afterward.
class Areas extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get color => text()();
  TextColumn get icon => text()();
  IntColumn get sortOrder => integer()();
  BoolColumn get archived => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

class Items extends Table {
  TextColumn get id => text()();
  TextColumn get areaId => text().nullable().references(Areas, #id)();
  TextColumn get parentId => text().nullable().references(Items, #id)();
  TextColumn get title => text()();
  TextColumn get shortTitle => text().nullable()();
  TextColumn get notes => text().nullable()();
  late final status = textEnum<ItemStatus>()();
  late final priority = textEnum<ItemPriority>().nullable()();
  DateTimeColumn get dueAt => dateTime().nullable()();
  DateTimeColumn get scheduledStart => dateTime().nullable()();
  DateTimeColumn get scheduledEnd => dateTime().nullable()();
  IntColumn get estimateMinutes => integer().nullable()();
  TextColumn get recurrenceRule => text().nullable()();
  DateTimeColumn get completedAt => dateTime().nullable()();
  TextColumn get externalCalendarEventId => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  /// Set the moment `status` moves away from `open` (done/cancelled/
  /// deleted) — what the Archive screen sorts and displays by. Cleared
  /// on restore back to `open`.
  DateTimeColumn get archivedAt => dateTime().nullable()();

  /// Manual ordering, used only when the Agenda sort mode is "Manual"
  /// (§4, drag-reorder). Not used by any date-based sort.
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  /// Minutes before `scheduledStart`/`dueAt` this item's reminder fires
  /// (§7) — set per-item in the create/edit sheet, not a global Settings
  /// default. `-1` is the "off" sentinel, same convention as the old
  /// global setting it replaces. Defaults to 60 (1 hour before) so
  /// existing rows keep firing reminders the same way they did under the
  /// old global-default behavior after the migration backfills them.
  IntColumn get reminderOffsetMinutes =>
      integer().withDefault(const Constant(60))();

  /// Set the first (and only) time the overdue XP penalty
  /// (`XpRepository.applyOverduePenalty`) is applied for this item — a
  /// deliberate one-off exception to the otherwise positive-only XP
  /// design. Prevents `ItemRepository.applyOverduePenalties` from
  /// re-charging the same item on every later scan.
  DateTimeColumn get overduePenaltyAppliedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Materialized recurrence instances, ~60 days ahead.
class Occurrences extends Table {
  TextColumn get id => text()();
  TextColumn get itemId => text().references(Items, #id)();
  DateTimeColumn get date => dateTime()();
  DateTimeColumn get scheduledStart => dateTime().nullable()();
  late final status = textEnum<OccurrenceStatus>()();
  DateTimeColumn get completedAt => dateTime().nullable()();

  /// Same one-off penalty flag as `Items.overduePenaltyAppliedAt`, tracked
  /// per-occurrence since a recurring item's instances go overdue
  /// independently of each other.
  DateTimeColumn get overduePenaltyAppliedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Cross-cutting labels that don't belong in the Area hierarchy.
class Tags extends Table {
  TextColumn get id => text()();
  TextColumn get name => text().unique()();

  @override
  Set<Column> get primaryKey => {id};
}

class ItemTags extends Table {
  TextColumn get itemId => text().references(Items, #id)();
  TextColumn get tagId => text().references(Tags, #id)();

  @override
  Set<Column> get primaryKey => {itemId, tagId};
}

/// Gamification (§17) — per-transaction XP grants, not a running total,
/// so undoing a completion can reverse the exact amount that specific
/// event awarded rather than a freshly recomputed value (which could
/// drift if the item was edited, or the reward table changed, in
/// between). `current_level` is always derived from summing this table
/// via the level curve — never stored directly, so it can't desync.
class XpLogs extends Table {
  TextColumn get id => text()();
  TextColumn get itemId => text().references(Items, #id)();
  IntColumn get xpAwarded => integer()();
  DateTimeColumn get awardedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

enum UnlockableType { accentTheme, widgetSkin, pet, furniture }

/// Cosmetic catalog (§17) — one flat, data-driven row per unlockable.
/// Visual data (sprite grid, palette, accent hex) lives in the static
/// `Cosmetics` catalog (`domain/services/cosmetics.dart`), keyed by [id];
/// this table only tracks unlock state, so an unlock is never re-locked
/// even if XP is later reversed (positive-only, §17's own design
/// principle — reversal corrects a mistaken completion, it isn't a
/// punishment).
class Unlockables extends Table {
  TextColumn get id => text()();
  late final type = textEnum<UnlockableType>()();
  TextColumn get name => text()();
  IntColumn get unlockLevel => integer()();
  DateTimeColumn get unlockedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Populated only if Calendar import is switched on in Settings.
class ExternalEvents extends Table {
  TextColumn get id => text()();
  TextColumn get googleEventId => text()();
  TextColumn get calendarId => text()();
  TextColumn get title => text()();
  DateTimeColumn get start => dateTime()();
  DateTimeColumn get end => dateTime().nullable()();
  DateTimeColumn get lastSyncedAt => dateTime()();

  /// True for a Google event with only a `date` (no `dateTime`) — an
  /// all-day event, treated as deadline-like (shown in Today/Up Next)
  /// rather than time-block-like (shown in Time Block), mirroring how
  /// Cove's own items split between `dueAt` and `scheduledStart`.
  BoolColumn get isAllDay => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Exact serialized payload the native home-screen widgets render.
class WidgetCaches extends Table {
  TextColumn get widgetName => text()();
  TextColumn get payloadJson => text()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {widgetName};
}

/// Sync bookkeeping — last_backup_at, drive_file_id,
/// calendar_export_mode, calendar_import_enabled, etc.
class SyncMetas extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

/// Theme mode, first day of week, default reminder offset, widget
/// refresh interval, onboarding-complete flag. No Google credentials —
/// those live in secure platform storage via google_sign_in.
class Settings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}
