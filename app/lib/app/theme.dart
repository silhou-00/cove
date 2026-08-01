import 'package:flutter/material.dart';

/// The design (`documents/cove-android-loft-design`) was authored inside a
/// fixed 360×640dp mockup frame — every size in it assumes that canvas. A
/// real phone is wider and much taller, so the same absolute sizes read as
/// smaller/sparser on it. This scales design values up proportionally to
/// the device's actual width, clamped so it doesn't run away on a tablet.
const _designWidth = 360.0;

double appScale(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  return (width / _designWidth).clamp(1.0, 1.35);
}

extension AppScale on BuildContext {
  /// Scales a design-mockup value (px in the source HTML, treated as dp)
  /// up to this device's actual size.
  double s(double designValue) => designValue * appScale(this);
}

/// Theme-reactive design tokens (§11) — background/surface/ink/border
/// shades that must swap between light and dark. Resolved per-[BuildContext]
/// via `context.colors`, never as static constants, so every consumer
/// rebuilds automatically when the theme mode changes.
///
/// The dark palette has no source-of-truth mockup (the design handoff only
/// covers light mode) — it's an original derivation that mirrors the light
/// palette's warm, low-saturation character rather than a generic
/// blue-black Material dark theme.
@immutable
class AppColorTokens extends ThemeExtension<AppColorTokens> {
  const AppColorTokens({
    required this.background,
    required this.surface,
    required this.ink,
    required this.inkMuted,
    required this.inkFaint,
    required this.inkFainter,
    required this.inkDisabled,
    required this.border,
    required this.borderSubtle,
    required this.borderFaint,
    required this.progressInactive,
    required this.accent,
    required this.accentDark,
  });

  final Color background;
  final Color surface;
  final Color ink;
  final Color inkMuted;
  final Color inkFaint;
  final Color inkFainter;
  final Color inkDisabled;
  final Color border;
  final Color borderSubtle;
  final Color borderFaint;
  final Color progressInactive;
  final Color accent;
  final Color accentDark;

  static const light = AppColorTokens(
    background: Color(0xFFF4F1EB),
    surface: Color(0xFFFCFAF6),
    ink: Color(0xFF1B1917),
    inkMuted: Color(0xFF6B6459),
    inkFaint: Color(0xFF8A8175),
    inkFainter: Color(0xFF9A9287),
    inkDisabled: Color(0xFFB5AC9E),
    border: Color(0xFFE0DACE),
    borderSubtle: Color(0xFFE7E1D6),
    borderFaint: Color(0xFFEFEAE1),
    progressInactive: Color(0xFFDED8CC),
    accent: Color(0xFFA4543A),
    accentDark: Color(0xFF7E3F2B),
  );

  static const dark = AppColorTokens(
    background: Color(0xFF171513),
    surface: Color(0xFF201D1B),
    ink: Color(0xFFF4F1EB),
    inkMuted: Color(0xFFB0A99C),
    inkFaint: Color(0xFF8F877A),
    inkFainter: Color(0xFF766F64),
    inkDisabled: Color(0xFF5C564C),
    border: Color(0xFF3A3532),
    borderSubtle: Color(0xFF2E2A27),
    borderFaint: Color(0xFF262220),
    progressInactive: Color(0xFF3A3532),
    // Brand/accent hue stays constant across themes (category identity,
    // same reasoning as areaXxx below) — only structural neutrals swap.
    accent: Color(0xFFA4543A),
    accentDark: Color(0xFF7E3F2B),
  );

  @override
  AppColorTokens copyWith({
    Color? background,
    Color? surface,
    Color? ink,
    Color? inkMuted,
    Color? inkFaint,
    Color? inkFainter,
    Color? inkDisabled,
    Color? border,
    Color? borderSubtle,
    Color? borderFaint,
    Color? progressInactive,
    Color? accent,
    Color? accentDark,
  }) {
    return AppColorTokens(
      background: background ?? this.background,
      surface: surface ?? this.surface,
      ink: ink ?? this.ink,
      inkMuted: inkMuted ?? this.inkMuted,
      inkFaint: inkFaint ?? this.inkFaint,
      inkFainter: inkFainter ?? this.inkFainter,
      inkDisabled: inkDisabled ?? this.inkDisabled,
      border: border ?? this.border,
      borderSubtle: borderSubtle ?? this.borderSubtle,
      borderFaint: borderFaint ?? this.borderFaint,
      progressInactive: progressInactive ?? this.progressInactive,
      accent: accent ?? this.accent,
      accentDark: accentDark ?? this.accentDark,
    );
  }

