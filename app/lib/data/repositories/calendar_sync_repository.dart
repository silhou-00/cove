import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/calendar/v3.dart' as calendar;
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../db/database.dart';
import 'settings_repository.dart';

const _calendarConnectedKey = 'calendar_connected';
const _calendarAccountEmailKey = 'calendar_account_email';
const _calendarImportEnabledKey = 'calendar_import_enabled';
const _calendarLastSyncedAtKey = 'calendar_last_synced_at';

/// Same OAuth-header-injection shim as `BackupRepository` — googleapis
/// clients need their own `http.BaseClient` wired to the signed-in
/// account's headers.
class _GoogleAuthClient extends http.BaseClient {
  _GoogleAuthClient(this._headers);
  final Map<String, String> _headers;
  final _inner = http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers.addAll(_headers);
    return _inner.send(request);
  }
}

/// Google Calendar import + export (§9) — isolated per §2 from Drive: a
/// separate OAuth grant, own connection state, deletable without touching
/// item logic. Connect always requests the read-only scope only; the
/// write scope (`calendar.events`) is requested incrementally via
/// [ensureExportScope], the first time export is actually turned on — the
/// permission ask should match what the app does at any given time, not
/// what it might do eventually.
class CalendarSyncRepository {
  CalendarSyncRepository(this._db, this._settings);

  final AppDatabase _db;
  final SettingsRepository _settings;
  static const _uuid = Uuid();

  // Lazy — same reasoning as BackupRepository: constructing GoogleSignIn
  // touches the platform plugin, which has no reason to run just because
  // Settings loaded its connection status.
  GoogleSignIn? _googleSignInInstance;
  GoogleSignIn get _googleSignIn => _googleSignInInstance ??= GoogleSignIn(
    scopes: [calendar.CalendarApi.calendarEventsReadonlyScope],
  );

  Future<bool> isConnected() async =>
      (await _settings.getValue(_calendarConnectedKey)) == 'true';
  Future<String?> accountEmail() =>
      _settings.getValue(_calendarAccountEmailKey);
  Future<bool> isImportEnabled() async =>
      (await _settings.getValue(_calendarImportEnabledKey)) == 'true';
  Future<String?> lastSyncedAt() =>
      _settings.getValue(_calendarLastSyncedAtKey);

  /// Turning import off also clears whatever's already synced — so the
  /// Agenda/Calendar read path can stay simple (it just watches
  /// `ExternalEvent`, no separate "is import even on" check needed) and
  /// nothing lingers on screen after the toggle says it shouldn't.
  Future<void> setImportEnabled(bool enabled) async {
    await _settings.setValue(_calendarImportEnabledKey, enabled.toString());
    if (!enabled) await (_db.delete(_db.externalEvents)).go();
  }

  /// Returns true on success, false if the user cancelled sign-in. Throws
  /// if Google Sign-In itself fails, same contract as
  /// `BackupRepository.connect()`.
  ///
  /// If the export mode setting is already something other than `never`
  /// (a reconnect after a previous disconnect, most likely — see
  /// [disconnect]'s doc comment), re-requests the write scope right away
  /// instead of leaving export silently broken until the user happens to
  /// re-toggle the export mode. `ensureExportScope`'s own re-consent
  /// prompt covers this; failing that prompt just leaves export
  /// unavailable, same as it would if never granted at all.
  Future<bool> connect() async {
    final account = await _googleSignIn.signIn();
    if (account == null) return false;
    await _settings.setValue(_calendarConnectedKey, 'true');
    await _settings.setValue(_calendarAccountEmailKey, account.email);
    if (await _settings.getCalendarExportMode() != CalendarExportMode.never) {
      await ensureExportScope();
    }
    return true;
  }

  /// Real token revocation (`security.md`'s "disconnect must revoke the
  /// token" rule), plus clears imported events — §9: "Disconnect clears
  /// ExternalEvent rows (import) and/or stops writing
  /// external_calendar_event_id (export) without touching already-created
  /// Google Calendar events." "Stops writing," not "clears": already-set
  /// `Item.externalCalendarEventId` values are left as-is — a factual
  /// record of what was exported before disconnecting — and exports
  /// simply stop happening on their own (every export path requires
  /// `isConnected()`/a live Google API client, both gone once
  /// disconnected). The export mode setting itself isn't reset either;
  /// see [connect]'s doc comment for what happens if it's still non-never
  /// on a later reconnect.
  Future<void> disconnect() async {
    try {
      await _googleSignIn.disconnect();
    } catch (_) {
      // Best-effort — still clear local state below even if the remote
      // token revocation call fails (e.g. offline).
    }
    await _settings.setValue(_calendarConnectedKey, 'false');
    await _settings.setValue(_calendarAccountEmailKey, '');
    await _settings.setValue(_calendarImportEnabledKey, 'false');
    await (_db.delete(_db.externalEvents)).go();
  }

