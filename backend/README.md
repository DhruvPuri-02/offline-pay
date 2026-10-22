# OfflinePay Backend

Backend server for OfflinePay - An offline-first digital payment prototype.

**⚠️ IMPORTANT: This uses SIMULATED money only. NOT connected to real banks or payment networks.**

## What's Implemented

- **Phase 1**: user creation, simulated balances, transfers, history
- **Phase 2**: QR payment-request generation and verification endpoints
- **Phase 5 (backend half)**: Ed25519 receipt verification
  (`src/utils/transactionSignature.js`) proven against the app with a
  shared signed interop vector (`npm run test:phase5`)
- **Phase 6**: offline sync - `POST /api/sync/push` (batch upload with
  per-transaction verdicts: signature + key binding + replay + idempotent
  dedupe) and `POST /api/sync/pull`; real end-to-end test in
  `npm run test:phase6`
- **Phase 7**: balance arbitration - the four push gates (type / offline
  cap / sender registered / balance), TOFU account onboarding with a
  server-decided grant + escrow, and the post-batch `balance` the app
  uses to self-correct; clone double-spend proven in
  `npm run test:phase7`
- **Replay protection**: duplicate-nonce uploads are rejected with
  `409 DUPLICATE_NONCE` (database-enforced, race-safe)
- **Zero-install database**: runs against an in-memory MongoDB when no
  `MONGODB_URI` is configured

## Prerequisites

- Node.js 18+ and npm
- MongoDB is **optional** (see "Running the Server")

## Installation

```bash
cd backend
npm install
```

## Configuration

Copy `.env.example` to `.env`:

```bash
cp .env.example .env
```

Edit `.env` if needed:

```env
PORT=5000
# Leave empty to auto-start an in-memory MongoDB (data lost on restart).
MONGODB_URI=
NODE_ENV=development
MAX_OFFLINE_TRANSACTION_LIMIT=500
```

## Running the Server

### Option 1: Zero setup (in-memory database)

```bash
npm start
```

With `MONGODB_URI` empty (the default), `mongodb-memory-server` downloads
and starts a throwaway MongoDB automatically. Perfect for development and
demos; data disappears when the server stops.

### Option 2: With a real MongoDB (persistent data)

```bash
# set MONGODB_URI=mongodb://127.0.0.1:27017/offlinepay in backend/.env
# Windows service: net start MongoDB
# Or manually:     mongod --dbpath ./data/db
npm start
```

### Option 3: Demo scripts (no server, no MongoDB)

```bash
npm test            # Phase 1 wallet demo
npm run test:phase2 # QR flow demo
npm run test:phase5 # Node verifies the Dart-signed interop vector
```

> **PowerShell:** if `npm` is blocked by execution policy, use `npm.cmd`.

## API Endpoints

### Health Check
```
GET /
```

### User Management

**Create User**
```
POST /api/users
Content-Type: application/json

{
  "username": "alice",
  "name": "Alice Kumar",
  "initialBalance": 1000
}
```

**Get All Users**
```
GET /api/users
```

**Get User by ID**
```
GET /api/users/:id
```
(`:id` can be `userId` or `walletId`)

**Add Simulated Balance**
```
POST /api/users/:id/topup
Content-Type: application/json

{
  "amount": 500
}
```

### Transactions

**Create Transfer**
```
POST /api/transactions/transfer
Content-Type: application/json

{
  "senderId": "USER_abc123",
  "receiverId": "USER_xyz789",
  "amount": 100,
  "description": "Payment for goods"
}
```

**Get User Transaction History**
```
GET /api/transactions/user/:id?limit=50&offset=0
```

**Get Transaction by ID**
```
GET /api/transactions/:transactionId
```

### QR Payments (Phase 2)

**Generate a payment request QR**
```
POST /api/qr/generate/:id
Content-Type: application/json

{ "amount": 100, "description": "Chai" }
```
`:id` is the receiver's `userId` or `walletId`. Returns the JSON payload
to render as a QR code (includes a one-time `nonce`, expires in 5 minutes).

> Note: the mobile app generates this payload **locally and offline**;
> this endpoint exists for server-driven/CLI flows.

**Verify a scanned payment request**
```
POST /api/qr/verify
Content-Type: application/json

{ "qrString": "<the scanned JSON>" }
```
Checks format, required fields, expiry, receiver existence, and whether
the nonce was already used.

**Process a payment (online path)**
```
POST /api/qr/pay
Content-Type: application/json

{
  "senderId": "USER_...", "receiverId": "USER_...",
  "receiverWalletId": "WALLET_...", "amount": 100,
  "description": "Chai", "nonce": "...", "timestamp": "..."
}
```
Responses:
- `201` payment accepted, balances updated
- `409 { "rejectionReason": "DUPLICATE_NONCE" }` - the same nonce was
  already processed. Enforced by a **unique partial index** on
  `transactions.nonce`, so even two concurrent uploads of the same
  transaction cannot double-credit the receiver (a pre-check alone would
  race).