  @override
  AppColorTokens lerp(ThemeExtension<AppColorTokens>? other, double t) {
    if (other is! AppColorTokens) return this;
    return AppColorTokens(
      background: Color.lerp(background, other.background, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      ink: Color.lerp(ink, other.ink, t)!,
      inkMuted: Color.lerp(inkMuted, other.inkMuted, t)!,
      inkFaint: Color.lerp(inkFaint, other.inkFaint, t)!,
      inkFainter: Color.lerp(inkFainter, other.inkFainter, t)!,
      inkDisabled: Color.lerp(inkDisabled, other.inkDisabled, t)!,
      border: Color.lerp(border, other.border, t)!,
      borderSubtle: Color.lerp(borderSubtle, other.borderSubtle, t)!,
      borderFaint: Color.lerp(borderFaint, other.borderFaint, t)!,
      progressInactive: Color.lerp(
        progressInactive,
        other.progressInactive,
        t,
      )!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentDark: Color.lerp(accentDark, other.accentDark, t)!,
    );
  }
}

extension AppColorsContext on BuildContext {
  /// The active theme's color tokens (§11) — use this instead of a fixed
  /// `AppColors` constant everywhere the color must change between
  /// light/dark. Falls back to [AppColorTokens.light] only if the
  /// extension was somehow never registered (defensive; `buildAppTheme`
  /// always registers it).
  AppColorTokens get colors =>
      Theme.of(this).extension<AppColorTokens>() ?? AppColorTokens.light;
}

/// Design tokens from the handoff in
/// `documents/cove-android-loft-design/project/Cove Prototype.dc.html`.
///
/// Only colors that are deliberately theme-**invariant** live here now —
/// everything else moved to [AppColorTokens] (`context.colors`) so it can
/// react to light/dark/system (§11). `dark` stays fixed because it's used
/// for surfaces that are always dark regardless of app theme (splash
/// screen, app-lock pad); the `areaXxx` set stays fixed because an area's
/// color is its category identity, not a theme-reactive token.
class AppColors {
  const AppColors._();

  static const dark = Color(0xFF1B1917);

  static const areaSchool = Color(0xFF6E4C6D);
  static const areaWork = Color(0xFF3F6F6A);
  static const areaPersonal = Color(0xFFA4543A);
  static const areaProjects = Color(0xFFA07A2C);
  static const areaCerts = Color(0xFF4A5A70);
}

/// A [Color] paired with its `#RRGGBB` storage form — avoids a runtime
/// Color-to-hex conversion for the fixed palette offered when
/// creating/recoloring an area (§10).
class AreaColorOption {
  const AreaColorOption(this.color, this.hex);
  final Color color;
  final String hex;
}

const areaColorOptions = [
  AreaColorOption(AppColors.areaSchool, '#6E4C6D'),
  AreaColorOption(AppColors.areaWork, '#3F6F6A'),
  AreaColorOption(AppColors.areaPersonal, '#A4543A'),
  AreaColorOption(AppColors.areaProjects, '#A07A2C'),
  AreaColorOption(AppColors.areaCerts, '#4A5A70'),
  AreaColorOption(
    Color(0xFFB4586E),
    '#B4586E',
  ), // Dawn — design's accent-theme unlock color
  AreaColorOption(Color(0xFF7A5B47), '#7A5B47'),
];

class AppTypography {
  const AppTypography._();

  static const sansFamily = 'IBM Plex Sans';
  static const monoFamily = 'IBM Plex Mono';
  static const wordmarkFamily = 'Bricolage Grotesque';

  // Fixed (not theme-reactive) colors: both call sites render against the
  // splash screen's permanently-dark backdrop (`AppColors.dark`, itself
  // fixed — see theme.dart's `AppColors` doc) or override the color
  // themselves (about_screen's wordmark), so these must not flip with the
  // app's light/dark setting.
  static TextStyle wordmark(BuildContext context) => TextStyle(
    fontFamily: wordmarkFamily,
    fontWeight: FontWeight.w700,
    fontSize: context.s(48),
    letterSpacing: context.s(-2.6),
    color: AppColorTokens.light.surface,
  );

