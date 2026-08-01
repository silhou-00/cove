# App documentation — Cove

## Overview

A personal, offline-first workload tracker for school, work, certifications, and everyday life — not limited to those categories, since areas are entirely user-defined.

Scope note: Android only. iOS builds require a Mac for code signing and Xcode, which isn't part of your setup, so it's explicitly out of scope rather than a silent gap.

Core principle, applies to every section below: **the app is fully functional offline, forever, by default.** Nothing in this doc introduces a network call that fires without you explicitly pressing a button for that specific feature.

---

## 1. Language and stack

| Layer | Choice | Why |
|---|---|---|
| App language | **Dart** | Single language for UI, logic, and data access. |
| App framework | **Flutter** | Full VSCode support (hot reload, debugger, DevTools); Kotlin's VSCode extension is Alpha and Android support isn't ready yet. |
| Native glue (unavoidable) | **Kotlin**, ~100–150 lines total | Android home screen widgets render as RemoteViews inside the launcher process — no runtime (Flutter, JS, or otherwise) executes there. Every cross-platform option needs a thin native layer for this. It's three small provider classes, written once. |
| Local database | **SQLite via `drift`** | Type-safe queries generated from Dart, real migrations, reactive `Stream<List<T>>` so writes auto-propagate to every screen and to the widget cache. |
| State management | **Riverpod** (`flutter_riverpod`) | Pairs naturally with drift's streams — a `StreamProvider` per query, no manual subscription management. |
| Navigation | **go_router** | Declarative routes, needed for deep links from widget taps into specific items. Scheme: `cove://item/[id]`. |
| Widget bridge | **`home_widget`** | Dart-side package that writes data for the native widgets to read and triggers `AppWidgetManager` updates. |
| Background scheduling | **`workmanager`** (Android) | Midnight rollover, recurrence horizon regeneration, batched calendar-export retry when connectivity returns. Never used to silently trigger a Google connection on its own. |
| Notifications | **`flutter_local_notifications`** | Reminders for scheduled and due items. Ships in v1. |
| Cloud backup (opt-in) | **`google_sign_in` + `googleapis`** | OAuth + Drive API access, only invoked when the Drive button in Settings is pressed. |
| Cloud calendar (opt-in) | **`google_sign_in` + `googleapis`** (Calendar API) | Separate scope grant from Drive, only invoked when the Calendar button in Settings is pressed. |
| Connectivity check | **`connectivity_plus`** | Used only to decide whether the post-save calendar-export prompt is eligible to appear — not used anywhere in the core offline path. |
| Date/time | **`intl`** + **`timezone`** | Formatting, locale support, correct scheduling across DST. |
| IDs | **`uuid`** | Stable identifiers safe to sync/restore without collision. |

Everything above `home_widget`'s native boundary is Dart. Below it — the three widget layout files — is Kotlin, and nothing else in the app needs to be.

---

## 2. Architecture

Three layers, one direction of dependency:

```
UI (widgets/screens)
   ↓ watches
Riverpod providers (StreamProvider, AsyncNotifier)
   ↓ calls
Repositories (ItemRepository, AreaRepository, BackupRepository, CalendarSyncRepository)
   ↓ queries
Drift database (SQLite)
```

- **Repositories** are the only layer allowed to touch drift directly. Screens never write raw queries.
- **Every mutation** (create/update/complete/delete an item) goes through a repository method that (a) writes to drift, (b) recomputes the affected `widget_cache` rows, (c) calls `home_widget.updateWidget()`, (d) if the item has a date and Calendar export mode is "ask each time," checks connectivity and surfaces the export prompt. This is the one path that must never be skipped — it's the difference between the widgets feeling live and feeling stale.
- **Google connections are isolated.** `BackupRepository` (Drive) and `CalendarSyncRepository` (Calendar) are separate classes with separate OAuth scopes, each only instantiated/called when their respective Settings toggle is on. Neither is referenced anywhere in the core item/area/widget path — deleting both classes entirely would not break offline use of the app.
- **No business logic in widgets.** Screens are thin; logic (progress calculation, recurrence expansion, agenda sorting, quick-add parsing) lives in the repository or a plain Dart service class, so it's testable without spinning up a widget tree.

---

## 3. Data model (drift schema)

