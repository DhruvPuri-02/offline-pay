# OfflinePay - Offline-First Digital Payment Prototype

**⚠️ IMPORTANT: This is a college/educational project using SIMULATED money only.**
**NO real banking, NO real money, NO real payment networks.**

## Project Overview

OfflinePay demonstrates how a digital payment system could work between two devices **without an internet connection**, then synchronize transactions with a backend when connectivity returns.

QR code is only the *transport*. The project's substance is the offline
architecture: local ledger, offline balance management, pending-sync queue,
and double-spend controls.

## Feature Status

- ✅ Phase 1: Basic wallet with simulated money (backend + demo)
- ✅ Phase 2: QR code payments (two-message protocol, camera + paste scanning)
- ✅ Phase 3: Offline-first architecture (SQLite ledger, pending-sync queue)
- ✅ Phase 4: Transaction PIN security (bcrypt hashing, 5-attempt lockout)
- ✅ Phase 5: Cryptographic signatures (Ed25519 receipts, verified on scan + by Node)
- 🔄 Phase 6: Backend synchronization
- 🔄 Phase 7: Double-spending protection (local half done: reservation + offline cap)
- 🔄 Phase 8: Advanced communication (Bluetooth/NFC)

## Technology Stack

### Mobile App
- Flutter (Dart)
- SQLite (sqflite) for local, offline storage
- mobile_scanner / qr_flutter for the QR transport

### Backend
- Node.js + Express.js
- MongoDB (or a zero-install in-memory MongoDB for development)

### Security
- Unique transaction IDs and nonces (replay protection)
- Local balance reservation + offline spending limits
- Transaction PIN: salted bcrypt hash + temporary lockout (device-local, Phase 4)
- Ed25519 transaction signatures: tamper-evident receipts, verified on
  scan and cross-checked by the backend via a shared interop vector (Phase 5)

## What Works Right Now

1. **A complete offline payment between two devices** - Bob generates a
   payment-request QR, Alice scans and confirms, Alice shows a receipt QR,
   Bob scans it to record the incoming payment. No internet at any step;
   both devices end up with matching `PENDING_SYNC` ledger entries.
2. **Offline wallet** - balance, history and payments survive app restarts
   because everything lives in SQLite.
3. **Honest three-balance display** - available / confirmed / pending.
4. **Local double-spend controls** - spending the same offline balance
   twice on one device is refused, with a clear reason.
5. **Backend** - user/wallet/transfer/history/QR APIs with duplicate-nonce
   replay rejection (`409 DUPLICATE_NONCE`), runnable with or without
   MongoDB installed.

## Quick Start

```bash
# Backend (no MongoDB needed - falls back to an in-memory database)
cd backend
npm install
npm start          # API on http://localhost:5000
npm test           # Phase 1 demo script, runs anywhere

# Mobile
cd mobile
flutter pub get
flutter analyze
flutter test       # 31 tests
flutter run        # device/emulator
```

Full instructions, including the two-device offline demo walkthrough:
**[SETUP.md](SETUP.md)**

## Project Structure

```
offline-pay/
├── backend/          # Node.js + Express backend (authoritative at sync time)
├── mobile/           # Flutter app (offline-first: local ledger + QR flows)
├── docs/             # GUIDE.md (all phases) + OFFLINE_FIRST.md (how it works)
├── README.md
└── SETUP.md
```

## Documentation

| File | Contents |
|---|---|
| [SETUP.md](SETUP.md) | Installation, running, two-device demo script |
| [docs/OFFLINE_FIRST.md](docs/OFFLINE_FIRST.md) | SQLite schema, QR protocol, sync flow, **honest double-spend limitations** |
| [docs/GUIDE.md](docs/GUIDE.md) | Full 8-phase technical guide |
| [backend/README.md](backend/README.md) | API reference + database schema |

## Honest Limitations

- Local rules stop double-spending **on one device**; authoritative
  arbitration happens only when Phase 6 sync runs against the server.
- Transactions are not yet signed (Phase 5), so a receipt could in
  principle be altered between devices - the prototype does not defend
  against that yet and does not claim to.
- Amounts use `double`; real financial systems use integer minor units.

---

**License**: MIT (Educational Project)
**Created**: October 2026
