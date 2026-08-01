import 'dart:convert';

import 'package:drift/drift.dart';

import '../db/database.dart';
import 'item_repository.dart';

/// Thrown by [ExportRepository.importFromJson] for anything wrong with the
/// picked file — malformed JSON, wrong top-level shape, or a row that
/// doesn't match the expected columns. [message] is written to be shown
/// to the user directly, not a raw Dart exception string.
class InvalidExportFileException implements Exception {
  const InvalidExportFileException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// JSON export/import (§11) — human-readable portability/inspection, not
/// the guaranteed-perfect migration path (Drive backup's raw `VACUUM INTO`
/// snapshot is that; see documents/documentation.md's "Rejected: per-row
/// user_id column" note). Original row ids are preserved; since Cove has
/// exactly one `Profile` row, that alone makes every relationship correct
/// on import — no per-row ownership tag needed.
///
/// Every table row class drift generates already has `toJson`/`fromJson`
/// (see `database.g.dart`), so this repository is mostly just plumbing
/// those together with an envelope, not writing its own serialization.
class ExportRepository {
  ExportRepository(this._db, this._items);

  final AppDatabase _db;
  final ItemRepository _items;

  Future<String> exportToJson() async {
    final profile = await (_db.select(
      _db.profiles,
    )..limit(1)).getSingleOrNull();
    final areas = await _db.select(_db.areas).get();
    final items = await _db.select(_db.items).get();
    final tags = await _db.select(_db.tags).get();
    final itemTags = await _db.select(_db.itemTags).get();

    final envelope = {
      'exportedFromProfileId': profile?.id,
      'exportedAt': DateTime.now().toIso8601String(),
      'data': {
        'profile': profile?.toJson(),
        'areas': areas.map((a) => a.toJson()).toList(),
        'items': items.map((i) => i.toJson()).toList(),
        'tags': tags.map((t) => t.toJson()).toList(),
        'itemTags': itemTags.map((it) => it.toJson()).toList(),
      },
    };
    return jsonEncode(envelope);
  }

  /// Rejects anything that isn't shaped like a Cove export before a single
  /// row is touched — a picked file could be anything (wrong app's export,
  /// truncated download, hand-edited JSON). Doesn't validate individual
  /// row *content* (an `Item.fromJson` with a missing required field still
  /// throws during the actual import) — just the top-level envelope shape,
  /// which is cheap to check and catches the common case (not JSON at all,
  /// or JSON but not an export) with a clean message instead of a raw
  /// type-cast exception.
  Map<String, dynamic> _validateEnvelope(String jsonString) {
    final Object? decoded;
    try {
      decoded = jsonDecode(jsonString);
    } on FormatException {
      throw const InvalidExportFileException('This file is not valid JSON.');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const InvalidExportFileException('Not a valid Cove export file.');
    }
    final data = decoded['data'];
    if (data is! Map<String, dynamic>) {
      throw const InvalidExportFileException('Not a valid Cove export file.');
    }
    for (final key in const ['areas', 'items', 'tags', 'itemTags']) {
      if (data[key] is! List) {
        throw InvalidExportFileException(
          'Malformed "$key" section in export file.',
        );
      }
    }
    final profile = data['profile'];
    if (profile != null && profile is! Map<String, dynamic>) {
      throw const InvalidExportFileException(
        'Malformed profile in export file.',
      );
    }
    return data;
  }

  /// Full replace, not a merge — wipes every row these tables currently
  /// hold and inserts exactly what the file describes, then re-expands
  /// recurrence occurrences (not part of the export — they're derived)
  /// and refreshes the widget caches, since this bypasses the normal
  /// create/update methods that would otherwise do both automatically.
  Future<void> importFromJson(String jsonString) async {
    final data = _validateEnvelope(jsonString);

    try {
      await _db.transaction(() async {
        await (_db.delete(_db.itemTags)).go();
        await (_db.delete(_db.occurrences)).go();
        await (_db.delete(_db.items)).go();
        await (_db.delete(_db.areas)).go();
        await (_db.delete(_db.tags)).go();
        await (_db.delete(_db.profiles)).go();

        final profileJson = data['profile'] as Map<String, dynamic>?;
        if (profileJson != null) {
          await _db
              .into(_db.profiles)
              .insert(
                Profile.fromJson(profileJson),
                mode: InsertMode.insertOrReplace,
              );
        }
        for (final json
            in (data['areas'] as List).cast<Map<String, dynamic>>()) {
          await _db
              .into(_db.areas)
              .insert(Area.fromJson(json), mode: InsertMode.insertOrReplace);
        }
        for (final json
            in (data['tags'] as List).cast<Map<String, dynamic>>()) {
          await _db
              .into(_db.tags)
              .insert(Tag.fromJson(json), mode: InsertMode.insertOrReplace);
        }
        for (final json
            in (data['items'] as List).cast<Map<String, dynamic>>()) {
          await _db
              .into(_db.items)
              .insert(Item.fromJson(json), mode: InsertMode.insertOrReplace);
        }
        for (final json
            in (data['itemTags'] as List).cast<Map<String, dynamic>>()) {
          await _db
              .into(_db.itemTags)
              .insert(ItemTag.fromJson(json), mode: InsertMode.insertOrReplace);
        }
      });
    } on InvalidExportFileException {
      rethrow;
    } catch (_) {
      // A row didn't match the expected columns (missing required field,
      // wrong type) — the transaction already rolled back itself; this
      // just replaces the raw type-cast/argument-error string with a
      // message the user can actually act on.
      throw const InvalidExportFileException(
        "This file's contents don't match what Cove exports — import cancelled, nothing was changed.",
      );
    }

    await _items.extendRecurrenceHorizons();
    await _items.refreshWidgetCaches();
  }

  /// Wipes every local table back to a fresh-install-empty state,
  /// including `Profile` and `Settings` (onboarding-complete, agenda
  /// sort, app-lock fields all live there or on `Profile`) — the caller
  /// is responsible for disconnecting Drive/Calendar *before* calling
  /// this if either is connected, so the token gets properly revoked
  /// rather than just having its local flag silently wiped alongside
  /// everything else (`security.md`'s "disconnect must revoke the
  /// token" rule).
  Future<void> clearAllData() async {
    await _db.transaction(() async {
      await (_db.delete(_db.itemTags)).go();
      await (_db.delete(_db.occurrences)).go();
      await (_db.delete(_db.items)).go();
      await (_db.delete(_db.areas)).go();
      await (_db.delete(_db.tags)).go();
      await (_db.delete(_db.profiles)).go();
      await (_db.delete(_db.externalEvents)).go();
      await (_db.delete(_db.widgetCaches)).go();
      await (_db.delete(_db.settings)).go();
      await (_db.delete(_db.syncMetas)).go();
      // Onboarding's "Your rooms" step edits existing presets rather than
      // creating them, same as a genuinely fresh install (see seedAreas'
      // own doc comment).
      await _db.seedAreas();
    });
    await _items.refreshWidgetCaches();
  }
}
