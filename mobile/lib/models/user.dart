class User {
  final String userId;
  final String username;
  final String name;
  final String walletId;
  double balance;
  final String? publicKey;
  final DateTime createdAt;

  User({
    required this.userId,
    required this.username,
    required this.name,
    required this.walletId,
    required this.balance,
    this.publicKey,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      userId: json['userId'] as String,
      username: json['username'] as String,
      name: json['name'] as String,
      walletId: json['walletId'] as String,
      balance: (json['balance'] as num).toDouble(),
      publicKey: json['publicKey'] as String?,
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'] as String)
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'userId': userId,
      'username': username,
      'name': name,
      'walletId': walletId,
      'balance': balance,
      'publicKey': publicKey,
      'createdAt': createdAt.toIso8601String(),
    };
  }
}
