import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import 'date_time_pickers.dart' show RepeatChip;

enum _ReminderUnit { hours, days, weeks }

const _unitMinutes = {
  _ReminderUnit.hours: 60,
  _ReminderUnit.days: 1440,
  _ReminderUnit.weeks: 10080,
};

const _unitLabels = {
  _ReminderUnit.hours: 'HOURS',
  _ReminderUnit.days: 'DAYS',
  _ReminderUnit.weeks: 'WEEKS',
};

/// Reminder lead-time picker (§7/§11): a quantity + unit (hours/days/weeks)
/// instead of a fixed handful of presets, capped at one month
/// ([maxMinutes]) — matches Google Calendar's own reminder picker shape.
/// Shared between Item Detail and Quick Add, same as the date/time
/// pickers in `date_time_pickers.dart`.
class ReminderOffsetPicker extends StatefulWidget {
  const ReminderOffsetPicker({
    super.key,
    required this.minutes,
    required this.onChanged,
  });

  /// Current value in minutes; `-1` means off.
  final int minutes;
  final ValueChanged<int> onChanged;

  /// One month, expressed as 30 days — there's no fixed minute count for
  /// "a month", so this uses the same round-number convention as the
  /// recurrence horizon (`_recurrenceHorizonDays`).
  static const maxMinutes = 43200;

  @override
  State<ReminderOffsetPicker> createState() => _ReminderOffsetPickerState();
}

class _ReminderOffsetPickerState extends State<ReminderOffsetPicker> {
  late bool _off;
  late _ReminderUnit _unit;
  late int _quantity;

  @override
  void initState() {
    super.initState();
    _syncFromMinutes(widget.minutes);
  }

  @override
  void didUpdateWidget(covariant ReminderOffsetPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.minutes != widget.minutes) _syncFromMinutes(widget.minutes);
  }

  /// Picks the coarsest unit that divides [minutes] evenly, so a value
  /// this picker itself produced round-trips back to the same
  /// quantity/unit instead of collapsing to hours every time.
  void _syncFromMinutes(int minutes) {
    if (minutes <= 0) {
      _off = true;
      _unit = _ReminderUnit.hours;
      _quantity = 1;
      return;
    }
    _off = false;
    if (minutes % _unitMinutes[_ReminderUnit.weeks]! == 0) {
      _unit = _ReminderUnit.weeks;
    } else if (minutes % _unitMinutes[_ReminderUnit.days]! == 0) {
      _unit = _ReminderUnit.days;
    } else {
      _unit = _ReminderUnit.hours;
    }
    _quantity = (minutes / _unitMinutes[_unit]!).round().clamp(
      1,
      _maxQuantity(_unit),
    );
  }

  int _maxQuantity(_ReminderUnit unit) =>
      (ReminderOffsetPicker.maxMinutes / _unitMinutes[unit]!).floor();

  void _emit() {
    widget.onChanged(_off ? -1 : _quantity * _unitMinutes[_unit]!);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: context.s(6),
          runSpacing: context.s(6),
          children: [
            RepeatChip(
              label: 'OFF',
              active: _off,
              onTap: () => setState(() {
                _off = true;
                _emit();
              }),
            ),
            RepeatChip(
              label: 'BEFORE',
              active: !_off,
              onTap: () => setState(() {
                _off = false;
                _emit();
              }),
            ),
          ],
        ),
        if (!_off) ...[
          SizedBox(height: context.s(8)),
          Row(
            children: [
              _StepButton(
                icon: Icons.remove,
                onTap: _quantity > 1
                    ? () => setState(() {
                        _quantity--;
                        _emit();
                      })
                    : null,
              ),
              SizedBox(width: context.s(10)),
              SizedBox(
                width: context.s(28),
                child: Text(
                  '$_quantity',
                  textAlign: TextAlign.center,
                  style: AppTypography.monoLabel(
                    context,
                  ).copyWith(fontSize: context.s(14)),
                ),
              ),
              SizedBox(width: context.s(10)),
              _StepButton(
                icon: Icons.add,
                onTap: _quantity < _maxQuantity(_unit)
                    ? () => setState(() {
                        _quantity++;
                        _emit();
                      })
                    : null,
              ),
              SizedBox(width: context.s(14)),
              Expanded(
                child: Wrap(
                  spacing: context.s(6),
                  runSpacing: context.s(6),
                  children: [
                    for (final unit in _ReminderUnit.values)
                      RepeatChip(
                        label: _unitLabels[unit]!,
                        active: _unit == unit,
                        onTap: () => setState(() {
                          _unit = unit;
                          _quantity = _quantity.clamp(1, _maxQuantity(unit));
                          _emit();
                        }),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: context.s(28),
        height: context.s(28),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: context.colors.surface,
          border: Border.all(color: context.colors.border),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Icon(
          icon,
          size: context.s(16),
          color: onTap != null ? context.colors.ink : context.colors.inkMuted,
        ),
      ),
    );
  }
}
