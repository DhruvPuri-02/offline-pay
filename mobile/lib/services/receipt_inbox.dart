import 'dart:async';

/// Phase 8: where receipts that arrive on a data carrier (LAN POST,
/// future Bluetooth/NFC) WAIT until the user records them.
///
/// Why an inbox instead of recording immediately: a receipt that arrives
/// over a cable-free carrier gets the exact same treatment as a scanned
/// QR - signature verification + the user's explicit confirmation in
/// `RecordPaymentScreen`. Nothing is written to the ledger by the
/// transport itself. The inbox is the parking lot between "bytes
/// arrived" and "user said yes".
///
/// Single consumer by design: `RecordPaymentScreen` takes from the queue
/// on open and listens to [events] for receipts that land while it is
/// already open. In-memory only: a receipt that is not recorded before
/// the app dies is simply fetched again (or re-shown as a QR) - the
/// payer's receipt screen still has it, and the sync channel (Phase 6)
/// carries the same transaction anyway.
class ReceiptInbox {
  ReceiptInbox._();

  /// App-wide instance the carriers write to. Tests use [forTest] so they
  /// never share state with the app singleton.
  static final ReceiptInbox instance = ReceiptInbox._();

  /// Fresh, unconnected instance for tests.
  ReceiptInbox.forTest();

  final List<String> _pending = [];
  final StreamController<String> _events = StreamController.broadcast();

  /// Number of receipts waiting to be recorded.
  int get length => _pending.length;

  /// Called by carriers when a receipt JSON arrives.
  void add(String receiptJson) {
    _pending.add(receiptJson);
    _events.add(receiptJson);
  }

  /// Removes and returns the oldest waiting receipt, or null.
  String? take() => _pending.isEmpty ? null : _pending.removeAt(0);

  /// Removes [receiptJson] from the queue if still present - used by a
  /// screen that claimed it through [events] so it is not handled twice.
  void claim(String receiptJson) {
    _pending.remove(receiptJson);
  }

  /// Fires for every receipt as it arrives (broadcast: no replay).
  Stream<String> get events => _events.stream;

  void clear() {
    _pending.clear();
  }
}
