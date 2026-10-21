import 'package:bcrypt/bcrypt.dart';

/// Transaction-PIN policy and hashing (Phase 4).
///
/// What this PIN is for: authorising OUTGOING payments on this device.
/// It is NOT a login PIN - the app opens without any prompt (spec section 5).
///
/// Security rules enforced here:
///  * 4-6 digits (the amount a human can realistically enter on a phone)
///  * only a salted bcrypt hash is ever persisted; plaintext never reaches
///    storage, logs, the backend, or another device
///  * bcrypt's work factor makes each guess cost real CPU time
///  * after [maxFailedAttempts] wrong entries the wallet locks for
///    [lockoutDuration] (attempt tracking lives in the wallet database)
///
/// Hashing uses the established `bcrypt` package (a port of OpenBSD's
/// jBCrypt) - no cryptographic algorithms are implemented in this project.
class PinService {
  const PinService._();

  static const int minPinLength = 4;
  static const int maxPinLength = 6;

  /// Failed attempts allowed before the lockout kicks in.
  static const int maxFailedAttempts = 5;

  /// How long payments are locked after too many failed attempts.
  static const Duration lockoutDuration = Duration(seconds: 30);

  /// bcrypt log-rounds ("cost"). 10 is the library default: measured at
  /// ~80ms per hash on a desktop, a few hundred ms on a phone - noticeable
  /// enough to throttle guessing, fast enough to stay usable. The salt is
  /// random for every PIN, so identical PINs never share a hash.
  static const int bcryptLogRounds = 10;

  /// Returns `null` when the PIN is acceptable, otherwise a user-facing
  /// reason. Format problems are NOT counted as failed attempts - a typo
  /// in length is not a guess at someone else's PIN.
  static String? validateFormat(String pin) {
    if (pin.length < minPinLength || pin.length > maxPinLength) {
      return 'PIN must be $minPinLength to $maxPinLength digits.';
    }
    if (!RegExp(r'^[0-9]+$').hasMatch(pin)) {
      return 'PIN must contain digits only.';
    }
    return null;
  }

  /// Salted bcrypt hash of [pin]. The plaintext is not recoverable from it.
  static String hash(String pin) {
    return BCrypt.hashpw(pin, BCrypt.gensalt(logRounds: bcryptLogRounds));
  }

  /// Check [pin] against a stored hash.
  ///
  /// Returns `false` (never throws) for malformed/foreign hashes so a
  /// corrupted record fails closed instead of crashing a payment.
  static bool verify(String pin, String storedHash) {
    try {
      return BCrypt.checkpw(pin, storedHash);
    } catch (_) {
      return false;
    }
  }
}

/// The PIN-related columns of the wallet profile, read as one unit.
///
/// Deliberately a separate type instead of fields on the `User` model:
/// PIN material should never ride along in objects that get serialized
/// toward the backend. The PIN stays on this device, period.
class PinRecord {
  const PinRecord({this.hash, this.failedAttempts = 0, this.lockedUntil});

  /// `null` = no PIN configured yet (first payment will create one).
  final String? hash;

  /// Consecutive failed attempts since the last success.
  final int failedAttempts;

  /// While the current time is before this, payments are refused outright.
  final DateTime? lockedUntil;

  bool get isConfigured => hash != null;
}
