// Regenerates the Phase 5 cross-platform interop vector.
//
// The SAME fixture transaction, the SAME fixed private-key seed, the SAME
// canonical payload - produced here in Dart and verified in Node
// (backend/test/signature_interop.test.js). If both suites accept this
// vector, receipts signed on a phone can be verified by the Phase 6
// backend, byte for byte.
//
// Usage:  cd mobile && dart run tool/gen_interop_vector.dart
//
// Paste the output into:
//   mobile/test/signature_service_test.dart
//   backend/test/signature_interop.test.js

import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:offlinepay/models/transaction.dart';
import 'package:offlinepay/services/signature_service.dart';

Future<void> main() async {
  // Fixed seed = bytes 0x00..0x1F, so the vector is reproducible forever.
  const seedBase64 = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=';

  final fixture = Transaction(
    transactionId: 'TX_interop_0001',
    senderId: 'USER_alice',
    receiverId: 'USER_bob',
    senderWalletId: 'WALLET_alice',
    receiverWalletId: 'WALLET_bob',
    amount: 125.50,
    type: TransactionType.offlinePayment,
    status: TransactionStatus.pendingSync,
    description: 'Interop vector payment',
    nonce: 'nonce_interop_1',
    timestamp: DateTime.utc(2026, 1, 15, 10, 30, 0, 123),
  );

  final canonical = SignatureService.canonicalPayload(fixture);
  final signature =
      await SignatureService.sign(canonical, seedBase64: seedBase64);

  // Public key derived from the fixed seed (Ed25519 import).
  final pair =
      await Ed25519().newKeyPairFromSeed(base64Decode(seedBase64));
  final publicKey = base64Encode((await pair.extractPublicKey()).bytes);

  // ignore: avoid_print
  print('PUBLIC_KEY_BASE64=$publicKey');
  // ignore: avoid_print
  print('SIGNATURE_BASE64=$signature');
  // ignore: avoid_print
  print('CANONICAL=$canonical');
}
