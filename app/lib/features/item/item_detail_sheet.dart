import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/db/database.dart' show Area, Item, ItemsCompanion, Tag;
import '../../data/db/tables.dart' show ItemPriority, ItemStatus;
import '../calendar/calendar_export_trigger.dart';
import 'widgets/date_time_pickers.dart';

DateTime _startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);

/// Full edit view for one item (§5, "Item detail"): title, area, tags,
/// priority, due/schedule, recurrence, notes, subtasks, delete. Presented
/// as a modal bottom sheet when tapping a row in-app; `ItemDeepLinkScreen`
/// (notification/widget-tap route) renders the same content as a full
/// page instead, since a deep-linked cold start has no screen behind it.
///
/// Edits use an explicit Save button, not autosave — closing the sheet
/// without saving discards changes, same as quick-add.
///
/// Returns the saved [Item] if changes were saved, `null` if the sheet
/// was dismissed/archived/deleted instead. Callers that need the §9
/// export trigger should use [showItemDetailSheetAndMaybeExport] instead
/// of calling this directly — the trigger's own SnackBar prompt needs a
/// context that outlives this sheet's, same reasoning as
/// `showQuickAddSheet`.
Future<Item?> showItemDetailSheet(BuildContext context, String itemId) {
  return showModalBottomSheet<Item>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.colors.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(context.s(24))),
    ),
    builder: (context) => ItemDetailSheet(itemId: itemId),
  );
}

/// Opens Item Detail, then — once it's fully closed — runs the §9 export
/// trigger with [context] (the caller's own long-lived screen context,
/// not the sheet's). Use this instead of [showItemDetailSheet] at every
/// call site that has a live [WidgetRef] to hand it.
Future<void> showItemDetailSheetAndMaybeExport(
  BuildContext context,
  WidgetRef ref,
  String itemId,
) async {
  final item = await showItemDetailSheet(context, itemId);
  if (item != null && context.mounted) {
    await maybeExportToCalendar(context, ref, item);
  }
}

class ItemDetailSheet extends ConsumerStatefulWidget {
  const ItemDetailSheet({super.key, required this.itemId});
  final String itemId;

  @override
  ConsumerState<ItemDetailSheet> createState() => _ItemDetailSheetState();
}

class _ItemDetailSheetState extends ConsumerState<ItemDetailSheet> {
  final _titleController = TextEditingController();
  final _notesController = TextEditingController();
  final _tagInputController = TextEditingController();
  final _subtaskInputController = TextEditingController();

  bool _loaded = false;
  bool _notFound = false;
  bool _done = false;
  ItemStatus _status = ItemStatus.open;
  String? _areaId;
  ItemPriority? _priority;
  List<String> _tags = [];

  ItemDateKind _kind = ItemDateKind.due;
  late DateTime _selectedDate;
  bool _calendarOpen = false;
  late DateTime _calendarMonth;
  int _hour = 9;
  int _minute = 0;
  int _endHour = 10;
  int _endMinute = 0;
  bool _noTime = true;
  String _repeat = 'NONE';
  int _reminderOffsetMinutes = 60;

  static const _reminderOffsetOptions = [60, 300, 1440, -1];

  static String _reminderOffsetLabel(int minutes) => switch (minutes) {
    -1 => 'OFF',
    60 => '1 HOUR',
    300 => '5 HOURS',
    1440 => '1 DAY',
    final m => '$m MIN',
  };

  // Google Calendar export (§9) manual toggle — named distinctly from the
  // `_calendar*` fields above (those are the date-picker's own popup, not
  // Google Calendar).
  bool _gcalConnected = false;
  String? _gcalEventId;
  bool _gcalBusy = false;
  bool _hasSavedDate = false;
  String? _timeError;

  @override
  void initState() {
    super.initState();
    _load();
    ref.read(calendarSyncRepositoryProvider).isConnected().then((connected) {
      if (mounted) setState(() => _gcalConnected = connected);
    });
  }

