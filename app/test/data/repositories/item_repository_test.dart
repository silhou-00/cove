import 'dart:convert';

import 'package:app/data/db/database.dart';
import 'package:app/data/db/tables.dart';
import 'package:app/data/repositories/area_repository.dart';
import 'package:app/data/repositories/item_repository.dart';
import 'package:app/data/repositories/settings_repository.dart';
import 'package:app/data/repositories/tag_repository.dart';
import 'package:app/data/repositories/xp_repository.dart';
import 'package:app/data/services/notification_service.dart';
import 'package:app/domain/services/quick_add_parser.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late AreaRepository areaRepo;
  late ItemRepository itemRepo;
  late TagRepository tagRepo;
  late XpRepository xpRepo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    areaRepo = AreaRepository(db);
    tagRepo = TagRepository(db);
    xpRepo = XpRepository(db);
    itemRepo = ItemRepository(
      db,
      NotificationService(SettingsRepository(db)),
      tagRepo,
      xpRepo,
    );
  });

  tearDown(() async {
    await db.close();
  });

  test(
    'create writes an item and refreshes the up_next cache when dueAt is set',
    () async {
      final item = await itemRepo.create(
        title: 'Pay rent',
        dueAt: DateTime(2026, 7, 30, 23, 59),
        priority: ItemPriority.high,
      );

      expect(item.title, 'Pay rent');
      expect(item.status, ItemStatus.open);

      final cache = await (db.select(
        db.widgetCaches,
      )..where((w) => w.widgetName.equals('up_next'))).getSingle();
      final payload = jsonDecode(cache.payloadJson) as List;
      expect(payload, hasLength(1));
      expect(payload.first['title'], 'Pay rent');
    },
  );

  group('Per-item reminder offset (§7/§11)', () {
    test('create defaults reminderOffsetMinutes to 60 when unset', () async {
      final item = await itemRepo.create(title: 'Water plants');
      expect(item.reminderOffsetMinutes, 60);
    });

    test('create accepts an explicit reminderOffsetMinutes', () async {
      final item = await itemRepo.create(
        title: 'Call dentist',
        reminderOffsetMinutes: -1,
      );
      expect(item.reminderOffsetMinutes, -1);
    });

    test('update changes an existing item\'s reminderOffsetMinutes', () async {
      final item = await itemRepo.create(title: 'Submit report');
      expect(item.reminderOffsetMinutes, 60);

      await itemRepo.update(
        item.id,
        const ItemsCompanion(reminderOffsetMinutes: Value(1440)),
      );
      final updated = await itemRepo.getByIdWithArea(item.id);
      expect(updated?.item.reminderOffsetMinutes, 1440);
    });
  });

  group('Gamification — XP on complete/un-complete (§17)', () {
    test('toggleComplete awards XP when marking an item done', () async {
      final item = await itemRepo.create(title: 'Water plants');
      await itemRepo.toggleComplete(item.id);

      final rows = await db.select(db.xpLogs).get();
      expect(rows, hasLength(1));
      expect(rows.single.itemId, item.id);
    });

    test('toggling back to open reverses the XP that was awarded', () async {
      final item = await itemRepo.create(title: 'Water plants');
      await itemRepo.toggleComplete(item.id);
      expect(await db.select(db.xpLogs).get(), hasLength(1));

      await itemRepo.toggleComplete(item.id);
      expect(await db.select(db.xpLogs).get(), isEmpty);
    });

    test(
      'toggleOccurrenceComplete awards XP under the template\'s item_id',
      () async {
        final item = await itemRepo.create(
          title: 'Meditate',
          dueAt: DateTime(2026, 7, 27, 23, 59),
          recurrenceRule: 'FREQ=DAILY',
          now: DateTime(2026, 7, 27),
        );
        final tuesdayRow =
            (await itemRepo
                    .watchDueForDay(DateTime(2026, 7, 28))
                    .first)
                .single;

        await itemRepo.toggleOccurrenceComplete(tuesdayRow.occurrenceId!);

        final rows = await db.select(db.xpLogs).get();
        expect(rows, hasLength(1));
        expect(rows.single.itemId, item.id);
      },
    );
  });

  test('createFromQuickAdd resolves @area against seeded areas', () async {
    final areas = await areaRepo.getAll();
    const parser = QuickAddParser();

    final item = await itemRepo.createFromQuickAdd(
      'submit timesheet @work fri 5pm',
      parser: parser,
      areas: areas,
    );

    final work = areas.firstWhere((a) => a.name == 'Work');
    expect(item.areaId, work.id);
    expect(item.title, 'submit timesheet');
    expect(item.scheduledStart, isNotNull);
  });

  group('Tags (§4)', () {
    test('createFromQuickAdd persists parsed #tags', () async {
      final areas = await areaRepo.getAll();
      const parser = QuickAddParser();

      final item = await itemRepo.createFromQuickAdd(
        'az-204 lab @certs 7pm-9pm #az-204 #lab',
        parser: parser,
        areas: areas,
      );

      final tags = await tagRepo.watchTagsForItem(item.id).first;
      expect(tags.map((t) => t.name).toSet(), {'az-204', 'lab'});
    });

    test(
      'the same tag name is reused (case-insensitive), not duplicated',
      () async {
        final item1 = await itemRepo.create(title: 'First', tags: ['Errand']);
        final item2 = await itemRepo.create(title: 'Second', tags: ['errand']);

        final allTags = await tagRepo.getAll();
        expect(
          allTags.where((t) => t.name.toLowerCase() == 'errand'),
          hasLength(1),
        );

        final tags1 = await tagRepo.watchTagsForItem(item1.id).first;
        final tags2 = await tagRepo.watchTagsForItem(item2.id).first;
        expect(tags1.single.id, tags2.single.id);
      },
    );

    test(
      'setTagsForItem replaces the previous tag set, not additive',
      () async {
        final item = await itemRepo.create(title: 'Task', tags: ['one', 'two']);

        await tagRepo.setTagsForItem(item.id, ['two', 'three']);

        final tags = await tagRepo.watchTagsForItem(item.id).first;
        expect(tags.map((t) => t.name).toSet(), {'two', 'three'});
      },
    );
  });

  group('update() with recurrence regeneration (Item Detail)', () {
    final monday = DateTime(2026, 7, 27);

    test(
      'adding a recurrence rule to a non-recurring item materializes occurrences',
      () async {
        final item = await itemRepo.create(
          title: 'Meditate',
          dueAt: DateTime(2026, 7, 27, 23, 59),
          now: monday,
        );
        expect(
          await (db.select(
            db.occurrences,
          )..where((o) => o.itemId.equals(item.id))).get(),
          isEmpty,
        );

        await itemRepo.update(
          item.id,
          const ItemsCompanion(recurrenceRule: Value('FREQ=DAILY')),
          now: monday,
        );

        final occurrences = await (db.select(
          db.occurrences,
        )..where((o) => o.itemId.equals(item.id))).get();
        expect(occurrences, hasLength(61));
      },
    );

    test(
      'editing recurrence regenerates future occurrences but preserves past/completed ones',
      () async {
        final item = await itemRepo.create(
          title: 'Meditate',
          dueAt: DateTime(2026, 7, 27, 23, 59),
          recurrenceRule: 'FREQ=DAILY',
          now: monday,
        );
        // Complete Monday's occurrence before editing — this is "past/completed" history.
        final mondayRow = (await itemRepo.watchDueForDay(monday).first).single;
        await itemRepo.toggleOccurrenceComplete(mondayRow.occurrenceId!);

        // Switch to weekdays-only, "today" now Wednesday.
        final wednesday = DateTime(2026, 7, 29);
        await itemRepo.update(
          item.id,
          const ItemsCompanion(
            recurrenceRule: Value('FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR'),
          ),
          now: wednesday,
        );

        final mondayAfter =
            await (db.select(db.occurrences)..where(
                  (o) => o.itemId.equals(item.id) & o.date.equals(monday),
                ))
                .getSingle();
        expect(
          mondayAfter.status,
          OccurrenceStatus.done,
          reason: 'past/completed occurrence must survive the edit',
        );

        final saturday = DateTime(2026, 8, 1);
        final saturdayRows =
            await (db.select(db.occurrences)..where(
                  (o) => o.itemId.equals(item.id) & o.date.equals(saturday),
                ))
                .get();
        expect(
          saturdayRows,
          isEmpty,
          reason: 'weekends must be excluded under the new weekdays-only rule',
        );

        final futureWeekdayRows =
            await (db.select(db.occurrences)..where(
                  (o) =>
                      o.itemId.equals(item.id) &
                      o.date.equals(DateTime(2026, 7, 30)),
                ))
                .get();
        expect(futureWeekdayRows, hasLength(1));
      },
    );

    test(
      'removing recurrence deletes future occurrences but keeps past/completed history',
      () async {
        final item = await itemRepo.create(
          title: 'Meditate',
          dueAt: DateTime(2026, 7, 27, 23, 59),
          recurrenceRule: 'FREQ=DAILY',
          now: monday,
        );
        final mondayRow = (await itemRepo.watchDueForDay(monday).first).single;
        await itemRepo.toggleOccurrenceComplete(mondayRow.occurrenceId!);

        await itemRepo.update(
          item.id,
          const ItemsCompanion(recurrenceRule: Value(null)),
          now: DateTime(2026, 7, 28),
        );

        final remaining = await (db.select(
          db.occurrences,
        )..where((o) => o.itemId.equals(item.id))).get();
        expect(remaining, hasLength(1));
        expect(remaining.single.date, monday);
        expect(remaining.single.status, OccurrenceStatus.done);
      },
    );
  });

  test(
    'toggleComplete flips status and removes item from up_next cache once done',
    () async {
      final item = await itemRepo.create(
        title: 'Water plants',
        dueAt: DateTime(2026, 7, 27, 23, 59),
      );

      await itemRepo.toggleComplete(item.id);

      final updated = await (db.select(
        db.items,
      )..where((i) => i.id.equals(item.id))).getSingle();
      expect(updated.status, ItemStatus.done);
      expect(updated.completedAt, isNotNull);

      final cache = await (db.select(
        db.widgetCaches,
      )..where((w) => w.widgetName.equals('up_next'))).getSingle();
      final payload = jsonDecode(cache.payloadJson) as List;
      expect(payload, isEmpty);
    },
  );

  test('permanentlyDelete removes the item and refreshes the cache', () async {
    final item = await itemRepo.create(
      title: 'Temp item',
      dueAt: DateTime(2026, 7, 28),
    );

    await itemRepo.permanentlyDelete(item.id);

    final remaining = await db.select(db.items).get();
    expect(remaining, isEmpty);

    final cache = await (db.select(
      db.widgetCaches,
    )..where((w) => w.widgetName.equals('up_next'))).getSingle();
    final payload = jsonDecode(cache.payloadJson) as List;
    expect(payload, isEmpty);
  });

  test(
    'setExternalCalendarEventId (§9) writes the id without touching anything else',
    () async {
      final item = await itemRepo.create(
        title: 'Dentist',
        dueAt: DateTime(2026, 7, 28),
      );

      await itemRepo.setExternalCalendarEventId(item.id, 'google-evt-123');

      final updated = await (db.select(
        db.items,
      )..where((i) => i.id.equals(item.id))).getSingle();
      expect(updated.externalCalendarEventId, 'google-evt-123');
      expect(updated.title, 'Dentist');
    },
  );

  group('Archive (§4) — cancel/archive/restore/bulk/reorder (V3 Step 3)', () {
    test(
      'cancelItem moves the item to Archive as cancelled and stops future occurrences',
      () async {
        // cancelItem has no `now` override — it always compares against the
        // real clock, so the anchor must be real "today", not a fixed date
        // that could land in the past by the time this test runs.
        final today = DateTime.now();
        final item = await itemRepo.create(
          title: 'Standup',
          scheduledStart: DateTime(today.year, today.month, today.day, 9),
          recurrenceRule: 'FREQ=DAILY',
        );

        await itemRepo.cancelItem(item.id);

        final updated = await (db.select(
          db.items,
        )..where((i) => i.id.equals(item.id))).getSingle();
        expect(updated.status, ItemStatus.cancelled);
        expect(updated.archivedAt, isNotNull);

        final remainingOccurrences = await (db.select(
          db.occurrences,
        )..where((o) => o.itemId.equals(item.id))).get();
        expect(remainingOccurrences, isEmpty);
      },
    );

    test(
      'archiveItem soft-deletes the item (status deleted) without removing the row',
      () async {
        final item = await itemRepo.create(
          title: 'Old note',
          dueAt: DateTime(2026, 7, 28),
        );

        await itemRepo.archiveItem(item.id);

        final updated = await (db.select(
          db.items,
        )..where((i) => i.id.equals(item.id))).getSingle();
        expect(updated.status, ItemStatus.deleted);
        expect(updated.archivedAt, isNotNull);
      },
    );

    test(
      'restoreItem brings an archived item back to open and clears archivedAt/completedAt',
      () async {
        final item = await itemRepo.create(
          title: 'Reopen me',
          dueAt: DateTime(2026, 7, 28),
        );
        await itemRepo.toggleComplete(item.id);

        await itemRepo.restoreItem(item.id);

        final updated = await (db.select(
          db.items,
        )..where((i) => i.id.equals(item.id))).getSingle();
        expect(updated.status, ItemStatus.open);
        expect(updated.completedAt, isNull);
        expect(updated.archivedAt, isNull);
      },
    );

    test(
      'watchArchived surfaces done/cancelled/deleted items, most recently archived first, optionally filtered',
      () async {
        final done = await itemRepo.create(
          title: 'Done item',
          dueAt: DateTime(2026, 7, 28),
        );
        final cancelled = await itemRepo.create(
          title: 'Cancelled item',
          dueAt: DateTime(2026, 7, 28),
        );
        final deleted = await itemRepo.create(
          title: 'Deleted item',
          dueAt: DateTime(2026, 7, 28),
        );
        final open = await itemRepo.create(
          title: 'Still open',
          dueAt: DateTime(2026, 7, 28),
        );

        await itemRepo.toggleComplete(done.id);
        await itemRepo.cancelItem(cancelled.id);
        await itemRepo.archiveItem(deleted.id);

        final all = await itemRepo.watchArchived().first;
        expect(
          all.map((iwa) => iwa.item.id),
          containsAll([done.id, cancelled.id, deleted.id]),
        );
        expect(all.map((iwa) => iwa.item.id), isNot(contains(open.id)));

        final onlyCancelled = await itemRepo
            .watchArchived(filter: ItemStatus.cancelled)
            .first;
        expect(onlyCancelled, hasLength(1));
        expect(onlyCancelled.single.item.id, cancelled.id);
      },
    );

    test('bulkComplete toggles every selected item', () async {
      final a = await itemRepo.create(title: 'A', dueAt: DateTime(2026, 7, 28));
      final b = await itemRepo.create(title: 'B', dueAt: DateTime(2026, 7, 28));

      await itemRepo.bulkComplete([
        ItemWithArea(item: a),
        ItemWithArea(item: b),
      ]);

      final rows = await db.select(db.items).get();
      expect(rows.every((i) => i.status == ItemStatus.done), isTrue);
    });

    test('bulkArchive archives every selected item', () async {
      final a = await itemRepo.create(title: 'A', dueAt: DateTime(2026, 7, 28));
      final b = await itemRepo.create(title: 'B', dueAt: DateTime(2026, 7, 28));

      await itemRepo.bulkArchive([
        ItemWithArea(item: a),
        ItemWithArea(item: b),
      ]);

      final rows = await db.select(db.items).get();
      expect(rows.every((i) => i.status == ItemStatus.deleted), isTrue);
    });

    test(
      'bulkMoveArea moves every selected item to the given area, or clears it when null',
      () async {
        final areas = await areaRepo.getAll();
        final work = areas.firstWhere((a) => a.name == 'Work');
        final a = await itemRepo.create(
          title: 'A',
          dueAt: DateTime(2026, 7, 28),
        );
        final b = await itemRepo.create(
          title: 'B',
          areaId: work.id,
          dueAt: DateTime(2026, 7, 28),
        );

        await itemRepo.bulkMoveArea([a.id, b.id], work.id);
        var rows = await db.select(db.items).get();
        expect(rows.every((i) => i.areaId == work.id), isTrue);

        await itemRepo.bulkMoveArea([a.id, b.id], null);
        rows = await db.select(db.items).get();
        expect(rows.every((i) => i.areaId == null), isTrue);
      },
    );

    test(
      'reorderItems writes sequential sortOrder values matching the given order',
      () async {
        final a = await itemRepo.create(
          title: 'A',
          dueAt: DateTime(2026, 7, 28),
        );
        final b = await itemRepo.create(
          title: 'B',
          dueAt: DateTime(2026, 7, 28),
        );
        final c = await itemRepo.create(
          title: 'C',
          dueAt: DateTime(2026, 7, 28),
        );

        await itemRepo.reorderItems([c.id, a.id, b.id]);

        final rows = {
          for (final i in await db.select(db.items).get()) i.id: i.sortOrder,
        };
        expect(rows[c.id], 0);
        expect(rows[a.id], 1);
        expect(rows[b.id], 2);
      },
    );
  });

  group('§5 Agenda/Up Next reads', () {
    final monday = DateTime(2026, 7, 27);

    test(
      'watchScheduledForDay only returns open items scheduled that day — done items move to Archive',
      () async {
        await itemRepo.create(
          title: 'Standup',
          scheduledStart: DateTime(2026, 7, 27, 8, 30),
        );
        final essay = await itemRepo.create(
          title: 'Essay',
          scheduledStart: DateTime(2026, 7, 27, 14, 0),
        );
        await itemRepo.create(
          title: 'Tomorrow thing',
          scheduledStart: DateTime(2026, 7, 28, 9, 0),
        );
        await itemRepo.toggleComplete(essay.id);

        final rows = await itemRepo.watchScheduledForDay(monday).first;

        expect(rows, hasLength(1));
        expect(rows.single.item.title, 'Standup');
      },
    );

    test('watchDueForDay only returns items due that day', () async {
      await itemRepo.create(
        title: 'Water plants',
        dueAt: DateTime(2026, 7, 27, 23, 59),
      );
      await itemRepo.create(
        title: 'Later thing',
        dueAt: DateTime(2026, 7, 29, 23, 59),
      );

      final rows = await itemRepo.watchDueForDay(monday).first;

      expect(rows, hasLength(1));
      expect(rows.single.item.title, 'Water plants');
    });

    test('watchUpcoming excludes today and is sorted ascending', () async {
      await itemRepo.create(
        title: 'Due today',
        dueAt: DateTime(2026, 7, 27, 23, 59),
      );
      await itemRepo.create(
        title: 'Pay rent',
        dueAt: DateTime(2026, 7, 30, 23, 59),
      );
      await itemRepo.create(
        title: 'Reading response',
        dueAt: DateTime(2026, 7, 28, 23, 59),
      );

      final tomorrow = monday.add(const Duration(days: 1));
      final rows = await itemRepo.watchUpcoming(from: tomorrow).first;

      expect(rows.map((r) => r.item.title), ['Reading response', 'Pay rent']);
    });

    test('area join resolves the right area, or null when unset', () async {
      final areas = await areaRepo.getAll();
      final school = areas.firstWhere((a) => a.name == 'School');
      await itemRepo.create(
        title: 'With area',
        areaId: school.id,
        dueAt: monday,
      );
      await itemRepo.create(title: 'No area', dueAt: monday);

      final rows = await itemRepo.watchDueForDay(monday).first;

      final withArea = rows.firstWhere((r) => r.item.title == 'With area');
      final noArea = rows.firstWhere((r) => r.item.title == 'No area');
      expect(withArea.area?.name, 'School');
      expect(noArea.area, isNull);
    });

    test(
      'watchItemsInRange includes scheduled and due items, excludes outside-range and dateless',
      () async {
        final weekEnd = monday.add(const Duration(days: 7));

        final scheduled = await itemRepo.create(
          title: 'Standup',
          scheduledStart: DateTime(2026, 7, 28, 8, 30),
        );
        final due = await itemRepo.create(
          title: 'Essay',
          dueAt: DateTime(2026, 7, 30, 23, 59),
        );
        await itemRepo.create(
          title: 'Next week thing',
          dueAt: DateTime(2026, 8, 5, 23, 59),
        );
        await itemRepo.create(title: 'Someday item');

        final rows = await itemRepo.watchItemsInRange(monday, weekEnd).first;
        final titles = rows.map((r) => r.item.title).toSet();

        expect(titles, {'Standup', 'Essay'});
        expect(rows.any((r) => r.item.id == scheduled.id), isTrue);
        expect(rows.any((r) => r.item.id == due.id), isTrue);
      },
    );
  });

  group('watchAreaProgress (§6 formula, written spec not the mockup)', () {
    final monday = DateTime(2026, 7, 27);

    test(
      'counts done-this-week and open-due-this-week, excludes outside-week and no-area items',
      () async {
        final areas = await areaRepo.getAll();
        final school = areas.firstWhere((a) => a.name == 'School');

        // Completed this week -> counts toward doneThisWeek.
        final doneItem = await itemRepo.create(
          title: 'Finished thing',
          areaId: school.id,
        );
        await (db.update(
          db.items,
        )..where((i) => i.id.equals(doneItem.id))).write(
          ItemsCompanion(
            status: Value(ItemStatus.done),
            completedAt: Value(DateTime(2026, 7, 28, 10, 0)),
          ),
        );

        // Open, due this week -> counts toward openDueThisWeek.
        await itemRepo.create(
          title: 'Still open',
          areaId: school.id,
          dueAt: DateTime(2026, 7, 29, 23, 59),
        );

        // Done, but completed last week -> must not count.
        final oldDone = await itemRepo.create(
          title: 'Old done',
          areaId: school.id,
        );
        await (db.update(
          db.items,
        )..where((i) => i.id.equals(oldDone.id))).write(
          ItemsCompanion(
            status: Value(ItemStatus.done),
            completedAt: Value(DateTime(2026, 7, 20, 10, 0)),
          ),
        );

        // Open, due next week -> must not count.
        await itemRepo.create(
          title: 'Future thing',
          areaId: school.id,
          dueAt: DateTime(2026, 8, 5, 23, 59),
        );

        final stats = await itemRepo.watchAreaProgress(now: monday).first;
        final schoolStat = stats.firstWhere((s) => s.area.id == school.id);

        expect(schoolStat.doneThisWeek, 1);
        expect(schoolStat.openDueThisWeek, 1);
        expect(schoolStat.hasActivity, isTrue);
        expect(schoolStat.ratio, 0.5);
      },
    );

    test(
      'an area with no activity this week has hasActivity false and ratio 0 (renders as "—")',
      () async {
        final stats = await itemRepo.watchAreaProgress(now: monday).first;
        final work = stats.firstWhere((s) => s.area.name == 'Work');

        expect(work.hasActivity, isFalse);
        expect(work.ratio, 0);
      },
    );

    test('items with no area are excluded from every area\'s stats', () async {
      await itemRepo.create(
        title: 'No area item',
        dueAt: DateTime(2026, 7, 28, 23, 59),
      );

      final stats = await itemRepo.watchAreaProgress(now: monday).first;
      final totalOpenDue = stats.fold<int>(
        0,
        (sum, s) => sum + s.openDueThisWeek,
      );

      expect(totalOpenDue, 0);
    });
  });

  group('V2 widget-cache payloads (agenda/areas)', () {
    test(
      'agenda cache carries raw open items with a schedule or due date, unfiltered by day',
      () async {
        final areas = await areaRepo.getAll();
        final work = areas.firstWhere((a) => a.name == 'Work');

        final scheduled = await itemRepo.create(
          title: 'Standup',
          areaId: work.id,
          scheduledStart: DateTime(2026, 7, 27, 8, 30),
          scheduledEnd: DateTime(2026, 7, 27, 9, 0),
        );
        final due = await itemRepo.create(
          title: 'Submit report',
          dueAt: DateTime(2026, 8, 15, 23, 59),
        );
        final noDate = await itemRepo.create(title: 'Someday item');
        final doneItem = await itemRepo.create(
          title: 'Done thing',
          dueAt: DateTime(2026, 7, 27, 23, 59),
        );
        await itemRepo.toggleComplete(doneItem.id);

        final cache = await (db.select(
          db.widgetCaches,
        )..where((w) => w.widgetName.equals('agenda'))).getSingle();
        final payload = (jsonDecode(cache.payloadJson) as List)
            .cast<Map<String, dynamic>>();
        final ids = payload.map((p) => p['id']).toSet();

        expect(ids, containsAll([scheduled.id, due.id]));
        expect(ids, isNot(contains(noDate.id)));
        expect(ids, isNot(contains(doneItem.id)));

        final standup = payload.firstWhere((p) => p['id'] == scheduled.id);
        expect(standup['area'], 'Work');
        expect(standup['scheduledStart'], isNotNull);
        expect(standup['scheduledEnd'], isNotNull);
        expect(standup['dueAt'], isNull);
      },
    );

    test(
      'areas cache carries raw areas + only items that could ever count toward the formula',
      () async {
        final areas = await areaRepo.getAll();
        final school = areas.firstWhere((a) => a.name == 'School');

        final counts = await itemRepo.create(
          title: 'Relevant',
          areaId: school.id,
          dueAt: DateTime(2026, 7, 29),
        );
        await itemRepo.create(title: 'No date, no area'); // excluded either way
        await itemRepo.create(
          title: 'No date but has area',
          areaId: school.id,
        ); // excluded: no due/completed date

        final cache = await (db.select(
          db.widgetCaches,
        )..where((w) => w.widgetName.equals('areas'))).getSingle();
        final payload = jsonDecode(cache.payloadJson) as Map<String, dynamic>;
        final payloadAreas = (payload['areas'] as List)
            .cast<Map<String, dynamic>>();
        final payloadItems = (payload['items'] as List)
            .cast<Map<String, dynamic>>();

        expect(
          payloadAreas.map((a) => a['name']),
          containsAll(['School', 'Work', 'Personal', 'Projects']),
        );
        expect(payloadItems, hasLength(1));
        expect(payloadItems.single['areaId'], school.id);
        expect(payloadItems.single['status'], 'open');
        expect(counts.areaId, school.id);
      },
    );
  });

  group('Recurrence (§3, V3 Step 1)', () {
    final monday = DateTime(2026, 7, 27);

    test(
      'creating a daily recurring item materializes occurrences through the 60-day horizon',
      () async {
        final item = await itemRepo.create(
          title: 'Meditate',
          dueAt: DateTime(2026, 7, 27, 23, 59),
          recurrenceRule: 'FREQ=DAILY',
          now: monday,
        );

        final occurrences = await (db.select(
          db.occurrences,
        )..where((o) => o.itemId.equals(item.id))).get();
        // Anchor (27 Jul) through 60 days later (25 Sep) inclusive = 61 days.
        expect(occurrences, hasLength(61));
        expect(
          occurrences
              .map((o) => o.date)
              .reduce((a, b) => a.isBefore(b) ? a : b),
          DateTime(2026, 7, 27),
        );
        expect(
          occurrences.map((o) => o.date).reduce((a, b) => a.isAfter(b) ? a : b),
          DateTime(2026, 9, 25),
        );
      },
    );

    test(
      'a recurring item is shown via its occurrences, never via its own raw date',
      () async {
        await itemRepo.create(
          title: 'Standup',
          scheduledStart: DateTime(2026, 7, 27, 9, 0),
          recurrenceRule: 'FREQ=DAILY',
          now: monday,
        );

        final rows = await itemRepo
            .watchScheduledForDay(DateTime(2026, 7, 29))
            .first;

        expect(rows, hasLength(1));
        expect(rows.single.item.title, 'Standup');
        expect(rows.single.occurrenceId, isNotNull);
        expect(rows.single.item.scheduledStart, DateTime(2026, 7, 29, 9, 0));
      },
    );

    test(
      'watchItemsInRange surfaces every occurrence of a weekday-only recurring item in the range',
      () async {
        await itemRepo.create(
          title: 'Gym',
          scheduledStart: DateTime(2026, 7, 27, 6, 0), // Monday
          scheduledEnd: DateTime(2026, 7, 27, 7, 0),
          recurrenceRule: 'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR',
          now: monday,
        );

        final rows = await itemRepo
            .watchItemsInRange(monday, monday.add(const Duration(days: 7)))
            .first;

        // Mon-Fri this week, weekend skipped.
        expect(rows, hasLength(5));
        expect(rows.every((r) => r.item.title == 'Gym'), isTrue);
        expect(
          rows
              .map(
                (r) => r.item.scheduledEnd!.difference(r.item.scheduledStart!),
              )
              .toSet(),
          {const Duration(hours: 1)},
        );
      },
    );

    test(
      'toggling one occurrence complete does not affect sibling occurrences or the template',
      () async {
        final item = await itemRepo.create(
          title: 'Meditate',
          dueAt: DateTime(2026, 7, 27, 23, 59),
          recurrenceRule: 'FREQ=DAILY',
          now: monday,
        );
        final tuesdayRow =
            (await itemRepo.watchDueForDay(DateTime(2026, 7, 28)).first).single;

        await itemRepo.toggleOccurrenceComplete(tuesdayRow.occurrenceId!);

        final mondayRows = await itemRepo.watchDueForDay(monday).first;
        final wednesdayRows = await itemRepo
            .watchDueForDay(DateTime(2026, 7, 29))
            .first;
        expect(mondayRows.single.item.status, ItemStatus.open);
        expect(wednesdayRows.single.item.status, ItemStatus.open);

        final template = await (db.select(
          db.items,
        )..where((i) => i.id.equals(item.id))).getSingle();
        expect(template.status, ItemStatus.open);
        expect(template.completedAt, isNull);
      },
    );

    test(
      'extendRecurrenceHorizons tops up without duplicating existing occurrences',
      () async {
        final item = await itemRepo.create(
          title: 'Meditate',
          dueAt: DateTime(2026, 7, 27, 23, 59),
          recurrenceRule: 'FREQ=DAILY',
          now: monday,
        );

        // Calling it again for the same "now" must not create duplicates.
        await itemRepo.extendRecurrenceHorizons(now: monday);
        final unchanged = await (db.select(
          db.occurrences,
        )..where((o) => o.itemId.equals(item.id))).get();
        expect(unchanged, hasLength(61));

        // Advancing "now" by 10 days should extend the horizon by exactly 10 more days.
        await itemRepo.extendRecurrenceHorizons(
          now: monday.add(const Duration(days: 10)),
        );
        final extended = await (db.select(
          db.occurrences,
        )..where((o) => o.itemId.equals(item.id))).get();
        expect(extended, hasLength(71));
        expect(
          extended.map((o) => o.date).reduce((a, b) => a.isAfter(b) ? a : b),
          DateTime(2026, 10, 5),
        );
      },
    );

    test(
      'permanentlyDelete on a recurring item cascades to delete all its occurrences',
      () async {
        final item = await itemRepo.create(
          title: 'Meditate',
          dueAt: DateTime(2026, 7, 27, 23, 59),
          recurrenceRule: 'FREQ=DAILY',
          now: monday,
        );

        await itemRepo.permanentlyDelete(item.id);

        final remainingOccurrences = await (db.select(
          db.occurrences,
        )..where((o) => o.itemId.equals(item.id))).get();
        expect(remainingOccurrences, isEmpty);
      },
    );

    test(
      'watchAreaProgress counts a completed occurrence toward doneThisWeek',
      () async {
        final areas = await areaRepo.getAll();
        final school = areas.firstWhere((a) => a.name == 'School');
        await itemRepo.create(
          title: 'Read a chapter',
          areaId: school.id,
          dueAt: DateTime(2026, 7, 27, 23, 59),
          recurrenceRule: 'FREQ=DAILY',
          now: monday,
        );
        final mondayRow = (await itemRepo.watchDueForDay(monday).first).single;

        await itemRepo.toggleOccurrenceComplete(mondayRow.occurrenceId!);

        final stats = await itemRepo.watchAreaProgress(now: monday).first;
        final schoolStat = stats.firstWhere((s) => s.area.id == school.id);
        expect(schoolStat.doneThisWeek, 1);
      },
    );

    test(
      'agenda widget cache includes recurring-item occurrences, not the raw template',
      () async {
        await itemRepo.create(
          title: 'Standup',
          scheduledStart: DateTime(2026, 7, 27, 9, 0),
          recurrenceRule: 'FREQ=DAILY',
          now: monday,
        );

        // Same "raw and unfiltered by day" contract as non-recurring items
        // (see _refreshAgendaCache's doc comment) — every occurrence within
        // the horizon shows up, the native widget picks "today" itself.
        final cache = await (db.select(
          db.widgetCaches,
        )..where((w) => w.widgetName.equals('agenda'))).getSingle();
        final payload = (jsonDecode(cache.payloadJson) as List)
            .cast<Map<String, dynamic>>();
        final standupEntries = payload.where((p) => p['title'] == 'Standup');

        expect(standupEntries, hasLength(61));
        expect(
          standupEntries.any(
            (p) => p['scheduledStart'] == '2026-07-27T09:00:00.000',
          ),
          isTrue,
        );
      },
    );
  });

  group('searchItems (§4/§5, Search + filters)', () {
    test('matches title or notes, case-insensitively', () async {
      await itemRepo.create(
        title: 'Renew passport',
        dueAt: DateTime(2026, 8, 1),
      );
      await itemRepo.create(
        title: 'Buy groceries',
        notes: 'get a new PASSPORT photo too',
      );
      await itemRepo.create(title: 'Unrelated');

      final results = await itemRepo.searchItems(query: 'passport');
      expect(results.map((r) => r.item.title).toSet(), {
        'Renew passport',
        'Buy groceries',
      });
    });

    test(
      'a literal underscore in the query is not treated as a single-char wildcard',
      () async {
        // "_" is SQL LIKE's single-character wildcard — without escaping,
        // searching "file_name" would also match "fileXname" (any
        // character standing in for "_"), which the user never typed.
        await itemRepo.create(title: 'file_name draft');
        await itemRepo.create(title: 'fileXname draft');

        final results = await itemRepo.searchItems(query: 'file_name');
        expect(results.map((r) => r.item.title), ['file_name draft']);
      },
    );

    test('filters by area', () async {
      final areas = await areaRepo.getAll();
      final school = areas.firstWhere((a) => a.name == 'School');
      await itemRepo.create(title: 'Essay', areaId: school.id);
      await itemRepo.create(title: 'Standup');

      final results = await itemRepo.searchItems(areaId: school.id);
      expect(results.map((r) => r.item.title), ['Essay']);
    });

    test('filters by tag', () async {
      final tagged = await itemRepo.create(title: 'Tagged', tags: ['urgent']);
      await itemRepo.create(title: 'Untagged');
      final urgentTag = (await tagRepo.getAll()).firstWhere(
        (t) => t.name == 'urgent',
      );

      final results = await itemRepo.searchItems(tagId: urgentTag.id);
      expect(results.map((r) => r.item.id), [tagged.id]);
    });

    test('filters by status', () async {
      final done = await itemRepo.create(title: 'Done thing');
      await itemRepo.toggleComplete(done.id);
      await itemRepo.create(title: 'Open thing');

      final results = await itemRepo.searchItems(status: ItemStatus.done);
      expect(results.map((r) => r.item.title), ['Done thing']);
    });

    test(
      'filters by date range (matches due or scheduled within range)',
      () async {
        await itemRepo.create(
          title: 'In range',
          dueAt: DateTime(2026, 7, 29, 23, 59),
        );
        await itemRepo.create(
          title: 'Out of range',
          dueAt: DateTime(2026, 8, 20, 23, 59),
        );

        final results = await itemRepo.searchItems(
          startDate: DateTime(2026, 7, 27),
          endDate: DateTime(2026, 8, 3),
        );
        expect(results.map((r) => r.item.title), ['In range']);
      },
    );

    test('combines multiple filters (AND semantics)', () async {
      final areas = await areaRepo.getAll();
      final school = areas.firstWhere((a) => a.name == 'School');
      await itemRepo.create(
        title: 'lab report',
        areaId: school.id,
        tags: ['urgent'],
      );
      await itemRepo.create(
        title: 'lab report',
        tags: ['urgent'],
      ); // no area -> excluded
      await itemRepo.create(
        title: 'lab report',
        areaId: school.id,
      ); // no tag -> excluded

      final urgentTag = (await tagRepo.getAll()).firstWhere(
        (t) => t.name == 'urgent',
      );
      final results = await itemRepo.searchItems(
        query: 'lab',
        areaId: school.id,
        tagId: urgentTag.id,
      );
      expect(results, hasLength(1));
    });
  });
}
