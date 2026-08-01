# Cove — build gaps & deferred decisions

Running log of things found while building that are worth solving later, but
aren't blocking the current step. Each entry: what the gap is, why it's
deferred, and what has to happen before it can be closed. Update this file as
gaps are found or resolved — don't let it go stale.

Spec references are to `documents/app-project.md`.

---

## Open

### Google Drive backup (§8) removed — no near-term use (2026-08-01)
Was fully built (`BackupRepository`: connect, back up now via `VACUUM
INTO` + upload to the hidden `appDataFolder`, restore, disconnect,
keep-last-5 pruning) but blocked on a real Google Cloud OAuth client
being registered, and removed on request rather than left dormant behind
a UI that could only ever show a sign-in error. Deleted
`lib/data/repositories/backup_repository.dart`, its provider, and the
Connections section's "Google Drive" row/state in `settings_screen.dart`
— `google_sign_in`/`googleapis` stay as dependencies since Google
Calendar import/export (§9) uses them independently. JSON export/import
and Clear All Data (§11) are unaffected — those never depended on Drive.
Git history has the full implementation if this gets revisited.

### Settings: daily digest toggle is the one remaining gap
§11 lists profile editing, theme (light/dark/system), first day of week,
a notifications on/off toggle, widget refresh interval, daily digest
toggle, and About/version. Everything except the daily digest toggle is
now built. Not built because it pairs with the still-deferred
`workmanager`-adjacent digest notification from §7 — there's no
notification to toggle yet, so the Settings row would control nothing.
Revisit once that notification exists.

### Widget skin unlocks (Outline/Bold/Mono) have no native effect yet
§17 Phase 2's `activeWidgetSkinId` Settings key is fully wired — unlock
gating, equip, persistence, the equip sheet's card for each skin — but
nothing on the Android widget side (`UpNextWidgetProvider.kt` etc.)
reads it yet, so equipping "Outline"/"Bold"/"Mono" only shows a
confirmation toast, same as the design handoff's own web prototype
(`equipItem` for `type: 'skin'` just flashes a message there too —
it never re-skins a live widget preview either). Building three actual
RemoteViews layouts and wiring the active skin into the widget refresh
payload is native Android work, out of scope for this pass.

---

## Resolved scoping calls (kept for context, not gaps)

### Areas widget's dynamic columns kept multiplying on every refresh (fixed 2026-08-01)
`AreasWidgetProvider.kt` builds its area columns with `RemoteViews.
addView` (needed for the column count to flex with however many areas
exist — see the "Areas widget rebuilt" entry below) but never cleared
`columns_row` before adding the new set. `RemoteViews.updateAppWidget`
patches the widget host's *existing* View tree in place rather than
always reinflating from scratch, so `addView` is additive across calls —
every refresh (the 30-min heartbeat, every item mutation) stacked another
full set of area columns on top of whatever was already there, squeezing
all of them narrower each time. Looked like a single bad resize at a
glance (many illegibly narrow repeating columns), but was really just
"however many refreshes happened since install" columns all coexisting.
Fixed with a `views.removeAllViews(R.id.columns_row)` right before the
loop that adds this update's columns.

### Widget taps spawned a duplicate app instance in Recents (fixed 2026-08-01)
`MainActivity` used `android:launchMode="singleTop"` (the stock Flutter
template default) with `android:taskAffinity=""`. `singleTop` only
dedupes when the activity is already at the top of the *same* task — it
does nothing to stop a tap arriving from outside the app's own task (a
home-screen widget's `PendingIntent`, launched from the launcher's
context) from spawning a brand-new task, which is exactly what showed up
as a second Cove entry in Recents. Changed to `android:launchMode=
"singleTask"`, which guarantees only one instance exists system-wide and
routes any later launch to `onNewIntent()` on the existing one instead.
Verified this doesn't need a custom `onNewIntent` override in
`MainActivity.kt`: `home_widget`'s own Android plugin already implements
`PluginRegistry.NewIntentListener` and forwards the new intent to its
event channel, which is what `HomeWidget.widgetClicked` listens on — the
same mechanism `flutter_local_notifications` already relied on for
notification-tap routing.

### Recurrence built (§3, V3 Step 1) — key decisions (2026-07-30)
`Occurrence` rows now materialize on item creation and top up on every
app open. Decisions worth remembering if this area gets touched again:

- **Horizon top-up is lazy (on app open), not a `workmanager` job** —
  same reasoning as the widgets' "push raw data, native decides 'today'"
  design: occurrences only matter for whatever date range is currently on
  screen, and the app has to be open to see it anyway. `ItemRepository.
  extendRecurrenceHorizons()` is called once from `CoveApp.initState`.
- **A recurring item is never shown via its own raw `due_at`/
  `scheduled_start`, including day one** — only its materialized
  `Occurrence` rows are displayed, so "mark this instance done" works
  identically for every instance instead of special-casing the first one.
- **Occurrence end-time isn't stored per-row** (schema only has
  `scheduled_start`) — a scheduled-kind occurrence's duration is inherited
  from the template `Item`'s own `scheduled_end - scheduled_start` delta,
  applied at read time (`_effectiveItemForOccurrence`).
- **Deleting a recurring item cascades to delete all its occurrences**
  (whole-series delete). "Delete just one occurrence" still isn't
  reachable — no per-occurrence UI, only whole-item delete.
- **Editing an existing item's recurrence rule** is now reachable via the
  Item Detail screen (see the next entry) — regenerates future occurrences
  under the new rule, leaves past/completed ones untouched.
- Per-occurrence reminders are a separate, still-open gap — see "Open"
  above.

### Item Detail screen + Tags/search/filters built (V3 Step 2) — key decisions (2026-07-30)
Full edit screen for one item, plus tag persistence and a search screen.

- **Built as a real screen, not a minimal tag-editor sheet** — also
  unblocks the later Google Calendar export step's "manual add to Google
  Calendar toggle" (§5), so one real screen now beats two throwaway
  patches later.
- **Explicit Save button, not autosave** — same pattern as quick-add;
  closing the sheet without saving discards edits.
- **Shared date/time picker widgets extracted** out of
  `quick_add_sheet.dart`'s private scope into
  `lib/features/item/widgets/date_time_pickers.dart` — both quick-add and
  Item Detail use the same `KindToggle`/`MonthCalendar`/`TimeWheelPair`/
  `RepeatChip` now, not duplicated copies.
- **Tag dedup is case-insensitive, checked in Dart** — `Tags.name` has a
  SQL unique constraint, but SQLite's default text comparison is
  case-sensitive, so `TagRepository.setTagsForItem` matches against
  existing rows in Dart before deciding to create vs. reuse (same
  approach as `@area` matching in quick-add).
- **Search operates on template items, not occurrences** — a recurring
  item's title/notes only need to match once in search results, not once
  per materialized instance. Date-range filter uses simple presets (this
  week / this month / all time), not a custom start/end date picker.
- **`ItemDeepLinkScreen` (notification/widget-tap route) renders the same
  `ItemDetailSheet` content as a full page** instead of a modal — a
  deep-linked cold start has no screen to show behind a sheet. Minor
  cosmetic mismatch (the sheet's drag-handle bar and 90%-height cap show
  up in the full-page context too) traded for not duplicating the form.

### Bulk actions, drag-reorder, swipe, sort, archive view built (V3 Step 3) — key decisions (2026-07-30)
Swipe complete/archive, long-press multi-select, sort control (due date /
priority / created / manual) with drag-reorder, and the Archive screen —
the whole "list-interaction surface" from §4, bundled together.

