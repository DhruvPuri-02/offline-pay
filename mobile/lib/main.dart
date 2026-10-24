import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'providers/wallet_provider.dart';
import 'screens/home_screen.dart';
import 'screens/pay_screen.dart';
import 'screens/receive_screen.dart';
import 'screens/record_payment_screen.dart';
import 'screens/scan_qr_screen.dart';
import 'screens/transaction_history_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Desktop support: sqflite's native implementation only exists on
  // mobile/macOS, so Windows and Linux use the FFI (C library) backend
  // instead. Same schema, same LocalDatabase code, runs on a laptop -
  // handy when you want to demo without a phone. (Camera scanning is
  // unavailable there; the paste-QR fallback covers it.)
  if (Platform.isWindows || Platform.isLinux) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  // Boot from SQLite BEFORE the first frame. No network, no spinner wait:
  // the wallet paints immediately, even in airplane mode.
  final walletProvider = WalletProvider();
  await walletProvider.initialize();

  runApp(OfflinePayApp(walletProvider: walletProvider));
}

class OfflinePayApp extends StatelessWidget {
  const OfflinePayApp({super.key, required this.walletProvider});

  final WalletProvider walletProvider;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: walletProvider,
      child: MaterialApp(
        title: 'OfflinePay',
        debugShowCheckedModeBanner: false,
        theme: _buildTheme(Brightness.light),
        darkTheme: _buildTheme(Brightness.dark),
        themeMode: ThemeMode.system,
        initialRoute: '/',
        routes: {
          '/': (context) => const HomeScreen(),
          '/pay': (context) => const PayScreen(),
          '/receive': (context) => const ReceiveScreen(),
          '/scan': (context) => const ScanQRScreen(),
          '/record-payment': (context) => const RecordPaymentScreen(),
          '/history': (context) => const TransactionHistoryScreen(),
        },
      ),
    );
  }
}

/// One place for the app's look: calm indigo palette, soft cards, rounded
/// inputs and buttons. Screens inherit all of this automatically.
ThemeData _buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF4338CA),
    brightness: brightness,
  );
  final isLight = brightness == Brightness.light;

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor:
        isLight ? const Color(0xFFF6F7FB) : scheme.surface,
    appBarTheme: AppBarTheme(
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: Colors.transparent,
      foregroundColor: scheme.onSurface,
      titleTextStyle: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
        color: scheme.onSurface,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );
}
