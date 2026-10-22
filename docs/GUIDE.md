# OfflinePay Project Documentation

## Project Overview

**OfflinePay** is an offline-first digital payment prototype designed as a college/educational project. It demonstrates how digital payments could work between devices without internet connectivity, then synchronize with a backend when connection is restored.

**⚠️ CRITICAL: This project uses SIMULATED money only. It is NOT connected to real banks, real money, or real payment networks.**

## Core Concept

Two users can transfer simulated money while both devices are offline:

```
Alice (₹500)  ──[QR Code]──>  Bob (Merchant)
    ↓                              ↓
₹400 balance                   +₹100 received
    ↓                              ↓
[Pending Sync]  ←──[Internet]──→  [Backend]
    ↓                              ↓
[Confirmed]                    [Confirmed]
```

## Technology Stack

### Mobile App
- **Framework**: Flutter
- **Language**: Dart
- **Local Storage**: SQLite or Hive
- **Communication**: QR codes (Phase 2), Bluetooth/NFC (Phase 8)

### Backend
- **Runtime**: Node.js
- **Framework**: Express.js
- **Database**: MongoDB
- **Libraries**: bcrypt, nanoid, mongoose

### Security (Later Phases)
- PIN hashing (bcrypt)
- Public/private key cryptography
- Digital signatures
- Transaction nonces

## Development Phases

### ✅ Phase 1: Basic Wallet (COMPLETED)
**Goal**: Create foundational user and wallet system

**Features**:
- User creation with unique IDs
- Simulated wallet balances
- Basic transaction recording
- Transaction history
- REST API endpoints

**Status**: Backend implemented and tested

### ✅ Phase 2: QR Payment (COMPLETED)
**Goal**: Enable payments via QR codes

**Implemented**:
- Payment-request QR generation on the receiver's device (Receive screen)
- QR scanning via camera (`mobile_scanner`) with a paste-JSON fallback
- Payment confirmation screen with balance preview
- Transaction created locally with status `PENDING_SYNC`
- Receipt QR handed back so the receiver can record the incoming payment
- Two message types defined in `mobile/lib/models/qr_message.dart`
  (`PAYMENT_REQUEST`, `TRANSACTION_RECEIPT`)

**See**: `docs/OFFLINE_FIRST.md` section 4 for the full message flow.

### ✅ Phase 3: Offline Mode (COMPLETED)
**Goal**: Remove internet dependency

**Implemented**:
- SQLite wallet + ledger (`mobile/lib/services/local_database.dart`)
- App boots from local storage before the first frame - no network calls
  in the payment path
- Pending-sync queue exposed (`pendingSyncTransactions`) with status
  persistence helpers for Phase 6
- Offline balance calculation with the three-balance split
  (available / confirmed / pending) in `mobile/lib/utils/balance.dart`
- First-half of double-spend controls: local balance reservation and a
  per-transaction offline cap (the server-side half arrived in Phase 7)

**Key design choice**: incoming pending payments do NOT raise the available
balance - see `docs/OFFLINE_FIRST.md` section 5 for why.

### ✅ Phase 4: Transaction PIN
**Goal**: Secure payment authorization

**What was built**:
- Device-local transaction PIN (NOT a login PIN - the app opens with no
  prompt, spec section 5)
- Setup flow on the very first payment (create + confirm), change flow
  in the settings screen (key icon on the Home app bar, requires the
  current PIN)
- Verification happens **inside** `createOfflinePayment()` - after the
  balance checks (an impossible payment never burns an attempt) and
  before any ledger write (a failed attempt leaves no trace)
- Salted bcrypt hashing via the established `bcrypt` package; the
  plaintext PIN is never stored, logged, or sent anywhere
- 5 failed attempts -> 30 second lockout; while locked even the correct
  PIN is refused; counters persist in SQLite across restarts
- SQLite schema v2 migration adds `pin_hash`, `pin_failed_attempts`,
  `pin_locked_until` to `wallet_profile`

**Important**: PIN is for PAYMENT authorization only, not app access.
The backend's `User.transactionPinHash` intentionally stays `null` -
a PIN hash never syncs to the server. Honest limitations are documented
in `docs/OFFLINE_FIRST.md` section 6.

### ✅ Phase 5: Cryptographic Security
**Goal**: Prevent transaction tampering

