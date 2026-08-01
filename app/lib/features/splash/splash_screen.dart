import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/cove_icon.dart';
import '../../app/providers.dart';
import '../../app/theme.dart';

/// Matches the design prototype's `isSplash` timing (~1.6s) before routing
/// to onboarding (first run) or straight home (§10 step 4 / return visits).
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(milliseconds: 1600), _navigateNext);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _navigateNext() async {
    if (!mounted) return;
    final settings = ref.read(settingsRepositoryProvider);
    final onboardingComplete = await settings.isOnboardingComplete();
    if (!onboardingComplete) {
      if (mounted) context.go('/onboarding');
      return;
    }
    // App lock (§12) is checked here, on cold start, and nowhere else —
    // resuming from background never re-locks.
    final lockEnabled = await ref
        .read(profileRepositoryProvider)
        .isAppLockEnabled();
    if (!mounted) return;
    context.go(lockEnabled ? '/lock' : '/home');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.dark,
      body: Stack(
        children: [
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CoveIcon(size: context.s(96)),
                SizedBox(height: context.s(22)),
                Text('cove', style: AppTypography.wordmark(context)),
                SizedBox(height: context.s(9)),
                Text(
                  'EVERYTHING IN ITS PLACE',
                  style: AppTypography.tagline(
                    context,
                  ).copyWith(fontSize: context.s(9.5)),
                ),
              ],
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: context.s(34),
            child: Center(
              child: Text(
                'OFFLINE · NO ACCOUNT',
                style: AppTypography.mono(context).copyWith(
                  fontSize: context.s(9),
                  color: const Color(0xFF4A453E),
                  letterSpacing: context.s(1.8),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
