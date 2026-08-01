import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/tap_scale.dart';
import '../../app/theme.dart';
import '../agenda/agenda_screen.dart';
import '../agenda/quick_add_sheet.dart';
import '../areas/areas_screen.dart';
import '../calendar/calendar_export_trigger.dart';
import '../calendar/calendar_screen.dart';
import '../settings/settings_screen.dart';

/// Persistent bottom nav shell (§5's `isApp` container). All four
/// destinations are real now — Settings is deliberately minimal; see
/// documents/documentation.md for what's still logged as a gap rather
/// than built.
///
/// Builds only the active tab, not all four at once. `IndexedStack` was
/// used originally and built every tab immediately on app start,
/// including Settings — which eagerly constructs `CalendarSyncRepository`
/// and therefore `GoogleSignIn()` before anyone's touched that tab.
/// Without a configured OAuth client that stalled badly enough to make
/// the whole app appear laggy and the Agenda tab render blank. Trade-off:
/// switching tabs no longer preserves each screen's scroll/local state —
/// worth revisiting with a proper lazy-keep-alive pattern if that's
/// missed.
class AppShellScreen extends ConsumerStatefulWidget {
  const AppShellScreen({
    super.key,
    this.initialIndex = 0,
    this.initialAgendaUpNext = false,
  });
  final int initialIndex;

  /// Only meaningful when [initialIndex] is 0 (Agenda) — the Up Next/
  /// Agenda home-screen widgets deep-link here to land on Agenda's Up
  /// Next sub-view instead of Today.
  final bool initialAgendaUpNext;

  @override
  ConsumerState<AppShellScreen> createState() => _AppShellScreenState();
}

class _AppShellScreenState extends ConsumerState<AppShellScreen> {
  late int _index = widget.initialIndex;

  Widget _buildActiveScreen() {
    switch (_index) {
      case 0:
        return AgendaScreen(initialUpNext: widget.initialAgendaUpNext);
      case 1:
        return const CalendarScreen();
      case 2:
        return const AreasScreen();
      default:
        return const SettingsScreen();
    }
  }

  /// Add-task now lives on the shared nav (not just Agenda's old FAB), so
  /// it's reachable from every tab. Runs the §9 export trigger with this
  /// screen's own long-lived context, once the quick-add sheet (whose own
  /// context is about to unmount) has already closed — see
  /// `showQuickAddSheet`'s doc comment.
  Future<void> _addItem() async {
    final item = await showQuickAddSheet(context);
    if (item != null && mounted) {
      await maybeExportToCalendar(context, ref, item);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.colors.background,
      // Fade only, not slide — a slide would need the outgoing and
      // incoming screens laid out simultaneously (each screen here builds
      // its own Scaffold/lists), which is more relayout work per frame
      // than this needs for a bottom-nav switch.
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 150),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        transitionBuilder: (child, animation) =>
            FadeTransition(opacity: animation, child: child),
        child: _buildActiveScreen(),
      ),
      bottomNavigationBar: _BottomNav(
        index: _index,
        onChanged: (i) => setState(() => _index = i),
        onAdd: _addItem,
      ),
    );
  }
}

/// One continuous pill with a real circular notch cut into its top edge
/// (via `Path.combine`, not a widget just layered on top) — the add-task
/// button sits inside that notch with a small gap all the way around it,
/// matching the user's sketch of the bar's own outline curving around the
/// button rather than the button merely floating over a flat top edge.
///
/// Every nav item gets the same fixed width regardless of active state —
/// the previous version let the active tab's label widen its own item,
/// which silently shifted the pill's total width (and so the notch's
/// centered position) depending on which tab happened to be selected.
class _BottomNav extends StatelessWidget {
  const _BottomNav({
    required this.index,
    required this.onChanged,
    required this.onAdd,
  });
  final int index;
  final ValueChanged<int> onChanged;
  final VoidCallback onAdd;

