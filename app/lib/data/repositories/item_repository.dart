import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:home_widget/home_widget.dart';
import 'package:uuid/uuid.dart';

import '../../domain/services/combine_latest.dart';
import '../../domain/services/gamification.dart';
import '../../domain/services/quick_add_parser.dart';
import '../../domain/services/recurrence_expander.dart';
import '../../domain/services/text_limits.dart';
import '../../domain/services/week_math.dart';
import '../db/database.dart';
import '../db/tables.dart';
import '../services/notification_service.dart';
import 'tag_repository.dart';
import 'xp_repository.dart';

const _upNextWidgetName = 'up_next';
const _upNextWidgetDataKey = 'up_next_payload';
const _upNextAndroidProvider = 'UpNextWidgetProvider';

const _agendaWidgetName = 'agenda';
const _agendaWidgetDataKey = 'agenda_payload';
const _agendaAndroidProvider = 'AgendaWidgetProvider';

const _areasWidgetName = 'areas';
const _areasWidgetDataKey = 'areas_payload';
const _areasAndroidProvider = 'AreasWidgetProvider';

/// An [Item] paired with its (possibly absent) [Area] — the shape the
/// Agenda/Up Next screens actually need, so they don't run a second query
/// per row just to show an area name and color.
class ItemWithArea {
  const ItemWithArea({required this.item, this.area, this.occurrenceId});

  final Item item;
  final Area? area;

  /// Non-null when this row is a materialized [Occurrence] of a recurring
  /// item rather than the template [Item] itself — completion toggles
  /// must target this occurrence (`toggleOccurrenceComplete`), not the
  /// template (`toggleComplete`), or every instance would flip together.
  final String? occurrenceId;
}

DateTime _startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);

int _compareNullable(DateTime? a, DateTime? b) {
  if (a == null && b == null) return 0;
  if (a == null) return -1;
  if (b == null) return 1;
  return a.compareTo(b);
}

/// Per-area weekly progress (§6's Areas widget formula, also the basis for
/// the V2 Areas screen): `done_this_week / (done_this_week +
/// open_due_this_week)`. This is the *written spec's* formula — the design
/// mockup's own JS just does `done / total` over all-time items, which is
/// simpler than §6 actually specifies. An area with no activity either way
/// renders as "—", dimmed, not "0%" (see [hasActivity]).
class AreaProgress {
  const AreaProgress({
    required this.area,
    required this.doneThisWeek,
    required this.openDueThisWeek,
  });

  final Area area;
  final int doneThisWeek;
  final int openDueThisWeek;

  bool get hasActivity => doneThisWeek + openDueThisWeek > 0;
  double get ratio =>
      hasActivity ? doneThisWeek / (doneThisWeek + openDueThisWeek) : 0;
}

/// The only layer allowed to touch `Items`/`WidgetCaches` directly (§2).
/// Every mutation writes the item and recomputes the `up_next` widget-cache
/// row in one drift transaction, then calls `home_widget`'s
/// `updateWidget()` and schedules/cancels its local reminder (§7) — both
/// best-effort. A missing platform channel (no native widget provider
/// exists until step 6; no notification plugin in unit tests) must never
/// block or corrupt the underlying item write (§12).
class ItemRepository {
  ItemRepository(this._db, this._notifications, this._tags, this._xp);

  final AppDatabase _db;
  final NotificationService _notifications;
  final TagRepository _tags;
  final XpRepository _xp;
  static const _uuid = Uuid();

  Stream<List<Item>> watchAll() => _db.select(_db.items).watch();

  /// Subtasks (§4, via `Item.parent_id`) — no separate table, a subtask is
  /// just an `Item` whose `parent_id` points at the parent. Ordered by
  /// creation so newly added subtasks land at the bottom, not sorted by
  /// due/schedule (subtasks usually don't have their own date).
  Stream<List<Item>> watchSubtasks(String parentId) {
    return (_db.select(_db.items)
          ..where((i) => i.parentId.equals(parentId))
          ..orderBy([(i) => OrderingTerm(expression: i.createdAt)]))
        .watch();
  }

  Future<ItemWithArea?> getByIdWithArea(String id) async {
    final query = _db.select(_db.items).join([
      leftOuterJoin(_db.areas, _db.areas.id.equalsExp(_db.items.areaId)),
    ])..where(_db.items.id.equals(id));
    final row = await query.getSingleOrNull();
    if (row == null) return null;
    return ItemWithArea(
      item: row.readTable(_db.items),
      area: row.readTableOrNull(_db.areas),
    );
  }

  /// Archive (§4) — every item that's moved out of the active views
  /// (done, cancelled, or soft-deleted), most recently archived first.
  /// [filter] narrows to one specific status; `null` shows all three.
  /// Occurrences of a recurring item aren't separately archived — the one
  /// template row is what shows here, same as everywhere else.
  Stream<List<ItemWithArea>> watchArchived({ItemStatus? filter}) {
    final query =
        _db.select(_db.items).join([
            leftOuterJoin(_db.areas, _db.areas.id.equalsExp(_db.items.areaId)),
          ])
          ..where(
            filter != null
                ? _db.items.status.equalsValue(filter)
                : _db.items.status.equalsValue(ItemStatus.done) |
                      _db.items.status.equalsValue(ItemStatus.cancelled) |
                      _db.items.status.equalsValue(ItemStatus.deleted),
          )
          ..orderBy([
            OrderingTerm(
              expression: _db.items.archivedAt,
              mode: OrderingMode.desc,
            ),
          ]);
    return query.watch().map(_mapItemWithArea);
  }

  /// Items scheduled (§5 Agenda "Scheduled" section) on [day], ordered by
  /// start time. Only `open` items — done/cancelled/deleted move to
  /// Archive (§4) instead of lingering here struck-through.
  ///
  /// Excludes recurring templates directly (`recurrenceRule` set) — once
  /// an item recurs, only its materialized [Occurrence] rows are ever
  /// shown, including the first one, so "mark this instance done" is
  /// handled the same way for every instance instead of special-casing
  /// day one.
  Stream<List<ItemWithArea>> watchScheduledForDay(DateTime day) {
    final start = _startOfDay(day);
    final end = start.add(const Duration(days: 1));

    final directQuery =
        _db.select(_db.items).join([
            leftOuterJoin(_db.areas, _db.areas.id.equalsExp(_db.items.areaId)),
          ])
          ..where(
            _isOpenItem(_db.items) &
                _db.items.recurrenceRule.isNull() &
                _db.items.scheduledStart.isBiggerOrEqualValue(start) &
                _db.items.scheduledStart.isSmallerThanValue(end),
          )
          ..orderBy([OrderingTerm(expression: _db.items.scheduledStart)]);

    final occQuery =
        _db.select(_db.occurrences).join([
            innerJoin(
              _db.items,
              _db.items.id.equalsExp(_db.occurrences.itemId),
            ),
            leftOuterJoin(_db.areas, _db.areas.id.equalsExp(_db.items.areaId)),
          ])
          ..where(
            _isOpenItem(_db.items) &
                _notSkipped(_db.occurrences) &
                _db.occurrences.scheduledStart.isBiggerOrEqualValue(start) &
                _db.occurrences.scheduledStart.isSmallerThanValue(end),
          )
          ..orderBy([OrderingTerm(expression: _db.occurrences.scheduledStart)]);

    return combineLatest2(
      directQuery.watch().map(_mapItemWithArea),
      occQuery.watch().map(_mapOccurrenceRows),
      (direct, occurrences) => [...direct, ...occurrences]
        ..sort(
          (a, b) =>
              _compareNullable(a.item.scheduledStart, b.item.scheduledStart),
        ),
    );
  }

