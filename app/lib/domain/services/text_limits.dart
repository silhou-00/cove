/// Defensive length caps enforced at the repository layer, not just the
/// UI — nothing below the database currently limits these, so a very
/// long string reaching a create/update method through any non-UI path
/// (a test, JSON import, a future caller) still ends up bounded before
/// it's stored.
class TextLimits {
  const TextLimits._();
  static const itemTitle = 500;
  static const itemShortTitle = 100;
  static const itemNotes = 10000;
  static const areaName = 100;
  static const tagName = 50;
  static const profileName = 100;
}

/// Trims and caps [value] at [maxLength] characters. Silent truncation,
/// not rejection — these are ordinary user-typed values that just need
/// an upper bound, not a validation error surfaced back to the caller.
String capLength(String value, int maxLength) {
  final trimmed = value.trim();
  return trimmed.length > maxLength ? trimmed.substring(0, maxLength) : trimmed;
}
