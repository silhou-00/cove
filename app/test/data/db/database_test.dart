import 'package:app/data/db/database.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  test('onCreate seeds the four preset areas', () async {
    final seeded = await db.select(db.areas).get();

    expect(seeded, hasLength(4));
    expect(
      seeded.map((a) => a.name),
      containsAllInOrder(['School', 'Work', 'Personal', 'Projects']),
    );

    final byName = {for (final a in seeded) a.name: a};
    expect(byName['School']!.color, '#6E4C6D');
    expect(byName['Work']!.color, '#3F6F6A');
    expect(byName['Personal']!.color, '#A4543A');
    expect(byName['Projects']!.color, '#A07A2C');

    for (final a in seeded) {
      expect(a.archived, isFalse);
    }
    expect(seeded.map((a) => a.sortOrder), containsAllInOrder([0, 1, 2, 3]));
  });
}
