import express from 'express';
import cors from 'cors';
import dotenv from 'dotenv';
import connectDB from './config/database.js';
import userRoutes from './routes/userRoutes.js';
import transactionRoutes from './routes/transactionRoutes.js';
import qrRoutes from './routes/qrRoutes.js';

// Load environment variables
dotenv.config();

const app = express();
const PORT = process.env.PORT || 5000;

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
    phase: 'Phase 2 - QR Payment System',
    warning: '⚠️ SIMULATED MONEY ONLY - Educational Project',
    timestamp: new Date().toISOString()
  });
});

// API routes
app.use('/api/users', userRoutes);
app.use('/api/transactions', transactionRoutes);
app.use('/api/qr', qrRoutes);

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

// Start server
const startServer = async () => {
  try {
    // Connect to MongoDB
    await connectDB();

    // Start listening
    app.listen(PORT, () => {
      console.log('');
      console.log('═════════════════════════════════════════════════════════');
      console.log('🚀 OfflinePay Backend Server');
      console.log('═════════════════════════════════════════════════════════');
      console.log(`📍 Server: http://localhost:${PORT}`);
      console.log(`🌍 Environment: ${process.env.NODE_ENV || 'development'}`);
      console.log(`⚠️  SIMULATED MONEY ONLY - Educational Project`);
      console.log('═════════════════════════════════════════════════════════');
      console.log('');
      console.log('📚 Available Endpoints:');
      console.log(`   GET    /                          - Health check`);
      console.log(`   POST   /api/users                 - Create user`);
      console.log(`   GET    /api/users                 - Get all users`);
      console.log(`   GET    /api/users/:id             - Get user by ID`);
      console.log(`   POST   /api/users/:id/topup       - Add simulated balance`);
      console.log(`   POST   /api/transactions/transfer - Create transfer`);
      console.log(`   GET    /api/transactions/user/:id - Get transaction history`);
      console.log(`   GET    /api/transactions/:txnId   - Get transaction details`);
      console.log(`   POST   /api/qr/generate/:id       - Generate payment QR`);
      console.log(`   POST   /api/qr/verify             - Verify QR payload`);
      console.log(`   POST   /api/qr/pay                - Process QR payment`);
      console.log('');
    });

  } catch (error) {
    console.error('Failed to start server:', error);
    process.exit(1);
  }
};

startServer();
