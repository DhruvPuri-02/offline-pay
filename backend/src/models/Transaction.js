import mongoose from 'mongoose';

const transactionSchema = new mongoose.Schema({
  transactionId: {
    type: String,
    required: true,
    unique: true,
    index: true
  },
  senderId: {
    type: String,
    required: true,
    index: true
  },
  receiverId: {
    type: String,
    required: true,
    index: true
  },
  senderWalletId: {
    type: String,
    required: true
  },
  receiverWalletId: {
    type: String,
    required: true
  },
  amount: {
    type: Number,
    required: true,
    min: 0.01
  },
  type: {
    type: String,
    enum: ['TOPUP', 'DIRECT_TRANSFER', 'OFFLINE_PAYMENT'],
    default: 'DIRECT_TRANSFER'
  },
  status: {
    type: String,
    enum: ['PENDING_SYNC', 'SYNCING', 'CONFIRMED', 'REJECTED', 'CONFLICT'],
    default: 'CONFIRMED'
  },
  description: {
    type: String,
    default: 'Simulated Payment'
  },
  nonce: {
    type: String,
    default: null
  },
  senderPublicKey: {
    type: String,
    default: null
  },
  signature: {
    type: String,
    default: null
  },
  rejectionReason: {
    type: String,
    default: null
  },
  timestamp: {
    type: Date,
    default: Date.now,
    index: true
  }
}, {
  timestamps: true
});

// Compound indexes for user transaction history queries
transactionSchema.index({ senderId: 1, timestamp: -1 });
transactionSchema.index({ receiverId: 1, timestamp: -1 });
transactionSchema.index({ senderWalletId: 1, timestamp: -1 });
transactionSchema.index({ receiverWalletId: 1, timestamp: -1 });

const Transaction = mongoose.model('Transaction', transactionSchema);

export default Transaction;
