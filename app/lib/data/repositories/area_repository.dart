import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../domain/services/text_limits.dart';
import '../db/database.dart';

final _hexColorPattern = RegExp(r'^#[0-9A-Fa-f]{6}$');

/// Full area management for onboarding (§10: "renamed, recolored, deleted,
/// or left as-is"). Reorder/progress-tracking UI is still the V2 "Areas
/// screen" roadmap item — this repository only covers what onboarding and
/// quick-add need.
class AreaRepository {
  AreaRepository(this._db);

  final AppDatabase _db;
  static const _uuid = Uuid();

  /// Every caller today only ever passes one of the fixed
  /// `areaColorOptions` swatches, so this can't actually fail in
  /// practice — but `colorFromHex()` (called at render time, not here)
  /// throws an uncaught `FormatException` on anything malformed, so this
  /// repository shouldn't accept a bad value in the first place if a
  /// future caller ever passes something else through.
  void _validateColor(String color) {
    if (!_hexColorPattern.hasMatch(color)) {
      throw ArgumentError.value(
        color,
        'color',
        'Must be a #RRGGBB hex string.',
      );
    }
  }

  Stream<List<Area>> watchAll() {
    return (_db.select(_db.areas)
          ..where((a) => a.archived.equals(false))
          ..orderBy([(a) => OrderingTerm(expression: a.sortOrder)]))
        .watch();
  }

  Future<List<Area>> getAll() =>
      (_db.select(_db.areas)
            ..where((a) => a.archived.equals(false))
            ..orderBy([(a) => OrderingTerm(expression: a.sortOrder)]))
          .get();

  /// `null` if [id] no longer exists — the Areas screen's detail page uses
  /// this after an edit-sheet round trip to tell "was deleted" apart from
  /// "was renamed/recolored".
  Future<Area?> getById(String id) =>
      (_db.select(_db.areas)..where((a) => a.id.equals(id))).getSingleOrNull();

  /// Includes archived areas — nothing currently archives an area (onboarding
  /// now deletes outright instead of toggling), but this stays for §3's
  /// `archived` column to have a reader if something needs it later.
  Stream<List<Area>> watchAllIncludingArchived() {
    return (_db.select(
      _db.areas,
    )..orderBy([(a) => OrderingTerm(expression: a.sortOrder)])).watch();
  }

  Future<void> setArchived(String id, bool archived) {
    return (_db.update(_db.areas)..where((a) => a.id.equals(id))).write(
      AreasCompanion(archived: Value(archived)),
    );
  }

  Future<Area> createArea({required String name, required String color}) async {
    _validateColor(color);
    final all = await (_db.select(_db.areas)).get();
    final maxSort = all.isEmpty
        ? -1
        : all.map((a) => a.sortOrder).reduce((a, b) => a > b ? a : b);
    final id = _uuid.v4();
    await _db
        .into(_db.areas)
        .insert(
          AreasCompanion.insert(
            id: id,
            name: capLength(name, TextLimits.areaName),
            color: color,
            icon: 'custom',
            sortOrder: maxSort + 1,
          ),
        );
    return (_db.select(_db.areas)..where((a) => a.id.equals(id))).getSingle();
  }

  Future<void> rename(String id, String name) {
    return (_db.update(_db.areas)..where((a) => a.id.equals(id))).write(
      AreasCompanion(name: Value(capLength(name, TextLimits.areaName))),
    );
  }

  Future<void> recolor(String id, String color) {
    _validateColor(color);
    return (_db.update(_db.areas)..where((a) => a.id.equals(id))).write(
      AreasCompanion(color: Value(color)),
    );
  }

  /// A hard delete, not an archive — §10 explicitly says areas can be
  /// "deleted" during onboarding, and at that point nothing references
  /// them yet (fresh install, no items created). The V2 Areas screen may
  /// want a reassign-or-archive prompt for deletes once items exist (§12) —
  /// not needed here.
  Future<void> deleteArea(String id) {
    return (_db.delete(_db.areas)..where((a) => a.id.equals(id))).go();
  }
}
