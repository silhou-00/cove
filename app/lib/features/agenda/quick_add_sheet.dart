import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/db/database.dart' show Area, Item;
import '../../domain/services/quick_add_parser.dart';
import '../item/widgets/date_time_pickers.dart';

DateTime _startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);

/// Highlights `@area`/`#tag`/`!priority` tokens inline as you type, the
/// same tint-per-kind used by the chips below the field.
class _HighlightingController extends TextEditingController {
  static final _tokenRe = RegExp(
    r'@[\w-]+|#[\w-]+|!(?:high|h|med|medium|m|low|l)\b',
    caseSensitive: false,
  );

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final spans = <TextSpan>[];
    var last = 0;
    for (final match in _tokenRe.allMatches(text)) {
      if (match.start > last) {
        spans.add(
          TextSpan(text: text.substring(last, match.start), style: style),
        );
      }
      final token = match.group(0)!;
      final Color bg;
      final Color ink;
      if (token.startsWith('@')) {
        bg = const Color(0xFF3F6F6A);
        ink = const Color(0xFF2F5450);
      } else if (token.startsWith('#')) {
        bg = const Color(0xFF4A5A70);
        ink = const Color(0xFF3A4759);
      } else {
        bg = const Color(0xFFA4543A);
        ink = const Color(0xFF8C4229);
      }
      spans.add(
        TextSpan(
          text: token,
          style: style?.copyWith(
            backgroundColor: bg.withValues(alpha: 0.16),
            color: ink,
          ),
        ),
      );
      last = match.end;
    }
    if (last < text.length) {
      spans.add(TextSpan(text: text.substring(last), style: style));
    }
    return TextSpan(children: spans, style: style);
  }
}

/// The full capture sheet (§4): free text for `@area`/`#tag`/`!priority`,
/// plus tap controls for date/time/recurrence. Typed date/time phrases
/// (still fully parsed by `QuickAddParser` from step 2 — the ten worked
/// examples all still pass) pre-fill the pickers below, live, as you type —
/// but the moment you touch a picker yourself, typing no longer overwrites
/// it. That avoids the picker fighting your manual choice.
/// Returns the created [Item], or `null` if the sheet was dismissed
/// without saving — the caller uses this to run the Calendar export
/// trigger (§9) with its own long-lived context, once the sheet's own
/// (short-lived, about to pop) context isn't the right one to show a
/// prompt from.
Future<Item?> showQuickAddSheet(BuildContext context) {
  return showModalBottomSheet<Item>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.colors.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(context.s(24))),
    ),
    builder: (context) => const QuickAddSheet(),
  );
}

class QuickAddSheet extends ConsumerStatefulWidget {
  const QuickAddSheet({super.key});

  @override
  ConsumerState<QuickAddSheet> createState() => _QuickAddSheetState();
}

class _QuickAddSheetState extends ConsumerState<QuickAddSheet> {
  final _controller = _HighlightingController();
  final _focusNode = FocusNode();
  final _notesController = TextEditingController();
  static const _parser = QuickAddParser();

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
  bool _dateTouchedManually = false;
  String? _timeError;

  static const _reminderOffsetOptions = [60, 300, 1440, -1];

  static String _reminderOffsetLabel(int minutes) => switch (minutes) {
    -1 => 'OFF',
    60 => '1 HOUR',
    300 => '5 HOURS',
    1440 => '1 DAY',
    final m => '$m MIN',
  };

  @override
  void initState() {
    super.initState();
    final now = _startOfDay(DateTime.now());
    _selectedDate = now;
    _calendarMonth = DateTime(now.year, now.month);
    // No auto-focus — the keyboard only opens once the user taps the
    // title field themselves, not the moment this sheet appears.
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _notesController.dispose();
    super.dispose();
  }

