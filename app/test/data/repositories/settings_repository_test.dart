import 'package:app/data/db/database.dart';
import 'package:app/data/repositories/settings_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late SettingsRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = SettingsRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('Notifications enabled (§7/§11)', () {
    test('defaults to true (on) when unset', () async {
      expect(await repo.getNotificationsEnabled(), isTrue);
    });

    test('persists turning it off, then back on', () async {
      await repo.setNotificationsEnabled(false);
      expect(await repo.getNotificationsEnabled(), isFalse);

      await repo.setNotificationsEnabled(true);
      expect(await repo.getNotificationsEnabled(), isTrue);
    });
  });

  group('First day of week (§11)', () {
    test('defaults to Sunday when unset', () async {
      expect(await repo.getFirstDayOfWeek(), DateTime.sunday);
    });

    test('persists Sunday, then persists switching back to Monday', () async {
      await repo.setFirstDayOfWeek(DateTime.sunday);
      expect(await repo.getFirstDayOfWeek(), DateTime.sunday);

      await repo.setFirstDayOfWeek(DateTime.monday);
      expect(await repo.getFirstDayOfWeek(), DateTime.monday);
    });
  });

  group('Widget refresh interval (§11)', () {
    test('defaults to 30 minutes when unset', () async {
      expect(await repo.getWidgetRefreshIntervalMinutes(), 30);
    });

    test('persists a set value', () async {
      await repo.setWidgetRefreshIntervalMinutes(120);
      expect(await repo.getWidgetRefreshIntervalMinutes(), 120);
    });
  });

  group('Theme mode (§11)', () {
    test('defaults to "system" when unset', () async {
      expect(await repo.getThemeMode(), 'system');
    });

    test('persists "light" and "dark"', () async {
      await repo.setThemeMode('light');
      expect(await repo.getThemeMode(), 'light');

      await repo.setThemeMode('dark');
      expect(await repo.getThemeMode(), 'dark');
    });
  });

  group('Calendar export mode (§9)', () {
    test('defaults to askEachTime when unset', () async {
      expect(
        await repo.getCalendarExportMode(),
        CalendarExportMode.askEachTime,
      );
    });

    test('persists alwaysAdd and never', () async {
      await repo.setCalendarExportMode(CalendarExportMode.alwaysAdd);
      expect(await repo.getCalendarExportMode(), CalendarExportMode.alwaysAdd);

      await repo.setCalendarExportMode(CalendarExportMode.never);
      expect(await repo.getCalendarExportMode(), CalendarExportMode.never);
    });
  });
}
