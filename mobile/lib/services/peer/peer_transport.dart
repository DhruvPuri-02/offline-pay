/// Phase 8: carriers for the two-message protocol.
///
/// Everything in Phases 2-7 travels as two JSON documents (the same ones
/// the QR screens exchange - see `models/qr_message.dart`):
///
///   PAYMENT_REQUEST   receiver -> payer    ("pay me ₹X")
///   TRANSACTION_RECEIPT payer -> receiver  ("here is the signed proof")
///
/// A "carrier" is anything that moves one of those documents between two
/// devices. QR (camera + paste) is the reference carrier and stays the
/// default: it needs no radio, no pairing, no permissions. Phase 8 adds
/// cable-free carriers behind this seam:
///
///   lan_peer.dart     Wi-Fi LAN host/fetch    - fully implemented AND tested
///   nearby_peer.dart  Bluetooth/Wi-Fi direct  - service-level, hardware-unverified
///   nfc_peer.dart     NFC tap exchange        - service-level, hardware-unverified
///
/// Every carrier carries the SAME bytes and gets the SAME trust
/// treatment as QR: a received message is only believed after its
/// signature check and the user's explicit confirmation (scan_qr_screen /
/// record_payment_screen). Changing the pipe never changes the security
/// model - that is the whole point of the seam.
library;

/// Thrown when a carrier cannot move a message (unreachable host,
/// permission denied, radio off, unsupported hardware, ...).
///
/// [reason] is written for the end user and is shown verbatim in the UI.
class PeerTransportException implements Exception {
  const PeerTransportException(this.reason);

  final String reason;

  @override
  String toString() => reason;
}

/// An address another device is reachable at on the LAN, written the way
/// a human reads it: `192.168.1.5:48231` (host + port, split on the LAST
/// colon so IPv6 literals like `[fe80::1]:48231` still parse).
class LanTarget {
  const LanTarget(this.host, this.port);

  /// Parses `host:port`. Throws [PeerTransportException] with a
  /// human-readable reason instead of a FormatException.
  factory LanTarget.parse(String address) {
    final trimmed = address.trim();
    final separator = trimmed.lastIndexOf(':');
    if (separator <= 0 || separator == trimmed.length - 1) {
      throw const PeerTransportException(
        'Address must look like 192.168.1.5:48231 (IP address, colon, port).',
      );
    }
    final host = trimmed.substring(0, separator);
    final port = int.tryParse(trimmed.substring(separator + 1));
    if (port == null || port < 1 || port > 65535) {
      throw const PeerTransportException(
        'Port must be a number between 1 and 65535.',
      );
    }
    return LanTarget(host, port);
  }

  final String host;
  final int port;

  @override
  String toString() => '$host:$port';
}
