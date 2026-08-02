import '../../domain/services/calendar_export_decision.dart'
    show CalendarExportMode;
import '../db/database.dart';

export '../../domain/services/calendar_export_decision.dart'
    show CalendarExportMode;

/// Agenda list ordering (§4). `manual` is the only mode where drag-reorder
/// is active — the others just pick which field the list is sorted by.
enum ItemSortMode { dueDate, priority, created, manual }

/// Key-value settings (§3): theme mode, first day of week, default reminder
/// offset, widget refresh interval, Calendar export mode, onboarding-complete
/// flag. No Google credentials — those live in secure platform storage.
class SettingsRepository {
  SettingsRepository(this._db);

  final AppDatabase _db;

  static const onboardingCompleteKey = 'onboarding_complete';
  static const agendaSortKey = 'agenda_sort';
  // Global kill switch (§7/§11) — per-item reminder offset lives on the
  // item itself (`Items.reminderOffsetMinutes`) now, not here; this only
  // controls whether reminders fire at all, regardless of what any item
  // has set.
  static const notificationsEnabledKey = 'notifications_enabled';
  static const firstDayOfWeekKey = 'first_day_of_week';
  static const widgetRefreshIntervalKey = 'widget_refresh_interval_minutes';
  static const widgetRefreshIntervalDefaultMinutes = 30;
  static const themeModeKey = 'theme_mode';
  static const calendarExportModeKey = 'calendar_export_mode';

  /// Cosmetic unlocks (§17). Three homogeneous slots — unlike the design
  /// handoff's fixed furniture/pet/flex split, any slot can hold either a
  /// pet or a furniture unlock (deliberate simplification the user asked
  /// for over the mockup's version). Accent theme and widget skin are
  /// single active picks, not slotted.
  static const activeAccentThemeIdKey = 'active_accent_theme_id';
  static const activeWidgetSkinIdKey = 'active_widget_skin_id';
  static const _equippedSlotKeys = [
    'equipped_slot_1',
    'equipped_slot_2',
    'equipped_slot_3',
  ];

  /// App Lock (§12) escalating-lockout state — persisted, not held in
  /// widget `State`, so force-closing and reopening the app between wrong
  /// PIN guesses can't reset the lockout to zero. Two independent
  /// key-pairs: the front-door lock screen and the Settings
  /// disable-App-Lock re-confirmation sheet track separate attempt
  /// counts, since a lockout on one shouldn't block the other.
  static const appLockFailedAttemptsKey = 'applock_failed_attempts';
  static const appLockLockoutUntilKey = 'applock_lockout_until';
  static const confirmPinFailedAttemptsKey = 'confirm_pin_failed_attempts';
  static const confirmPinLockoutUntilKey = 'confirm_pin_lockout_until';

  Future<String?> getValue(String key) async {
    final row = await (_db.select(
      _db.settings,
    )..where((s) => s.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<void> setValue(String key, String value) {
    return _db
        .into(_db.settings)
        .insertOnConflictUpdate(
          SettingsCompanion.insert(key: key, value: value),
        );
  }

  Future<bool> isOnboardingComplete() async =>
      (await getValue(onboardingCompleteKey)) == 'true';

  Future<void> markOnboardingComplete() =>
      setValue(onboardingCompleteKey, 'true');

  Future<ItemSortMode> getAgendaSort() async {
    final value = await getValue(agendaSortKey);
    return ItemSortMode.values.firstWhere(
      (mode) => mode.name == value,
      orElse: () => ItemSortMode.dueDate,
    );
  }

  Future<void> setAgendaSort(ItemSortMode mode) =>
      setValue(agendaSortKey, mode.name);

  Future<bool> getNotificationsEnabled() async =>
      (await getValue(notificationsEnabledKey)) != 'false';

  Future<void> setNotificationsEnabled(bool enabled) =>
      setValue(notificationsEnabledKey, enabled.toString());

  /// `DateTime.monday` (1) or `DateTime.sunday` (7) — matches `DateTime.
  /// weekday`'s own numbering, so callers can feed this straight into
  /// `startOfWeek()` without a lookup table.
  Future<int> getFirstDayOfWeek() async {
    final value = await getValue(firstDayOfWeekKey);
    return value == 'monday' ? DateTime.monday : DateTime.sunday;
  }

  Future<void> setFirstDayOfWeek(int weekday) => setValue(
    firstDayOfWeekKey,
    weekday == DateTime.sunday ? 'sunday' : 'monday',
  );

  Future<int> getWidgetRefreshIntervalMinutes() async {
    final value = await getValue(widgetRefreshIntervalKey);
    return value != null
        ? int.tryParse(value) ?? widgetRefreshIntervalDefaultMinutes
        : widgetRefreshIntervalDefaultMinutes;
  }

  Future<void> setWidgetRefreshIntervalMinutes(int minutes) =>
      setValue(widgetRefreshIntervalKey, minutes.toString());

  /// `'light'` / `'dark'` / `'system'` (§11) — a plain string, not
  /// Flutter's `ThemeMode`, so this data-layer class stays framework-free
  /// like the rest of the file; `app/providers.dart` maps it to
  /// `ThemeMode` for `MaterialApp.router`.
  Future<String> getThemeMode() async =>
      (await getValue(themeModeKey)) ?? 'system';

  Future<void> setThemeMode(String mode) => setValue(themeModeKey, mode);

  Future<CalendarExportMode> getCalendarExportMode() async {
    final value = await getValue(calendarExportModeKey);
    return CalendarExportMode.values.firstWhere(
      (mode) => mode.name == value,
      orElse: () => CalendarExportMode.askEachTime,
    );
  }

  Future<void> setCalendarExportMode(CalendarExportMode mode) =>
      setValue(calendarExportModeKey, mode.name);

  Future<int> getFailedAttempts(String key) async {
    final value = await getValue(key);
    return value != null ? int.tryParse(value) ?? 0 : 0;
  }

  Future<void> setFailedAttempts(String key, int count) =>
      setValue(key, count.toString());

  Future<DateTime?> getLockoutUntil(String key) async {
    final value = await getValue(key);
    return (value == null || value.isEmpty) ? null : DateTime.tryParse(value);
  }

  Future<void> setLockoutUntil(String key, DateTime? until) =>
      setValue(key, until?.toIso8601String() ?? '');

  Future<String?> getActiveAccentThemeId() => getValue(activeAccentThemeIdKey);

  Future<void> setActiveAccentThemeId(String id) =>
      setValue(activeAccentThemeIdKey, id);

  Future<String?> getActiveWidgetSkinId() => getValue(activeWidgetSkinIdKey);

  Future<void> setActiveWidgetSkinId(String id) =>
      setValue(activeWidgetSkinIdKey, id);

  /// [slot] is 1-3, matching the three cluster slots shown in the header
  /// row of Agenda/Up Next/Calendar/Areas.
  Future<String?> getEquippedSlot(int slot) =>
      getValue(_equippedSlotKeys[slot - 1]);

  Future<void> setEquippedSlot(int slot, String id) =>
      setValue(_equippedSlotKeys[slot - 1], id);
}
