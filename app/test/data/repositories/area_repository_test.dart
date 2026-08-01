import 'package:app/data/db/database.dart';
import 'package:app/data/repositories/area_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late AreaRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = AreaRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('createArea adds a new area after the existing sort order', () async {
    final created = await repo.createArea(name: 'Fitness', color: '#4A5A70');

    expect(created.name, 'Fitness');
    expect(created.color, '#4A5A70');
    expect(created.sortOrder, 4); // after the 4 seeded presets (0-3)

    final all = await repo.getAll();
    expect(all.map((a) => a.name), contains('Fitness'));
  });

  test('rename and recolor update the existing row in place', () async {
    final areas = await repo.getAll();
    final school = areas.firstWhere((a) => a.name == 'School');

    await repo.rename(school.id, 'Uni');
    await repo.recolor(school.id, '#123456');

    final updated = (await repo.getAll()).firstWhere((a) => a.id == school.id);
    expect(updated.name, 'Uni');
    expect(updated.color, '#123456');
  });

  test('deleteArea removes the row entirely, not just archives it', () async {
    final areas = await repo.getAll();
    final projects = areas.firstWhere((a) => a.name == 'Projects');

    await repo.deleteArea(projects.id);

    final remainingIncludingArchived = await db.select(db.areas).get();
    expect(remainingIncludingArchived.any((a) => a.id == projects.id), isFalse);
  });
}