  /// Requests the write scope on top of the connection's existing
  /// read-only grant (§9, export) — call once, the first time export is
  /// switched on. Returns false if the user declines the re-consent
  /// prompt or there's no signed-in account; the connection and import
  /// keep working either way, only export stays unavailable.
  ///
  /// Deliberately does not pre-check via `canAccessScopes` — the Android
  /// platform implementation (`google_sign_in_android`) never overrides
  /// it, so it always throws `UnimplementedError` there regardless of
  /// account/scope state. `requestScopes` alone already no-ops (no
  /// prompt shown) when the scope was granted in a previous session, so
  /// nothing is lost by calling it unconditionally.
  Future<bool> ensureExportScope() async {
    const scope = calendar.CalendarApi.calendarEventsScope;
    if (_googleSignIn.currentUser == null) return false;
    try {
      return await _googleSignIn.requestScopes([scope]);
    } catch (_) {
      return false;
    }
  }

  Future<calendar.CalendarApi?> _calendarApi() async {
    final account =
        _googleSignIn.currentUser ?? await _googleSignIn.signInSilently();
    if (account == null) return null;
    final headers = await account.authHeaders;
    return calendar.CalendarApi(_GoogleAuthClient(headers));
  }

  /// Manual "Sync now" (§9: "Sync trigger (import direction): manual
  /// 'Sync now' button in v1") — pulls the primary calendar's events in a
  /// window around now (-30d/+90d, a generous-but-bounded horizon,
  /// matching the convention already used for recurrence materialization)
  /// into `ExternalEvent`.
  Future<void> syncNow() async {
    final api = await _calendarApi();
    if (api == null) throw StateError('Not connected to Google Calendar.');

    final now = DateTime.now();
    final result = await api.events.list(
      'primary',
      timeMin: now.subtract(const Duration(days: 30)),
      timeMax: now.add(const Duration(days: 90)),
      singleEvents: true,
      orderBy: 'startTime',
    );
    await applyEvents(result.items ?? const []);
    await _settings.setValue(
      _calendarLastSyncedAtKey,
      DateTime.now().toIso8601String(),
    );
  }

  /// The actual write, separated from [syncNow]'s network call so it's
  /// testable without a live Google connection — construct `calendar.
  /// Event` objects directly and call this. A full replace, not a merge:
  /// clears every previously-synced row first, so an event deleted or
  /// moved outside the sync window on Google's side doesn't linger
  /// locally forever — "dedup by google_event_id" falls out for free
  /// since each sync starts from empty.
  @visibleForTesting
  Future<void> applyEvents(List<calendar.Event> events) async {
    final now = DateTime.now();
    await _db.transaction(() async {
      await (_db.delete(_db.externalEvents)).go();
      for (final event in events) {
        final googleId = event.id;
        final start = event.start?.dateTime ?? event.start?.date;
        if (googleId == null || start == null) continue;

        await _db
            .into(_db.externalEvents)
            .insert(
              ExternalEventsCompanion.insert(
                id: _uuid.v4(),
                googleEventId: googleId,
                calendarId: 'primary',
                title: _sanitizeTitle(event.summary),
                start: start,
                end: Value(event.end?.dateTime ?? event.end?.date),
                lastSyncedAt: now,
              ),
            );
      }
    });
  }

  /// Imported event titles come from the Google Calendar API — untrusted
  /// input (§9's security checklist: they can ultimately be set by anyone
  /// who invited the device owner to an event, not just the owner). Caps
  /// length and falls back for a missing/blank summary rather than
  /// storing whatever the API returned unchecked.
  static const _maxTitleLength = 300;

  String _sanitizeTitle(String? raw) {
    final trimmed = raw?.trim();
    if (trimmed == null || trimmed.isEmpty) return '(untitled)';
    return trimmed.length > _maxTitleLength
        ? trimmed.substring(0, _maxTitleLength)
        : trimmed;
  }

  /// Pushes one item to Google Calendar (§9, export) and returns the
  /// created event's id. Callers (the save-time trigger, the Item Detail
  /// manual toggle, the offline retry job) are responsible for the
  /// has-a-date / not-already-exported / mode checks and for writing the
  /// returned id back via `ItemRepository.setExternalCalendarEventId` —
  /// this method only knows how to talk to Google, not when it should.
  Future<String> exportItem({
    required String title,
    String? notes,
    required DateTime start,
  }) async {
    final api = await _calendarApi();
    if (api == null) throw StateError('Not connected to Google Calendar.');
    final event = calendar.Event(
      summary: title,
      description: notes,
      start: calendar.EventDateTime(dateTime: start, timeZone: 'UTC'),
      end: calendar.EventDateTime(
        dateTime: start.add(const Duration(hours: 1)),
        timeZone: 'UTC',
      ),
    );
    final created = await api.events.insert(event, 'primary');
    final id = created.id;
    if (id == null) {
      throw StateError('Google Calendar did not return an event id.');
    }
    return id;
  }

  /// Read path stays local-only — screens watch this instead of a live
  /// Google query, same "materialize then read locally" pattern already
  /// used for recurrence occurrences.
  Stream<List<ExternalEvent>> watchExternalEventsForRange(
    DateTime start,
    DateTime end,
  ) {
    return (_db.select(_db.externalEvents)
          ..where(
            (e) =>
                e.start.isBiggerOrEqualValue(start) &
                e.start.isSmallerThanValue(end),
          )
          ..orderBy([(e) => OrderingTerm(expression: e.start)]))
        .watch();
  }
}
