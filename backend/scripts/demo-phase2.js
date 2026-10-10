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
  constructor({ transactionId, senderId, receiverId, senderWalletId, receiverWalletId, amount, type, status, description, nonce, timestamp }) {
    this.transactionId = transactionId;
    this.senderId = senderId;
    this.receiverId = receiverId;
    this.senderWalletId = senderWalletId;
    this.receiverWalletId = receiverWalletId;
    this.amount = amount;
    this.type = type;
    this.status = status;
    this.description = description;
    this.nonce = nonce;
    this.timestamp = timestamp || new Date();
  }
}

// Simulate QR payload generation
function generateQRPayload(receiver, amount, description) {
  const nonce = nanoid(16);
  const timestamp = new Date().toISOString();

  return {
    version: '1.0',
    type: 'PAYMENT_REQUEST',
    receiverId: receiver.userId,
    receiverName: receiver.name,
    receiverWalletId: receiver.walletId,
    amount: amount,
    description: description,
    nonce: nonce,
    timestamp: timestamp,
    expiresAt: new Date(Date.now() + 5 * 60 * 1000).toISOString()
  };
}

// Simulate QR verification
function verifyQRPayload(qrPayload, usedNonces) {
  // Check expiry
  if (qrPayload.expiresAt) {
    const expiryTime = new Date(qrPayload.expiresAt);
    if (expiryTime < new Date()) {
      return { valid: false, error: 'QR code has expired' };
    }
  }

  // Check for duplicate nonce
  if (usedNonces.has(qrPayload.nonce)) {
    return { valid: false, error: 'QR code already used (replay attack prevented)' };
  }

  return { valid: true };
}

// Simulate offline payment processing
function processOfflinePayment(sender, receiver, qrPayload, transactions, usedNonces) {
  // Verify QR
  const verification = verifyQRPayload(qrPayload, usedNonces);
  if (!verification.valid) {
    return { success: false, error: verification.error };
  }

  // Check balance
  if (sender.balance < qrPayload.amount) {
    return {
      success: false,
      error: 'Insufficient balance',
      available: sender.balance,
      required: qrPayload.amount
    };
  }

  // Create transaction
  const transaction = new Transaction({
    transactionId: `TXN_${nanoid(16)}`,
    senderId: sender.userId,
    receiverId: receiver.userId,
    senderWalletId: sender.walletId,
    receiverWalletId: receiver.walletId,
    amount: qrPayload.amount,
    type: 'OFFLINE_PAYMENT',
    status: 'CONFIRMED',
    description: qrPayload.description,
    nonce: qrPayload.nonce,
    timestamp: new Date(qrPayload.timestamp)
  });

  // Update balances
  sender.balance -= qrPayload.amount;
  receiver.balance += qrPayload.amount;

  // Mark nonce as used
  usedNonces.add(qrPayload.nonce);

  // Store transaction
  transactions.push(transaction);

  return {
    success: true,
    transaction: transaction,
    senderNewBalance: sender.balance,
    receiverNewBalance: receiver.balance
  };
}

