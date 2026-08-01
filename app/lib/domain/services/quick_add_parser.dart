import 'package:app/data/db/tables.dart' show ItemPriority;

/// Structured result of parsing one line of quick-add text (§4).
class QuickAddResult {
  const QuickAddResult({
    required this.title,
    this.areaName,
    this.tags = const [],
    this.priority,
    this.dueAt,
    this.scheduledStart,
    this.scheduledEnd,
    this.recurrenceRule,
  });

  final String title;
  final String? areaName;
  final List<String> tags;
  final ItemPriority? priority;
  final DateTime? dueAt;
  final DateTime? scheduledStart;
  final DateTime? scheduledEnd;
  final String? recurrenceRule;
}

const _weekdays = {
  'mon': DateTime.monday,
  'tue': DateTime.tuesday,
  'wed': DateTime.wednesday,
  'thu': DateTime.thursday,
  'fri': DateTime.friday,
  'sat': DateTime.saturday,
  'sun': DateTime.sunday,
};

const _weekdayRruleCodes = {
  DateTime.monday: 'MO',
  DateTime.tuesday: 'TU',
  DateTime.wednesday: 'WE',
  DateTime.thursday: 'TH',
  DateTime.friday: 'FR',
  DateTime.saturday: 'SA',
  DateTime.sunday: 'SU',
};

const _months = {
  'jan': 1,
  'feb': 2,
  'mar': 3,
  'apr': 4,
  'may': 5,
  'jun': 6,
  'jul': 7,
  'aug': 8,
  'sep': 9,
  'oct': 10,
  'nov': 11,
  'dec': 12,
};

final _priorityRe = RegExp(
  r'^!(high|h|med|medium|m|low|l)$',
  caseSensitive: false,
);
final _time12Re = RegExp(
  r'^(\d{1,2})(?::(\d{2}))?(am|pm)$',
  caseSensitive: false,
);
final _time24Re = RegExp(r'^([01]?\d|2[0-3]):([0-5]\d)$');
final _timeRangeRe = RegExp(
  r'^(\d{1,2}(?::\d{2})?(?:am|pm))-(\d{1,2}(?::\d{2})?(?:am|pm))$',
  caseSensitive: false,
);
final _slashDateRe = RegExp(r'^(\d{1,2})/(\d{1,2})$');

/// Minutes since midnight, or null if [token] isn't a recognized time.
int? _parseTimeToken(String token) {
  final m12 = _time12Re.firstMatch(token);
  if (m12 != null) {
    var hour = int.parse(m12.group(1)!);
    final minute = m12.group(2) != null ? int.parse(m12.group(2)!) : 0;
    final meridiem = m12.group(3)!.toLowerCase();
    if (hour < 1 || hour > 12) return null;
    if (meridiem == 'am') {
      hour = hour == 12 ? 0 : hour;
    } else {
      hour = hour == 12 ? 12 : hour + 12;
    }
    return hour * 60 + minute;
  }
  final m24 = _time24Re.firstMatch(token);
  if (m24 != null) {
    return int.parse(m24.group(1)!) * 60 + int.parse(m24.group(2)!);
  }
  return null;
}

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// True if [day] is a real day-of-month for [month] in [year] — `DateTime`
/// itself silently normalizes an out-of-range day into the following
/// month instead of rejecting it (e.g. `DateTime(2026, 7, 45)` becomes
/// Aug 14), so a typed phrase like "jul 45" needs this check before being
/// treated as a valid date at all.
bool _isValidDayOfMonth(int year, int month, int day) {
  if (day < 1) return false;
  return day <= DateTime(year, month + 1, 0).day;
}

DateTime _nextWeekday(DateTime now, int targetWeekday) {
  final offset = (targetWeekday - now.weekday) % 7;
  return _dateOnly(now).add(Duration(days: offset));
}

/// Parses one line of quick-add text into structured fields (§4).
///
/// Resolution rule: a time (single or a `7pm-9pm` range) always makes the
/// item scheduled, defaulting to today if no date was given; a date with no
/// time makes it a deadline. `due`/`sched` override the derived kind either
/// way.
class QuickAddParser {
  const QuickAddParser();

