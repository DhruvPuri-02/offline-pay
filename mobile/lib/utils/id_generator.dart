import 'package:uuid/uuid.dart';

class IdGenerator {
  static const _uuid = Uuid();

  static String generateUserId() {
    return 'USER_${_uuid.v4().substring(0, 12)}';
  }

  static String generateWalletId() {
    return 'WALLET_${_uuid.v4().substring(0, 12)}';
  }

  static String generateTransactionId() {
    return 'TXN_${_uuid.v4().substring(0, 16)}';
  }

  static String generateNonce() {
    return _uuid.v4().substring(0, 16);
  }
}