**What was built**:
- Every payment is signed (Ed25519, RFC 8032) with the payer's private
  key over a **canonical payload**: fixed key order, amounts as integer
  paise, timestamps as integer epoch-milliseconds - so the signed bytes
  are identical on any platform
- Signing happens inside `createOfflinePayment()` (after the PIN check);
  the receipt QR carries `signature` + `senderPublicKey`
- The receiver's Scan screen **verifies on sight**: a tampered
  amount/receiver/description shows a red INVALID banner and blocks
  recording; `recordIncomingPayment` re-verifies (defense in depth)
- Private key seed lives in the platform keystore
  (`flutter_secure_storage`: Android Keystore / Windows Credential
  Manager / iOS Keychain), never in plain SQLite; keys are generated
  lazily on the first payment and restored from the seed after restarts
- **Cross-platform interop**: the same signed vector is verified by
  Dart (`test/signature_service_test.dart`) AND Node's built-in crypto
  (`npm run test:phase5`) - Phase 6's backend can check any receipt.
  `scripts/verify_receipt.js` verifies a copied receipt JSON by hand

**Algorithm choice (a documented deviation from the plan)**: the plan
suggested RSA/ECDSA. Measured instead of guessed: ECDSA P-256 in the
standard `cryptography` package throws `UnimplementedError` for pure-Dart
key generation, and RSA keygen is far too slow for a phone. Ed25519:
keygen ~56ms, sign ~10ms, verify ~7ms, 32-byte keys / 64-byte signatures
(QR friendly), keys restorable from a seed, and first-class Node/Python
interop. Same requirements, better engineering - the underlying rule
(use established libraries, never hand-roll crypto) is fully honored.

**Important**: signatures prove "the holder of this key authorized these
exact details". Binding keys to identities happens in Phase 6: the first
sync registers the device's public key server-side (trust-on-first-use),
after which receipts signed by any OTHER key are refused for that sender -
documented honestly in `docs/OFFLINE_FIRST.md` sections 7 and 8.

### ✅ Phase 6: Synchronization
**Goal**: Reconcile offline transactions with backend

**What was built**:
- `POST /api/sync/push`: batch upload of the `PENDING_SYNC` queue. The
  server checks shape -> signature (Phase 5) -> registered-key binding
  -> nonce replay -> transactionId idempotency, and answers each
  transaction individually: CONFIRMED / DUPLICATE / CONFLICT / REJECTED
- `POST /api/sync/pull`: everything the server knows about this user -
  payments the OTHER device uploaded while we were offline, plus statuses
- **Idempotent by design**: identical re-pushes are ACKed (never
  double-credited); identical content under the same id = DUPLICATE,
  different content = CONFLICT (first copy wins); same nonce under a new
  id = replay rejection
- **Local application**: confirmed rows move the confirmed balance exactly
  once (outgoing debits, incoming credits); rejected/conflicted rows
  RELEASE their reservation; pull inserts confirmed incoming payments so
  money received offline becomes spendable
- **Trust-on-first-use key registration** completes Phase 5: first push
  binds userId -> public key, later mismatches are refused for that sender
- Manual **Sync** button on Home with queue count + last sync verdict;
  failures leave the queue untouched (offline-first contract)

**Honest scope**: Phase 6 by itself did not arbitrate balances (a device
could push itself negative) - that gap is closed by Phase 7 below.
Still open even now: no authentication (TOFU first-claim-wins) and
cleartext HTTP. See `docs/OFFLINE_FIRST.md` section 8.

**Transaction Status Flow**:
```
PENDING_SYNC → SYNCING → CONFIRMED
                      ↓
                   REJECTED
                      ↓
                   CONFLICT
```

### ✅ Phase 7: Double-Spending Protection
**Goal**: Prevent spending the same money twice - authoritatively, at sync

**The Challenge**:
```
Alice has ₹500

While offline:
- Pays Bob ₹400
- Pays Charlie ₹400

How to detect and prevent this?
```

**How this project answers it - in layers**:

*On one device (Phase 3, instantly, offline):* balance reservation -
Bob's ₹400 is subtracted from `available` the moment the payment is
created, so Charlie's ₹400 is refused before it ever exists. Plus the
₹500 per-transaction offline cap.

*Across cloned devices (Phase 7, authoritative, at sync):* two devices
claiming the same userId share ONE server balance.
`POST /api/sync/push` runs every spend through four gates in order:

1. **type** - offline payments only (a client-pushed TOPUP would print money)
2. **offline limit** - the ₹500 cap again, server-side (the client is modifiable)
3. **sender registered** - a valid signature from an unknown account debits nothing
4. **balance** - `amount <= balance` against the running balance

The first spend wins; the twin's payment is `REJECTED` with code
`INSUFFICIENT_BALANCE`, and its app adopts the server's balance instead
of its own fantasy number (the push response carries the authoritative
`balance` after every batch).

**What else Phase 7 built**:
- **Server-side onboarding**: a first push from an unknown userId
  creates the account with a SERVER-decided ₹500 grant plus escrowed
  incoming payments (received before the account existed). Clients
  cannot declare their own opening balance - "I am rich" would defeat
  the gate; no server-side welcome row is written (the device already
  has its local seed one - a second would double-count on pull)
- **`npm run test:phase7`** proves all of it over real HTTP with real
  signatures: affordable/unaffordable spends, batch-cumulative debits,
  no double-debit on duplicate re-push, the clone double-spend itself,
  all four gates, TOFU onboarding and escrow landing

**Honest scope**: the balance gate is load-compare-save, not one atomic
database operation - two truly SIMULTANEOUS pushes could race (the app
syncs serially; production would use atomic conditional decrements).
There is still no authentication, and arbitration happens only AT SYNC:
offline, a clone's spend is accepted locally until the next Sync runs.
See `docs/OFFLINE_FIRST.md` section 8.

**Solution approaches (all now implemented)**:
- Maximum offline transaction limit ✅ (device + server)
- Balance hold/reservation ✅ (device) + authoritative ledger (server)
- Server reconciliation on sync ✅ (Phase 6 push/pull)
- First-received-wins policy ✅ (first copy of a transactionId is kept;
  first spend of a shared balance wins)

### 🔄 Phase 8: Advanced Communication
**Goal**: Alternative device-to-device communication

**Features**:
- Bluetooth payment transfer
- NFC tap-to-pay
- Direct device pairing

**Note**: Only implement after Phases 1-7 work correctly

## Project Structure

```
offline-pay/
├── backend/
│   ├── src/
│   │   ├── config/
│   │   │   └── database.js
│   │   ├── models/
│   │   │   ├── User.js
│   │   │   └── Transaction.js
│   │   ├── controllers/
│   │   │   ├── userController.js
│   │   │   └── transactionController.js
│   │   ├── routes/
│   │   │   ├── userRoutes.js
│   │   │   └── transactionRoutes.js
│   │   └── server.js
│   ├── scripts/
│   │   └── demo-phase1.js
│   ├── .env.example
│   ├── package.json
│   └── README.md
├── mobile/
│   ├── lib/
│   │   ├── models/
│   │   ├── services/
│   │   ├── providers/
│   │   ├── screens/
│   │   ├── widgets/
│   │   ├── utils/
│   │   └── main.dart
│   ├── assets/
│   └── README.md
├── docs/
│   └── GUIDE.md (this file)
└── README.md
```

## Key Technical Concepts

### 1. Offline-First Architecture

The app must work WITHOUT internet:
- Local data storage (SQLite/Hive)
- Local transaction ledger
- Local balance calculation
- Queue for pending sync

Internet is only needed for:
- Initial setup
- Synchronization
- Reconciliation

### 2. Transaction Structure

```javascript
{
  transactionId: "TXN_xyz123",
  senderId: "USER_abc",
  receiverId: "USER_def",
  amount: 100,
  timestamp: "2026-10-09T12:00:00Z",
  nonce: "random_unique_string",
  senderPublicKey: "-----BEGIN PUBLIC KEY-----...",
  signature: "digital_signature_hash",
  status: "PENDING_SYNC"
}
```

### 3. Digital Signatures (Phase 5)

```
Transaction Data → Hash → Sign with Private Key → Signature

Verification:
Signature → Verify with Public Key → Valid/Invalid
```

**Why**: Prevents tampering with transaction amount or details

### 4. Synchronization Flow

> Implemented (Phase 6): `SyncService` + `POST /api/sync/push|pull`,
> including per-transaction verdicts, idempotent duplicates, conflict
> detection, TOFU key registration, and local status/balance application
> (`LocalDatabase.getPendingSyncTransactions`, `updateTransactionStatus`).