  /// Items due (§5 Agenda "Due today" section) on [day], ordered by due
  /// time. Same open-only-status and recurring-template-exclusion rules
  /// as [watchScheduledForDay].
  Stream<List<ItemWithArea>> watchDueForDay(DateTime day) {
    final start = _startOfDay(day);
    final end = start.add(const Duration(days: 1));

    final directQuery =
        _db.select(_db.items).join([
            leftOuterJoin(_db.areas, _db.areas.id.equalsExp(_db.items.areaId)),
          ])
          ..where(
            _isOpenItem(_db.items) &
                _db.items.recurrenceRule.isNull() &
                _db.items.dueAt.isBiggerOrEqualValue(start) &
                _db.items.dueAt.isSmallerThanValue(end),
          )
          ..orderBy([OrderingTerm(expression: _db.items.dueAt)]);

    final occQuery =
        _db.select(_db.occurrences).join([
            innerJoin(
              _db.items,
              _db.items.id.equalsExp(_db.occurrences.itemId),
            ),
            leftOuterJoin(_db.areas, _db.areas.id.equalsExp(_db.items.areaId)),
          ])
          ..where(
            _isOpenItem(_db.items) &
                _notSkipped(_db.occurrences) &
                _db.occurrences.scheduledStart.isNull() &
                _db.occurrences.date.isBiggerOrEqualValue(start) &
                _db.occurrences.date.isSmallerThanValue(end),
          )
          ..orderBy([OrderingTerm(expression: _db.occurrences.date)]);

    return combineLatest2(
      directQuery.watch().map(_mapItemWithArea),
      occQuery.watch().map(_mapOccurrenceRows),
      (direct, occurrences) =>
          [...direct, ...occurrences]
            ..sort((a, b) => _compareNullable(a.item.dueAt, b.item.dueAt)),
    );
  }

  /// The Up Next list (§5/§6): due items from [from] onward, flat and
  /// date-sorted, regardless of area. Screens bucket these into date
  /// groups client-side; this just returns them in order.
  Stream<List<ItemWithArea>> watchUpcoming({required DateTime from}) {
    final start = _startOfDay(from);

    final directQuery =
        _db.select(_db.items).join([
            leftOuterJoin(_db.areas, _db.areas.id.equalsExp(_db.items.areaId)),
          ])
          ..where(
            _isOpenItem(_db.items) &
                _db.items.recurrenceRule.isNull() &
                _db.items.dueAt.isBiggerOrEqualValue(start),
          )
          ..orderBy([OrderingTerm(expression: _db.items.dueAt)]);

    final occQuery =
        _db.select(_db.occurrences).join([
            innerJoin(
              _db.items,
              _db.items.id.equalsExp(_db.occurrences.itemId),
            ),
            leftOuterJoin(_db.areas, _db.areas.id.equalsExp(_db.items.areaId)),
          ])
          ..where(
            _isOpenItem(_db.items) &
                _notSkipped(_db.occurrences) &
                _db.occurrences.scheduledStart.isNull() &
                _db.occurrences.date.isBiggerOrEqualValue(start),
          )
          ..orderBy([OrderingTerm(expression: _db.occurrences.date)]);

    return combineLatest2(
      directQuery.watch().map(_mapItemWithArea),
      occQuery.watch().map(_mapOccurrenceRows),
      (direct, occurrences) =>
          [...direct, ...occurrences]
            ..sort((a, b) => _compareNullable(a.item.dueAt, b.item.dueAt)),
    );
  }

  /// Items with a `scheduledStart` or `dueAt` inside `[start, end)` (§5's
  /// Week/Month views). Open items only, same rule as Agenda — a
  /// completed/cancelled/deleted item moves to Archive instead. Callers
  /// decide how to place/group these; a due-only item has no time slot to
  /// plot on a time grid (§3: `due_at` has "no implied time slot"), so
  /// Week view renders it as a compact all-day pill rather than
  /// fabricating a time for it.
  Stream<List<ItemWithArea>> watchItemsInRange(DateTime start, DateTime end) {
    final directQuery =
        _db.select(_db.items).join([
            leftOuterJoin(_db.areas, _db.areas.id.equalsExp(_db.items.areaId)),
          ])
          ..where(
            _isOpenItem(_db.items) &
                _db.items.recurrenceRule.isNull() &
                ((_db.items.scheduledStart.isBiggerOrEqualValue(start) &
                        _db.items.scheduledStart.isSmallerThanValue(end)) |
                    (_db.items.dueAt.isBiggerOrEqualValue(start) &
                        _db.items.dueAt.isSmallerThanValue(end))),
          )
          ..orderBy([
            OrderingTerm(expression: _db.items.scheduledStart),
            OrderingTerm(expression: _db.items.dueAt),
          ]);

    // A single occurrence-date filter covers both kinds here — `date`
    // always holds the calendar day the instance falls on, whether it's
    // a due-kind or scheduled-kind occurrence (see `_effectiveItemForOccurrence`).
    final occQuery =
        _db.select(_db.occurrences).join([
            innerJoin(
              _db.items,
              _db.items.id.equalsExp(_db.occurrences.itemId),
            ),
            leftOuterJoin(_db.areas, _db.areas.id.equalsExp(_db.items.areaId)),
          ])
          ..where(
            _isOpenItem(_db.items) &
                _notSkipped(_db.occurrences) &
                _db.occurrences.date.isBiggerOrEqualValue(start) &
                _db.occurrences.date.isSmallerThanValue(end),
          )
          ..orderBy([OrderingTerm(expression: _db.occurrences.date)]);

    return combineLatest2(
      directQuery.watch().map(_mapItemWithArea),
      occQuery.watch().map(_mapOccurrenceRows),
      (direct, occurrences) => [...direct, ...occurrences]
        ..sort((a, b) {
          final schedCompare = _compareNullable(
            a.item.scheduledStart,
            b.item.scheduledStart,
          );
          return schedCompare != 0
              ? schedCompare
              : _compareNullable(a.item.dueAt, b.item.dueAt);
        }),
    );
  }

