# OfflinePay - Offline-First Design (Implemented, Phases 2-6)

This document describes **what the code actually does today**, not what is
planned. Planned work is marked clearly as such.

**⚠️ Simulated money only. Educational prototype - not a real payment system.**

---

## 1. The core rule

> The payment flow must never require the network. The backend is a
> *reconciler*, not a *dependency*.

Everything the app needs - identity, balance, ledger - lives in one SQLite
file on the device. The backend learns about offline payments only in
Phase 6, when the device next gets connectivity and uploads them.

---

## 2. Local database schema (SQLite)

Created in `mobile/lib/services/local_database.dart`:

```sql
-- One row: this device's wallet profile
CREATE TABLE wallet_profile (
  user_id           TEXT PRIMARY KEY,   -- USER_xxx
  username          TEXT NOT NULL,
  name              TEXT NOT NULL,
  wallet_id         TEXT NOT NULL UNIQUE,
  confirmed_balance REAL NOT NULL DEFAULT 0,  -- agrees with backend
  public_key        TEXT,               -- Phase 5
  created_at        TEXT NOT NULL
);

-- The ledger: every transaction this device has ever seen
CREATE TABLE transactions (
  transaction_id    TEXT PRIMARY KEY,   -- idempotency: duplicates ignored
  sender_id         TEXT NOT NULL,
  receiver_id       TEXT NOT NULL,
  sender_wallet_id  TEXT NOT NULL,
  receiver_wallet_id TEXT NOT NULL,
  amount            REAL NOT NULL,
  type              TEXT NOT NULL,      -- TOPUP | DIRECT_TRANSFER | OFFLINE_PAYMENT
  status            TEXT NOT NULL,      -- PENDING_SYNC | SYNCING | CONFIRMED | REJECTED | CONFLICT
  description       TEXT NOT NULL,
  nonce             TEXT,               -- replay protection
  sender_public_key TEXT,               -- Phase 5
  signature         TEXT,               -- Phase 5
  rejection_reason  TEXT,               -- why the backend refused (Phase 6)
  timestamp         TEXT NOT NULL
);

CREATE INDEX idx_transactions_time ON transactions (timestamp DESC);
CREATE UNIQUE INDEX idx_transactions_nonce
  ON transactions (nonce) WHERE nonce IS NOT NULL;
```

**Two deliberate design choices:**

1. `transaction_id` is the PRIMARY KEY, so `INSERT OR IGNORE` makes
   re-scanning the same receipt a no-op. Idempotency is enforced by the
   schema, not by application code that can be forgotten.
2. The nonce index is **partial** (`WHERE nonce IS NOT NULL`). A plain
   `UNIQUE` index would treat two `NULL` nonces as a collision and reject
   the second seeded topup - this exact bug was found and fixed during
   development on the backend side too.

---

## 3. The three balances

| Balance | Meaning |
|---|---|
| **confirmed** | Last value agreed with the backend. Stored in `wallet_profile.confirmed_balance`. |
| **pending outgoing** | Sum of *our* unsettled (`PENDING_SYNC`/`SYNCING`) payments. |
| **pending incoming** | Sum of *their* unsettled payments to us. |
| **available** | `confirmed - pending outgoing`. **This is what you can spend.** |

**Why incoming pending money is NOT spendable:** until the backend
reconciles, we cannot know a received offline payment will survive conflict
resolution (the payer may have spent the same money elsewhere while offline).
Counting it would let users spend an unconfirmed receipt - a double-spend.
This is intentionally conservative. Computation lives in
`mobile/lib/utils/balance.dart` so it is unit-tested in isolation.

---

## 4. QR message protocol

QR is only a transport for JSON. There are exactly two message types
(`mobile/lib/models/qr_message.dart`):

```
Type 1: PAYMENT_REQUEST      receiver -> payer
{ version, type, receiverId, receiverName, receiverWalletId,
  amount, description, nonce, timestamp, expiresAt }

Type 2: TRANSACTION_RECEIPT  payer -> receiver
{ version, type, transaction: { ...full transaction... } }
```

### Complete offline payment, no internet anywhere

```
Bob's device                              Alice's device
-------------                             -------------
Receive screen
 enter ₹100
 [Generate QR]  ── PAYMENT_REQUEST ──>  Scan screen
                                            reads QR
                                            checks local balance
                                            [Confirm]
                                            creates transaction
                                            status = PENDING_SYNC
                                            writes to SQLite
                     <── TRANSACTION_RECEIPT ──  [Show QR]
Scan incoming
 [Record Payment]
 writes to SQLite
 status = PENDING_SYNC

Both devices now hold matching ledger entries.
Neither contacted any server.
```