```
Device                              Backend
  │                                    │
  │─── Upload Pending Transactions ──→│
  │                                    │ Verify Signature
  │                                    │ Check Nonce
  │                                    │ Validate Balance
  │                                    │ Check Conflicts
  │                                    │
  │←─── Transaction Status ────────────│
  │     (CONFIRMED/REJECTED/CONFLICT)  │
  │                                    │
  │─── Update Local Status ────────────│
```

### 5. Double-Spending Prevention

**Problem**: Alice has ₹500 offline. She tries to pay Bob ₹500 AND Charlie ₹500.

**Solutions**:
1. **Offline Limit**: Maximum ₹500 total can be spent offline
2. **Sequence Numbers**: Transactions have sequential IDs
3. **Server Reconciliation**: First transaction wins, second rejected
4. **Balance Hold**: Reserve balance for pending transactions

## Security Principles

### DO:
- ✅ Hash PINs with bcrypt + salt
- ✅ Use established crypto libraries
- ✅ Keep private keys on device only
- ✅ Sign all offline transactions
- ✅ Verify signatures on backend
- ✅ Use unique transaction IDs
- ✅ Implement replay protection (nonces)

### DON'T:
- ❌ Store PINs in plaintext
- ❌ Implement custom crypto algorithms
- ❌ Send private keys to backend
- ❌ Trust client-provided balances
- ❌ Skip signature verification
- ❌ Allow duplicate transaction IDs
- ❌ Process same transaction twice

## Testing Strategy

### Phase 1 Testing
- Create users
- Check initial balances
- Perform transfers
- Verify transaction history
- Confirm balance updates

### Phase 2 Testing
- Generate QR codes
- Scan QR codes
- Confirm payment flow
- Verify offline storage

### Phase 7 Testing
- Push an affordable spend: CONFIRMED, balance moves (server + REST view)
- Push an unaffordable spend: REJECTED `INSUFFICIENT_BALANCE`, balance unchanged
- Batch of spends: debits run cumulatively, in order
- The CLONE: same userId + same copied key, spend refused, total capped
- Policy gates: client TOPUP refused, >₹500 refused, unknown sender refused
- Duplicate re-push: DUPLICATE, never a second debit
- Unknown device onboards (server-decided grant + escrow) and is then
  arbitrated like any other account
- Device side (`flutter test`): balance correction fires ONLY on
  `INSUFFICIENT_BALANCE`; other rejections and lone balance fields never
  override local bookkeeping

All of the above run in `npm run test:phase7` (18 checks, real HTTP) and
`test/sync_service_test.dart`.

## Important Notes

### This is NOT:
- ❌ A real payment system
- ❌ Connected to actual banks
- ❌ Using real money
- ❌ Production-ready code
- ❌ Cryptographically bulletproof

### This IS:
- ✅ An educational prototype
- ✅ A demonstration of concepts
- ✅ Using simulated money
- ✅ A learning project
- ✅ Showcasing offline-first architecture

## Limitations & Disclaimers

1. **Simulated Money Only**: All transactions use fake money
2. **Educational Purpose**: Not for actual financial transactions
3. **Security Limitations**: Simplified security model for learning
4. **Double-Spend Mitigation**: Uses practical controls, not blockchain-level guarantees
5. **Offline Constraints**: Limited offline transaction capacity
6. **No Bank Integration**: Completely isolated system

## Getting Started

See **[SETUP.md](../SETUP.md)** for verified, step-by-step instructions
including the two-device offline demo. Implementation details of the
current offline architecture are in **[OFFLINE_FIRST.md](OFFLINE_FIRST.md)**.

```bash
cd backend && npm install && npm start   # server (MongoDB optional)
cd mobile  && flutter pub get && flutter run
```

## Next Steps

1. ✅ Complete Phase 1 backend
2. ⏳ Install Flutter SDK
3. ⏳ Implement Phase 1 mobile UI
4. ⏳ Start Phase 2 QR implementation

## Resources

- Flutter: https://flutter.dev
- MongoDB: https://www.mongodb.com
- Express.js: https://expressjs.com
- Cryptography basics: https://crypto.stanford.edu

---

**Created**: October 2026  
**License**: MIT (Educational)  
**Warning**: SIMULATED MONEY ONLY - NOT FOR REAL TRANSACTIONS
