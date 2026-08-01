/// Google Calendar export mode (§9) — governs the save-time behavior
/// only; the Item Detail manual "Add to Google Calendar" toggle always
/// works regardless of mode. Lives here (not `SettingsRepository`) so
/// this file's pure [decideExportAction] can take it directly instead of
/// a magic string, without the domain layer depending on the data layer.
enum CalendarExportMode { askEachTime, alwaysAdd, never }

/// What to do with a just-saved item, given the Calendar export mode
/// (§9). A pure function of its inputs — no Google/DB/context access — so
/// the ask/always-add/never rules are unit-testable without a live
/// connection, same reasoning as `lockoutSecondsForAttempt`.
enum ExportAction {
  /// Not connected, mode is `never`, the item has no date, or it's
  /// already been exported — nothing to do.
  none,

  /// `askEachTime` and online — show the non-blocking "Add to Google
  /// Calendar?" prompt.
  prompt,

  /// `alwaysAdd` and online — export immediately, no prompt.
  autoExport,

  /// `alwaysAdd` and offline — queue for the workmanager retry job. Never
  /// happens for `askEachTime`: per §9, that mode never fires
  /// retroactively once connectivity returns, only via the Item Detail
  /// manual toggle.
  queueForLater,
}

ExportAction decideExportAction({
  required bool connected,
  required CalendarExportMode exportMode,
  required bool hasDate,
  required bool alreadyExported,
  required bool online,
}) {
  if (!connected ||
      exportMode == CalendarExportMode.never ||
      !hasDate ||
      alreadyExported) {
    return ExportAction.none;
  }
  if (exportMode == CalendarExportMode.askEachTime) {
    return online ? ExportAction.prompt : ExportAction.none;
  }
  return online ? ExportAction.autoExport : ExportAction.queueForLater;
}
