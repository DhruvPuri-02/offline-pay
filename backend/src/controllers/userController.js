import { nanoid } from 'nanoid';
import User from '../models/User.js';
import Transaction from '../models/Transaction.js';

// Create a new user with a wallet
export const createUser = async (req, res) => {
  try {
    const { username, name, initialBalance = 1000 } = req.body;

    // Validation
    if (!username || !name) {
      return res.status(400).json({
        success: false,
        error: 'Username and name are required'
      });
    }

    // Check if username already exists
    const existingUser = await User.findOne({ username });
    if (existingUser) {
      return res.status(400).json({
        success: false,
        error: 'Username already exists'
      });
    }

    // Generate unique IDs
    const userId = `USER_${nanoid(12)}`;
    const walletId = `WALLET_${nanoid(12)}`;

    // Create user
    const user = new User({
      userId,
      username,
      name,
      walletId,
      balance: initialBalance
    });

    await user.save();

    // Create initial balance transaction (simulated topup)
    if (initialBalance > 0) {
      const transaction = new Transaction({
        transactionId: `TXN_${nanoid(16)}`,
        senderId: 'SYSTEM',
        receiverId: userId,
        senderWalletId: 'SYSTEM',
        receiverWalletId: walletId,
        amount: initialBalance,
        type: 'TOPUP',
        status: 'CONFIRMED',
        description: 'Initial simulated balance',
        timestamp: new Date()
      });

      await transaction.save();
    }

    res.status(201).json({
      success: true,
      message: 'User created successfully',
      data: {
        userId: user.userId,
        username: user.username,
        name: user.name,
        walletId: user.walletId,
        balance: user.balance
      }
    });

  } catch (error) {
    console.error('Create user error:', error);
    res.status(500).json({
      success: false,
      error: 'Internal server error'
    });
  }
};

// Get user by userId or walletId
export const getUser = async (req, res) => {
  try {
    const { id } = req.params;

    const user = await User.findOne({
      $or: [{ userId: id }, { walletId: id }]
    });

    if (!user) {
      return res.status(404).json({
        success: false,
        error: 'User not found'
      });
    }

    res.status(200).json({
      success: true,
      data: {
        userId: user.userId,
        username: user.username,
        name: user.name,
        walletId: user.walletId,
        balance: user.balance,
        publicKey: user.publicKey,
        createdAt: user.createdAt
      }
    });

  } catch (error) {
    console.error('Get user error:', error);
    res.status(500).json({
      success: false,
      error: 'Internal server error'
    });
  }
};

// Get all users (for demo purposes)
export const getAllUsers = async (req, res) => {
  try {
    const users = await User.find()
      .select('-transactionPinHash -__v')
      .sort({ createdAt: -1 });

    res.status(200).json({
      success: true,
      count: users.length,
      data: users
    });

  } catch (error) {
    console.error('Get all users error:', error);
    res.status(500).json({
      success: false,
      error: 'Internal server error'
    });
  }
};

// Add simulated money to wallet (for demo/development only)
export const addSimulatedBalance = async (req, res) => {
  try {
    const { id } = req.params;
    const { amount } = req.body;

    if (!amount || amount <= 0) {
      return res.status(400).json({
        success: false,
        error: 'Valid amount is required'
      });
    }

    const user = await User.findOne({
      $or: [{ userId: id }, { walletId: id }]
    });

    if (!user) {
      return res.status(404).json({
        success: false,
        error: 'User not found'
      });
    }

    // Update balance
    user.balance += amount;
    await user.save();

    // Create topup transaction
    const transaction = new Transaction({
      transactionId: `TXN_${nanoid(16)}`,
      senderId: 'SYSTEM',
      receiverId: user.userId,
      senderWalletId: 'SYSTEM',
      receiverWalletId: user.walletId,
      amount: amount,
      type: 'TOPUP',
      status: 'CONFIRMED',
      description: 'Simulated balance topup',
      timestamp: new Date()
    });

    await transaction.save();

    res.status(200).json({
      success: true,
      message: `Added ₹${amount} to wallet`,
      data: {
        userId: user.userId,
        walletId: user.walletId,
        newBalance: user.balance,
        transactionId: transaction.transactionId
      }
    });

  } catch (error) {
    console.error('Add balance error:', error);
    res.status(500).json({
      success: false,
      error: 'Internal server error'
    });
  }
};
