import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../db/database.dart';
import '../db/tables.dart' show ItemStatus;
import '../repositories/settings_repository.dart';

const _permissionRequestedKey = 'notifications_permission_requested';
const _notificationChannelId = 'reminders';

/// The anchor time a reminder fires relative to, minus the offset. Pure
/// date math — kept separate from the plugin-calling methods below so it's
/// unit-testable without a platform channel. Prefers `scheduled_start` over
/// `due_at` when an item somehow has both (§7 lists both, in that order).
DateTime? reminderFireTime(Item item, int offsetMinutes) {
  final anchor = item.scheduledStart ?? item.dueAt;
  if (anchor == null) return null;
  return anchor.subtract(Duration(minutes: offsetMinutes));
}

/// The offset options now go up to 1 day/5 hours (§11) — long enough
/// that [idealFireAt] (the anchor minus the configured offset) is
/// routinely already in the past for anything due sooner than that,
/// e.g. a "due in 2 hours" item with the default "1 hour before" offset
/// used to fine, but "1 day before" never fires at all for it. Rather
/// than silently skipping the reminder outright whenever that happens,
/// clamp to [now] — the item itself is still ahead of us, so it still
/// deserves *a* reminder, just shorter notice than the configured offset
/// would ideally give. Returns null only when [anchor] itself has
/// already passed (nothing left to remind about).
DateTime? clampedReminderFireTime({
  required DateTime idealFireAt,
  required DateTime anchor,
  required DateTime now,
}) {
  if (!anchor.isAfter(now)) return null;
  return idealFireAt.isBefore(now) ? now : idealFireAt;
}

int notificationIdFor(String itemId) => itemId.hashCode & 0x7fffffff;

String _pad2(int n) => n.toString().padLeft(2, '0');

const _notesPreviewMaxLength = 80;

/// Shared by [reminderBody] and [occurrenceReminderBody] — the time it's
/// for, plus a short notes preview when there's room to say something
/// more than just "Reminder". Pure string building, kept separate from
/// the plugin-calling code below so it's unit-testable without a
/// platform channel, same reasoning as [reminderFireTime].
String _formatReminderBody({
  DateTime? scheduledStart,
  DateTime? scheduledEnd,
  DateTime? dueAt,
  String? notes,
}) {
  final String? timePart;
  if (scheduledStart != null) {
    timePart = scheduledEnd == null
        ? 'Starts ${_pad2(scheduledStart.hour)}:${_pad2(scheduledStart.minute)}'
        : '${_pad2(scheduledStart.hour)}:${_pad2(scheduledStart.minute)}'
              '–${_pad2(scheduledEnd.hour)}:${_pad2(scheduledEnd.minute)}';
  } else if (dueAt != null) {
    timePart = (dueAt.hour == 23 && dueAt.minute == 59)
        ? null
        : 'Due ${_pad2(dueAt.hour)}:${_pad2(dueAt.minute)}';
  } else {
    timePart = null;
  }

  final trimmedNotes = notes?.trim();
  final notesPart = (trimmedNotes == null || trimmedNotes.isEmpty)
      ? null
      : trimmedNotes.length > _notesPreviewMaxLength
      ? '${trimmedNotes.substring(0, _notesPreviewMaxLength)}…'
      : trimmedNotes;

  final parts = [?timePart, ?notesPart];
  return parts.isEmpty ? 'Reminder' : parts.join(' · ');
}

String reminderBody(Item item) => _formatReminderBody(
  scheduledStart: item.scheduledStart,
  scheduledEnd: item.scheduledEnd,
  dueAt: item.dueAt,
  notes: item.notes,
);

/// Same shape as [reminderBody], sourced from one materialized
/// [Occurrence] instead of the recurring item's own template anchor —
/// `Occurrence` has no `scheduledEnd` column, so a time-blocked
/// recurrence only ever shows "Starts", never a range.
String occurrenceReminderBody(Item item, Occurrence occurrence) =>
    _formatReminderBody(
      scheduledStart: occurrence.scheduledStart,
      dueAt: occurrence.scheduledStart == null ? occurrence.date : null,
      notes: item.notes,
    );

