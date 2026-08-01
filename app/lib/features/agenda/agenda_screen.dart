import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/db/database.dart' show ExternalEvent;
import '../../data/db/tables.dart' show ItemPriority;
import '../../data/repositories/item_repository.dart';
import '../../data/repositories/settings_repository.dart' show ItemSortMode;
import '../../domain/services/gamification.dart';
import '../item/item_detail_sheet.dart';
import '../search/search_screen.dart';
import '../shared/cosmetic_cluster.dart';
import 'widgets/item_row.dart';

/// Ties the current sort mode's semantics to display text and, for the
/// non-Manual modes, an in-memory comparator applied on top of whatever
/// order the underlying query already returned. `dueDate` needs no
/// comparator — every list here is already queried in date/time order.
String sortModeLabel(ItemSortMode mode) => switch (mode) {
  ItemSortMode.dueDate => 'Due date',
  ItemSortMode.priority => 'Priority',
  ItemSortMode.created => 'Created',
  ItemSortMode.manual => 'Manual',
};

int _priorityRank(ItemPriority? p) => switch (p) {
  ItemPriority.high => 0,
  ItemPriority.medium => 1,
  ItemPriority.low => 2,
  null => 3,
};

List<ItemWithArea> sortItems(List<ItemWithArea> items, ItemSortMode mode) {
  final sorted = [...items];
  switch (mode) {
    case ItemSortMode.dueDate:
      break;
    case ItemSortMode.priority:
      sorted.sort(
        (a, b) => _priorityRank(
          a.item.priority,
        ).compareTo(_priorityRank(b.item.priority)),
      );
    case ItemSortMode.created:
      sorted.sort((a, b) => a.item.createdAt.compareTo(b.item.createdAt));
    case ItemSortMode.manual:
      sorted.sort((a, b) => a.item.sortOrder.compareTo(b.item.sortOrder));
  }
  return sorted;
}

const _weekdayNames = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];
const _monthNames = [
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

DateTime _startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);

enum _View { today, upNext }

/// Today/Agenda + Up Next (§5) — one screen, two views, matching the
/// design's shared "Today | Up Next" tab-switcher header.
class AgendaScreen extends ConsumerStatefulWidget {
  const AgendaScreen({super.key, this.initialUpNext = false});

  /// Set by the Up Next/Agenda home-screen widget taps (via
  /// `AppShellScreen.initialAgendaUpNext`) to land straight on the Up
  /// Next sub-view instead of Today.
  final bool initialUpNext;

  @override
  ConsumerState<AgendaScreen> createState() => _AgendaScreenState();
}

class _AgendaScreenState extends ConsumerState<AgendaScreen> {
  late _View _view = widget.initialUpNext ? _View.upNext : _View.today;
  ItemSortMode _sort = ItemSortMode.dueDate;

  /// Multi-select (§4, bulk actions), keyed by occurrence id when the row
  /// is a recurring instance, else the item id — matches how swipe-archive
  /// and toggle already distinguish the two.
  final Map<String, ItemWithArea> _selected = {};

  @override
  void initState() {
    super.initState();
    ref.read(settingsRepositoryProvider).getAgendaSort().then((mode) {
      if (mounted) setState(() => _sort = mode);
    });
  }

  void _setSort(ItemSortMode mode) {
    setState(() => _sort = mode);
    ref.read(settingsRepositoryProvider).setAgendaSort(mode);
  }

