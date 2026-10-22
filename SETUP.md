# OfflinePay - Setup Guide

Everything below has been run and verified on Windows. Commands are shown
from the repository root.

> **Simulated money only** - this project never touches real banks or payment networks.

---

## 1. Backend

### Prerequisites
- Node.js 18+ (verified on Node 24)

### Install & run

```bash
cd backend
npm install
npm start
```

**You do NOT need MongoDB installed.** If `MONGODB_URI` is empty (the
default), the server starts an in-memory MongoDB automatically via
`mongodb-memory-server`. Data lives until the server stops.

To use a real MongoDB instead, set it in `backend/.env`:

```env
MONGODB_URI=mongodb://127.0.0.1:27017/offlinepay
```

> **PowerShell note:** if you see *"running scripts is disabled on this
> system"* for `npm.ps1`, use `npm.cmd` instead (e.g. `npm.cmd start`),
> or run `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.

### Verify

```bash
cd backend
npm test           # Phase 1 demo (no database required)
```

Then with the server running:

```bash
curl http://localhost:5000/                  # health check
curl http://localhost:5000/api/users         # list users
```

API reference: [backend/README.md](backend/README.md)

---

## 2. Mobile App

### Prerequisites
- Flutter SDK 3.x (verified on 3.47.7 / Dart 3.13)

```bash
# Install (one-time), e.g. to C:\Users\<you>\flutter-sdk
#   download: https://docs.flutter.dev/get-started/install/windows
# add <sdk>\flutter\bin to your PATH, then:
flutter doctor        # check what is missing on your machine
```

`flutter doctor` will flag an Android SDK (for phones/emulators) and
Visual Studio "Desktop development with C++" (for Windows builds).
Neither is needed for `flutter analyze` / `flutter test`.

### Build & test

```bash
cd mobile
flutter create . --project-name offlinepay --org com.offlinepay --platforms android,windows
flutter pub get
flutter analyze      # must report "No issues found"
flutter test         # 57 tests
flutter run          # start on a connected device/emulator
```

> `flutter create .` only needs to run once (it generates the `android/`
> and `windows/` folders). Re-running it never touches `lib/`.
>
> **Windows build tip:** building the app with plugins requires Developer
> Mode (symlinks): Settings → System → For developers → Developer Mode ON.
> `flutter analyze` and `flutter test` do not need it.

### No device handy?

The app also runs on Windows (wallet, ledger, balance, manual Pay flow).
The camera scanner has a paste-JSON fallback everywhere, so the full
payment flow is still demo-able with two desktop windows: copy the QR JSON
from one window's "Copy transaction JSON" button and paste it into the
other's scanner field.

---

## 3. The Two-Device Offline Demo (the whole point of the project)

Prerequisites: two devices/emulators (or one device + one desktop), app
installed. **Turn Wi-Fi and mobile data OFF on both devices first.**

```
1. Bob (receiver):  Receive → enter amount ₹100 → [Generate QR Code]
2. Alice (payer):   Scan QR Code → point camera at Bob's QR
                    (or paste the QR JSON)
3. Alice:           verify details → [Confirm Payment]
                    → FIRST TIME: create a 4-6 digit transaction PIN;
                      later payments: enter that PIN
                    → receipt QR appears, status PENDING SYNC
4. Bob:             Receive → [I received a payment - scan receipt]
                    → scans Alice's receipt QR → [Record Payment]
5. Check both apps: Home shows Available reduced (Alice) / Pending in (Bob);
                    History shows PENDING SYNC on both sides.
6. Restart both apps: balances and history are still there (SQLite).
```

Pay-a-friend variant (payer initiates): **Pay** → recipient ID + amount →
Continue → Alice shows a receipt QR → Bob records it in step 4 above.

**Step 7 - back online (Phase 6 sync):**

```
7a. Start the backend (cd backend && npm.cmd start) and turn Wi-Fi back ON
7b. Both devices: tap [Sync] on Home
    → Alice: her outgoing payment gets a verdict (CONFIRMED) - the
      reserved amount becomes a real debit, no balance jump
    → Bob:   pulls the payment Alice uploaded (even if Bob never synced
      his copy first) - it lands as CONFIRMED and becomes spendable
    → History shows the settled statuses; the queue count drops to 0
    → Repeat taps are safe: sync is idempotent (never double-credits)
