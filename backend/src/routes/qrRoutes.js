import express from 'express';
import {
  generatePaymentQR,
  processOfflinePayment,
  verifyQRPayload
} from '../controllers/qrController.js';

const router = express.Router();

// QR code routes
router.post('/generate/:id', generatePaymentQR);
router.post('/verify', verifyQRPayload);
router.post('/pay', processOfflinePayment);

export default router;
