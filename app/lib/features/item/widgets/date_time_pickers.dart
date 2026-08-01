import 'package:flutter/material.dart';

import '../../../app/theme.dart';

/// Shared between quick-add and the Item Detail sheet — both need the
/// same Deadline/Time-block toggle, calendar, and time-wheel pickers.
/// Extracted out of quick_add_sheet.dart's private scope rather than
/// duplicated.
enum ItemDateKind { due, sched }

const monthNames = [
  'JANUARY',
  'FEBRUARY',
  'MARCH',
  'APRIL',
  'MAY',
  'JUNE',
  'JULY',
  'AUGUST',
  'SEPTEMBER',
  'OCTOBER',
  'NOVEMBER',
  'DECEMBER',
];
const _weekdayHeaders = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

String pad2(int n) => n < 10 ? '0$n' : '$n';
int roundToStep(int value, int step) =>
    ((value + step ~/ 2) ~/ step * step) % 60;

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

class KindToggle extends StatelessWidget {
  const KindToggle({super.key, required this.kind, required this.onChanged});
  final ItemDateKind kind;
  final ValueChanged<ItemDateKind> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(context.s(3)),
      decoration: BoxDecoration(
        color: context.colors.borderFaint,
        borderRadius: BorderRadius.circular(context.s(12)),
      ),
      // LayoutBuilder gives the exact resolved width of this row (bounded
      // by the sheet's width, since Expanded below already fills it) —
      // used to slide the highlight by a known pixel amount via
      // Positioned. Deliberately not a bare Align/AnimatedAlign here: one
      // without a widthFactor expands to fill any loose-but-bounded
      // constraint it's given rather than wrapping its child, which is
      // exactly the bug that made the bottom nav swallow the whole
      // screen earlier this session.
      child: LayoutBuilder(
        builder: (context, constraints) {
          final segmentWidth = constraints.maxWidth / 2;
          return Stack(
            children: [
              AnimatedPositioned(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                top: 0,
                bottom: 0,
                left: kind == ItemDateKind.due ? 0 : segmentWidth,
                width: segmentWidth,
                child: Container(
                  decoration: BoxDecoration(
                    color: context.colors.surface,
                    borderRadius: BorderRadius.circular(context.s(9)),
                  ),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: _segment(
                      context,
                      'Deadline',
                      kind == ItemDateKind.due,
                      () => onChanged(ItemDateKind.due),
                    ),
                  ),
                  Expanded(
                    child: _segment(
                      context,
                      'Time block',
                      kind == ItemDateKind.sched,
                      () => onChanged(ItemDateKind.sched),
                    ),
                  ),
                ],
              ),
            ],
          );
        },
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
      // full half-width segment (Flutter's default HitTestBehavior.
      // deferToChild) — most of the visible segment would silently eat taps.
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: EdgeInsets.symmetric(vertical: context.s(9)),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontFamily: AppTypography.sansFamily,
            fontSize: context.s(13),
            fontWeight: FontWeight.w600,
            color: active ? context.colors.ink : context.colors.inkFaint,
          ),
        ),
      ),
    );
  }
}

class MonthCalendar extends StatelessWidget {
  const MonthCalendar({
    super.key,
    required this.month,
    required this.selected,
    required this.onPrevMonth,
    required this.onNextMonth,
    required this.onPick,
  });
  final DateTime month;
  final DateTime selected;
  final VoidCallback onPrevMonth;
  final VoidCallback onNextMonth;
  final ValueChanged<DateTime> onPick;