### `Profile`
| Column | Type | Notes |
|---|---|---|
| id | text | fixed single row, no accounts |
| first_name | text | |
| last_name | text, nullable | |
| created_at | datetime | |

Local only. Never transmitted anywhere, including to Google — it's not part of any OAuth flow, just a greeting on the Agenda screen ("Good morning, [first name]").

### `Area`
| Column | Type | Notes |
|---|---|---|
| id | text (uuid) | PK |
| name | text | user-defined; seeded with presets at onboarding, fully editable/deletable afterward |
| color | text | hex, used in Agenda/Areas widgets |
| icon | text | icon key |
| sort_order | int | manual ordering |
| archived | bool | soft-hide without deleting history |

### `Item`
| Column | Type | Notes |
|---|---|---|
| id | text (uuid) | PK |
| area_id | text, nullable | FK → Area; nullable so a bare quick-add with no `@area` token still saves instantly, uncategorized |
| parent_id | text, nullable | FK → Item, enables subtasks/projects with no separate table |
| title | text | |
| short_title | text, nullable | fallback display string for widget row width; falls back to truncated `title` if null |
| notes | text, nullable | |
| status | enum: open / done / cancelled | |
| priority | enum: low / medium / high, nullable | |
| due_at | datetime, nullable | deadline — no implied time slot |
| scheduled_start | datetime, nullable | independent from `due_at` — a blocked-out time |
| scheduled_end | datetime, nullable | |
| estimate_minutes | int, nullable | |
| recurrence_rule | text, nullable | RRULE-style string |
| completed_at | datetime, nullable | |
| external_calendar_event_id | text, nullable | set only once this item has actually been exported to Google Calendar; null otherwise |
| created_at | datetime | |
| updated_at | datetime | |

`due_at` and `scheduled_*` are deliberately separate columns. A lab you've blocked 7–9pm has a schedule but no deadline; an assignment due Friday 11:59pm has a deadline but no schedule.

### `Occurrence`
Materialized recurrence instances, ~60 days ahead. See §4 for the recurrence grammar.

| Column | Type | Notes |
|---|---|---|
| id | text (uuid) | PK |
| item_id | text | FK → Item (the recurring template) |
| date | date | |
| scheduled_start | datetime, nullable | |
| status | enum: open / done / skipped | |
| completed_at | datetime, nullable | |

### `Tag` / `ItemTag`
Standard many-to-many. Cross-cutting labels that don't belong in the Area hierarchy.

### `ExternalEvent`
Populated only if Calendar import is switched on in Settings. Never written by anything else.

| Column | Type | Notes |
|---|---|---|
| id | text (uuid) | PK |
| google_event_id | text | source-of-truth ID from Google Calendar |
| calendar_id | text | which Google calendar it came from |
| title | text | |
| start | datetime | |
| end | datetime, nullable | |
| last_synced_at | datetime | |

Rendered alongside `Item`/`Occurrence` in Agenda/Week/Month views, visually marked as external and read-only.

### `WidgetCache`
| Column | Type | Notes |
|---|---|---|
| widget_name | text | PK — `agenda`, `up_next`, `areas` |
| payload_json | text | exact serialized data the native widget renders |
| updated_at | datetime | |

### `SyncMeta`
| Column | Type | Notes |
|---|---|---|
| key | text | PK, e.g. `last_backup_at`, `drive_file_id`, `calendar_export_mode`, `calendar_import_enabled` |
| value | text | |

### `Settings`
Key-value table: theme mode, first day of week, default reminder offset, widget refresh interval, onboarding-complete flag. Does not store any Google credentials — those live in secure platform storage via `google_sign_in`, not in the app database.

---

## 4. Core features (task/item management)

- Create, edit, complete, delete items
- Areas: user-created, colored, reorderable, archivable
- Subtasks / projects via `parent_id`
- Independent due date and scheduled time block per item
- Priority (low/medium/high), optional
- Free-text notes per item
- Tags, independent of area, many-to-many
- Recurrence (daily/weekly/custom RRULE), materialized into occurrences
- Search across title/notes/tags
- Filter by area, tag, status, date range
- Sort by due date, priority, created date, manual order
- Swipe actions (complete / delete) on list rows
- Drag-to-reorder within a list
- Undo on delete/complete (snackbar with timeout)
- Bulk actions (multi-select complete/delete/move-area)
- Archive view for completed/cancelled items