  Future<void> _pickSort() async {
    final chosen = await showModalBottomSheet<ItemSortMode>(
      context: context,
      backgroundColor: context.colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(context.s(24)),
        ),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.all(context.s(16)),
              child: Text(
                'Sort by',
                style: AppTypography.sectionHeader(context),
              ),
            ),
            for (final mode in ItemSortMode.values)
              ListTile(
                title: Text(sortModeLabel(mode)),
                trailing: mode == _sort
                    ? Icon(Icons.check, color: context.colors.accent)
                    : null,
                onTap: () => Navigator.of(context).pop(mode),
              ),
          ],
        ),
      ),
    );
    if (chosen == null) return;
    _setSort(chosen);
  }

  /// Writes back the new manual order (§4) after a drag-reorder — targets
  /// each row's template item id, same rule as every other occurrence-aware
  /// mutation here.
  Future<void> _reorder(List<ItemWithArea> orderedItems) {
    return ref
        .read(itemRepositoryProvider)
        .reorderItems(orderedItems.map((iwa) => iwa.item.id).toList());
  }

  String _rowKey(ItemWithArea iwa) => iwa.occurrenceId ?? iwa.item.id;

  void _toggleSelect(ItemWithArea iwa) {
    setState(() {
      final key = _rowKey(iwa);
      if (_selected.containsKey(key)) {
        _selected.remove(key);
      } else {
        _selected[key] = iwa;
      }
    });
  }

  void _clearSelection() => setState(_selected.clear);

  Future<void> _bulkComplete() async {
    final items = _selected.values.toList();
    _clearSelection();
    await ref.read(itemRepositoryProvider).bulkComplete(items);
  }

  Future<void> _bulkArchive() async {
    final items = _selected.values.toList();
    _clearSelection();
    await ref.read(itemRepositoryProvider).bulkArchive(items);
  }

  Future<void> _bulkMoveArea() async {
    final areas = ref.read(activeAreasProvider).value ?? const [];
    // '' is the "No area" sentinel, distinct from null (sheet dismissed
    // without choosing anything, e.g. tapped the barrier) — both would
    // otherwise be indistinguishable and silently clear every selected
    // item's area on a plain cancel.
    final chosen = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: context.colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(context.s(24)),
        ),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.all(context.s(16)),
              child: Text(
                'Move to area',
                style: AppTypography.sectionHeader(context),
              ),
            ),
            for (final area in areas)
              ListTile(
                title: Text(area.name),
                onTap: () => Navigator.of(context).pop(area.id),
              ),
            ListTile(
              title: const Text('No area'),
              onTap: () => Navigator.of(context).pop(''),
            ),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    final ids = _selected.values.map((iwa) => iwa.item.id).toList();
    _clearSelection();
    await ref
        .read(itemRepositoryProvider)
        .bulkMoveArea(ids, chosen.isEmpty ? null : chosen);
  }

  /// Routes to the right repository method depending on whether [iwa] is
  /// a materialized occurrence of a recurring item or a direct item —
  /// toggling an occurrence must never flip the template or its sibling
  /// instances (§3, Recurrence).
  Future<void> _toggle(ItemWithArea iwa) async {
    final repo = ref.read(itemRepositoryProvider);
    Future<void> apply() => iwa.occurrenceId != null
        ? repo.toggleOccurrenceComplete(iwa.occurrenceId!)
        : repo.toggleComplete(iwa.item.id);

    await apply();
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: context.colors.ink,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
        content: Text(
          'Updated',
          style: TextStyle(color: context.colors.surface),
        ),
        action: SnackBarAction(
          label: 'UNDO',
          textColor: const Color(0xFFCFC7B8),
          onPressed: apply,
        ),
      ),
    );
  }

  /// Swipe-left archive (§4). Always targets the template item id, even
  /// for an occurrence row — same rule as tapping a row opening the
  /// template's Item Detail, not a per-occurrence one.
  Future<void> _archive(ItemWithArea iwa) async {
    final repo = ref.read(itemRepositoryProvider);
    await repo.archiveItem(iwa.item.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: context.colors.ink,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
        content: Text(
          'Archived',
          style: TextStyle(color: context.colors.surface),
        ),
        action: SnackBarAction(
          label: 'UNDO',
          textColor: const Color(0xFFCFC7B8),
          onPressed: () => repo.restoreItem(iwa.item.id),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final today = _startOfDay(DateTime.now());
    return Scaffold(
      backgroundColor: context.colors.background,
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: context.s(16)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(height: context.s(8)),
              if (_selected.isNotEmpty)
                _SelectionBar(
                  count: _selected.length,
                  onCancel: _clearSelection,
                  onComplete: _bulkComplete,
                  onArchive: _bulkArchive,
                  onMoveArea: _bulkMoveArea,
                )
              else if (_view == _View.today)
                _TodayHeader(today: today)
              else
                const _UpNextHeader(),
              SizedBox(height: context.s(12)),
              _TabSwitcher(
                view: _view,
                onChanged: (v) => setState(() => _view = v),
                onSortTap: _pickSort,
              ),
              Expanded(
                child: _view == _View.today
                    ? _TodayBody(
                        today: today,
                        onToggle: _toggle,
                        onArchive: _archive,
                        selectedKeys: _selected.keys.toSet(),
                        onLongPress: _toggleSelect,
                        onSelectTap: _toggleSelect,
                        sort: _sort,
                        onReorder: _reorder,
                      )
                    : _UpNextBody(
                        today: today,
                        onToggle: _toggle,
                        onArchive: _archive,
                        selectedKeys: _selected.keys.toSet(),
                        onLongPress: _toggleSelect,
                        onSelectTap: _toggleSelect,
                        sort: _sort,
                        onReorder: _reorder,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TodayHeader extends ConsumerWidget {
  const _TodayHeader({required this.today});
  final DateTime today;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider).value;
    final name = profile?.firstName ?? 'there';
    final totalXp = ref.watch(totalXpProvider).value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              '${today.day}',
              style: TextStyle(
                fontFamily: AppTypography.monoFamily,
                fontSize: context.s(46),
                fontWeight: FontWeight.w600,
                letterSpacing: context.s(-2.3),
                color: context.colors.ink,
                height: 0.82,
              ),
            ),
            SizedBox(width: context.s(9)),
            Padding(
              padding: EdgeInsets.only(bottom: context.s(3)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _monthNames[today.month - 1],
                    style: AppTypography.monoLabel(context),
                  ),
                  Text(
                    _weekdayNames[today.weekday - 1],
                    style: AppTypography.monoLabel(
                      context,
                    ).copyWith(color: context.colors.accent),
                  ),
                ],
              ),
            ),
          ],
        ),
        SizedBox(height: context.s(12)),
        Row(
          children: [
            Expanded(
              child: Text(
                'Good morning, $name',
                style: AppTypography.headline(
                  context,
                ).copyWith(fontSize: context.s(24)),
              ),
            ),
            const CosmeticCluster(),
            SizedBox(width: context.s(8)),
            GestureDetector(
              onTap: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const SearchScreen())),
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: context.s(11),
                  vertical: context.s(6),
                ),
                decoration: BoxDecoration(
                  color: context.colors.borderFaint,
                  border: Border.all(color: context.colors.border),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  'FIND',
                  style: AppTypography.monoLabel(
                    context,
                  ).copyWith(fontSize: context.s(10)),
                ),
              ),
            ),
          ],
        ),
        if (totalXp != null) ...[
          SizedBox(height: context.s(10)),
          _LevelGauge(totalXp: totalXp),
        ],
      ],
    );
  }
}

