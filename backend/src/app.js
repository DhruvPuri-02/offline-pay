import express from 'express';
import cors from 'cors';
import userRoutes from './routes/userRoutes.js';
import transactionRoutes from './routes/transactionRoutes.js';
import qrRoutes from './routes/qrRoutes.js';
import syncRoutes from './routes/syncRoutes.js';

// The Express app, without the "listen" part.
//
// It lives in its own file so scripts (scripts/demo-phase6.js) and future
// test suites can boot the REAL endpoints against an in-memory MongoDB
// without starting the production server binary.

const app = express();

// Middleware
app.use(cors());
app.use(express.json());
app.use(express.urlencoded({ extended: true }));

// Request logging middleware
app.use((req, res, next) => {
  console.log(`${req.method} ${req.path}`);
  next();
});

// Health check endpoint
app.get('/', (req, res) => {
  res.json({
    service: 'OfflinePay Backend',
    version: '1.0.0',
    status: 'running',
    phase: 'Phase 6 - Offline Sync',
    warning: '⚠️ SIMULATED MONEY ONLY - Educational Project',
    timestamp: new Date().toISOString()
  });
});

// API routes
app.use('/api/users', userRoutes);
app.use('/api/transactions', transactionRoutes);
app.use('/api/qr', qrRoutes);
app.use('/api/sync', syncRoutes);

// 404 handler
app.use((req, res) => {
  res.status(404).json({
    success: false,
    error: 'Route not found'
  });
});

// Error handling middleware
app.use((err, req, res, next) => {
  console.error('Error:', err);
  res.status(500).json({
    success: false,
    error: 'Internal server error',
    message: process.env.NODE_ENV === 'development' ? err.message : undefined
  });
});

export default app;
