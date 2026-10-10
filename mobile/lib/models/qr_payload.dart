class QRPayload {
  final String version;
  final String type;
  final String receiverId;
  final String receiverName;
  final String receiverWalletId;
  final double amount;
  final String description;
  final String nonce;
  final DateTime timestamp;
  final DateTime expiresAt;

  QRPayload({
    this.version = '1.0',
    this.type = 'PAYMENT_REQUEST',
    required this.receiverId,
    required this.receiverName,
    required this.receiverWalletId,
    required this.amount,
    required this.description,
    required this.nonce,
    DateTime? timestamp,
    DateTime? expiresAt,
  })  : timestamp = timestamp ?? DateTime.now(),
        expiresAt = expiresAt ?? DateTime.now().add(const Duration(minutes: 5));

  factory QRPayload.fromJson(Map<String, dynamic> json) {
    return QRPayload(
      version: json['version'] as String? ?? '1.0',
      type: json['type'] as String? ?? 'PAYMENT_REQUEST',
      receiverId: json['receiverId'] as String,
      receiverName: json['receiverName'] as String,
      receiverWalletId: json['receiverWalletId'] as String,
      amount: (json['amount'] as num).toDouble(),
      description: json['description'] as String,
      nonce: json['nonce'] as String,
      timestamp: json['timestamp'] != null
          ? DateTime.parse(json['timestamp'] as String)
          : DateTime.now(),
      expiresAt: json['expiresAt'] != null
          ? DateTime.parse(json['expiresAt'] as String)
          : DateTime.now().add(const Duration(minutes: 5)),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'type': type,
      'receiverId': receiverId,
      'receiverName': receiverName,
      'receiverWalletId': receiverWalletId,
      'amount': amount,
      'description': description,
      'nonce': nonce,
      'timestamp': timestamp.toIso8601String(),
      'expiresAt': expiresAt.toIso8601String(),
    };
  }

  bool get isExpired {
    return DateTime.now().isAfter(expiresAt);
  }

  Duration get timeUntilExpiry {
    return expiresAt.difference(DateTime.now());
  }

  String toQRString() {
    return toJson().toString();
  }
}
