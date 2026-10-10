import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/transaction.dart';

class TransactionTile extends StatelessWidget {
  final Transaction transaction;
  final String currentUserId;

  const TransactionTile({
    super.key,
    required this.transaction,
    required this.currentUserId,
  });

  @override
  Widget build(BuildContext context) {
    final isSender = transaction.senderId == currentUserId;
    final isReceiver = transaction.receiverId == currentUserId;
    
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: isSender ? Colors.red.shade100 : Colors.green.shade100,
          child: Icon(
            isSender ? Icons.arrow_upward : Icons.arrow_downward,
            color: isSender ? Colors.red : Colors.green,
          ),
        ),
        title: Text(
          isSender 
            ? 'Paid to ${transaction.receiverId}'
            : 'Received from ${transaction.senderId}',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(transaction.description),
            const SizedBox(height: 4),
            Text(
              DateFormat('MMM dd, yyyy - hh:mm a').format(transaction.timestamp),
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              '${isSender ? '-' : '+'}₹${transaction.amount.toStringAsFixed(2)}',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
                color: isSender ? Colors.red : Colors.green,
              ),
            ),
            _buildStatusChip(transaction.status),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusChip(TransactionStatus status) {
    Color color;
    String label;

    switch (status) {
      case TransactionStatus.confirmed:
        color = Colors.green;
        label = 'Confirmed';
        break;
      case TransactionStatus.pendingSync:
        color = Colors.orange;
        label = 'Pending';
        break;
      case TransactionStatus.rejected:
        color = Colors.red;
        label = 'Rejected';
        break;
      default:
        color = Colors.grey;
        label = status.toString();
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
