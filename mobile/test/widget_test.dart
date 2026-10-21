import 'package:flutter_test/flutter_test.dart';
import 'package:offlinepay/main.dart';
import 'package:offlinepay/providers/wallet_provider.dart';
import 'package:offlinepay/services/local_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  setUpAll(() {
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('home screen boots offline and shows the three balances',
      (tester) async {
    // SQLite performs real (non-fake) async I/O, which cannot complete
    // inside the test's FakeAsync zone - runAsync gives it a real event
    // loop turn, exactly like the app's own main() gets.
    final provider = WalletProvider(database: LocalDatabase.inMemory());
    await tester.runAsync(() => provider.initialize());

    await tester.pumpWidget(OfflinePayApp(walletProvider: provider));
    await tester.pumpAndSettle();

    expect(find.text('Available Balance'), findsOneWidget);
    expect(find.text('Pay'), findsOneWidget);
    expect(find.text('Receive'), findsOneWidget);
    expect(find.text('History'), findsOneWidget);
    expect(find.textContaining('SIMULATED MONEY ONLY'), findsOneWidget);

    // The seeded wallet shows its confirmed amount.
    expect(find.text('₹500.00'), findsWidgets);
  });
}
