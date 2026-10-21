import mongoose from 'mongoose';
import dotenv from 'dotenv';

dotenv.config();

// Holds the in-memory MongoDB instance (if we started one) so it can be
// shut down cleanly when the process exits.
let memoryServer = null;

/**
 * Connect to the database.
 *
 * Two modes:
 *
 * 1. MONGODB_URI is set  -> use your real MongoDB (persistent data).
 * 2. MONGODB_URI is empty -> start an in-memory MongoDB (mongodb-memory-server).
 *
 * The in-memory mode exists so a student can run the whole backend with
 * ZERO manual setup: no MongoDB installer, no service configuration.
 * The trade-off: data is thrown away every time the server stops.
 */
const connectDB = async () => {
  const configuredUri = process.env.MONGODB_URI;
  const useMemory = process.env.USE_MEMORY_DB === 'true' || !configuredUri;

  try {
    if (useMemory) {
      // Imported lazily so production setups that point at a real MongoDB
      // never pay the cost of loading the memory-server package.
      const { MongoMemoryServer } = await import('mongodb-memory-server');

      memoryServer = await MongoMemoryServer.create();
      const uri = memoryServer.getUri('offlinepay');

      await mongoose.connect(uri);

      console.log('✅ MongoDB Connected: in-memory (mongodb-memory-server)');
      console.log('📦 Database: offlinepay (ephemeral - data is lost on restart)');
      console.log('ℹ️  Set MONGODB_URI in backend/.env to use a real MongoDB.');
      return;
    }

    const conn = await mongoose.connect(configuredUri);
    console.log(`✅ MongoDB Connected: ${conn.connection.host}`);
    console.log(`📦 Database: ${conn.connection.name}`);
  } catch (error) {
    console.error(`❌ MongoDB Connection Error: ${error.message}`);
    console.log('⚠️  Either fix MONGODB_URI or delete it to fall back to the in-memory database.');
    process.exit(1);
  }
};

/**
 * Close the mongoose connection and stop the in-memory server (if any).
 * Used by tests and by the graceful-shutdown handler in server.js.
 */
const disconnectDB = async () => {
  await mongoose.disconnect();
  if (memoryServer) {
    await memoryServer.stop();
    memoryServer = null;
  }
};

export { disconnectDB };
export default connectDB;
