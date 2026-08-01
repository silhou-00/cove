import 'dart:ui' show Color;

/// Cosmetic unlock catalog (§17) — ported verbatim from the design handoff
/// (`documents/cove-android-loft-design/project/Cove Prototype.dc.html`,
/// `SHEETS`/`PALS`/`COSMETICS` consts). Pure data, no image assets: pets
/// and furniture are 10×10 pixel sprites (a 5-cell half, mirrored) drawn
/// with a 3-4 color palette; accent themes are a single hex color; widget
/// skins are an id only (the native home-screen widget reads it, out of
/// scope for this Dart layer). `unlockLevel` matches
/// `Gamification.levelThresholds` exactly — one source of truth for the
/// level curve, this file only adds what unlocks at each rung.
enum CosmeticType { accentTheme, widgetSkin, pet, furniture }

class CosmeticDef {
  const CosmeticDef({
    required this.id,
    required this.name,
    required this.type,
    required this.unlockLevel,
    this.accent,
    this.sheet,
  });

  final String id;
  final String name;
  final CosmeticType type;
  final int unlockLevel;

  /// Set only for [CosmeticType.accentTheme].
  final Color? accent;

  /// Sprite sheet key into [PixelSprites.sheets]/[PixelSprites.palettes].
  /// Set only for [CosmeticType.pet]/[CosmeticType.furniture].
  final String? sheet;

  bool get isSlottable =>
      type == CosmeticType.pet || type == CosmeticType.furniture;
}

class Cosmetics {
  const Cosmetics._();

  static const catalog = <CosmeticDef>[
    CosmeticDef(
      id: 'dawn',
      name: 'Dawn',
      type: CosmeticType.accentTheme,
      unlockLevel: 2,
      accent: Color(0xFFB4586E),
    ),
    CosmeticDef(
      id: 'outline',
      name: 'Outline',
      type: CosmeticType.widgetSkin,
      unlockLevel: 3,
    ),
    CosmeticDef(
      id: 'fox',
      name: 'Fox',
      type: CosmeticType.pet,
      unlockLevel: 4,
      sheet: 'fox',
    ),
    CosmeticDef(
      id: 'lamp',
      name: 'Reading lamp',
      type: CosmeticType.furniture,
      unlockLevel: 5,
      sheet: 'lamp',
    ),
    CosmeticDef(
      id: 'bold',
      name: 'Bold',
      type: CosmeticType.widgetSkin,
      unlockLevel: 6,
    ),
    CosmeticDef(
      id: 'owl',
      name: 'Owl',
      type: CosmeticType.pet,
      unlockLevel: 7,
      sheet: 'owl',
    ),
    CosmeticDef(
      id: 'fern',
      name: 'Potted fern',
      type: CosmeticType.furniture,
      unlockLevel: 8,
      sheet: 'fern',
    ),
    CosmeticDef(
      id: 'mono',
      name: 'Mono',
      type: CosmeticType.widgetSkin,
      unlockLevel: 9,
    ),
    CosmeticDef(
      id: 'otter',
      name: 'Otter',
      type: CosmeticType.pet,
      unlockLevel: 10,
      sheet: 'otter',
    ),
  ];

  static CosmeticDef byId(String id) =>
      catalog.firstWhere((c) => c.id == id);

  static CosmeticDef? byIdOrNull(String? id) =>
      id == null ? null : catalog.where((c) => c.id == id).firstOrNull;
}

/// 10×10 pixel-sprite data (§17 "loft build" drawing rules): each sheet is
/// 10 rows of a 5-character half, mirrored to 10 characters wide. `.` is
/// transparent; every other character looks up a color in the matching
/// [palettes] entry.
class PixelSprites {
  const PixelSprites._();

  static String _mirror(String half) =>
      half + half.split('').reversed.join();

  static List<String> _grid(List<String> halves) =>
      halves.map(_mirror).toList(growable: false);

  static final sheets = <String, List<String>>{
    'fox': _grid([
      '..d..',
      '.dod.',
      '.dooo',
      'dokoo',
      'dooww',
      '.dowk',
      '.doww',
      '..doo',
      '..dww',
      '..dd.',
    ]),
    'owl': _grid([
      '..qs.',
      '.qsss',
      'qswws',
      'qswkw',
      'qsswb',
      'qsssw',
      '.qsww',
      '.qsww',
      '..qss',
      '..bb.',
    ]),
    'otter': _grid([
      '..u..',
      '.uuuu',
      'uukuu',
      'uuull',
      'uullk',
      '.ulll',
      '.ulll',
      '..ull',
      '..ull',
      '..ll.',
    ]),
    'fern': _grid([
      '...g.',
      '..ghg',
      '.ghgh',
      'ghghg',
      '.ghgh',
      '..hgh',
      '...hg',
      '.nppp',
      '..npp',
      '...nn',
    ]),
    'lamp': _grid([
      '...bb',
      '..bby',
      '.bbyy',
      'bbyyy',
      '....k',
      '....k',
      '....k',
      '....k',
      '..kkk',
      '.kkkk',
    ]),
  };

  static const palettes = <String, Map<String, Color>>{
    'fox': {
      'd': Color(0xFF7E3F2B),
      'o': Color(0xFFA4543A),
      'w': Color(0xFFF4F1EB),
      'k': Color(0xFF1B1917),
    },
    'owl': {
      'q': Color(0xFF33404F),
      's': Color(0xFF4A5A70),
      'w': Color(0xFFF4F1EB),
      'k': Color(0xFF1B1917),
      'b': Color(0xFFA07A2C),
    },
    'otter': {
      'u': Color(0xFF7A5B47),
      'l': Color(0xFFA98B72),
      'k': Color(0xFF1B1917),
      'w': Color(0xFFF4F1EB),
    },
    'fern': {
      'g': Color(0xFF3F6F6A),
      'h': Color(0xFF2A4E4A),
      'p': Color(0xFFA4543A),
      'n': Color(0xFF7E3F2B),
    },
    'lamp': {
      'b': Color(0xFFA07A2C),
      'y': Color(0xFFE8C88A),
      'k': Color(0xFF1B1917),
    },
  };
}
