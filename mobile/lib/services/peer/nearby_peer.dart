import 'dart:async';
import 'dart:convert';

import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';

import 'peer_transport.dart';

/// Phase 8: "Bluetooth payment transfer" - phone-to-phone exchange of the
/// same two protocol messages over Google's Nearby Connections API,
/// which uses BLE for discovery/handshake and BLE or Wi-Fi Direct for
/// the payload, with no server and no internet.
///
/// ---------------------------------------------------------------------------
/// HONEST STATUS: API-verified, HARDWARE-UNVERIFIED.
/// This adapter is written against the installed plugin's real API
/// (nearby_connections 4.3.0, checked against its source) and passes
/// `flutter analyze`, but it has NEVER been executed: this project was
/// built on a machine with no Android SDK and no physical device.
/// Treat it as reviewed scaffolding, not a working feature - the working,
/// TESTED nearby channel in this app is the LAN one (lan_peer.dart).
/// ---------------------------------------------------------------------------
///
/// Why Nearby Connections instead of flutter_blue_plus: BLE transfer needs
/// BOTH roles - one phone must advertise/serve (peripheral/GATT-server)
/// and one must discover/read (central). flutter_blue_plus 2.x is
/// central-only (verified against its source: it exposes scan + GATT
/// client, no advertising or GATT server), so phone-to-phone could never
/// complete with it. Nearby Connections provides both roles in one API
/// and handles the transport (BLE/Wi-Fi) itself.
///
/// Protocol mapping (identical bytes to the QR carrier):
///
///   payer discovers -> connects; host accepts and immediately sends the
///   PAYMENT_REQUEST bytes; payer pays offline; payer sends the signed
///   TRANSACTION_RECEIPT bytes back over the same endpoint.
///
/// Only ONE session per side exists at a time (the plugin's callbacks are
/// global) - the app starts a host while receiving, and one fetch while
/// paying, never both at once. Same trust model as every other carrier:
/// the request is public information (no PIN ever crosses this channel)
/// and an arriving receipt is only recorded after signature verification
/// + user confirmation in RecordPaymentScreen.
class NearbyHost {
  static const serviceId = 'offlinepay.sync';

  final Nearby _nearby = Nearby();
  String? _servedRequest;
  void Function(String receiptJson)? _onReceipt;

  /// True while advertising.
  bool get isServing => _serving;
  bool _serving = false;

  /// Starts advertising [nickname] and serves [requestJson] to the first
  /// payer that connects; receipts arrive through [onReceipt].
  Future<void> start({
    required String nickname,
    required String requestJson,
    void Function(String receiptJson)? onReceipt,
  }) async {
    final decoded = jsonDecode(requestJson);
    if (decoded is! Map<String, dynamic>) {
      throw const PeerTransportException(
        'Request to serve must be a JSON object.',
      );
    }
    await _ensureNearbyPermissions(advertise: true);
    _servedRequest = requestJson;
    _onReceipt = onReceipt;

    final ok = await _nearby.startAdvertising(
      nickname,
      Strategy.P2P_POINT_TO_POINT,
      serviceId: serviceId,
      onConnectionInitiated: (endpointId, info) async {
        await _nearby.acceptConnection(
          endpointId,
          onPayLoadRecieved: (id, payload) {
            if (payload.type == PayloadType.BYTES && payload.bytes != null) {
              _onReceipt?.call(
                utf8.decode(payload.bytes!, allowMalformed: true),
              );
            }
          },
        );
        // The payer connected: hand over the request right away.
        await _nearby.sendBytesPayload(
          endpointId,
          utf8.encode(_servedRequest ?? ''),
        );
      },
      onConnectionResult: (endpointId, status) {
        if (status != Status.CONNECTED) _serving = false;
      },
      onDisconnected: (endpointId) {
        _serving = false;
      },
    );
    if (!ok) {
      throw const PeerTransportException(
        'Bluetooth advertising could not start - is Bluetooth on?',
      );
    }
    _serving = true;
  }

  Future<void> stop() async {
    _serving = false;
    _servedRequest = null;
    _onReceipt = null;
    await _nearby.stopAdvertising();
    await _nearby.stopAllEndpoints();
  }
}