  Future<void> _load() async {
    final repo = ref.read(itemRepositoryProvider);
    final itemWithArea = await repo.getByIdWithArea(widget.itemId);
    if (!mounted) return;
    if (itemWithArea == null) {
      setState(() {
        _loaded = true;
        _notFound = true;
      });
      return;
    }
    final item = itemWithArea.item;
    final tags = await ref
        .read(tagRepositoryProvider)
        .watchTagsForItem(widget.itemId)
        .first;

    final anchor =
        item.scheduledStart ?? item.dueAt ?? _startOfDay(DateTime.now());
    setState(() {
      _titleController.text = item.title;
      _notesController.text = item.notes ?? '';
      _done = item.status == ItemStatus.done;
      _status = item.status;
      _areaId = item.areaId;
      _priority = item.priority;
      _reminderOffsetMinutes = item.reminderOffsetMinutes;
      _tags = tags.map((t) => t.name).toList();

      _selectedDate = _startOfDay(anchor);
      _calendarMonth = DateTime(_selectedDate.year, _selectedDate.month);
      _gcalEventId = item.externalCalendarEventId;
      _hasSavedDate = item.dueAt != null || item.scheduledStart != null;
      if (item.scheduledStart != null) {
        _kind = ItemDateKind.sched;
        _hour = item.scheduledStart!.hour;
        _minute = item.scheduledStart!.minute;
        _endHour = item.scheduledEnd?.hour ?? ((_hour + 1) % 24);
        _endMinute = item.scheduledEnd?.minute ?? _minute;
        _noTime = false;
      } else if (item.dueAt != null) {
        _kind = ItemDateKind.due;
        final isEndOfDay = item.dueAt!.hour == 23 && item.dueAt!.minute == 59;
        _noTime = isEndOfDay;
        _hour = isEndOfDay ? 9 : item.dueAt!.hour;
        _minute = isEndOfDay ? 0 : item.dueAt!.minute;
      } else {
        _kind = ItemDateKind.due;
        _noTime = true;
      }
      if (item.recurrenceRule == 'FREQ=DAILY') {
        _repeat = 'DAILY';
      } else if (item.recurrenceRule?.startsWith(
            'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR',
          ) ==
          true) {
        _repeat = 'WEEKDAYS';
      } else if (item.recurrenceRule?.startsWith('FREQ=WEEKLY') == true) {
        _repeat = 'WEEKLY';
      } else {
        _repeat = 'NONE';
      }
      _loaded = true;
    });
  }

  @override
  void dispose() {
    _titleController.dispose();
    _notesController.dispose();
    _tagInputController.dispose();
    _subtaskInputController.dispose();
    super.dispose();
  }

  String? _recurrenceRule() {
    switch (_repeat) {
      case 'DAILY':
        return 'FREQ=DAILY';
      case 'WEEKLY':
        return 'FREQ=WEEKLY';
      case 'WEEKDAYS':
        return 'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR';
      default:
        return null;
    }
  }

  Future<void> _toggleDone() async {
    await ref.read(itemRepositoryProvider).toggleComplete(widget.itemId);
    if (mounted) setState(() => _done = !_done);
  }

  /// Manual "Add to Google Calendar" (§9) — the retroactive/offline
  /// catch-up path that works regardless of export mode, including
  /// `askEachTime` (which never prompts again once the save-time moment
  /// has passed). One-way: once exported, this becomes a static
  /// confirmation, no un-export.
  Future<void> _addToGoogleCalendar() async {
    final itemWithArea = await ref
        .read(itemRepositoryProvider)
        .getByIdWithArea(widget.itemId);
    final item = itemWithArea?.item;
    final date = item?.scheduledStart ?? item?.dueAt;
    if (item == null || date == null) return;
    setState(() => _gcalBusy = true);
    await exportItemNow(ref, item, date);
    if (!mounted) return;
    final refreshed = await ref
        .read(itemRepositoryProvider)
        .getByIdWithArea(widget.itemId);
    setState(() {
      _gcalBusy = false;
      _gcalEventId = refreshed?.item.externalCalendarEventId;
    });
  }

