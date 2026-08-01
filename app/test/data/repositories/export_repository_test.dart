import 'package:app/data/db/database.dart';
import 'package:app/data/repositories/area_repository.dart';
import 'package:app/data/repositories/export_repository.dart';
import 'package:app/data/repositories/item_repository.dart';
import 'package:app/data/repositories/profile_repository.dart';
import 'package:app/data/repositories/settings_repository.dart';
import 'package:app/data/repositories/tag_repository.dart';
import 'package:app/data/repositories/xp_repository.dart';
import 'package:app/data/services/notification_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late AreaRepository areaRepo;
  late ItemRepository itemRepo;
  late TagRepository tagRepo;
  late ProfileRepository profileRepo;
  late SettingsRepository settingsRepo;
  late ExportRepository exportRepo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    areaRepo = AreaRepository(db);
    tagRepo = TagRepository(db);
    settingsRepo = SettingsRepository(db);
    itemRepo = ItemRepository(
      db,
      NotificationService(settingsRepo),
      tagRepo,
      XpRepository(db),
    );
    profileRepo = ProfileRepository(db);
    exportRepo = ExportRepository(db, itemRepo);
  });

  tearDown(() async {
    await db.close();
  });

  group('Export/import (§11)', () {
    test(
      'round-trip preserves items, areas, tags, and profile after a full wipe',
      () async {
        await profileRepo.saveProfile(firstName: 'Test');
        final areas = await areaRepo.getAll();
        final work = areas.firstWhere((a) => a.name == 'Work');
        final item = await itemRepo.create(
          title: 'Ship it',
          areaId: work.id,
          dueAt: DateTime(2026, 8, 1),
          tags: ['urgent'],
        );

        final json = await exportRepo.exportToJson();

        // Wipe everything first, so a passing import proves it actually
        // rebuilt the data rather than it having silently stayed put.
        await db.delete(db.itemTags).go();
        await db.delete(db.items).go();
        await db.delete(db.areas).go();
        await db.delete(db.tags).go();
        await db.delete(db.profiles).go();

        await exportRepo.importFromJson(json);

        final profile = await profileRepo.getProfile();
        expect(profile?.firstName, 'Test');

        final restoredAreas = await areaRepo.getAll();
        expect(restoredAreas.map((a) => a.name), contains('Work'));

        final restoredItem = await itemRepo.getByIdWithArea(item.id);
        expect(restoredItem, isNotNull);
        expect(restoredItem!.item.title, 'Ship it');
        expect(restoredItem.area?.name, 'Work');

        final tags = await tagRepo.watchTagsForItem(item.id).first;
        expect(tags.map((t) => t.name), contains('urgent'));
      },
    );

    test(
      'importFromJson re-expands recurrence occurrences (not part of the export itself)',
      () async {
        final today = DateTime.now();
        await itemRepo.create(
          title: 'Daily standup',
          scheduledStart: DateTime(today.year, today.month, today.day, 9),
          recurrenceRule: 'FREQ=DAILY',
        );

        final json = await exportRepo.exportToJson();
        await db.delete(db.occurrences).go();

        await exportRepo.importFromJson(json);

        final occurrences = await db.select(db.occurrences).get();
        expect(occurrences, isNotEmpty);
      },
    );

    test(
      'clearAllData wipes items/areas/tags/profile/settings and re-seeds the four preset areas',
      () async {
        await profileRepo.saveProfile(firstName: 'Test');
        await settingsRepo.markOnboardingComplete();
        await itemRepo.create(title: 'Temp', dueAt: DateTime(2026, 8, 1));

        await exportRepo.clearAllData();

        expect(await profileRepo.getProfile(), isNull);
        expect(await settingsRepo.isOnboardingComplete(), isFalse);
        expect(await db.select(db.items).get(), isEmpty);

        final areasAfter = await areaRepo.getAll();
        expect(areasAfter.map((a) => a.name).toSet(), {
          'School',
          'Work',
          'Personal',
          'Projects',
        });
      },
    );
  });
}
