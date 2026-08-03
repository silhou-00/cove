import 'package:app/data/db/database.dart';
import 'package:app/data/repositories/calendar_sync_repository.dart';
import 'package:app/data/repositories/settings_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/calendar/v3.dart' as calendar;

void main() {
  late AppDatabase db;
  late CalendarSyncRepository calendarRepo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    calendarRepo = CalendarSyncRepository(db, SettingsRepository(db));
  });

  tearDown(() async {
    await db.close();
  });

  group('Google Calendar import (§9)', () {
    test('applyEvents writes one ExternalEvent per timed event', () async {
      await calendarRepo.applyEvents([
        calendar.Event(
          id: 'evt-1',
          summary: 'Team standup',
          start: calendar.EventDateTime(dateTime: DateTime(2026, 8, 1, 9, 0)),
          end: calendar.EventDateTime(dateTime: DateTime(2026, 8, 1, 9, 30)),
        ),
      ]);

      final rows = await db.select(db.externalEvents).get();
      expect(rows, hasLength(1));
      expect(rows.single.googleEventId, 'evt-1');
      expect(rows.single.title, 'Team standup');
      expect(rows.single.start, DateTime(2026, 8, 1, 9, 0));
      expect(rows.single.end, DateTime(2026, 8, 1, 9, 30));
    });

    test(
      'applyEvents caps an absurdly long title and falls back for a blank one',
      () async {
        await calendarRepo.applyEvents([
          calendar.Event(
            id: 'evt-long',
            summary: 'x' * 1000,
            start: calendar.EventDateTime(dateTime: DateTime(2026, 8, 1, 9, 0)),
          ),
          calendar.Event(
            id: 'evt-blank',
            summary: '   ',
            start: calendar.EventDateTime(dateTime: DateTime(2026, 8, 2, 9, 0)),
          ),
        ]);

        final rows = await db.select(db.externalEvents).get();
        final long = rows.firstWhere((r) => r.googleEventId == 'evt-long');
        final blank = rows.firstWhere((r) => r.googleEventId == 'evt-blank');
        expect(long.title.length, 300);
        expect(blank.title, '(untitled)');
      },
    );

    test(
      'applyEvents falls back to the all-day date when there is no dateTime',
      () async {
        await calendarRepo.applyEvents([
          calendar.Event(
            id: 'evt-allday',
            summary: 'Company holiday',
            start: calendar.EventDateTime(date: DateTime(2026, 8, 3)),
          ),
        ]);

        final row = (await db.select(db.externalEvents).get()).single;
        expect(row.start, DateTime(2026, 8, 3));
      },
    );

    test(
      'applyEvents marks a dateTime event as not all-day (time-block-like)',
      () async {
        await calendarRepo.applyEvents([
          calendar.Event(
            id: 'evt-timed',
            summary: 'Standup',
            start: calendar.EventDateTime(dateTime: DateTime(2026, 8, 1, 9)),
          ),
        ]);

        final row = (await db.select(db.externalEvents).get()).single;
        expect(row.isAllDay, isFalse);
      },
    );

    test(
      'applyEvents marks a date-only event as all-day (deadline-like)',
      () async {
        await calendarRepo.applyEvents([
          calendar.Event(
            id: 'evt-allday',
            summary: 'Company holiday',
            start: calendar.EventDateTime(date: DateTime(2026, 8, 3)),
          ),
        ]);

        final row = (await db.select(db.externalEvents).get()).single;
        expect(row.isAllDay, isTrue);
      },
    );

    test('applyEvents skips events missing an id or a start', () async {
      await calendarRepo.applyEvents([
        calendar.Event(
          summary: 'No id',
          start: calendar.EventDateTime(dateTime: DateTime(2026, 8, 1)),
        ),
        calendar.Event(id: 'no-start', summary: 'No start'),
      ]);

      expect(await db.select(db.externalEvents).get(), isEmpty);
    });

    test('applyEvents is a full replace, not an accumulating merge', () async {
      await calendarRepo.applyEvents([
        calendar.Event(
          id: 'evt-1',
          summary: 'First sync',
          start: calendar.EventDateTime(dateTime: DateTime(2026, 8, 1, 9)),
        ),
      ]);
      await calendarRepo.applyEvents([
        calendar.Event(
          id: 'evt-2',
          summary: 'Second sync',
          start: calendar.EventDateTime(dateTime: DateTime(2026, 8, 2, 9)),
        ),
      ]);

      final rows = await db.select(db.externalEvents).get();
      expect(rows, hasLength(1));
      expect(rows.single.googleEventId, 'evt-2');
    });

    test(
      'watchExternalEventsForRange only returns events within the range',
      () async {
        await calendarRepo.applyEvents([
          calendar.Event(
            id: 'in-range',
            summary: 'In range',
            start: calendar.EventDateTime(dateTime: DateTime(2026, 8, 5, 10)),
          ),
          calendar.Event(
            id: 'out-of-range',
            summary: 'Out of range',
            start: calendar.EventDateTime(dateTime: DateTime(2026, 9, 1, 10)),
          ),
        ]);

        final results = await calendarRepo
            .watchExternalEventsForRange(
              DateTime(2026, 8, 1),
              DateTime(2026, 8, 31),
            )
            .first;

        expect(results, hasLength(1));
        expect(results.single.googleEventId, 'in-range');
      },
    );

    test(
      'setImportEnabled(false) clears whatever was already synced',
      () async {
        await calendarRepo.applyEvents([
          calendar.Event(
            id: 'evt-1',
            summary: 'Team standup',
            start: calendar.EventDateTime(dateTime: DateTime(2026, 8, 1, 9)),
          ),
        ]);
        expect(await db.select(db.externalEvents).get(), isNotEmpty);

        await calendarRepo.setImportEnabled(false);

        expect(await db.select(db.externalEvents).get(), isEmpty);
        expect(await calendarRepo.isImportEnabled(), isFalse);
      },
    );
  });
}
