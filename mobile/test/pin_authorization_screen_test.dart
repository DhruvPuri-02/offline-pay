import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offlinepay/models/transaction.dart';
import 'package:offlinepay/providers/wallet_provider.dart';
import 'package:offlinepay/screens/pin_authorization_screen.dart';
import 'package:offlinepay/services/local_database.dart';
import 'package:offlinepay/services/pin_service.dart';
import 'package:offlinepay/utils/payment_exception.dart';
import 'package:provider/provider.dart';

/// In-memory stand-in for the wallet.
///
/// Widget tests run under FakeAsync: real SQLite I/O inside a tap handler
/// deadlocks the test (known sqflite + testWidgets pitfall), so the screen
/// is exercised against pure in-memory behaviour instead. The real PIN +
/// SQLite behaviour is covered in wallet_provider_pin_test.dart.
class FakeWallet extends WalletProvider {
  FakeWallet({bool pinSet = false})
      : _pinSet = pinSet,
        super(database: LocalDatabase.inMemory());

  bool _pinSet;
  String? storedPin;
  int lockSeconds = 0;

  @override
  bool get hasTransactionPin => _pinSet;

  @override
  Duration get pinLockRemaining => Duration(seconds: lockSeconds);

  @override
  int get pinAttemptsRemaining => PinService.maxFailedAttempts;

  @override
  Future<void> setTransactionPin(String pin) async {
    _pinSet = true;
    storedPin = pin;
    notifyListeners();
  }
}

Transaction _dummyTx() => Transaction(
      transactionId: 'TX_test',
      senderId: 'USER_alice',
      receiverId: 'USER_bob',
      senderWalletId: 'WALLET_alice',
      receiverWalletId: 'WALLET_bob',
      amount: 100,
      type: TransactionType.offlinePayment,
      status: TransactionStatus.pendingSync,
      description: 'Test payment',
    );

/// Captures what the launcher received after the screen closes.
class LaunchResult {
  Transaction? transaction;
  bool closed = false;
}

/// Push the PIN screen through its real entry point (`open()`), so the
/// returned value and the pop are part of the assertions.
Future<LaunchResult> _pumpLauncher(
  WidgetTester tester, {
  required FakeWallet wallet,
  required Future<Transaction> Function(String pin) onAttempt,
  Map<String, String> summary = const {},
}) async {
  final launch = LaunchResult();
  await tester.pumpWidget(
    ChangeNotifierProvider<WalletProvider>.value(
      value: wallet,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              key: const Key('open-pin'),
              onPressed: () async {
                launch.transaction = await PinAuthorizationScreen.open(
                  context,
                  onAttempt: onAttempt,
                  summary: summary,
                );
                launch.closed = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('open-pin')));
  await tester.pump();
  // Bounded pumps instead of pumpAndSettle: when the wallet is already
  // locked, the 1s countdown ticker schedules frames forever and
  // pumpAndSettle would spin until its timeout.
  await tester.pump(const Duration(milliseconds: 500));
  return launch;
}

void main() {
  testWidgets('setup mode: create PIN, then the payment attempt runs with it',
      (tester) async {
    String? attemptedWith;
    final wallet = FakeWallet();
    final launch = await _pumpLauncher(
      tester,
      wallet: wallet,
      summary: const {'Amount': '₹100'},
      onAttempt: (pin) async {
        attemptedWith = pin;
        return _dummyTx();
      },
    );

    // No PIN yet -> setup UI.
    expect(find.text('Create Transaction PIN'), findsOneWidget);
    expect(find.text('₹100'), findsOneWidget); // summary shown
    expect(find.byType(TextField), findsNWidgets(2)); // PIN + confirm

    await tester.enterText(find.byType(TextField).at(0), '4321');
    await tester.enterText(find.byType(TextField).at(1), '4321');
    await tester.tap(find.text('Create PIN & Pay'));
    await tester.pumpAndSettle();

    expect(wallet.storedPin, '4321'); // PIN was set (stored as hash upstream)
    expect(attemptedWith, '4321'); // and used for this very payment
    expect(launch.closed, isTrue);
    expect(launch.transaction, isNotNull);
    expect(find.byType(PinAuthorizationScreen), findsNothing); // popped

    await tester.pumpWidget(const SizedBox()); // dispose leftovers
  });

  testWidgets('setup mode: mismatched PINs are refused before any attempt',
      (tester) async {
    var attemptCount = 0;
    final wallet = FakeWallet();
    await _pumpLauncher(
      tester,
      wallet: wallet,
      onAttempt: (_) async {
        attemptCount++;
        return _dummyTx();
      },
    );

    await tester.enterText(find.byType(TextField).at(0), '4321');
    await tester.enterText(find.byType(TextField).at(1), '4322');
    await tester.tap(find.text('Create PIN & Pay'));
    await tester.pumpAndSettle();

    expect(find.text('PINs do not match. Try again.'), findsOneWidget);
    expect(attemptCount, 0); // payment never ran
    expect(wallet.storedPin, isNull); // nothing persisted

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('verify mode: a failing payment surfaces its PIN reason',
      (tester) async {
    final wallet = FakeWallet(pinSet: true);
    final launch = await _pumpLauncher(
      tester,
      wallet: wallet,
      onAttempt: (_) async =>
          throw const PaymentException('Incorrect transaction PIN. 4 attempt(s) left.'),
    );

    // PIN exists -> verify UI (single field, different title).
    expect(find.text('Enter Transaction PIN'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);

    await tester.enterText(find.byType(TextField), '9999');
    await tester.tap(find.text('Authorize Payment'));
    await tester.pumpAndSettle();

    expect(
      find.text('Incorrect transaction PIN. 4 attempt(s) left.'),
      findsOneWidget,
    );
    expect(find.byType(TextField), findsOneWidget); // still on screen
    expect(launch.closed, isFalse); // no result delivered

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('verify mode: correct PIN delivers the transaction',
      (tester) async {
    String? attemptedWith;
    final wallet = FakeWallet(pinSet: true);
    final launch = await _pumpLauncher(
      tester,
      wallet: wallet,
      onAttempt: (pin) async {
        attemptedWith = pin;
        return _dummyTx();
      },
    );

    await tester.enterText(find.byType(TextField), '1234');
    await tester.tap(find.text('Authorize Payment'));
    await tester.pumpAndSettle();

    expect(attemptedWith, '1234');
    expect(launch.transaction, isNotNull);
    expect(find.byType(PinAuthorizationScreen), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('lockout: input and button are disabled with a countdown',
      (tester) async {
    final wallet = FakeWallet(pinSet: true)..lockSeconds = 15;
    await _pumpLauncher(
      tester,
      wallet: wallet,
      onAttempt: (_) async => _dummyTx(),
    );

    expect(find.textContaining('Try again in 15s'), findsOneWidget);
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull); // cannot submit while locked
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.enabled, isFalse); // cannot even type

    // The ticker refreshes the countdown as time passes.
    wallet.lockSeconds = 14;
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('Try again in 14s'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('cancel returns no transaction', (tester) async {
    final wallet = FakeWallet(pinSet: true);
    final launch = await _pumpLauncher(
      tester,
      wallet: wallet,
      onAttempt: (_) async => _dummyTx(),
    );

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(launch.closed, isTrue);
    expect(launch.transaction, isNull);
    expect(find.byType(PinAuthorizationScreen), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });
}
