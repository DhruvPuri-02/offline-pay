import express from 'express';
import {
  createUser,
  getUser,
  getAllUsers,
  addSimulatedBalance
} from '../controllers/userController.js';

const router = express.Router();

// User routes
router.post('/', createUser);
router.get('/', getAllUsers);
router.get('/:id', getUser);
router.post('/:id/topup', addSimulatedBalance);

export default router;
