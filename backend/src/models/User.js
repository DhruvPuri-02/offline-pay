import mongoose from 'mongoose';

const userSchema = new mongoose.Schema({
  userId: {
    type: String,
    required: true,
    unique: true,
    index: true
  },
  username: {
    type: String,
    required: true,
    unique: true,
    trim: true,
    minlength: 3,
    maxlength: 30
  },
  name: {
    type: String,
    required: true,
    trim: true
  },
  walletId: {
    type: String,
    required: true,
    unique: true,
    index: true
  },
  balance: {
    type: Number,
    required: true,
    default: 0,
    min: 0
  },
  // Public key for cryptographic verification (Phase 5)
  publicKey: {
    type: String,
    default: null
  },
  // Transaction PIN hash (Phase 4)
  transactionPinHash: {
    type: String,
    default: null
  },
  createdAt: {
    type: Date,
    default: Date.now
  },
  updatedAt: {
    type: Date,
    default: Date.now
  }
}, {
  timestamps: true
});

// NOTE: userId and walletId already declare `index: true` above, so adding
// userSchema.index() here again would duplicate them (mongoose warns and
// drops one definition). Only add extra compound/secondary indexes below.

const User = mongoose.model('User', userSchema);

export default User;