/// Local reminders for scheduled/due items (§7). Entirely on-device — no
/// relation to either Google connection. Every plugin-calling method is
/// wrapped so a missing platform channel (unit tests) or a denied
/// permission never blocks or corrupts the item write that triggered it
/// (§12), same rule already applied to `home_widget` in step 2.
class NotificationService {
  NotificationService(this._settings);

  final SettingsRepository _settings;
  final _plugin = FlutterLocalNotificationsPlugin();
  final _tapController = StreamController<String>.broadcast();

  Future<void>? _initFuture;
  bool _tzReady = false;

  /// Emits the tapped item's id whenever a reminder notification is opened
  /// while the app is running.
  Stream<String> get itemTapped => _tapController.stream;

  Future<void> _ensureInitialized() {
    return _initFuture ??= _init();
  }

  Future<void> _init() async {
    try {
      if (!_tzReady) {
        tz_data.initializeTimeZones();
        final name = await FlutterTimezone.getLocalTimezone();
        tz.setLocalLocation(tz.getLocation(name));
        _tzReady = true;
      }
      // A flat alpha-only vector, not @mipmap/ic_launcher — Android renders
      // status-bar icons from the alpha channel only, so a full-color
      // opaque launcher icon shows as a solid block. Anchored against R8's
      // resource shrinker (isShrinkResources, §13) via a manifest meta-data
      // reference in AndroidManifest.xml, since it's otherwise referenced
      // only by string name from here, which the shrinker can't see.
      const androidSettings = AndroidInitializationSettings(
        'ic_notification',
      );
      await _plugin.initialize(
        const InitializationSettings(android: androidSettings),
        onDidReceiveNotificationResponse: (details) {
          final id = details.payload;
          if (id != null) _tapController.add(id);
        },
      );
    } catch (_) {
      // No platform channel available (e.g. running under `flutter test`).
    }
  }

  /// The item id a notification launched the app with, if any — checked
  /// once at startup for the cold-start case.
  Future<String?> consumeLaunchPayload() async {
    await _ensureInitialized();
    try {
      final details = await _plugin.getNotificationAppLaunchDetails();
      if (details?.didNotificationLaunchApp == true) {
        return details!.notificationResponse?.payload;
      }
    } catch (_) {
      // No platform channel available.
    }
    return null;
  }

