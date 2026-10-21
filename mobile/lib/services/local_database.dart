import 'package:path/path.dart' as p;
// `hide Transaction` is required: sqflite exports a `Transaction` type for
// SQL BEGIN/COMMIT blocks, which would collide with our transaction model.
import 'package:sqflite/sqflite.dart' hide Transaction;

import '../models/transaction.dart';
import '../models/user.dart';

/// Local SQLite storage - the heart of the offline-first design.
///
/// Everything the app needs to run WITHOUT internet lives here:
///   * the wallet profile (identity + confirmed balance)
///   * the transaction ledger (incoming, outgoing, pending, rejected)
///
/// The app reads from this database on startup and never blocks on the
/// network. The backend is only contacted later, during Phase 6 sync,
/// to reconcile what happened while offline.
///
/// Design notes for reviewers:
///  * `transactionId` is the PRIMARY KEY. Inserting the same transaction
///    twice (e.g. scanning the same receipt QR twice) is therefore a no-op,
///    which is what makes the local ledger idempotent.
///  * A partial UNIQUE index on `nonce` gives the same protection at the
///    database level, mirroring the backend's index on `transactions.nonce`.
class LocalDatabase {
  /// [path] exists so tests can run against an in-memory database
  /// (`LocalDatabase.inMemory()`), keeping them fast and isolated.
  LocalDatabase({String? path}) : _pathOverride = path;

  /// The single instance the app uses.
  static final LocalDatabase instance = LocalDatabase();

  /// Creates a throwaway database that lives only in RAM (used by tests).
  factory LocalDatabase.inMemory() => LocalDatabase(path: ':memory:');

  final String? _pathOverride;
  Database? _db;

