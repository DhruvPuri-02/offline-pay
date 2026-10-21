# OfflinePay - Offline-First Design (Implemented, Phases 2-4)

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
| Payer claims "I never paid" after handing over a receipt | ❌ no | Phase 5 digital signatures |
| Receipt amount tampered between devices | ❌ no | Phase 5 signatures + Phase 6 server verification |
| Device reset / app reinstall resets local ledger | ❌ no | Phase 6 server is the authority after sync |
| Two devices with cloned wallets spend the same balance | ❌ no | Server-side reconciliation (Phase 6/7) |
| Backend down during sync | N/A | Requeue: transactions stay `PENDING_SYNC` |

**Honest summary:** the local rules stop the *accidental and casual* case
(the user spending the same offline balance twice on one device). Real
double-spend guarantees require the authoritative server to arbitrate at
sync time - which is Phase 6/7. This prototype does not have the same
guarantees as a banking system and must not be described as if it did.

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
| "bcrypt makes PINs strong" | ❌ bcrypt makes *verification* expensive and per-PIN salts defeat precomputation; it cannot make a 4-digit PIN high-entropy. Real authenticity weight arrives with Phase 5 signatures. |

---

## 7. Synchronization flow (partially implemented)

**Implemented today (Phase 3):**
- Transactions are created as `PENDING_SYNC` and persisted.
- `WalletProvider.pendingSyncTransactions` + `LocalDatabase.getPendingSyncTransactions()`
  expose the upload queue (ordered oldest-first, `SYNCING` included).
- `LocalDatabase.updateTransactionStatus(id, status, rejectionReason:)`
  is ready to persist the server's verdict.

**Planned (Phase 6):**

```
pendingSyncTransactions
      |  POST /api/sync/transactions      (endpoint to be built)
      v
backend verifies: signature (P5) -> nonce replay -> transactionId
      -> balance/conflict check
      |
      v  per transaction: CONFIRMED | REJECTED(reason) | CONFLICT
      |
device updates local rows and reconciles confirmed_balance
```

The backend already guarantees the pieces the sync endpoint will need:
unique `transactionId`, unique partial index on `nonce` (duplicate uploads
of the same payment return `409 DUPLICATE_NONCE` instead of double-crediting),
and balance checks on every credit/debit.

---

## 8. Testing

| Suite | What it proves |
|---|---|
| `test/balance_test.dart` | Three-balance maths; the spec's ₹400+₹400 double-spend case is refused |
| `test/local_database_test.dart` | Insert-twice is a no-op; nonce replay rejected; NULL nonces allowed; status persistence |
| `test/wallet_provider_test.dart` | First-run seeding, PENDING_SYNC creation, balance reservation, receipt idempotency, wrong-wallet rejection |
| `test/qr_message_test.dart` | Receipt round-trip; malformed QRs produce readable errors |
| `test/pin_service_test.dart` | Format rules; salted hashes (same PIN -> different hash); fail-closed on corrupt hashes |
| `test/wallet_provider_pin_test.dart` | Hash-only storage; PIN enforced inside `createOfflinePayment`; attempt counting; lockout incl. clock-driven expiry; change-PIN rules |
| `test/pin_authorization_screen_test.dart` | Setup vs verify modes, mismatch handling, locked-state UI (fake wallet, no SQLite in FakeAsync) |
| `test/widget_test.dart` | Home screen boots from SQLite alone and renders the balances |

Run: `cd mobile && flutter test` (57 tests, a few seconds).

Backend: `cd backend && npm test` (runs without MongoDB), or `npm start`
(now also runs without MongoDB via `mongodb-memory-server`).
