const _weekdayCodes = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// Expands one of the simplified recurrence rules quick-add produces
/// (`FREQ=DAILY`, `FREQ=WEEKLY`, `FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR`) into
/// concrete calendar dates, used to materialize `Occurrence` rows (§3,
/// "~60 days ahead"). Pure date math — no database, no notion of "now" —
/// so the caller decides the horizon and this stays trivially testable.
class RecurrenceExpander {
  const RecurrenceExpander();

  /// Caps how far before [horizonEnd] expansion can effectively reach,
  /// regardless of how old [anchor] actually is — every current caller
  /// already keeps dated items non-past (§4/§5), but this is a pure,
  /// reusable function that shouldn't depend on that holding upstream.
  /// An anchor from years back would otherwise expand into one huge
  /// occurrence batch on first materialization; those ancient dates
  /// aren't useful to have anyway, only the window near [horizonEnd] is
  /// ever actually displayed.
  static const _maxSpanDays = 400;

  /// Returns date-only [DateTime]s from [anchor] through [horizonEnd]
  /// inclusive that match [rule]. For a plain weekly/daily rule this
  /// always includes [anchor] itself (the pattern is defined to start
  /// there). For a `BYDAY` rule it only includes days whose weekday is
  /// listed — if [anchor] itself doesn't fall on one of those days (e.g.
  /// an item created on a Saturday with "every weekday"), the first
  /// result is the next matching day, not the anchor.
  List<DateTime> expand({
    required String rule,
    required DateTime anchor,
    required DateTime horizonEnd,
  }) {
    final rawStart = _dateOnly(anchor);
    final end = _dateOnly(horizonEnd);
    if (end.isBefore(rawStart)) return const [];

    final byDay = _byDayCodes(rule);
    final dates = <DateTime>[];

    if (byDay != null) {
      final start = _clampStart(rawStart, end, stepDays: 1);
      for (var d = start; !d.isAfter(end); d = d.add(const Duration(days: 1))) {
        if (byDay.contains(_weekdayCodes[d.weekday - 1])) dates.add(d);
      }
    } else if (rule.startsWith('FREQ=DAILY')) {
      final start = _clampStart(rawStart, end, stepDays: 1);
      for (var d = start; !d.isAfter(end); d = d.add(const Duration(days: 1))) {
        dates.add(d);
      }
    } else if (rule.startsWith('FREQ=WEEKLY')) {
      // stepDays: 7 preserves the anchor's original weekday phase — the
      // loop below increments by exactly 7 days from `start`, so `start`
      // itself determines which weekday every future occurrence lands
      // on. Clamping to an arbitrary later date (instead of one that's
      // still a multiple of 7 days from the true anchor) would silently
      // shift the whole pattern onto the wrong day of the week.
      final start = _clampStart(rawStart, end, stepDays: 7);
      for (var d = start; !d.isAfter(end); d = d.add(const Duration(days: 7))) {
        dates.add(d);
      }
    }

    return dates;
  }

  /// If [start] is more than [_maxSpanDays] before [end], advances it in
  /// whole [stepDays] increments until it's within that window — whole
  /// increments so the recurrence pattern's phase (which weekday a
  /// weekly rule lands on) stays anchored to the original [start].
  DateTime _clampStart(DateTime start, DateTime end, {required int stepDays}) {
    final earliestAllowed = end.subtract(const Duration(days: _maxSpanDays));
    if (!start.isBefore(earliestAllowed)) return start;
    final daysShort = earliestAllowed.difference(start).inDays;
    final stepsToSkip = (daysShort / stepDays).ceil();
    return start.add(Duration(days: stepsToSkip * stepDays));
  }

  List<String>? _byDayCodes(String rule) {
    final match = RegExp(r'BYDAY=([A-Z,]+)').firstMatch(rule);
    return match?.group(1)!.split(',');
  }
}
