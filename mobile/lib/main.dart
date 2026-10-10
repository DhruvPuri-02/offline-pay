import 'package:flutter/material.dart';
import 'screens/home_screen.dart';
import 'screens/pay_screen.dart';
import 'screens/receive_screen.dart';
import 'screens/scan_qr_screen.dart';
import 'screens/transaction_history_screen.dart';
import 'providers/wallet_provider.dart';
import 'package:provider/provider.dart';

void main() {
  runApp(const OfflinePayApp());
}

class OfflinePayApp extends StatelessWidget {
  const OfflinePayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => WalletProvider()),
      ],
      child: MaterialApp(
        title: 'OfflinePay',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.deepPurple,
            brightness: Brightness.light,
          ),
          useMaterial3: true,
          appBarTheme: const AppBarTheme(
            centerTitle: true,
            elevation: 0,
          ),
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.deepPurple,
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
          appBarTheme: const AppBarTheme(
            centerTitle: true,
            elevation: 0,
          ),
        ),
        themeMode: ThemeMode.system,
        initialRoute: '/',
        routes: {
          '/': (context) => const HomeScreen(),
          '/pay': (context) => const PayScreen(),
          '/receive': (context) => const ReceiveScreen(),
          '/scan': (context) => const ScanQRScreen(),
          '/history': (context) => const TransactionHistoryScreen(),
        },
      ),
    );
  }
}