/// "LV n · dashed progress track · n / ceiling XP" (§17 design handoff,
/// `Cove Prototype.dc.html:153-159`) — replaces a plain "· Level n" text
/// suffix on the greeting with the actual gauge the mockup specifies.
/// Always shown once `totalXp` has loaded, even at 0 (LV 1, empty bar,
/// 0/100 XP) — hiding it below the first completion would hide the
/// gamification feature from ever being discovered.
class _LevelGauge extends StatelessWidget {
  const _LevelGauge({required this.totalXp});
  final int totalXp;

  @override
  Widget build(BuildContext context) {
    final level = Gamification.levelForXp(totalXp);
    final floor = level == 1 ? 0 : Gamification.levelThresholds[level]!;
    final ceil = level >= Gamification.maxLevel
        ? Gamification.levelThresholds[Gamification.maxLevel]!
        : Gamification.levelThresholds[level + 1]!;
    final fraction = ceil == floor
        ? 1.0
        : ((totalXp - floor) / (ceil - floor)).clamp(0.0, 1.0);
    return Row(
      children: [
        Text(
          'LV $level',
          style: AppTypography.monoLabel(context).copyWith(letterSpacing: context.s(1.6)),
        ),
        SizedBox(width: context.s(10)),
        Expanded(
          child: _DashedTrack(
            fraction: fraction,
            height: context.s(9),
            fillColor: context.colors.accent,
            trackColor: context.colors.border,
          ),
        ),
        SizedBox(width: context.s(10)),
        Text('$totalXp / $ceil XP', style: AppTypography.mono(context)),
      ],
    );
  }
}