  static const _itemWidth = 56.0;
  static const _smallGap = 6.0;
  // Half of this must clear the notch's full radius (fabSize/2 +
  // notchPadding = 35) — `ClipPath` (see `_NotchedPillClipper`) rejects
  // hit-testing for anything inside the cutout, not just the paint, so a
  // gap that's too small doesn't just look wrong, it makes the inner
  // edge of Calendar/Areas genuinely untappable.
  static const _bigGap = 72.0;
  static const _horizontalInset = 10.0;
  static const _pillHeight = 56.0;
  static const _fabSize = 50.0;
  static const _notchPadding = 10.0;
  static const _cornerRadius = 20.0;
  static const _bottomMargin = 18.0;
  // How far to shift the button/notch down from the pill's top edge —
  // 0 would straddle it exactly half-above/half-below; positive values
  // sink it further into the pill so less of it pokes up above the bar.
  static const _buttonLowerOffset = 12.0;

  @override
  Widget build(BuildContext context) {
    final itemWidth = context.s(_itemWidth);
    final smallGap = context.s(_smallGap);
    final bigGap = context.s(_bigGap);
    final horizontalInset = context.s(_horizontalInset);
    final pillHeight = context.s(_pillHeight);
    final fabSize = context.s(_fabSize);
    final notchRadius = fabSize / 2 + context.s(_notchPadding);
    // The Row of nav items is inset from the pill's own edges by
    // horizontalInset on each side — without it, the active tab's
    // highlight rectangle sits flush against the pill's rounded corner
    // and its square-ish edge pokes past that curve.
    final pillWidth =
        itemWidth * 4 + smallGap * 2 + bigGap + horizontalInset * 2;
    final boxHeight = pillHeight + notchRadius;
    final notchCenter = Offset(
      pillWidth / 2,
      boxHeight - pillHeight + context.s(_buttonLowerOffset),
    );

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: context.s(_bottomMargin)),
        child: Center(
          // heightFactor pins Center to its child's natural height. Without
          // it, Center fills the full loose height Scaffold offers the
          // bottomNavigationBar slot (up to the whole screen) — which then
          // makes Scaffold think the nav bar is screen-height tall and
          // gives `body` zero height left over, rendering the entire app
          // blank below the status bar with only this pill floating
          // mid-screen. widthFactor stays unset so it still centers
          // horizontally as intended.
          heightFactor: 1,
          child: SizedBox(
            width: pillWidth,
            height: boxHeight,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                CustomPaint(
                  size: Size(pillWidth, boxHeight),
                  painter: _NotchedPillPainter(
                    pillRect: Rect.fromLTWH(
                      0,
                      boxHeight - pillHeight,
                      pillWidth,
                      pillHeight,
                    ),
                    cornerRadius: context.s(_cornerRadius),
                    notchCenter: notchCenter,
                    notchRadius: notchRadius,
                    fillColor: context.colors.surface.withValues(alpha: 0.92),
                    borderColor: context.colors.borderSubtle,
                  ),
                ),
                Positioned(
                  left: horizontalInset,
                  right: horizontalInset,
                  top: boxHeight - pillHeight,
                  height: pillHeight,
                  // Clips the active-tab highlight (and anything else drawn
                  // in this layer) to the same pill-minus-notch shape the
                  // background is painted with — without this, the
                  // highlight is a plain rounded rect that ignores the
                  // notch entirely, so it doesn't "bend" where the pill's
                  // own outline curves inward near the button.
                  child: ClipPath(
                    clipper: _NotchedPillClipper(
                      pillRect: Rect.fromLTWH(
                        -horizontalInset,
                        0,
                        pillWidth,
                        pillHeight,
                      ),
                      cornerRadius: context.s(_cornerRadius),
                      notchCenter: Offset(
                        notchCenter.dx - horizontalInset,
                        context.s(_buttonLowerOffset),
                      ),
                      notchRadius: notchRadius,
                    ),
                    child: Row(
                      children: [
                        SizedBox(
                          width: itemWidth,
                          child: _NavItem(
                            icon: Icons.view_agenda_outlined,
                            label: 'AGENDA',
                            active: index == 0,
                            onTap: () => onChanged(0),
                          ),
                        ),
                        SizedBox(width: smallGap),
                        SizedBox(
                          width: itemWidth,
                          child: _NavItem(
                            icon: Icons.calendar_today_outlined,
                            label: 'CALENDAR',
                            active: index == 1,
                            onTap: () => onChanged(1),
                          ),
                        ),
                        SizedBox(width: bigGap),
                        SizedBox(
                          width: itemWidth,
                          child: _NavItem(
                            icon: Icons.grid_view_outlined,
                            label: 'AREAS',
                            active: index == 2,
                            onTap: () => onChanged(2),
                          ),
                        ),
                        SizedBox(width: smallGap),
                        SizedBox(
                          width: itemWidth,
                          child: _NavItem(
                            icon: Icons.settings_outlined,
                            label: 'SETTINGS',
                            active: index == 3,
                            onTap: () => onChanged(3),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  left: notchCenter.dx - fabSize / 2,
                  top: notchCenter.dy - fabSize / 2,
                  child: _AddButton(size: fabSize, onTap: onAdd),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The pill-minus-notch outline shared by [_NotchedPillPainter] (draws it)
/// and [_NotchedPillClipper] (clips the nav-items layer to it, so the
/// active-tab highlight bends with the same curve instead of ignoring it).
Path _notchedPillPath({
  required Rect pillRect,
  required double cornerRadius,
  required Offset notchCenter,
  required double notchRadius,
}) {
  final pillPath = Path()
    ..addRRect(RRect.fromRectAndRadius(pillRect, Radius.circular(cornerRadius)));
  final notchPath = Path()
    ..addOval(Rect.fromCircle(center: notchCenter, radius: notchRadius));
  return Path.combine(PathOperation.difference, pillPath, notchPath);
}

/// Cuts a circular notch out of the pill's top edge (`Path.combine` with
/// `PathOperation.difference`) instead of drawing the button as a separate
/// layer on top of an unbroken pill — the pill's own outline bends around
/// the button, leaving a visible ring gap ([_BottomNav._notchPadding])
/// between the button's edge and the notch wall.
class _NotchedPillPainter extends CustomPainter {
  const _NotchedPillPainter({
    required this.pillRect,
    required this.cornerRadius,
    required this.notchCenter,
    required this.notchRadius,
    required this.fillColor,
    required this.borderColor,
  });

  final Rect pillRect;
  final double cornerRadius;
  final Offset notchCenter;
  final double notchRadius;
  final Color fillColor;
  final Color borderColor;

  @override
  void paint(Canvas canvas, Size size) {
    final shape = _notchedPillPath(
      pillRect: pillRect,
      cornerRadius: cornerRadius,
      notchCenter: notchCenter,
      notchRadius: notchRadius,
    );
    canvas.drawPath(shape, Paint()..color = fillColor);
    canvas.drawPath(
      shape,
      Paint()
        ..color = borderColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _NotchedPillPainter oldDelegate) =>
      oldDelegate.pillRect != pillRect ||
      oldDelegate.notchCenter != notchCenter ||
      oldDelegate.notchRadius != notchRadius ||
      oldDelegate.fillColor != fillColor ||
      oldDelegate.borderColor != borderColor;
}

class _NotchedPillClipper extends CustomClipper<Path> {
  const _NotchedPillClipper({
    required this.pillRect,
    required this.cornerRadius,
    required this.notchCenter,
    required this.notchRadius,
  });

  final Rect pillRect;
  final double cornerRadius;
  final Offset notchCenter;
  final double notchRadius;

  @override
  Path getClip(Size size) => _notchedPillPath(
    pillRect: pillRect,
    cornerRadius: cornerRadius,
    notchCenter: notchCenter,
    notchRadius: notchRadius,
  );

  @override
  bool shouldReclip(covariant _NotchedPillClipper oldClipper) =>
      oldClipper.pillRect != pillRect ||
      oldClipper.notchCenter != notchCenter ||
      oldClipper.notchRadius != notchRadius;
}

class _AddButton extends StatelessWidget {
  const _AddButton({required this.size, required this.onTap});
  final double size;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TapScale(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: context.colors.accent,
          shape: BoxShape.circle,
        ),
        child: Icon(
          Icons.add,
          color: context.colors.surface,
          size: context.s(20),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TapScale(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        height: context.s(44),
        decoration: BoxDecoration(
          color: active
              ? context.colors.accent.withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(context.s(14)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: context.s(16),
              color: active ? context.colors.ink : context.colors.inkFaint,
            ),
            if (active) ...[
              SizedBox(height: context.s(3)),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  style: AppTypography.monoLabel(
                    context,
                  ).copyWith(fontSize: context.s(8.5), color: context.colors.ink),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