- `400` insufficient balance / validation failure

> This is the *immediate* path used by demo scripts. The Phase 6 sync
> endpoint below builds on the same checks; offline payments in the app are
> NOT sent here in real time - they wait in the device's pending queue.

### Offline Sync (Phases 6-7)

**POST /api/sync/push** - batch upload of a device's PENDING_SYNC queue
```
body: { userId?, publicKey?, transactions: [ transaction, ... ] }
200:  { data: { registration, results: [
        { transactionId, outcome, serverStatus, reason, code }
      ], balance, serverTime } }
```
Per transaction, checked in order: shape -> signature (offline payments
must be Ed25519-signed) -> registered-key binding (TOFU: first push
binds `User.publicKey`; later mismatches refused) -> nonce replay ->
transactionId idempotency -> **Phase 7 gates**: type (only
`OFFLINE_PAYMENT` may be pushed - a client TOPUP would print money) ->
offline cap (amount <= 500, mirrored from the app - the client is
modifiable) -> sender must be registered -> **balance gate**
(`amount <= balance`, against the running balance so a batch debits in
order).

**Onboarding**: a first push from an unknown `userId` creates the
account with a SERVER-decided 500 grant plus escrow (confirmed payments
already waiting for that receiver), reported as
`registration: 'created'`. Clients cannot declare their own opening
balance, and no welcome transaction row is written - the device already
has its local seed one.

