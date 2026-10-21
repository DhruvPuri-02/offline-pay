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
    default: null,
    index: true
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

// Replay protection at the database level.
//
// A *sparse* unique index would NOT work here: TOPUP transactions store an
// explicit `nonce: null` (not a missing field), and MongoDB's sparse index
// still indexes explicit nulls - so the second topup would collide with the
// first. A *partial* index avoids that: it only indexes nonces that are
// actually strings, so nulls are free but a repeated nonce raises E11000.
//
// Why we need this at all: the findOne({nonce}) check in the controllers has
// a race window - two concurrent uploads of the same transaction can both
// pass the check. This index closes that window.
transactionSchema.index(
  { nonce: 1 },
  { unique: true, partialFilterExpression: { nonce: { $type: 'string' } } }
);

const Transaction = mongoose.model('Transaction', transactionSchema);

export default Transaction;
