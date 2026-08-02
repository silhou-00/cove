import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/db/database.dart' show ExternalEvent;
import '../../data/repositories/item_repository.dart';
import '../../domain/services/week_math.dart';
import '../agenda/widgets/item_row.dart' show timeLabel, dueTimeLabel;
import '../item/item_detail_sheet.dart';
import '../shared/cosmetic_cluster.dart';

/// A muted blue-grey used only for imported Google Calendar events'
/// dots/rows (§9) — deliberately outside `areaColorOptions` so an
/// external event is never visually mistaken for a real Cove area.
const _externalEventColor = Color(0xFF5B7A99);

// Monday-indexed (day.weekday - 1); TH/SA disambiguate Thursday from
// Tuesday and Saturday from Sunday, matching the "SMTWTHFSA" convention.
const _weekdayLetters = ['M', 'T', 'W', 'TH', 'F', 'SA', 'S'];

/// [_weekdayLetters] rotated to start at [firstWeekday] (`DateTime.monday`
/// or `DateTime.sunday`) — used wherever a header row must read in the
/// same left-to-right order as the day grid beneath it.
List<String> _weekdayLettersFrom(int firstWeekday) =>
    List.generate(7, (i) => _weekdayLetters[(firstWeekday - 1 + i) % 7]);
const _monthNamesShort = [
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
const _monthNamesFull = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

DateTime _startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);

bool _isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

enum _CalView { week, month }

/// Calendar tab (§5): Week and Month views, replacing the "Calendar —
/// built in V2" stub. Both use one range query (`watchItemsInRange`).
/// Deviates from the interactive mockup in two ways, both for
/// correctness rather than style — see documents/documentation.md:
/// prev/next navigation is added (the mockup is static to one week/month),
/// and the month grid is sized dynamically (35 or 42 cells) instead of a
/// hardcoded 35, so a month needing 6 rows doesn't clip its last few days.
class CalendarScreen extends ConsumerStatefulWidget {
  const CalendarScreen({super.key});

