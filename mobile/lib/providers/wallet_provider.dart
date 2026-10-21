import 'package:flutter/foundation.dart';

import '../models/transaction.dart';
import '../models/user.dart';
import '../services/local_database.dart';
import '../utils/balance.dart';
import '../utils/id_generator.dart';
import '../utils/payment_exception.dart';

/// App-wide wallet state, stored OFFLINE-FIRST.
///
/// Data flow (Phase 3 architecture):
///
///   app start  -> read SQLite (never waits for the network)
///   user acts  -> validate -> write SQLite -> update memory -> notify UI
///   Phase 6    -> (later) upload PENDING_SYNC rows, reconcile, update SQLite
///
/// The backend is NOT in this loop yet. That is the point: opening the
/// wallet, checking balance, reading history, paying and receiving all work
/// with Wi-Fi and mobile data switched off.
class WalletProvider with ChangeNotifier {
  WalletProvider({LocalDatabase? database})
      : _db = database ?? LocalDatabase.instance;

  /// Hard cap on a single offline payment (spec section 11, offline limit).
  /// Deliberately small: a lost/stolen device can only inject so much
  /// unverified debt into the system before the server rejects it at sync.
  static const double maxOfflineTransactionAmount = 500;

  /// Balance granted on first launch so the app is demo-able offline.
  /// This is SIMULATED money created locally - Phase 6 will create the
  /// matching wallet on the backend with the same starting value.
  static const double firstRunSeedBalance = 500;

  final LocalDatabase _db;

  User? _profile;
  List<Transaction> _transactions = [];
  bool _initialized = false;
  bool _busy = false;
  String? _error;

  // ------------------------------------------------------------------
  // Read-only state
  // ------------------------------------------------------------------

  User? get currentUser => _profile;
  bool get isInitialized => _initialized;
  bool get isLoading => _busy;
  String? get error => _error;

  /// The local ledger, newest first.
  List<Transaction> get transactions => List.unmodifiable(_transactions);

  BalanceSummary get balanceSummary => computeBalance(
        confirmed: _profile?.balance ?? 0,
        transactions: _transactions,
        userId: _profile?.userId ?? '',
      );

  /// Money the backend has agreed with us.
  double get confirmedBalance => balanceSummary.confirmed;

  /// Offline payments we made that are still unsettled.
  double get pendingOutgoing => balanceSummary.pendingOutgoing;

  /// Offline payments others made to us that are still unsettled.
  double get pendingIncoming => balanceSummary.pendingIncoming;

  /// What may be spent right now, offline = confirmed - pending outgoing.
  double get availableBalance => balanceSummary.available;

  /// Alias kept so widgets can keep reading `wallet.balance`.
  double get balance => availableBalance;

  /// The Phase 6 upload queue: everything that must reach the backend.
  List<Transaction> get pendingSyncTransactions =>
      _transactions.where((tx) => _isUnsettled(tx)).toList();

  List<Transaction> get sentTransactions => _transactions
      .where((tx) => tx.senderId == _profile?.userId)
      .toList();

  List<Transaction> get receivedTransactions => _transactions
      .where((tx) => tx.receiverId == _profile?.userId)
      .toList();

  static bool _isUnsettled(Transaction tx) =>
      tx.status == TransactionStatus.pendingSync ||
      tx.status == TransactionStatus.syncing;

  // ------------------------------------------------------------------
  // Lifecycle
  // ------------------------------------------------------------------

