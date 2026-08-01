import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/db/database.dart';
import '../data/db/tables.dart' show ItemStatus;
import '../data/repositories/area_repository.dart';
import '../data/repositories/calendar_sync_repository.dart';
import '../data/repositories/export_repository.dart';
import '../data/repositories/item_repository.dart';
import '../data/repositories/profile_repository.dart';
import '../data/repositories/settings_repository.dart';
import '../data/repositories/tag_repository.dart';
import '../data/repositories/unlockable_repository.dart';
import '../data/repositories/xp_repository.dart';
import '../data/services/notification_service.dart';

final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

final areaRepositoryProvider = Provider<AreaRepository>(
  (ref) => AreaRepository(ref.watch(appDatabaseProvider)),
);

final notificationServiceProvider = Provider<NotificationService>(
  (ref) => NotificationService(ref.watch(settingsRepositoryProvider)),
);

final tagRepositoryProvider = Provider<TagRepository>(
  (ref) => TagRepository(ref.watch(appDatabaseProvider)),
);

final unlockableRepositoryProvider = Provider<UnlockableRepository>(
  (ref) => UnlockableRepository(
    ref.watch(appDatabaseProvider),
    ref.watch(settingsRepositoryProvider),
  ),
);

final xpRepositoryProvider = Provider<XpRepository>(
  (ref) => XpRepository(
    ref.watch(appDatabaseProvider),
    ref.watch(unlockableRepositoryProvider),
  ),
);

final itemRepositoryProvider = Provider<ItemRepository>(
  (ref) => ItemRepository(
    ref.watch(appDatabaseProvider),
    ref.watch(notificationServiceProvider),
    ref.watch(tagRepositoryProvider),
    ref.watch(xpRepositoryProvider),
  ),
);

/// Raw total XP (§17) — the Agenda header's level gauge derives both the
/// level and how far through it XP sits from this; see
/// `XpRepository.watchTotalXp()` for why it's always derived, never stored.
final totalXpProvider = StreamProvider<int>(
  (ref) => ref.watch(xpRepositoryProvider).watchTotalXp(),
);

/// The three-slot cosmetic cluster (§17) shown in Agenda/Up Next/Calendar/
/// Areas' header rows — a list of 3 nullable unlockable ids (`null` = an
/// empty slot). Every list screen watches the same provider so equipping
/// from any of them (or from Settings' Unlocks list) updates them all at
/// once.
final equippedSlotsProvider = StreamProvider<List<String?>>(
  (ref) => ref.watch(unlockableRepositoryProvider).watchEquippedSlots(),
);

final unlockablesProvider = StreamProvider<List<Unlockable>>(
  (ref) => ref.watch(unlockableRepositoryProvider).watchAll(),
);

/// Active accent theme id (§17), `null` = the base theme. A `StateProvider`
/// like [themeModeProvider] (must repaint the whole app immediately on
/// equip, not just on next launch) — seeded from `SettingsRepository` at
/// startup by `CoveApp`, updated in place when the user equips a new one.
final accentThemeIdProvider = StateProvider<String?>((ref) => null);

final allTagsProvider = StreamProvider<List<Tag>>(
  (ref) => ref.watch(tagRepositoryProvider).watchAll(),
);

final tagsForItemProvider = StreamProvider.family<List<Tag>, String>(
  (ref, itemId) => ref.watch(tagRepositoryProvider).watchTagsForItem(itemId),
);

final profileRepositoryProvider = Provider<ProfileRepository>(
  (ref) => ProfileRepository(ref.watch(appDatabaseProvider)),
);

final settingsRepositoryProvider = Provider<SettingsRepository>(
  (ref) => SettingsRepository(ref.watch(appDatabaseProvider)),
);


final exportRepositoryProvider = Provider<ExportRepository>(
  (ref) => ExportRepository(
    ref.watch(appDatabaseProvider),
    ref.watch(itemRepositoryProvider),
  ),
);

final calendarSyncRepositoryProvider = Provider<CalendarSyncRepository>(
  (ref) => CalendarSyncRepository(
    ref.watch(appDatabaseProvider),
    ref.watch(settingsRepositoryProvider),
  ),
);

final externalEventsInRangeProvider =
    StreamProvider.family<
      List<ExternalEvent>,
      ({DateTime start, DateTime end})
    >(
      (ref, range) => ref
          .watch(calendarSyncRepositoryProvider)
          .watchExternalEventsForRange(range.start, range.end),
    );

/// Active (non-archived) areas — used for onboarding's area management and
/// the quick-add sheet's `@area`
/// matching and anywhere else that should only offer areas the user kept.
final activeAreasProvider = StreamProvider<List<Area>>(
  (ref) => ref.watch(areaRepositoryProvider).watchAll(),
);

final profileProvider = StreamProvider<Profile?>(
  (ref) => ref.watch(profileRepositoryProvider).watchProfile(),
);

/// `DateTime.monday` or `DateTime.sunday` (§11) — a `FutureProvider`, not
/// a `StreamProvider`, matching how every other Settings value in this
/// app is read (loaded once, not continuously watched); see
/// `SettingsRepository.getFirstDayOfWeek`.
final firstDayOfWeekProvider = FutureProvider<int>(
  (ref) => ref.watch(settingsRepositoryProvider).getFirstDayOfWeek(),
);

/// Theme mode (§11) — a `StateProvider`, not a `FutureProvider` like
/// [firstDayOfWeekProvider], because switching it must repaint the whole
/// app immediately (no restart). Seeded from `SettingsRepository` at
/// startup by `CoveApp`; Settings' theme row updates both this state and
/// the persisted value on change.
final themeModeProvider = StateProvider<ThemeMode>((ref) => ThemeMode.system);

final scheduledForDayProvider =
    StreamProvider.family<List<ItemWithArea>, DateTime>(
      (ref, day) => ref.watch(itemRepositoryProvider).watchScheduledForDay(day),
    );

final dueForDayProvider = StreamProvider.family<List<ItemWithArea>, DateTime>(
  (ref, day) => ref.watch(itemRepositoryProvider).watchDueForDay(day),
);

final upcomingItemsProvider =
    StreamProvider.family<List<ItemWithArea>, DateTime>(
      (ref, from) =>
          ref.watch(itemRepositoryProvider).watchUpcoming(from: from),
    );

final areaProgressProvider =
    StreamProvider.family<List<AreaProgress>, DateTime>(
      (ref, today) => ref
          .watch(itemRepositoryProvider)
          .watchAreaProgress(
            now: today,
            firstWeekday:
                ref.watch(firstDayOfWeekProvider).value ?? DateTime.monday,
          ),
    );

final itemsInRangeProvider =
    StreamProvider.family<List<ItemWithArea>, ({DateTime start, DateTime end})>(
      (ref, range) => ref
          .watch(itemRepositoryProvider)
          .watchItemsInRange(range.start, range.end),
    );

final subtasksProvider = StreamProvider.family<List<Item>, String>(
  (ref, parentId) => ref.watch(itemRepositoryProvider).watchSubtasks(parentId),
);

final archivedItemsProvider =
    StreamProvider.family<List<ItemWithArea>, ItemStatus?>(
      (ref, filter) =>
          ref.watch(itemRepositoryProvider).watchArchived(filter: filter),
    );
