import { nanoid } from 'nanoid';
import User from '../models/User.js';
import Transaction from '../models/Transaction.js';

// Get transaction history for a user
export const getTransactionHistory = async (req, res) => {
  try {
    const { id } = req.params;
    const { limit = 50, offset = 0 } = req.query;

    // Find user
    const user = await User.findOne({
      $or: [{ userId: id }, { walletId: id }]
    });

    if (!user) {
      return res.status(404).json({
        success: false,
        error: 'User not found'
      });
    }

    // Get transactions where user is sender or receiver
    const transactions = await Transaction.find({
      $or: [
        { senderId: user.userId },
        { receiverId: user.userId }
      ]
    })
      .sort({ timestamp: -1 })
      .limit(parseInt(limit))
      .skip(parseInt(offset));

    // Format transactions for response
    const formattedTransactions = transactions.map(txn => ({
      transactionId: txn.transactionId,
      type: txn.senderId === user.userId ? 'SENT' : 'RECEIVED',
      amount: txn.amount,
      otherPartyId: txn.senderId === user.userId ? txn.receiverId : txn.senderId,
      otherPartyWalletId: txn.senderId === user.userId ? txn.receiverWalletId : txn.senderWalletId,
      status: txn.status,
      description: txn.description,
      timestamp: txn.timestamp,
      rejectionReason: txn.rejectionReason
    }));

    res.status(200).json({
      success: true,
      count: formattedTransactions.length,
      data: formattedTransactions
    });

  } catch (error) {
    console.error('Get transaction history error:', error);
    res.status(500).json({
      success: false,
      error: 'Internal server error'
    });
  }
};

// Create a direct transfer (Phase 1 - basic transfer without offline/QR)
export const createTransfer = async (req, res) => {
  try {
    const { senderId, receiverId, amount, description = 'Payment' } = req.body;

    // Validation
    if (!senderId || !receiverId || !amount) {
      return res.status(400).json({
        success: false,
        error: 'senderId, receiverId, and amount are required'
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
        error: 'Cannot transfer to yourself'
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
      type: 'DIRECT_TRANSFER',
      status: 'CONFIRMED',
      description: description,
      timestamp: new Date()
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
      message: 'Transfer successful',
      data: {
        transactionId: transaction.transactionId,
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
    console.error('Create transfer error:', error);
    res.status(500).json({
      success: false,
      error: 'Internal server error'
    });
  }
};

// Get a specific transaction by ID
export const getTransaction = async (req, res) => {
  try {
    const { transactionId } = req.params;

    const transaction = await Transaction.findOne({ transactionId });

    if (!transaction) {
      return res.status(404).json({
        success: false,
        error: 'Transaction not found'
      });
    }

    res.status(200).json({
      success: true,
      data: transaction
    });

  } catch (error) {
    console.error('Get transaction error:', error);
    res.status(500).json({
      success: false,
      error: 'Internal server error'
    });
  }
};
