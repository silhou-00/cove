import 'package:app/data/db/database.dart';
import 'package:app/data/repositories/profile_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late ProfileRepository repo;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    repo = ProfileRepository(db);
    await repo.saveProfile(firstName: 'Test');
  });

  tearDown(() async {
    await db.close();
  });

  group('App lock (§12)', () {
    test('isAppLockEnabled defaults to false', () async {
      expect(await repo.isAppLockEnabled(), isFalse);
    });

    test(
      'setPin enables app lock and verifyPin accepts the correct PIN',
      () async {
        await repo.setPin('1234');

        expect(await repo.isAppLockEnabled(), isTrue);
        expect(await repo.verifyPin('1234'), isTrue);
      },
    );

    test('verifyPin rejects a wrong PIN', () async {
      await repo.setPin('1234');

      expect(await repo.verifyPin('9999'), isFalse);
    });

    test('verifyPin returns false when no PIN has been set', () async {
      expect(await repo.verifyPin('1234'), isFalse);
    });

    test('disableAppLock clears the hash/salt and turns lock off', () async {
      await repo.setPin('1234');

      await repo.disableAppLock();

      expect(await repo.isAppLockEnabled(), isFalse);
      expect(await repo.verifyPin('1234'), isFalse);
    });

    test(
      'the same PIN set twice never produces the same hash (fresh salt each time)',
      () async {
        await repo.setPin('1234');
        final first = await repo.getProfile();

        await repo.setPin('1234');
        final second = await repo.getProfile();

        expect(first!.appLockPinSalt, isNot(second!.appLockPinSalt));
        expect(first.appLockPinHash, isNot(second.appLockPinHash));
      },
    );

    test('setPin rejects anything that isn\'t exactly 4 digits', () async {
      await expectLater(repo.setPin('123'), throwsArgumentError);
      await expectLater(repo.setPin('12345'), throwsArgumentError);
      await expectLater(repo.setPin('12a4'), throwsArgumentError);
      await expectLater(repo.setPin(''), throwsArgumentError);
    });
  });

  group('setAvatarPath (§11, profile picture)', () {
    test('defaults to null', () async {
      expect((await repo.getProfile())?.avatarPath, isNull);
    });

    test('sets and clears the stored path', () async {
      await repo.setAvatarPath('/data/user/0/com.silhou.cove/profile_avatar.img');
      expect(
        (await repo.getProfile())?.avatarPath,
        '/data/user/0/com.silhou.cove/profile_avatar.img',
      );

      await repo.setAvatarPath(null);
      expect((await repo.getProfile())?.avatarPath, isNull);
    });
  });
}