The request's `nonce` is reused as the transaction's `nonce`, which is what
links a receipt to its request and lets the backend detect replays later.

There is a second, payer-initiated path (manual **Pay** screen: recipient +
amount). Both paths call the same `WalletProvider.createOfflinePayment()`,
so the validation and ledger-writing logic exists exactly once.

---

## 5. Offline spending rules (double-spend prevention, honest version)

Implemented in `mobile/lib/utils/balance.dart` (`validateOfflinePayment`):

1. **Local balance reservation** - every unsettled outgoing payment
   immediately reduces `available`. Alice with ₹500 who pays ₹400 has
   ₹100 left, so a second ₹400 payment is refused.
2. **Per-transaction offline cap** - `WalletProvider.maxOfflineTransactionAmount`
   (₹500) bounds how much unverified debt one device can inject.
3. **Self-payment blocked**, non-positive amounts blocked.
4. **Idempotency** - duplicate transaction IDs/nonces are ignored locally
   and rejected server-side (partial unique index, HTTP 409 on the backend).

### What this does NOT prevent (read this part carefully)

| Attack / failure | Prevented now? | What would fix it |
|---|---|---|
| Same phone spends twice while offline | ✅ yes (local reservation) | - |
| Payer claims "I never paid" after handing over a receipt | 🟡 mitigated (Phase 5) | The receipt is signed; the payer's key cannot deny *these details*. Binding keys to people = Phase 6 public-key registration |
| Receipt amount tampered between devices | ✅ yes (Phase 5) | Signatures cover amount/receiver/nonce/description/timestamp; receiver + backend both refuse tampered receipts |
| Device reset / app reinstall resets local ledger | ❌ no | Phase 6 server is the authority after sync |
| Two devices with cloned wallets spend the same balance | ❌ no | Server-side arbitration over the Phase 6 sync channel (Phase 7) |
| Backend down during sync | N/A | Requeue: transactions stay `PENDING_SYNC` |

**Honest summary:** the local rules stop the *accidental and casual* case
(the user spending the same offline balance twice on one device). Real
double-spend guarantees require the authoritative server to arbitrate at
sync time - Phase 6 now provides the sync channel and verification, but
the balance arbitration itself is Phase 7. This prototype does not have
the same guarantees as a banking system and must not be described as if
it did.

---

## 6. Transaction PIN (Phase 4, implemented)

Implemented in `mobile/lib/services/pin_service.dart` +
`WalletProvider`; UI in `screens/pin_authorization_screen.dart` and
`screens/pin_settings_screen.dart`.

**What the PIN is for**: authorising OUTGOING payments on this device.
The app itself opens with no prompt - there is deliberately no login PIN.

**How it is enforced**: `createOfflinePayment()` verifies the PIN
*inside the operation that moves money* - after the balance checks, so
an impossible payment never consumes a PIN attempt, and before any
ledger write, so a failed attempt leaves no trace. No other code path
writes payments into the ledger, so nothing can bypass the check.

**Storage** (`wallet_profile` table, SQLite schema v2):
- `pin_hash` - a salted bcrypt hash (cost 10, the library default:
  ~80ms per verification measured on a desktop). The plaintext PIN is
  never written, logged, or sent anywhere.
- `pin_failed_attempts`, `pin_locked_until` - brute-force counters.

**Brute-force policy**: 5 failed attempts -> 30 seconds lockout. While
locked, even the CORRECT PIN is refused; after the cooldown the attempt
budget starts fresh. A success resets the counter. Counters live in
SQLite, so restarting the app does not help an attacker.

**Bootstrap**: on the very first payment the PIN screen is in setup
mode (create + confirm); from then on, every payment verifies it.
Changing the PIN (settings screen, key icon on the Home app bar)
requires the current PIN.

### Honest limitations of the PIN

| Claim | Reality |
|---|---|
| "Only the owner can pay" | ❌ The hash lives on the same device; anyone with root/malware could extract it and brute-force a 4-digit space offline. The PIN deters *casual* misuse of an unlocked phone, not a forensic attacker. |
| "5 attempts total" | ❌ 5 attempts per 30-second window (~5 guesses per ~30s). Rate-limiting makes guessing slow, not impossible. |
| "The backend knows my PIN" | ❌ by design. `User.transactionPinHash` on the backend stays `null` forever - syncing a PIN hash to a server only creates another copy to steal. |
| "bcrypt makes PINs strong" | ❌ bcrypt makes *verification* expensive and per-PIN salts defeat precomputation; it cannot make a 4-digit PIN high-entropy. Real authenticity weight arrives with Phase 5 signatures (now implemented, section 7). |