  Future<void> _ensurePermission() async {
    final alreadyAsked = await _settings.getValue(_permissionRequestedKey);
    if (alreadyAsked == 'true') return;
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
    } catch (_) {
      // No platform channel available.
    }
    await _settings.setValue(_permissionRequestedKey, 'true');
  }

  /// Whether exact-time delivery is currently available — re-checked on
  /// every schedule call (not "ask once ever" like [_ensurePermission]),
  /// since this is a special permission the user can revoke from system
  /// Settings independently of anything this app does. Requests it via
  /// the OS's own settings screen the first time it isn't yet granted; a
  /// declined/unavailable request just means [scheduleForItem] falls back
  /// to inexact delivery instead of failing outright.
  Future<bool> _canScheduleExact() async {
    try {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (android == null) return false;
      if (await android.canScheduleExactNotifications() ?? false) return true;
      return await android.requestExactAlarmsPermission() ?? false;
    } catch (_) {
      // No platform channel available (e.g. running under `flutter test`).
      return false;
    }
  }

  /// Schedules (or reschedules) a reminder for [item] if it's open and has
  /// a scheduled/due date in the future; cancels any existing one
  /// otherwise. Called from `ItemRepository`'s mutation path.
  ///
  /// Recurring items are deliberately excluded — [ItemRepository] schedules
  /// those through [scheduleForOccurrence] instead, one materialized
  /// instance at a time, so this just cancels any stale item-level
  /// reminder and stops (a recurring item's own template anchor fields
  /// otherwise describe the *first* occurrence only, which would double
  /// up with the occurrence-level reminder for that same date).
  Future<void> scheduleForItem(Item item) async {
    await cancelForItem(item.id);
    if (item.status != ItemStatus.open) return;
    if (item.recurrenceRule != null) return;
    if (!await _settings.getNotificationsEnabled()) return;

    final offset = item.reminderOffsetMinutes;
    if (offset < 0) return; // -1 sentinel: this item's reminder is off
    final anchor = item.scheduledStart ?? item.dueAt;
    if (anchor == null) return;
    final idealFireAt = reminderFireTime(item, offset)!;

    await _scheduleCore(
      notificationId: notificationIdFor(item.id),
      title: item.shortTitle ?? item.title,
      body: reminderBody(item),
      anchor: anchor,
      idealFireAt: idealFireAt,
      payload: item.id,
    );
  }

  /// Schedules (or reschedules) a reminder for one materialized
  /// [Occurrence] of a recurring [item] — `ItemRepository` only ever
  /// calls this for the single *soonest* still-open occurrence, not every
  /// materialized instance (recurrence horizons run ~60 days ahead, and
  /// scheduling dozens of exact alarms at once for one repeating task
  /// would be wasteful and could hit OS alarm-count limits). Tapping the
  /// resulting notification opens the item template (same [payload] as
  /// [scheduleForItem]) since there's no dedicated occurrence detail
  /// screen to deep-link to.
  Future<void> scheduleForOccurrence(Item item, Occurrence occurrence) async {
    await cancelForOccurrence(occurrence.id);
    if (item.status != ItemStatus.open) return;
    if (!await _settings.getNotificationsEnabled()) return;

    final offset = item.reminderOffsetMinutes;
    if (offset < 0) return;
    final anchor = occurrence.scheduledStart ?? occurrence.date;
    final idealFireAt = anchor.subtract(Duration(minutes: offset));

    await _scheduleCore(
      notificationId: notificationIdFor(occurrence.id),
      title: item.shortTitle ?? item.title,
      body: occurrenceReminderBody(item, occurrence),
      anchor: anchor,
      idealFireAt: idealFireAt,
      payload: item.id,
    );
  }

  Future<void> _scheduleCore({
    required int notificationId,
    required String title,
    required String body,
    required DateTime anchor,
    required DateTime idealFireAt,
    required String payload,
  }) async {
    await _ensureInitialized();
    await _ensurePermission();
    final exact = await _canScheduleExact();

    // `now` is deliberately captured here, after the awaits above, not at
    // the top of this method — the plugin below rejects any scheduledDate
    // that isn't strictly in the future, and the permission/init checks
    // can take long enough that an earlier-captured `now` has already
    // elapsed by the time we get here. The extra second is headroom for
    // the zonedSchedule platform-channel round trip itself.
    final fireAt = clampedReminderFireTime(
      idealFireAt: idealFireAt,
      anchor: anchor,
      now: DateTime.now().add(const Duration(seconds: 1)),
    );
    if (fireAt == null) return;

    try {
      await _plugin.zonedSchedule(
        notificationId,
        title,
        body,
        tz.TZDateTime.from(fireAt, tz.local),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _notificationChannelId,
            'Reminders',
            channelDescription: 'Reminders for scheduled and due items',
            icon: 'ic_notification',
          ),
        ),
        androidScheduleMode: exact
            ? AndroidScheduleMode.exactAllowWhileIdle
            : AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        payload: payload,
      );
    } catch (_) {
      // No platform channel available, or permission was denied.
    }
  }

  Future<void> cancelForItem(String itemId) async {
    await _ensureInitialized();
    try {
      await _plugin.cancel(notificationIdFor(itemId));
    } catch (_) {
      // No platform channel available.
    }
  }

  Future<void> cancelForOccurrence(String occurrenceId) async {
    await _ensureInitialized();
    try {
      await _plugin.cancel(notificationIdFor(occurrenceId));
    } catch (_) {
      // No platform channel available.
    }
  }
}
