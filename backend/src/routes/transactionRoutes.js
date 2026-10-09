import express from 'express';
import {
  getTransactionHistory,
  createTransfer,
  getTransaction
} from '../controllers/transactionController.js';

const router = express.Router();

// Transaction routes
router.post('/transfer', createTransfer);
router.get('/user/:id', getTransactionHistory);
router.get('/:transactionId', getTransaction);

export default router;
