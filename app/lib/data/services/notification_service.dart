import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../db/database.dart';
import '../db/tables.dart' show ItemStatus;
import '../repositories/settings_repository.dart';

const _permissionRequestedKey = 'notifications_permission_requested';

// Channel ids were bumped from the original 'reminders' (§7 addendum, on
// request: sound + a bigger style for time blocks) — Android notification
// channels are immutable once created on a device, so changing importance/
// sound/style settings in code has zero effect for anyone who already has
// the old channel from a prior install. A fresh id is the only way these
// settings actually take effect, for existing installs and new ones alike;
// the old channel just goes unused, which is harmless.
const _notificationChannelId = 'reminders_v2';
const _timeBlockChannelId = 'reminders_v2_time_block';

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

  final parts = [?timePart, ?_notesPreview(notes)];
  return parts.isEmpty ? 'Reminder' : parts.join(' · ');
}

/// Shared by [_formatReminderBody] and [momentBody] — truncates a notes
/// preview to [_notesPreviewMaxLength], or `null` for blank/absent notes.
String? _notesPreview(String? notes) {
  final trimmed = notes?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  return trimmed.length > _notesPreviewMaxLength
      ? '${trimmed.substring(0, _notesPreviewMaxLength)}…'
      : trimmed;
}

/// Body for a moment-of notification (§7 addendum, on request) — fires
/// exactly at a time block's start/end or a deadline's due time itself,
/// rather than some lead time before it like [reminderBody]. Public, not
/// private, same reasoning as every other pure body-builder here: kept
/// unit-testable without a platform channel.
String momentBody(String label, String? notes) {
  final notesPart = _notesPreview(notes);
  return notesPart == null ? label : '$label · $notesPart';
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

  /// Requests the Android 13+ notification permission proactively — from
  /// onboarding or the moment Settings' notifications toggle is turned on,
  /// rather than only ever surfacing incidentally the first time an item
  /// mutation happens to schedule a reminder. Shares the same
  /// once-ever-asked flag as [_scheduleCore]'s own call, so calling this
  /// first just means the later, implicit call is a no-op.
  Future<void> requestPermissionIfNeeded() async {
    await _ensureInitialized();
    await _ensurePermission();
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
    await _scheduleMomentNotifications(
      key: item.id,
      title: item.shortTitle ?? item.title,
      notes: item.notes,
      scheduledStart: item.scheduledStart,
      scheduledEnd: item.scheduledEnd,
      dueAt: item.dueAt,
      payload: item.id,
    );
  }

  /// Start/end/due-now notifications (§7 addendum, on request) — fire
  /// exactly at the moment itself, on top of (not instead of) the
  /// existing lead-time reminder above. A time block gets one at its
  /// start and, if it has one, its end; a due-only item gets one at its
  /// due time. Time-block moments use the bigger/louder
  /// [_timeBlockChannelId] channel; the due-now moment uses the same
  /// plain channel as the lead-time reminder.
  Future<void> _scheduleMomentNotifications({
    required String key,
    required String title,
    required String? notes,
    required DateTime? scheduledStart,
    required DateTime? scheduledEnd,
    required DateTime? dueAt,
    required String payload,
  }) async {
    if (scheduledStart != null) {
      await _scheduleCore(
        notificationId: notificationIdFor('$key#start'),
        title: title,
        body: momentBody('Started', notes),
        anchor: scheduledStart,
        idealFireAt: scheduledStart,
        payload: payload,
        timeBlockStyle: true,
      );
      if (scheduledEnd != null) {
        await _scheduleCore(
          notificationId: notificationIdFor('$key#end'),
          title: title,
          body: momentBody('Ended', notes),
          anchor: scheduledEnd,
          idealFireAt: scheduledEnd,
          payload: payload,
          timeBlockStyle: true,
        );
      }
    } else if (dueAt != null) {
      await _scheduleCore(
        notificationId: notificationIdFor('$key#due'),
        title: title,
        body: momentBody('Due now', notes),
        anchor: dueAt,
        idealFireAt: dueAt,
        payload: payload,
      );
    }
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

    // Occurrence rows have no `scheduledEnd` column of their own — a
    // scheduled-kind occurrence's duration is inherited from the
    // template's `scheduledEnd - scheduledStart` delta, same derivation
    // `ItemRepository._effectiveItemForOccurrence` already uses.
    final duration =
        (item.scheduledStart != null && item.scheduledEnd != null)
        ? item.scheduledEnd!.difference(item.scheduledStart!)
        : null;
    await _scheduleMomentNotifications(
      key: occurrence.id,
      title: item.shortTitle ?? item.title,
      notes: item.notes,
      scheduledStart: occurrence.scheduledStart,
      scheduledEnd: (occurrence.scheduledStart != null && duration != null)
          ? occurrence.scheduledStart!.add(duration)
          : null,
      dueAt: occurrence.scheduledStart == null ? occurrence.date : null,
      payload: item.id,
    );
  }

  /// [timeBlockStyle] (§7 addendum, on request: "just like events in
  /// Google Calendar the notification should be bigger") routes to the
  /// louder/taller [_timeBlockChannelId] channel with `Importance.high`
  /// (heads-up display) and an expanded [BigTextStyleInformation] body,
  /// instead of the plain default-importance channel every other
  /// reminder here uses.
  Future<void> _scheduleCore({
    required int notificationId,
    required String title,
    required String body,
    required DateTime anchor,
    required DateTime idealFireAt,
    required String payload,
    bool timeBlockStyle = false,
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

    final androidDetails = timeBlockStyle
        ? AndroidNotificationDetails(
            _timeBlockChannelId,
            'Time blocks',
            channelDescription: 'Start/end alerts for scheduled time blocks',
            icon: 'ic_notification',
            importance: Importance.high,
            priority: Priority.high,
            playSound: true,
            enableVibration: true,
            styleInformation: BigTextStyleInformation(body),
          )
        : AndroidNotificationDetails(
            _notificationChannelId,
            'Reminders',
            channelDescription: 'Reminders for scheduled and due items',
            icon: 'ic_notification',
            playSound: true,
            enableVibration: true,
          );

    try {
      await _plugin.zonedSchedule(
        notificationId,
        title,
        body,
        tz.TZDateTime.from(fireAt, tz.local),
        NotificationDetails(android: androidDetails),
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

  /// The lead-time reminder plus every moment notification
  /// ([_scheduleMomentNotifications]) share this same key prefix, so a
  /// single cancel call clears all of them — needed since
  /// [scheduleForItem]/[scheduleForOccurrence] always cancel-then-
  /// reschedule from scratch, and which of start/end/due actually apply
  /// can change between calls (e.g. an item edited from a time block to
  /// a plain deadline).
  List<int> _notificationIdsFor(String key) => [
    notificationIdFor(key),
    notificationIdFor('$key#start'),
    notificationIdFor('$key#end'),
    notificationIdFor('$key#due'),
  ];

  Future<void> cancelForItem(String itemId) async {
    await _ensureInitialized();
    try {
      for (final id in _notificationIdsFor(itemId)) {
        await _plugin.cancel(id);
      }
    } catch (_) {
      // No platform channel available.
    }
  }

  Future<void> cancelForOccurrence(String occurrenceId) async {
    await _ensureInitialized();
    try {
      for (final id in _notificationIdsFor(occurrenceId)) {
        await _plugin.cancel(id);
      }
    } catch (_) {
      // No platform channel available.
    }
  }
}