  QuickAddResult parse(
    String input, {
    required DateTime now,
    List<String> areaNames = const [],
  }) {
    final words = input
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    final consumed = List<bool>.filled(words.length, false);
    final titleWords = <String>[];
    final tags = <String>[];

    String? areaName;
    ItemPriority? priority;
    DateTime? dateOnly;
    int? timeStart;
    int? timeEnd;
    String? kindOverride; // 'due' | 'sched'
    String? recurrenceRule;

    final lowerAreaNames = {for (final a in areaNames) a.toLowerCase(): a};

    int i = 0;
    while (i < words.length) {
      if (consumed[i]) {
        i++;
        continue;
      }
      final word = words[i];
      final lower = word.toLowerCase();

      // Three-word phrase: "in <N> days|weeks"
      if (lower == 'in' &&
          i + 2 < words.length &&
          RegExp(r'^\d+$').hasMatch(words[i + 1]) &&
          RegExp(
            r'^(day|days|week|weeks)$',
            caseSensitive: false,
          ).hasMatch(words[i + 2])) {
        final n = int.parse(words[i + 1]);
        final unit = words[i + 2].toLowerCase();
        final days = unit.startsWith('week') ? n * 7 : n;
        dateOnly = _dateOnly(now).add(Duration(days: days));
        consumed[i] = consumed[i + 1] = consumed[i + 2] = true;
        i += 3;
        continue;
      }

      // Two-word phrase: "next <weekday>" — "next" is filler; same
      // resolution as the bare weekday.
      if (lower == 'next' &&
          i + 1 < words.length &&
          _weekdays.containsKey(words[i + 1].toLowerCase())) {
        dateOnly = _nextWeekday(now, _weekdays[words[i + 1].toLowerCase()]!);
        consumed[i] = consumed[i + 1] = true;
        i += 2;
        continue;
      }

      // Two-word phrase: "<month> <day>", e.g. "jul 26". An out-of-range
      // day (e.g. "jul 99") is left unconsumed rather than fed to
      // DateTime, which would silently roll it into a different,
      // unintended month instead of rejecting it.
      if (i + 1 < words.length &&
          _months.containsKey(lower) &&
          RegExp(r'^\d{1,2}$').hasMatch(words[i + 1])) {
        final month = _months[lower]!;
        final day = int.parse(words[i + 1]);
        if (_isValidDayOfMonth(now.year, month, day)) {
          var year = now.year;
          var candidate = DateTime(year, month, day);
          if (candidate.isBefore(_dateOnly(now))) {
            candidate = DateTime(year + 1, month, day);
          }
          dateOnly = candidate;
          consumed[i] = consumed[i + 1] = true;
          i += 2;
          continue;
        }
      }

      // Two-word phrase: "every <unit>"
      if (lower == 'every' && i + 1 < words.length) {
        final unit = words[i + 1].toLowerCase();
        if (unit == 'day' || unit == 'days') {
          recurrenceRule = 'FREQ=DAILY';
          consumed[i] = consumed[i + 1] = true;
          i += 2;
          continue;
        }
        if (_weekdays.containsKey(unit)) {
          recurrenceRule =
              'FREQ=WEEKLY;BYDAY=${_weekdayRruleCodes[_weekdays[unit]!]}';
          consumed[i] = consumed[i + 1] = true;
          i += 2;
          continue;
        }
      }

      // Single-word tokens.
      if (word.startsWith('@') && RegExp(r'^@[\w-]+$').hasMatch(word)) {
        final name = word.substring(1);
        areaName = lowerAreaNames[name.toLowerCase()] ?? name;
        consumed[i] = true;
        i++;
        continue;
      }
      if (word.startsWith('#') && RegExp(r'^#[\w-]+$').hasMatch(word)) {
        tags.add(word.substring(1));
        consumed[i] = true;
        i++;
        continue;
      }
      final prioMatch = _priorityRe.firstMatch(word);
      if (prioMatch != null) {
        final p = prioMatch.group(1)!.toLowerCase();
        priority = p.startsWith('h')
            ? ItemPriority.high
            : p.startsWith('l')
            ? ItemPriority.low
            : ItemPriority.medium;
        consumed[i] = true;
        i++;
        continue;
      }
      if (lower == 'due') {
        kindOverride = 'due';
        consumed[i] = true;
        i++;
        continue;
      }
      if (lower == 'sched') {
        kindOverride = 'sched';
        consumed[i] = true;
        i++;
        continue;
      }
      if (lower == 'today') {
        dateOnly = _dateOnly(now);
        consumed[i] = true;
        i++;
        continue;
      }
      if (lower == 'tomorrow') {
        dateOnly = _dateOnly(now).add(const Duration(days: 1));
        consumed[i] = true;
        i++;
        continue;
      }
      if (_weekdays.containsKey(lower)) {
        dateOnly = _nextWeekday(now, _weekdays[lower]!);
        consumed[i] = true;
        i++;
        continue;
      }
      final slashMatch = _slashDateRe.firstMatch(word);
      if (slashMatch != null) {
        final month = int.parse(slashMatch.group(1)!);
        final day = int.parse(slashMatch.group(2)!);
        if (month >= 1 &&
            month <= 12 &&
            _isValidDayOfMonth(now.year, month, day)) {
          var year = now.year;
          var candidate = DateTime(year, month, day);
          if (candidate.isBefore(_dateOnly(now))) {
            candidate = DateTime(year + 1, month, day);
          }
          dateOnly = candidate;
          consumed[i] = true;
          i++;
          continue;
        }
      }
      final rangeMatch = _timeRangeRe.firstMatch(word);
      if (rangeMatch != null) {
        timeStart = _parseTimeToken(rangeMatch.group(1)!.toLowerCase());
        timeEnd = _parseTimeToken(rangeMatch.group(2)!.toLowerCase());
        consumed[i] = true;
        i++;
        continue;
      }
      final singleTime = _parseTimeToken(word);
      if (singleTime != null) {
        timeStart = singleTime;
        consumed[i] = true;
        i++;
        continue;
      }

      titleWords.add(word);
      i++;
    }

    final hasTime = timeStart != null;
    final kind =
        kindOverride ?? (hasTime ? 'sched' : (dateOnly != null ? 'due' : null));
    final resolvedDate = dateOnly ?? (kind != null ? _dateOnly(now) : null);

    DateTime? dueAt;
    DateTime? scheduledStart;
    DateTime? scheduledEnd;

    if (kind == 'due' && resolvedDate != null) {
      final minutes = timeStart ?? (23 * 60 + 59);
      dueAt = resolvedDate.add(Duration(minutes: minutes));
    } else if (kind == 'sched' && resolvedDate != null) {
      final startMinutes = timeStart ?? 0;
      scheduledStart = resolvedDate.add(Duration(minutes: startMinutes));
      if (timeEnd != null) {
        scheduledEnd = resolvedDate.add(Duration(minutes: timeEnd));
      }
    }

    return QuickAddResult(
      title: titleWords.isEmpty ? 'Untitled item' : titleWords.join(' '),
      areaName: areaName,
      tags: tags,
      priority: priority,
      dueAt: dueAt,
      scheduledStart: scheduledStart,
      scheduledEnd: scheduledEnd,
      recurrenceRule: recurrenceRule,
    );
  }
}