---

## 7. Transaction signatures (Phase 5, implemented)

Implemented in `mobile/lib/services/signature_service.dart` (app) with
the same rules mirrored in `backend/src/utils/transactionSignature.js`
(server side, used by Phase 6).

**What is signed**: `SignatureService.canonicalPayload(tx)` - the
payment facts (ids, wallets, integer paise, nonce, timestamp as epoch
milliseconds, description) in a fixed key order. NOT signed: `status`
and the signature itself (the signature authorizes the payment, not its
later bookkeeping).

**Flow**: `createOfflinePayment()` signs with the payer's Ed25519 key
after the PIN check. Keys are generated lazily on the first payment;
the 32-byte seed lives in the platform keystore (`flutter_secure_storage`
- Android Keystore / Windows Credential Manager / iOS Keychain), never
in plain SQLite. The receipt QR carries `signature` + `senderPublicKey`.
The receiver verifies on scan (red INVALID banner, recording blocked)
and again inside `recordIncomingPayment()`.

**Interop guarantee**: one signed vector, generated by Dart
(`mobile/tool/gen_interop_vector.dart`) and verified by BOTH
`mobile/test/signature_service_test.dart` AND `npm run test:phase5`
using Node's built-in crypto. If either suite drifts, the vector fails
on that side - bytes are bytes on every platform.

**Why Ed25519 and not the plan's RSA/ECDSA**: measured, not guessed.
Pure-Dart ECDSA P-256 key generation is `UnimplementedError` in the
standard `cryptography` package, and RSA keygen is phone-hostile slow.
Ed25519 gives ~56ms keygen / ~10ms sign / ~7ms verify, 32-byte keys and
64-byte signatures (QR friendly), clean restart recovery from a seed,
and universal interop. The plan's underlying requirement - use an
established library, never hand-roll crypto - is fully honored.

### Honest limitations of signatures

| Claim | Reality |
|---|---|
| "A receipt cannot be forged" | ❌ Anyone can generate a keypair and sign a *fake* receipt naming themselves as payer. What you DO get: the payer's own device cannot quietly alter or later deny the details it signed. |
| "We know WHO signed" | 🟡 TOFU only (Phase 6): the first sync binds userId -> key, later mismatches are refused. Without authentication the first claim on an identity stays unverified - see section 8. |
| "Tampering goes undetected" | ✅ prevented today: amount/receiver/nonce/description/timestamp edits all break the signature; the receiving app and the backend both refuse the receipt. |
| "The private key is unextractable" | ❌ The seed is encrypted at rest in the platform keystore - this defeats casual file reads and backups, NOT root/malware reading a running process. No prototype on a general-purpose OS can claim more. |
| "Unsigned receipts are rejected" | 🟡 ACCEPTED by design (pre-Phase-5 compatibility) but flagged as unverifiable in the UI. Only *invalid* signatures are hard-refused. |

---

## 8. Synchronization flow (Phase 6, implemented)

Implemented in `mobile/lib/services/sync_service.dart` (device) and
`backend/src/controllers/syncController.js` (server), with a real
end-to-end test over live HTTP in `backend/scripts/demo-phase6.js`
(`npm run test:phase6`).

**PUSH** (`POST /api/sync/push`): the device uploads its whole
`PENDING_SYNC` queue as one batch, declaring its userId + Ed25519 public
key. Per transaction the server checks, in order:

1. **shape** - required fields present, positive amount
2. **signature** - offline payments MUST be signed and verify (Phase 5)
3. **key binding** - if the sender's key is registered, this must be it
   (a self-consistent signature from an unregistered key is refused)
4. **nonce replay** - same nonce under a different id = REJECTED
5. **transactionId idempotency** - identical content = DUPLICATE (both
   devices push their copy of a payment; the second copy is ACKed, never
   double-credited); different content = CONFLICT (first copy kept)
6. **accept** - stored as CONFIRMED; server balances of known users move

