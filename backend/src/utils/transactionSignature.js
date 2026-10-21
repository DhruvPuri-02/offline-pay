// Phase 5: receipt signature verification - the BACKEND half.
//
// Mirrors mobile/lib/services/signature_service.dart. The canonical
// payload rules must stay byte-identical between Dart and JavaScript,
// otherwise signatures cannot cross from the app to this server. The
// shared interop vector is pinned in BOTH test suites:
//   mobile/test/signature_service_test.dart
//   backend/scripts/test-signature.js
//
// Phase 6's sync endpoint will call verifyReceiptSignature() before it
// trusts any uploaded transaction.

import crypto from 'node:crypto';

// Raw 32-byte Ed25519 public keys need this fixed SPKI/DER prefix to be
// usable by node:crypto (the standard ASN.1 wrapper for Ed25519 keys).
// It is a CONSTANT defined by RFC 8410 - not our invention.
const ED25519_SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');

/**
 * The exact bytes that were signed. Keep this in lockstep with
 * SignatureService.canonicalPayload() in Dart:
 *   - fixed key order (JSON.stringify preserves insertion order, just
 *     like Dart's jsonEncode preserves Map order)
 *   - amount as INTEGER paise (binary floats print differently per
 *     platform: 0.07 * 100 === 7.000000000000001 here, too)
 *   - timestamp as INTEGER epoch milliseconds UTC (Dart prints
 *     microseconds, JS prints milliseconds - integers cannot diverge)
 *   - status/signature NOT covered: the signature authorizes the
 *     payment, not its later bookkeeping
 */
export function canonicalPayload(tx) {
  const amountPaise = Math.round(parseFloat(Number(tx.amount).toFixed(2)) * 100);
  const timestampMs = new Date(tx.timestamp).getTime();

  return JSON.stringify({
    v: 1,
    id: tx.transactionId,
    type: tx.type,
    sender: tx.senderId,
    senderWallet: tx.senderWalletId,
    receiver: tx.receiverId,
    receiverWallet: tx.receiverWalletId,
    amountPaise,
    nonce: tx.nonce ?? null,
    timestampMs,
    description: tx.description,
  });
}

/**
 * Verify a transaction's embedded signature (tx.signature +
 * tx.senderPublicKey, base64) over its canonical payload.
 *
 * Returns:
 *   true  - signature valid for these exact payment details
 *   false - tampered, forged, malformed, or wrong key (fails CLOSED)
 *   null  - receipt carries no signature at all (legacy, unsigned)
 */
export function verifyReceiptSignature(tx) {
  if (!tx.signature && !tx.senderPublicKey) return null;
  if (!tx.signature || !tx.senderPublicKey) return false;

  try {
    const key = crypto.createPublicKey({
      key: Buffer.concat([
        ED25519_SPKI_PREFIX,
        Buffer.from(tx.senderPublicKey, 'base64'),
      ]),
      format: 'der',
      type: 'spki',
    });
    return crypto.verify(
      null, // Ed25519 signs the raw message; no pre-hash algorithm arg
      Buffer.from(canonicalPayload(tx), 'utf8'),
      key,
      Buffer.from(tx.signature, 'base64'),
    );
  } catch (_) {
    return false; // malformed key/signature bytes must never crash a request
  }
}
