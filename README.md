# Cove

> **Note:** Google Calendar sync may not work for you. It requires Google to verify the app, which hasn't been submitted — only Google accounts manually added as test users can currently connect. Everything else works normally without it.

## What is Cove

Cove is a personal task and agenda manager built for Android with Flutter. It's a single-user, offline-first app: everything you enter — tasks, schedules, recurring items, categories — is stored in a local database on your phone, with no account, no login, and no backend server involved at any point.

You capture a task with a short typed line (Quick Add parses out its category, priority, and schedule for you), and from there Cove gives you four different lenses on the same data: **Agenda** for what's happening today, **Up Next** for what needs attention soon, **Calendar** for a full date-based view, and **Areas** for grouping tasks by category with per-area progress. Three home-screen widgets mirror those views so you can check and complete tasks without opening the app, and local notifications remind you ahead of a task's scheduled time — all computed on-device, with no push service in the loop. If you want your schedule to also show up in Google Calendar, that's available as an optional, off-by-default sync.

## Purpose of Cove

Most to-do apps assume you want an account, a cloud sync, and a subscription tier. Cove was built on the opposite assumption: a single person, on one device, who wants to capture and follow through on tasks as fast as possible, with nothing running in the background that isn't strictly needed to do that. There's no signup step, no server round-trip when you save a task, and no telemetry collecting usage data — the entire feature set works the same on a plane with no signal as it does at home.

On top of that foundation, Cove adds a lightweight motivation layer: completing tasks earns XP toward a level, and leveling up unlocks purely cosmetic rewards (accent themes, pets, furniture) — never anything that gates or changes how the app functions. It's meant to make finishing tasks feel a little more rewarding, without turning task management into a guilt mechanism: there's no XP loss for missed tasks and no streak that resets to zero.

## Features

- **Quick Add** — type a task in plain text (e.g. `lab report @school !high`) and Cove parses the area, priority, and schedule from it
- **Agenda / Up Next / Calendar / Areas** — four ways to view the same tasks, organized by day, priority, date, and category
- **Recurring tasks** — daily/weekly/custom recurrence, each occurrence tracked and completed independently
- **Local reminders** — exact-time notifications with a per-task configurable lead time, no push server involved
- **Home-screen widgets** — Agenda, Up Next, and Areas widgets, including tap-to-complete directly from the widget
- **Gamification** — completing tasks earns XP toward a level; leveling up unlocks purely cosmetic pets, furniture, and accent themes
- **App Lock** — optional PIN or biometric lock on the app itself
- **Google Calendar sync** — optional, off by default; export tasks to your calendar with configurable per-item or automatic modes
- **JSON export/import** — back up or move your data manually, since there's no cloud backup

## Requirements

- Android 7.0 (API 24) or newer
- iOS: not currently planned
- No internet connection required, except if you turn on Google Calendar sync

## How to Install

1. Go to the [Releases page](../../releases)
2. Download the latest `cove-vX.X.X.apk` from the newest release
3. On your Android device, open the downloaded file — if prompted, allow installs from this source (Settings → apps → allow from this source)
4. Follow the install prompt

## How to Update

1. Go to the [Releases page](../../releases) and download the latest APK
2. Open it and install — it installs over your existing copy since it's signed with the same key, so your data and settings are kept

## Privacy

Cove is offline-first: no account, no cloud sync, no analytics, no telemetry. All data stays on your device, and nothing is sent anywhere unless you explicitly turn on Google Calendar sync.

## Changelog

### v1.0.1
- Fixed: Google Calendar export crashing with an UnimplementedError on Android
- Fixed: notification permission is now requested proactively (onboarding + Settings toggle), instead of only appearing incidentally
- Fixed: Calendar week header disambiguated (S M T W TH F SA); "First day of week" now consistently respected in Month view too (default changed to Sunday)
- Fixed: time-blocked (scheduled) items now show up in Up Next, both in-app and in the widgets
- Fixed: intermittent error opening the app from a home-screen widget tap
- Changed: Up Next tab now shows the same header (date/greeting/XP bar/Find) as Today, instead of a plain title
- Added: privacy policy (PRIVACY.md), noted Google Calendar's current test-user limitation in the README

### v1.0.0
- First build version of Cove

---

<p align="center">more functionalities to appear later</p>