  @override
  Widget build(BuildContext context) {
    final firstWeekday = DateTime(
      month.year,
      month.month,
      1,
    ).weekday; // 1=Mon..7=Sun
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final leadingBlanks = firstWeekday - 1;
    final today = _dateOnly(DateTime.now());
    // Due/scheduled dates are never in the past (§4/§5 — a task manager's
    // dates are forward-looking; nothing reads or writes a backdated item
    // on purpose). Enforced here, not just at save time, so it can't be
    // picked in the first place.
    final atCurrentMonth =
        month.year == today.year && month.month == today.month;

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            GestureDetector(
              onTap: atCurrentMonth ? null : onPrevMonth,
              child: Icon(
                Icons.chevron_left,
                size: context.s(20),
                color: atCurrentMonth
                    ? context.colors.inkDisabled
                    : context.colors.inkMuted,
              ),
            ),
            Text(
              '${monthNames[month.month - 1]} ${month.year}',
              style: AppTypography.mono(context).copyWith(
                fontSize: context.s(10.5),
                letterSpacing: context.s(1.4),
                color: context.colors.ink,
              ),
            ),
            GestureDetector(
              onTap: onNextMonth,
              child: Icon(
                Icons.chevron_right,
                size: context.s(20),
                color: context.colors.inkMuted,
              ),
            ),
          ],
        ),
        SizedBox(height: context.s(6)),
        Row(
          children: [
            for (final h in _weekdayHeaders)
              Expanded(
                child: Center(
                  child: Text(
                    h,
                    style: AppTypography.mono(context).copyWith(
                      fontSize: context.s(8),
                      color: context.colors.inkDisabled,
                    ),
                  ),
                ),
              ),
          ],
        ),
        SizedBox(height: context.s(3)),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: 35,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 7,
          ),
          itemBuilder: (context, i) {
            final dayNum = i - leadingBlanks + 1;
            final inMonth = dayNum >= 1 && dayNum <= daysInMonth;
            if (!inMonth) return const SizedBox.shrink();
            final date = DateTime(month.year, month.month, dayNum);
            final isSelected = date == selected;
            final isToday = date == today;
            final isPast = date.isBefore(today);
            return Padding(
              padding: EdgeInsets.all(context.s(1)),
              child: GestureDetector(
                onTap: isPast ? null : () => onPick(date),
                child: Container(
                  decoration: BoxDecoration(
                    color: isSelected ? context.colors.ink : Colors.transparent,
                    borderRadius: BorderRadius.circular(context.s(8)),
                    border: !isSelected && isToday
                        ? Border.all(color: context.colors.border)
                        : null,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '$dayNum',
                    style: AppTypography.mono(context).copyWith(
                      fontSize: context.s(11),
                      color: isSelected
                          ? context.colors.surface
                          : isPast
                          ? context.colors.inkDisabled
                          : context.colors.ink,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

class TimeWheelPair extends StatelessWidget {
  const TimeWheelPair({
    super.key,
    required this.hour,
    required this.minute,
    required this.onHourChanged,
    required this.onMinuteChanged,
  });
  final int hour;
  final int minute;
  final ValueChanged<int> onHourChanged;
  final ValueChanged<int> onMinuteChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: context.s(4)),
      decoration: BoxDecoration(
        color: context.colors.surface,
        border: Border.all(color: context.colors.border),
        borderRadius: BorderRadius.circular(context.s(12)),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned(
            left: context.s(4),
            right: context.s(4),
            child: Container(
              height: context.s(28),
              decoration: BoxDecoration(
                color: context.colors.accent.withValues(alpha: 0.09),
                borderRadius: BorderRadius.circular(context.s(8)),
              ),
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _WheelColumn(
                values: List.generate(24, (i) => i),
                selected: hour,
                onChanged: onHourChanged,
              ),
              Text(
                ':',
                style: TextStyle(
                  fontFamily: AppTypography.monoFamily,
                  fontSize: context.s(17),
                  color: context.colors.inkDisabled,
                ),
              ),
              _WheelColumn(
                values: List.generate(12, (i) => i * 5),
                selected: minute,
                onChanged: onMinuteChanged,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _WheelColumn extends StatefulWidget {
  const _WheelColumn({
    required this.values,
    required this.selected,
    required this.onChanged,
  });
  final List<int> values;
  final int selected;
  final ValueChanged<int> onChanged;

  @override
  State<_WheelColumn> createState() => _WheelColumnState();
}

class _WheelColumnState extends State<_WheelColumn> {
  late FixedExtentScrollController _controller;
  late int _index;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _index = widget.values.indexOf(widget.selected);
    if (_index < 0) _index = 0;
    _controller = FixedExtentScrollController(initialItem: _index);
  }

  @override
  void didUpdateWidget(covariant _WheelColumn oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newIndex = widget.values.indexOf(widget.selected);
    if (newIndex >= 0 &&
        newIndex != _index &&
        !_controller.position.isScrollingNotifier.value) {
      _index = newIndex;
      _controller.jumpToItem(newIndex);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: context.s(46),
      height: context.s(84),
      // Only the local index updates (setState here) while the wheel is
      // actively scrolling — cheap, scoped to this small column. The
      // parent-level widget.onChanged (which rebuilds whatever contains
      // this) fires once, on ScrollEndNotification, instead of on every
      // tick. Firing it per tick was the main cause of dropped frames
      // while dragging the hour/minute wheels — confirmed via on-device
      // profiling.
      child: NotificationListener<ScrollEndNotification>(
        onNotification: (notification) {
          if (_dirty) {
            _dirty = false;
            widget.onChanged(widget.values[_index]);
          }
          return false;
        },
        child: ListWheelScrollView.useDelegate(
          controller: _controller,
          itemExtent: context.s(28),
          perspective: 0.003,
          diameterRatio: 1.4,
          physics: const FixedExtentScrollPhysics(),
          onSelectedItemChanged: (i) => setState(() {
            _index = i;
            _dirty = true;
          }),
          childDelegate: ListWheelChildBuilderDelegate(
            childCount: widget.values.length,
            builder: (context, i) {
              final active = i == _index;
              return Center(
                child: Text(
                  pad2(widget.values[i]),
                  style: TextStyle(
                    fontFamily: AppTypography.monoFamily,
                    fontSize: context.s(19),
                    fontWeight: FontWeight.w600,
                    color: active
                        ? context.colors.ink
                        : context.colors.inkFaint,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class RepeatChip extends StatelessWidget {
  const RepeatChip({
    super.key,
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
        padding: EdgeInsets.symmetric(
          horizontal: context.s(11),
          vertical: context.s(7),
        ),
        decoration: BoxDecoration(
          color: active ? context.colors.ink : context.colors.surface,
          border: Border.all(
            color: active ? context.colors.ink : context.colors.border,
          ),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: AppTypography.monoLabel(context).copyWith(
            fontSize: context.s(10),
            color: active ? context.colors.surface : context.colors.inkMuted,
          ),
        ),
      ),
    );
  }
}
