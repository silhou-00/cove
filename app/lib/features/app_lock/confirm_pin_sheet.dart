import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/services/secure_screen_service.dart';
import 'lock_screen.dart' show lockoutSecondsForAttempt;
import 'widgets/number_pad.dart';

const _pinLength = 4;

/// Re-confirms identity before a security-relevant Settings action (§12 —
/// currently just disabling App Lock) — biometric-first, PIN fallback.
/// Shares the front-door lock screen's escalating lockout logic (same
/// [lockoutSecondsForAttempt] curve) but its own persisted attempt
/// counter — reachable independently of the lock screen by anyone
/// handed an already-unlocked phone, so it needs its own rate limit, not
/// a free pass just because this app screen happened to be reached
/// legitimately. Returns true if confirmed, false if cancelled.
Future<bool> showConfirmPinSheet(
  BuildContext context, {
  required String reason,
}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.colors.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(context.s(24))),
    ),
    builder: (context) => _ConfirmPinSheet(reason: reason),
  );
  return result ?? false;
}

class _ConfirmPinSheet extends ConsumerStatefulWidget {
  const _ConfirmPinSheet({required this.reason});
  final String reason;

  @override
  ConsumerState<_ConfirmPinSheet> createState() => _ConfirmPinSheetState();
}

class _ConfirmPinSheetState extends ConsumerState<_ConfirmPinSheet> {
  final _localAuth = LocalAuthentication();
  String _entered = '';
  String? _error;
  int _wrongAttempts = 0;
  int _lockoutSecondsLeft = 0;
  Timer? _lockoutTimer;

  @override
  void initState() {
    super.initState();
    setSecureScreen(true);
    _resumeLockoutState();
    _tryBiometric();
  }

  @override
  void dispose() {
    _lockoutTimer?.cancel();
    setSecureScreen(false);
    super.dispose();
  }

  Future<void> _resumeLockoutState() async {
    final settings = ref.read(settingsRepositoryProvider);
    final attempts = await settings.getFailedAttempts(
      SettingsRepository.confirmPinFailedAttemptsKey,
    );
    final until = await settings.getLockoutUntil(
      SettingsRepository.confirmPinLockoutUntilKey,
    );
    if (!mounted) return;
    _wrongAttempts = attempts;
    if (until != null) {
      final remaining = until.difference(DateTime.now()).inSeconds;
      if (remaining > 0) _startLockoutTimer(remaining);
    }
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

  Future<void> _tryBiometric() async {
    try {
      final supported = await _localAuth.isDeviceSupported();
      final canCheck = await _localAuth.canCheckBiometrics;
      if (supported && canCheck) {
        final didAuth = await _localAuth.authenticate(
          localizedReason: widget.reason,
          biometricOnly: true,
        );
        if (didAuth && mounted) Navigator.of(context).pop(true);
      }
    } catch (_) {
      // Falls through to the PIN pad.
    }
  }

  Future<void> _submit() async {
    final correct = await ref
        .read(profileRepositoryProvider)
        .verifyPin(_entered);
    if (!mounted) return;
    final settings = ref.read(settingsRepositoryProvider);
    if (correct) {
      await settings.setFailedAttempts(
        SettingsRepository.confirmPinFailedAttemptsKey,
        0,
      );
      await settings.setLockoutUntil(
        SettingsRepository.confirmPinLockoutUntilKey,
        null,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
      return;
    }
    _wrongAttempts += 1;
    final lockout = lockoutSecondsForAttempt(_wrongAttempts);
    await settings.setFailedAttempts(
      SettingsRepository.confirmPinFailedAttemptsKey,
      _wrongAttempts,
    );
    await settings.setLockoutUntil(
      SettingsRepository.confirmPinLockoutUntilKey,
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
    return Padding(
      padding: EdgeInsets.only(
        left: context.s(16),
        right: context.s(16),
        top: context.s(20),
        bottom: MediaQuery.of(context).padding.bottom + context.s(24),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.reason,
            style: AppTypography.sectionHeader(context),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: context.s(16)),
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
                        ? context.colors.ink
                        : Colors.transparent,
                    border: Border.all(
                      color: context.colors.inkDisabled,
                      width: 1.5,
                    ),
                  ),
                ),
            ],
          ),
          SizedBox(height: context.s(10)),
          SizedBox(
            height: context.s(18),
            child: Text(
              _lockoutSecondsLeft > 0
                  ? 'Locked — try again in ${_lockoutSecondsLeft}s'
                  : (_error ?? ''),
              style: TextStyle(
                color: context.colors.accent,
                fontSize: context.s(12.5),
              ),
            ),
          ),
          SizedBox(height: context.s(12)),
          NumberPad(
            enabled: _lockoutSecondsLeft == 0,
            onDigit: _onDigit,
            onBackspace: _onBackspace,
          ),
          SizedBox(height: context.s(8)),
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }
}
