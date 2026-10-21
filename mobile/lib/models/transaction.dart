class Transaction {
  final String transactionId;
  final String senderId;
  final String receiverId;
  final String senderWalletId;
  final String receiverWalletId;
  final double amount;
  final TransactionType type;
  final TransactionStatus status;
  final String description;
  final String? nonce;
  final String? senderPublicKey;
  final String? signature;
  final String? rejectionReason;
  final DateTime timestamp;

  Transaction({
    required this.transactionId,
    required this.senderId,
    required this.receiverId,
    required this.senderWalletId,
    required this.receiverWalletId,
    required this.amount,
    required this.type,
    required this.status,
    required this.description,
    this.nonce,
    this.senderPublicKey,
    this.signature,
    this.rejectionReason,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  factory Transaction.fromJson(Map<String, dynamic> json) {
    return Transaction(
      transactionId: json['transactionId'] as String,
      senderId: json['senderId'] as String,
      receiverId: json['receiverId'] as String,
      senderWalletId: json['senderWalletId'] as String,
      receiverWalletId: json['receiverWalletId'] as String,
      amount: (json['amount'] as num).toDouble(),
      type: TransactionType.fromString(json['type'] as String),
      status: TransactionStatus.fromString(json['status'] as String),
      description: json['description'] as String,
      nonce: json['nonce'] as String?,
      senderPublicKey: json['senderPublicKey'] as String?,
      signature: json['signature'] as String?,
      rejectionReason: json['rejectionReason'] as String?,
      timestamp: json['timestamp'] != null
          ? DateTime.parse(json['timestamp'] as String)
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'transactionId': transactionId,
      'senderId': senderId,
      'receiverId': receiverId,
      'senderWalletId': senderWalletId,
      'receiverWalletId': receiverWalletId,
      'amount': amount,
      'type': type.toString(),
      'status': status.toString(),
      'description': description,
      'nonce': nonce,
      'senderPublicKey': senderPublicKey,
      'signature': signature,
      'rejectionReason': rejectionReason,
      'timestamp': timestamp.toIso8601String(),
    };
  }

  /// Phase 5: an identical copy carrying this payment's signature.
  ///
  /// Every field - INCLUDING the timestamp - is copied exactly, so the
  /// canonical payload that was signed describes precisely this copy.
  /// (`Transaction` is immutable; signing mutates nothing.)
  Transaction signed({
    required String signature,
    required String senderPublicKey,
  }) {
    return Transaction(
      transactionId: transactionId,
      senderId: senderId,
      receiverId: receiverId,
      senderWalletId: senderWalletId,
      receiverWalletId: receiverWalletId,
      amount: amount,
      type: type,
      status: status,
      description: description,
      nonce: nonce,
      senderPublicKey: senderPublicKey,
      signature: signature,
      rejectionReason: rejectionReason,
      timestamp: timestamp,
    );
  }
}

enum TransactionType {
  topup,
  directTransfer,
  offlinePayment;

  static TransactionType fromString(String value) {
    switch (value.toUpperCase()) {
      case 'TOPUP':
        return TransactionType.topup;
      case 'DIRECT_TRANSFER':
        return TransactionType.directTransfer;
      case 'OFFLINE_PAYMENT':
        return TransactionType.offlinePayment;
      default:
        return TransactionType.directTransfer;
    }
  }

  @override
  String toString() {
    switch (this) {
      case TransactionType.topup:
        return 'TOPUP';
      case TransactionType.directTransfer:
        return 'DIRECT_TRANSFER';
      case TransactionType.offlinePayment:
        return 'OFFLINE_PAYMENT';
    }
  }
}

enum TransactionStatus {
  pendingSync,
  syncing,
  confirmed,
  rejected,
  conflict;

  static TransactionStatus fromString(String value) {
    switch (value.toUpperCase()) {
      case 'PENDING_SYNC':
        return TransactionStatus.pendingSync;
      case 'SYNCING':
        return TransactionStatus.syncing;
      case 'CONFIRMED':
        return TransactionStatus.confirmed;
      case 'REJECTED':
        return TransactionStatus.rejected;
      case 'CONFLICT':
        return TransactionStatus.conflict;
      default:
        return TransactionStatus.confirmed;
    }
  }

  @override
  String toString() {
    switch (this) {
      case TransactionStatus.pendingSync:
        return 'PENDING_SYNC';
      case TransactionStatus.syncing:
        return 'SYNCING';
      case TransactionStatus.confirmed:
        return 'CONFIRMED';
      case TransactionStatus.rejected:
        return 'REJECTED';
      case TransactionStatus.conflict:
        return 'CONFLICT';
    }
  }
}