### Quick-add grammar

A single text field parses tokens out of one line, in any order, and treats whatever's left as the title. This is the single highest-leverage feature for whether the app survives past week one — a slow capture flow is the most common reason these apps get abandoned.

| Token | Meaning | Examples |
|---|---|---|
| `@word` | Area, matched case-insensitively against existing area names | `@school`, `@work` |
| `#word` | Tag, repeatable | `#lab`, `#quick-win` |
| `!high` / `!med` / `!low` (aliases `!h` `!m` `!l`) | Priority | `!high` |
| `today`, `tomorrow`, `mon`…`sun`, `in 3 days`, `in 2 weeks`, explicit `7/26` or `jul 26` | Date | `fri`, `in 3 days` |
| a time attached to a date (`3pm`, `3:30pm`, `15:00`) or a range (`7pm-9pm`) | Time | `fri 3pm`, `7pm-9pm` |
| `every <unit>` | Recurrence | `every mon`, `every day` |
| `due` (forces deadline semantics) / `sched` (forces scheduled semantics) | Override | `due mon 11:59pm` |

**Resolution rule, in one sentence: a date with no time becomes a deadline (`due_at`); a date with a time, or a bare time range with no date (defaults to today), becomes a scheduled block (`scheduled_start`/`scheduled_end`).** The `due`/`sched` keywords override this when the default guess would be wrong for a specific case.

Ten worked examples:

1. `email prof re lab @school #email fri` → title "email prof re lab", area School, tag email, due Friday (date only → deadline)
2. `submit timesheet @work fri 5pm` → title "submit timesheet", area Work, scheduled Friday 5pm (date + time → block)
3. `az-204 container apps lab @certs 7pm-9pm #az-204` → title "az-204 container apps lab", area Certs, tag az-204, scheduled today 7–9pm (time range, no date → assumes today)
4. `gym !low` → title "gym", priority low, no date — a someday item, fine to have
5. `renew passport due next fri` → title "renew passport", due next Friday (explicit `due` keyword)
6. `standup @work 9am every day` → title "standup", area Work, scheduled 9am today, recurrence daily
7. `pay rent in 3 days !high` → title "pay rent", due in 3 days, priority high
8. `essay due mon 11:59pm @school #essay` → title "essay", area School, tag essay, due Monday 11:59pm — `due` here overrides the default (a bare time would otherwise read as scheduled)
9. `dentist appt sched mon 10am` → title "dentist appt", scheduled Monday 10am — `sched` used explicitly, though this case would default to scheduled anyway
10. `water plants` → title "water plants", nothing else — zero-friction capture, no area, no date, no priority

## 5. Screens

- **Today / Agenda** — chronological view of scheduled items + due-today items, plus imported external calendar events if enabled
- **Up Next** — flat, date-sorted list of upcoming due items regardless of area
- **Areas** — list of areas with per-area progress and item counts
- **Week view** — 7-day grid, items placed by scheduled time
- **Month view** — full calendar grid, dot/count indicators per day, tapping a day drills into that day's agenda. Same underlying query as Agenda/Week, just grouped differently.
- **Item detail** — full edit screen: title, notes, area, tags, due, schedule, recurrence, subtasks, and (if Calendar is connected) a manual "add to Google Calendar" toggle for retroactive/offline cases
- **Search** — global search with filter chips
- **Settings** — see §11
- **Onboarding** — see §10

## 6. Home screen widgets

| Widget | Answers | Size | Data source |
|---|---|---|---|
| **Agenda** | "What's happening today, in order?" | 4×3 | `Occurrence` + `Item.scheduled_*` for today |
| **Up Next** | "What's closing in on me?" | 4×2 | `Item.due_at`, sorted ascending, flat list |
| **Areas** | "Where am I falling behind?" | 4×2 | Per-area progress ratio |

**Progress formula** (Areas widget): `done_this_week / (done_this_week + open_due_this_week)`, calendar week starting Monday. An area with zero items this week renders as `—`, dimmed, not `0%`.

