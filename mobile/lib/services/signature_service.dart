import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../models/transaction.dart';

/// Phase 5: transaction signing - the crypto that makes receipts prove
/// something.
///
/// What it buys us: when Alice pays Bob, her receipt carries a signature
/// only Alice's private key could produce, computed over the exact payment
/// details (amount, receiver, nonce, description, ...). Change ONE character
/// of the receipt and the signature no longer matches - so Bob (and, in
/// Phase 6, the backend) can prove the payment was authorized by the key
/// holder and was not tampered with between signing and scanning.
///
/// Algorithm: **Ed25519** (RFC 8032), through the established
/// `cryptography` package. No cryptographic primitive is implemented in
/// this project - this file is glue code around a vetted library.
///
/// Why Ed25519 instead of the plan's RSA/ECDSA suggestion? Measured on
/// this project's machine, not guessed:
///
/// | option | verdict |
/// |---|---|
/// | ECDSA P-256 via `cryptography` | `UnimplementedError` on key generation outside browser/native backends - unusable pure Dart |
/// | RSA-2048 | key generation is far too slow for a phone; no keygen in the package at all |
/// | **Ed25519** | keygen ~56ms, sign ~10ms, verify ~7ms, 32B keys / 64B signatures (QR friendly), keys restorable from a 32-byte seed, and Node.js/Python verify the exact same bytes |
///
/// The last row is why Phase 6's backend can verify receipts with Node's
/// built-in `crypto` (see `backend/scripts/verify_receipt.js` and the
/// shared interop vector pinned in BOTH test suites).
class SignatureService {
  const SignatureService._();

  // The algorithm object is stateless; `Ed25519()` itself is a factory,
  // so it cannot be const - one shared instance is enough.
  static final Ed25519 _algorithm = Ed25519();

  /// Names under which key material is stored in the [SecureKeyStore].
  /// The seed IS the private key; the public key is safe to share.
  static const String privateKeySeedKey = 'offlinepay.ed25519.seed';
  static const String publicKeyKey = 'offlinepay.ed25519.public';

  /// Create a fresh signing identity. Returns base64-encoded material:
  /// the seed is PRIVATE (never leaves the device/keystore), the public
  /// key travels with every receipt.
  static Future<SigningKeyPair> generateKeyPair() async {
    final pair = await _algorithm.newKeyPair();
    final seed = await pair.extractPrivateKeyBytes();
    final publicKey = await pair.extractPublicKey();
    return SigningKeyPair(
      seedBase64: base64Encode(seed),
      publicKeyBase64: base64Encode(publicKey.bytes),
    );
  }

  /// Sign [message] (usually [canonicalPayload]) with the private key
  /// identified by [seedBase64]; returns a base64 signature.
  static Future<String> sign(
    String message, {
    required String seedBase64,
  }) async {
    final pair = await _algorithm.newKeyPairFromSeed(base64Decode(seedBase64));
    final signature =
        await _algorithm.sign(utf8.encode(message), keyPair: pair);
    return base64Encode(signature.bytes);
  }

  /// Verify a base64 [signatureBase64] over [message] against
  /// [publicKeyBase64].
  ///
  /// Fails CLOSED: malformed base64, wrong key types or any library error
  /// returns `false` instead of throwing - a broken receipt must never
  /// crash the receiver's app.
  static Future<bool> verify(
    String message, {
    required String signatureBase64,
    required String publicKeyBase64,
  }) async {
    try {
      final signature = Signature(
        base64Decode(signatureBase64),
        publicKey: SimplePublicKey(
          base64Decode(publicKeyBase64),
          type: KeyPairType.ed25519,
        ),
      );
      return await _algorithm.verify(utf8.encode(message), signature: signature);
    } catch (_) {
      return false;
    }
  }

  /// The exact bytes that get signed.
  ///
  /// This function MUST stay byte-identical on the payer, the receiver and
  /// (Phase 6) the backend - otherwise signatures cannot cross devices.
  /// The rules that make it deterministic:
  ///
  ///  * **fixed key order** - JSON object order is preserved by both Dart
  ///    (`jsonEncode`) and JavaScript (`JSON.stringify`)
  ///  * **integer amounts** - money becomes paise as an INT, because
  ///    binary floats print differently on different platforms
  ///  * **integer timestamps** - epoch milliseconds UTC, because Dart
  ///    prints microseconds while JS prints milliseconds
  ///  * **no lifecycle state** - `status` and the signature itself are NOT
  ///    covered: the signature authorizes the payment, not its later
  ///    CONFIRMED/REJECTED bookkeeping
  ///
  /// Known edge: exotic Unicode line separators (U+2028/9) inside the
  /// description could escape differently between platforms. Keep
  /// descriptions plain text (Phase 6 note for the sync endpoint).
  static String canonicalPayload(Transaction tx) {
    // Round to 2 decimals FIRST: toStringAsFixed turns 0.07 into '0.07',
    // and only then is the float multiplied - avoiding 0.07*100 = 7.0000001.
    final twoDecimals = double.parse(tx.amount.toStringAsFixed(2));
    return jsonEncode({
      'v': 1,
      'id': tx.transactionId,
      'type': tx.type.toString(),
      'sender': tx.senderId,
      'senderWallet': tx.senderWalletId,
      'receiver': tx.receiverId,
      'receiverWallet': tx.receiverWalletId,
      'amountPaise': (twoDecimals * 100).round(),
      'nonce': tx.nonce,
      'timestampMs': tx.timestamp.toUtc().millisecondsSinceEpoch,
      'description': tx.description,
    });
  }
}

/// A signing identity, base64-encoded. [seedBase64] is the private half.
class SigningKeyPair {
  const SigningKeyPair({
    required this.seedBase64,
    required this.publicKeyBase64,
  });

  final String seedBase64;
  final String publicKeyBase64;
}
