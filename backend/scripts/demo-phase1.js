import { MongoMemoryServer } from 'mongodb-memory-server';
import mongoose from 'mongoose';
import { nanoid } from 'nanoid';
import User from '../src/models/User.js';
import Transaction from '../src/models/Transaction.js';

let mongod;

const connectTestDB = async () => {
  try {
    // Start in-memory MongoDB server
    mongod = await MongoMemoryServer.create();
    const uri = mongod.getUri();

    await mongoose.connect(uri);
    console.log('✅ Connected to in-memory MongoDB');
  } catch (error) {
    console.error('❌ Failed to connect to test database:', error);
    process.exit(1);
  }
};

const disconnectTestDB = async () => {
  try {
    await mongoose.disconnect();
    await mongod.stop();
    console.log('✅ Disconnected from test database');
  } catch (error) {
    console.error('❌ Error disconnecting:', error);
  }
};

const runDemo = async () => {
  console.log('');
  console.log('═══════════════════════════════════════════════════════════');
  console.log('📱 OfflinePay - Phase 1 Demo: Basic Wallet System');
  console.log('═══════════════════════════════════════════════════════════');
  console.log('');

  try {
    await connectTestDB();

    // Create users
    console.log('👤 Creating users...');
    console.log('');

    const alice = new User({
      userId: `USER_${nanoid(12)}`,
      username: 'alice',
      name: 'Alice Kumar',
      walletId: `WALLET_${nanoid(12)}`,
      balance: 500
    });
    await alice.save();

    const bob = new User({
      userId: `USER_${nanoid(12)}`,
      username: 'bob_merchant',
      name: 'Bob (Merchant)',
      walletId: `WALLET_${nanoid(12)}`,
      balance: 1000
    });
    await bob.save();

    const charlie = new User({
      userId: `USER_${nanoid(12)}`,
      username: 'charlie',
      name: 'Charlie Singh',
      walletId: `WALLET_${nanoid(12)}`,
      balance: 750
    });
    await charlie.save();

    console.log(`✓ Alice created:`);
    console.log(`  User ID: ${alice.userId}`);
    console.log(`  Wallet ID: ${alice.walletId}`);
    console.log(`  Balance: ₹${alice.balance}`);
    console.log('');

    console.log(`✓ Bob (Merchant) created:`);
    console.log(`  User ID: ${bob.userId}`);
    console.log(`  Wallet ID: ${bob.walletId}`);
    console.log(`  Balance: ₹${bob.balance}`);
    console.log('');

    console.log(`✓ Charlie created:`);
    console.log(`  User ID: ${charlie.userId}`);
    console.log(`  Wallet ID: ${charlie.walletId}`);
    console.log(`  Balance: ₹${charlie.balance}`);
    console.log('');

    // Create initial balance transactions (topups)
    console.log('💰 Recording initial balance transactions...');
    console.log('');

    const topups = [
      { user: alice, amount: 500 },
      { user: bob, amount: 1000 },
      { user: charlie, amount: 750 }
    ];

    for (const { user, amount } of topups) {
      const txn = new Transaction({
        transactionId: `TXN_${nanoid(16)}`,
        senderId: 'SYSTEM',
        receiverId: user.userId,
        senderWalletId: 'SYSTEM',
        receiverWalletId: user.walletId,
        amount: amount,
        type: 'TOPUP',
        status: 'CONFIRMED',
        description: 'Initial simulated balance',
        timestamp: new Date()
      });
      await txn.save();
    }

    console.log('✓ Initial balances recorded');
    console.log('');

    // Simulate a transfer: Alice pays Bob ₹100
    console.log('💸 Transaction 1: Alice → Bob (₹100)');
    console.log('');

    const txn1 = new Transaction({
      transactionId: `TXN_${nanoid(16)}`,
      senderId: alice.userId,
      receiverId: bob.userId,
      senderWalletId: alice.walletId,
      receiverWalletId: bob.walletId,
      amount: 100,
      type: 'DIRECT_TRANSFER',
      status: 'CONFIRMED',
      description: 'Payment for goods',
      timestamp: new Date()
    });
    await txn1.save();

    alice.balance -= 100;
    bob.balance += 100;
    await alice.save();
    await bob.save();

    console.log(`  Transaction ID: ${txn1.transactionId}`);
    console.log(`  Alice new balance: ₹${alice.balance}`);
    console.log(`  Bob new balance: ₹${bob.balance}`);
    console.log('');

    // Simulate another transfer: Charlie pays Alice ₹50
    console.log('💸 Transaction 2: Charlie → Alice (₹50)');
    console.log('');

    const txn2 = new Transaction({
      transactionId: `TXN_${nanoid(16)}`,
      senderId: charlie.userId,
      receiverId: alice.userId,
      senderWalletId: charlie.walletId,
      receiverWalletId: alice.walletId,
      amount: 50,
      type: 'DIRECT_TRANSFER',
      status: 'CONFIRMED',
      description: 'Payment split',
      timestamp: new Date()
    });
    await txn2.save();

    charlie.balance -= 50;
    alice.balance += 50;
    await charlie.save();
    await alice.save();

    console.log(`  Transaction ID: ${txn2.transactionId}`);
    console.log(`  Charlie new balance: ₹${charlie.balance}`);
    console.log(`  Alice new balance: ₹${alice.balance}`);
    console.log('');

    // Display final balances
    console.log('═══════════════════════════════════════════════════════════');
    console.log('📊 Final Wallet Balances');
    console.log('═══════════════════════════════════════════════════════════');
    console.log('');

    const allUsers = await User.find().sort({ createdAt: 1 });
    for (const user of allUsers) {
      console.log(`${user.name}:`);
      console.log(`  Balance: ₹${user.balance}`);
      console.log(`  Wallet ID: ${user.walletId}`);
      console.log('');
    }

    // Display transaction history for Alice
    console.log('═══════════════════════════════════════════════════════════');
    console.log(`📜 Alice's Transaction History`);
    console.log('═══════════════════════════════════════════════════════════');
    console.log('');

    const aliceTransactions = await Transaction.find({
      $or: [{ senderId: alice.userId }, { receiverId: alice.userId }]
    }).sort({ timestamp: 1 });

    for (const txn of aliceTransactions) {
      const isSender = txn.senderId === alice.userId;
      const type = isSender ? '→' : '←';
      const sign = isSender ? '-' : '+';
      const otherParty = isSender ? txn.receiverId : txn.senderId;

      console.log(`${sign}₹${txn.amount} ${type} ${otherParty}`);
      console.log(`  ${txn.description}`);
      console.log(`  Status: ${txn.status}`);
      console.log(`  Type: ${txn.type}`);
      console.log(`  Time: ${txn.timestamp.toISOString()}`);
      console.log('');
    }

    console.log('═══════════════════════════════════════════════════════════');
    console.log('✅ Phase 1 Demo Complete!');
    console.log('═══════════════════════════════════════════════════════════');
    console.log('');
    console.log('What we demonstrated:');
    console.log('  ✓ User creation with unique IDs');
    console.log('  ✓ Wallet system with simulated balances');
    console.log('  ✓ Transaction recording');
    console.log('  ✓ Balance updates');
    console.log('  ✓ Transaction history tracking');
    console.log('');
    console.log('Next Phase: QR code payment system');
    console.log('');

  } catch (error) {
    console.error('❌ Demo failed:', error);
  } finally {
    await disconnectTestDB();
  }
};

runDemo();
