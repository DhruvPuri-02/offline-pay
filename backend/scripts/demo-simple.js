import { nanoid } from 'nanoid';

// Simulate the data models without MongoDB
class User {
  constructor({ userId, username, name, walletId, balance = 0 }) {
    this.userId = userId;
    this.username = username;
    this.name = name;
    this.walletId = walletId;
    this.balance = balance;
    this.createdAt = new Date();
  }
}

class Transaction {
  constructor({ transactionId, senderId, receiverId, senderWalletId, receiverWalletId, amount, type, status, description }) {
    this.transactionId = transactionId;
    this.senderId = senderId;
    this.receiverId = receiverId;
    this.senderWalletId = senderWalletId;
    this.receiverWalletId = receiverWalletId;
    this.amount = amount;
    this.type = type;
    this.status = status;
    this.description = description;
    this.timestamp = new Date();
  }
}

const runDemo = () => {
  console.log('');
  console.log('═══════════════════════════════════════════════════════════');
  console.log('📱 OfflinePay - Phase 1 Demo: Basic Wallet System');
  console.log('═══════════════════════════════════════════════════════════');
  console.log('');
  console.log('⚠️  SIMULATED MONEY ONLY - Educational Project');
  console.log('');

  const users = [];
  const transactions = [];

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
  users.push(alice);

  const bob = new User({
    userId: `USER_${nanoid(12)}`,
    username: 'bob_merchant',
    name: 'Bob (Merchant)',
    walletId: `WALLET_${nanoid(12)}`,
    balance: 1000
  });
  users.push(bob);

  const charlie = new User({
    userId: `USER_${nanoid(12)}`,
    username: 'charlie',
    name: 'Charlie Singh',
    walletId: `WALLET_${nanoid(12)}`,
    balance: 750
  });
  users.push(charlie);

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

  [
    { user: alice, amount: 500 },
    { user: bob, amount: 1000 },
    { user: charlie, amount: 750 }
  ].forEach(({ user, amount }) => {
    const txn = new Transaction({
      transactionId: `TXN_${nanoid(16)}`,
      senderId: 'SYSTEM',
      receiverId: user.userId,
      senderWalletId: 'SYSTEM',
      receiverWalletId: user.walletId,
      amount: amount,
      type: 'TOPUP',
      status: 'CONFIRMED',
      description: 'Initial simulated balance'
    });
    transactions.push(txn);
  });

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
    description: 'Payment for goods'
  });
  transactions.push(txn1);

  alice.balance -= 100;
  bob.balance += 100;

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
    description: 'Payment split'
  });
  transactions.push(txn2);

  charlie.balance -= 50;
  alice.balance += 50;

  console.log(`  Transaction ID: ${txn2.transactionId}`);
  console.log(`  Charlie new balance: ₹${charlie.balance}`);
  console.log(`  Alice new balance: ₹${alice.balance}`);
  console.log('');

  // Simulate insufficient balance scenario
  console.log('💸 Transaction 3 (Failed): Bob → Alice (₹2000)');
  console.log('');

  if (bob.balance < 2000) {
    console.log(`  ❌ Payment rejected`);
    console.log(`  Reason: Insufficient balance`);
    console.log(`  Available: ₹${bob.balance}`);
    console.log(`  Required: ₹2000`);
  }
  console.log('');

  // Display final balances
  console.log('═══════════════════════════════════════════════════════════');
  console.log('📊 Final Wallet Balances');
  console.log('═══════════════════════════════════════════════════════════');
  console.log('');

  users.forEach(user => {
    console.log(`${user.name}:`);
    console.log(`  Balance: ₹${user.balance}`);
    console.log(`  Wallet ID: ${user.walletId}`);
    console.log('');
  });

  // Display transaction history for Alice
  console.log('═══════════════════════════════════════════════════════════');
  console.log(`📜 Alice's Transaction History`);
  console.log('═══════════════════════════════════════════════════════════');
  console.log('');

  const aliceTransactions = transactions.filter(
    txn => txn.senderId === alice.userId || txn.receiverId === alice.userId
  );

  aliceTransactions.forEach(txn => {
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
  });

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
  console.log('  ✓ Insufficient balance validation');
  console.log('');
  console.log('Database Schema:');
  console.log('  • User: userId, username, name, walletId, balance');
  console.log('  • Transaction: transactionId, senderId, receiverId,');
  console.log('    amount, type, status, description, timestamp');
  console.log('');
  console.log('Next Steps:');
  console.log('  1. Install MongoDB to run the full backend server');
  console.log('  2. Test backend APIs with Postman or curl');
  console.log('  3. Install Flutter SDK for mobile app development');
  console.log('  4. Move to Phase 2: QR code payment system');
  console.log('');
};

runDemo();
