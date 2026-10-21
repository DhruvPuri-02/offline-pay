import { nanoid } from 'nanoid';
import User from '../models/User.js';
import Transaction from '../models/Transaction.js';

// Generate QR payment payload
export const generatePaymentQR = async (req, res) => {
  try {
    const { id } = req.params; // receiver's userId or walletId
    const { amount, description = 'Payment' } = req.body;

    // Validation
    if (!amount || amount <= 0) {
      return res.status(400).json({
        success: false,
        error: 'Valid amount is required'
      });
    }

    // Find receiver
    const receiver = await User.findOne({
      $or: [{ userId: id }, { walletId: id }]
    });

    if (!receiver) {
      return res.status(404).json({
        success: false,
        error: 'User not found'
      });
    }

    // Generate unique nonce for this payment request
    const nonce = nanoid(16);
    const timestamp = new Date().toISOString();

    // Create QR payload
    const qrPayload = {
      version: '1.0',
      type: 'PAYMENT_REQUEST',
      receiverId: receiver.userId,
      receiverName: receiver.name,
      receiverWalletId: receiver.walletId,
      amount: amount,
      description: description,
      nonce: nonce,
      timestamp: timestamp,
      expiresAt: new Date(Date.now() + 5 * 60 * 1000).toISOString() // 5 minutes
    };

    res.status(200).json({
      success: true,
      message: 'QR payment request generated',
      data: {
        qrPayload: qrPayload,
        qrString: JSON.stringify(qrPayload),
        expiresIn: 300 // seconds
      }
    });

  } catch (error) {
    console.error('Generate QR error:', error);
    res.status(500).json({
      success: false,
      error: 'Internal server error'
    });
  }
};

// Process offline payment (from scanned QR)
export const processOfflinePayment = async (req, res) => {
  try {
    const {
      senderId,
      receiverId,
      receiverWalletId,
      amount,
      description,
      nonce,
      timestamp
    } = req.body;

    // Validation
    if (!senderId || !receiverId || !amount || !nonce) {
      return res.status(400).json({
        success: false,
        error: 'Missing required fields'
      });
    }

    if (amount <= 0) {
      return res.status(400).json({
        success: false,
        error: 'Amount must be greater than 0'
      });
    }

    if (senderId === receiverId) {
      return res.status(400).json({
        success: false,
        error: 'Cannot pay yourself'
      });
    }

    // Check for duplicate nonce (replay protection)
    const existingTransaction = await Transaction.findOne({ nonce });
    if (existingTransaction) {
      return res.status(400).json({
        success: false,
        error: 'Transaction already processed (duplicate nonce)',
        rejectionReason: 'DUPLICATE_NONCE'
      });
    }

    // Find sender and receiver
    const sender = await User.findOne({
      $or: [{ userId: senderId }, { walletId: senderId }]
    });

    const receiver = await User.findOne({
      $or: [{ userId: receiverId }, { walletId: receiverId }]
    });

    if (!sender) {
      return res.status(404).json({
        success: false,
        error: 'Sender not found'
      });
    }

    if (!receiver) {
      return res.status(404).json({
        success: false,
        error: 'Receiver not found'
      });
    }

    // Check balance
    if (sender.balance < amount) {
      return res.status(400).json({
        success: false,
        error: 'Insufficient balance',
        available: sender.balance,
        required: amount
      });
    }

    // Create transaction
    const transaction = new Transaction({
      transactionId: `TXN_${nanoid(16)}`,
      senderId: sender.userId,
      receiverId: receiver.userId,
      senderWalletId: sender.walletId,
      receiverWalletId: receiver.walletId,
      amount: amount,
      type: 'OFFLINE_PAYMENT',
      status: 'CONFIRMED', // Will be PENDING_SYNC in Phase 3
      description: description || 'QR Payment',
      nonce: nonce,
      timestamp: timestamp ? new Date(timestamp) : new Date()
    });

    // Update balances
    sender.balance -= amount;
    receiver.balance += amount;

    // Save all changes
    await Promise.all([
      sender.save(),
      receiver.save(),
      transaction.save()
    ]);

    res.status(201).json({
      success: true,
      message: 'Payment successful',
      data: {
        transactionId: transaction.transactionId,
        status: transaction.status,
        from: {
          userId: sender.userId,
          name: sender.name,
          newBalance: sender.balance
        },
        to: {
          userId: receiver.userId,
          name: receiver.name,
          newBalance: receiver.balance
        },
        amount: amount,
        timestamp: transaction.timestamp
      }
    });

  } catch (error) {
    // E11000 = MongoDB duplicate key. Our findOne() nonce check above has a
    // race window: two uploads of the same transaction can both pass it.
    // The unique index on `nonce` is the real defence - whoever loses the
    // race gets this error, and we report it as a duplicate instead of
    // double-crediting the receiver.
    if (error.code === 11000) {
      return res.status(409).json({
        success: false,
        error: 'Transaction already processed (duplicate nonce)',
        rejectionReason: 'DUPLICATE_NONCE'
      });
    }

    console.error('Process offline payment error:', error);
    res.status(500).json({
      success: false,
      error: 'Internal server error'
    });
  }
};

// Verify QR payload (check if expired, valid format, etc.)
export const verifyQRPayload = async (req, res) => {
  try {
    const { qrString } = req.body;

    if (!qrString) {
      return res.status(400).json({
        success: false,
        error: 'QR string is required'
      });
    }

    // Parse QR payload
    let qrPayload;
    try {
      qrPayload = JSON.parse(qrString);
    } catch (e) {
      return res.status(400).json({
        success: false,
        error: 'Invalid QR format'
      });
    }

    // Validate required fields
    const requiredFields = ['receiverId', 'receiverWalletId', 'amount', 'nonce', 'timestamp'];
    const missingFields = requiredFields.filter(field => !qrPayload[field]);

    if (missingFields.length > 0) {
      return res.status(400).json({
        success: false,
        error: 'Invalid QR payload',
        missingFields: missingFields
      });
    }

    // Check if expired
    if (qrPayload.expiresAt) {
      const expiryTime = new Date(qrPayload.expiresAt);
      if (expiryTime < new Date()) {
        return res.status(400).json({
          success: false,
          error: 'QR code has expired'
        });
      }
    }

    // Check if receiver exists
    const receiver = await User.findOne({
      $or: [
        { userId: qrPayload.receiverId },
        { walletId: qrPayload.receiverWalletId }
      ]
    });

    if (!receiver) {
      return res.status(404).json({
        success: false,
        error: 'Receiver not found'
      });
    }

    // Check for duplicate nonce
    const existingTransaction = await Transaction.findOne({ nonce: qrPayload.nonce });
    if (existingTransaction) {
      return res.status(400).json({
        success: false,
        error: 'QR code already used',
        usedAt: existingTransaction.timestamp
      });
    }

    res.status(200).json({
      success: true,
      message: 'QR code is valid',
      data: {
        receiverName: receiver.name,
        receiverUserId: receiver.userId,
        amount: qrPayload.amount,
        description: qrPayload.description,
        valid: true
      }
    });

  } catch (error) {
    console.error('Verify QR error:', error);
    res.status(500).json({
      success: false,
      error: 'Internal server error'
    });
  }
};
