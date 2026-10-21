import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:offlinepay/models/transaction.dart';
import 'package:offlinepay/services/signature_service.dart';

/// Fixed cross-platform interop vector.
///
/// Regenerate with:  cd mobile && dart run tool/gen_interop_vector.dart
/// The exact same constants live in backend/test/signature_interop.test.js,
/// where Node's built-in crypto must verify them. If both suites pass,
/// a receipt signed by the Flutter app is provably checkable by the
/// Phase 6 backend - no "trust us", just bytes.
const interopSeedBase64 = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=';
const interopPublicKeyBase64 = 'A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg=';
const interopSignatureBase64 =
    'qHn4v9kRRu1g2hkjDTnUnVXM0GyjlwemUvtA5fiNcCXCovkbrPCPnrMm6favvpK11ywX2tpHdVrnB6c4fo/fBg==';
const interopCanonical =
    '{"v":1,"id":"TX_interop_0001","type":"OFFLINE_PAYMENT",'
    '"sender":"USER_alice","senderWallet":"WALLET_alice",'
    '"receiver":"USER_bob","receiverWallet":"WALLET_bob",'
    '"amountPaise":12550,"nonce":"nonce_interop_1",'
    '"timestampMs":1768473000123,"description":"Interop vector payment"}';

/// The fixture transaction that produces [interopCanonical].
Transaction interopFixture() => Transaction(
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

/// Fixture with overrides - reads like the tampering scenarios it models.
Transaction fixture({
  double amount = 125.50,
  String receiver = 'USER_bob',
  String? nonce = 'nonce_interop_1',
  String description = 'Interop vector payment',
  DateTime? timestamp,
}) =>
    Transaction(
      transactionId: 'TX_interop_0001',
      senderId: 'USER_alice',
      receiverId: receiver,
      senderWalletId: 'WALLET_alice',
      receiverWalletId: 'WALLET_bob',
      amount: amount,
      type: TransactionType.offlinePayment,
      status: TransactionStatus.pendingSync,
      description: description,
      nonce: nonce,
      timestamp: timestamp ?? DateTime.utc(2026, 1, 15, 10, 30, 0, 123),
    );

void main() {
  group('canonicalPayload (the bytes that get signed)', () {
    test('is deterministic and matches the shared interop vector', () {
      expect(SignatureService.canonicalPayload(interopFixture()),
          interopCanonical);
      // Building the same logical transaction twice -> identical bytes.
      expect(SignatureService.canonicalPayload(fixture()),
          SignatureService.canonicalPayload(fixture()));
    });

    test('money becomes integer paise (binary floats must not leak in)',
        () {
      expect(SignatureService.canonicalPayload(fixture(amount: 100.5)),
          contains('"amountPaise":10050'));
      expect(SignatureService.canonicalPayload(fixture(amount: 0.07)),
          contains('"amountPaise":7'));
      // The trap this avoids: 0.07 * 100 == 7.000000000000001 in floats.
      expect(0.07 * 100, isNot(7.0));
    });

    test('covers every payment fact an attacker might edit', () {
      final base = SignatureService.canonicalPayload(fixture());
      expect(SignatureService.canonicalPayload(fixture(amount: 999)), isNot(base));
      expect(
          SignatureService.canonicalPayload(fixture(receiver: 'USER_mallory')),
          isNot(base));
      expect(SignatureService.canonicalPayload(fixture(nonce: 'other')),
          isNot(base));
      expect(
          SignatureService.canonicalPayload(
              fixture(description: 'something else')),
          isNot(base));
      expect(
          SignatureService.canonicalPayload(
              fixture(timestamp: DateTime.utc(2027))),
          isNot(base));
    });

    test('does NOT cover lifecycle state (signature authorizes, not tracks)',
        () {
      final unsigned = interopFixture();
      final signedCopy = unsigned.signed(
        signature: interopSignatureBase64,
        senderPublicKey: interopPublicKeyBase64,
      );
      expect(SignatureService.canonicalPayload(signedCopy),
          SignatureService.canonicalPayload(unsigned));
    });
  });

  group('key pairs', () {
    test('are 32-byte halves and unique per generation', () async {
      final a = await SignatureService.generateKeyPair();
      final b = await SignatureService.generateKeyPair();

      expect(base64Length(a.seedBase64), 32);
      expect(base64Length(a.publicKeyBase64), 32);
      expect(a.seedBase64, isNot(b.seedBase64));
      expect(a.publicKeyBase64, isNot(b.publicKeyBase64));
    });
  });

  group('sign / verify', () {
    test('round trip on a fresh key', () async {
      final pair = await SignatureService.generateKeyPair();
      const message = 'pay Bob 100 rupees';

      final signature =
          await SignatureService.sign(message, seedBase64: pair.seedBase64);

      expect(
        await SignatureService.verify(
          message,
          signatureBase64: signature,
          publicKeyBase64: pair.publicKeyBase64,
        ),
        isTrue,
      );
    });

    test('the fixed interop vector verifies (Dart side of Node interop)',
        () async {
      expect(
        await SignatureService.verify(
          interopCanonical,
          signatureBase64: interopSignatureBase64,
          publicKeyBase64: interopPublicKeyBase64,
        ),
        isTrue,
      );
      // And it is reproducible from the fixed seed.
      expect(
        await SignatureService.sign(interopCanonical,
            seedBase64: interopSeedBase64),
        interopSignatureBase64,
      );
    });

    test('a tampered message fails', () async {
      final pair = await SignatureService.generateKeyPair();
      final signature = await SignatureService.sign('amount: 100',
          seedBase64: pair.seedBase64);

      expect(
        await SignatureService.verify(
          'amount: 100000', // the classic receipt edit
          signatureBase64: signature,
          publicKeyBase64: pair.publicKeyBase64,
        ),
        isFalse,
      );
    });

    test('the wrong public key fails', () async {
      final alice = await SignatureService.generateKeyPair();
      final mallory = await SignatureService.generateKeyPair();
      final signature = await SignatureService.sign('legit message',
          seedBase64: alice.seedBase64);

      expect(
        await SignatureService.verify(
          'legit message',
          signatureBase64: signature,
          publicKeyBase64: mallory.publicKeyBase64,
        ),
        isFalse,
      );
    });

    test('malformed input fails closed - never throws', () async {
      const message = 'anything';
      // Not base64 at all.
      expect(
        await SignatureService.verify(message,
            signatureBase64: '!!!', publicKeyBase64: '???'),
        isFalse,
      );
      // Valid base64, wrong lengths (truncated QR scan).
      expect(
        await SignatureService.verify(message,
            signatureBase64: 'AAAA', publicKeyBase64: 'AAAA'),
        isFalse,
      );
      // Empty everything.
      expect(
        await SignatureService.verify(message,
            signatureBase64: '', publicKeyBase64: ''),
        isFalse,
      );
    });
  });
}

int base64Length(String value) => base64Decode(value).length;