**Refresh strategy**, all three required:
1. Heartbeat: `updatePeriodMillis` at Android's 30-minute floor — backstop only.
2. On-mutation: every repository write calls `home_widget.updateWidget()` immediately.
3. Midnight rollover: a `workmanager` task at 00:00 local regenerates the Agenda payload and resets the week boundary on Mondays.

**Text budget**: ~28–32 characters per row at 4-cell width before ellipsis. `short_title` column exists for this reason.

**Native layer**: three Kotlin classes (`AgendaWidgetProvider`, `UpNextWidgetProvider`, `AreasWidgetProvider`) using Glance or RemoteViews XML. Tapping a row deep-links via `cove://item/[id]`.

**Build order**: Up Next → Agenda → Areas.

## 7. Notifications and reminders (v1)

- Local reminders for `scheduled_start` and `due_at`, with a configurable default offset (e.g. 30 min before)
- Per-item override of reminder timing, or none
- Daily digest notification (optional, toggle in settings) summarizing today's agenda
- Notification tap deep-links to the item, same routing as widget taps
- Android 13+ runtime notification permission requested **contextually — at first reminder setup, not during onboarding.** Shipping in v1 doesn't change this; asking upfront before the person has created anything with a reminder is a worse experience than asking the moment it's actually needed.
- Entirely local (`flutter_local_notifications`); no relation to either Google connection

## 8. Google Drive backup (opt-in, separate button)

- Lives only in Settings, behind its own **"Connect Google Drive"** button
- **Scope**: `drive.appdata` only — a hidden per-app folder invisible in the user's Drive UI
- **Mechanism**: snapshot, not live sync. `VACUUM INTO 'snapshot.db'` before every upload
- **Trigger**: manual "Back up now" button in v1
- **Restore**: explicit action, confirmation step, warns it replaces local data
- **Versioning**: keep the last 5 snapshots, not just the latest
- **Disconnect**: revokes the token, clears `SyncMeta` Drive keys
- **OAuth publishing status**: "In production" immediately, to avoid the 7-day testing-mode token expiry
- **SHA-1 fingerprints**: register both debug and release keystore fingerprints up front

## 9. Google Calendar (opt-in, separate button, independent of Drive)

- Lives only in Settings, behind its own **"Connect Google Calendar"** button — a distinct OAuth grant from Drive's
- Two independently toggleable directions:
  - **Import (read-only)** — pulls events into the local `ExternalEvent` table, shown read-only in Agenda/Week/Month. Sensitive scope (`calendar.events.readonly`).
  - **Export (read-write)** — pushes scheduled items to a Google Calendar, setting `Item.external_calendar_event_id`. Restricted scope (`calendar.events`); personal-use apps are an explicit exception to the security-assessment requirement.
- **Export mode**, once connected — this is the actual UX design for "should it ask me":
  - **Ask each time** (default) — after saving an item that has a `due_at` or `scheduled_start`, if the device is online at that moment, show a lightweight, non-blocking prompt: "Add '[title]' to Google Calendar?" It never appears for items with no date, and it never appears offline — no retroactive prompt fires later when connectivity returns.
  - **Always add** — every dated item exports automatically, no prompt. For someone who's decided they always want this.
  - **Never** — export path is fully disabled even though the connection stays alive for import.
  - Switching modes takes effect only for items saved after the switch; it never bulk-processes existing items retroactively.
- **Offline handling**, and it differs by mode:
  - **Ask each time**: no prompt appears while offline, and — deliberately — none fires retroactively once you're back online either. A dialog surfacing days later for a task you've half-forgotten adding is worse than not asking. The item detail screen always has a manual "add to Google Calendar" toggle for exporting it later yourself.
  - **Always add**: since this mode has no prompt to begin with, an offline save queues silently instead of failing — `external_calendar_event_id` stays null, and the `workmanager` job described in §1 pushes it to Google Calendar automatically, with no dialog, the next time connectivity is detected.
  - **Never**: offline or online, nothing happens.
- **Sync trigger** (import direction): manual "Sync now" button in v1
- **Disconnect**: clears `ExternalEvent` rows (import) and/or stops writing `external_calendar_event_id` (export) without touching already-created Google Calendar events

## 10. Onboarding

Full first-run flow, with concrete content at each step:

1. **Profile** — two fields: first name (required to personalize the greeting), last name (optional). Nothing else is asked here — no email, no account, no permissions. Stored in `Profile`, used only for "Good morning, [first name]" on the Agenda screen.
2. **Create areas** — presented with four presets, each pre-colored and editable: **School** (purple), **Work** (teal), **Personal** (coral), **Projects** (amber). Each can be renamed, recolored, deleted, or left as-is; new areas can be added right here or skipped entirely and added later from the Areas screen. Nothing is locked in — these are starting points, not a fixed taxonomy.
3. **Widget prompt** — a three-card explainer, one per widget (Agenda / Up Next / Areas), each with a one-line description and a small preview image, followed by an "Add to home screen" button that opens the OS-level widget picker (the app can prompt but can't place a widget itself — Android requires the long-press-and-drag flow) and a "Skip for now" option. Beneath that, a single passive line: *"Want cloud backup or calendar sync later? Find both in Settings — connecting isn't required."* Tapping it deep-links straight into Settings; it never opens a Google sign-in screen from onboarding itself.
4. **Arrival at Home** — lands on the Agenda screen. Notification permission is not requested here (see §7). No OAuth screen appears anywhere in onboarding — the line in step 3 is a breadcrumb, not a setup step.

## 11. Settings

- Profile: edit first/last name
- Theme: light / dark / system
- First day of week (Mon/Sun)
- Default reminder offset
- Widget refresh interval
- Daily digest notification toggle
- Data: manual backup/restore, export all data to JSON, clear all data (with confirmation)
- **Google Drive**: standalone "Connect" button; once connected, last backup time, "Back up now," "Restore," "Disconnect"
- **Google Calendar**: standalone "Connect" button, independent of Drive; once connected, Import toggle + "Sync now," and the Export mode selector (ask each time / always add / never), plus "Disconnect"
- About: version number, changelog

## 12. General / non-functional features

- **Offline-first**: 100% functional with no network at any point, permanently, unless Drive or Calendar has been explicitly connected
- **Accessibility**: screen-reader labels, respects system font-scaling, contrast-checked area colors in both light and dark
- **Localization scaffolding**: strings routed through `intl` from day one
- **Error handling**: a failed widget-cache write never blocks or corrupts the underlying item write; failed backups/syncs surface a non-blocking banner
- **Data integrity**: foreign keys enforced at the drift layer; deleting a non-empty area prompts to reassign or archive
- **Logging**: lightweight local debug log, visible in a hidden developer screen
- **App icon and branding**: adaptive icon (Android 13+ themed icon support)
- **Deep linking**: `cove://item/[id]`, used by both widgets and notifications
- **Security**: optional app lock (biometric/PIN), off by default
- **No analytics/telemetry** by default
- **Testing**: unit tests on repository logic (progress formula, recurrence expansion, quick-add parser — these three have the most edge cases), widget tests on key screens
- **Versioning**: semantic version in `pubspec.yaml`, visible in Settings → About

## 13. Build and deployment (Windows)

- Android Studio installed for SDK/platform-tools/emulator management only — VSCode remains the editor
- `flutter doctor` run after SDK install; resolve every flagged item, including Android license acceptance and Windows Developer Mode
- Short project path (`C:\dev\cove`) to avoid Windows path-length issues with Gradle
- Windows Defender exclusion on the project folder and Flutter SDK folder
- Debug and release signing configs kept separate from day one; both SHA-1s registered with Google Cloud Console before first Drive or Calendar connection test
- Play Store distribution optional and out of scope for now

## 14. Project structure (lib/)

```
lib/
  main.dart
  app/                    // routing, theming, app-level providers
  data/
    db/                    // drift schema, migrations, DAOs
    repositories/          // ItemRepository, AreaRepository, BackupRepository, CalendarSyncRepository
  domain/
    models/
    services/              // progress calculation, recurrence expansion, quick-add parser
  features/
    agenda/
    up_next/
    areas/
    week_view/
    month_view/
    item_detail/
    search/
    settings/
    onboarding/
  widgets_native/          // Kotlin: three widget provider classes + shared read helper
```

## 15. Roadmap — tagged by priority

**MVP (build first, ship, use for two weeks before touching anything else):**
- Schema + migrations, seeded areas (School / Work / Personal / Projects)
- Onboarding: profile, areas, widget prompt
- Item CRUD, quick-add (full grammar from §4)
- Today/Agenda screen, Up Next screen
- Notifications/reminders (permission requested contextually, first-reminder-triggered)
- One widget: Up Next

**V2:**
- Areas screen + progress formula, validated in-app before it goes on a widget
- Agenda widget, Areas widget
- Week view, Month view
- Google Drive backup (manual, opt-in button)

**V3 (only if the app has survived daily use):**
- Recurrence
- Tags, search, filters
- Bulk actions, drag-reorder
- App lock, export/import
- Google Calendar import (opt-in button)
- Google Calendar export, "ask each time" mode first — "always add" is a later refinement once the ask-mode has been trusted for a while

This ordering exists to avoid the dashboard trap: it's easy to spend more time tuning widget colors or sync plumbing than using the capture flow.

**Not tiered above because it's not required for the app to be complete:** XP and levels, fully specified in §17, whenever the core loop has earned its keep and you want a motivation layer on top of it.

## 16. End-to-end flow

**Onboarding** (first run only, no Google steps in it):
1. Profile — first name, last name (optional)
2. Create areas — School / Work / Personal / Projects presets, each editable, addable, skippable
3. Widget prompt — one card per widget with a preview + "add to home screen," or skip
4. Arrives at Home (Agenda screen)

**Daily loop** (every mutation runs this path):
1. Add or edit an item — via quick-add grammar (§4) or the full item detail form
2. Saved locally via drift
3. Widget cache and any scheduled reminders recompute
4. If the item has a date, Calendar export mode is "ask each time," and the device is online — a one-time prompt to add it to Google Calendar appears; otherwise nothing happens automatically
5. Reflected on the in-app screens (Agenda/Up Next/Areas/Week/Month) and on the home screen widgets (immediately on mutation, 30-minute heartbeat as backstop)

**Settings branch** (only reachable by explicitly opening Settings):
- "Connect Drive" → independent OAuth grant → manual backup/restore/disconnect
- "Connect Calendar" → independent OAuth grant → import toggle (manual sync/disconnect) and export mode selector (ask each time / always add / never)
- Connecting one never triggers or implies the other; neither is reachable from anywhere except Settings

## 17. Gamification — XP, levels, and cosmetic unlocks (deferred, optional)

Not part of MVP/V2/V3. Included here as a fully-specified design so it's ready to build once the core loop has been used daily for a while — not before, since it's easy to spend more time polishing a level curve than using the capture flow it sits on top of.

**Design principle: positive-only.** No XP loss for missed tasks, no streak that resets to zero. This is a motivation layer, not a guilt mechanism — punishing missed days turns the feature against the person using it.

**XP formula per completed item** — deterministic, calculated from attributes already on the item, never manually assigned per task:
```
XP = 10 (base)
   × priority multiplier   (low = 1, medium/unset = 1.5, high = 2)
   + effort bonus          (estimate_minutes ÷ 15, capped at 40)
   + on-time bonus         (+5 if completed by due_at/scheduled_end, else +0 — never negative)
```
Cancelling an item awards 0 XP. Recurring items award XP per completed `Occurrence`, same formula. Rewards effort/importance, not raw task count, so the incentive is to do real work rather than farm trivial items.

**Priority stays optional, not required.** Since priority is now the main XP lever, making it mandatory would seem to sharpen the formula, but a required field that blocks saving a task reintroduces exactly the capture friction this whole app is designed to avoid. Instead: the add/edit screen gets a three-way chip (Low · Med · High), Medium pre-selected, one tap to change, zero taps to accept — differentiation is fast when you want it, invisible when you don't. The quick-add text grammar already has the equivalent for typed capture (`!high`/`!med`/`!low`, see §4); this just brings the tap-based flow to parity.

**Level curve** (cumulative XP, front-loaded so early levels come fast):

| Level | Cumulative XP | Level | Cumulative XP |
|---|---|---|---|
| 2 | 100 | 7 | 975 |
| 3 | 225 | 8 | 1,225 |
| 4 | 375 | 9 | 1,500 |
| 5 | 550 | 10 | 1,800 |
| 6 | 750 | | |

**Cosmetic unlocks** — the actual reward, so this isn't just a number going up. Cosmetic only: nothing gates function, nothing is paid, nothing affects the data model's core behavior. Four categories:

- **Accent themes** — alternate color schemes for the whole app
- **Widget skins** — alternate visual treatments for the three home screen widgets
- **Pet** — a small companion character
- **Furniture** — a small decorative object (a lamp, a plant, and so on)

(The original three-category version of this section had a "profile flair" badge as the fourth slot. Folded into pet/furniture instead — a companion and a small object next to your name accomplish the same personal-touch goal more concretely than a generic badge would.)

**Display: three fixed slots, one shared set across every list screen.** Rather than per-screen configuration, there's a single equipped set — one furniture, one pet, and one flexible slot that can hold either — rendered identically in the header row of Agenda, Up Next, Calendar (week and month), and Areas, always next to that screen's title rather than boxed into a section of its own. Tapping the cluster from any of those screens opens the same equip modal; changing what's equipped updates it everywhere at once. It does not appear on the home screen widgets — those stay strictly reserved for task content, given the tight text budget already covered in §6.

First-pass unlock cadence, front-loaded to match the level curve above:

| Level | Unlock |
|---|---|
| 2 | Accent theme "Dawn" |
| 3 | Widget skin "Outline" |
| 4 | Pet "Fox" |
| 5 | Furniture "Reading lamp" |
| 6 | Widget skin "Bold" |
| 7 | Pet "Owl" |
| 8 | Furniture "Potted fern" |
| 9 | Widget skin "Mono" |
| 10 | Pet "Otter" |

**Data model additions:**
- `XpLog`: `id`, `item_id`, `xp_awarded`, `awarded_at` — per-transaction, not a running total. Required for correct undo: hitting undo on a completion must reverse the exact XP that was granted for that specific event, not a freshly recomputed value (which could drift if the item was edited in between).
- `current_level` is always derived from total XP via the curve above — never stored directly, so it can't desync from the log.
- `Unlockable`: `id`, `type` (accent_theme / widget_skin / pet / furniture), `name`, `unlock_level`, `asset_ref` (hex color or asset key), `unlocked_at` (nullable, set once total XP crosses the level threshold). One flat table, data-driven — adding more unlocks later is adding rows, not writing new unlock logic.
- Five new `Settings` keys: `active_accent_theme_id`, `active_widget_skin_id`, `active_furniture_id` (fixed slot), `active_pet_id` (fixed slot), `active_flex_id` (the third slot — its type is read from whichever `Unlockable` row it points to, since it can hold either a pet or a furniture item).

**Surface area, kept deliberately small:**
- A level badge next to the profile greeting on the Agenda screen ("Good morning, [name] · Level 4")
- The three-slot cluster (furniture, pet, flex) in the header row of Agenda, Up Next, Calendar, and Areas — tap from any of them to open the equip modal, which updates the shared set everywhere at once
- Nothing added to the home screen widgets
- A simple "Unlocks" list in Settings as an alternate way to view and equip anything already earned
- No dedicated stats screen, no per-area leveling

**Explicitly deferred within this feature itself**: any anti-farming mechanism beyond the formula's own weighting (e.g. diminishing returns after N completions in a day). This is a single-player system — the only person a gamed XP count would mislead is you, so it's not worth the added complexity unless it turns out to matter in practice.

## 18. Decisions log

| Decision | Resolution |
|---|---|
| App name | Cove |
| Preset area list | School, Work, Personal, Projects — editable/skippable, see §10 |
| Notifications timing | Ships in v1; permission still requested contextually, not during onboarding |
| Quick-add grammar | Defined in full in §4 |
| Google Calendar export UX | Manual per-item prompt by default ("ask each time"), with "always add" and "never" as alternate modes; never prompts offline, see §9 |
| Google sign-in visibility | Kept out of the OAuth flow itself during onboarding; a single passive line on the widget-prompt screen deep-links to Settings for discoverability, but never triggers sign-in from onboarding, see §10 |
| XP calculation | Deterministic from priority/estimate/timing, not manually assigned per task; priority itself stays optional (medium default) rather than required, to protect capture speed — see §17 |
| Gamification reward type | Cosmetic unlocks — accent themes, widget skins, pets, and furniture — shown as one shared three-slot cluster (furniture + pet + flex) in the header row of Agenda/Up Next/Calendar/Areas, never on widgets; tap the cluster to open the equip modal, see §17 |