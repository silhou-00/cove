import 'package:app/domain/services/recurrence_expander.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const expander = RecurrenceExpander();

  test(
    'FREQ=DAILY includes every day from anchor through horizon inclusive',
    () {
      final dates = expander.expand(
        rule: 'FREQ=DAILY',
        anchor: DateTime(2026, 7, 27),
        horizonEnd: DateTime(2026, 7, 30),
      );
      expect(dates, [
        DateTime(2026, 7, 27),
        DateTime(2026, 7, 28),
        DateTime(2026, 7, 29),
        DateTime(2026, 7, 30),
      ]);
    },
  );

  test('FREQ=WEEKLY repeats every 7 days on the anchor\'s weekday', () {
    // Monday 27 Jul 2026.
    final dates = expander.expand(
      rule: 'FREQ=WEEKLY',
      anchor: DateTime(2026, 7, 27),
      horizonEnd: DateTime(2026, 8, 17),
    );
    expect(dates, [
      DateTime(2026, 7, 27),
      DateTime(2026, 8, 3),
      DateTime(2026, 8, 10),
      DateTime(2026, 8, 17),
    ]);
  });

  test('FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR only includes matching weekdays', () {
    // Monday 27 Jul 2026 through Monday 3 Aug 2026 — skips the weekend.
    final dates = expander.expand(
      rule: 'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR',
      anchor: DateTime(2026, 7, 27),
      horizonEnd: DateTime(2026, 8, 3),
    );
    expect(dates, [
      DateTime(2026, 7, 27), // Mon
      DateTime(2026, 7, 28), // Tue
      DateTime(2026, 7, 29), // Wed
      DateTime(2026, 7, 30), // Thu
      DateTime(2026, 7, 31), // Fri
      DateTime(2026, 8, 3), // Mon (skips Sat 1st, Sun 2nd)
    ]);
  });

  test('BYDAY rule excludes the anchor itself when it doesn\'t match', () {
    // Saturday 1 Aug 2026 — "every weekday" from a weekend anchor.
    final dates = expander.expand(
      rule: 'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR',
      anchor: DateTime(2026, 8, 1),
      horizonEnd: DateTime(2026, 8, 4),
    );
    expect(dates, [DateTime(2026, 8, 3), DateTime(2026, 8, 4)]);
  });

  test('horizon before anchor returns nothing', () {
    final dates = expander.expand(
      rule: 'FREQ=DAILY',
      anchor: DateTime(2026, 7, 27),
      horizonEnd: DateTime(2026, 7, 20),
    );
    expect(dates, isEmpty);
  });

  test('anchor equal to horizon returns exactly the anchor', () {
    final dates = expander.expand(
      rule: 'FREQ=DAILY',
      anchor: DateTime(2026, 7, 27),
      horizonEnd: DateTime(2026, 7, 27),
    );
    expect(dates, [DateTime(2026, 7, 27)]);
  });

  test('time-of-day on anchor/horizon is ignored — dates only', () {
    final dates = expander.expand(
      rule: 'FREQ=DAILY',
      anchor: DateTime(2026, 7, 27, 21, 30),
      horizonEnd: DateTime(2026, 7, 28, 6, 0),
    );
    expect(dates, [DateTime(2026, 7, 27), DateTime(2026, 7, 28)]);
  });

  group('anchor far in the past is capped, not fully expanded', () {
    test('FREQ=DAILY stays within the max span instead of one huge batch', () {
      final dates = expander.expand(
        rule: 'FREQ=DAILY',
        anchor: DateTime(2016, 1, 1),
        horizonEnd: DateTime(2026, 7, 30),
      );
      expect(dates.length, lessThan(410));
      expect(dates.last, DateTime(2026, 7, 30));
    });

    test(
      'FREQ=WEEKLY keeps the anchor\'s original weekday phase after clamping',
      () {
        // Anchor is a Wednesday, years back — every clamped result must
        // still fall on a Wednesday, not whatever weekday the clamp
        // boundary itself happens to be.
        final anchor = DateTime(2016, 1, 6); // Wednesday
        final dates = expander.expand(
          rule: 'FREQ=WEEKLY',
          anchor: anchor,
          horizonEnd: DateTime(2026, 7, 29), // Wednesday
        );
        expect(dates, isNotEmpty);
        for (final d in dates) {
          expect(d.weekday, DateTime.wednesday);
        }
        expect(dates.length, lessThan(60));
      },
    );
  });
}
