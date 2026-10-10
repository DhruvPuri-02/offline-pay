import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/wallet_provider.dart';
import '../widgets/transaction_tile.dart';

class TransactionHistoryScreen extends StatelessWidget {
  const TransactionHistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Transaction History'),
      ),
      body: Consumer<WalletProvider>(
        builder: (context, wallet, child) {
          if (wallet.transactions.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.receipt_long, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text('No transactions yet', style: TextStyle(color: Colors.grey)),
                ],
              ),
            );
          }

          return ListView.builder(
            itemCount: wallet.transactions.length,
            itemBuilder: (context, index) {
              final transaction = wallet.transactions[index];
              return TransactionTile(
                transaction: transaction,
                currentUserId: wallet.currentUser!.userId,
              );
            },
          );
        },
      ),
    );
  }
}