  @override
  ConsumerState<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends ConsumerState<CalendarScreen> {
  _CalView _view = _CalView.week;
  late DateTime _referenceDate;
  late DateTime _selectedDay;

  @override
  void initState() {
    super.initState();
    final today = _startOfDay(DateTime.now());
    _referenceDate = today;
    _selectedDay = today;
  }

  void _goPrev() {
    setState(() {
      _referenceDate = _view == _CalView.week
          ? _referenceDate.subtract(const Duration(days: 7))
          : DateTime(_referenceDate.year, _referenceDate.month - 1, 1);
    });
  }

  void _goNext() {
    setState(() {
      _referenceDate = _view == _CalView.week
          ? _referenceDate.add(const Duration(days: 7))
          : DateTime(_referenceDate.year, _referenceDate.month + 1, 1);
    });
  }

  String get _title {
    // Labeled by _referenceDate's own month, not the displayed week's
    // start — a week that starts in the previous month (e.g. the week
    // containing Aug 1, which starts Jul 27) should still read as
    // "August" once that's the month the anchor date (today, then
    // whatever +/-7-day navigation lands on) is actually in.
    if (_view == _CalView.week) {
      return _monthNamesFull[_referenceDate.month - 1];
    }
    return '${_monthNamesFull[_referenceDate.month - 1]} ${_referenceDate.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.colors.background,
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: context.s(16)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(height: context.s(8)),
              Row(
                children: [
                  GestureDetector(
                    onTap: _goPrev,
                    child: Icon(
                      Icons.chevron_left,
                      size: context.s(22),
                      color: context.colors.inkMuted,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      _title,
                      textAlign: TextAlign.center,
                      style: AppTypography.sectionHeader(
                        context,
                      ).copyWith(fontSize: context.s(17)),
                    ),
                  ),
                  GestureDetector(
                    onTap: _goNext,
                    child: Icon(
                      Icons.chevron_right,
                      size: context.s(22),
                      color: context.colors.inkMuted,
                    ),
                  ),
                ],
              ),
              SizedBox(height: context.s(10)),
              Row(
                children: [
                  const CosmeticCluster(),
                  const Spacer(),
                  _ViewToggle(
                    view: _view,
                    onChanged: (v) => setState(() => _view = v),
                  ),
                ],
              ),
              SizedBox(height: context.s(14)),
              Expanded(
                child: _view == _CalView.week
                    ? _WeekView(referenceDate: _referenceDate)
                    : _MonthView(
                        referenceDate: _referenceDate,
                        selectedDay: _selectedDay,
                        onSelectDay: (d) => setState(() => _selectedDay = d),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ViewToggle extends StatelessWidget {
  const _ViewToggle({required this.view, required this.onChanged});
  final _CalView view;
  final ValueChanged<_CalView> onChanged;

  // Fixed, equal segment width instead of intrinsic text sizing — this
  // toggle is meant to stay compact (shrink-wrapped, not full-width), so
  // the sliding highlight below needs a known pixel width to animate
  // between rather than measuring text. Wide enough for "MONTH" at this
  // label style's letter-spacing.
  static const _segmentWidth = 64.0;

  @override
  Widget build(BuildContext context) {
    final segW = context.s(_segmentWidth);
    return Container(
      padding: EdgeInsets.all(context.s(3)),
      decoration: BoxDecoration(
        color: context.colors.borderSubtle,
        borderRadius: BorderRadius.circular(context.s(10)),
      ),
      child: SizedBox(
        width: segW * 2,
        height: context.s(24),
        child: Stack(
          children: [
            AnimatedPositioned(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              top: 0,
              bottom: 0,
              left: view == _CalView.week ? 0 : segW,
              width: segW,
              child: Container(
                decoration: BoxDecoration(
                  color: context.colors.surface,
                  borderRadius: BorderRadius.circular(context.s(8)),
                ),
              ),
            ),
            Row(
              children: [
                SizedBox(
                  width: segW,
                  child: _segment(
                    context,
                    'WEEK',
                    view == _CalView.week,
                    () => onChanged(_CalView.week),
                  ),
                ),
                SizedBox(
                  width: segW,
                  child: _segment(
                    context,
                    'MONTH',
                    view == _CalView.month,
                    () => onChanged(_CalView.month),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _segment(
    BuildContext context,
    String label,
    bool active,
    VoidCallback onTap,
  ) {
    return GestureDetector(
      onTap: onTap,
      // Container below has no color/decoration, so without this the tap
      // target shrinks to the label's own text bounds instead of the
      // full segment (Flutter's default HitTestBehavior.deferToChild) —
      // most of the visible WEEK/MONTH segment would silently eat taps.
      behavior: HitTestBehavior.opaque,
      child: Container(
        alignment: Alignment.center,
        child: Text(
          label,
          style: AppTypography.monoLabel(context).copyWith(
            fontSize: context.s(10),
            color: active ? context.colors.ink : context.colors.inkMuted,
          ),
        ),
      ),
    );
  }
}

class _WeekView extends ConsumerWidget {
  const _WeekView({required this.referenceDate});
  final DateTime referenceDate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final firstWeekday =
        ref.watch(firstDayOfWeekProvider).value ?? DateTime.sunday;
    final weekStart = startOfWeek(referenceDate, firstWeekday);
    final weekEnd = weekStart.add(const Duration(days: 7));
    final days = List.generate(7, (i) => weekStart.add(Duration(days: i)));
    final today = _startOfDay(DateTime.now());

    final itemsAsync = ref.watch(
      itemsInRangeProvider((start: weekStart, end: weekEnd)),
    );
    final items = itemsAsync.value ?? const <ItemWithArea>[];

    final scheduled = items
        .where((i) => i.item.scheduledStart != null)
        .toList();
    final dueOnly = items
        .where((i) => i.item.scheduledStart == null && i.item.dueAt != null)
        .toList();

    var hourStart = 7;
    var hourEnd = 21;
    for (final iwa in scheduled) {
      final s = iwa.item.scheduledStart!;
      final e = iwa.item.scheduledEnd ?? s.add(const Duration(minutes: 30));
      if (s.hour < hourStart) hourStart = s.hour;
      final endHour = e.minute > 0 ? e.hour + 1 : e.hour;
      if (endHour > hourEnd) hourEnd = endHour;
    }
    final hourCount = hourEnd - hourStart;
    final hourHeight = context.s(56);
    const labelWidth = 30.0;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(width: context.s(labelWidth)),
              for (final day in days)
                Expanded(
                  child: Column(
                    children: [
                      Text(
                        _weekdayLetters[day.weekday - 1],
                        style: AppTypography.mono(context).copyWith(
                          fontSize: context.s(8.5),
                          color: context.colors.inkFainter,
                        ),
                      ),
                      SizedBox(height: context.s(3)),
                      Container(
                        margin: EdgeInsets.symmetric(horizontal: context.s(2)),
                        padding: EdgeInsets.symmetric(vertical: context.s(3)),
                        decoration: BoxDecoration(
                          color: _isSameDay(day, today)
                              ? context.colors.ink
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(context.s(7)),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          '${day.day}',
                          style: TextStyle(
                            fontFamily: AppTypography.monoFamily,
                            fontSize: context.s(12),
                            fontWeight: _isSameDay(day, today)
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: _isSameDay(day, today)
                                ? context.colors.surface
                                : context.colors.ink,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          SizedBox(height: context.s(6)),
          // Due-only items have no time slot (§3) — a compact all-day row
          // per day, above the timed grid, rather than a fabricated
          // position on it.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: context.s(labelWidth)),
              for (final day in days)
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: context.s(2)),
                    child: Column(
                      children: [
                        for (final iwa in dueOnly.where(
                          (i) => _isSameDay(i.item.dueAt!, day),
                        ))
                          GestureDetector(
                            onTap: () => showItemDetailSheetAndMaybeExport(
                              context,
                              ref,
                              iwa.item.id,
                            ),
                            child: Container(
                              width: double.infinity,
                              margin: EdgeInsets.only(bottom: context.s(2)),
                              padding: EdgeInsets.symmetric(
                                horizontal: context.s(4),
                                vertical: context.s(2),
                              ),
                              decoration: BoxDecoration(
                                color:
                                    (iwa.area != null
                                            ? colorFromHex(iwa.area!.color)
                                            : context.colors.inkDisabled)
                                        .withValues(alpha: 0.16),
                                borderRadius: BorderRadius.circular(
                                  context.s(4),
                                ),
                              ),
                              child: Text(
                                iwa.item.shortTitle ?? iwa.item.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: context.s(8.5),
                                  color: context.colors.ink,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          SizedBox(height: context.s(6)),
          SizedBox(
            height: hourHeight * hourCount,
            child: Stack(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: context.s(labelWidth),
                      child: Column(
                        children: List.generate(
                          hourCount,
                          (i) => SizedBox(
                            height: hourHeight,
                            child: Padding(
                              padding: EdgeInsets.only(top: context.s(2)),
                              child: Text(
                                '${(hourStart + i).toString().padLeft(2, '0')}:00',
                                style: AppTypography.mono(context).copyWith(
                                  fontSize: context.s(8),
                                  color: context.colors.inkMuted,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    for (final day in days)
                      Expanded(
                        child: SizedBox(
                          height: hourHeight * hourCount,
                          child: Stack(
                            children: [
                              Column(
                                children: List.generate(
                                  hourCount,
                                  (i) => Container(
                                    height: hourHeight,
                                    decoration: BoxDecoration(
                                      border: Border(
                                        left: BorderSide(
                                          color: context.colors.borderSubtle,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              for (final iwa in scheduled.where(
                                (i) => _isSameDay(i.item.scheduledStart!, day),
                              ))
                                _ScheduledBlock(
                                  itemWithArea: iwa,
                                  hourStart: hourStart,
                                  hourHeight: hourHeight,
                                  onTap: () => showItemDetailSheetAndMaybeExport(
                                    context,
                                    ref,
                                    iwa.item.id,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
                if (today.isAfter(
                      weekStart.subtract(const Duration(seconds: 1)),
                    ) &&
                    today.isBefore(weekEnd))
                  _CurrentTimeLine(
                    hourStart: hourStart,
                    hourEnd: hourEnd,
                    hourHeight: hourHeight,
                    labelWidth: context.s(labelWidth),
                  ),
              ],
            ),
          ),
          SizedBox(height: context.s(24)),
        ],
      ),
    );
  }
}

class _ScheduledBlock extends StatelessWidget {
  const _ScheduledBlock({
    required this.itemWithArea,
    required this.hourStart,
    required this.hourHeight,
    required this.onTap,
  });
  final ItemWithArea itemWithArea;
  final int hourStart;
  final double hourHeight;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final item = itemWithArea.item;
    final start = item.scheduledStart!;
    final end = item.scheduledEnd ?? start.add(const Duration(minutes: 30));
    final startMinutes = (start.hour - hourStart) * 60 + start.minute;
    final durationMinutes = end.difference(start).inMinutes.clamp(15, 24 * 60);
    final top = startMinutes / 60 * hourHeight;
    final height = (durationMinutes / 60 * hourHeight).clamp(
      context.s(16),
      double.infinity,
    );
    final color = itemWithArea.area != null
        ? colorFromHex(itemWithArea.area!.color)
        : context.colors.inkDisabled;
    final done = item.status.name == 'done';

    return Positioned(
      top: top,
      left: context.s(2),
      right: context.s(2),
      height: height,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: context.s(3),
            vertical: context.s(2),
          ),
          decoration: BoxDecoration(
            color: color.withValues(alpha: done ? 0.5 : 1),
            borderRadius: BorderRadius.circular(context.s(4)),
          ),
          child: Text(
            item.shortTitle ?? item.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: AppTypography.monoFamily,
              fontSize: context.s(8),
              color: context.colors.surface,
              decoration: done
                  ? TextDecoration.lineThrough
                  : TextDecoration.none,
            ),
          ),
        ),
      ),
    );
  }
}

class _CurrentTimeLine extends StatelessWidget {
  const _CurrentTimeLine({
    required this.hourStart,
    required this.hourEnd,
    required this.hourHeight,
    required this.labelWidth,
  });
  final int hourStart;
  final int hourEnd;
  final double hourHeight;
  final double labelWidth;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    if (now.hour < hourStart || now.hour >= hourEnd)
      return const SizedBox.shrink();
    final minutesFromStart = (now.hour - hourStart) * 60 + now.minute;
    final top = minutesFromStart / 60 * hourHeight;

    return Positioned(
      top: top,
      left: labelWidth,
      right: 0,
      child: Container(
        height: 1.5,
        color: context.colors.accent,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Transform.translate(
            offset: Offset(-context.s(3), 0),
            child: Container(
              width: context.s(6),
              height: context.s(6),
              decoration: BoxDecoration(
                color: context.colors.accent,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MonthView extends ConsumerWidget {
  const _MonthView({
    required this.referenceDate,
    required this.selectedDay,
    required this.onSelectDay,
  });
  final DateTime referenceDate;
  final DateTime selectedDay;
  final ValueChanged<DateTime> onSelectDay;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final firstWeekday =
        ref.watch(firstDayOfWeekProvider).value ?? DateTime.sunday;
    final monthStart = DateTime(referenceDate.year, referenceDate.month, 1);
    final daysInMonth = DateTime(
      referenceDate.year,
      referenceDate.month + 1,
      0,
    ).day;
    final leadingBlanks = (monthStart.weekday - firstWeekday + 7) % 7;
    final totalCells = ((leadingBlanks + daysInMonth + 6) ~/ 7) * 7;
    final gridStart = monthStart.subtract(Duration(days: leadingBlanks));
    final gridEnd = gridStart.add(Duration(days: totalCells));
    final today = _startOfDay(DateTime.now());

    final itemsAsync = ref.watch(
      itemsInRangeProvider((start: gridStart, end: gridEnd)),
    );
    final items = itemsAsync.value ?? const <ItemWithArea>[];
    final externalEvents =
        ref
            .watch(
              externalEventsInRangeProvider((start: gridStart, end: gridEnd)),
            )
            .value ??
        const <ExternalEvent>[];

    List<Color> dotsFor(DateTime day) {
      final colors = <Color>{};
      for (final iwa in items) {
        final s = iwa.item.scheduledStart;
        final d = iwa.item.dueAt;
        final matches =
            (s != null && _isSameDay(s, day)) ||
            (d != null && _isSameDay(d, day));
        if (matches) {
          colors.add(
            iwa.area != null
                ? colorFromHex(iwa.area!.color)
                : context.colors.inkDisabled,
          );
        }
      }
      if (externalEvents.any((e) => _isSameDay(e.start, day))) {
        colors.add(_externalEventColor);
      }
      return colors.take(4).toList();
    }

    final dayItems =
        items
            .where(
              (iwa) =>
                  (iwa.item.scheduledStart != null &&
                      _isSameDay(iwa.item.scheduledStart!, selectedDay)) ||
                  (iwa.item.dueAt != null &&
                      _isSameDay(iwa.item.dueAt!, selectedDay)),
            )
            .toList()
          ..sort((a, b) {
            final aTime = a.item.scheduledStart ?? a.item.dueAt!;
            final bTime = b.item.scheduledStart ?? b.item.dueAt!;
            return aTime.compareTo(bTime);
          });
    final dayExternalEvents = externalEvents
        .where((e) => _isSameDay(e.start, selectedDay))
        .toList();

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              for (final letter in _weekdayLettersFrom(firstWeekday))
                Expanded(
                  child: Center(
                    child: Text(
                      letter,
                      style: AppTypography.mono(context).copyWith(
                        fontSize: context.s(8.5),
                        color: context.colors.inkFainter,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          SizedBox(height: context.s(6)),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: totalCells,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
            ),
            itemBuilder: (context, i) {
              final day = gridStart.add(Duration(days: i));
              final inMonth = day.month == monthStart.month;
              final isSelected = _isSameDay(day, selectedDay);
              final isToday = _isSameDay(day, today);
              final dots = inMonth ? dotsFor(day) : const <Color>[];

              return Padding(
                padding: EdgeInsets.all(context.s(1.5)),
                child: GestureDetector(
                  onTap: () => onSelectDay(day),
                  child: Container(
                    decoration: BoxDecoration(
                      color: isSelected
                          ? context.colors.ink
                          : (inMonth
                                ? context.colors.surface
                                : Colors.transparent),
                      border: !isSelected && isToday
                          ? Border.all(color: context.colors.accent)
                          : Border.all(color: Colors.transparent),
                      borderRadius: BorderRadius.circular(context.s(8)),
                    ),
                    padding: EdgeInsets.symmetric(vertical: context.s(4)),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          '${day.day}',
                          style: TextStyle(
                            fontFamily: AppTypography.monoFamily,
                            fontSize: context.s(11),
                            color: isSelected
                                ? context.colors.surface
                                : (inMonth
                                      ? context.colors.ink
                                      : context.colors.inkDisabled),
                          ),
                        ),
                        SizedBox(height: context.s(3)),
                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: context.s(2),
                          children: [
                            for (final c in dots)
                              Container(
                                width: context.s(4),
                                height: context.s(4),
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? context.colors.surface
                                      : c,
                                  shape: BoxShape.circle,
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
          SizedBox(height: context.s(16)),
          Text(
            '${_monthNamesShort[selectedDay.month - 1]} ${selectedDay.day} · '
            '${dayItems.length + dayExternalEvents.length} '
            '${dayItems.length + dayExternalEvents.length == 1 ? 'ITEM' : 'ITEMS'}',
            style: AppTypography.monoLabel(
              context,
            ).copyWith(fontSize: context.s(9.5), letterSpacing: context.s(1.2)),
          ),
          SizedBox(height: context.s(8)),
          for (final event in dayExternalEvents)
            _DayExternalEventRow(event: event),
          for (final iwa in dayItems)
            _DayItemRow(
              itemWithArea: iwa,
              onTap: () =>
                  showItemDetailSheetAndMaybeExport(context, ref, iwa.item.id),
            ),
          SizedBox(height: context.s(24)),
        ],
      ),
    );
  }
}

/// A read-only row for an imported Google Calendar event (§9), same shape
/// as `_DayItemRow` but with no status/completion concept and the
/// distinct external-event color instead of an area color.
class _DayExternalEventRow extends StatelessWidget {
  const _DayExternalEventRow({required this.event});
  final ExternalEvent event;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(vertical: context.s(9)),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: context.colors.borderSubtle)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: context.s(38),
            child: Text(
              timeLabel(event.start),
              style: AppTypography.mono(
                context,
              ).copyWith(fontSize: context.s(10.5)),
            ),
          ),
          Container(
            width: context.s(2),
            height: context.s(16),
            color: _externalEventColor,
          ),
          SizedBox(width: context.s(10)),
          Expanded(
            child: Text(
              event.title,
              style: TextStyle(
                fontSize: context.s(14),
                color: context.colors.inkMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DayItemRow extends StatelessWidget {
  const _DayItemRow({required this.itemWithArea, required this.onTap});
  final ItemWithArea itemWithArea;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final item = itemWithArea.item;
    final done = item.status.name == 'done';
    final color = itemWithArea.area != null
        ? colorFromHex(itemWithArea.area!.color)
        : context.colors.inkDisabled;
    final label = item.scheduledStart != null
        ? timeLabel(item.scheduledStart!)
        : (dueTimeLabel(item.dueAt!) ?? '—');

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: EdgeInsets.symmetric(vertical: context.s(9)),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: context.colors.borderSubtle),
          ),
        ),
        child: Row(
          children: [
            SizedBox(
              width: context.s(38),
              child: Text(
                label,
                style: AppTypography.mono(
                  context,
                ).copyWith(fontSize: context.s(10.5)),
              ),
            ),
            Container(
              width: context.s(2),
              height: context.s(16),
              color: color,
            ),
            SizedBox(width: context.s(10)),
            Expanded(
              child: Text(
                item.shortTitle ?? item.title,
                style: TextStyle(
                  fontSize: context.s(14),
                  color: done
                      ? context.colors.inkDisabled
                      : context.colors.ink,
                  decoration: done
                      ? TextDecoration.lineThrough
                      : TextDecoration.none,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
