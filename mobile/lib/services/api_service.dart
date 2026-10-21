import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/user.dart';
import '../models/transaction.dart';
import '../models/qr_payload.dart';

/// REST client for the backend.
///
/// IMPORTANT (Phase 3): nothing in the offline payment flow calls this.
/// Opening the wallet, paying and receiving all go through
/// `LocalDatabase` only - that is what makes the app work in airplane
/// mode. This class becomes active again in Phase 6 (synchronization),
/// when pending transactions are uploaded and reconciled.
class ApiService {
  // Change this to your computer's IP address when testing on physical device
  static const String baseUrl = 'http://localhost:5000/api';

  // User endpoints
  static Future<User> createUser(String username, String name, {double initialBalance = 1000}) async {
    final response = await http.post(
      Uri.parse('$baseUrl/users'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'username': username,
        'name': name,
        'initialBalance': initialBalance,
      }),
    );

    if (response.statusCode == 201) {
      final data = jsonDecode(response.body);
      return User.fromJson(data['data']);
    } else {
      throw Exception('Failed to create user: ${response.body}');
    }
  }

  static Future<User> getUser(String userId) async {
    final response = await http.get(
      Uri.parse('$baseUrl/users/$userId'),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return User.fromJson(data['data']);
    } else {
      throw Exception('Failed to get user: ${response.body}');
    }
  }

  static Future<void> addBalance(String userId, double amount) async {
    final response = await http.post(
      Uri.parse('$baseUrl/users/$userId/topup'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'amount': amount}),
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to add balance: ${response.body}');
    }
  }

  // Transaction endpoints
  static Future<List<Transaction>> getTransactionHistory(String userId) async {
    final response = await http.get(
      Uri.parse('$baseUrl/transactions/user/$userId'),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      final List<dynamic> transactionsJson = data['data'];
      return transactionsJson.map((json) => Transaction.fromJson(json)).toList();
    } else {
      throw Exception('Failed to get transaction history: ${response.body}');
    }
  }

  // QR Payment endpoints
  static Future<QRPayload> generatePaymentQR(String userId, double amount, String description) async {
    final response = await http.post(
      Uri.parse('$baseUrl/qr/generate/$userId'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'amount': amount,
        'description': description,
      }),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return QRPayload.fromJson(data['data']['qrPayload']);
    } else {
      throw Exception('Failed to generate QR: ${response.body}');
    }
  }

  static Future<Map<String, dynamic>> verifyQRPayload(String qrString) async {
    final response = await http.post(
      Uri.parse('$baseUrl/qr/verify'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'qrString': qrString}),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data['data'];
    } else {
      final errorData = jsonDecode(response.body);
      throw Exception(errorData['error'] ?? 'Failed to verify QR');
    }
  }

  static Future<Map<String, dynamic>> processOfflinePayment({
    required String senderId,
    required String receiverId,
    required String receiverWalletId,
    required double amount,
    required String description,
    required String nonce,
    required String timestamp,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/qr/pay'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'senderId': senderId,
        'receiverId': receiverId,
        'receiverWalletId': receiverWalletId,
        'amount': amount,
        'description': description,
        'nonce': nonce,
        'timestamp': timestamp,
      }),
    );

    if (response.statusCode == 201) {
      final data = jsonDecode(response.body);
      return data['data'];
    } else {
      final errorData = jsonDecode(response.body);
      throw Exception(errorData['error'] ?? 'Payment failed');
    }
  }
}
