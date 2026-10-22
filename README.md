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
- ✅ Phase 6: Backend synchronization (push verdicts, pull merge, TOFU key binding)
- ✅ Phase 7: Double-spending protection (server-side balance arbitration, clone-stopper)
- ✅ Phase 8: Advanced communication - Wi-Fi LAN channel (implemented **and**
  tested) + Bluetooth/NFC adapters (service-level, honestly labeled
  hardware-unverified)

## Technology Stack

### Mobile App
- Flutter (Dart)
- SQLite (sqflite) for local, offline storage
- mobile_scanner / qr_flutter for the QR transport
- Peer carriers (Phase 8): `dart:io` sockets for the tested LAN channel;
  nearby_connections / flutter_nfc_hce / nfc_manager for the
  hardware-unverified Bluetooth and NFC adapters

### Backend
- Node.js + Express.js
- MongoDB (or a zero-install in-memory MongoDB for development)

### Security
- Unique transaction IDs and nonces (replay protection)
- Local balance reservation + offline spending limits
- Transaction PIN: salted bcrypt hash + temporary lockout (device-local, Phase 4)
- Ed25519 transaction signatures: tamper-evident receipts, verified on
  scan and cross-checked by the backend via a shared interop vector (Phase 5)
- Server-side sync verification: signature + registered-key binding +
  nonce replay + idempotent dedupe on every upload; pull re-verified on
  the device (Phase 6)
- Server-side balance arbitration: every pushed spend is checked against
  the sender's authoritative balance (a cloned wallet's twin is refused,
  `INSUFFICIENT_BALANCE`), plus type/limit/sender gates; onboarding
  grants are server-decided (Phase 7)

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
6. **Synchronization** - the Home screen's Sync button uploads the
   `PENDING_SYNC` queue (each transaction gets a verdict), pulls
   payments other devices uploaded while this one was offline, and
   applies them to balances. Offline, it fails without losing anything
   and the queue just waits.
7. **Double-spend arbitration** - the server debits ONE authoritative
   balance per user: a cloned wallet's second device is refused at sync
   (`INSUFFICIENT_BALANCE`) and its app corrects itself to the server's
   number. First-time syncs onboard the account with a server-decided
   ₹500 grant plus any payments escrowed while the device was away.
8. **Same payment over Wi-Fi instead of a QR scan** - the receiver
   switches on "Also serve via Wi-Fi" (Receive screen), the payer types
   the shown `ip:port` in Scan → Fetch, pays exactly as before, and sends
   the receipt straight back; the receiver still verifies its signature
   and confirms before it is recorded. No cloud, no internet, same
   protocol - and this channel is covered by real-socket tests.

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
flutter test       # 120 tests
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

- Local rules stop double-spending **on one device**; server-side
  arbitration (Phase 7) stops it **across clones at sync time** - one
  shared server balance, first spend wins. Offline, the clone's spend is
  accepted locally until the next Sync.
- Sync has no authentication (trust-on-first-use: first claim on a
  userId wins - account, grant and key) and runs over cleartext HTTP;
  the balance gate is load-compare-save, not atomic. Fine for a LAN
  demo, not for production.
- The Phase 8 LAN carrier is equally unauthenticated: plain HTTP, anyone
  on the same Wi-Fi can fetch the (public) request or inject junk
  receipts that fail verification anyway. The Bluetooth/NFC adapters
  have never run on hardware from this repo - only their APIs are
  verified - so they are labeled accordingly wherever they appear.
- Amounts use `double`; real financial systems use integer minor units.

---

**License**: MIT (Educational Project)
**Created**: October 2026
