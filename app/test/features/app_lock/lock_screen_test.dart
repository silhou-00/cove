import 'package:app/features/app_lock/lock_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('lockoutSecondsForAttempt (§12, escalating lockout)', () {
    test('first three wrong attempts are free (no lockout)', () {
      expect(lockoutSecondsForAttempt(1), 0);
      expect(lockoutSecondsForAttempt(2), 0);
      expect(lockoutSecondsForAttempt(3), 0);
    });

    test(
      '4th wrong attempt locks for 10s, escalating by 10s each attempt after',
      () {
        expect(lockoutSecondsForAttempt(4), 10);
        expect(lockoutSecondsForAttempt(5), 20);
        expect(lockoutSecondsForAttempt(6), 30);
      },
    );
  });
}
