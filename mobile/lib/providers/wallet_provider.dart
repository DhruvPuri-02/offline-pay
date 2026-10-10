import 'package:flutter/foundation.dart';
import '../models/user.dart';
import '../models/transaction.dart';
import '../services/api_service.dart';

class WalletProvider with ChangeNotifier {
  User? _currentUser;
  List<Transaction> _transactions = [];
  bool _isLoading = false;
  String? _error;

  // Getters
  User? get currentUser => _currentUser;
  List<Transaction> get transactions => _transactions;
  bool get isLoading => _isLoading;
  String? get error => _error;
  double get balance => _currentUser?.balance ?? 0.0;

  // Initialize with demo user (for Phase 2 testing)
  void setDemoUser() {
    _currentUser = User(
      userId: 'USER_demo123',
      username: 'demo_user',
      name: 'Demo User',
      walletId: 'WALLET_demo456',
      balance: 1000.0,
    );
    notifyListeners();
  }

  // Load user data
  Future<void> loadUser(String userId) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final user = await ApiService.getUser(userId);
      _currentUser = user;
      await loadTransactions();
    } catch (e) {
      _error = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // Load transaction history
  Future<void> loadTransactions() async {
    if (_currentUser == null) return;

    try {
      _transactions = await ApiService.getTransactionHistory(_currentUser!.userId);
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  // Update balance locally (optimistic update)
  void updateBalance(double newBalance) {
    if (_currentUser != null) {
      _currentUser!.balance = newBalance;
      notifyListeners();
    }
  }

  // Add transaction locally
  void addTransaction(Transaction transaction) {
    _transactions.insert(0, transaction);
    notifyListeners();
  }

  // Get sent transactions
  List<Transaction> get sentTransactions {
    return _transactions
        .where((txn) => txn.senderId == _currentUser?.userId)
        .toList();
  }

  // Get received transactions
  List<Transaction> get receivedTransactions {
    return _transactions
        .where((txn) => txn.receiverId == _currentUser?.userId)
        .toList();
  }

  // Get pending sync transactions
  List<Transaction> get pendingTransactions {
    return _transactions
        .where((txn) => txn.status == TransactionStatus.pendingSync)
        .toList();
  }

  // Clear error
  void clearError() {
    _error = null;
    notifyListeners();
  }
}
