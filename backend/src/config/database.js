import mongoose from 'mongoose';
import dotenv from 'dotenv';

dotenv.config();

const connectDB = async () => {
  try {
    const conn = await mongoose.connect(process.env.MONGODB_URI, {
      // Remove deprecated options - mongoose 6+ handles these automatically
    });

    console.log(`✅ MongoDB Connected: ${conn.connection.host}`);
    console.log(`📦 Database: ${conn.connection.name}`);
  } catch (error) {
    console.error(`❌ MongoDB Connection Error: ${error.message}`);
    console.log('⚠️  Make sure MongoDB is installed and running:');
    console.log('   Windows: Download from https://www.mongodb.com/try/download/community');
    console.log('   Start service: net start MongoDB');
    console.log('   Or run: mongod --dbpath ./data/db');
    process.exit(1);
  }
};

export default connectDB;