  Expression<bool> _notSkipped($OccurrencesTable occurrences) {
    return occurrences.status.equalsValue(OccurrenceStatus.open) |
        occurrences.status.equalsValue(OccurrenceStatus.done);
  }

  /// Done/cancelled/deleted items move to Archive (§4) instead of
  /// lingering in the active views — every read path that feeds Agenda,
  /// Calendar, widgets, area progress, or search filters to this.
  Expression<bool> _isOpenItem($ItemsTable items) {
    return items.status.equalsValue(ItemStatus.open);
  }

  /// Open or done — used where cancelled/deleted items would otherwise
  /// keep counting toward area-progress payloads forever (they don't
  /// affect the actual done/open-due totals since the accounting logic
  /// checks each status exactly, but excluding them here keeps the
  /// payload from growing with archived history it'll never use).
  Expression<bool> _isActiveOrDone($ItemsTable items) {
    return items.status.equalsValue(ItemStatus.open) |
        items.status.equalsValue(ItemStatus.done);
  }

  List<ItemWithArea> _mapItemWithArea(List<TypedResult> rows) {
    return rows
        .map(
          (row) => ItemWithArea(
            item: row.readTable(_db.items),
            area: row.readTableOrNull(_db.areas),
          ),
        )
        .toList();
  }

