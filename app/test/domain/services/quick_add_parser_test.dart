import 'package:app/data/db/tables.dart' show ItemPriority;
import 'package:app/domain/services/quick_add_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Monday 27 Jul 2026 — matches the design prototype's own in-app "today".
  final now = DateTime(2026, 7, 27);
  const parser = QuickAddParser();
  const areaNames = ['School', 'Work', 'Personal', 'Projects', 'Certs'];

  test('1: date only -> deadline', () {
    final r = parser.parse(
      'email prof re lab @school #email fri',
      now: now,
      areaNames: areaNames,
    );
    expect(r.title, 'email prof re lab');
    expect(r.areaName, 'School');
    expect(r.tags, ['email']);
    expect(r.dueAt, DateTime(2026, 7, 31, 23, 59));
    expect(r.scheduledStart, isNull);
  });

  test('2: date + time -> scheduled block', () {
    final r = parser.parse(
      'submit timesheet @work fri 5pm',
      now: now,
      areaNames: areaNames,
    );
    expect(r.title, 'submit timesheet');
    expect(r.areaName, 'Work');
    expect(r.scheduledStart, DateTime(2026, 7, 31, 17, 0));
    expect(r.scheduledEnd, isNull);
    expect(r.dueAt, isNull);
  });

  test('3: bare time range, no date -> assumes today', () {
    final r = parser.parse(
      'az-204 container apps lab @certs 7pm-9pm #az-204',
      now: now,
      areaNames: areaNames,
    );
    expect(r.title, 'az-204 container apps lab');
    expect(r.areaName, 'Certs');
    expect(r.tags, ['az-204']);
    expect(r.scheduledStart, DateTime(2026, 7, 27, 19, 0));
    expect(r.scheduledEnd, DateTime(2026, 7, 27, 21, 0));
  });

  test('4: no date -> someday item', () {
    final r = parser.parse('gym !low', now: now, areaNames: areaNames);
    expect(r.title, 'gym');
    expect(r.priority, ItemPriority.low);
    expect(r.dueAt, isNull);
    expect(r.scheduledStart, isNull);
  });

  test('5: explicit due keyword with "next fri"', () {
    final r = parser.parse(
      'renew passport due next fri',
      now: now,
      areaNames: areaNames,
    );
    expect(r.title, 'renew passport');
    expect(r.dueAt, DateTime(2026, 7, 31, 23, 59));
  });

  test('6: bare time, no date, plus recurrence', () {
    final r = parser.parse(
      'standup @work 9am every day',
      now: now,
      areaNames: areaNames,
    );
    expect(r.title, 'standup');
    expect(r.areaName, 'Work');
    expect(r.scheduledStart, DateTime(2026, 7, 27, 9, 0));
    expect(r.recurrenceRule, 'FREQ=DAILY');
  });

  test('7: relative date + priority', () {
    final r = parser.parse(
      'pay rent in 3 days !high',
      now: now,
      areaNames: areaNames,
    );
    expect(r.title, 'pay rent');
    expect(r.dueAt, DateTime(2026, 7, 30, 23, 59));
    expect(r.priority, ItemPriority.high);
  });

  test('8: due keyword overrides a date+time back to deadline', () {
    final r = parser.parse(
      'essay due mon 11:59pm @school #essay',
      now: now,
      areaNames: areaNames,
    );
    expect(r.title, 'essay');
    expect(r.areaName, 'School');
    expect(r.tags, ['essay']);
    expect(r.dueAt, DateTime(2026, 7, 27, 23, 59));
    expect(r.scheduledStart, isNull);
  });

  test('9: sched keyword confirms scheduled semantics', () {
    final r = parser.parse(
      'dentist appt sched mon 10am',
      now: now,
      areaNames: areaNames,
    );
    expect(r.title, 'dentist appt');
    expect(r.scheduledStart, DateTime(2026, 7, 27, 10, 0));
    expect(r.dueAt, isNull);
  });

  test('10: zero-friction capture', () {
    final r = parser.parse('water plants', now: now, areaNames: areaNames);
    expect(r.title, 'water plants');
    expect(r.areaName, isNull);
    expect(r.priority, isNull);
    expect(r.dueAt, isNull);
    expect(r.scheduledStart, isNull);
    expect(r.tags, isEmpty);
  });

  test(
    'out-of-range typed dates are left as literal text, not silently rolled over',
    () {
      final monthDay = parser.parse(
        'report jul 45',
        now: now,
        areaNames: areaNames,
      );
      expect(monthDay.dueAt, isNull);
      expect(monthDay.title, 'report jul 45');

      final slash = parser.parse(
        'report 13/45',
        now: now,
        areaNames: areaNames,
      );
      expect(slash.dueAt, isNull);
      expect(slash.title, 'report 13/45');
    },
  );
}