With the backend STOPPED, tapping [Sync] shows "Push failed" and loses
nothing - the queue waits exactly as before.
```

---

## 4. Project Status

### ✅ Phase 1 - Basic Wallet (backend)
Users, simulated balances, transfers, history, topups, demo scripts.

### ✅ Phase 2 - QR Payments
Payment-request QR generation, camera + paste scanning, payment
confirmation, receipt QR hand-off back to the receiver.

### ✅ Phase 3 - Offline Mode
SQLite wallet + ledger, boot from local storage, `PENDING_SYNC`
transactions, pending-sync queue API for Phase 6, three-balance display
(available / confirmed / pending), local double-spend controls
(reservation + ₹500 offline cap).

### ✅ Phase 4 - Transaction PIN
First payment asks you to create a 4-6 digit PIN (stored only as a
salted bcrypt hash); every payment after that verifies it before the
transaction is written. Wrong PINs are counted - 5 failures lock
payments for 30 seconds. The key icon on the Home app bar opens the
PIN settings (status, change PIN, lockout countdown).

### ✅ Phase 5 - Cryptographic signatures
Every payment is signed (Ed25519) over the exact payment details. The
payer's receipt screen shows the key fingerprint; the receiver's Scan
screen verifies the signature *before* you can record - a tampered
amount/receiver/description shows a red INVALID banner and blocks the
transaction. The private key seed lives in the platform keystore
(Android Keystore / Windows Credential Manager), generated lazily on
the first payment. The backend verifies the same bytes:
`cd backend && npm run test:phase5`, or copy a receipt JSON and run
`node scripts/verify_receipt.js receipt.json`.

### ✅ Phase 6 - Backend synchronization
The Home screen's **Sync** button uploads every `PENDING_SYNC` transaction
in one batch; the server verifies signatures, refuses replays, dedupes by
transaction id (both devices may push the same payment) and returns a
per-transaction verdict that the app applies locally - confirmed money
moves the balance exactly once, rejections release the reservation. A
pull then imports payments other devices uploaded while this one was
offline. First push binds the device's public key to its user
(trust-on-first-use). Self-check: `cd backend && npm run test:phase6`.
Honest limits (no auth, cleartext HTTP; the balance half is Phase 7
below): `docs/OFFLINE_FIRST.md` section 8.

### ✅ Phase 7 - Double-spending protection
Server-side balance arbitration: every spend pushed at
`POST /api/sync/push` is checked against the sender's authoritative
balance - a cloned wallet's twin is refused (`INSUFFICIENT_BALANCE`)
and its app corrects itself to the server's number. Four gates run per
transaction: offline-payments-only (a pushed TOPUP would print money),
the ₹500 cap again, sender-must-exist, then the balance itself. A first
push from an unknown userId **onboards** the account with a
server-decided ₹500 grant plus escrowed incoming payments (received
before the account existed). Self-check: `cd backend && npm run
test:phase7` (18 real-HTTP checks incl. the clone double-spend).
Honest limits (no auth - first claim wins; load-compare-save, not
atomic; arbitration only at sync): `docs/OFFLINE_FIRST.md` section 8.

### ✅ Phase 8 - Advanced communication
The two protocol messages (request + receipt) can now travel without a
QR scan, behind one rule: however a message arrives, it gets the same
signature verification and the same explicit confirmation before
anything is recorded.

- **Wi-Fi LAN channel - works and is tested** (`flutter test`,
  `test/lan_peer_test.dart` runs the real host and client on loopback).
  Demo with two devices: in **Receive**, generate the QR as usual, then
  flip **"Also serve via Wi-Fi"** and note the shown `ip:port`. On the
  payer device open **Scan**, type that address under **"From a nearby
  device (same Wi-Fi)"** and tap **Fetch** - pay exactly like a QR flow.
  After paying, tap **"Send receipt to ip:port"** on the receipt screen;
  the receiver gets a "Receipt received" notice and records it in
  **Receive → Scan incoming payment**, where the signature check and
  confirmation run as always. Both phones must be on the same Wi-Fi (or
  one phone's hotspot).
- **Bluetooth (Nearby Connections) and NFC (tap exchange) adapters**:
  service-level code written against the installed plugins' APIs and
  wired into the Android manifest, but **never executed on hardware in
  this repo** (no Android SDK/device here) - so they are labeled
  "hardware-unverified" everywhere and are not yet on the screens. They
  need a real phone + permissions to become features. Honest details and
  integration notes: `docs/OFFLINE_FIRST.md` section 10, and the header
  comments in `mobile/lib/services/peer/`.

Self-check: `cd mobile && flutter analyze && flutter test` (120 tests).
QR remains the always-works fallback for every carrier.

---

## 5. Troubleshooting

| Problem | Fix |
|---|---|
| `npm.ps1 cannot be loaded` | Use `npm.cmd start`, or set execution policy (above) |
| Backend: "MongoDB Connection Error" | Leave `MONGODB_URI` empty to use the in-memory database |
| Port 5000 already in use | Change `PORT` in `backend/.env` |
| `flutter: command not found` | Add `<sdk>\flutter\bin` to PATH, restart terminal |
| Camera does not open | Grant permission, or use the paste-JSON field (works everywhere) |
| Windows build: "requires symlink support" | Enable Windows Developer Mode |
| App cannot reach backend on a phone | Use your PC's LAN IP in `mobile/lib/services/api_service.dart` (`baseUrl`); the offline flow does not need this |
| Sync says "Push failed" | Backend not running (or wrong `baseUrl`) - start it with `npm.cmd start`; the queue keeps everything meanwhile |
| Nearby fetch: "Could not reach ip:port" | Both devices on the same Wi-Fi (or one hotspot), the Receive screen still shows its request **and** the Wi-Fi switch is ON (leaving Receive stops serving), correct port from the displayed address |
| Bluetooth/NFC buttons missing | Expected: those carriers are service-level adapters until confirmed on real hardware; the LAN + QR paths are the working ones |

---

## 6. Documentation

- **[docs/OFFLINE_FIRST.md](docs/OFFLINE_FIRST.md)** - SQLite schema, QR
  message protocol, sync flow, honest double-spend limitations
- **[docs/GUIDE.md](docs/GUIDE.md)** - all 8 phases, design concepts
- **[backend/README.md](backend/README.md)** - API + Mongo schema

---

**Project**: OfflinePay
**Status**: Phases 1-8 complete
**Date**: October 2026

**⚠️ SIMULATED MONEY ONLY - Educational Project**
