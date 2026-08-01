import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../domain/services/text_limits.dart';
import '../db/database.dart';

/// Tags (§3 `Tag`/`ItemTag`, §4 "Tags, independent of area, many-to-many").
/// Case-insensitive matching/dedup, same convention as `@area` matching in
/// quick-add — `Tags.name` has a SQL-level unique constraint, but SQLite's
/// default text comparison is case-sensitive, so dedup has to happen in
/// Dart against the existing rows, not left to the constraint.
class TagRepository {
  TagRepository(this._db);

  final AppDatabase _db;
  static const _uuid = Uuid();

  Stream<List<Tag>> watchAll() {
    return (_db.select(
      _db.tags,
    )..orderBy([(t) => OrderingTerm(expression: t.name)])).watch();
  }

  Future<List<Tag>> getAll() => (_db.select(
    _db.tags,
  )..orderBy([(t) => OrderingTerm(expression: t.name)])).get();

  Stream<List<Tag>> watchTagsForItem(String itemId) {
    final query =
        _db.select(_db.tags).join([
            innerJoin(_db.itemTags, _db.itemTags.tagId.equalsExp(_db.tags.id)),
          ])
          ..where(_db.itemTags.itemId.equals(itemId))
          ..orderBy([OrderingTerm(expression: _db.tags.name)]);
    return query.watch().map(
      (rows) => rows.map((r) => r.readTable(_db.tags)).toList(),
    );
  }

  /// Finds each name's existing [Tag] (case-insensitive) or creates it,
  /// then links all of them to [itemId] — replacing whatever tags were
  /// linked before. Safe to call with an empty list (clears all tags).
  Future<void> setTagsForItem(String itemId, List<String> names) async {
    await _db.transaction(() async {
      final existing = await getAll();
      final byLowerName = {for (final t in existing) t.name.toLowerCase(): t};

      final tagIds = <String>[];
      for (final name in names) {
        final trimmed = capLength(name, TextLimits.tagName);
        if (trimmed.isEmpty) continue;
        final found = byLowerName[trimmed.toLowerCase()];
        if (found != null) {
          tagIds.add(found.id);
        } else {
          final id = _uuid.v4();
          await _db
              .into(_db.tags)
              .insert(TagsCompanion.insert(id: id, name: trimmed));
          byLowerName[trimmed.toLowerCase()] = Tag(id: id, name: trimmed);
          tagIds.add(id);
        }
      }

      await (_db.delete(
        _db.itemTags,
      )..where((it) => it.itemId.equals(itemId))).go();
      for (final tagId in tagIds) {
        await _db
            .into(_db.itemTags)
            .insert(ItemTagsCompanion.insert(itemId: itemId, tagId: tagId));
      }
    });
  }
}
