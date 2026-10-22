import express from 'express';
import { pushTransactions, pullTransactions } from '../controllers/syncController.js';

const router = express.Router();

// Phase 6: offline sync. Devices upload their PENDING_SYNC queue and pull
// whatever the server already knows (see syncController.js for semantics).
router.post('/push', pushTransactions);
router.post('/pull', pullTransactions);

export default router;
