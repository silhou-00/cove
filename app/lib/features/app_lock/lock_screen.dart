import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:local_auth/local_auth.dart';

import '../../app/providers.dart';
import '../../app/session_lock.dart';
import '../../app/theme.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/services/secure_screen_service.dart';
import 'widgets/number_pad.dart';

const _pinLength = 4;

/// Consecutive wrong attempts allowed before the escalating lockout starts
/// (§12) — matches `security.md`'s "progressive delay after repeated
/// failed logins" rule.
const _freeAttempts = 3;
const _lockoutStepSeconds = 10;

/// Seconds to lock out after the [wrongAttempt]-th wrong PIN overall
/// (1-indexed) — 0 while still within the free attempts, then 10/20/30...
/// for the 4th/5th/6th... wrong attempt. A pure function (no widget/timer
/// state) so it's directly testable without a `Timer`.
int lockoutSecondsForAttempt(int wrongAttempt) {
  if (wrongAttempt <= _freeAttempts) return 0;
  return (wrongAttempt - _freeAttempts) * _lockoutStepSeconds;
}

/// App lock (§12), cold-start only — reached from splash when App Lock is
/// enabled, replaces the route so back-navigation can't return to it.
/// Biometric is tried automatically on open; the PIN pad is always
/// available as a fallback (and the only path if biometric isn't
/// enrolled/supported). There's no "forgot PIN" reset — reinstalling is
/// the only recovery path, same as it would be either way since no
/// account layer exists to recover through.
class LockScreen extends ConsumerStatefulWidget {
  const LockScreen({super.key});

  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen> {
  final _localAuth = LocalAuthentication();
  String _entered = '';
  int _wrongAttempts = 0;
  int _lockoutSecondsLeft = 0;
  Timer? _lockoutTimer;
  String? _error;
  bool _checkingBiometric = false;

  @override
  void initState() {
    super.initState();
    setSecureScreen(true);
    _resumeLockoutState();
    _tryBiometric();
  }

  /// Loads the persisted attempt count / lockout deadline (§12) and
  /// resumes an in-progress lockout's countdown if one is still active —
  /// the whole point of persisting this is that force-closing the app
  /// between guesses must not reset it to zero.
  Future<void> _resumeLockoutState() async {
    final settings = ref.read(settingsRepositoryProvider);
    final attempts = await settings.getFailedAttempts(
      SettingsRepository.appLockFailedAttemptsKey,
    );
    final until = await settings.getLockoutUntil(
      SettingsRepository.appLockLockoutUntilKey,
    );
    if (!mounted) return;
    _wrongAttempts = attempts;
    if (until != null) {
      final remaining = until.difference(DateTime.now()).inSeconds;
      if (remaining > 0) _startLockoutTimer(remaining);
    }
  }

  @override
  void dispose() {
    _lockoutTimer?.cancel();
    setSecureScreen(false);
    super.dispose();
  }

  Future<void> _tryBiometric() async {
    setState(() => _checkingBiometric = true);
    try {
      final supported = await _localAuth.isDeviceSupported();
      final canCheck = await _localAuth.canCheckBiometrics;
      if (supported && canCheck) {
        final didAuth = await _localAuth.authenticate(
          localizedReason: 'Unlock Cove',
          biometricOnly: true,
          persistAcrossBackgrounding: true,
        );
        if (didAuth) {
          await _unlock();
          return;
        }
      }
    } catch (_) {
      // Not enrolled, permission denied, or platform unsupported — fall
      // through to the PIN pad, same as any other biometric failure.
    }
    if (mounted) setState(() => _checkingBiometric = false);
  }

  Future<void> _unlock() async {
    final settings = ref.read(settingsRepositoryProvider);
    await settings.setFailedAttempts(
      SettingsRepository.appLockFailedAttemptsKey,
      0,
    );
    await settings.setLockoutUntil(
      SettingsRepository.appLockLockoutUntilKey,
      null,
    );
    if (!mounted) return;
    SessionLock.instance.unlock();
    context.go('/home');
  }

  void _startLockoutTimer(int seconds) {
    _lockoutTimer?.cancel();
    setState(() => _lockoutSecondsLeft = seconds);
    _lockoutTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() => _lockoutSecondsLeft -= 1);
      if (_lockoutSecondsLeft <= 0) timer.cancel();
    });
  }

  Future<void> _submit() async {
    final correct = await ref
        .read(profileRepositoryProvider)
        .verifyPin(_entered);
    if (!mounted) return;
    if (correct) {
      await _unlock();
      return;
    }
    _wrongAttempts += 1;
    final lockout = lockoutSecondsForAttempt(_wrongAttempts);
    final settings = ref.read(settingsRepositoryProvider);
    await settings.setFailedAttempts(
      SettingsRepository.appLockFailedAttemptsKey,
      _wrongAttempts,
    );
    await settings.setLockoutUntil(
      SettingsRepository.appLockLockoutUntilKey,
      lockout > 0 ? DateTime.now().add(Duration(seconds: lockout)) : null,
    );
    if (!mounted) return;
    setState(() {
      _entered = '';
      _error = lockout > 0 ? 'Too many attempts' : 'Wrong PIN';
    });
    if (lockout > 0) _startLockoutTimer(lockout);
  }

  void _onDigit(String digit) {
    if (_lockoutSecondsLeft > 0 || _entered.length >= _pinLength) return;
    setState(() {
      _entered += digit;
      _error = null;
    });
    if (_entered.length == _pinLength) _submit();
  }

  void _onBackspace() {
    if (_lockoutSecondsLeft > 0 || _entered.isEmpty) return;
    setState(() => _entered = _entered.substring(0, _entered.length - 1));
  }

  @override
  Widget build(BuildContext context) {
    final locked = _lockoutSecondsLeft > 0;
    return Scaffold(
      backgroundColor: AppColors.dark,
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: context.s(32)),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                'Enter PIN',
                style: AppTypography.headline(context).copyWith(
                  color: AppColorTokens.light.surface,
                  fontSize: context.s(22),
                ),
              ),
              SizedBox(height: context.s(24)),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < _pinLength; i++)
                    Container(
                      width: context.s(14),
                      height: context.s(14),
                      margin: EdgeInsets.symmetric(horizontal: context.s(8)),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i < _entered.length
                            ? AppColorTokens.light.surface
                            : Colors.transparent,
                        border: Border.all(
                          color: AppColorTokens.light.surface.withValues(
                            alpha: 0.5,
                          ),
                          width: 1.5,
                        ),
                      ),
                    ),
                ],
              ),
              SizedBox(height: context.s(16)),
              SizedBox(
                height: context.s(20),
                child: Text(
                  locked
                      ? 'Locked — try again in ${_lockoutSecondsLeft}s'
                      : (_error ?? ''),
                  style: TextStyle(
                    color: context.colors.accent,
                    fontSize: context.s(13),
                  ),
                ),
              ),
              SizedBox(height: context.s(24)),
              NumberPad(
                enabled: !locked,
                onDigit: _onDigit,
                onBackspace: _onBackspace,
                color: AppColorTokens.light.surface,
              ),
              SizedBox(height: context.s(16)),
              if (!_checkingBiometric)
                TextButton.icon(
                  onPressed: _tryBiometric,
                  icon: Icon(
                    Icons.fingerprint,
                    color: AppColorTokens.light.surface.withValues(alpha: 0.7),
                  ),
                  label: Text(
                    'Use biometric',
                    style: TextStyle(
                      color: AppColorTokens.light.surface.withValues(
                        alpha: 0.7,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