/// Draws the "repeating-linear-gradient" dashed bar from the design
/// handoff (5px dash, 4px gap, scaled by [context.s]) — a filled track
/// under an unfilled one, both dashed, rather than a solid Material
/// `LinearProgressIndicator`.
class _DashedTrack extends StatelessWidget {
  const _DashedTrack({
    required this.fraction,
    required this.height,
    required this.fillColor,
    required this.trackColor,
  });

  final double fraction;
  final double height;
  final Color fillColor;
  final Color trackColor;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: CustomPaint(
        painter: _DashedTrackPainter(
          fraction: fraction,
          dash: context.s(5),
          gap: context.s(4),
          fillColor: fillColor,
          trackColor: trackColor,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _DashedTrackPainter extends CustomPainter {
  const _DashedTrackPainter({
    required this.fraction,
    required this.dash,
    required this.gap,
    required this.fillColor,
    required this.trackColor,
  });

  final double fraction;
  final double dash;
  final double gap;
  final Color fillColor;
  final Color trackColor;

  void _paintDashes(Canvas canvas, Size size, double upTo, Color color) {
    final paint = Paint()..color = color;
    final period = dash + gap;
    for (var x = 0.0; x < upTo; x += period) {
      final w = (dash < upTo - x) ? dash : upTo - x;
      canvas.drawRect(Rect.fromLTWH(x, 0, w, size.height), paint);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    _paintDashes(canvas, size, size.width, trackColor);
    _paintDashes(canvas, size, size.width * fraction, fillColor);
  }

  @override
  bool shouldRepaint(covariant _DashedTrackPainter oldDelegate) =>
      oldDelegate.fraction != fraction ||
      oldDelegate.fillColor != fillColor ||
      oldDelegate.trackColor != trackColor;
}

class _UpNextHeader extends StatelessWidget {
  const _UpNextHeader();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: context.s(8)),
      child: Row(
        children: [
          Expanded(
            child: Text('Up Next', style: AppTypography.sectionHeader(context)),
          ),
          const CosmeticCluster(),
        ],
      ),
    );
  }
}

class _TabSwitcher extends StatelessWidget {
  const _TabSwitcher({
    required this.view,
    required this.onChanged,
    required this.onSortTap,
  });
  final _View view;
  final ValueChanged<_View> onChanged;
  final VoidCallback onSortTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: context.colors.border)),
      ),
      child: Row(
        children: [
          _TabLabel(
            label: 'Today',
            active: view == _View.today,
            onTap: () => onChanged(_View.today),
          ),
          SizedBox(width: context.s(20)),
          _TabLabel(
            label: 'Up Next',
            active: view == _View.upNext,
            onTap: () => onChanged(_View.upNext),
          ),
          const Spacer(),
          GestureDetector(
            onTap: onSortTap,
            child: Padding(
              padding: EdgeInsets.only(bottom: context.s(9)),
              child: Icon(
                Icons.sort,
                size: context.s(18),
                color: context.colors.inkMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TabLabel extends StatelessWidget {
  const _TabLabel({
    required this.label,
    required this.active,
    required this.onTap,
  });
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.only(bottom: context.s(9)),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: active ? context.colors.ink : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: AppTypography.sansFamily,
            fontSize: context.s(14.5),
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            color: active ? context.colors.ink : context.colors.inkFaint,
          ),
        ),
      ),
    );
  }
}