  void _onDraftChanged(QuickAddResult result) {
    if (_dateTouchedManually) return;
    setState(() {
      if (result.scheduledStart != null) {
        _kind = ItemDateKind.sched;
        _selectedDate = _startOfDay(result.scheduledStart!);
        _hour = result.scheduledStart!.hour;
        _minute = roundToStep(result.scheduledStart!.minute, 5);
        if (result.scheduledEnd != null) {
          _endHour = result.scheduledEnd!.hour;
          _endMinute = roundToStep(result.scheduledEnd!.minute, 5);
        } else {
          final endTotal = (_hour * 60 + _minute + 60) % (24 * 60);
          _endHour = endTotal ~/ 60;
          _endMinute = endTotal % 60;
        }
      } else if (result.dueAt != null) {
        _kind = ItemDateKind.due;
        _selectedDate = _startOfDay(result.dueAt!);
        final isEndOfDay =
            result.dueAt!.hour == 23 && result.dueAt!.minute == 59;
        _noTime = isEndOfDay;
        if (!isEndOfDay) {
          _hour = result.dueAt!.hour;
          _minute = roundToStep(result.dueAt!.minute, 5);
        }
      } else {
        _kind = ItemDateKind.due;
        _selectedDate = _startOfDay(DateTime.now());
        _noTime = true;
      }
      if (result.recurrenceRule == 'FREQ=DAILY') {
        _repeat = 'DAILY';
      } else if (result.recurrenceRule?.startsWith(
            'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR',
          ) ==
          true) {
        _repeat = 'WEEKDAYS';
      } else if (result.recurrenceRule?.startsWith('FREQ=WEEKLY') == true) {
        _repeat = 'WEEKLY';
      } else {
        _repeat = 'NONE';
      }
    });
  }

  void _markTouched(VoidCallback change) => setState(() {
    _dateTouchedManually = true;
    _timeError = null;
    change();
  });

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

  Future<void> _save(List<Area> areas) async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    final result = _parser.parse(
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

    final notes = _notesController.text.trim();
    final item = await ref
        .read(itemRepositoryProvider)
        .create(
          areaId: matchedArea?.id,
          title: result.title,
          notes: notes.isEmpty ? null : notes,
          priority: result.priority,
          dueAt: dueAt,
          scheduledStart: scheduledStart,
          scheduledEnd: scheduledEnd,
          recurrenceRule: _recurrenceRule(),
          reminderOffsetMinutes: _reminderOffsetMinutes,
          tags: result.tags,
        );
    if (mounted) Navigator.of(context).pop(item);
  }

