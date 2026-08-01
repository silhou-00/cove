import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show compute;

import '../../domain/services/text_limits.dart';
import '../db/database.dart';

const _pbkdf2Iterations = 100000;
const _pinPattern = r'^\d{4}$';

/// PBKDF2-HMAC-SHA256, 100,000 iterations — not bcrypt/argon2/scrypt
/// (`security.md`'s usual rule for network-facing account passwords), but
/// a real work factor instead of the single-round SHA-256 this replaced.
/// A local device PIN has no network exposure, so bcrypt/argon2/scrypt's
/// memory-hardness isn't buying much extra here — the actual risk this
/// closes is a fast offline guess if the DB is ever extracted, which a
/// deliberate iteration count already addresses. Salt is fresh random
/// bytes per [ProfileRepository.setPin] call, never derived from
/// anything else on the row. Run via [compute] (a background isolate) —
/// 100k iterations of pure-Dart HMAC would otherwise visibly block the UI
/// thread for a couple hundred milliseconds on every PIN entry.
Future<String> hashPin(String pin, String salt) =>
    compute(_pbkdf2HashPin, (pin: pin, salt: salt));

String _pbkdf2HashPin(({String pin, String salt}) args) {
  final saltBytes = base64Url.decode(args.salt);
  final hmac = Hmac(sha256, utf8.encode(args.pin));
  var block = hmac.convert([...saltBytes, 0, 0, 0, 1]).bytes;
  final result = List<int>.from(block);
  for (var i = 1; i < _pbkdf2Iterations; i++) {
    block = hmac.convert(block).bytes;
    for (var j = 0; j < result.length; j++) {
      result[j] ^= block[j];
    }
  }
  return base64Url.encode(result);
}

String _generateSalt() {
  final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
  return base64Url.encode(bytes);
}

/// Single-row profile — no accounts (§3). The row simply doesn't exist
/// until onboarding saves a name; a missing row is a valid state (e.g. the
/// user skipped onboarding before entering one), not an error.
class ProfileRepository {
  ProfileRepository(this._db);

  final AppDatabase _db;

  static const _profileId = 'local';

  Stream<Profile?> watchProfile() {
    return (_db.select(
      _db.profiles,
    )..where((p) => p.id.equals(_profileId))).watchSingleOrNull();
  }

  Future<Profile?> getProfile() => (_db.select(
    _db.profiles,
  )..where((p) => p.id.equals(_profileId))).getSingleOrNull();

  Future<void> saveProfile({
    required String firstName,
    String? lastName,
  }) async {
    final cappedFirstName = capLength(firstName, TextLimits.profileName);
    final cappedLastName = lastName == null
        ? null
        : capLength(lastName, TextLimits.profileName);
    final existing = await getProfile();
    if (existing == null) {
      await _db
          .into(_db.profiles)
          .insert(
            ProfilesCompanion.insert(
              id: _profileId,
              firstName: cappedFirstName,
              lastName: Value(cappedLastName),
              createdAt: DateTime.now(),
            ),
          );
    } else {
      await (_db.update(
        _db.profiles,
      )..where((p) => p.id.equals(_profileId))).write(
        ProfilesCompanion(
          firstName: Value(cappedFirstName),
          lastName: Value(cappedLastName),
        ),
      );
    }
  }

  /// [path] should already be a copy living in the app's own documents
  /// directory (see `edit_profile_sheet.dart`), not the original picked
  /// file's path — that one isn't guaranteed to still exist later. `null`
  /// reverts to the initial-letter avatar.
  Future<void> setAvatarPath(String? path) async {
    await (_db.update(
      _db.profiles,
    )..where((p) => p.id.equals(_profileId))).write(
      ProfilesCompanion(avatarPath: Value(path)),
    );
  }

  Future<bool> isAppLockEnabled() async =>
      (await getProfile())?.appLockEnabled ?? false;

  /// Sets a new PIN and enables App Lock (§12) — called from Settings'
  /// set-PIN sheet, which only exists once onboarding has already created
  /// the profile row. The 4-digit constraint is enforced here, not just
  /// in the UI's number pad — a repository method should hold on its own
  /// regardless of what calls it.
  Future<void> setPin(String pin) async {
    if (!RegExp(_pinPattern).hasMatch(pin)) {
      throw ArgumentError.value(pin, 'pin', 'Must be exactly 4 digits.');
    }
    final salt = _generateSalt();
    final hash = await hashPin(pin, salt);
    await (_db.update(
      _db.profiles,
    )..where((p) => p.id.equals(_profileId))).write(
      ProfilesCompanion(
        appLockEnabled: const Value(true),
        appLockPinHash: Value(hash),
        appLockPinSalt: Value(salt),
      ),
    );
  }

  Future<bool> verifyPin(String pin) async {
    final profile = await getProfile();
    final storedHash = profile?.appLockPinHash;
    final salt = profile?.appLockPinSalt;
    if (storedHash == null || salt == null) return false;
    return (await hashPin(pin, salt)) == storedHash;
  }

  Future<void> disableAppLock() async {
    await (_db.update(
      _db.profiles,
    )..where((p) => p.id.equals(_profileId))).write(
      const ProfilesCompanion(
        appLockEnabled: Value(false),
        appLockPinHash: Value(null),
        appLockPinSalt: Value(null),
      ),
    );
  }
}
