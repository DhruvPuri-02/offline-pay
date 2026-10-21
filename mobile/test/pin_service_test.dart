import 'package:flutter_test/flutter_test.dart';
import 'package:offlinepay/services/pin_service.dart';

/// Phase 4: the PIN policy itself, with no database or UI involved.
void main() {
  group('PinService.validateFormat', () {
    test('accepts 4 and 6 digit PINs', () {
      expect(PinService.validateFormat('1234'), isNull);
      expect(PinService.validateFormat('123456'), isNull);
    });

    test('rejects wrong length or non-digits with a usable reason', () {
      expect(PinService.validateFormat('123'), contains('4 to 6'));
      expect(PinService.validateFormat('1234567'), contains('4 to 6'));
      expect(PinService.validateFormat('12a4'), contains('digits only'));
      expect(PinService.validateFormat(''), contains('4 to 6'));
    });
  });

  group('PinService hashing', () {
    test('produces a bcrypt hash, never the plaintext', () {
      final stored = PinService.hash('4321');
      expect(stored, startsWith(r'$2')); // modular crypt format = bcrypt
      expect(stored, isNot('4321'));
      expect(stored.contains('4321'), isFalse);
    });

    test('hashes of the same PIN differ (random salt per PIN)', () {
      final a = PinService.hash('1234');
      final b = PinService.hash('1234');
      expect(a, isNot(b));
      // Both still verify - the salt lives inside the stored hash.
      expect(PinService.verify('1234', a), isTrue);
      expect(PinService.verify('1234', b), isTrue);
    });

    test('verifies the right PIN and rejects wrong ones', () {
      final stored = PinService.hash('9876');
      expect(PinService.verify('9876', stored), isTrue);
      expect(PinService.verify('9875', stored), isFalse);
      expect(PinService.verify('', stored), isFalse);
    });

    test('fails closed on malformed or foreign hashes', () {
      expect(PinService.verify('1234', 'not-a-bcrypt-hash'), isFalse);
      expect(PinService.verify('1234', ''), isFalse);
    });
  });

  group('lockout policy constants (spec: max attempts + temporary lockout)', () {
    test('are what the docs promise', () {
      expect(PinService.maxFailedAttempts, 5);
      expect(PinService.lockoutDuration, const Duration(seconds: 30));
    });
  });
}
