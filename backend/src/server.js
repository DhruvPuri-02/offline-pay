import dotenv from 'dotenv';
import connectDB, { disconnectDB } from './config/database.js';
import app from './app.js';

// Load environment variables
dotenv.config();

const PORT = process.env.PORT || 5000;

// Start server
const startServer = async () => {
  try {
    // Connect to MongoDB
    await connectDB();

    // Capture the server handle so we can close it cleanly on exit.
    const server = app.listen(PORT, () => {
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
      console.log(`   POST   /api/sync/push             - Upload PENDING_SYNC batch (Phase 6)`);
      console.log(`   POST   /api/sync/pull             - Pull server-side ledger (Phase 6)`);
      console.log('');
    });

    // Graceful shutdown: stop accepting requests, then close MongoDB (and the
    // in-memory server, if one is running - otherwise its process lingers).
    const shutdown = async () => {
      console.log('\n⏳ Shutting down...');
      server.close(async () => {
        await disconnectDB();
        process.exit(0);
      });
      // Failsafe if a request hangs the close.
      setTimeout(() => process.exit(0), 5000).unref();
    };

    process.on('SIGINT', shutdown);
    process.on('SIGTERM', shutdown);

  } catch (error) {
    console.error('Failed to start server:', error);
    process.exit(1);
  }
};

startServer();
