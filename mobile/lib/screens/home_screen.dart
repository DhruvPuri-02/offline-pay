import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/wallet_provider.dart';
import '../widgets/balance_card.dart';
import '../widgets/quick_action_button.dart';
import '../widgets/recent_transactions.dart';
import 'pin_settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    // main() already boots the wallet from SQLite before the first frame;
    // this is only a safety net so a cold widget tree still gets loaded.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final wallet = context.read<WalletProvider>();
      if (!wallet.isInitialized) {
        wallet.initialize();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('OfflinePay'),
        actions: [
          IconButton(
            tooltip: 'Transaction PIN settings',
            icon: Icon(
              Icons.key,
              // Subtle hint that protection is (not yet) active.
              color: context.watch<WalletProvider>().hasTransactionPin
                  ? null
                  : Colors.grey,
            ),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const PinSettingsScreen()),
              );
            },
          ),
          IconButton(
            tooltip: 'Reload local ledger',
            icon: const Icon(Icons.refresh),
            onPressed: () {
              context.read<WalletProvider>().reload();
            },
          ),
        ],
      ),
      body: Consumer<WalletProvider>(
        builder: (context, wallet, child) {
          if (!wallet.isInitialized || wallet.currentUser == null) {
            return Center(
              child: wallet.error != null
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        wallet.error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.red),
                      ),
                    )
                  : const CircularProgressIndicator(),
            );
          }

          return RefreshIndicator(
            onRefresh: () => wallet.reload(),
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Greeting
                  Text(
                    'Hello, ${wallet.currentUser!.name}',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 24),

                  // Balance Card (available / confirmed / pending)
                  BalanceCard(summary: wallet.balanceSummary),
                  const SizedBox(height: 24),

                  // Quick Actions
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      QuickActionButton(
                        icon: Icons.payments,
                        label: 'Pay',
                        onTap: () => Navigator.pushNamed(context, '/pay'),
                      ),
                      QuickActionButton(
                        icon: Icons.qr_code,
                        label: 'Receive',
                        onTap: () => Navigator.pushNamed(context, '/receive'),
                      ),
                      QuickActionButton(
                        icon: Icons.history,
                        label: 'History',
                        onTap: () => Navigator.pushNamed(context, '/history'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 32),

                  // Recent Transactions
                  Text(
                    'Recent Transactions',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 16),
                  RecentTransactions(
                    transactions: wallet.transactions.take(5).toList(),
                    currentUserId: wallet.currentUser!.userId,
                  ),

                  // Warning banner
                  const SizedBox(height: 32),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.orange.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.orange),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.warning_amber, color: Colors.orange),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '⚠️ SIMULATED MONEY ONLY\nEducational Project',
                            style: TextStyle(
                              color: Colors.orange.shade900,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
