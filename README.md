# OfflinePay - Offline-First Digital Payment Prototype

**⚠️ IMPORTANT: This is a college/educational project using SIMULATED money only.**
**NO real banking, NO real money, NO real payment networks.**

## Project Overview

OfflinePay demonstrates how a digital payment system could work between two devices **without an internet connection**, then synchronize transactions with a backend when connectivity returns.

## Core Features (Planned)

- ✅ Phase 1: Basic wallet with simulated money
- 🔄 Phase 2: QR code payments
- 🔄 Phase 3: Offline-first architecture
- 🔄 Phase 4: Transaction PIN security
- 🔄 Phase 5: Cryptographic signatures
- 🔄 Phase 6: Backend synchronization
- 🔄 Phase 7: Double-spending protection
- 🔄 Phase 8: Advanced communication (Bluetooth/NFC)

## Technology Stack

### Mobile App
- Flutter (Dart)
- SQLite/Hive for local storage

### Backend
- Node.js
- Express.js
- MongoDB

### Security
- PIN hashing with bcrypt
- Public/private key cryptography (RSA/ECDSA)
- Digital signatures
- Unique transaction IDs/nonces

## Current Status: Phase 1 - Basic Wallet

Building the foundational user and wallet system with simulated money.

## Project Structure

```
offline-pay/
├── backend/          # Node.js + Express backend
├── mobile/           # Flutter mobile app
├── docs/             # Documentation
└── README.md
```

## Development Progress

### Phase 1 Checklist
- [ ] Backend server setup
- [ ] User/wallet schema
- [ ] Simulated balance system
- [ ] Basic transaction history
- [ ] API endpoints

---

**License**: MIT (Educational Project)
**Created**: October 2026
