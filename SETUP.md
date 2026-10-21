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
flutter test         # 31 tests
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
                    → receipt QR appears, status PENDING SYNC
4. Bob:             Receive → [I received a payment - scan receipt]
                    → scans Alice's receipt QR → [Record Payment]
5. Check both apps: Home shows Available reduced (Alice) / Pending in (Bob);
                    History shows PENDING SYNC on both sides.
6. Restart both apps: balances and history are still there (SQLite).
```

Pay-a-friend variant (payer initiates): **Pay** → recipient ID + amount →
Continue → Alice shows a receipt QR → Bob records it in step 4 above.

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

### 🔄 Next: Phase 4 - Transaction PIN
Extension points are already marked in
`mobile/lib/providers/wallet_provider.dart` (`PHASE 4 HOOK`, `PHASE 5 HOOK`).

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

---

## 6. Documentation

- **[docs/OFFLINE_FIRST.md](docs/OFFLINE_FIRST.md)** - SQLite schema, QR
  message protocol, sync flow, honest double-spend limitations
- **[docs/GUIDE.md](docs/GUIDE.md)** - all 8 phases, design concepts
- **[backend/README.md](backend/README.md)** - API + Mongo schema

---

**Project**: OfflinePay
**Status**: Phases 1-3 complete
**Date**: October 2026

**⚠️ SIMULATED MONEY ONLY - Educational Project**