  /// Search (§5) across title/notes, plus area/tag/status/date-range
  /// filters (§4). Operates on template items, not per-occurrence — a
  /// recurring item's title/notes only need to match once, not once per
  /// materialized instance. Tag filtering is done as a Dart-side
  /// intersection rather than a SQL join, since a conditional many-to-many
  /// join only when a tag filter is active is more complex than it's
  /// worth here.
  Future<List<ItemWithArea>> searchItems({
    String? query,
    String? areaId,
    String? tagId,
    ItemStatus? status,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    final q = _db.select(_db.items).join([
      leftOuterJoin(_db.areas, _db.areas.id.equalsExp(_db.items.areaId)),
    ]);

    final conditions = <Expression<bool>>[];
    final trimmed = query?.trim() ?? '';
    if (trimmed.isNotEmpty) {
      // Escape LIKE's own wildcard characters in the *user's* text before
      // wrapping it in the search's own %...% pattern — otherwise a
      // search for a literal "%" or "_" (e.g. "50%" or "file_name")
      // silently matches on those as wildcards instead of as the literal
      // characters the user typed.
      final escaped = trimmed
          .replaceAll('\\', '\\\\')
          .replaceAll('%', '\\%')
          .replaceAll('_', '\\_');
      final pattern = '%$escaped%';
      conditions.add(
        _db.items.title.like(pattern, escapeChar: '\\') |
            _db.items.notes.like(pattern, escapeChar: '\\'),
      );
    }
    if (areaId != null) conditions.add(_db.items.areaId.equals(areaId));
    if (status != null) conditions.add(_db.items.status.equalsValue(status));
    if (startDate != null && endDate != null) {
      conditions.add(
        (_db.items.dueAt.isBiggerOrEqualValue(startDate) &
                _db.items.dueAt.isSmallerThanValue(endDate)) |
            (_db.items.scheduledStart.isBiggerOrEqualValue(startDate) &
                _db.items.scheduledStart.isSmallerThanValue(endDate)),
      );
    }
    if (conditions.isNotEmpty) {
      q.where(conditions.reduce((a, b) => a & b));
    }
    q.orderBy([
      OrderingTerm(expression: _db.items.updatedAt, mode: OrderingMode.desc),
    ]);

    var results = _mapItemWithArea(await q.get());

    if (tagId != null) {
      final taggedIds =
          (await (_db.select(
                _db.itemTags,
              )..where((it) => it.tagId.equals(tagId))).get())
              .map((it) => it.itemId)
              .toSet();
      results = results.where((r) => taggedIds.contains(r.item.id)).toList();
    }

    return results;
  }

  List<ItemWithArea> _mapOccurrenceRows(List<TypedResult> rows) =>
      rows.map(_mapOccurrenceRow).toList();

  ItemWithArea _mapOccurrenceRow(TypedResult row) {
    final occurrence = row.readTable(_db.occurrences);
    final template = row.readTable(_db.items);
    final area = row.readTableOrNull(_db.areas);
    return ItemWithArea(
      item: _effectiveItemForOccurrence(template, occurrence),
      area: area,
      occurrenceId: occurrence.id,
    );
  }

  /// Builds the [Item] a screen should render for one [Occurrence] — the
  /// template's title/area/priority/etc. stay as-is, but the date/status
  /// fields are overridden with this specific instance's own values.
  /// Occurrence end-time isn't stored per-row (schema only has
  /// `scheduledStart`); a scheduled-kind occurrence's duration is
  /// inherited from the template's own `scheduledEnd - scheduledStart`
  /// delta rather than duplicating it on every row.
  Item _effectiveItemForOccurrence(Item template, Occurrence occurrence) {
    final done = occurrence.status == OccurrenceStatus.done;
    if (occurrence.scheduledStart != null) {
      final duration =
          (template.scheduledStart != null && template.scheduledEnd != null)
          ? template.scheduledEnd!.difference(template.scheduledStart!)
          : null;
      return template.copyWith(
        dueAt: const Value(null),
        scheduledStart: Value(occurrence.scheduledStart),
        scheduledEnd: Value(
          duration != null ? occurrence.scheduledStart!.add(duration) : null,
        ),
        status: done ? ItemStatus.done : ItemStatus.open,
        completedAt: Value(occurrence.completedAt),
      );
    }
    final dueTime = template.dueAt ?? DateTime(0, 1, 1, 23, 59);
    return template.copyWith(
      scheduledStart: const Value(null),
      scheduledEnd: const Value(null),
      dueAt: Value(
        DateTime(
          occurrence.date.year,
          occurrence.date.month,
          occurrence.date.day,
          dueTime.hour,
          dueTime.minute,
        ),
      ),
      status: done ? ItemStatus.done : ItemStatus.open,
      completedAt: Value(occurrence.completedAt),
    );
  }

  /// §6's progress formula per active area, for the calendar week
  /// containing [now] (defaults to today). [firstWeekday] is
  /// `DateTime.monday` (default) or `DateTime.sunday` (§11, first day of
  /// week) — the caller resolves the actual Settings value; this stays
  /// decoupled from `SettingsRepository` since it's already a `Stream`-
  /// returning method with no natural point to re-read an async setting
  /// mid-stream. One joined watch query — reacts to any item/area write,
  /// no separate stream combination needed.
  Stream<List<AreaProgress>> watchAreaProgress({
    DateTime? now,
    int firstWeekday = DateTime.monday,
  }) {
    final weekStart = startOfWeek(now ?? DateTime.now(), firstWeekday);
    final weekEnd = weekStart.add(const Duration(days: 7));

    // Recurring templates excluded from the join itself (not a WHERE
    // clause — this is a LEFT JOIN, so filtering in the ON condition
    // keeps an area with *only* recurring items still producing a row,
    // just with a null item; a WHERE filter would silently turn that
    // into an inner join and drop the area's zero-activity row entirely).
    final directQuery =
        _db.select(_db.areas).join([
            leftOuterJoin(
              _db.items,
              _db.items.areaId.equalsExp(_db.areas.id) &
                  _db.items.recurrenceRule.isNull() &
                  _isActiveOrDone(_db.items),
            ),
          ])
          ..where(_db.areas.archived.equals(false))
          ..orderBy([OrderingTerm(expression: _db.areas.sortOrder)]);

    final occQuery = _db.select(_db.occurrences).join([
      innerJoin(_db.items, _db.items.id.equalsExp(_db.occurrences.itemId)),
    ])..where(_db.items.areaId.isNotNull() & _isActiveOrDone(_db.items));

    return combineLatest2(directQuery.watch(), occQuery.watch(), (
      areaRows,
      occRows,
    ) {
      final order = <String>[];
      final areasById = <String, Area>{};
      final doneCounts = <String, int>{};
      final openDueCounts = <String, int>{};

      void account(Area area, Item item) {
        final completedAt = item.completedAt;
        if (item.status == ItemStatus.done &&
            completedAt != null &&
            !completedAt.isBefore(weekStart) &&
            completedAt.isBefore(weekEnd)) {
          doneCounts[area.id] = doneCounts[area.id]! + 1;
        }
        final dueAt = item.dueAt;
        if (item.status == ItemStatus.open &&
            dueAt != null &&
            !dueAt.isBefore(weekStart) &&
            dueAt.isBefore(weekEnd)) {
          openDueCounts[area.id] = openDueCounts[area.id]! + 1;
        }
      }

      for (final row in areaRows) {
        final area = row.readTable(_db.areas);
        if (!areasById.containsKey(area.id)) {
          areasById[area.id] = area;
          doneCounts[area.id] = 0;
          openDueCounts[area.id] = 0;
          order.add(area.id);
        }
        final item = row.readTableOrNull(_db.items);
        if (item != null) account(area, item);
      }

      for (final row in occRows) {
        final template = row.readTable(_db.items);
        final area = areasById[template.areaId];
        // Null only if the template's area is archived (so it never
        // appeared in areaRows above) — matches the direct-item path,
        // which only ever surfaces active areas.
        if (area == null) continue;
        account(
          area,
          _effectiveItemForOccurrence(template, row.readTable(_db.occurrences)),
        );
      }

      return order
          .map(
            (id) => AreaProgress(
              area: areasById[id]!,
              doneThisWeek: doneCounts[id]!,
              openDueThisWeek: openDueCounts[id]!,
            ),
          )
          .toList();
    });
  }

  Future<Item> create({
    String? areaId,
    String? parentId,
    required String title,
    String? shortTitle,
    String? notes,
    ItemPriority? priority,
    DateTime? dueAt,
    DateTime? scheduledStart,
    DateTime? scheduledEnd,
    int? estimateMinutes,
    String? recurrenceRule,
    int reminderOffsetMinutes = 60,
    List<String> tags = const [],
    DateTime? now,
  }) async {
    final effectiveNow = now ?? DateTime.now();
    final id = _uuid.v4();
    final cappedTitle = capLength(title, TextLimits.itemTitle);
    final cappedShortTitle = shortTitle == null
        ? null
        : capLength(shortTitle, TextLimits.itemShortTitle);
    final cappedNotes = notes == null
        ? null
        : capLength(notes, TextLimits.itemNotes);
    late Item inserted;
    late _WidgetPayloads payloads;
    await _db.transaction(() async {
      await _db
          .into(_db.items)
          .insert(
            ItemsCompanion.insert(
              id: id,
              areaId: Value(areaId),
              parentId: Value(parentId),
              title: cappedTitle,
              shortTitle: Value(cappedShortTitle),
              notes: Value(cappedNotes),
              status: ItemStatus.open,
              priority: Value(priority),
              dueAt: Value(dueAt),
              scheduledStart: Value(scheduledStart),
              scheduledEnd: Value(scheduledEnd),
              estimateMinutes: Value(estimateMinutes),
              recurrenceRule: Value(recurrenceRule),
              reminderOffsetMinutes: Value(reminderOffsetMinutes),
              createdAt: effectiveNow,
              updatedAt: effectiveNow,
            ),
          );
      inserted = await (_db.select(
        _db.items,
      )..where((i) => i.id.equals(id))).getSingle();
      await _expandOccurrencesForItem(inserted, now: effectiveNow);
      if (tags.isNotEmpty) await _tags.setTagsForItem(id, tags);
      payloads = await _refreshWidgetCaches();
    });
    await _notifyWidgets(payloads);
    await _notifications.scheduleForItem(inserted);
    await _rescheduleOccurrenceReminder(inserted);
    return inserted;
  }

  static const _recurrenceExpander = RecurrenceExpander();
  static const _recurrenceHorizonDays = 60;

  /// Materializes [Occurrence] rows (§3, "~60 days ahead") for [item] if
  /// it has a `recurrenceRule`. Re-derives the full pattern from the
  /// item's own anchor date every time (never from "the last materialized
  /// date + 1") so a `FREQ=WEEKLY` item stays locked to its original
  /// weekday even after repeated horizon top-ups — then only inserts
  /// dates past whatever's already there, making this safe to call
  /// repeatedly (used by both [create] and [extendRecurrenceHorizons]).
  Future<void> _expandOccurrencesForItem(Item item, {DateTime? now}) async {
    final rule = item.recurrenceRule;
    final anchor = item.scheduledStart ?? item.dueAt;
    if (rule == null || anchor == null) return;

    final horizonEnd = (now ?? DateTime.now()).add(
      const Duration(days: _recurrenceHorizonDays),
    );
    final existing = await (_db.select(
      _db.occurrences,
    )..where((o) => o.itemId.equals(item.id))).get();
    final maxExisting = existing.isEmpty
        ? null
        : existing.map((o) => o.date).reduce((a, b) => a.isAfter(b) ? a : b);

    final dates = _recurrenceExpander
        .expand(rule: rule, anchor: anchor, horizonEnd: horizonEnd)
        .where((d) => maxExisting == null || d.isAfter(maxExisting));

    for (final date in dates) {
      await _db
          .into(_db.occurrences)
          .insert(
            OccurrencesCompanion.insert(
              id: _uuid.v4(),
              itemId: item.id,
              date: date,
              scheduledStart: Value(
                item.scheduledStart != null
                    ? DateTime(
                        date.year,
                        date.month,
                        date.day,
                        item.scheduledStart!.hour,
                        item.scheduledStart!.minute,
                      )
                    : null,
              ),
              status: OccurrenceStatus.open,
            ),
          );
    }
  }

  /// Extends every recurring item's materialized occurrences so at least
  /// [_recurrenceHorizonDays] days ahead of [now] are covered. Called once
  /// on app open (see `CoveApp`) rather than via a `workmanager`
  /// background job — occurrences only matter for whatever date range is
  /// currently on screen, and the app has to be open to see it anyway, so
  /// a background job would add isolate complexity for no benefit here.
  Future<void> extendRecurrenceHorizons({DateTime? now}) async {
    final recurringItems = await (_db.select(
      _db.items,
    )..where((i) => i.recurrenceRule.isNotNull())).get();
    for (final item in recurringItems) {
      await _expandOccurrencesForItem(item, now: now);
      await _rescheduleOccurrenceReminder(item);
    }
  }

  /// Recurring items' reminders live on the *occurrence*, not the item
  /// template (§7/§3) — only ever one active at a time per item, the
  /// soonest still-open, not-yet-passed materialized instance. Called
  /// after occurrences are (re)materialized and after an occurrence's
  /// completion state changes, so the reminder always tracks whichever
  /// instance is actually next. No-ops for non-recurring items.
  Future<void> _rescheduleOccurrenceReminder(Item item) async {
    if (item.recurrenceRule == null) return;
    final now = DateTime.now();
    final candidates =
        await (_db.select(_db.occurrences)
              ..where(
                (o) =>
                    o.itemId.equals(item.id) &
                    o.status.equalsValue(OccurrenceStatus.open),
              )
              ..orderBy([(o) => OrderingTerm(expression: o.date)]))
            .get();
    for (final occurrence in candidates) {
      final anchor = occurrence.scheduledStart ?? occurrence.date;
      if (anchor.isAfter(now)) {
        await _notifications.scheduleForOccurrence(item, occurrence);
        return;
      }
    }
  }

  /// Parses [text] with [parser] and resolves its `@area` token against
  /// [areas] (case-insensitive). Parsed `#tag` tokens are persisted via
  /// [TagRepository.setTagsForItem] (§4, "Tags, search, filters").
  ///
  /// The quick-add sheet UI doesn't call this directly — once it has its
  /// own tap-driven date/time/recurrence pickers, those are authoritative
  /// over anything typed, so the sheet calls [create] with its own picker
  /// state instead. This stays as the tested, spec-faithful text-only path
  /// (§4's ten worked examples), in case a non-interactive capture surface
  /// wants it later.
  Future<Item> createFromQuickAdd(
    String text, {
    required QuickAddParser parser,
    required List<Area> areas,
  }) async {
    final result = parser.parse(
      text,
      now: DateTime.now(),
      areaNames: areas.map((a) => a.name).toList(),
    );

    Area? matchedArea;
    if (result.areaName != null) {
      for (final a in areas) {
        if (a.name.toLowerCase() == result.areaName!.toLowerCase()) {
          matchedArea = a;
          break;
        }
      }
    }

    return create(
      areaId: matchedArea?.id,
      title: result.title,
      priority: result.priority,
      dueAt: result.dueAt,
      scheduledStart: result.scheduledStart,
      scheduledEnd: result.scheduledEnd,
      recurrenceRule: result.recurrenceRule,
      tags: result.tags,
    );
  }

  /// [tags], if provided, replaces the item's full tag set (via
  /// [TagRepository.setTagsForItem]) — pass `null` to leave tags
  /// untouched, not to clear them.
  ///
  /// If [changes] touches `recurrenceRule`, `dueAt`, `scheduledStart`, or
  /// `scheduledEnd`, future (not-yet-passed) `Occurrence` rows are
  /// deleted and regenerated under the item's new anchor/rule —
  /// past/completed occurrences are left untouched, preserving history.
  /// Editing an item with no recurrence and none added is unaffected.
  Future<void> update(
    String id,
    ItemsCompanion changes, {
    List<String>? tags,
    DateTime? now,
  }) async {
    final effectiveNow = now ?? DateTime.now();
    final cappedChanges = changes.copyWith(
      title: changes.title.present
          ? Value(capLength(changes.title.value, TextLimits.itemTitle))
          : changes.title,
      shortTitle: changes.shortTitle.present && changes.shortTitle.value != null
          ? Value(
              capLength(changes.shortTitle.value!, TextLimits.itemShortTitle),
            )
          : changes.shortTitle,
      notes: changes.notes.present && changes.notes.value != null
          ? Value(capLength(changes.notes.value!, TextLimits.itemNotes))
          : changes.notes,
    );
    late Item updated;
    late _WidgetPayloads payloads;
    await _db.transaction(() async {
      await (_db.update(_db.items)..where((i) => i.id.equals(id))).write(
        cappedChanges.copyWith(updatedAt: Value(effectiveNow)),
      );
      updated = await (_db.select(
        _db.items,
      )..where((i) => i.id.equals(id))).getSingle();

      if (changes.recurrenceRule.present ||
          changes.dueAt.present ||
          changes.scheduledStart.present ||
          changes.scheduledEnd.present) {
        await _regenerateFutureOccurrences(updated, now: effectiveNow);
      }
      if (tags != null) await _tags.setTagsForItem(id, tags);

      payloads = await _refreshWidgetCaches();
    });
    await _notifyWidgets(payloads);
    await _notifications.scheduleForItem(updated);
    // Unconditional, not just inside the regenerate branch above — editing
    // only `reminderOffsetMinutes` on a recurring item (no date/rule
    // change) still needs its occurrence-level reminder rescheduled with
    // the new offset, and this is cheap/safe to re-run either way.
    await _rescheduleOccurrenceReminder(updated);
  }

  Future<void> _regenerateFutureOccurrences(Item item, {DateTime? now}) async {
    await _removeFutureOccurrences(item.id, now: now);
    if (item.recurrenceRule != null) {
      await _expandOccurrencesForItem(item, now: now);
    }
  }

  /// Deletes future (not-yet-passed) `Occurrence` rows for [itemId] without
  /// regenerating anything — used when a recurring item is archived or
  /// cancelled and shouldn't keep producing new instances while it's not
  /// open, unlike [_regenerateFutureOccurrences] which deletes-then-rebuilds
  /// for a still-open item whose rule/anchor just changed.
  Future<void> _removeFutureOccurrences(String itemId, {DateTime? now}) async {
    final today = _startOfDay(now ?? DateTime.now());
    // Cancel each row's own reminder before deleting it — once gone, its
    // id (and any notification scheduled against it) can't be looked up
    // again, so a live alarm for a deleted occurrence would otherwise
    // linger scheduled at the OS level with nothing left to cancel it.
    final toRemove = await (_db.select(_db.occurrences)..where(
          (o) => o.itemId.equals(itemId) & o.date.isBiggerOrEqualValue(today),
        ))
        .get();
    for (final occurrence in toRemove) {
      await _notifications.cancelForOccurrence(occurrence.id);
    }
    await (_db.delete(_db.occurrences)..where(
          (o) => o.itemId.equals(itemId) & o.date.isBiggerOrEqualValue(today),
        ))
        .go();
  }

  /// Awards XP (§17) on the done transition, reverses it on the reopen
  /// transition — `toggleComplete` is a literal toggle, not a one-way
  /// "complete" action, so un-completing an item has to undo the exact
  /// XP that specific completion granted, not just skip granting more.
  Future<void> toggleComplete(String id) async {
    late Item updated;
    late _WidgetPayloads payloads;
    late bool nowDone;
    await _db.transaction(() async {
      final item = await (_db.select(
        _db.items,
      )..where((i) => i.id.equals(id))).getSingle();
      nowDone = item.status != ItemStatus.done;
      final now = DateTime.now();
      await (_db.update(_db.items)..where((i) => i.id.equals(id))).write(
        ItemsCompanion(
          status: Value(nowDone ? ItemStatus.done : ItemStatus.open),
          completedAt: Value(nowDone ? now : null),
          // Archive (§4): done moves it out of the active views into
          // Archive; reopening clears archivedAt and brings it back.
          archivedAt: Value(nowDone ? now : null),
          updatedAt: Value(now),
        ),
      );
      updated = await (_db.select(
        _db.items,
      )..where((i) => i.id.equals(id))).getSingle();
      payloads = await _refreshWidgetCaches();
    });
    await _notifyWidgets(payloads);
    await _notifications.scheduleForItem(updated);
    if (nowDone) {
      await _xp.awardForCompletion(id);
    } else {
      await _xp.reverseForItem(id);
    }
  }

  /// Marks [id] cancelled (§4, Archive) — moves it out of the active
  /// views into Archive, same as completing, but distinct from "done". A
  /// recurring item's future occurrences stop being generated (past/
  /// completed ones are kept, same rule as archiving).
  Future<void> cancelItem(String id) async {
    late _WidgetPayloads payloads;
    await _db.transaction(() async {
      final now = DateTime.now();
      await (_db.update(_db.items)..where((i) => i.id.equals(id))).write(
        ItemsCompanion(
          status: const Value(ItemStatus.cancelled),
          archivedAt: Value(now),
          updatedAt: Value(now),
        ),
      );
      await _removeFutureOccurrences(id, now: now);
      payloads = await _refreshWidgetCaches();
    });
    await _notifyWidgets(payloads);
    await _notifications.cancelForItem(id);
  }

  /// Soft delete (§4, Archive) — what the UI's "delete" action actually
  /// calls now. The row and its occurrence history stay; only [restore]
  /// or [permanentlyDelete] (Archive-only) undo or finalize it.
  Future<void> archiveItem(String id) async {
    late _WidgetPayloads payloads;
    await _db.transaction(() async {
      final now = DateTime.now();
      await (_db.update(_db.items)..where((i) => i.id.equals(id))).write(
        ItemsCompanion(
          status: const Value(ItemStatus.deleted),
          archivedAt: Value(now),
          updatedAt: Value(now),
        ),
      );
      await _removeFutureOccurrences(id, now: now);
      payloads = await _refreshWidgetCaches();
    });
    await _notifyWidgets(payloads);
    await _notifications.cancelForItem(id);
  }

  /// Brings an archived item (done/cancelled/deleted) back to `open` —
  /// reachable only from the Archive screen. A recurring item resumes
  /// generating future occurrences from wherever its history left off.
  Future<void> restoreItem(String id) async {
    late Item restored;
    late _WidgetPayloads payloads;
    await _db.transaction(() async {
      final now = DateTime.now();
      await (_db.update(_db.items)..where((i) => i.id.equals(id))).write(
        ItemsCompanion(
          status: const Value(ItemStatus.open),
          completedAt: const Value(null),
          archivedAt: const Value(null),
          updatedAt: Value(now),
        ),
      );
      restored = await (_db.select(
        _db.items,
      )..where((i) => i.id.equals(id))).getSingle();
      if (restored.recurrenceRule != null) {
        await _expandOccurrencesForItem(restored, now: now);
      }
      payloads = await _refreshWidgetCaches();
    });
    await _notifyWidgets(payloads);
    await _notifications.scheduleForItem(restored);
    await _rescheduleOccurrenceReminder(restored);
  }

  /// Bulk actions (§4, multi-select) — each just loops the existing
  /// single-item method rather than duplicating its transaction/cascade
  /// logic. N transactions instead of one is a real inefficiency, but at
  /// the scale a person bulk-selecting their own tasks actually hits (a
  /// handful of rows, not thousands), reusing already-correct logic beats
  /// a parallel batched implementation that could drift out of sync with
  /// it. Occurrence-backed rows route to [toggleOccurrenceComplete], same
  /// distinction as the single-item toggle.
  Future<void> bulkComplete(List<ItemWithArea> items) async {
    for (final iwa in items) {
      if (iwa.occurrenceId != null) {
        await toggleOccurrenceComplete(iwa.occurrenceId!);
      } else {
        await toggleComplete(iwa.item.id);
      }
    }
  }

  Future<void> bulkArchive(List<ItemWithArea> items) async {
    for (final iwa in items) {
      await archiveItem(iwa.item.id);
    }
  }

  Future<void> bulkMoveArea(List<String> itemIds, String? areaId) async {
    for (final id in itemIds) {
      await update(id, ItemsCompanion(areaId: Value(areaId)));
    }
  }

  /// Persists a drag-reorder (§4, Manual sort) — writes sequential
  /// `sortOrder` values for [orderedIds] in the given order. An
  /// occurrence-backed row reorders its template `Item`, same as every
  /// other occurrence-routed mutation.
  Future<void> reorderItems(List<String> orderedIds) async {
    await _db.transaction(() async {
      for (var i = 0; i < orderedIds.length; i++) {
        await (_db.update(_db.items)
              ..where((it) => it.id.equals(orderedIds[i])))
            .write(ItemsCompanion(sortOrder: Value(i)));
      }
    });
  }

  /// Toggles one materialized instance of a recurring item, not the
  /// template — sibling occurrences and the template `Item` row are
  /// untouched. Cancels this occurrence's own reminder (a no-op if it
  /// never had one live) and reschedules onto whichever occurrence is now
  /// the soonest still-open one — covers both directions: completing the
  /// occurrence that currently holds the reminder advances it to the next
  /// one, and un-completing an earlier occurrence can bring the reminder
  /// back to it.
  Future<void> toggleOccurrenceComplete(String occurrenceId) async {
    late _WidgetPayloads payloads;
    late Item item;
    late bool nowDone;
    await _db.transaction(() async {
      final occurrence = await (_db.select(
        _db.occurrences,
      )..where((o) => o.id.equals(occurrenceId))).getSingle();
      nowDone = occurrence.status != OccurrenceStatus.done;
      await (_db.update(
        _db.occurrences,
      )..where((o) => o.id.equals(occurrenceId))).write(
        OccurrencesCompanion(
          status: Value(
            nowDone ? OccurrenceStatus.done : OccurrenceStatus.open,
          ),
          completedAt: Value(nowDone ? DateTime.now() : null),
        ),
      );
      item = await (_db.select(
        _db.items,
      )..where((i) => i.id.equals(occurrence.itemId))).getSingle();
      payloads = await _refreshWidgetCaches();
    });
    await _notifyWidgets(payloads);
    await _notifications.cancelForOccurrence(occurrenceId);
    await _rescheduleOccurrenceReminder(item);
    // §17: "recurring items award XP per completed Occurrence, same
    // formula" — logged under the template's item_id (XpLog's own
    // schema, per §17, has no occurrence_id column), same daily cap
    // shared across every item/occurrence in the app.
    if (nowDone) {
      await _xp.awardForCompletion(item.id);
    } else {
      await _xp.reverseForItem(item.id);
    }
  }

  /// The real, unrecoverable row removal — reachable only from within the
  /// Archive screen's "Delete permanently" action. Everywhere else in the
  /// app, "delete" means [archiveItem] (soft, restorable).
  Future<void> permanentlyDelete(String id) async {
    late _WidgetPayloads payloads;
    await _db.transaction(() async {
      // Occurrences first — deleting the template while its occurrences
      // still reference it risks a foreign-key violation depending on
      // how strictly SQLite enforces it in this build.
      await (_db.delete(
        _db.occurrences,
      )..where((o) => o.itemId.equals(id))).go();
      await (_db.delete(_db.items)..where((i) => i.id.equals(id))).go();
      payloads = await _refreshWidgetCaches();
    });
    await _notifyWidgets(payloads);
    await _notifications.cancelForItem(id);
  }

  /// Records that [id] was pushed to Google Calendar as [eventId] (§9,
  /// export). A narrow single-column setter, not a Calendar-aware method —
  /// keeps this repository ignorant of Google entirely; `CalendarSyncRepository`
  /// (or its caller) is what decides an item should be exported and calls
  /// this afterward, same "isolated, deletable without touching item
  /// logic" boundary the read path already keeps.
  Future<void> setExternalCalendarEventId(String id, String eventId) {
    return (_db.update(_db.items)..where((i) => i.id.equals(id))).write(
      ItemsCompanion(externalCalendarEventId: Value(eventId)),
    );
  }

  Future<void> _upsertWidgetCache(String widgetName, String payloadJson) {
    return _db
        .into(_db.widgetCaches)
        .insertOnConflictUpdate(
          WidgetCachesCompanion.insert(
            widgetName: widgetName,
            payloadJson: payloadJson,
            updatedAt: DateTime.now(),
          ),
        );
  }

  /// Recomputes and pushes all three widget-cache payloads — for a bulk
  /// write that bypasses the normal create/update/toggle methods (JSON
  /// import's full-table replace, `clearAllData`), so the home-screen
  /// widgets don't keep showing stale data until some unrelated item
  /// write happens to trigger a refresh.
  Future<void> refreshWidgetCaches() async {
    await _notifyWidgets(await _refreshWidgetCaches());
  }

  /// Recomputes all three widget-cache rows in one go (§6). Returns each
  /// serialized payload so the caller can push the exact same JSON to the
  /// native widgets' storage after the transaction commits.
  Future<_WidgetPayloads> _refreshWidgetCaches() async {
    return (
      upNext: await _refreshUpNextCache(),
      agenda: await _refreshAgendaCache(),
      areas: await _refreshAreasCache(),
    );
  }

  /// Up Next (§6): open items with a due date, sorted ascending. Recurring
  /// templates are excluded in favor of their materialized due-kind
  /// `Occurrence` rows, same rule as the in-app read paths.
  Future<String> _refreshUpNextCache() async {
    final directQuery =
        _db.select(_db.items).join([
          leftOuterJoin(_db.areas, _db.areas.id.equalsExp(_db.items.areaId)),
        ])..where(
          _db.items.status.equalsValue(ItemStatus.open) &
              _db.items.dueAt.isNotNull() &
              _db.items.recurrenceRule.isNull(),
        );
    final direct = await directQuery.get();

    final occQuery =
        _db.select(_db.occurrences).join([
          innerJoin(_db.items, _db.items.id.equalsExp(_db.occurrences.itemId)),
          leftOuterJoin(_db.areas, _db.areas.id.equalsExp(_db.items.areaId)),
        ])..where(
          _isOpenItem(_db.items) &
              _db.occurrences.status.equalsValue(OccurrenceStatus.open) &
              _db.occurrences.scheduledStart.isNull(),
        );
    final occRows = await occQuery.get();

    final entries = [
      ...direct.map(
        (row) => (
          item: row.readTable(_db.items),
          area: row.readTableOrNull(_db.areas),
          occurrenceId: null as String?,
        ),
      ),
      ...occRows.map(
        (row) => (
          item: _effectiveItemForOccurrence(
            row.readTable(_db.items),
            row.readTable(_db.occurrences),
          ),
          area: row.readTableOrNull(_db.areas),
          occurrenceId: row.readTable(_db.occurrences).id,
        ),
      ),
    ]..sort((a, b) => _compareNullable(a.item.dueAt, b.item.dueAt));

    // `occurrenceId` lets the Up Next widget's complete-toggle (§6/§17,
    // UpNextWidgetProvider.kt) call the right repository method —
    // `toggleOccurrenceComplete` for a recurring instance,
    // `toggleComplete` for a direct item — same distinction the in-app
    // rows already make via `ItemWithArea.occurrenceId`.
    final payload = entries.map((e) {
      return {
        'id': e.item.id,
        'occurrenceId': e.occurrenceId,
        'title': e.item.shortTitle ?? e.item.title,
        'area': e.area?.name,
        'areaColor': e.area?.color,
        'dueAt': e.item.dueAt!.toIso8601String(),
      };
    }).toList();
    final payloadJson = jsonEncode(payload);
    await _upsertWidgetCache(_upNextWidgetName, payloadJson);
    return payloadJson;
  }

  /// Agenda (§6): all open items with a schedule and/or due date, raw and
  /// unfiltered by day — the native widget decides what "today" is itself,
  /// using the device's own clock at render time. That's what makes the
  /// midnight rollover work without a `workmanager` background job: the
  /// existing 30-minute heartbeat already re-renders regardless, and each
  /// render re-asks "what's today right now" fresh (see
  /// documents/documentation.md for the full reasoning).
  Future<String> _refreshAgendaCache() async {
    final directQuery =
        _db.select(_db.items).join([
          leftOuterJoin(_db.areas, _db.areas.id.equalsExp(_db.items.areaId)),
        ])..where(
          _db.items.status.equalsValue(ItemStatus.open) &
              (_db.items.scheduledStart.isNotNull() |
                  _db.items.dueAt.isNotNull()) &
              _db.items.recurrenceRule.isNull(),
        );
    final direct = await directQuery.get();

    final occQuery =
        _db.select(_db.occurrences).join([
          innerJoin(_db.items, _db.items.id.equalsExp(_db.occurrences.itemId)),
          leftOuterJoin(_db.areas, _db.areas.id.equalsExp(_db.items.areaId)),
        ])..where(
          _isOpenItem(_db.items) &
              _db.occurrences.status.equalsValue(OccurrenceStatus.open),
        );
    final occRows = await occQuery.get();

    final entries = [
      ...direct.map(
        (row) => (
          item: row.readTable(_db.items),
          area: row.readTableOrNull(_db.areas),
        ),
      ),
      ...occRows.map(
        (row) => (
          item: _effectiveItemForOccurrence(
            row.readTable(_db.items),
            row.readTable(_db.occurrences),
          ),
          area: row.readTableOrNull(_db.areas),
        ),
      ),
    ];

    final payload = entries.map((e) {
      return {
        'id': e.item.id,
        'title': e.item.shortTitle ?? e.item.title,
        'area': e.area?.name,
        'areaColor': e.area?.color,
        'scheduledStart': e.item.scheduledStart?.toIso8601String(),
        'scheduledEnd': e.item.scheduledEnd?.toIso8601String(),
        'dueAt': e.item.dueAt?.toIso8601String(),
      };
    }).toList();
    final payloadJson = jsonEncode(payload);
    await _upsertWidgetCache(_agendaWidgetName, payloadJson);
    return payloadJson;
  }

  /// Areas (§6): raw per-area items (only ones that could ever count
  /// toward the formula — has an area, and has a due date or a completion
  /// date). Same "native decides the week boundary at render time" reasoning
  /// as [_refreshAgendaCache] — the formula itself (§6, written spec, not
  /// the mockup's plain `done/total`) gets reimplemented in Kotlin against
  /// this raw data; see AreasWidgetProvider.kt.
  Future<String> _refreshAreasCache() async {
    final areas =
        await (_db.select(_db.areas)
              ..where((a) => a.archived.equals(false))
              ..orderBy([(a) => OrderingTerm(expression: a.sortOrder)]))
            .get();
    final directItems =
        await (_db.select(_db.items)..where(
              (i) =>
                  i.areaId.isNotNull() &
                  (i.dueAt.isNotNull() | i.completedAt.isNotNull()) &
                  i.recurrenceRule.isNull() &
                  _isActiveOrDone(i),
            ))
            .get();

    final occQuery = _db.select(_db.occurrences).join([
      innerJoin(_db.items, _db.items.id.equalsExp(_db.occurrences.itemId)),
    ])..where(_db.items.areaId.isNotNull() & _isActiveOrDone(_db.items));
    final occItems = (await occQuery.get())
        .map(
          (row) => _effectiveItemForOccurrence(
            row.readTable(_db.items),
            row.readTable(_db.occurrences),
          ),
        )
        .where((item) => item.dueAt != null || item.completedAt != null);

    final items = [...directItems, ...occItems];

    // §17's level badge in the widget's own corner (design handoff: "Level
    // marker sits in the Areas widget corner only — no fifth widget") —
    // the only gamification data that ever reaches native code, since
    // nothing else in the cluster/equip system is meant to show here.
    final level = Gamification.levelForXp(await _xp.totalXp());

    final payload = {
      'level': level,
      'areas': areas
          .map((a) => {'id': a.id, 'name': a.name, 'color': a.color})
          .toList(),
      'items': items
          .map(
            (i) => {
              'areaId': i.areaId,
              'status': i.status.name,
              'dueAt': i.dueAt?.toIso8601String(),
              'completedAt': i.completedAt?.toIso8601String(),
            },
          )
          .toList(),
    };
    final payloadJson = jsonEncode(payload);
    await _upsertWidgetCache(_areasWidgetName, payloadJson);
    return payloadJson;
  }

  /// Pushes each payload into `home_widget`'s own storage (what the native
  /// `AppWidgetProvider`s actually read — the `WidgetCaches` drift rows
  /// above are the in-app record, not themselves readable from Kotlin) and
  /// asks Android to redraw each widget. Best-effort per widget: one
  /// missing/failed platform channel must never block another widget's
  /// update, or the underlying item write that triggered all of this (§12).
  Future<void> _notifyWidgets(_WidgetPayloads payloads) async {
    try {
      await HomeWidget.saveWidgetData(_upNextWidgetDataKey, payloads.upNext);
      await HomeWidget.updateWidget(androidName: _upNextAndroidProvider);
    } catch (_) {
      // No native widget provider exists until step 6 (§6) — a failed or
      // missing platform channel must never block the item write (§12).
    }
    try {
      await HomeWidget.saveWidgetData(_agendaWidgetDataKey, payloads.agenda);
      await HomeWidget.updateWidget(androidName: _agendaAndroidProvider);
    } catch (_) {
      // Same as above.
    }
    try {
      await HomeWidget.saveWidgetData(_areasWidgetDataKey, payloads.areas);
      await HomeWidget.updateWidget(androidName: _areasAndroidProvider);
    } catch (_) {
      // Same as above.
    }
  }
}

typedef _WidgetPayloads = ({String upNext, String agenda, String areas});
