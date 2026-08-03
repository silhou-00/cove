import 'package:app/data/db/database.dart';
import 'package:app/data/db/tables.dart';
import 'package:app/data/services/notification_service.dart';
import 'package:flutter_test/flutter_test.dart';

Item _item({
  DateTime? dueAt,
  DateTime? scheduledStart,
  DateTime? scheduledEnd,
  String? notes,
  int reminderOffsetMinutes = 60,
}) {
  final now = DateTime(2026, 7, 27);
  return Item(
    id: 't1',
    title: 'Test item',
    status: ItemStatus.open,
    dueAt: dueAt,
    scheduledStart: scheduledStart,
    scheduledEnd: scheduledEnd,
    notes: notes,
    reminderOffsetMinutes: reminderOffsetMinutes,
    createdAt: now,
    updatedAt: now,
    sortOrder: 0,
  );
}

void main() {
  group('reminderFireTime', () {
    test('subtracts the offset from scheduledStart when present', () {
      final item = _item(scheduledStart: DateTime(2026, 7, 27, 17, 0));
      expect(reminderFireTime(item, 30), DateTime(2026, 7, 27, 16, 30));
    });

    test('falls back to dueAt when there is no scheduledStart', () {
      final item = _item(dueAt: DateTime(2026, 7, 27, 23, 59));
      expect(reminderFireTime(item, 30), DateTime(2026, 7, 27, 23, 29));
    });

    test('prefers scheduledStart over dueAt when both are set', () {
      final item = _item(
        dueAt: DateTime(2026, 7, 27, 23, 59),
        scheduledStart: DateTime(2026, 7, 27, 9, 0),
      );
      expect(reminderFireTime(item, 30), DateTime(2026, 7, 27, 8, 30));
    });

    test('returns null when the item has neither date', () {
      expect(reminderFireTime(_item(), 30), isNull);
    });
  });

  group('clampedReminderFireTime (§7/§11 — long reminder offsets)', () {
    final now = DateTime(2026, 7, 27, 12, 0);

    test(
      'returns the ideal fire time unchanged when already in the future',
      () {
        final result = clampedReminderFireTime(
          idealFireAt: DateTime(2026, 7, 28, 11, 0),
          anchor: DateTime(2026, 7, 28, 12, 0),
          now: now,
        );
        expect(result, DateTime(2026, 7, 28, 11, 0));
      },
    );

    test(
      'clamps to now when the offset is longer than the time left, but the anchor is still ahead',
      () {
        // Anchor (due) is only 2 hours from now, but the offset (e.g. "1
        // day before") would put the ideal fire time a day in the past.
        final result = clampedReminderFireTime(
          idealFireAt: now.subtract(const Duration(hours: 22)),
          anchor: now.add(const Duration(hours: 2)),
          now: now,
        );
        expect(result, now);
      },
    );

    test('returns null once the anchor itself has already passed', () {
      final result = clampedReminderFireTime(
        idealFireAt: now.subtract(const Duration(days: 2)),
        anchor: now.subtract(const Duration(minutes: 5)),
        now: now,
      );
      expect(result, isNull);
    });
  });

  group('reminderBody', () {
    test('shows the due time when there is no scheduled block', () {
      final item = _item(dueAt: DateTime(2026, 7, 27, 19, 45));
      expect(reminderBody(item), 'Due 19:45');
    });

    test('omits the time for the end-of-day sentinel (23:59)', () {
      final item = _item(dueAt: DateTime(2026, 7, 27, 23, 59));
      expect(reminderBody(item), 'Reminder');
    });

    test('shows a start–end range for a time block', () {
      final item = _item(
        scheduledStart: DateTime(2026, 7, 27, 17, 0),
        scheduledEnd: DateTime(2026, 7, 27, 18, 30),
      );
      expect(reminderBody(item), '17:00–18:30');
    });

    test('shows "Starts" for a time block with no end time', () {
      final item = _item(scheduledStart: DateTime(2026, 7, 27, 17, 0));
      expect(reminderBody(item), 'Starts 17:00');
    });

    test('appends a notes preview when notes are present', () {
      final item = _item(
        dueAt: DateTime(2026, 7, 27, 19, 45),
        notes: 'Bring the folder',
      );
      expect(reminderBody(item), 'Due 19:45 · Bring the folder');
    });

    test('truncates a long notes preview with an ellipsis', () {
      final item = _item(
        dueAt: DateTime(2026, 7, 27, 19, 45),
        notes: 'x' * 200,
      );
      final body = reminderBody(item);
      expect(body, startsWith('Due 19:45 · '));
      expect(body, endsWith('…'));
      expect(body.length, lessThan(200));
    });

    test('falls back to "Reminder" with no time and no notes', () {
      expect(reminderBody(_item()), 'Reminder');
    });
  });

  group('occurrenceReminderBody (§3/§7, per-occurrence reminders)', () {
    final item = _item(notes: 'Bring the mat');

    test('shows the occurrence\'s own due-style date, not the item\'s', () {
      final occurrence = Occurrence(
        id: 'o1',
        itemId: 't1',
        date: DateTime(2026, 8, 3, 7, 30),
        status: OccurrenceStatus.open,
      );
      expect(
        occurrenceReminderBody(item, occurrence),
        'Due 07:30 · Bring the mat',
      );
    });

    test('shows "Starts" for a time-blocked occurrence', () {
      final occurrence = Occurrence(
        id: 'o2',
        itemId: 't1',
        date: DateTime(2026, 8, 3),
        scheduledStart: DateTime(2026, 8, 3, 9, 0),
        status: OccurrenceStatus.open,
      );
      expect(
        occurrenceReminderBody(item, occurrence),
        'Starts 09:00 · Bring the mat',
      );
    });
  });

  group('momentBody (§7 addendum, start/end/due-now notifications)', () {
    test('is just the label when there are no notes', () {
      expect(momentBody('Started', null), 'Started');
      expect(momentBody('Started', ''), 'Started');
    });

    test('appends a notes preview when notes are present', () {
      expect(momentBody('Ended', 'Bring the folder'), 'Ended · Bring the folder');
    });

    test('truncates a long notes preview with an ellipsis', () {
      final body = momentBody('Due now', 'x' * 200);
      expect(body, startsWith('Due now · '));
      expect(body, endsWith('…'));
      expect(body.length, lessThan(200));
    });
  });

  group('notificationIdFor', () {
    test('is deterministic and non-negative', () {
      final id = notificationIdFor('some-item-id');
      expect(id, notificationIdFor('some-item-id'));
      expect(id, greaterThanOrEqualTo(0));
    });
  });
}
