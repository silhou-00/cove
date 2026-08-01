# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> Durable rules only. Implementation status (what's built, pending, deferred) lives in the project docs — shipping a feature must never require an edit here.

## Commands

All commands run from `app/`:

- `flutter pub get` — install dependencies
- `flutter run` — run the app (debug)
- `flutter test` — run tests
- `flutter analyze` — lint/static analysis (rules in `app/analysis_options.yaml`)
- `flutter build <apk|ios|...>` — build for a target platform

## Stack

- Flutter / Dart (SDK `^3.11.5`), app code lives under `app/`
- Package manager: `pub` (`app/pubspec.yaml`, `app/pubspec.lock`)
- Lints: `flutter_lints` via `app/analysis_options.yaml`

## Environment Variables

- `.env` is required and git-ignored; `.env.example` is committed and is the key inventory.
- A variable enters `.env` / `.env.example` only together with the code that reads it.
- All config is validated at boot in one central module; code reads the exported config object, never `process.env` directly.

<!-- claude-init: list the actual variables here as they land -->

## Git Policy

Claude does not run state-changing git commands (enforced by `.claude/hooks/block-git.sh`). Instead, suggested git commands are listed at the end of the reply for the user to run manually. Read-only git (`status`, `diff`, `log`, `show`) is allowed.

## Rules

@.claude/rules/architecture.md
@.claude/rules/api-design.md
@.claude/rules/security.md
@.claude/rules/code-quality.md