  @override
  Widget build(BuildContext context) {
    final areas = ref.watch(activeAreasProvider).value ?? const <Area>[];
    final result = _parser.parse(
      _controller.text,
      now: DateTime.now(),
      areaNames: areas.map((a) => a.name).toList(),
    );

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
          maxHeight: MediaQuery.of(context).size.height * 0.85,
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
                    TextField(
                      controller: _controller,
                      focusNode: _focusNode,
                      style: TextStyle(
                        fontFamily: AppTypography.monoFamily,
                        fontSize: context.s(14),
                        color: context.colors.ink,
                      ),
                      decoration: InputDecoration(
                        hintText: 'lab report @school !high',
                        hintStyle: TextStyle(color: context.colors.inkDisabled),
                        border: UnderlineInputBorder(
                          borderSide: BorderSide(
                            color: context.colors.ink,
                            width: 1.5,
                          ),
                        ),
                        enabledBorder: UnderlineInputBorder(
                          borderSide: BorderSide(
                            color: context.colors.ink,
                            width: 1.5,
                          ),
                        ),
                        focusedBorder: UnderlineInputBorder(
                          borderSide: BorderSide(
                            color: context.colors.ink,
                            width: 1.5,
                          ),
                        ),
                      ),
                      onChanged: (_) {
                        final r = _parser.parse(
                          _controller.text,
                          now: DateTime.now(),
                          areaNames: areas.map((a) => a.name).toList(),
                        );
                        _onDraftChanged(r);
                      },
                    ),
                    SizedBox(height: context.s(12)),
                    Wrap(
                      spacing: context.s(6),
                      runSpacing: context.s(6),
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (result.areaName != null)
                          _Chip(kind: 'AREA', label: result.areaName!),
                        for (final tag in result.tags)
                          _Chip(kind: 'TAG', label: tag),
                        if (result.priority != null)
                          _Chip(kind: 'PRIORITY', label: result.priority!.name),
                        Text(
                          '@area · #tag · !high',
                          style: AppTypography.monoLabel(
                            context,
                          ).copyWith(fontSize: context.s(9.5)),
                        ),
                      ],
                    ),
                    SizedBox(height: context.s(14)),
                    KindToggle(
                      kind: _kind,
                      onChanged: (k) => _markTouched(() {
                        _kind = k;
                        if (k == ItemDateKind.sched) _noTime = false;
                      }),
                    ),
                    SizedBox(height: context.s(8)),
                    Text(
                      _kind == ItemDateKind.due
                          ? 'A date it must be finished by. No slot is held in the day.'
                          : 'A slot held in the day, start and end. It shows up on the calendar.',
                      style: AppTypography.secondaryMeta(
                        context,
                      ).copyWith(fontSize: context.s(12)),
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
                        onPick: (day) => _markTouched(() {
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
                            onHourChanged: (h) => _markTouched(() {
                              _hour = h;
                              _noTime = false;
                            }),
                            onMinuteChanged: (m) => _markTouched(() {
                              _minute = m;
                              _noTime = false;
                            }),
                          ),
                          SizedBox(width: context.s(14)),
                          Expanded(
                            child: GestureDetector(
                              onTap: () =>
                                  _markTouched(() => _noTime = !_noTime),
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
                                  onHourChanged: (h) =>
                                      _markTouched(() => _hour = h),
                                  onMinuteChanged: (m) =>
                                      _markTouched(() => _minute = m),
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
                                  onHourChanged: (h) =>
                                      _markTouched(() => _endHour = h),
                                  onMinuteChanged: (m) =>
                                      _markTouched(() => _endMinute = m),
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
                            onTap: () => _markTouched(() => _repeat = option),
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
                    SizedBox(height: context.s(14)),
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
                    SizedBox(height: context.s(14)),
                    Container(
                      padding: EdgeInsets.all(context.s(12)),
                      decoration: BoxDecoration(
                        color: context.colors.background,
                        border: Border.all(color: context.colors.borderFaint),
                        borderRadius: BorderRadius.circular(context.s(12)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'WILL SAVE AS',
                            style: AppTypography.monoLabel(context).copyWith(
                              fontSize: context.s(9),
                              letterSpacing: context.s(1.2),
                            ),
                          ),
                          SizedBox(height: context.s(5)),
                          Text(
                            result.title,
                            style: TextStyle(
                              fontFamily: AppTypography.sansFamily,
                              fontSize: context.s(15),
                              fontWeight: FontWeight.w600,
                              color: context.colors.ink,
                            ),
                          ),
                          SizedBox(height: context.s(4)),
                          Text(
                            _summaryLine(),
                            style: AppTypography.mono(context).copyWith(
                              fontSize: context.s(10.5),
                              color: context.colors.accent,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(height: context.s(14)),
            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () => _save(areas),
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

  String _summaryLine() {
    final date = _formatDate(_selectedDate);
    final repeatSuffix = _repeat == 'NONE' ? '' : ' · REPEATS $_repeat';
    if (_kind == ItemDateKind.sched) {
      return 'BLOCK · $date · ${pad2(_hour)}:${pad2(_minute)} — ${pad2(_endHour)}:${pad2(_endMinute)}$repeatSuffix';
    }
    final time = _noTime ? 'END OF DAY' : '${pad2(_hour)}:${pad2(_minute)}';
    return 'DUE · $date · $time$repeatSuffix';
  }
}

/// Translucent per-kind tint (§4's capture sheet: teal for area, slate for
/// tag, clay for priority) — distinct enough to read at a glance, unlike a
/// single flat neutral pill for every kind.
class _Chip extends StatelessWidget {
  const _Chip({required this.kind, required this.label});
  final String kind;
  final String label;

  static const _tints = {
    'AREA': Color(0xFF3F6F6A),
    'TAG': Color(0xFF4A5A70),
    'PRIORITY': Color(0xFFA4543A),
  };
  static const _inks = {
    'AREA': Color(0xFF2F5450),
    'TAG': Color(0xFF3A4759),
    'PRIORITY': Color(0xFF8C4229),
  };

  @override
  Widget build(BuildContext context) {
    final tint = _tints[kind] ?? context.colors.inkFaint;
    final ink = _inks[kind] ?? context.colors.ink;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.s(10),
        vertical: context.s(5),
      ),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            kind,
            style: AppTypography.monoLabel(
              context,
            ).copyWith(fontSize: context.s(9), color: ink),
          ),
          SizedBox(width: context.s(6)),
          Text(
            label,
            style: TextStyle(
              fontSize: context.s(12),
              fontWeight: FontWeight.w500,
              color: ink,
            ),
          ),
        ],
      ),
    );
  }
}
