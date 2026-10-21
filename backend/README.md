# OfflinePay Backend

Backend server for OfflinePay - An offline-first digital payment prototype.

**⚠️ IMPORTANT: This uses SIMULATED money only. NOT connected to real banks or payment networks.**

## What's Implemented

- **Phase 1**: user creation, simulated balances, transfers, history
- **Phase 2**: QR payment-request generation and verification endpoints
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

> This is the *immediate* path used by demo scripts and the future Phase 6
> sync endpoint builds on the same checks. Offline payments in the app are
> NOT sent here in real time - they wait in the device's pending queue.

## Data Models

### User Schema
```javascript
{
  userId: String (unique),
  username: String (unique),
  name: String,
  walletId: String (unique),
  balance: Number,
  publicKey: String (for Phase 5),
  transactionPinHash: String (for Phase 4),
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
  senderPublicKey: String (for Phase 5),
  signature: String (for Phase 5),
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

## Development Roadmap

- [x] **Phase 1**: Basic wallet system
- [x] **Phase 2**: QR endpoints + replay protection (backend side)
- [x] **Phase 3**: Offline-first mobile app (backend unchanged)
- [ ] **Phase 4**: Transaction PIN security
- [ ] **Phase 5**: Cryptographic signatures
- [ ] **Phase 6**: Backend synchronization (upload/verify/reconcile endpoint)
- [ ] **Phase 7**: Double-spending protection (server-side arbitration)
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
│   │   └── qrController.js   # QR generate/verify/pay
│   ├── routes/
│   │   ├── userRoutes.js
│   │   ├── transactionRoutes.js
│   │   └── qrRoutes.js
│   └── server.js             # Express app entry point
├── scripts/
│   ├── demo-simple.js        # Phase 1 demonstration
│   ├── demo-phase1.js
│   └── demo-phase2.js        # QR flow demonstration
├── .env.example
├── .env
└── package.json
```

## Security Notes (for later phases)

- Transaction PINs will be hashed with bcrypt (Phase 4)
- Private keys will never be stored on the backend (Phase 5)
- Digital signatures will verify transaction authenticity (Phase 5)
- Double-spending protection via reconciliation (Phase 7)

## License

MIT - Educational Project