  static TextStyle tagline(BuildContext context) => TextStyle(
    fontFamily: monoFamily,
    fontSize: context.s(10),
    letterSpacing: context.s(2.8),
    color: AppColorTokens.light.inkFaint,
  );

  // These five accept an optional [tokens] override — `buildAppTheme` is
  // called with a [context] whose ambient `Theme.of(context)` is still the
  // *previous* theme (the new one isn't applied yet), so it must pass the
  // tokens it just built explicitly instead of relying on `context.colors`.
  // Every other call site (regular widget builds, post-Theme) omits it and
  // gets the correct live lookup.
  static TextStyle headline(BuildContext context, {AppColorTokens? tokens}) =>
      TextStyle(
        fontFamily: sansFamily,
        fontSize: context.s(30),
        fontWeight: FontWeight.w600,
        letterSpacing: context.s(-0.6),
        height: 1.15,
        color: (tokens ?? context.colors).ink,
      );

  static TextStyle sectionHeader(
    BuildContext context, {
    AppColorTokens? tokens,
  }) => TextStyle(
    fontFamily: sansFamily,
    fontSize: context.s(17),
    fontWeight: FontWeight.w600,
    color: (tokens ?? context.colors).ink,
  );

  static TextStyle itemTitle(BuildContext context, {AppColorTokens? tokens}) =>
      TextStyle(
        fontFamily: sansFamily,
        fontSize: context.s(15),
        fontWeight: FontWeight.w400,
        color: (tokens ?? context.colors).ink,
      );

  static TextStyle body(BuildContext context, {AppColorTokens? tokens}) =>
      TextStyle(
        fontFamily: sansFamily,
        fontSize: context.s(14),
        fontWeight: FontWeight.w400,
        height: 1.5,
        color: (tokens ?? context.colors).inkMuted,
      );

  static TextStyle secondaryMeta(
    BuildContext context, {
    AppColorTokens? tokens,
  }) => TextStyle(
    fontFamily: sansFamily,
    fontSize: context.s(13),
    fontWeight: FontWeight.w400,
    color: (tokens ?? context.colors).inkMuted,
  );

  static TextStyle mono(BuildContext context) => TextStyle(
    fontFamily: monoFamily,
    fontSize: context.s(12),
    letterSpacing: context.s(0.5),
    color: context.colors.inkMuted,
  );

  static TextStyle monoLabel(BuildContext context) => TextStyle(
    fontFamily: monoFamily,
    fontSize: context.s(10),
    fontWeight: FontWeight.w500,
    letterSpacing: context.s(1.2),
    color: context.colors.inkFaint,
  );

  static TextStyle button(BuildContext context) => TextStyle(
    fontFamily: sansFamily,
    fontSize: context.s(15),
    fontWeight: FontWeight.w500,
  );
}

/// Parses a `#RRGGBB` hex string (as stored on `Area.color`) into a [Color].
Color colorFromHex(String hex) {
  return Color(int.parse('FF${hex.replaceFirst('#', '')}', radix: 16));
}

/// [accentOverride] is the equipped accent-theme cosmetic's color (§17,
/// e.g. Dawn), or `null` for the base theme. `accentDark` is derived by
/// darkening it rather than requiring a second designer-authored hex,
/// since the catalog only specifies one color per accent theme.
ThemeData buildAppTheme(
  BuildContext context, {
  required Brightness brightness,
  Color? accentOverride,
}) {
  final baseTokens = brightness == Brightness.dark
      ? AppColorTokens.dark
      : AppColorTokens.light;
  final tokens = accentOverride == null
      ? baseTokens
      : baseTokens.copyWith(
          accent: accentOverride,
          accentDark: Color.lerp(accentOverride, Colors.black, 0.18),
        );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    scaffoldBackgroundColor: tokens.background,
    fontFamily: AppTypography.sansFamily,
    colorScheme: ColorScheme.fromSeed(
      seedColor: tokens.accent,
      brightness: brightness,
      surface: tokens.surface,
      onSurface: tokens.ink,
    ),
    extensions: [tokens],
    textTheme: TextTheme(
      headlineMedium: AppTypography.headline(context),
      titleMedium: AppTypography.sectionHeader(context),
      bodyLarge: AppTypography.itemTitle(context),
      bodyMedium: AppTypography.body(context),
      bodySmall: AppTypography.secondaryMeta(context),
    ),
  );
}