  static const int _schemaVersion = 1;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _open();
    return _db!;
  }

  Future<Database> _open() async {
    final String path;
    if (_pathOverride != null) {
      path = _pathOverride!;
    } else {
      path = p.join(await getDatabasesPath(), 'offlinepay.db');
    }

    return openDatabase(
      path,
      version: _schemaVersion,
      onCreate: _createSchema,
    );
  }

  Future<void> _createSchema(Database db, int version) async {
    // ---------------------------------------------------------------
    // Wallet profile: one row per device. `confirmed_balance` is the
    // balance the backend has (or will have) agreed with. Pending
    // offline payments are NOT subtracted here - they are derived from
    // the ledger at runtime, so the raw confirmed figure stays intact
    // for reconciliation.
    // ---------------------------------------------------------------
    await db.execute('''
      CREATE TABLE wallet_profile (
        user_id           TEXT PRIMARY KEY,
        username          TEXT NOT NULL,
        name              TEXT NOT NULL,
        wallet_id         TEXT NOT NULL UNIQUE,
        confirmed_balance REAL NOT NULL DEFAULT 0,
        public_key        TEXT,
        created_at        TEXT NOT NULL
      )
    ''');

    // ---------------------------------------------------------------
    // Transaction ledger. One row per transaction, ever - regardless of
    // status (PENDING_SYNC / SYNCING / CONFIRMED / REJECTED / CONFLICT).
    // ---------------------------------------------------------------
    await db.execute('''
      CREATE TABLE transactions (
        transaction_id      TEXT PRIMARY KEY,
        sender_id           TEXT NOT NULL,
        receiver_id         TEXT NOT NULL,
        sender_wallet_id    TEXT NOT NULL,
        receiver_wallet_id  TEXT NOT NULL,
        amount              REAL NOT NULL,
        type                TEXT NOT NULL,
        status              TEXT NOT NULL,
        description         TEXT NOT NULL,
        nonce               TEXT,
        sender_public_key   TEXT,
        signature           TEXT,
        rejection_reason    TEXT,
        timestamp           TEXT NOT NULL
      )
    ''');

    // History is always read "newest first, for this user".
    await db.execute('''
      CREATE INDEX idx_transactions_time
      ON transactions (timestamp DESC)
    ''');

    // Replay protection: the same nonce can never be recorded twice.
    // The WHERE clause keeps NULL nonces (e.g. seeded topups) out of the
    // index, because SQLite counts NULLs as distinct-but-equal for
    // UNIQUE indexes and would otherwise reject a second NULL row.
    await db.execute('''
      CREATE UNIQUE INDEX idx_transactions_nonce
      ON transactions (nonce)
      WHERE nonce IS NOT NULL
    ''');
  }

  // ------------------------------------------------------------------
  // Wallet profile
  // ------------------------------------------------------------------

  Future<User?> getWalletProfile() async {
    final db = await database;
    final rows = await db.query('wallet_profile', limit: 1);
    if (rows.isEmpty) return null;

    final row = rows.first;
    return User(
      userId: row['user_id'] as String,
      username: row['username'] as String,
      name: row['name'] as String,
      walletId: row['wallet_id'] as String,
      balance: (row['confirmed_balance'] as num).toDouble(),
      publicKey: row['public_key'] as String?,
      createdAt: DateTime.parse(row['created_at'] as String),
    );
  }

  Future<void> saveWalletProfile(User user) async {
    final db = await database;
    await db.insert(
      'wallet_profile',
      {
        'user_id': user.userId,
        'username': user.username,
        'name': user.name,
        'wallet_id': user.walletId,
        'confirmed_balance': user.balance,
        'public_key': user.publicKey,
        'created_at': user.createdAt.toIso8601String(),
      },
      // Replacing keeps the profile in one place if it is ever updated.
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Update only the confirmed balance (used once Phase 6 sync reconciles
  /// with the backend).
  Future<void> updateConfirmedBalance(String userId, double newBalance) async {
    final db = await database;
    await db.update(
      'wallet_profile',
      {'confirmed_balance': newBalance},
      where: 'user_id = ?',
      whereArgs: [userId],
    );
  }

  // ------------------------------------------------------------------
  // Transaction ledger
  // ------------------------------------------------------------------

  /// Insert a transaction.
  ///
  /// Returns `true` if a NEW row was written, `false` if it was already
  /// there. That return value is what makes receiving the same QR twice
  /// harmless: the second attempt changes nothing (idempotency).
  Future<bool> insertTransaction(Transaction tx) async {
    final db = await database;

    final existing = await db.query(
      'transactions',
      columns: ['transaction_id'],
      where: 'transaction_id = ?',
      whereArgs: [tx.transactionId],
      limit: 1,
    );
    if (existing.isNotEmpty) return false;

    try {
      await db.insert('transactions', _toRow(tx));
      return true;
    } on DatabaseException catch (e) {
      // A UNIQUE constraint fired (duplicate nonce). Treat it exactly
      // like a duplicate transaction id: already recorded.
      if (e.isUniqueConstraintError()) return false;
      rethrow;
    }
  }

  /// All transactions, newest first.
  Future<List<Transaction>> getTransactions() async {
    final db = await database;
    final rows = await db.query('transactions', orderBy: 'timestamp DESC');
    return rows.map(_fromRow).toList();
  }

  /// Transactions still waiting for the backend (the Phase 6 upload queue).
  Future<List<Transaction>> getPendingSyncTransactions() async {
    final db = await database;
    final rows = await db.query(
      'transactions',
      where: 'status IN (?, ?)',
      whereArgs: [
        TransactionStatus.pendingSync.toString(),
        TransactionStatus.syncing.toString(),
      ],
      orderBy: 'timestamp ASC',
    );
    return rows.map(_fromRow).toList();
  }

  /// Update a transaction's status after the backend has responded
  /// (Phase 6). Stores the rejection reason so the UI can explain WHY
  /// a payment failed.
  Future<void> updateTransactionStatus(
    String transactionId,
    TransactionStatus status, {
    String? rejectionReason,
  }) async {
    final db = await database;
    await db.update(
      'transactions',
      {
        'status': status.toString(),
        if (rejectionReason != null) 'rejection_reason': rejectionReason,
      },
      where: 'transaction_id = ?',
      whereArgs: [transactionId],
    );
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  // ------------------------------------------------------------------
  // Row mapping
  // ------------------------------------------------------------------

  Map<String, Object?> _toRow(Transaction tx) {
    return {
      'transaction_id': tx.transactionId,
      'sender_id': tx.senderId,
      'receiver_id': tx.receiverId,
      'sender_wallet_id': tx.senderWalletId,
      'receiver_wallet_id': tx.receiverWalletId,
      'amount': tx.amount,
      'type': tx.type.toString(),
      'status': tx.status.toString(),
      'description': tx.description,
      'nonce': tx.nonce,
      'sender_public_key': tx.senderPublicKey,
      'signature': tx.signature,
      'rejection_reason': tx.rejectionReason,
      'timestamp': tx.timestamp.toIso8601String(),
    };
  }

  Transaction _fromRow(Map<String, Object?> row) {
    return Transaction(
      transactionId: row['transaction_id'] as String,
      senderId: row['sender_id'] as String,
      receiverId: row['receiver_id'] as String,
      senderWalletId: row['sender_wallet_id'] as String,
      receiverWalletId: row['receiver_wallet_id'] as String,
      amount: (row['amount'] as num).toDouble(),
      type: TransactionType.fromString(row['type'] as String),
      status: TransactionStatus.fromString(row['status'] as String),
      description: row['description'] as String,
      nonce: row['nonce'] as String?,
      senderPublicKey: row['sender_public_key'] as String?,
      signature: row['signature'] as String?,
      rejectionReason: row['rejection_reason'] as String?,
      timestamp: DateTime.parse(row['timestamp'] as String),
    );
  }
}