const runDemo = () => {
  console.log('');
  console.log('═══════════════════════════════════════════════════════════');
  console.log('📱 OfflinePay - Phase 2 Demo: QR Payment System');
  console.log('═══════════════════════════════════════════════════════════');
  console.log('');
  console.log('⚠️  SIMULATED MONEY ONLY - Educational Project');
  console.log('');

  const users = [];
  const transactions = [];
  const usedNonces = new Set();

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

  console.log(`✓ Alice: ₹${alice.balance}`);
  console.log(`✓ Bob (Merchant): ₹${bob.balance}`);
  console.log('');

  // Scenario 1: Bob generates QR code for ₹100 payment
  console.log('═══════════════════════════════════════════════════════════');
  console.log('📲 Scenario 1: Generate Payment QR Code');
  console.log('═══════════════════════════════════════════════════════════');
  console.log('');
  console.log('Bob wants to receive ₹100 for goods...');
  console.log('');

  const qrPayload1 = generateQRPayload(bob, 100, 'Payment for goods');

  console.log('✓ QR Code Generated:');
  console.log(`  Receiver: ${qrPayload1.receiverName}`);
  console.log(`  Amount: ₹${qrPayload1.amount}`);
  console.log(`  Description: ${qrPayload1.description}`);
  console.log(`  Nonce: ${qrPayload1.nonce}`);
  console.log(`  Expires: ${new Date(qrPayload1.expiresAt).toLocaleString()}`);
  console.log('');
  console.log('QR Payload (JSON):');
  console.log(JSON.stringify(qrPayload1, null, 2));
  console.log('');

  // Scenario 2: Alice scans and verifies QR code
  console.log('═══════════════════════════════════════════════════════════');
  console.log('📷 Scenario 2: Alice Scans QR Code');
  console.log('═══════════════════════════════════════════════════════════');
  console.log('');
  console.log('Alice scans Bob\'s QR code with her phone...');
  console.log('');

  const verification = verifyQRPayload(qrPayload1, usedNonces);
  if (verification.valid) {
    console.log('✓ QR Code Verified:');
    console.log(`  Pay to: ${qrPayload1.receiverName}`);
    console.log(`  Amount: ₹${qrPayload1.amount}`);
    console.log(`  Description: ${qrPayload1.description}`);
    console.log(`  Status: Valid ✅`);
  } else {
    console.log(`❌ QR Verification Failed: ${verification.error}`);
  }
  console.log('');

  // Scenario 3: Alice confirms and processes payment
  console.log('═══════════════════════════════════════════════════════════');
  console.log('💸 Scenario 3: Process Payment');
  console.log('═══════════════════════════════════════════════════════════');
  console.log('');
  console.log('Alice confirms payment...');
  console.log('');

  const payment1 = processOfflinePayment(alice, bob, qrPayload1, transactions, usedNonces);

  if (payment1.success) {
    console.log('✓ Payment Successful!');
    console.log(`  Transaction ID: ${payment1.transaction.transactionId}`);
    console.log(`  Alice's new balance: ₹${payment1.senderNewBalance}`);
    console.log(`  Bob's new balance: ₹${payment1.receiverNewBalance}`);
    console.log(`  Nonce recorded: ${payment1.transaction.nonce}`);
  } else {
    console.log(`❌ Payment Failed: ${payment1.error}`);
  }
  console.log('');

  // Scenario 4: Attempt to replay the same QR code (security test)
  console.log('═══════════════════════════════════════════════════════════');
  console.log('🔒 Scenario 4: Replay Attack Prevention');
  console.log('═══════════════════════════════════════════════════════════');
  console.log('');
  console.log('Alice tries to scan the same QR code again...');
  console.log('');

  const replayAttempt = processOfflinePayment(alice, bob, qrPayload1, transactions, usedNonces);

  if (replayAttempt.success) {
    console.log('❌ SECURITY FAILURE: Replay attack succeeded (should not happen!)');
  } else {
    console.log('✓ Replay Attack Blocked!');
    console.log(`  Reason: ${replayAttempt.error}`);
    console.log(`  Security: Nonce validation working correctly ✅`);
  }
  console.log('');

  // Scenario 5: New QR code for different amount
  console.log('═══════════════════════════════════════════════════════════');
  console.log('📲 Scenario 5: New Payment Request');
  console.log('═══════════════════════════════════════════════════════════');
  console.log('');
  console.log('Bob generates a new QR code for ₹50...');
  console.log('');

  const qrPayload2 = generateQRPayload(bob, 50, 'Coffee and snacks');
  console.log('✓ New QR Code Generated:');
  console.log(`  Amount: ₹${qrPayload2.amount}`);
  console.log(`  Description: ${qrPayload2.description}`);
  console.log(`  New Nonce: ${qrPayload2.nonce}`);
  console.log('');

  console.log('Alice scans and pays...');
  console.log('');

  const payment2 = processOfflinePayment(alice, bob, qrPayload2, transactions, usedNonces);

  if (payment2.success) {
    console.log('✓ Payment Successful!');
    console.log(`  Transaction ID: ${payment2.transaction.transactionId}`);
    console.log(`  Alice's new balance: ₹${payment2.senderNewBalance}`);
    console.log(`  Bob's new balance: ₹${payment2.receiverNewBalance}`);
  }
  console.log('');

  // Scenario 6: Insufficient balance
  console.log('═══════════════════════════════════════════════════════════');
  console.log('❌ Scenario 6: Insufficient Balance');
  console.log('═══════════════════════════════════════════════════════════');
  console.log('');
  console.log('Bob generates QR for ₹500 (Alice has insufficient funds)...');
  console.log('');

  const qrPayload3 = generateQRPayload(bob, 500, 'Expensive item');
  console.log(`Alice's current balance: ₹${alice.balance}`);
  console.log(`Payment amount: ₹${qrPayload3.amount}`);
  console.log('');

  const payment3 = processOfflinePayment(alice, bob, qrPayload3, transactions, usedNonces);

  if (payment3.success) {
    console.log('Payment succeeded');
  } else {
    console.log('✓ Payment Rejected:');
    console.log(`  Reason: ${payment3.error}`);
    console.log(`  Available: ₹${payment3.available}`);
    console.log(`  Required: ₹${payment3.required}`);
  }
  console.log('');

  // Display final state
  console.log('═══════════════════════════════════════════════════════════');
  console.log('📊 Final State');
  console.log('═══════════════════════════════════════════════════════════');
  console.log('');

  console.log('Wallet Balances:');
  users.forEach(user => {
    console.log(`  ${user.name}: ₹${user.balance}`);
  });
  console.log('');

  console.log('Transaction History:');
  transactions.forEach(txn => {
    console.log(`  ${txn.transactionId}`);
    console.log(`    Amount: ₹${txn.amount}`);
    console.log(`    Type: ${txn.type}`);
    console.log(`    Status: ${txn.status}`);
    console.log(`    Nonce: ${txn.nonce}`);
    console.log('');
  });

  console.log('Security Stats:');
  console.log(`  Total nonces used: ${usedNonces.size}`);
  console.log(`  Total transactions: ${transactions.length}`);
  console.log(`  Replay attacks prevented: ${usedNonces.size - transactions.length}`);
  console.log('');

  console.log('═══════════════════════════════════════════════════════════');
  console.log('✅ Phase 2 Demo Complete!');
  console.log('═══════════════════════════════════════════════════════════');
  console.log('');
  console.log('What we demonstrated:');
  console.log('  ✓ QR code payload generation');
  console.log('  ✓ QR code verification');
  console.log('  ✓ QR expiration tracking');
  console.log('  ✓ Offline payment processing');
  console.log('  ✓ Nonce-based replay attack prevention');
  console.log('  ✓ Balance validation');
  console.log('  ✓ Transaction recording with QR metadata');
  console.log('');
  console.log('Next Phase: Offline-first architecture with local storage');
  console.log('');
};

runDemo();