Outcomes:
- `CONFIRMED` - stored, sender debited, receiver credited (an unknown
  receiver's credit is escrowed until THEIR onboarding)
- `DUPLICATE` - identical copy already stored (both devices push their
  copy of a payment; ACKed, never double-credited)
- `CONFLICT` - same transactionId, different content: first copy kept
- `REJECTED` - human `reason` plus stable `code`: `MALFORMED`,
  `UNSIGNED`, `INVALID_SIGNATURE`, `KEY_MISMATCH`, `NONCE_REPLAY`,
  `NOT_OFFLINE_PAYMENT`, `OVER_LIMIT`, `SENDER_NOT_REGISTERED`,
  `INSUFFICIENT_BALANCE`

`data.balance` is the pushing user's authoritative balance AFTER the
batch (null when no userId was claimed). The app adopts it locally if,
and only if, it sees an `INSUFFICIENT_BALANCE` refusal - a cloned
device's local figure was a fantasy and would fail every later push.

One bad transaction never hides the fate of the others in the batch.

**POST /api/sync/pull** - everything stored about a user
```
body: { userId, since? }          // since = ISO timestamp (incremental)
200:  { data: { transactions: [...], serverTime } }
```
Returns payments the OTHER device uploaded while this one was offline,
plus statuses. Optional `since` for cheap incremental syncs.

> Honest limits: no authentication (anyone can claim any userId - TOFU
> first-claim-wins: account, grant and key alike), and the balance gate
> is load-compare-save rather than one atomic database operation (two
> truly SIMULTANEOUS pushes could race; the app syncs one queue at a
> time, production would use atomic conditional decrements). Both are
> documented in docs/OFFLINE_FIRST.md section 8. Transport is cleartext
> HTTP on the LAN.

## Data Models

### User Schema
```javascript
{
  userId: String (unique),
  username: String (unique),
  name: String,
  walletId: String (unique),
  balance: Number,
  publicKey: String (set at first sync - Phase 6/7 TOFU),
  transactionPinHash: String (stays null by design - see Security Notes),
  createdAt: Date,
  updatedAt: Date
}
```

### Transaction Schema
```javascript
{
  transactionId: String (unique),        // PRIMARY dedupe key
  senderId: String,
  receiverId: String,
  senderWalletId: String,
  receiverWalletId: String,
  amount: Number,
  type: 'TOPUP' | 'DIRECT_TRANSFER' | 'OFFLINE_PAYMENT',
  status: 'PENDING_SYNC' | 'SYNCING' | 'CONFIRMED' | 'REJECTED' | 'CONFLICT',
  description: String,
  nonce: String (unique, partial index), // replay protection: only
                                         // non-null string nonces are
                                         // indexed, so seeded topups with
                                         // nonce: null don't collide
  senderPublicKey: String (from Phase 5 receipts),
  signature: String (Ed25519, verified before any upload is trusted),
  rejectionReason: String,
  timestamp: Date
}
```

## Example Usage

Using curl:

```bash
# Create Alice
curl -X POST http://localhost:5000/api/users \
  -H "Content-Type: application/json" \
  -d '{"username":"alice","name":"Alice Kumar","initialBalance":500}'

# Create Bob
curl -X POST http://localhost:5000/api/users \
  -H "Content-Type: application/json" \
  -d '{"username":"bob","name":"Bob Merchant","initialBalance":1000}'

# Alice pays Bob ₹100
curl -X POST http://localhost:5000/api/transactions/transfer \
  -H "Content-Type: application/json" \
  -d '{
    "senderId":"USER_<alice_id>",
    "receiverId":"USER_<bob_id>",
    "amount":100,
    "description":"Payment for goods"
  }'

# Get Alice's transaction history
curl http://localhost:5000/api/transactions/user/USER_<alice_id>
```

## Testing

Run the Phase 1 demo:
```bash
npm test
```

This creates sample users (Alice, Bob, Charlie) and demonstrates transfers between them.

Verify a receipt signature (Phase 5 interop):
```bash
npm run test:phase5
npm run test:phase2
node scripts/verify_receipt.js receipt.json   # paste a receipt from the app
```

## Development Roadmap

- [x] **Phase 1**: Basic wallet system
- [x] **Phase 2**: QR endpoints + replay protection (backend side)
- [x] **Phase 3**: Offline-first mobile app (backend unchanged)
- [x] **Phase 4**: Transaction PIN security (app-side only; PIN never syncs)
- [x] **Phase 5**: Cryptographic signatures (verifier + interop vector)
- [x] **Phase 6**: Backend synchronization (push/pull + TOFU key registration)
- [x] **Phase 7**: Double-spending protection (server-side balance arbitration + onboarding)
- [ ] **Phase 8**: Advanced communication (Bluetooth/NFC)

## Project Structure

```
backend/
├── src/
│   ├── config/
│   │   └── database.js       # MongoDB or in-memory (mongodb-memory-server)
│   ├── models/
│   │   ├── User.js           # User/wallet schema
│   │   └── Transaction.js    # Transaction schema + unique nonce index
│   ├── controllers/
│   │   ├── userController.js
│   │   ├── transactionController.js
│   │   ├── qrController.js   # QR generate/verify/pay
│   │   └── syncController.js # Phase 6: push verdicts + pull merge
│   ├── utils/
│   │   └── transactionSignature.js  # Phase 5: canonical payload + Ed25519 verify
│   ├── routes/
│   │   ├── userRoutes.js
│   │   ├── transactionRoutes.js
│   │   ├── qrRoutes.js
│   │   └── syncRoutes.js     # POST /api/sync/push, /pull
│   ├── app.js                # Express app (importable by tests/scripts)
│   └── server.js             # entry point: app + listen
├── scripts/
│   ├── demo-simple.js        # Phase 1 demonstration
│   ├── demo-phase1.js
│   ├── demo-phase2.js        # QR flow demonstration
│   ├── test-signature.js     # Phase 5: Dart<->Node interop vector
│   ├── verify_receipt.js     # Phase 5: verify a receipt JSON by hand
│   ├── demo-phase6.js        # Phase 6: REAL sync endpoints over HTTP
│   └── demo-phase7.js        # Phase 7: balance arbitration over HTTP
├── .env.example
├── .env
└── package.json
```

## Security Notes (for later phases)

- Transaction PINs are hashed with bcrypt on the DEVICE (Phase 4).
  `User.transactionPinHash` stays `null` forever on purpose: a PIN hash
  is an offline-crackable secret, so it never leaves the phone.
- Private keys never touch the backend (Phase 5): only the 32-byte
  Ed25519 PUBLIC key travels with a receipt; the seed stays in the
  device keystore.
- Receipts are verified with `src/utils/transactionSignature.js`
  (Node's built-in crypto) - the exact rules mirrored from the app's
  `SignatureService.canonicalPayload`, pinned by the shared interop
  vector in `scripts/test-signature.js`.
- Sync verifies everything it stores (Phase 6): shape, signature,
  registered-key binding (TOFU: first push binds userId -> public key,
  later mismatches refused), nonce replay, and transactionId idempotency.
- Sync ARBITRATES every spend (Phase 7): only offline payments within
  the ₹500 cap from a registered sender, against the sender's
  authoritative balance - a cloned wallet's twin gets
  `INSUFFICIENT_BALANCE`, and onboarding grants are server-decided so a
  client cannot declare itself rich. Known honest gap: the gate is
  load-compare-save, not one atomic DB operation (see section 8 of
  docs/OFFLINE_FIRST.md), and there is still no authentication.
- Double-spending protection via server-side balance arbitration
  (Phase 7) - DONE; Phase 8 (Bluetooth/NFC transport) remains.

## License

MIT - Educational Project