/// The payer side: discover the receiver's phone, receive the request
/// over the connection, and (after paying) push the receipt back on the
/// same endpoint.
class NearbyClient {
  final Nearby _nearby = Nearby();
  String? _endpointId;

  /// Discovers the nearest OfflinePay host, connects, and returns the
  /// request JSON it serves. Stops discovery at the first match.
  ///
  /// Throws [PeerTransportException] (no device found within [timeout],
  /// connection refused, permission denied).
  Future<String> fetchRequest({
    required String nickname,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    await _ensureNearbyPermissions(advertise: false, discover: true);
    final completer = Completer<String>();

    await _nearby.startDiscovery(
      nickname,
      Strategy.P2P_POINT_TO_POINT,
      serviceId: NearbyHost.serviceId,
      onEndpointFound: (endpointId, endpointName, serviceId) async {
        await _nearby.stopDiscovery();
        if (completer.isCompleted) return;
        await _nearby.requestConnection(
          nickname,
          endpointId,
          onConnectionInitiated: (id, info) async {
            await _nearby.acceptConnection(
              id,
              // (sic) the plugin's own parameter spelling.
              onPayLoadRecieved: (payloadId, payload) {
                if (payload.type == PayloadType.BYTES &&
                    payload.bytes != null &&
                    !completer.isCompleted) {
                  completer.complete(
                    utf8.decode(payload.bytes!, allowMalformed: true),
                  );
                }
              },
            );
          },
          onConnectionResult: (id, status) {
            if (status == Status.CONNECTED) {
              _endpointId = id;
            } else if (!completer.isCompleted) {
              completer.completeError(
                PeerTransportException(
                  'The nearby device ended the connection ($status).',
                ),
              );
            }
          },
          onDisconnected: (id) {
            if (_endpointId == id) _endpointId = null;
          },
        );
      },
      onEndpointLost: (endpointId) {},
    );

    try {
      final requestJson = await completer.future.timeout(timeout);
      _requireJsonObject(requestJson);
      return requestJson;
    } on TimeoutException {
      throw PeerTransportException(
        'No nearby device answered within ${timeout.inSeconds} seconds.',
      );
    } finally {
      await _nearby.stopDiscovery();
    }
  }

  /// Pushes the signed receipt back to the host we fetched from.
  Future<void> sendReceipt(String receiptJson) async {
    final endpointId = _endpointId;
    if (endpointId == null) {
      throw const PeerTransportException(
        'No nearby connection to send to - fetch the request again first.',
      );
    }
    _requireJsonObject(receiptJson);
    await _nearby.sendBytesPayload(endpointId, utf8.encode(receiptJson));
  }

  Future<void> close() async {
    final endpointId = _endpointId;
    _endpointId = null;
    if (endpointId != null) {
      await _nearby.disconnectFromEndpoint(endpointId);
    }
    await _nearby.stopAllEndpoints();
  }

  void _requireJsonObject(String json) {
    if (jsonDecode(json) is! Map<String, dynamic>) {
      throw const PeerTransportException(
        'Expected a JSON object from the nearby device.',
      );
    }
  }
}

/// Requests the Android runtime permissions Nearby Connections needs
/// (Bluetooth 12+ split permissions, location for the pre-12 scan path,
/// NEARBY_WIFI_DEVICES on 13+ for the Wi-Fi leg). Throws
/// [PeerTransportException] naming what was denied - a silent denial
/// would otherwise surface as an inexplicable "no devices found".
Future<void> _ensureNearbyPermissions({
  required bool advertise,
  bool discover = false,
}) async {
  final wanted = <Permission>[
    if (discover) Permission.bluetoothScan,
    if (advertise) Permission.bluetoothAdvertise,
    Permission.bluetoothConnect,
    Permission.locationWhenInUse,
    Permission.nearbyWifiDevices,
  ];
  final denied = <Permission>[];
  for (final permission in wanted) {
    if (await permission.isGranted) continue;
    await permission.request();
    if (!await permission.isGranted) denied.add(permission);
  }
  if (denied.isNotEmpty) {
    throw PeerTransportException(
      'Nearby transfer needs these permissions: '
      '${denied.map((p) => p.toString()).join(', ')} - '
      'grant them in system settings.',
    );
  }
}
