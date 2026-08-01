import 'package:app/domain/services/cosmetics.dart';
import 'package:app/domain/services/gamification.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Cosmetics.catalog (§17)', () {
    test('has exactly the 9 catalog entries from the design handoff', () {
      expect(Cosmetics.catalog, hasLength(9));
      expect(Cosmetics.catalog.map((c) => c.id), [
        'dawn',
        'outline',
        'fox',
        'lamp',
        'bold',
        'owl',
        'fern',
        'mono',
        'otter',
      ]);
    });

    test('every unlockLevel is a real rung on the level curve', () {
      for (final def in Cosmetics.catalog) {
        expect(Gamification.levelThresholds, contains(def.unlockLevel));
      }
    });

    test('accent theme entries carry a color, others do not', () {
      for (final def in Cosmetics.catalog) {
        expect(
          def.accent != null,
          def.type == CosmeticType.accentTheme,
          reason: '${def.id} accent-presence mismatch',
        );
      }
    });

    test('pet/furniture entries carry a sheet key, others do not', () {
      for (final def in Cosmetics.catalog) {
        expect(def.sheet != null, def.isSlottable, reason: '${def.id} sheet-presence mismatch');
      }
    });

    test('byId finds a known entry, byIdOrNull is null-safe', () {
      expect(Cosmetics.byId('fox').name, 'Fox');
      expect(Cosmetics.byIdOrNull('fox'), isNotNull);
      expect(Cosmetics.byIdOrNull('nope'), isNull);
      expect(Cosmetics.byIdOrNull(null), isNull);
    });
  });

  group('PixelSprites (§17 "loft build" drawing rules)', () {
    test('every sheet is a mirrored 10x10 grid', () {
      for (final entry in PixelSprites.sheets.entries) {
        final rows = entry.value;
        expect(rows, hasLength(10), reason: '${entry.key} row count');
        for (final row in rows) {
          expect(row, hasLength(10), reason: '${entry.key} row width');
          // Drawn as a 5-cell half then mirrored — the second half must be
          // the reverse of the first.
          final half = row.substring(0, 5);
          final mirrored = row.substring(5);
          expect(
            mirrored,
            half.split('').reversed.join(),
            reason: '${entry.key} row not mirrored: $row',
          );
        }
      }
    });

    test('every non-"." character in a sheet has a palette color', () {
      for (final entry in PixelSprites.sheets.entries) {
        final palette = PixelSprites.palettes[entry.key]!;
        for (final row in entry.value) {
          for (final ch in row.split('')) {
            if (ch == '.') continue;
            expect(
              palette,
              contains(ch),
              reason: '${entry.key} missing palette color for "$ch"',
            );
          }
        }
      }
    });

    test('has a sheet/palette for every slottable catalog entry', () {
      for (final def in Cosmetics.catalog.where((c) => c.isSlottable)) {
        expect(PixelSprites.sheets, contains(def.sheet));
        expect(PixelSprites.palettes, contains(def.sheet));
      }
    });
  });
}
