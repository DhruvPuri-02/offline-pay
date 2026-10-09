# OfflinePay Backend

Backend server for OfflinePay - An offline-first digital payment prototype.

**⚠️ IMPORTANT: This uses SIMULATED money only. NOT connected to real banks or payment networks.**

## Phase 1: Basic Wallet System ✅

This phase implements:
- User creation with unique IDs
- Wallet system with simulated balances
- Basic transaction recording
- Transaction history tracking
- Balance management

## Prerequisites

- Node.js 18+ and npm
- MongoDB (or use the built-in memory server for testing)

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
MONGODB_URI=mongodb://127.0.0.1:27017/offlinepay
NODE_ENV=development
MAX_OFFLINE_TRANSACTION_LIMIT=500
```

## Running the Server

### Option 1: With MongoDB installed

Start MongoDB first:
```bash
# Windows
net start MongoDB

# Or manually
mongod --dbpath ./data/db
```

Then start the server:
```bash
npm start
```

### Option 2: Demo mode (no MongoDB needed)

Run the Phase 1 demo with in-memory database:
```bash
npm test
```

This will create sample users and transactions to demonstrate the wallet system.

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
  transactionId: String (unique),
  senderId: String,
  receiverId: String,
  senderWalletId: String,
  receiverWalletId: String,
  amount: Number,
  type: 'TOPUP' | 'DIRECT_TRANSFER' | 'OFFLINE_PAYMENT',
  status: 'PENDING_SYNC' | 'SYNCING' | 'CONFIRMED' | 'REJECTED' | 'CONFLICT',
  description: String,
  nonce: String (for Phase 5),
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

- [x] **Phase 1**: Basic wallet system (Current)
- [ ] **Phase 2**: QR code payments
- [ ] **Phase 3**: Offline-first architecture
- [ ] **Phase 4**: Transaction PIN security
- [ ] **Phase 5**: Cryptographic signatures
- [ ] **Phase 6**: Backend synchronization
- [ ] **Phase 7**: Double-spending protection
- [ ] **Phase 8**: Advanced communication (Bluetooth/NFC)

## Project Structure

```
backend/
├── src/
│   ├── config/
│   │   └── database.js       # MongoDB connection
│   ├── models/
│   │   ├── User.js           # User/wallet schema
│   │   └── Transaction.js    # Transaction schema
│   ├── controllers/
│   │   ├── userController.js
│   │   └── transactionController.js
│   ├── routes/
│   │   ├── userRoutes.js
│   │   └── transactionRoutes.js
│   └── server.js             # Express app entry point
├── scripts/
│   └── demo-phase1.js        # Phase 1 demonstration
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
