import 'package:flutter_test/flutter_test.dart';
import 'package:offlinepay/models/transaction.dart';
import 'package:offlinepay/providers/wallet_provider.dart';
import 'package:offlinepay/services/local_database.dart';
import 'package:offlinepay/services/pin_service.dart';
import 'package:offlinepay/utils/payment_exception.dart';
// hide Transaction: sqflite_common also exports a `Transaction` type.
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;

/// Phase 4: PIN enforcement, brute-force lockout, and the "hash only"
/// storage guarantee - all against a real (in-memory) SQLite database.
void main() {
  sqfliteFfiInit();
  setUpAll(() {
    databaseFactory = databaseFactoryFfi;
  });

  late LocalDatabase db;
  late WalletProvider wallet;

  // The provider reads "now" through an injectable clock, so lockout
  // expiry is tested by moving time - never by sleeping.
  late DateTime now;

  setUp(() async {
    db = LocalDatabase.inMemory();
    now = DateTime(2026, 1, 1, 12, 0, 0);
    wallet = WalletProvider(database: db, clock: () => now);
    await wallet.initialize();
  });

  tearDown(() => db.close());

  /// Run a payment the way the PIN screen does it.
  Future<Transaction> pay({String? pin, double amount = 100}) {
    return wallet.createOfflinePayment(
      receiverId: 'USER_bob',
      receiverWalletId: 'WALLET_bob',
      amount: amount,
      description: 'Test payment',
      transactionPin: pin,
    );
  }

  Matcher throwsPaymentWith(String fragment) => throwsA(
        allOf(
          isA<PaymentException>(),
          predicate<PaymentException>(
            (e) => e.reason.contains(fragment),
            'reason contains "$fragment"',
          ),
        ),
      );

  group('PIN storage', () {
    test('stores only a salted bcrypt hash - never the plaintext', () async {
      await wallet.setTransactionPin('4321');

      expect(wallet.hasTransactionPin, isTrue);
      final record = await db.getPinRecord();
      expect(record.hash, startsWith(r'$2'));
      expect(record.hash, isNot('4321'));
      expect(record.hash!.contains('4321'), isFalse);
      // The stored hash verifies the real PIN...
      expect(PinService.verify('4321', record.hash!), isTrue);
    });

    test('rejects malformed PINs before anything is written', () async {
      for (final bad in ['12', '1234567', '12a4']) {
        await expectLater(
          wallet.setTransactionPin(bad),
          throwsA(isA<PaymentException>()),
        );
      }
      expect(wallet.hasTransactionPin, isFalse);
      expect((await db.getPinRecord()).hash, isNull);
    });
  });

  group('createOfflinePayment PIN enforcement', () {
    test('bootstrap: with no PIN configured the payment still goes through',
        () async {
      // The UI always forces PIN setup before the first payment; at the
      // provider level there is simply nothing to verify yet.
      expect(wallet.hasTransactionPin, isFalse);
      final tx = await pay();
      expect(tx.status, TransactionStatus.pendingSync);
    });

    test('once a PIN exists, a payment without one is refused', () async {
      await wallet.setTransactionPin('1234');

      await expectLater(pay(), throwsPaymentWith('Transaction PIN required'));
      // Refused before any ledger write: only the seed top-up exists.
      expect(wallet.transactions, hasLength(1));
      expect(wallet.pendingSyncTransactions, isEmpty);
      expect(wallet.availableBalance, WalletProvider.firstRunSeedBalance);
    });

    test('wrong PIN is refused with attempt count and writes nothing',
        () async {
      await wallet.setTransactionPin('1234');

      await expectLater(
        pay(pin: '9999'),
        throwsPaymentWith('4 attempt(s) left'),
      );
      expect(wallet.pinAttemptsRemaining, 4);
      expect(wallet.transactions, hasLength(1));
    });

    test('correct PIN creates the payment normally', () async {
      await wallet.setTransactionPin('1234');

      final tx = await pay(pin: '1234');
      expect(tx.status, TransactionStatus.pendingSync);
      expect(wallet.pendingOutgoing, 100);
      expect(
          wallet.availableBalance, WalletProvider.firstRunSeedBalance - 100);
      // Success reset the failed-attempt budget.
      expect(wallet.pinAttemptsRemaining, PinService.maxFailedAttempts);
    });

    test('validation failures run before PIN verification (no attempt burned)',
        () async {
      await wallet.setTransactionPin('1234');

      // Over the offline cap AND wrong PIN: the balance rule wins, which
      // proves validation runs first and the attempt budget is untouched.
      await expectLater(
        pay(pin: '0000', amount: 99999),
        throwsPaymentWith('Offline payments are limited to'),
      );
      expect(wallet.pinAttemptsRemaining, PinService.maxFailedAttempts);
    });

    test('5 wrong attempts lock out - even for the correct PIN', () async {
      await wallet.setTransactionPin('1234');

      for (var i = 0; i < PinService.maxFailedAttempts - 1; i++) {
        await expectLater(
          pay(pin: '0000'),
          throwsPaymentWith('Incorrect transaction PIN'),
        );
      }
      expect(wallet.pinAttemptsRemaining, 1);
      expect(wallet.pinLockRemaining, Duration.zero);

      // 5th failure starts the lockout.
      await expectLater(
        pay(pin: '0000'),
        throwsPaymentWith(
            'locked for ${PinService.lockoutDuration.inSeconds} seconds'),
      );
      expect(wallet.pinLockRemaining, greaterThan(Duration.zero));

      // While locked the CORRECT PIN must not work either - that is the
      // point of throttling a stolen/unlocked phone.
      await expectLater(pay(pin: '1234'), throwsPaymentWith('more seconds'));
      expect(wallet.transactions, hasLength(1)); // still no payments
    });

    test('after the cooldown the correct PIN works and the budget resets',
        () async {
      await wallet.setTransactionPin('1234');
      for (var i = 0; i < PinService.maxFailedAttempts; i++) {
        // The 5th rejection is the lockout message, not "incorrect PIN" -
        // either way, the attempt was refused.
        await expectLater(pay(pin: '0000'), throwsA(isA<PaymentException>()));
      }
      expect(wallet.pinLockRemaining, greaterThan(Duration.zero));

      // Move the clock past the lockout (not wall-clock waiting).
      now = now.add(PinService.lockoutDuration).add(const Duration(seconds: 1));
      expect(wallet.pinLockRemaining, Duration.zero);

      final tx = await pay(pin: '1234');
      expect(tx.status, TransactionStatus.pendingSync);
      expect(wallet.pinAttemptsRemaining, PinService.maxFailedAttempts);
    });

    test('failed attempts survive an app restart (persisted in SQLite)',
        () async {
      await wallet.setTransactionPin('1234');
      await expectLater(
        pay(pin: '0000'),
        throwsPaymentWith('Incorrect transaction PIN'),
      );
      await expectLater(
        pay(pin: '0000'),
        throwsPaymentWith('Incorrect transaction PIN'),
      );
      expect(wallet.pinAttemptsRemaining, 3);

      await wallet.reload(); // simulates reopening the app
      expect(wallet.pinAttemptsRemaining, 3);
      expect(wallet.hasTransactionPin, isTrue);
    });
  });

  group('changeTransactionPin', () {
    test('refuses with a wrong current PIN (and counts the attempt)', () async {
      await wallet.setTransactionPin('1234');

      await expectLater(
        wallet.changeTransactionPin(currentPin: '9999', newPin: '6543'),
        throwsPaymentWith('Incorrect transaction PIN'),
      );

      // Old PIN still active - a thief cannot swap it.
      final tx = await pay(pin: '1234');
      expect(tx.status, TransactionStatus.pendingSync);
    });

    test('replaces the PIN when the current one is correct', () async {
      await wallet.setTransactionPin('1234');

      await wallet.changeTransactionPin(currentPin: '1234', newPin: '6543');

      await expectLater(
        pay(pin: '1234'),
        throwsPaymentWith('Incorrect transaction PIN'),
      );
      final tx = await pay(pin: '6543');
      expect(tx.status, TransactionStatus.pendingSync);
    });

    test('rejects a malformed new PIN without changing the old one', () async {
      await wallet.setTransactionPin('1234');
      await expectLater(
        wallet.changeTransactionPin(currentPin: '1234', newPin: '99'),
        throwsA(isA<PaymentException>()),
      );
      final tx = await pay(pin: '1234');
      expect(tx.status, TransactionStatus.pendingSync);
    });
  });
}
