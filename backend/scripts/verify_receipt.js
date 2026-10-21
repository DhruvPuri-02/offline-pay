// Manually verify an OfflinePay receipt (Phase 5 demo tool).
//
// Usage:
//   node scripts/verify_receipt.js receipt.json
//
// receipt.json may be either:
//   - the raw QR string shape  {"version":"1.0","type":"TRANSACTION_RECEIPT","transaction":{...}}
//   - a bare transaction object           {"transactionId": "...", ...}
//
// Typical demo: in the app, tap "Copy transaction JSON" on the payer's
// receipt screen, paste it into receipt.json, run this script - then
// edit the "amount" and watch the verdict flip to INVALID.

import fs from 'node:fs';
import { canonicalPayload, verifyReceiptSignature } from '../src/utils/transactionSignature.js';

const path = process.argv[2];
if (!path) {
  console.error('Usage: node scripts/verify_receipt.js <receipt.json>');
  process.exit(2);
}

let parsed;
try {
  parsed = JSON.parse(fs.readFileSync(path, 'utf8'));
} catch (error) {
  console.error(`Could not read JSON from ${path}: ${error.message}`);
  process.exit(2);
}

const tx = parsed.transaction ?? parsed;

console.log('Canonical payload (the signed bytes):');
console.log(canonicalPayload(tx));
console.log();

const verdict = verifyReceiptSignature(tx);
if (verdict === true) {
  console.log('VERDICT: VALID - signature matches these payment details.');
  console.log(`  payer key: ${(tx.senderPublicKey ?? '').slice(0, 8)}...`);
  process.exit(0);
} else if (verdict === null) {
  console.log('VERDICT: UNSIGNED - no signature present (older app version).');
  process.exit(0);
} else {
  console.log('VERDICT: INVALID - tampered, forged, or malformed signature.');
  process.exit(1);
}
