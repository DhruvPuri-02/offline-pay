# OfflinePay - Setup Guide

## Quick Start (Phase 1)

The backend is ready to run! You can test Phase 1 without any additional installation.

### Test the Demo (No MongoDB Required)

```bash
cd C:\Users\DHRUV\OneDrive\offline-pay\backend
npm test
```

This runs a simulation showing:
- User creation with unique IDs
- Wallet balances
- Money transfers
- Transaction history
- Balance validation

---

## Full Backend Setup (Optional)

To run the full REST API server, you'll need MongoDB.

### Install MongoDB

**Option 1: MongoDB Community Server (Recommended)**

1. Download from: https://www.mongodb.com/try/download/community
2. Run installer (choose "Complete" installation)
3. Install as a Windows Service (check the option during setup)
4. MongoDB will start automatically

**Option 2: MongoDB Compass (GUI + Server)**

1. Download from: https://www.mongodb.com/try/download/compass
2. Includes MongoDB server with visual interface

### Start the Backend Server

```bash
cd C:\Users\DHRUV\OneDrive\offline-pay\backend

# Make sure MongoDB is running
# Windows: net start MongoDB
# Or: mongod --dbpath ./data/db

npm start
```

The server will run at: `http://localhost:5000`

### Test the API

**Create a user:**
```bash
curl -X POST http://localhost:5000/api/users -H "Content-Type: application/json" -d "{\"username\":\"alice\",\"name\":\"Alice Kumar\",\"initialBalance\":500}"
```

**Get all users:**
```bash
curl http://localhost:5000/api/users
```

---

## Mobile App Setup

### Install Flutter

1. **Download Flutter SDK**
   - Visit: https://docs.flutter.dev/get-started/install/windows
   - Download the Flutter SDK zip
   - Extract to: `C:\src\flutter`

2. **Add to PATH**
   - Open "Environment Variables" in Windows
   - Add `C:\src\flutter\bin` to your PATH

3. **Install Dependencies**
   - Android Studio: https://developer.android.com/studio
   - Or VS Code with Flutter extension

4. **Verify Installation**
   ```bash
   flutter doctor
   ```

### Create the Flutter Project

Once Flutter is installed:

```bash
cd C:\Users\DHRUV\OneDrive\offline-pay\mobile
flutter create .
flutter pub add http provider sqflite path_provider qr_flutter qr_code_scanner
```

---

## Project Status

### ✅ Phase 1: Basic Wallet (COMPLETED)

**What's Working:**
- Backend server structure
- User/wallet models
- Transaction models
- REST API endpoints
- Demo simulation

**Files Created:**
```
backend/
├── src/
│   ├── config/database.js
│   ├── models/User.js
│   ├── models/Transaction.js
│   ├── controllers/userController.js
│   ├── controllers/transactionController.js
│   ├── routes/userRoutes.js
│   ├── routes/transactionRoutes.js
│   └── server.js
├── scripts/demo-simple.js
├── .env.example
├── package.json
└── README.md
```

### 🔄 Phase 2: QR Payments (Next)

**To Do:**
- Install Flutter SDK
- Create mobile app UI
- Implement QR code generation
- Implement QR code scanning
- Connect mobile app to backend
- Add payment flow with confirmation

---

## API Reference (Phase 1)

### Health Check
```
GET http://localhost:5000/
```

### Users

**Create User**
```
POST http://localhost:5000/api/users
Body: {
  "username": "alice",
  "name": "Alice Kumar",
  "initialBalance": 1000
}
```

**Get All Users**
```
GET http://localhost:5000/api/users
```

**Get User**
```
GET http://localhost:5000/api/users/:id
```

**Add Balance**
```
POST http://localhost:5000/api/users/:id/topup
Body: {
  "amount": 500
}
```

### Transactions

**Create Transfer**
```
POST http://localhost:5000/api/transactions/transfer
Body: {
  "senderId": "USER_abc123",
  "receiverId": "USER_xyz789",
  "amount": 100,
  "description": "Payment"
}
```

**Get Transaction History**
```
GET http://localhost:5000/api/transactions/user/:id
```

**Get Transaction**
```
GET http://localhost:5000/api/transactions/:transactionId
```

---

## Development Workflow

### Working on Backend

1. Make code changes in `src/`
2. Test with: `npm test` (demo) or `npm start` (server)
3. Use Postman/curl to test API endpoints

### Working on Mobile (Phase 2+)

1. Start backend: `npm start`
2. Run Flutter app: `flutter run`
3. Test on emulator or physical device

---

## Troubleshooting

### MongoDB Connection Error

**Problem:** Server can't connect to MongoDB

**Solution:**
- Check if MongoDB service is running: `net start MongoDB`
- Or start manually: `mongod --dbpath ./data/db`
- Check connection string in `.env`

### Port Already in Use

**Problem:** Port 5000 is already in use

**Solution:**
- Change port in `.env`: `PORT=5001`
- Or stop the other process using port 5000

### Flutter Not Found

**Problem:** `flutter: command not found`

**Solution:**
- Install Flutter SDK
- Add Flutter to PATH
- Restart terminal/command prompt

---

## Next Steps

1. ✅ Backend Phase 1 is complete and tested
2. ⏳ Install MongoDB (optional, for full server)
3. ⏳ Install Flutter SDK
4. ⏳ Create mobile app UI
5. ⏳ Implement Phase 2 (QR payments)

---

## Important Reminders

⚠️ **SIMULATED MONEY ONLY**
- This is an educational project
- NOT connected to real banks
- NOT using real money
- For learning purposes only

🔒 **Security Notes**
- Current phase uses simulated security
- PIN hashing comes in Phase 4
- Cryptographic signing comes in Phase 5
- Not production-ready

---

## Resources

- **MongoDB Tutorial**: https://www.mongodb.com/docs/manual/tutorial/
- **Express.js Guide**: https://expressjs.com/en/guide/routing.html
- **Flutter Documentation**: https://docs.flutter.dev/
- **QR Code in Flutter**: https://pub.dev/packages/qr_flutter

---

**Project**: OfflinePay  
**Current Phase**: Phase 1 Complete ✅  
**Next Phase**: Phase 2 - QR Payments  
**Date**: October 2026
