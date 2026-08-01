/// The most recent [firstWeekday] on or before [date]'s calendar day —
/// `firstWeekday` is `DateTime.monday` (1) or `DateTime.sunday` (7),
/// matching `DateTime.weekday`'s own numbering (§11, first day of week).
/// Previously duplicated as `_startOfWeek` (always Monday-hardcoded) in
/// four places: `item_repository.dart`, `calendar_screen.dart`,
/// `areas_screen.dart`, `search_screen.dart`.
DateTime startOfWeek(DateTime date, int firstWeekday) {
  final day = DateTime(date.year, date.month, date.day);
  final offset = (day.weekday - firstWeekday + 7) % 7;
  return day.subtract(Duration(days: offset));
}