  Future<void> _save() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) return;

    final now = DateTime.now();
    // Floored to the minute so picking exactly "now" isn't rejected just
    // because a few seconds elapse before Save is actually tapped.
    final nowFloor = DateTime(
      now.year,
      now.month,
      now.day,
      now.hour,
      now.minute,
    );

    DateTime? dueAt;
    DateTime? scheduledStart;
    DateTime? scheduledEnd;
    if (_kind == ItemDateKind.due) {
      dueAt = _noTime
          ? _selectedDate.add(const Duration(hours: 23, minutes: 59))
          : _selectedDate.add(Duration(hours: _hour, minutes: _minute));
      if (dueAt.isBefore(nowFloor)) {
        setState(() => _timeError = 'Due time must be in the future.');
        return;
      }
    } else {
      scheduledStart = _selectedDate.add(
        Duration(hours: _hour, minutes: _minute),
      );
      scheduledEnd = _selectedDate.add(
        Duration(hours: _endHour, minutes: _endMinute),
      );
      if (scheduledStart.isBefore(nowFloor)) {
        setState(() => _timeError = 'Start time must be in the future.');
        return;
      }
      if (!scheduledEnd.isAfter(scheduledStart)) {
        setState(() => _timeError = 'End time must be after start time.');
        return;
      }
    }
    if (_timeError != null) setState(() => _timeError = null);

    await ref
        .read(itemRepositoryProvider)
        .update(
          widget.itemId,
          ItemsCompanion(
            title: Value(title),
            notes: Value(
              _notesController.text.trim().isEmpty
                  ? null
                  : _notesController.text.trim(),
            ),
            areaId: Value(_areaId),
            priority: Value(_priority),
            dueAt: Value(dueAt),
            scheduledStart: Value(scheduledStart),
            scheduledEnd: Value(scheduledEnd),
            recurrenceRule: Value(_recurrenceRule()),
            reminderOffsetMinutes: Value(_reminderOffsetMinutes),
          ),
          tags: _tags,
        );
    if (!mounted) return;
    // Fetch the fresh row rather than having `update()` return one —
    // `update()` has no other caller, but re-reading keeps its existing
    // `Future<void>` contract intact instead of changing it just for this.
    // Popped as the sheet's result (not used to trigger the export here
    // directly) so the §9 trigger runs with the caller's long-lived
    // context once this sheet's own context is gone — see
    // `showItemDetailSheetAndMaybeExport`.
    final saved = await ref
        .read(itemRepositoryProvider)
        .getByIdWithArea(widget.itemId);
    if (mounted) Navigator.of(context).pop(saved?.item);
  }

  /// Moves the item to Archive (§4) — a soft delete, not the permanent
  /// kind. "Delete" is the label the user sees; only the Archive screen's
  /// own "Delete permanently" action is unrecoverable.
  Future<void> _archive() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: context.colors.surface,
        title: const Text('Delete this item?'),
        content: const Text(
          'It moves to Archive — you can restore it from there later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              'Delete',
              style: TextStyle(color: context.colors.accent),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref.read(itemRepositoryProvider).archiveItem(widget.itemId);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _cancelItem() async {
    await ref.read(itemRepositoryProvider).cancelItem(widget.itemId);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _restore() async {
    await ref.read(itemRepositoryProvider).restoreItem(widget.itemId);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _permanentlyDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: context.colors.surface,
        title: const Text('Delete permanently?'),
        content: const Text(
          'This removes it for good — it can\'t be restored after this.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              'Delete permanently',
              style: TextStyle(color: context.colors.accent),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref.read(itemRepositoryProvider).permanentlyDelete(widget.itemId);
    if (mounted) Navigator.of(context).pop();
  }

  void _addTag() {
    final value = _tagInputController.text.trim();
    if (value.isEmpty ||
        _tags.any((t) => t.toLowerCase() == value.toLowerCase())) {
      _tagInputController.clear();
      return;
    }
    setState(() {
      _tags = [..._tags, value];
      _tagInputController.clear();
    });
  }

  Future<void> _addSubtask() async {
    final title = _subtaskInputController.text.trim();
    if (title.isEmpty) return;
    _subtaskInputController.clear();
    await ref
        .read(itemRepositoryProvider)
        .create(title: title, parentId: widget.itemId, areaId: _areaId);
  }

  @override
  Widget build(BuildContext context) {
    if (_loaded && _notFound) {
      return SizedBox(
        height: context.s(200),
        child: Center(
          child: Text('Item not found', style: AppTypography.body(context)),
        ),
      );
    }
    if (!_loaded) {
      return SizedBox(
        height: context.s(200),
        child: const Center(child: CircularProgressIndicator()),
      );
    }
    final areas = ref.watch(activeAreasProvider).value ?? const <Area>[];
    final allTags = ref.watch(allTagsProvider).value ?? const <Tag>[];
    final subtasks =
        ref.watch(subtasksProvider(widget.itemId)).value ?? const <Item>[];

    return Padding(
      padding: EdgeInsets.only(
        left: context.s(16),
        right: context.s(16),
        top: context.s(12),
        bottom:
            MediaQuery.of(context).viewInsets.bottom +
            MediaQuery.of(context).padding.bottom +
            context.s(18),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.9,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: context.s(36),
                height: context.s(4),
                margin: EdgeInsets.only(bottom: context.s(14)),
                decoration: BoxDecoration(
                  color: context.colors.border,
                  borderRadius: BorderRadius.circular(context.s(2)),
                ),
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        GestureDetector(
                          // Archived items (cancelled/deleted) don't get the
                          // complete toggle — toggleComplete() only knows
                          // done/open, so tapping this on an archived item
                          // could silently flip it back to open (undoing the
                          // archive) instead of going through Restore.
                          onTap: _status == ItemStatus.open
                              ? _toggleDone
                              : null,
                          child: Container(
                            width: context.s(26),
                            height: context.s(26),
                            margin: EdgeInsets.only(top: context.s(4)),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _done
                                  ? context.colors.ink
                                  : Colors.transparent,
                              border: Border.all(
                                color: _done
                                    ? context.colors.ink
                                    : context.colors.inkDisabled,
                                width: 1.5,
                              ),
                            ),
                            alignment: Alignment.center,
                            child: _done
                                ? Icon(
                                    Icons.check,
                                    size: context.s(14),
                                    color: context.colors.surface,
                                  )
                                : null,
                          ),
                        ),
                        SizedBox(width: context.s(10)),
                        Expanded(
                          child: TextField(
                            controller: _titleController,
                            maxLines: null,
                            style: TextStyle(
                              fontFamily: AppTypography.sansFamily,
                              fontSize: context.s(18),
                              fontWeight: FontWeight.w600,
                              color: context.colors.ink,
                              decoration: _done
                                  ? TextDecoration.lineThrough
                                  : TextDecoration.none,
                            ),
                            decoration: const InputDecoration(
                              border: InputBorder.none,
                              isDense: true,
                            ),
                          ),
                        ),
                        if (_status == ItemStatus.open)
                          PopupMenuButton<String>(
                            color: context.colors.surface,
                            onSelected: (value) {
                              if (value == 'cancel') _cancelItem();
                              if (value == 'delete') _archive();
                            },
                            itemBuilder: (context) => const [
                              PopupMenuItem(
                                value: 'cancel',
                                child: Text('Cancel item'),
                              ),
                              PopupMenuItem(
                                value: 'delete',
                                child: Text('Delete'),
                              ),
                            ],
                            child: Padding(
                              padding: EdgeInsets.only(
                                left: context.s(8),
                                top: context.s(4),
                              ),
                              child: Icon(
                                Icons.more_vert,
                                size: context.s(20),
                                color: context.colors.inkFaint,
                              ),
                            ),
                          ),
                      ],
                    ),
                    SizedBox(height: context.s(16)),
                    Text(
                      'AREA',
                      style: AppTypography.monoLabel(
                        context,
                      ).copyWith(letterSpacing: context.s(1.4)),
                    ),
                    SizedBox(height: context.s(6)),
                    Wrap(
                      spacing: context.s(6),
                      runSpacing: context.s(6),
                      children: [
                        _SelectableChip(
                          label: 'None',
                          selected: _areaId == null,
                          onTap: () => setState(() => _areaId = null),
                        ),
                        for (final area in areas)
                          _SelectableChip(
                            label: area.name,
                            color: colorFromHex(area.color),
                            selected: _areaId == area.id,
                            onTap: () => setState(() => _areaId = area.id),
                          ),
                      ],
                    ),
                    SizedBox(height: context.s(16)),
                    Text(
                      'TAGS',
                      style: AppTypography.monoLabel(
                        context,
                      ).copyWith(letterSpacing: context.s(1.4)),
                    ),
                    SizedBox(height: context.s(6)),
                    Wrap(
                      spacing: context.s(6),
                      runSpacing: context.s(6),
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        for (final tag in _tags)
                          _RemovableChip(
                            label: tag,
                            onRemove: () => setState(
                              () =>
                                  _tags = _tags.where((t) => t != tag).toList(),
                            ),
                          ),
                        SizedBox(
                          width: context.s(120),
                          child: TextField(
                            controller: _tagInputController,
                            style: TextStyle(
                              fontFamily: AppTypography.monoFamily,
                              fontSize: context.s(12),
                              color: context.colors.ink,
                            ),
                            decoration: InputDecoration(
                              isDense: true,
                              hintText: '+ add tag',
                              hintStyle: TextStyle(
                                color: context.colors.inkDisabled,
                                fontFamily: AppTypography.monoFamily,
                                fontSize: context.s(12),
                              ),
                              border: InputBorder.none,
                            ),
                            onSubmitted: (_) => _addTag(),
                          ),
                        ),
                      ],
                    ),
                    if (allTags.isNotEmpty) ...[
                      SizedBox(height: context.s(6)),
                      Wrap(
                        spacing: context.s(6),
                        runSpacing: context.s(6),
                        children: [
                          for (final tag in allTags)
                            if (!_tags.contains(tag.name))
                              GestureDetector(
                                onTap: () => setState(
                                  () => _tags = [..._tags, tag.name],
                                ),
                                child: Container(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: context.s(9),
                                    vertical: context.s(4),
                                  ),
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                      color: context.colors.borderSubtle,
                                    ),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: Text(
                                    tag.name,
                                    style: AppTypography.monoLabel(context)
                                        .copyWith(
                                          fontSize: context.s(9.5),
                                          color: context.colors.inkFaint,
                                        ),
                                  ),
                                ),
                              ),
                        ],
                      ),
                    ],
                    SizedBox(height: context.s(16)),
                    Text(
                      'PRIORITY',
                      style: AppTypography.monoLabel(
                        context,
                      ).copyWith(letterSpacing: context.s(1.4)),
                    ),
                    SizedBox(height: context.s(6)),
                    Wrap(
                      spacing: context.s(6),
                      children: [
                        _SelectableChip(
                          label: 'None',
                          selected: _priority == null,
                          onTap: () => setState(() => _priority = null),
                        ),
                        for (final p in ItemPriority.values)
                          _SelectableChip(
                            label: p.name.toUpperCase(),
                            selected: _priority == p,
                            onTap: () => setState(() => _priority = p),
                          ),
                      ],
                    ),
                    SizedBox(height: context.s(16)),
                    KindToggle(
                      kind: _kind,
                      onChanged: (k) => setState(() => _kind = k),
                    ),
                    SizedBox(height: context.s(14)),
                    Text(
                      'PICK A DATE',
                      style: AppTypography.monoLabel(
                        context,
                      ).copyWith(letterSpacing: context.s(1.4)),
                    ),
                    SizedBox(height: context.s(6)),
                    GestureDetector(
                      onTap: () =>
                          setState(() => _calendarOpen = !_calendarOpen),
                      child: Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: context.s(12),
                          vertical: context.s(10),
                        ),
                        decoration: BoxDecoration(
                          color: context.colors.surface,
                          border: Border.all(color: context.colors.border),
                          borderRadius: BorderRadius.circular(context.s(12)),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                _formatDate(_selectedDate),
                                style: TextStyle(
                                  fontFamily: AppTypography.monoFamily,
                                  fontSize: context.s(13),
                                  fontWeight: FontWeight.w600,
                                  color: context.colors.ink,
                                ),
                              ),
                            ),
                            Text(
                              _calendarOpen ? 'CLOSE' : 'CHANGE',
                              style: AppTypography.monoLabel(
                                context,
                              ).copyWith(fontSize: context.s(9.5)),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (_calendarOpen) ...[
                      SizedBox(height: context.s(8)),
                      MonthCalendar(
                        month: _calendarMonth,
                        selected: _selectedDate,
                        onPrevMonth: () => setState(
                          () => _calendarMonth = DateTime(
                            _calendarMonth.year,
                            _calendarMonth.month - 1,
                          ),
                        ),
                        onNextMonth: () => setState(
                          () => _calendarMonth = DateTime(
                            _calendarMonth.year,
                            _calendarMonth.month + 1,
                          ),
                        ),
                        onPick: (day) => setState(() {
                          _selectedDate = day;
                          _calendarOpen = false;
                        }),
                      ),
                    ],
                    SizedBox(height: context.s(14)),
                    Text(
                      'PICK A TIME',
                      style: AppTypography.monoLabel(
                        context,
                      ).copyWith(letterSpacing: context.s(1.4)),
                    ),
                    SizedBox(height: context.s(6)),
                    if (_kind == ItemDateKind.due)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          TimeWheelPair(
                            hour: _hour,
                            minute: _minute,
                            onHourChanged: (h) => setState(() {
                              _hour = h;
                              _noTime = false;
                            }),
                            onMinuteChanged: (m) => setState(() {
                              _minute = m;
                              _noTime = false;
                            }),
                          ),
                          SizedBox(width: context.s(14)),
                          Expanded(
                            child: GestureDetector(
                              onTap: () => setState(() => _noTime = !_noTime),
                              child: Container(
                                padding: EdgeInsets.symmetric(
                                  vertical: context.s(8),
                                ),
                                decoration: BoxDecoration(
                                  color: _noTime
                                      ? context.colors.ink
                                      : context.colors.surface,
                                  border: Border.all(
                                    color: _noTime
                                        ? context.colors.ink
                                        : context.colors.border,
                                  ),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  'END OF DAY',
                                  style: AppTypography.monoLabel(context)
                                      .copyWith(
                                        fontSize: context.s(9.5),
                                        color: _noTime
                                            ? context.colors.surface
                                            : context.colors.inkMuted,
                                      ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      )
                    else
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              children: [
                                Text(
                                  'FROM',
                                  style: AppTypography.monoLabel(
                                    context,
                                  ).copyWith(fontSize: context.s(9)),
                                ),
                                SizedBox(height: context.s(6)),
                                TimeWheelPair(
                                  hour: _hour,
                                  minute: _minute,
                                  onHourChanged: (h) => setState(() {
                                    _hour = h;
                                    _timeError = null;
                                  }),
                                  onMinuteChanged: (m) => setState(() {
                                    _minute = m;
                                    _timeError = null;
                                  }),
                                ),
                              ],
                            ),
                          ),
                          SizedBox(width: context.s(10)),
                          Expanded(
                            child: Column(
                              children: [
                                Text(
                                  'TO',
                                  style: AppTypography.monoLabel(
                                    context,
                                  ).copyWith(fontSize: context.s(9)),
                                ),
                                SizedBox(height: context.s(6)),
                                TimeWheelPair(
                                  hour: _endHour,
                                  minute: _endMinute,
                                  onHourChanged: (h) => setState(() {
                                    _endHour = h;
                                    _timeError = null;
                                  }),
                                  onMinuteChanged: (m) => setState(() {
                                    _endMinute = m;
                                    _timeError = null;
                                  }),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    if (_timeError != null) ...[
                      SizedBox(height: context.s(6)),
                      Text(
                        _timeError!,
                        style: TextStyle(
                          color: context.colors.accent,
                          fontSize: context.s(12.5),
                        ),
                      ),
                    ],
                    SizedBox(height: context.s(14)),
                    Text(
                      'REPEAT',
                      style: AppTypography.monoLabel(
                        context,
                      ).copyWith(letterSpacing: context.s(1.4)),
                    ),
                    SizedBox(height: context.s(6)),
                    Wrap(
                      spacing: context.s(6),
                      runSpacing: context.s(6),
                      children: [
                        for (final option in [
                          'NONE',
                          'DAILY',
                          'WEEKLY',
                          'WEEKDAYS',
                        ])
                          RepeatChip(
                            label: option,
                            active: _repeat == option,
                            onTap: () => setState(() => _repeat = option),
                          ),
                      ],
                    ),
                    SizedBox(height: context.s(14)),
                    Text(
                      'REMINDER',
                      style: AppTypography.monoLabel(
                        context,
                      ).copyWith(letterSpacing: context.s(1.4)),
                    ),
                    SizedBox(height: context.s(6)),
                    Wrap(
                      spacing: context.s(6),
                      runSpacing: context.s(6),
                      children: [
                        for (final option in _reminderOffsetOptions)
                          RepeatChip(
                            label: _reminderOffsetLabel(option),
                            active: _reminderOffsetMinutes == option,
                            onTap: () => setState(
                              () => _reminderOffsetMinutes = option,
                            ),
                          ),
                      ],
                    ),
                    if (_gcalConnected && _hasSavedDate) ...[
                      SizedBox(height: context.s(14)),
                      GestureDetector(
                        onTap: (_gcalBusy || _gcalEventId != null)
                            ? null
                            : _addToGoogleCalendar,
                        child: Row(
                          children: [
                            Icon(
                              _gcalEventId != null
                                  ? Icons.check_circle
                                  : Icons.event_outlined,
                              size: context.s(16),
                              color: _gcalEventId != null
                                  ? context.colors.accent
                                  : context.colors.inkMuted,
                            ),
                            SizedBox(width: context.s(8)),
                            Text(
                              _gcalEventId != null
                                  ? 'Added to Google Calendar'
                                  : (_gcalBusy
                                        ? 'Adding…'
                                        : 'Add to Google Calendar'),
                              style: AppTypography.secondaryMeta(context)
                                  .copyWith(
                                    fontSize: context.s(13),
                                    color: _gcalEventId != null
                                        ? context.colors.ink
                                        : context.colors.inkMuted,
                                  ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    SizedBox(height: context.s(16)),
                    Text(
                      'NOTES',
                      style: AppTypography.monoLabel(
                        context,
                      ).copyWith(letterSpacing: context.s(1.4)),
                    ),
                    SizedBox(height: context.s(6)),
                    TextField(
                      controller: _notesController,
                      maxLines: 4,
                      minLines: 2,
                      style: TextStyle(
                        fontFamily: AppTypography.sansFamily,
                        fontSize: context.s(13.5),
                        color: context.colors.ink,
                      ),
                      decoration: InputDecoration(
                        hintText: 'Add notes...',
                        hintStyle: TextStyle(color: context.colors.inkDisabled),
                        filled: true,
                        fillColor: context.colors.background,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(context.s(12)),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: EdgeInsets.all(context.s(12)),
                      ),
                    ),
                    SizedBox(height: context.s(16)),
                    Text(
                      'SUBTASKS',
                      style: AppTypography.monoLabel(
                        context,
                      ).copyWith(letterSpacing: context.s(1.4)),
                    ),
                    SizedBox(height: context.s(6)),
                    for (final subtask in subtasks)
                      _SubtaskRow(subtask: subtask),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _subtaskInputController,
                            style: TextStyle(
                              fontFamily: AppTypography.sansFamily,
                              fontSize: context.s(13.5),
                              color: context.colors.ink,
                            ),
                            decoration: InputDecoration(
                              isDense: true,
                              hintText: '+ add subtask',
                              hintStyle: TextStyle(
                                color: context.colors.inkDisabled,
                              ),
                              border: InputBorder.none,
                            ),
                            onSubmitted: (_) => _addSubtask(),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (_status != ItemStatus.open) ...[
              SizedBox(height: context.s(14)),
              Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: _restore,
                      child: Container(
                        height: context.s(44),
                        decoration: BoxDecoration(
                          color: context.colors.ink,
                          borderRadius: BorderRadius.circular(context.s(15)),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          'Restore',
                          style: AppTypography.button(
                            context,
                          ).copyWith(color: context.colors.surface),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(width: context.s(10)),
                  Expanded(
                    child: GestureDetector(
                      onTap: _permanentlyDelete,
                      child: Container(
                        height: context.s(44),
                        decoration: BoxDecoration(
                          border: Border.all(color: context.colors.accent),
                          borderRadius: BorderRadius.circular(context.s(15)),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          'Delete permanently',
                          style: AppTypography.button(context).copyWith(
                            color: context.colors.accent,
                            fontSize: context.s(12.5),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
            SizedBox(height: context.s(14)),
            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: _save,
                    child: Container(
                      height: context.s(48),
                      decoration: BoxDecoration(
                        color: context.colors.ink,
                        borderRadius: BorderRadius.circular(context.s(15)),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        'Save',
                        style: AppTypography.button(
                          context,
                        ).copyWith(color: context.colors.surface),
                      ),
                    ),
                  ),
                ),
                SizedBox(width: context.s(10)),
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  child: Container(
                    width: context.s(48),
                    height: context.s(48),
                    decoration: BoxDecoration(
                      border: Border.all(color: context.colors.border),
                      borderRadius: BorderRadius.circular(context.s(15)),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.close,
                      size: context.s(18),
                      color: context.colors.inkMuted,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime d) {
    const weekdays = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];
    const months = [
      'JAN',
      'FEB',
      'MAR',
      'APR',
      'MAY',
      'JUN',
      'JUL',
      'AUG',
      'SEP',
      'OCT',
      'NOV',
      'DEC',
    ];
    return '${weekdays[d.weekday - 1]} ${d.day} ${months[d.month - 1]}';
  }
}

class _SelectableChip extends StatelessWidget {
  const _SelectableChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.color,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: context.s(11),
          vertical: context.s(7),
        ),
        decoration: BoxDecoration(
          color: selected ? context.colors.ink : context.colors.surface,
          border: Border.all(
            color: selected ? context.colors.ink : context.colors.border,
          ),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (color != null) ...[
              Container(
                width: context.s(7),
                height: context.s(7),
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              SizedBox(width: context.s(6)),
            ],
            Text(
              label,
              style: AppTypography.monoLabel(context).copyWith(
                fontSize: context.s(10),
                color: selected
                    ? context.colors.surface
                    : context.colors.inkMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RemovableChip extends StatelessWidget {
  const _RemovableChip({required this.label, required this.onRemove});
  final String label;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.s(9),
        vertical: context.s(5),
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF4A5A70).withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: context.s(12),
              fontWeight: FontWeight.w500,
              color: const Color(0xFF3A4759),
            ),
          ),
          SizedBox(width: context.s(5)),
          GestureDetector(
            onTap: onRemove,
            child: Icon(
              Icons.close,
              size: context.s(13),
              color: const Color(0xFF3A4759),
            ),
          ),
        ],
      ),
    );
  }
}

class _SubtaskRow extends ConsumerWidget {
  const _SubtaskRow({required this.subtask});
  final Item subtask;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final done = subtask.status.name == 'done';
    return Padding(
      padding: EdgeInsets.symmetric(vertical: context.s(5)),
      child: Row(
        children: [
          GestureDetector(
            onTap: () =>
                ref.read(itemRepositoryProvider).toggleComplete(subtask.id),
            child: Container(
              width: context.s(18),
              height: context.s(18),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: done ? context.colors.ink : Colors.transparent,
                border: Border.all(
                  color: done ? context.colors.ink : context.colors.inkDisabled,
                  width: 1.5,
                ),
              ),
              alignment: Alignment.center,
              child: done
                  ? Icon(
                      Icons.check,
                      size: context.s(10),
                      color: context.colors.surface,
                    )
                  : null,
            ),
          ),
          SizedBox(width: context.s(10)),
          Expanded(
            child: Text(
              subtask.title,
              style: AppTypography.itemTitle(context).copyWith(
                fontSize: context.s(13.5),
                color: done ? context.colors.inkDisabled : context.colors.ink,
                decoration: done
                    ? TextDecoration.lineThrough
                    : TextDecoration.none,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