class _TodayBody extends ConsumerWidget {
  const _TodayBody({
    required this.today,
    required this.onToggle,
    required this.onArchive,
    required this.selectedKeys,
    required this.onLongPress,
    required this.onSelectTap,
    required this.sort,
    required this.onReorder,
  });
  final DateTime today;
  final Future<void> Function(ItemWithArea) onToggle;
  final Future<void> Function(ItemWithArea) onArchive;
  final Set<String> selectedKeys;
  final ValueChanged<ItemWithArea> onLongPress;
  final ValueChanged<ItemWithArea> onSelectTap;
  final ItemSortMode sort;
  final Future<void> Function(List<ItemWithArea>) onReorder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheduled = sortItems(
      ref.watch(scheduledForDayProvider(today)).value ?? const <ItemWithArea>[],
      sort,
    );
    final due = sortItems(
      ref.watch(dueForDayProvider(today)).value ?? const <ItemWithArea>[],
      sort,
    );
    final externalEvents =
        ref
            .watch(
              externalEventsInRangeProvider((
                start: today,
                end: today.add(const Duration(days: 1)),
              )),
            )
            .value ??
        const <ExternalEvent>[];

    if (scheduled.isEmpty && due.isEmpty && externalEvents.isEmpty) {
      return const _EmptyState(
        message: 'Nothing today. Tap + to add something.',
      );
    }