- **Done/cancelled/deleted items all move to Archive** — resolving the
  "Decision needed" this whole item was logged with. A completed item no
  longer stays inline in Agenda struck-through; every read path that feeds
  Agenda/Up Next/widgets/area-progress now filters to `status = open` (or
  `open | done` where a formula still needs done-counts), so archived
  items simply stop appearing rather than needing a second suppressed
  state.
- **`ItemStatus` gained a 4th value, `deleted`, as a soft delete** —
  reused the existing status-based filtering everywhere instead of a
  separate boolean/table. The Item Detail trash icon calls `archiveItem`
  (soft, restorable), never a real delete; only Archive's own "Delete
  permanently" action calls the renamed `permanentlyDelete` (the old
  hard-delete `delete()`).
- **Archive's entry point lives in Settings**, not a header icon on
  Agenda (the user's call, overriding the initial proposal) — a "DATA"
  section with an "Archive" row. The list shows each item's archived date
  (`archivedAt`, stamped by complete/cancel/archive, cleared by restore).
- **Bulk ops are simple loops over the existing single-item repository
  methods** (`bulkComplete`, `bulkArchive`, `bulkMoveArea`) rather than a
  parallel batched implementation — N transactions instead of one is a
  real inefficiency, but at the scale a person bulk-selecting their own
  tasks actually hits, reusing already-correct logic beats risking drift
  from a second implementation of the same cascade/notification rules.
- **Sort mode is persisted in `SettingsRepository`** (`ItemSortMode`:
  dueDate/priority/created/manual) and applied as an in-memory comparator
  on top of whatever order each query already returns — `dueDate` needs no
  comparator since every Agenda/Up Next query is already date/time
  ordered server-side. Manual sort compares the new `Item.sortOrder` int
  column.
- **Drag-reorder is scoped per rendered section** (Scheduled, Due-today,
  each Up Next date-bucket), nested `ReorderableListView`s with
  `buildDefaultDragHandles: false` and an explicit drag-handle icon (not
  whole-row long-press, which is already claimed by multi-select) —
  writes sequential `sortOrder` values only for the items in that
  section via `reorderItems()`. Only active when sort = Manual and
  nothing is selected.
- **An occurrence-backed row's swipe-archive, bulk-archive, and
  drag-reorder all target the template `Item.id`**, same rule already
  established for toggle/tap-to-open — there's no per-occurrence archive
  or sort-order concept.

### App lock built (§12) — key decisions (2026-07-31)
Optional biometric/PIN gate, off by default, resolving the two
"Decision needed" items this roadmap entry was logged with, plus one the
user raised mid-build about where the PIN itself should live.

- **PIN/enabled flag live on `Profiles`, not `SettingsRepository`** — the
  user asked about formalizing a single-row "User" table that every other
  table (Items, Areas, Tags...) would reference by foreign key, with App
  Lock's config stored there. Pushed back on the FK-everywhere part: this
  is a local-first, no-accounts, single-device app (confirmed by the
  `Profiles` table's own doc comment) — a `userId` column on every table
  would always hold the one same value, so it's a migration sweep for
  zero query benefit, and conflicts with this project's own "no
  abstractions for hypothetical future needs" rule. `Profiles` already
  *is* the one-row "this is the user" record, though, so putting
  `appLockEnabled`/`appLockPinHash`/`appLockPinSalt` there (rather than
  the generic `Settings` key-value table used for onboarding/agenda-sort)
  was the right-sized version of the idea — no FK changes anywhere else.
- **Cold start only, not resume-from-background** — the user's call.
  Splash is the only place the check happens (`SplashScreen._navigateNext`);
  there's no `AppLifecycleState`-observer re-lock on foregrounding.
- **Escalating lockout instead of a "forgot PIN" reset** — after 3 free
  wrong attempts, each subsequent wrong attempt locks for
  10s/20s/30s.../ (matches `security.md`'s own "progressive delay after
  repeated failed logins" rule, applied to a local PIN instead of a
  server login). The user explicitly chose **no in-app reset at all** —
  reinstalling is the only recovery path, no weaker than it already would
  be since there's no account layer to recover through anyway.
- **Salted SHA-256, not bcrypt/argon2/scrypt** — a deliberate deviation
  from `security.md`'s usual password-hashing rule, since this hashes a
  local 4-digit device PIN with no network exposure, not an account
  password; if the phone itself is compromised the hash's strength stops
  being the binding constraint anyway. Salt is fresh random bytes
  generated on `setPin()`, stored in its own column (`Profiles.id` is
  always the fixed string `'local'`, so it can't double as a salt).
- **`MainActivity` changed from `FlutterActivity` to
  `FlutterFragmentActivity`** — required by `local_auth`'s
  `BiometricPrompt` integration on Android; plain `FlutterActivity` can't
  host it.
- **Verified on-device**: enabling App Lock via the set-PIN sheet, a full
  cold restart (`am force-stop` + relaunch) correctly routing to the lock
  screen, biometric-first auto-unlock succeeding, and disabling it again
  via the confirm-PIN re-entry sheet.

### Export/import (JSON) built (§11) — key decisions (2026-07-31)
Export data / Import data / Clear all data as three separate Settings
buttons (per the user's explicit call — not a combined menu).

- **Full replace, not a merge, for both import and clear** — import wipes
  Items/Areas/Tags/ItemTags/Occurrences/Profile and re-inserts exactly
  what the file describes; there's no id-collision/merge-conflict logic
  to get subtly wrong. `Occurrences` aren't part of the export payload at
  all (they're derived from `recurrenceRule`) — import re-expands them
  via the existing `extendRecurrenceHorizons()` afterward.
- **Drift's generated `toJson`/`fromJson` on every table row class did
  almost all the serialization work** — `ExportRepository` is mostly
  plumbing those together with an envelope (`exportedFromProfileId`,
  `exportedAt`, `data`), not hand-written serialization code.
- **"Clear all data" wipes `Profile` too, back to onboarding** — the
  user's call on the one open decision this roadmap entry was logged
  with. Implemented as a full wipe of every table including `Settings`
  (onboarding-complete, agenda-sort) and `SyncMetas`, then
  `AppDatabase.seedAreas()` re-runs to restore the four presets —
  onboarding's "Your rooms" step edits existing rows, it doesn't create
  them, so skipping this would leave onboarding showing an empty list on
  a state that's supposed to look like a fresh install.
- **Clear-all disconnects Google Drive *before* wiping tables**, not
  after — `security.md`'s "disconnect must revoke the token, not just
  clear a local flag" rule, since a blind full-table wipe would otherwise
  silently drop the `drive_connected` flag alongside everything else
  without ever calling `_googleSignIn.disconnect()`.
- **New `ItemRepository.refreshWidgetCaches()`** (public wrapper around
  the existing private cache-refresh/notify pair) — needed because JSON
  import and clear-all both write directly to the tables, bypassing the
  normal create/update methods that would otherwise keep the home-screen
  widget caches in sync automatically.
- **`share_plus`/`file_picker` version pin**: `share_plus` 13.x and
  `file_picker`'s latest majors transitively depend on incompatible
  `win32` (Windows-only) ranges — pinned to `share_plus ^10.1.0` +
  `file_picker ^8.1.0`, the newest combination that resolves cleanly.
  Harmless on Android, the only platform this app ships to; avoided the
  resolver's fallback to `file_picker 3.0.4` (too old to trust against a
  modern Android target).
- Unlike Drive restore (which swaps the raw SQLite file out from under
  the open connection and needs an app restart), JSON import writes
  through the same open drift connection, so every active `Stream` watch
  picks up the change immediately — no restart required.

### Google Calendar import built (§9) — key decisions (2026-07-31)
Connect + Import + Sync now, scoped down from the original full
import-and-export plan at the user's explicit request — export is a
separate, later step. The user also asked why "Connect" wasn't just one
thing covering everything; the answer settled the design: Connect grants
the *permission* to move data at all, Import and Export are the two
independent switches that actually decide what flows through it — read
from Google into Cove, or write from Cove out to Google. Someone can
reasonably want only one direction, so they stay separate toggles even
though they share one connection.

- **Read-only scope only, not both scopes upfront** — reverses what this
  roadmap entry originally planned (request both scopes at connect time
  to avoid a future re-consent). Once export was deliberately deferred to
  its own later step, least-privilege won out: the app shouldn't hold a
  calendar-write grant before any code path uses it. Export's own entry
  above now carries the "re-consent needed" cost this created.
- **`CalendarSyncRepository` mirrors `BackupRepository`'s shape exactly**
  — lazy `GoogleSignIn`, connection state in `SettingsRepository`,
  real-token-revocation `disconnect()`. `googleapis` already covered
  Calendar (used for Drive) — no new pub dependency.
- **`syncNow()` is a full replace, not a merge** — clears every
  previously-synced `ExternalEvent` row before inserting the fresh batch
  from a -30d/+90d window around now. "Dedup by google_event_id" falls
  out for free since each sync starts from empty; an event deleted or
  moved outside the window on Google's side doesn't linger locally
  forever the way an incremental merge would risk.
- **Turning the Import toggle off also clears synced events** — keeps the
  read path simple (Agenda/Calendar just watch `ExternalEvent`, no
  separate "is import even on" check needed) and matches user expectation
  that switching import off actually removes what it added.
- **Read path lives at the UI layer, not `ItemRepository`** — Agenda's
  Today view and Calendar's Month view each independently watch
  `externalEventsInRangeProvider` and render read-only rows (no
  complete-circle, no swipe, distinct muted color) alongside the existing
  item stream. `ItemRepository` itself stays untouched, matching the
  architecture's "Calendar is isolated, deletable without touching item
  logic" rule more literally than extending its four read methods a third
  time would have.
- **Week view's hour-grid does not show external events yet** — deferred,
  not built. Positioning read-only blocks correctly alongside/behind the
  existing scheduled-item blocks in the timed grid (overlap handling, a
  visually distinct treatment that still fits the grid's tight cells) is
  real design work, out of proportion to what "connect and import first"
  asked for. Month view got the cheaper extension instead (existing
  dot-indicator pattern already generalizes to a third color).
- **All-day events fall back to `EventDateTime.date`** when there's no
  `dateTime` — stored as midnight, which reads as "00:00" in the UI
  rather than an "ALL DAY" label. `ExternalEvent` has no `isAllDay`
  column to distinguish the two cases; adding one was skipped as unneeded
  schema surface for this pass. Known minor cosmetic gap, not a
  correctness bug.
- **`applyEvents()` is `@visibleForTesting`**, separated from `syncNow()`
  so the upsert/dedup/all-day-fallback logic is unit-testable by
  constructing `calendar.Event` objects directly, without a live Google
  connection — same reasoning that already applies to why
  `BackupRepository` itself has zero tests (nothing to unit-test without
  a real OAuth client registered).
- **Bug found and fixed, in both this and Drive's connect flow**:
  cancelling the account picker (backing out without choosing an
  account) still showed "Connected" instead of "Sign-in cancelled." Root
  cause: `connect()` returns `false` (not a thrown error) on cancel, but
  Settings' shared `_run`/`_calRun` helper only checks whether an
  exception was thrown before showing the success message — the boolean
  return value was silently discarded since the helper's action
  signature is `Future<void> Function()`. Fixed by pulling `_connect()`
  and `_calConnect()` out of the shared helper into their own
  success/cancelled branches. Worth remembering if another connect-style
  action gets added later: don't route a boolean-result action through
  `_run`/`_calRun`.

### Google Calendar export built (§9) — key decisions (2026-07-31)
The last V3 roadmap item. Prompted by the user asking why export wasn't
just a per-item "add to Google Calendar" option on save — it already was
supposed to be, per §9's own design; the build below is that, not a new
direction.

- **Write scope requested incrementally, not at initial connect** —
  `CalendarSyncRepository.ensureExportScope()` calls
  `GoogleSignIn.requestScopes([calendarEventsScope])` the first time the
  export mode is switched away from `never`, mirroring the same
  least-privilege call already made for import's read-only scope.
  `canAccessScopes` short-circuits the re-consent prompt if already
  granted from a previous session.
- **`connect()` re-requests the write scope on reconnect if the export
  mode is already non-`never`** — closes a real gap: `disconnect()`
  revokes the whole token (all scopes, not just the ones it added), so a
  user who disconnects and reconnects while export mode is still
  "always add" would otherwise have exports silently fail forever with
  no obvious way to notice, since every export call is wrapped
  best-effort and swallows its own errors.
- **`Item.externalCalendarEventId` already existed in the schema**
  (unused, added earlier) — no migration needed. `ItemRepository` gained
  one narrow setter (`setExternalCalendarEventId`) rather than any
  Calendar-aware logic, keeping the "isolated, deletable without
  touching item logic" boundary the import build already established.
- **The ask/always-add/never decision is a pure function**
  (`decideExportAction` in `domain/services/calendar_export_decision.dart`),
  taking connected/mode/hasDate/alreadyExported/online and returning
  none/prompt/autoExport/queueForLater — unit-tested directly, same
  reasoning as `lockoutSecondsForAttempt`, since the actual Google API
  call can't be tested without live OAuth.
- **The trigger only fires for open items** — Item Detail is reachable
  from Archive too, and saving a done/cancelled/deleted item shouldn't
  push it onto a calendar. Archive's own row doesn't even wire the
  trigger in (it's a guaranteed no-op there), keeping that call site
  unchanged.
- **Save-time export runs with the caller's context, not the sheet's
  own** — both `showQuickAddSheet` and `showItemDetailSheet` now return
  the saved `Item` (or `null`) instead of nothing, and a small combinator
  (`showItemDetailSheetAndMaybeExport`) runs the trigger only after the
  sheet has fully closed. The trigger's SnackBar prompt needs a
  `BuildContext` that outlives the modal sheet it was saved from; using
  the sheet's own context after `pop()` is exactly the kind of
  `BuildContext`-across-an-async-gap the analyzer already warns about.
- **"Ask each time" never fires retroactively, by design** — confirmed with
  the user directly: catching up on an item saved while offline (or one
  that was declined) is the Item Detail manual toggle's job, always
  available regardless of mode, not an automatic prompt that reappears
  once connectivity returns. That's `alwaysAdd`'s job instead, via the
  offline queue below.
- **No new queue table for the offline retry** — "pending export" is
  just `WHERE dueAt/scheduledStart IS NOT NULL AND
  externalCalendarEventId IS NULL AND mode = alwaysAdd`, re-queried by
  the job itself rather than tracked separately.
- **The workmanager job runs in a headless isolate and deliberately
  doesn't reuse `ItemRepository`** — it builds its own minimal
  `AppDatabase`/`CalendarSyncRepository` and writes
  `externalCalendarEventId` directly via drift, skipping
  `ItemRepository` (which needs `NotificationService`/`TagRepository` —
  unnecessary weight, and unnecessary plugin-initialization risk in a
  background isolate, for a one-column write).
- **`workmanager: ^0.5.2` doesn't build** against the current Flutter
  plugin embedding — references removed v1-embedding shim classes
  (`PluginRegistrantCallback`, `ShimPluginRegistry`) and pulls a
  conflicting `androidx.work` version, both fixed by pinning
  `^0.9.0+3` instead.
- **Disconnect leaves already-set `externalCalendarEventId` values in
  place** — §9 says "stops writing," not "clears." Already-exported
  items keep their id as a factual record; nothing re-exports them, and
  nothing deletes the Google-side event either.

### Settings batch built: profile editing, About, first day of week, default reminder offset, widget refresh interval, theme (§11) — key decisions (2026-07-31)
Built together in one pass, prioritized backend-ready-first (the values
each already had a repository read/write path, just no Settings row):
first day of week, default reminder offset, widget refresh interval,
profile editing, About, then theme last as the largest lift. Daily digest
stayed out of scope (see the gap entry above) since it has no
notification to control yet.

- **`-1` sentinel for "reminder off"**, distinct from a real `0`-minute
  offset (which still fires a reminder exactly at the due/scheduled
  time). `NotificationService.scheduleForItem` checks `if (offset < 0)
  return;` before scheduling anything.
- **First day of week and widget refresh interval both cycle through a
  small fixed set** (Monday/Sunday; 30/60/120 min) via a shared
  `_CycleRow` tap-to-cycle widget, matching the design mockup's
  `cycleReminder`/`cycleTheme` pattern rather than introducing a picker
  dialog for a 2–3-value choice.
- **Widget refresh interval turned out to need Android 12+ (API 31)**,
  not the "any Android version" the option was first scoped as — flagged
  back to the user mid-build rather than silently shipping a no-op on
  older devices. `AppWidgetManager.updateAppWidgetProviderInfo` takes an
  `"@xml/name"` resource-reference *string*, not a resolved resource
  int, confirmed against the real `android.jar` stub after the
  documented-elsewhere signature assumption failed to compile — six new
  XML variants (30/60/120 min × 3 widgets isn't needed; only 60/120 are
  new, 30 is each widget's existing default) let the native side just
  swap which provider-info file is active, no `workmanager` job needed.
  Below API 31, the call is skipped entirely (graceful degradation, not
  a crash); the Settings value still saves either way, so it applies
  retroactively if the device is ever updated.
- **Theme is a genuine `ThemeExtension<AppColorTokens>`-based light/dark
  system, not a static-const swap.** Flutter's rebuild propagation only
  reacts to `Theme.of(context)`/`InheritedWidget` lookups, so every
  color reference that needs to change between light and dark had to
  move from `AppColors.xxx` (a `const Color`) to `context.colors.xxx` (a
  context-dependent lookup) — 318 call sites across 21 files. Converting
  a reference away from `const` breaks `const`-ness on every surrounding
  widget literal that used it; that cascade (not the palette design
  itself) was the actual size of this task, fixed mechanically via
  `flutter analyze`'s error list rather than by hand-auditing each file.
- **`AppColors` still exists, narrowed to genuinely theme-invariant
  colors only**: `dark` (splash screen and the lock screen's fixed dark
  backdrop — both deliberately ignore the app's theme) and the five
  `areaXxx` category colors (an area's color is its identity, not a
  themeable token). Everything else moved to `AppColorTokens`.
- **`AppTypography.wordmark`/`tagline` stayed on fixed light-mode
  colors**, not `context.colors`, because their only real consumers
  render against that same fixed dark backdrop (splash) or override the
  color themselves (About's wordmark) — making them theme-reactive would
  have made splash's text invisible in dark mode (light-mode `surface`
  is near-white; dark-mode `surface` is near-black, the wrong direction
  for text sitting on a background that never changes).
- **No dark-mode design mockup exists** — the design handoff only covers
  light. The dark palette (`AppColorTokens.dark`) is an original
  derivation: same warm, low-saturation character as the light palette
  with luminance roughly mirrored, not a generic Material blue-black.
  Revisit if a real dark-mode mockup ever gets produced.
- **Theme mode is a `StateProvider<ThemeMode>`, not a `FutureProvider`**
  like every other Settings-backed provider in this app — switching
  theme has to repaint the whole app immediately (no restart), which a
  once-loaded `FutureProvider` can't do. Seeded from `SettingsRepository`
  at launch by `CoveApp`; the Settings row updates both the provider and
  the persisted value on every tap.

### Full security/validation pass + Settings rebuild + Areas drill-down (2026-07-31)
Triggered by an explicit ask to audit "all instances" for security and
validation gaps, then fix everything found. Four parallel research passes
covered data/input validation, auth/secrets/OAuth, file I/O + platform
boundaries, and Android config/dependencies; a second, more literal pass
(prompted by the user directly catching two missed date/time validation
gaps) covered past-date and same-day-past-time picker restrictions and an
end-before-start time check. Everything found was fixed in this same
session except the one item the user explicitly said to leave (no
weak-PIN check on `0000`/`1234`).

**Critical/High fixes:**
- **App Lock was fully bypassable via notification tap or home-screen
  widget tap** — both called `appRouter.go('/item/$id')` directly,
  neither checked `isAppLockEnabled()`, and `router.dart` had no route
  guard at all (only splash's one-time cold-start check gated a normal
  launch). Fixed with a new `SessionLock` (`app/session_lock.dart`) —
  a `ChangeNotifier` singleton read once before `runApp()` (`main.dart`,
  via a short-lived standalone `AppDatabase` connection) and wired into
  `appRouter`'s new `redirect` callback via `refreshListenable`. Every
  route except `/`, `/onboarding`, `/lock` now redirects to `/lock`
  whenever App Lock is enabled and the session hasn't unlocked yet —
  covers the notification/widget-tap paths that used to skip it
  entirely, not just the normal launch path.
- **The escalating lockout wasn't persisted** — force-closing the app
  between wrong PIN guesses reset the attempt counter to zero, since it
  only ever lived in `State` fields. Now persisted via
  `SettingsRepository` (new `getFailedAttempts`/`setFailedAttempts`/
  `getLockoutUntil`/`setLockoutUntil`, generic over a key so both the
  lock screen and the disable-App-Lock re-confirmation sheet get their
  own independent counters) — `lock_screen.dart`'s `initState` resumes
  an in-progress lockout's countdown from the persisted deadline instead
  of starting fresh.
- **Release builds were signed with the shared Flutter debug keystore.**
  Generated a real release keystore
  (`android/app/cove-release.jks`, gitignored) and wired
  `android/key.properties` (gitignored) + `build.gradle.kts` to use it,
  falling back to debug signing only if `key.properties` is missing (a
  fresh clone without the keystore file). **The store/key password was
  generated and is only recorded in `android/key.properties` on this
  machine — back it up somewhere durable (password manager); losing this
  keystore means losing the ability to publish updates under the same
  app identity later.**
- **Android Auto Backup was still enabled with no exclusions** —
  `android:allowBackup="false"` added to the manifest; the PIN hash+salt
  and Google connection state are no longer eligible for cloud backup or
  `adb backup` extraction.
- **JSON import had no schema validation or file-size cap** —
  `ExportRepository` now validates the top-level envelope shape
  (`InvalidExportFileException` with a clean message) before touching any
  row, and `settings_screen.dart` rejects a picked file over 20MB before
  reading it into memory.

**Medium fixes:**
- Disable-App-Lock re-confirmation sheet (`confirm_pin_sheet.dart`) now
  has the same escalating lockout as the front-door lock screen —
  previously unlimited guesses, reachable independently of the lock
  screen by anyone handed an already-unlocked phone.
- PIN hashing upgraded from single-round salted SHA-256 to
  PBKDF2-HMAC-SHA256 at 100,000 iterations, run via `compute()` (a
  background isolate) so the added work doesn't visibly block PIN entry.
  Breaking change with no migration — acceptable since no real user has
  a PIN set on the one device this app runs on yet.
- `FLAG_SECURE` now toggles on native side
  (`com.silhou.cove/secure_screen` channel) while the lock screen,
  confirm-PIN sheet, or set-PIN sheet is visible — blocks
  screenshots/recording/recents-thumbnail capture of PIN entry.
- Imported Google Calendar event titles are length-capped (300 chars)
  and blank-fallback before storage, not stored raw from the API.
- Repository-level length caps added (`domain/services/text_limits.dart`)
  for item title/notes/short-title, area name, tag name, profile name —
  previously UI-only if enforced at all.

**Low fixes:** exported JSON temp files are swept on next launch instead
of never being deleted; the quick-add parser now rejects out-of-range
typed dates ("jul 45", "13/45") instead of letting `DateTime` silently
roll them into a different month; `area_repository.recolor()` validates
hex format; `recurrence_expander.dart` caps how far an old anchor can
expand in one batch (with a phase-preserving clamp so a weekly rule
doesn't shift onto the wrong weekday); `setPin()` enforces the 4-digit
format at the repository layer; `BackupRepository.restore()` caps the
downloaded snapshot size; the workmanager callback now catches
exceptions and returns `false` instead of letting them escape.

**Two picker-UI gaps caught by direct user testing, not the audit
passes:** the calendar picker had no lower bound at all (any past date
was selectable), and separately, picking *today's* date with an
already-passed time was still accepted. Both are now blocked —
`MonthCalendar` disables past-day cells and the prev-month chevron once
at the current month; both save paths (`quick_add_sheet.dart`,
`item_detail_sheet.dart`) reject a computed due/scheduled time before
"now" (floored to the minute, so picking the literal current minute
isn't rejected by the time Save is tapped) — plus the already-fixed
end-before-start-time check for "Time block" mode. Applied uniformly
("block everywhere," per explicit direction) to both new items and
edits of existing ones — a real consequence: editing an already-overdue
item now requires pushing its time forward before Save works again,
even for an unrelated edit like fixing a typo.

**Settings screen rebuilt to match the design handoff's actual layout**
— the previous build used its own boxed-card-per-section structure with
tap-to-cycle rows, not what `Cove Prototype.dc.html` actually shows
(compact profile header, flowing sectioned lists with thin per-row
borders, Drive+Calendar sharing one "Connections" header, Export mode as
three always-visible inline picks). Gamification elements in that same
mockup (Level/XP/Rewards/Restart) were **not** carried over — they're
not in `app-project.md` §11's actual spec, just prototype flourish from
an earlier concept. General's rows (Theme, first day of week, default
reminder, widget refresh) now open a bottom-sheet picker listing every
option (matching Agenda's own sort picker), not tap-to-cycle — an
explicit ask, since cycling gets worse the more options a field has.

**Default reminder options changed**: 10 min and 30 min dropped (10 min
called out directly as too short), replaced with 1 hour / 5 hours / 1
day / off — new default is 1 hour.

**Areas are now tappable** — each area card navigates to a new
`AreaDetailScreen` listing that area's open items (reusing the shared
`ItemRow` and `searchItems(areaId:, status: open)`, not a new read
path), with toggle-complete/archive/open-detail all wired the same as
every other item list.

### Reminders never actually fired — four stacked bugs, not one (2026-07-31)
Triggered by direct user reports ("set a 1-hour reminder, never notified")
that kept reproducing after each individual fix — every prior attempt
fixed a real bug but left the notification still silent, because the
failures were stacked: fixing one just exposed the next. Root-caused by
adding a temporary diagnostic `print` around `zonedSchedule()`'s
try/catch (the method swallows all exceptions by design, per its own
doc comment, so nothing was ever visible without it) and by reading
`dumpsys alarm`/`dumpsys activity broadcasts`/`dumpsys notification`
directly on-device rather than trusting Dart-side logs alone.

1. **R8 resource/code shrinking (`isMinifyEnabled`/`isShrinkResources`,
   added in the same session's earlier security pass) broke
   `flutter_local_notifications` in two separate ways**, each only
   surfacing once the previous one was fixed:
   - The plugin's persisted-notification cache uses Gson `TypeToken`
     reflection; R8 stripped the generic signatures, throwing
     `RuntimeException: Missing type parameter` on *every* plugin call
     (schedule and cancel alike). Fixed with explicit keep rules in
     `proguard-rules.pro` (`-keep class com.dexterous.**`,
     `-keepattributes Signature`, TypeToken keep rules).
   - The custom small-icon drawable (`ic_notification`) was referenced
     only by string name from Dart, so the resource shrinker saw no
     static reference and stripped it — `zonedSchedule()` then threw
     `PlatformException(invalid_icon, ...)`. A `tools:keep` hint in
     `res/raw/keep.xml` didn't reliably fix this; switched to
     `@mipmap/ic_launcher` (the app icon itself, guaranteed to survive
     shrinking) for both `AndroidInitializationSettings` and
     `AndroidNotificationDetails.icon` instead, and deleted the
     now-unused custom drawable + keep.xml.
2. **The "clamp to now" fallback (added earlier for long offsets like
   "1 day before" on a soon-due item) captured `now` before several
   `await`s** (`_ensureInitialized`, `_ensurePermission`,
   `_canScheduleExact`) that can take long enough for that timestamp to
   already be in the past by the time `zonedSchedule()` validates it —
   which rejects any `scheduledDate` that isn't strictly in the future.
   Fixed by capturing `now` (with a 1-second buffer) *after* those
   awaits, immediately before the clamp/schedule call, in
   `notification_service.dart`'s `scheduleForItem()`.
3. **The real root cause, underneath both of the above**:
   `flutter_local_notifications` 18.x no longer bundles its own
   `ScheduledNotificationReceiver` / `ScheduledNotificationBootReceiver`
   manifest declarations (confirmed by reading the installed package's
   own `android/src/main/AndroidManifest.xml` in pub cache — it only
   declares two `<uses-permission>` tags now). Every scheduled alarm
   fired at the OS level exactly on time — confirmed via
   `dumpsys alarm` showing the correct `origWhen` and, separately, via
   `dumpsys activity broadcasts` showing the broadcast dispatched with
   `dispatchTime == finishTime` and zero matched receivers — but Android
   found no component to deliver it to, so it silently no-opped: no
   exception anywhere (nothing to throw against), no notification
   channel ever created, nothing in logcat. This is why the bug survived
   multiple "fixes" — the scheduling side was actually fine the whole
   time. Fixed by declaring both receivers directly in
   `android/app/src/main/AndroidManifest.xml` (plus
   `RECEIVE_BOOT_COMPLETED`, needed for the boot receiver to actually
   receive that action) — already covered by the existing
   `com.dexterous.flutterlocalnotifications.**` proguard keep rule.

Verified end-to-end on-device after all four fixes: a real item edit
now produces a live `NotificationRecord` on the `reminders` channel,
visible in the notification shade, both for the "clamped to now"
immediate-fire path and a genuine future exact-alarm registration
confirmed via `dumpsys alarm` before it fired.

**Follow-up same day**: two content/appearance requests once reminders
were confirmed working. The notification body was just the literal word
"Reminder" — now `reminderBody()` (`notification_service.dart`, unit
tested) shows the due time or scheduled start–end range plus a
truncated notes preview (e.g. "Due 21:00 · Bring the folder with
receipts"), falling back to "Reminder" only when the item has neither.
Separately, the small status-bar icon appeared as a solid black square
— `@mipmap/ic_launcher` (used as the icon after the R8 resource-
shrinking saga above) is a full-color opaque square, and Android renders
status-bar icons from the alpha channel only, so an opaque icon shows as
a filled block. Restored the flat single-color `ic_notification.xml`
vector for this instead, anchoring it against the same resource shrinker
via a harmless `<meta-data>` manifest reference (`res/raw/keep.xml`'s
`tools:keep` hint didn't reliably survive shrinking earlier; a real
manifest resource reference does).

### Three remaining gaps closed before starting gamification (2026-07-31)
Prompted by a "before we move on, is MVP–V3 actually done?" check — cross-
referencing the roadmap (§15) against the real code (not just this file,
which turned out to have several stale entries already closed by later
work — removed those while here: the Calendar export prompt, the
onboarding widget-pin stub, and per-item reminder override, all
superseded by since-built work but never cleaned up). Three real gaps
remained; closed all three:

- **Google Calendar write-scope risk now named in Settings.** Added a
  line under the "Google Calendar" connection row, shown only while
  disconnected: "Connecting lets Cove create and delete events on your
  Google Calendar. You choose how much of that it actually does — ask
  each time, always, or never — once connected." Placed before the
  moment the scope is actually granted, not just in the OAuth consent
  screen's own copy.
- **Onboarding's "Find both in Settings" line is a real link now.**
  `AppShellScreen` gained an `initialIndex` param (default 0/Agenda);
  the `/home` route reads a starting tab index from `state.extra` so
  `context.go('/home', extra: 3)` lands directly on Settings. Tapping the
  breadcrumb finishes onboarding (same profile-save +
  `markOnboardingComplete()` as "Continue"/"Skip") and lands there
  instead of Agenda.
- **Recurring items now get a real per-occurrence reminder** (§3/§7).
  Design questions the original gap entry left open, now resolved:
  - *Does every occurrence get its own reminder?* No — only ever one
    live reminder per recurring item, on the soonest still-open,
    not-yet-passed materialized `Occurrence`. Scheduling dozens of exact
    alarms at once for one daily-repeating task (occurrences materialize
    ~60 days ahead) would be wasteful and risks OS alarm-count limits.
  - *Does completing one cancel just that instance's notification?* Yes
    — `NotificationService.cancelForOccurrence(occurrenceId)` /
    `scheduleForOccurrence(item, occurrence)` are keyed off the
    occurrence's own id (`notificationIdFor` already hashed any string,
    not just item ids), distinct from the item-level notification id.
  - New `ItemRepository._rescheduleOccurrenceReminder(item)` re-picks
    the soonest open+future occurrence and reschedules onto it — called
    after occurrences are (re)materialized (`create`, `update`,
    `restoreItem`, `extendRecurrenceHorizons`) and after
    `toggleOccurrenceComplete` (covers both directions: completing the
    occurrence holding the reminder advances it to the next one;
    un-completing an earlier one can bring the reminder back to it).
  - `NotificationService.scheduleForItem()` now returns early for any
    item with a `recurrenceRule` — its own template anchor fields
    describe only the *first* occurrence, which would otherwise
    double-schedule alongside the occurrence-level reminder for that
    same date.
  - `_removeFutureOccurrences` now cancels each row's notification
    *before* deleting it (used when a recurring item's rule/dates change
    or it's archived/cancelled) — once an occurrence row is gone, its id
    can't be looked up again to cancel a stale alarm still scheduled
    against it.
  - Body text: extracted the shared time+notes formatting out of
    `reminderBody(Item)` into a private `_formatReminderBody(...)`, and
    added `occurrenceReminderBody(Item, Occurrence)` for the occurrence
    path — `Occurrence` has no `scheduledEnd` column, so a time-blocked
    recurrence only ever shows "Starts", never a range.

### Gamification Phase 2 built: cosmetic unlocks (2026-08-01)
Built the reward layer on top of Phase 1's XP/level engine (below):
`Unlockables` table (schema v5→v6, `UnlockableRepository`), the 9-item
catalog and 10×10 pixel-sprite data ported verbatim from the design
handoff's `Cove Prototype.dc.html` (`SHEETS`/`PALS`/`COSMETICS` consts —
no external image assets, just data), the equip sheet (a modal bottom
sheet opened from the header cluster or Settings' "Unlocks" row, matching
the handoff's `openEquip`/`closeEquip`, not a pushed screen), and the
Agenda header's `LV n` dashed-progress-bar gauge (also ported from the
handoff — replaced an earlier plain "· Level n" text suffix after review
caught the mismatch against the reference).

Key decisions, some deviating from both §17 and the design handoff on
explicit request:
- **Three flexible slots, not furniture/pet/flex.** The handoff's
  `equipped: {furniture, pet, flex}` type-restricts two of the three
  slots; built as three homogeneous slots instead (any can hold a pet or
  furniture item) — a deliberate simplification over the mockup, not a
  missed detail.
- **Positive-only unlocks.** `Unlockable.unlockedAt` is never cleared
  once set, even if `XpRepository.reverseForItem` later drops total XP
  back below that threshold (undoing a mistaken completion isn't a
  punishment — see §17's own "positive-only" principle).
- **Header-tap opens the sheet; cycling happens inside it.** Tapping a
  slot *inside* the sheet cycles it through the unlocked pet/furniture
  pool (`UnlockableRepository.cycleSlot`); tapping an unlocked catalog
  card equips into slot 1 specifically (`equipToSlotOne`) — no slot
  picker needed since the pills above serve that purpose for slots 2/3.
- **Accent theme** repaints `AppColorTokens.accent`/`accentDark` app-wide
  via a `StateProvider` bootstrapped at launch (same pattern as
  `themeModeProvider`); `accentDark` is derived by darkening the
  catalog's single hex rather than requiring a second designer color.
- Verified: 168 tests total (`unlockable_repository_test.dart`,
  `cosmetics_test.dart`, plus 2 new cases in `xp_repository_test.dart`
  are the additions from this pass), `flutter analyze` clean, a release
  APK builds and installs. The equip sheet + level gauge were **not**
  visually confirmed live on-device this pass — the test device has App
  Lock enabled from earlier testing and its PIN wasn't available, so
  every relaunch landed on the lock screen instead of Agenda. The
  Unlocks list (now folded into the equip sheet) was confirmed rendering
  correctly on-device before that point — all 9 sprites/chips draw as
  expected.
- Widget skins have no native-side effect yet — logged as its own gap
  above.

### Gamification Phase 1 built: XP/level engine, no cosmetics yet (2026-08-01)
§17 is fully specified as deferred/optional; built the XP/level engine
now on explicit request, deliberately split from the cosmetic-unlocks
half (three-slot equip cluster, accent themes, widget skins, pet/
furniture) — that half needs real visual-asset decisions first (no
illustration pipeline in this project yet) and is its own follow-up.

**Two deliberate deviations from §17's original formula**, decided with
the user before building:
- **Flat random XP, not priority/estimate/on-time-weighted.** Every
  completion draws from a fixed set (`Gamification.xpOptions = [5, 10,
  15, 20, 25]`), regardless of the item's priority, estimate, or
  timing — priority stays purely organizational (its chip UI is
  untouched; it just never fed the formula to begin with in this
  build). Rationale: a weighted formula invites gaming (mark everything
  "high" to farm more XP); a flat reward is simpler to reason about.
- **A daily cap replaces the weighting as the anti-farming mechanism.**
  §17 explicitly deferred any anti-farming mechanism as unnecessary
  ("the only person a gamed XP count would mislead is you") — revisited
  and built anyway on request: only the first `Gamification.dailyXpCap`
  (5) XP-eligible completions per calendar day actually grant XP; the
  6th+ still completes the task normally, just silently for 0 XP, same
  treatment as cancelling an item.

**Schema**: new `XpLogs` table (`id`, `item_id`, `xp_awarded`,
`awarded_at`) — schema v4→v5, plain `createTable` migration (no
backfill; both fresh and upgraded installs start at 0 XP / level 1).
Per-transaction log, not a running total, matching §17's own reasoning:
undoing a completion (`toggleComplete`/`toggleOccurrenceComplete` are
literal toggles, not one-way actions) needs to reverse the *exact* XP
that specific event granted, not a freshly recomputed value.

**New `XpRepository`** (`lib/data/repositories/xp_repository.dart`) —
`awardForCompletion` (cap-checked insert), `reverseForItem` (deletes the
most recent `XpLog` row for that item_id — a heuristic, not exact
event-tracking, since neither `Item` nor `Occurrence` carries a "which
log row is currently live" pointer; correct for the ordinary
complete → uncomplete sequence, not proofed against out-of-order
sibling-occurrence completions on the same recurring item), `totalXp`,
`watchLevel` (derives the level via `Gamification.levelForXp` on every
`XpLogs` write — never stored, can't desync). Pure level-curve/reward-
table logic lives in a new DB-free `lib/domain/services/gamification.dart`
(`xpForCompletion`, `levelForXp`, unchanged level thresholds from §17: 100/
225/375/550/750/975/1225/1500/1800 for levels 2–10, capped at 10 since
§17 doesn't define further growth).

**Wiring**: `ItemRepository.toggleComplete`/`toggleOccurrenceComplete`
award on the done transition, reverse on the reopen transition.
Recurring items log XP under the *template's* item_id per completed
occurrence (§17: "recurring items award XP per completed Occurrence,
same formula") — `XpLog`'s schema has no occurrence_id column, matching
§17 as written.

**Surface area, kept to just the one thing Phase 1 needs**: a level
badge next to the Agenda greeting ("Good morning, Mathew · Level 4"),
via a new `currentLevelProvider` (`StreamProvider<int>` watching
`XpRepository.watchLevel()`). Nothing else from §17's "surface area"
list (equip cluster, Unlocks screen in Settings) is built yet.

### Package renamed from com.example.app to com.silhou.cove (2026-07-29)
Done ahead of the Google Drive work specifically — Cloud Console OAuth
clients for Android are tied to package name + SHA-1 fingerprint, and
renaming after registration would invalidate it. Cheap to do now since
there's no real install base yet. Note for testing: this makes the app a
*different* Android package than any earlier debug build — old test
installs don't get overwritten/updated, they need a separate uninstall.

### V2 Step 3: Week/Month view diverge from the mockup for correctness
Two deliberate deviations, confirmed with the user before building: (1)
prev/next navigation added to both views — the mockup is static to one
week/month, but a calendar you can't browse isn't usable; (2) the month
grid is sized dynamically (35 or 42 cells based on the actual month)
instead of the mockup's hardcoded 35, so a month needing 6 rows doesn't
clip its last few days. Also: due-only items (no time slot, §3) get a
compact all-day row per day in Week view above the timed grid, rather
than being left off it entirely or given a fabricated time — raised by
the user, not something the mockup or spec text showed directly.

No external-calendar-event legend/striped rendering in Week view —
Calendar import (`ExternalEvent`) is V3, nothing to show a legend for yet.

### V2 Step 2: no `workmanager` job — native clock-based recomputation instead
§1/§6 name a specific mechanism for keeping the Agenda widget's "today" and
the Areas widget's "this week" fresh overnight: a `workmanager` background
job at 00:00 local. Deliberately not built — discussed at length with the
user first. Instead, `ItemRepository._refreshAgendaCache`/
`_refreshAreasCache` push **raw** unfiltered data (all open items with a
date, for Agenda; all areas + items with a due/completed date, for Areas),
and `AgendaWidgetProvider`/`AreasWidgetProvider` (Kotlin) decide what
"today"/"this week" means themselves, using the device's own clock, every
time they render. Since the widget already re-renders every 30 minutes
regardless (the heartbeat, required anyway as backstop #1), this
self-corrects across any midnight/Monday boundary without a background
job, isolate, or separate DB connection ever existing. Real trade made:
§6's progress formula now has two implementations to keep in sync — Dart
(`ItemRepository.watchAreaProgress`, tested) and Kotlin
(`AreasWidgetProvider.computeStats`, untested — Kotlin widget code has no
test harness in this project). If the two ever drift apart, the widget and
the in-app Areas screen would disagree; watch for that when either one
changes to also update the other.

### Areas widget rebuilt to match the design handoff (2026-08-01)
Was: 4 stacked full-width rows (dot + name + system-tinted `ProgressBar`),
capped at exactly 4 areas, no level indicator — none of which matched the
"05 — Home screen widgets" mockup (`Cove Android.dc.html:1298-1350`), which
shows 4 side-by-side columns (mini bar + "NAME %" label) plus an "LV n"
badge in the header corner.

Rebuilt as `widget_areas.xml` (an empty `columns_row` container) +
`widget_areas_column.xml` (one column template), with
`AreasWidgetProvider.kt` calling `addView` once per area instead of
populating a fixed set of XML slots — the row now scales to however many
areas actually exist (each column's `layout_weight="1"` shrinks
proportionally), capped at 8 purely because columns get illegibly narrow
past that, not because of a hardcoded slot count.

Per-area colored fill: the previous entry here rejected this as needing
`RemoteViews` APIs gated to API 31+ (crash risk on older devices for a
cosmetic difference). Revisited on request — instead of tinting a real
`ProgressBar`, each bar is drawn as a small bitmap
(`AreasWidgetProvider.makeBarBitmap`, plain `Canvas`/`Paint` calls) and
set via `setImageViewBitmap`, which works on every API level this app
supports, sidestepping the version gate entirely.

Level badge: `ItemRepository._refreshAreasCache` now includes a `level`
field (`Gamification.levelForXp(await _xp.totalXp())`) in the areas
widget payload — the only §17 gamification data that reaches native code,
since nothing else in the cosmetic-unlock system is meant to show on a
widget (design handoff: "no cluster on home screen widgets").

Also bumped text sizes across all three widget layouts (Agenda, Up Next,
Areas) — they were using the design mockup's raw px values directly,
which assume the in-app Flutter screens' `context.s()` scaling (up to
1.35x on a wide device); native RemoteViews has no equivalent scaling, so
the same numbers read noticeably smaller here than the equivalent in-app
text.

### First name is required to leave onboarding step 1 (2026-07-29)
Was an open question (see prior entry, now resolved): user decided first
name should be required, overriding my "leave as-is" recommendation —
explicitly a product call, not a bug fix. Both "Continue" and the step-1
"skip" link now call `_validateName()` first; if the field is empty,
neither advances nor finishes onboarding, and an inline error ("Add a name
to continue") shows under the field in accent color, clearing itself the
moment the user types something. This deviates from both §10's own design
prototype (which never gated `nextStep()`) and from the general
everything-is-skippable onboarding philosophy — a deliberate, explicit
exception for this one field, not a misreading to fix later.

### Post-MVP fidelity pass (2026-07-28): onboarding areas, sizing, quick-add
After the first on-device test, real usage surfaced things spec-review
alone hadn't: onboarding's area step matched the *interactive prototype's*
simplified keep/drop toggle instead of §10's actual text ("renamed,
recolored, deleted, or left as-is" plus adding new ones right there) — a
real misreading, now fixed with proper add/rename/recolor/delete via
`AreaRepository` + an edit sheet. Also added: an onboarding back button,
the quick-add sheet's Deadline/Time-block toggle + calendar + time-wheel
pickers (previously cut in step 4), and per-kind chip tinting.

Also fixed: every screen's sizes were pulled directly from the design's
literal numbers, correct against the source but authored inside a fixed
360×640dp mockup frame — on a real (wider, much taller) phone the same
absolute sizes read as smaller/sparser. Added `context.s(value)`
(`lib/app/theme.dart`) — scales a design value by device-width-vs-360dp,
clamped to [1.0, 1.35] — and routed every screen's fonts/paddings/dimensions
through it instead of raw literals. `AppTypography` styles became
`TextStyle Function(BuildContext)` instead of `const TextStyle` fields for
this reason — every call site changed from `AppTypography.headline` to
`AppTypography.headline(context)`.

### Quick-add: typed dates still parse, but pickers now win once touched
Now that the sheet has real Deadline/Time-block + calendar + time-wheel
controls, typing a date phrase (`fri 5pm`) live-fills those controls, but
the moment you tap a control yourself, further typing stops overwriting it
— a one-way latch (`_dateTouchedManually`), not a two-way sync, to avoid
the picker fighting a manual choice on every keystroke. The sheet now
calls `ItemRepository.create()` with its own picker state directly, not
`createFromQuickAdd()` — that method stays as-is (still fully tested against
the ten worked examples) since it's a faithful, working text-only path a
future non-interactive capture surface could still use; it's just not
what this particular UI calls anymore.

### Full §3 schema built in step 1, not gated by MVP/V2/V3 tiering
§15's tiering applies to features/UI, not to the schema doc (§3), which
describes the whole app's data model in one place. Built `Tag`/`ItemTag` and
`ExternalEvent` now even though tags/search and Calendar import are V3 —
empty tables cost nothing, a real migration later doesn't. Excluded only the
gamification tables (`XpLog`, `Unlockable`) since those are specified
separately in §17, tagged deferred.

### Core library desugaring required for flutter_local_notifications (fixed)
First Android build after step 5/6 failed: `flutter_local_notifications`
requires core library desugaring. Fixed in `android/app/build.gradle.kts` —
`isCoreLibraryDesugaringEnabled = true` plus the
`coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")`
dependency. `flutter build apk --debug` succeeds as of this fix.

### Widget cache write was missing its actual bridge (fixed in step 6)
Step 2's `_refreshUpNextCache()` computed the payload and wrote it to the
drift `WidgetCaches` table, but never called `HomeWidget.saveWidgetData()`
— the actual channel the native `AppWidgetProvider` reads from (it can't
read the app's drift/sqlite file directly). The drift row was effectively
write-only until step 6 built the consuming side and this surfaced. Fixed:
`_notifyWidget` now takes the payload JSON and pushes it via
`HomeWidget.saveWidgetData` before calling `updateWidget()`.

### Up Next widget shows at most 3 rows, no RemoteViewsService/ListView
A 4×2 widget only realistically fits ~3 rows, and a scrollable
`RemoteViewsFactory` adapter is a meaningfully bigger native surface
(a separate registered `Service`, an adapter class) for a widget the
design itself scopes to "what's closing in on me" at a glance. Rows 4+ are
simply not shown. Revisit if a taller widget size gets added later.

### Midnight-rollover `workmanager` job not built
§6 lists three required refresh paths: on-mutation (done), a 30-minute
heartbeat (done, `updatePeriodMillis`), and a midnight rollover job. That
job's job in the spec is specifically to regenerate the *Agenda* payload
and reset the *Areas* widget's Monday week-boundary — neither of which
exists yet (both V2). Up Next's own content (a flat due-date sort) has no
day-boundary dependency the heartbeat doesn't already cover within 30
minutes. Build the `workmanager` job when Agenda/Areas widgets do.

### Up Next widget date labels are a simplified approximation
The Kotlin provider formats due dates without `java.time` (avoiding a
minSdk/desugaring change) — it gets TODAY/TOMORROW/weekday-name right for
anything within a week, and falls back to `M/D` beyond that, rather than
matching the design mock's exact range-style labels. Cosmetic only.

### Daily digest notification not built
§7 lists an optional daily digest summarizing today's agenda, toggled in
Settings. Needs a Settings toggle UI (doesn't exist) and a `workmanager`
midnight job — the latter pairs naturally with step 6's own midnight
widget-rollover job, so it's better done together with that rather than
built twice. Revisit alongside step 6.

### `cove://` URI scheme not registered in AndroidManifest yet
Notification taps route through `flutter_local_notifications`' own payload
mechanism (a plain string, delivered directly to the Dart callback) — no
OS-level intent-filter needed for that. Step 6's native widget taps will
construct a real Android `Intent` with a `cove://item/[id]` data URI, which
*does* need `<data android:scheme="cove"/>` on `MainActivity`. Add it then,
not now — no reason to touch the manifest twice.

### Quick-add sheet ships without the tap-based date/time pickers
The design's capture sheet also has a Deadline/Time-block toggle,
scroll-wheel time pickers, and a month calendar picker as an alternative to
typing dates. Step 4 shipped text-field-only (parses via the same
`QuickAddParser` from step 2, live chips, Save). The typed grammar already
covers every date/time case the pickers would — they're a convenience path
for people who don't want to type it, not a functional gap. Build them if
that convenience turns out to matter in practice.

### Agenda doesn't render external (Google Calendar) events
§5 says Agenda should show imported `ExternalEvent` rows alongside items,
marked read-only. `ExternalEvent` is never populated because Calendar
import is V3-tagged and not built. Nothing to do until that lands.

### Onboarding's passive Settings line is inert text
The widget-prompt step's breadcrumb ("Find both in Settings...") is meant
to deep-link into Settings (§10). Settings is fully built now, but this
specific line was never wired up to actually navigate there — cosmetic,
low priority, purely onboarding copy.

### Area drag-reorder not built
`AreaRepository` has rename/recolor/archive (built as part of onboarding's
own area-editing pass and the Areas screen) — only manual drag-reorder is
still missing; `sortOrder` is only ever set once, at creation (append to
the end), with no write path to change it afterward.

### Rejected: per-row `user_id` column for cross-device export/import
Raised 2026-07-28, referencing a pattern from the Desku project (checked via
`/blueprint analyze Desku_Blueprint`). Decision: **not adding it.**

Desku's `user_id` doesn't do what it looks like it does — on import,
`importData(userId, sections)` re-stamps every row with the *receiving*
device's own freshly-generated UUID, discarding the original device's value
entirely. It's not a cross-device correlation key; it's a constant,
always-one-value scoping column that exists in case an account layer gets
added later. It wouldn't actually serve the goal (export from phone A,
import into phone B) even if copied verbatim.

What actually makes device-to-device transfer work for Cove: an export that
carries the *complete* dataset with original row ids intact (`Item.id`,
`Area.id`, `parent_id`, `area_id`, `item_tags` FKs), imported as a full
replace or a straight insert into an empty install. Since Cove has exactly
one `Profile` row, preserved ids already make every relationship correct —
no ownership tag needed, because there's only ever one owner per install.

If a lightweight "is this a real Cove backup, and whose?" check is wanted
later, stamp the **export envelope** (`exported_from_profile_id`,
`exported_at` alongside the payload), not every row — same idea as Desku's
`validateStructure()` rejecting non-Desku CSVs. That's a confirmation/safety
layer, not the transfer mechanism itself, and costs zero schema changes.

Also worth remembering when JSON export (§11) actually gets built: Drive
backup (§8, `VACUUM INTO` snapshot + full-replace restore) is the more
robust mechanism for exact phone-to-phone migration — no export/import
serialization code to get subtly wrong across schema versions. JSON export
is better framed as human-readable portability/inspection than as the
guaranteed-perfect migration path. Decide deliberately between the two when
V2/V3 gets there; no action needed now.
