import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../features/app_lock/lock_screen.dart';
import '../features/home/app_shell_screen.dart';
import '../features/item/item_deep_link_screen.dart';
import '../features/onboarding/onboarding_screen.dart';
import '../features/splash/splash_screen.dart';
import 'session_lock.dart';

/// Routes reachable while locked — everything else redirects to `/lock`
/// when App Lock is on and this session hasn't passed it yet (§12).
const _lockExemptPaths = {'/', '/onboarding', '/lock'};

/// `/home`'s `extra` shape — which bottom-nav tab, and (only meaningful
/// for tab 0) whether Agenda should open straight to its Up Next sub-view.
/// Onboarding's Settings-breadcrumb deep link and the Up Next/Agenda/Areas
/// widget taps (see `app.dart`'s `_openFromWidgetUri`) are the only
/// callers that ever pass this.
typedef HomeRouteArgs = ({int tabIndex, bool upNext});

const _defaultHomeArgs = (tabIndex: 0, upNext: false);

/// Cross-fade instead of go_router/Android's default slide-in — used for
/// every top-level route so splash → onboarding/home doesn't cut instantly.
/// Fade only (no scale/slide) keeps it cheap: one Opacity layer, no extra
/// relayout per frame.
///
/// [key] matters specifically for `/home`: `AppShellScreen`/`AgendaScreen`
/// seed their tab/sub-view from a `late` field on first build only, so
/// re-navigating to `/home` with different `extra` while the app (and
/// that Page) is already alive wouldn't otherwise rebuild those State
/// objects at all — go_router's Navigator diffs pages by key, and an
/// unkeyed page at the same path is treated as unchanged. Keying the page
/// by the actual `extra` content forces a fresh page (and fresh State)
/// whenever it differs, e.g. the Up Next widget tap needing to land on
/// the Up Next sub-view even if Agenda/Today was already showing.
CustomTransitionPage<void> _fadeThrough(Widget child, {LocalKey? key}) {
  return CustomTransitionPage(
    key: key,
    child: child,
    transitionDuration: const Duration(milliseconds: 220),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      return FadeTransition(opacity: animation, child: child);
    },
  );
}

/// `cove://item/[id]` (§6/§7) resolves to this path — shared by notification
/// taps (this step) and, later, home-screen widget taps (step 6).
final appRouter = GoRouter(
  initialLocation: '/',
  refreshListenable: SessionLock.instance,
  // §12 — the actual App Lock boundary. Splash's own check only covers a
  // normal cold-start navigation into the app; a notification tap or
  // home-screen widget tap calls appRouter.go(...) directly and would
  // otherwise land straight on protected content.
  redirect: (context, state) {
    if (_lockExemptPaths.contains(state.matchedLocation)) return null;
    final lock = SessionLock.instance;
    if (lock.enabled && !lock.unlocked) return '/lock';
    return null;
  },
  routes: [
    GoRoute(
      path: '/',
      pageBuilder: (context, state) => _fadeThrough(const SplashScreen()),
    ),
    GoRoute(
      path: '/onboarding',
      pageBuilder: (context, state) => _fadeThrough(const OnboardingScreen()),
    ),
    GoRoute(
      path: '/lock',
      pageBuilder: (context, state) => _fadeThrough(const LockScreen()),
    ),
    GoRoute(
      path: '/home',
      // `extra` optionally picks a starting tab and, for tab 0, whether
      // to land on Agenda's Up Next sub-view instead of Today — see
      // [HomeRouteArgs]. Everywhere else omits it and gets the default
      // Agenda tab, Today view.
      pageBuilder: (context, state) {
        final args = state.extra as HomeRouteArgs? ?? _defaultHomeArgs;
        return _fadeThrough(
          AppShellScreen(
            initialIndex: args.tabIndex,
            initialAgendaUpNext: args.upNext,
          ),
          key: ValueKey(args),
        );
      },
    ),
    GoRoute(
      path: '/item/:id',
      pageBuilder: (context, state) =>
          _fadeThrough(ItemDeepLinkScreen(itemId: state.pathParameters['id']!)),
    ),
  ],
);