  /// Open the local wallet. Called once before the first frame.
  ///
  /// Purely local: if this is the first launch it seeds a demo wallet, also
  /// locally. No socket is opened, so the app paints instantly offline.
  Future<void> initialize() async {
    if (_busy) return;
    _busy = true;
    _error = null;
    notifyListeners();

    try {
      var profile = await _db.getWalletProfile();
      profile ??= await _seedFirstRunWallet();

      _profile = profile;
      _transactions = await _db.getTransactions();
      _initialized = true;
    } catch (e) {
      _error = 'Failed to open local wallet: $e';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Re-read everything from SQLite (used by pull-to-refresh).
  /// Local-only by design - syncing with the backend is Phase 6.
  Future<void> reload() async {
    final profile = await _db.getWalletProfile();
    if (profile == null) return;
    _profile = profile;
    _transactions = await _db.getTransactions();
    notifyListeners();
  }

  /// First launch: create a local demo identity + seed balance.
  Future<User> _seedFirstRunWallet() async {
    final user = User(
      userId: IdGenerator.generateUserId(),
      username: 'demo_user',
      name: 'Demo User',
      walletId: IdGenerator.generateWalletId(),
      balance: firstRunSeedBalance,
    );
    await _db.saveWalletProfile(user);

    // Record where the starting money came from, otherwise the history
    // shows a balance that no transaction ever explains.
    final seedTx = Transaction(
      transactionId: IdGenerator.generateTransactionId(),
      senderId: 'SYSTEM',
      receiverId: user.userId,
      senderWalletId: 'SYSTEM',
      receiverWalletId: user.walletId,
      amount: firstRunSeedBalance,
      type: TransactionType.topup,
      // Marked CONFIRMED because it is the wallet's *baseline*, not an
      // offline payment awaiting reconciliation. The backend gets seeded
      // with the same figure during Phase 6.
      status: TransactionStatus.confirmed,
      description: 'Initial simulated balance (demo seed)',
      timestamp: DateTime.now(),
    );
    await _db.insertTransaction(seedTx);
    return user;
  }

  // ------------------------------------------------------------------
  // Payer side
  // ------------------------------------------------------------------

  /// Create an offline payment from this device.
  ///
  /// Flow (spec section 6): validate -> create -> store in local ledger.
  /// The transaction is ALWAYS created as PENDING_SYNC: only the backend,
  /// during Phase 6, may declare it CONFIRMED.
  ///
  /// Throws [PaymentException] with a user-facing reason when refused.
  Future<Transaction> createOfflinePayment({
    required String receiverId,
    required String receiverWalletId,
    required double amount,
    String description = 'Payment',
    String? nonce,
  }) async {
    _requireInitialized();
    final sender = _profile!;

    final decision = validateOfflinePayment(
      amount: amount,
      available: availableBalance,
      senderId: sender.userId,
      receiverId: receiverId,
      maxOfflineAmount: maxOfflineTransactionAmount,
    );
    if (!decision.allowed) {
      throw PaymentException(decision.reason!);
    }

    // --------------------------------------------------------------
    // PHASE 4 HOOK: verify the transaction PIN here, BEFORE anything
    // is written. Verify against a salted hash (never plaintext), then
    // apply failed-attempt lockout. Nothing below this line should run
    // unless the PIN check passes.
    // --------------------------------------------------------------

    final transaction = Transaction(
      transactionId: IdGenerator.generateTransactionId(),
      senderId: sender.userId,
      receiverId: receiverId,
      senderWalletId: sender.walletId,
      receiverWalletId: receiverWalletId,
      amount: amount,
      type: TransactionType.offlinePayment,
      status: TransactionStatus.pendingSync,
      description: description,
      nonce: nonce ?? IdGenerator.generateNonce(),
      // --------------------------------------------------------------
      // PHASE 5 HOOK: sign the canonical transaction fields with the
      // sender's private key and set `senderPublicKey` + `signature`.
      // The private key never leaves this device.
      // --------------------------------------------------------------
      timestamp: DateTime.now(),
    );

    final inserted = await _db.insertTransaction(transaction);
    if (!inserted) {
      throw const PaymentException('This transaction was already recorded.');
    }

    _transactions.insert(0, transaction);
    notifyListeners();
    return transaction;
  }

  // ------------------------------------------------------------------
  // Receiver side
  // ------------------------------------------------------------------

  /// Record a payment handed to us by the payer (scanned receipt QR).
  ///
  /// Returns `true` when newly recorded, `false` when it was already in the
  /// ledger - scanning the same receipt twice must never credit twice.
  ///
  /// Throws [PaymentException] if the receipt is not actually ours.
  Future<bool> recordIncomingPayment(Transaction tx) async {
    _requireInitialized();
    final me = _profile!;

    if (tx.receiverId != me.userId) {
      throw const PaymentException(
          'This payment is addressed to a different wallet.');
    }
    if (tx.senderId == me.userId) {
      throw const PaymentException('You cannot receive your own payment.');
    }
    if (tx.amount <= 0) {
      throw const PaymentException('Transaction amount is invalid.');
    }

    // --------------------------------------------------------------
    // PHASE 5 HOOK: verify `tx.signature` against `tx.senderPublicKey`
    // here. Without signatures a hostile payer could alter the amount
    // between signing and scanning - that check is not possible yet,
    // and the app must not claim otherwise.
    // --------------------------------------------------------------

    final inserted = await _db.insertTransaction(tx);
    if (inserted) {
      _transactions.insert(0, tx);
      notifyListeners();
    }
    // false == duplicate scan: not an error, just a no-op.
    return inserted;
  }

  // ------------------------------------------------------------------
  // Phase 6 helpers (status updates come back from the backend)
  // ------------------------------------------------------------------

  Future<void> updateTransactionStatus(
    String transactionId,
    TransactionStatus status, {
    String? rejectionReason,
  }) async {
    await _db.updateTransactionStatus(
      transactionId,
      status,
      rejectionReason: rejectionReason,
    );
    await reload();
  }

  Future<void> updateConfirmedBalance(double newBalance) async {
    final user = _profile;
    if (user == null) return;
    await _db.updateConfirmedBalance(user.userId, newBalance);
    await reload();
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }

  void _requireInitialized() {
    if (!_initialized || _profile == null) {
      throw const PaymentException('Wallet is not ready yet.');
    }
  }
}
