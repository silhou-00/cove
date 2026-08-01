import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/services/secure_screen_service.dart';
import 'widgets/number_pad.dart';

const _pinLength = 4;

/// Turns App Lock on (§12) — enter a new PIN, then confirm it. A mismatch
/// resets back to the first stage rather than re-prompting just the
/// second entry, so there's no stale "first" PIN lingering across a typo.
/// Returns true once the PIN is set and lock enabled, false if cancelled.
Future<bool> showSetPinSheet(BuildContext context) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.colors.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(context.s(24))),
    ),
    builder: (context) => const _SetPinSheet(),
  );
  return result ?? false;
}

class _SetPinSheet extends ConsumerStatefulWidget {
  const _SetPinSheet();

  @override
  ConsumerState<_SetPinSheet> createState() => _SetPinSheetState();
}

class _SetPinSheetState extends ConsumerState<_SetPinSheet> {
  String? _firstEntry;
  String _entered = '';
  String? _error;

  bool get _confirming => _firstEntry != null;

  @override
  void initState() {
    super.initState();
    setSecureScreen(true);
  }

  @override
  void dispose() {
    setSecureScreen(false);
    super.dispose();
  }

  Future<void> _onComplete() async {
    if (!_confirming) {
      setState(() {
        _firstEntry = _entered;
        _entered = '';
      });
      return;
    }
    if (_entered == _firstEntry) {
      await ref.read(profileRepositoryProvider).setPin(_entered);
      if (mounted) Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _firstEntry = null;
      _entered = '';
      _error = "PINs didn't match — try again";
    });
  }

  void _onDigit(String digit) {
    if (_entered.length >= _pinLength) return;
    setState(() {
      _entered += digit;
      _error = null;
    });
    if (_entered.length == _pinLength) _onComplete();
  }

  void _onBackspace() {
    if (_entered.isEmpty) return;
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
            _confirming ? 'Confirm PIN' : 'Set a PIN',
            style: AppTypography.sectionHeader(context),
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
              _error ?? '',
              style: TextStyle(
                color: context.colors.accent,
                fontSize: context.s(12.5),
              ),
            ),
          ),
          SizedBox(height: context.s(12)),
          NumberPad(
            enabled: true,
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