    return ListView(
      padding: EdgeInsets.only(top: context.s(12), bottom: context.s(96)),
      children: [
        if (externalEvents.isNotEmpty) ...[
          Text(
            'FROM GOOGLE CALENDAR',
            style: AppTypography.monoLabel(
              context,
            ).copyWith(letterSpacing: context.s(1.4)),
          ),
          SizedBox(height: context.s(8)),
          for (final event in externalEvents) _ExternalEventRow(event: event),
          SizedBox(height: context.s(12)),
        ],
        if (scheduled.isNotEmpty) ...[
          Text(
            'SCHEDULED',
            style: AppTypography.monoLabel(
              context,
            ).copyWith(letterSpacing: context.s(1.4)),
          ),
          SizedBox(height: context.s(8)),
          _ItemSection(
            items: scheduled,
            sort: sort,
            selectedKeys: selectedKeys,
            onToggle: onToggle,
            onArchive: onArchive,
            onOpenItem: (iwa) =>
                showItemDetailSheetAndMaybeExport(context, ref, iwa.item.id),
            onLongPress: onLongPress,
            onSelectTap: onSelectTap,
            onReorder: onReorder,
            leadingBuilder: (iwa) => SizedBox(
              width: context.s(44),
              child: Text(
                iwa.item.scheduledEnd != null
                    ? '${timeLabel(iwa.item.scheduledStart!)}\n${timeLabel(iwa.item.scheduledEnd!)}'
                    : timeLabel(iwa.item.scheduledStart!),
                style: AppTypography.mono(
                  context,
                ).copyWith(fontSize: context.s(11)),
              ),
            ),
          ),
          SizedBox(height: context.s(12)),
        ],
        if (due.isNotEmpty) ...[
          Text(
            'DUE TODAY',
            style: AppTypography.monoLabel(
              context,
            ).copyWith(letterSpacing: context.s(1.4)),
          ),
          SizedBox(height: context.s(8)),
          _ItemSection(
            items: due,
            sort: sort,
            selectedKeys: selectedKeys,
            onToggle: onToggle,
            onArchive: onArchive,
            onOpenItem: (iwa) =>
                showItemDetailSheetAndMaybeExport(context, ref, iwa.item.id),
            onLongPress: onLongPress,
            onSelectTap: onSelectTap,
            onReorder: onReorder,
            leadingBuilder: (iwa) => SizedBox(
              width: context.s(44),
              child: Text(
                dueTimeLabel(iwa.item.dueAt!) ?? '—',
                style: AppTypography.mono(context).copyWith(
                  fontSize: context.s(11),
                  color: context.colors.accent,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _UpNextBody extends ConsumerWidget {
  const _UpNextBody({
    required this.today,
    required this.onToggle,
    required this.onArchive,
    required this.selectedKeys,
    required this.onLongPress,
    required this.onSelectTap,
    required this.sort,
    required this.onReorder,
  });
  final DateTime today;
  final Future<void> Function(ItemWithArea) onToggle;
  final Future<void> Function(ItemWithArea) onArchive;
  final Set<String> selectedKeys;
  final ValueChanged<ItemWithArea> onLongPress;
  final ValueChanged<ItemWithArea> onSelectTap;
  final ItemSortMode sort;
  final Future<void> Function(List<ItemWithArea>) onReorder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tomorrow = today.add(const Duration(days: 1));
    final items =
        ref.watch(upcomingItemsProvider(tomorrow)).value ??
        const <ItemWithArea>[];

    if (items.isEmpty) {
      return const _EmptyState(message: 'Nothing coming up.');
    }

    final groups = <String, List<ItemWithArea>>{};
    for (final iwa in items) {
      final label = _bucketLabel(today, iwa.item.dueAt!);
      groups.putIfAbsent(label, () => []).add(iwa);
    }

    return ListView(
      padding: EdgeInsets.only(top: context.s(12), bottom: context.s(96)),
      children: [
        for (final entry in groups.entries) ...[
          Row(
            children: [
              Text(
                entry.key.toUpperCase(),
                style: AppTypography.monoLabel(
                  context,
                ).copyWith(letterSpacing: context.s(1.4)),
              ),
              SizedBox(width: context.s(10)),
              Expanded(
                child: Divider(color: context.colors.borderSubtle, height: 1),
              ),
            ],
          ),
          SizedBox(height: context.s(6)),
          _ItemSection(
            items: sortItems(entry.value, sort),
            sort: sort,
            selectedKeys: selectedKeys,
            onToggle: onToggle,
            onArchive: onArchive,
            onOpenItem: (iwa) =>
                showItemDetailSheetAndMaybeExport(context, ref, iwa.item.id),
            onLongPress: onLongPress,
            onSelectTap: onSelectTap,
            onReorder: onReorder,
            trailingBuilder: (iwa) => Text(
              dueTimeLabel(iwa.item.dueAt!) ??
                  _weekdayNames[iwa.item.dueAt!.weekday - 1],
              style: AppTypography.mono(
                context,
              ).copyWith(fontSize: context.s(10.5)),
            ),
          ),
          SizedBox(height: context.s(14)),
        ],
      ],
    );
  }
}

/// Renders one section's rows — a plain stack normally, or a nested
/// drag-reorderable list when [sort] is Manual and nothing is selected
/// (dragging and multi-select never apply to the same row at once). The
/// manual drag handle takes over the row's `trailing` slot; any
/// section-specific trailing (Up Next's weekday label) only shows outside
/// Manual mode, matching how `onArchive`/swipe is suspended during
/// multi-select.
class _ItemSection extends StatelessWidget {
  const _ItemSection({
    required this.items,
    required this.sort,
    required this.selectedKeys,
    required this.onToggle,
    required this.onArchive,
    required this.onOpenItem,
    required this.onLongPress,
    required this.onSelectTap,
    required this.onReorder,
    this.leadingBuilder,
    this.trailingBuilder,
  });

  final List<ItemWithArea> items;
  final ItemSortMode sort;
  final Set<String> selectedKeys;
  final Future<void> Function(ItemWithArea) onToggle;
  final Future<void> Function(ItemWithArea) onArchive;
  final ValueChanged<ItemWithArea> onOpenItem;
  final ValueChanged<ItemWithArea> onLongPress;
  final ValueChanged<ItemWithArea> onSelectTap;
  final Future<void> Function(List<ItemWithArea>) onReorder;
  final Widget Function(ItemWithArea)? leadingBuilder;
  final Widget Function(ItemWithArea)? trailingBuilder;

  bool _isSelected(ItemWithArea iwa) =>
      selectedKeys.contains(iwa.occurrenceId ?? iwa.item.id);

  Widget _row(ItemWithArea iwa, {required bool manual, Widget? dragHandle}) {
    return ItemRow(
      key: ValueKey(iwa.occurrenceId ?? iwa.item.id),
      itemWithArea: iwa,
      onToggle: () => onToggle(iwa),
      onTap: selectedKeys.isNotEmpty
          ? () => onSelectTap(iwa)
          : () => onOpenItem(iwa),
      onArchive: manual ? null : () => onArchive(iwa),
      onLongPress: () => onLongPress(iwa),
      selectionMode: selectedKeys.isNotEmpty,
      selected: _isSelected(iwa),
      leading: leadingBuilder?.call(iwa),
      trailing: manual ? dragHandle : trailingBuilder?.call(iwa),
    );
  }

  @override
  Widget build(BuildContext context) {
    final manual = sort == ItemSortMode.manual && selectedKeys.isEmpty;

    if (!manual) {
      return Column(
        children: [for (final iwa in items) _row(iwa, manual: false)],
      );
    }

    return ReorderableListView(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      onReorder: (oldIndex, newIndex) {
        final reordered = [...items];
        if (newIndex > oldIndex) newIndex -= 1;
        final moved = reordered.removeAt(oldIndex);
        reordered.insert(newIndex, moved);
        onReorder(reordered);
      },
      children: [
        for (var i = 0; i < items.length; i++)
          _row(
            items[i],
            manual: true,
            dragHandle: ReorderableDragStartListener(
              index: i,
              child: Icon(
                Icons.drag_handle,
                size: context.s(18),
                color: context.colors.inkFaint,
              ),
            ),
          ),
      ],
    );
  }
}

String _bucketLabel(DateTime today, DateTime due) {
  final days = _startOfDay(due).difference(today).inDays;
  if (days <= 1) {
    return 'Tomorrow · ${_weekdayNames[due.weekday - 1]} ${due.day}';
  }
  if (days <= 7) return 'This week';
  if (days <= 14) return 'Next week';
  return 'Later';
}

/// Replaces the normal date/greeting header while items are selected
/// (§4, bulk actions) — count + Complete/Archive/Move/Cancel.
class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.count,
    required this.onCancel,
    required this.onComplete,
    required this.onArchive,
    required this.onMoveArea,
  });
  final int count;
  final VoidCallback onCancel;
  final VoidCallback onComplete;
  final VoidCallback onArchive;
  final VoidCallback onMoveArea;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        GestureDetector(
          onTap: onCancel,
          child: Icon(
            Icons.close,
            size: context.s(20),
            color: context.colors.inkMuted,
          ),
        ),
        SizedBox(width: context.s(10)),
        Expanded(
          child: Text(
            '$count selected',
            style: AppTypography.headline(
              context,
            ).copyWith(fontSize: context.s(18)),
          ),
        ),
        _BarAction(icon: Icons.check, onTap: onComplete),
        SizedBox(width: context.s(6)),
        _BarAction(icon: Icons.drive_file_move_outline, onTap: onMoveArea),
        SizedBox(width: context.s(6)),
        _BarAction(icon: Icons.archive_outlined, onTap: onArchive),
      ],
    );
  }
}

class _BarAction extends StatelessWidget {
  const _BarAction({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: context.s(34),
        height: context.s(34),
        decoration: BoxDecoration(
          color: context.colors.borderFaint,
          borderRadius: BorderRadius.circular(context.s(10)),
        ),
        alignment: Alignment.center,
        child: Icon(icon, size: context.s(17), color: context.colors.ink),
      ),
    );
  }
}

/// A read-only row for an imported Google Calendar event (§9) — no
/// complete-circle, no swipe, no tap-to-edit; Cove never writes to or
/// materially interacts with these, it only displays what was synced.
class _ExternalEventRow extends StatelessWidget {
  const _ExternalEventRow({required this.event});
  final ExternalEvent event;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(vertical: context.s(10)),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: context.colors.borderSubtle)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: context.s(44),
            child: Text(
              timeLabel(event.start),
              style: AppTypography.mono(context).copyWith(
                fontSize: context.s(11),
                color: context.colors.inkFaint,
              ),
            ),
          ),
          SizedBox(width: context.s(12)),
          Expanded(
            child: Text(
              event.title,
              style: AppTypography.itemTitle(
                context,
              ).copyWith(color: context.colors.inkMuted),
            ),
          ),
          Icon(
            Icons.event_outlined,
            size: context.s(14),
            color: context.colors.inkFaint,
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        message,
        style: AppTypography.body(context),
        textAlign: TextAlign.center,
      ),
    );
  }
}