Each verdict is applied locally: CONFIRMED/DUPLICATE -> the row becomes
CONFIRMED and the confirmed balance moves exactly ONCE (outgoing
debits, incoming credits - a `DUPLICATE` is how a push whose response
was lost gets booked on retry). REJECTED/CONFLICT -> status + reason
are stored and the local reservation is RELEASED: the server refused to
spend the money, so it is spendable again.

**PULL** (`POST /api/sync/pull`): returns every stored transaction
involving the user. The device merges each one: unknown ids are
inserted with the SERVER's status - this is how a payment received
while the phone was offline finally appears and becomes spendable -
while known unsettled ids are advanced to the server's status. Every
pulled transaction is re-verified locally (signature self-consistency)
before it may enter the ledger.

**Trust-on-first-use key registration**: the first push declaring a
public key for a user BINDS it (`User.publicKey`); later pushes signed
by a different key are refused for that sender. This completes Phase
5's trust story - but it is TOFU: there is no login, so the FIRST
claim on a userId wins.

### Honest limitations of sync

| Claim | Reality |
|---|---|
| "Only the real user can sync as that user" | ❌ There is NO authentication in this prototype. Anyone who can reach the server may push/pull as any userId. TOFU key binding helps after the first honest registration, but the first claim on an identity is unverified. Production needs authenticated channels (tokens/login) + PKI-bound keys. |
| "Double-spends are impossible now" | ❌ Phase 6 stores what passes signature/shape/replay checks WITHOUT checking the sender's balance - a device can push itself negative. Server-side balance arbitration is Phase 7. |
| "Sync is automatic" | 🟡 Manual: the Home screen's Sync button. A production app would hook connectivity events and app resume; the service itself is trigger-agnostic. |
| "The transport is secure" | ❌ Cleartext HTTP on the LAN. Signatures make TAMPERING detectable (push is verified server-side, pull re-verified device-side), but metadata, privacy and server identity are unprotected. Real deployments need TLS. |
| "Sync creates the server-side user" | 🟡 No. Sync records transactions and binds keys opportunistically; onboarding users with authoritative starting balances is Phase 7's job. |
| "A failed sync loses data" | ✅ No: push/pull failures leave the queue and balances untouched, and every step is idempotent - retrying is always safe. |

---

## 9. Testing

| Suite | What it proves |
|---|---|
| `test/balance_test.dart` | Three-balance maths; the spec's ₹400+₹400 double-spend case is refused |
| `test/local_database_test.dart` | Insert-twice is a no-op; nonce replay rejected; NULL nonces allowed; status persistence |
| `test/wallet_provider_test.dart` | First-run seeding, PENDING_SYNC creation, balance reservation, receipt idempotency, wrong-wallet rejection |
| `test/qr_message_test.dart` | Receipt round-trip; malformed QRs produce readable errors |
| `test/pin_service_test.dart` | Format rules; salted hashes (same PIN -> different hash); fail-closed on corrupt hashes |
| `test/wallet_provider_pin_test.dart` | Hash-only storage; PIN enforced inside `createOfflinePayment`; attempt counting; lockout incl. clock-driven expiry; change-PIN rules |
| `test/signature_service_test.dart` | Canonical-payload rules (paise, epoch-ms); sign/verify; tamper cases; fail-closed malformed input; the shared interop vector |
| `test/wallet_provider_signature_test.dart` | Signing inside payments; key lazily generated, survives restart; two-device flow with real payer/receiver wallets; tampered receipts refused, unsigned accepted |
| `test/pin_authorization_screen_test.dart` | Setup vs verify modes, mismatch handling, locked-state UI (fake wallet, no SQLite in FakeAsync) |
| `test/show_transaction_qr_screen_test.dart` | Receipt shows the signing key fingerprint / admits "not signed" |
| `test/sync_service_test.dart` | Push verdicts applied once (confirm/duplicate/reject/conflict), reservation release on rejection, pull merge (insert confirmed incoming, skip tampered, accept unsigned legacy, ignore foreign), failure leaves queue intact, full cycle balances |
| `test/widget_test.dart` | Home screen boots from SQLite alone and renders the balances |

Run: `cd mobile && flutter test` (92 tests, a few seconds).

Backend: `cd backend && npm test` (Phase 1 demo, runs without MongoDB),
`npm run test:phase2` (QR replay protection), `npm run test:phase5`
(Node verifying the Dart-signed interop vector), or `npm run test:phase6`
(the REAL sync endpoints over HTTP with real signatures - confirm,
idempotent duplicate, tampered/key-mismatch/replay rejection, conflict,
pull).
