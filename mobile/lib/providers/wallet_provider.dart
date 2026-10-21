import 'package:flutter/foundation.dart';

import '../models/transaction.dart';
import '../models/user.dart';
import '../services/local_database.dart';
import '../services/pin_service.dart';
import '../services/secure_key_store.dart';
import '../services/signature_service.dart';
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
  WalletProvider({
    LocalDatabase? database,
    DateTime Function()? clock,
    SecureKeyStore? keyStore,
  })  : _db = database ?? LocalDatabase.instance,
        _clock = clock ?? DateTime.now,
        _keyStore = keyStore ?? const PlatformKeyStore();

  /// Hard cap on a single offline payment (spec section 11, offline limit).
  /// Deliberately small: a lost/stolen device can only inject so much
  /// unverified debt into the system before the server rejects it at sync.
  static const double maxOfflineTransactionAmount = 500;

  /// Balance granted on first launch so the app is demo-able offline.
  /// This is SIMULATED money created locally - Phase 6 will create the
  /// matching wallet on the backend with the same starting value.
  static const double firstRunSeedBalance = 500;

  final LocalDatabase _db;

  /// Injectable time source: the lockout rules are pure functions of
  /// "now", so tests can fast-forward through a lockout without waiting.
  final DateTime Function() _clock;

  /// Encrypted storage for the Ed25519 private key (platform keystore).
  final SecureKeyStore _keyStore;

  User? _profile;
  List<Transaction> _transactions = [];
  PinRecord _pinRecord = const PinRecord();
  String? _publicKeyBase64; // lazily loaded (Phase 5)
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

  // ------------------------------------------------------------------
  // Transaction PIN state (Phase 4)
  // ------------------------------------------------------------------

  /// Whether a transaction PIN has been created on this device.
  bool get hasTransactionPin => _pinRecord.isConfigured;

  /// Time left in the current lockout (zero when not locked).
  Duration get pinLockRemaining {
    final until = _pinRecord.lockedUntil;
    if (until == null) return Duration.zero;
    final remaining = until.difference(_clock());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// Failed attempts left before lockout (only meaningful when a PIN
  /// is configured and the wallet is not locked).
  int get pinAttemptsRemaining =>
      PinService.maxFailedAttempts - _pinRecord.failedAttempts;

  // ------------------------------------------------------------------
  // Transaction signing state (Phase 5)
  // ------------------------------------------------------------------

  /// This wallet's Ed25519 public key (base64), or `null` before the
  /// first payment - keys are generated lazily, never at app start.
  String? get publicKeyBase64 => _publicKeyBase64;

  /// Whether a signing key exists on this device yet.
  bool get hasSigningKey => _publicKeyBase64 != null;

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
      _pinRecord = await _db.getPinRecord();
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
    _pinRecord = await _db.getPinRecord();
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
  // Transaction PIN (Phase 4)
  // ------------------------------------------------------------------

  /// Create the device's transaction PIN (first payment does this before
  /// the payment is allowed through).
  Future<void> setTransactionPin(String pin) async {
    _requireInitialized();
    final formatError = PinService.validateFormat(pin);
    if (formatError != null) throw PaymentException(formatError);

    // Hashing is CPU-bound (~80ms at cost 10) - kept synchronous inside
    // this async call so the UI can show its busy state around it.
    await _db.savePinHash(PinService.hash(pin));
    _pinRecord = await _db.getPinRecord();
    notifyListeners();
  }

  /// Change the PIN: current PIN must verify first.
  Future<void> changeTransactionPin({
    required String currentPin,
    required String newPin,
  }) async {
    await _verifyTransactionPin(currentPin); // throws on wrong/locked
    final formatError = PinService.validateFormat(newPin);
    if (formatError != null) throw PaymentException(formatError);

    await _db.savePinHash(PinService.hash(newPin));
    _pinRecord = await _db.getPinRecord();
    notifyListeners();
  }

  /// Verify [pin] against the stored hash, applying the brute-force policy.
  ///
  /// Throws [PaymentException] with a user-facing reason on failure.
  /// Success clears the failed-attempt counter.
  ///
  /// When NO PIN has been configured yet this returns silently: nothing
  /// to verify. The UI always forces `setTransactionPin()` before the
  /// first payment, so the bootstrap window never applies to real usage.
  Future<void> _verifyTransactionPin(String? pin) async {
    final record = await _db.getPinRecord();
    _pinRecord = record;
    if (!record.isConfigured) return;

    final now = _clock();

    // Lockout check comes first and ignores the entered value entirely:
    // while locked, even the correct PIN must not work.
    final lockedUntil = record.lockedUntil;
    if (lockedUntil != null && now.isBefore(lockedUntil)) {
      throw PaymentException(
        'Too many failed attempts. Payments locked for '
        '${lockedUntil.difference(now).inSeconds} more seconds.',
      );
    }

    if (pin == null) {
      throw const PaymentException('Transaction PIN required.');
    }
    final formatError = PinService.validateFormat(pin);
    if (formatError != null) throw PaymentException(formatError);

    if (PinService.verify(pin, record.hash!)) {
      await _db.clearPinFailures();
      _pinRecord = await _db.getPinRecord();
      notifyListeners();
      return;
    }

    // Wrong PIN: count it. At the limit, start a lockout with a FRESH
    // counter so that after the cooldown the user gets a new set of
    // attempts (otherwise the next mistake would re-lock instantly).
    final attempts = record.failedAttempts + 1;
    if (attempts >= PinService.maxFailedAttempts) {
      final until = now.add(PinService.lockoutDuration);
      await _db.savePinAttempts(0, until);
      _pinRecord = await _db.getPinRecord();
      notifyListeners();
      throw PaymentException(
        'Too many failed attempts. Payments locked for '
        '${PinService.lockoutDuration.inSeconds} seconds.',
      );
    }

    await _db.savePinAttempts(attempts, null);
    _pinRecord = await _db.getPinRecord();
    notifyListeners();
    throw PaymentException(
      'Incorrect transaction PIN. '
      '${PinService.maxFailedAttempts - attempts} attempt(s) left.',
    );
  }

  // ------------------------------------------------------------------
  // Transaction signing (Phase 5)
  // ------------------------------------------------------------------

  /// Load this device's signing key, generating it on first use.
  ///
  /// Lazy by design: key generation costs ~56ms and most app opens never
  /// send a payment, so launch stays instant. The seed goes into the
  /// encrypted [SecureKeyStore]; only the public key is cached in memory.
  Future<void> _loadSigningKeyIfNeeded() async {
    if (_publicKeyBase64 != null) return;

    var seed = await _keyStore.read(SignatureService.privateKeySeedKey);
    var publicKey = await _keyStore.read(SignatureService.publicKeyKey);

    if (seed == null || publicKey == null) {
      // First payment this device ever makes -> create the identity.
      final pair = await SignatureService.generateKeyPair();
      seed = pair.seedBase64;
      publicKey = pair.publicKeyBase64;
      await _keyStore.write(SignatureService.privateKeySeedKey, seed);
      await _keyStore.write(SignatureService.publicKeyKey, publicKey);
    }

    _publicKeyBase64 = publicKey;
  }

  /// Force key creation (if needed) and return the public key, e.g. for
  /// the UI or Phase 6 registration with the backend.
  Future<String> ensureSigningKey() async {
    await _loadSigningKeyIfNeeded();
    return _publicKeyBase64!;
  }

  /// Phase 5: attach this device's signature to [tx].
  ///
  /// The signed message is `SignatureService.canonicalPayload(tx)` - the
  /// tamper-evident core of the receipt. The private seed is read from
  /// the secure key store for this call and never persisted elsewhere.
  Future<Transaction> _signTransaction(Transaction tx) async {
    await _loadSigningKeyIfNeeded();
    final seed = await _keyStore.read(SignatureService.privateKeySeedKey);
    final signature = await SignatureService.sign(
      SignatureService.canonicalPayload(tx),
      seedBase64: seed!,
    );
    return tx.signed(
      signature: signature,
      senderPublicKey: _publicKeyBase64!,
    );
  }

  // ------------------------------------------------------------------
  // Payer side
  // ------------------------------------------------------------------

  /// Create an offline payment from this device.
  ///
  /// Flow (spec section 6, adapted for Phase 4):
  ///   validate balance -> verify transaction PIN -> create -> store in
  ///   the local ledger.
  ///
  /// The transaction is ALWAYS created as PENDING_SYNC: only the backend,
  /// during Phase 6, may declare it CONFIRMED.
  ///
  /// [transactionPin] is verified here - inside the operation that moves
  /// money - so no other code path can create a payment while skipping
  /// the PIN check. The plaintext PIN is used for this call only: it is
  /// compared against the stored bcrypt hash and never persisted.
  ///
  /// Throws [PaymentException] with a user-facing reason when refused.
  Future<Transaction> createOfflinePayment({
    required String receiverId,
    required String receiverWalletId,
    required double amount,
    String description = 'Payment',
    String? nonce,
    String? transactionPin,
  }) async {
    _requireInitialized();
    final sender = _profile!;

    // Cheap, PIN-independent checks first - never ask for a PIN that
    // could not be used anyway (and never waste an attempt on a payment
    // that would be refused regardless).
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

    // Phase 4: PIN verification (lockout policy included). This happens
    // BEFORE any ledger entry exists, so a failed attempt writes nothing.
    await _verifyTransactionPin(transactionPin);

    final unsigned = Transaction(
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
      timestamp: DateTime.now(),
    );

    // Phase 5: sign the canonical payment fields with this device's
    // private key (generated lazily on the first payment, kept in the
    // platform keystore). The signature travels with the receipt and lets
    // the receiver - and later the backend - detect any tampering.
    final transaction = await _signTransaction(unsigned);

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

    // Phase 5 FIRST: verify the payer's signature before any field of the
    // receipt is trusted. A tampered amount, receiver or nonce breaks the
    // signature, so a hostile payer cannot hand Bob a receipt for a
    // different payment than Alice actually signed. Unsigned receipts
    // (pre-Phase-5 builds) are still accepted; a HALF-signed receipt is
    // refused - that combination never leaves a real build.
    final signature = tx.signature;
    final publicKey = tx.senderPublicKey;
    if (signature != null || publicKey != null) {
      if (signature == null || publicKey == null) {
        throw const PaymentException(
            'Receipt has an incomplete signature. Not recorded.');
      }
      final valid = await SignatureService.verify(
        SignatureService.canonicalPayload(tx),
        signatureBase64: signature,
        publicKeyBase64: publicKey,
      );
      if (!valid) {
        throw const PaymentException(
          'Receipt signature is invalid: this QR was tampered with or '
          'forged. Not recorded.',
        );
      }
    }

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
