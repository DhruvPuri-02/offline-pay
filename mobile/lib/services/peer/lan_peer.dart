import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'peer_transport.dart';

/// Phase 8: move the two protocol messages over a plain Wi-Fi LAN -
/// "direct device pairing" with no server and no cloud involved.
///
/// How it works (deliberately boring tech - a tiny HTTP server on the
/// receiving phone):
///
///   RECEIVER (has the request)          PAYER (wants the request)
///   ------------------------            --------------------------
///   LanPeerHost.start(requestJson)      LanPeerClient.fetchRequest(ip:port)
///     GET /request  ---------------------------------->  returns the JSON
///
///   (payment happens offline on the payer, exactly like QR)
///
///   RECEIPT arrives on the host via POST /receipt  <------- sendReceipt(json)
///
/// Why HTTP and not a hand-rolled socket protocol: framing, timeouts and
/// malformed input are solved problems here - a hostile or buggy client
/// cannot desynchronise us with a half-written message, because every
/// request has a Content-Length and a defined end. That matters: this
/// server accepts connections from ANY device on the local network.
///
/// Trust model (identical to QR, see OFFLINE_FIRST.md section 10): the
/// request JSON is the same information the QR code shows in public, and
/// no PIN or secret ever crosses this channel. Receipts that arrive here
/// are NOT auto-recorded - they land in [ReceiptInbox] and go through the
/// same signature verification + user confirmation as a scanned QR.
class LanPeerHost {
  HttpServer? _server;
  String? _requestJson;
  void Function(String receiptJson)? _onReceipt;

  /// True while the server is listening.
  bool get isServing => _server != null;

  /// The port the host bound to (ephemeral unless [port] given).
  int? get port => _server?.port;

  /// Starts serving [requestJson] to anyone on the LAN.
  ///
  /// [onReceipt] fires (with the raw receipt JSON) for every well-formed
  /// receipt POSTed to us; garbage bodies are answered 400 and ignored.
  /// Calling start() again replaces the served request and restarts.
  Future<void> start({
    required String requestJson,
    int? port,
    void Function(String receiptJson)? onReceipt,
  }) async {
    await stop();
    // The served body must be a protocol message, not arbitrary text -
    // refuse to start with something we could not have shown as a QR.
    final decoded = jsonDecode(requestJson);
    if (decoded is! Map<String, dynamic>) {
      throw const PeerTransportException(
        'Request to serve must be a JSON object.',
      );
    }
    _requestJson = requestJson;
    _onReceipt = onReceipt;
    final server = await HttpServer.bind(InternetAddress.anyIPv4, port ?? 0);
    _server = server;
    server.listen(
      (request) => unawaited(_handle(request)),
      onError: (_) {}, // a client vanishing mid-request is normal here
      cancelOnError: true,
    );
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.method == 'GET' && request.uri.path == '/request') {
        request.response.headers.contentType = ContentType.json;
        request.response.write(_requestJson);
      } else if (request.method == 'POST' && request.uri.path == '/receipt') {
        final body = await utf8.decodeStream(request);
        final decoded = jsonDecode(body); // throws on garbage -> 400 below
        if (decoded is! Map<String, dynamic>) {
          request.response.statusCode = HttpStatus.badRequest;
          request.response
              .write(jsonEncode({'ok': false, 'error': 'not a JSON object'}));
        } else {
          _onReceipt?.call(body);
          request.response.write(jsonEncode({'ok': true}));
        }
      } else {
        request.response.statusCode = HttpStatus.notFound;
        request.response.write(jsonEncode({'ok': false, 'error': 'unknown'}));
      }
    } on FormatException {
      request.response.statusCode = HttpStatus.badRequest;
      request.response
          .write(jsonEncode({'ok': false, 'error': 'malformed JSON'}));
    } catch (_) {
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.write(jsonEncode({'ok': false, 'error': 'server'}));
    } finally {
      await request.response.close();
    }
  }

  /// The address to type on the other device, e.g. `192.168.1.5:48231`.
  ///
  /// Best effort: picks the first non-loopback IPv4 of this device. On a
  /// phone hotspot or normal Wi-Fi that is the address the payer can
  /// reach; in an emulator the host machine's network layout decides.
  /// Returns null when no candidate exists (still serving, we just have
  /// nothing to show - the payer can be told the port and use the
  /// device's known IP).
  Future<String?> addressLabel() async {
    final boundPort = port;
    if (boundPort == null) return null;
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (!address.isLoopback) return '${address.address}:$boundPort';
        }
      }
    } catch (_) {
      // Interface listing can fail on restricted platforms; fall through.
    }
    return null;
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _requestJson = null;
    _onReceipt = null;
    if (server != null) await server.close(force: true);
  }
}

/// The payer side of the LAN carrier: fetch the served request, later
/// push the receipt back. Stateless - each call is its own short-lived
/// HTTP exchange, so a payer that walks away mid-payment leaves no
/// half-open connection on either device.
class LanPeerClient {
  /// Fetches the payment request JSON from a [LanPeerHost].
  ///
  /// Throws [PeerTransportException] with a human-readable reason
  /// (wrong address, host gone, timeout, or a hostile server returning
  /// something that is not a JSON object).
  Future<String> fetchRequest(
    LanTarget target, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final response = await _get(target, '/request', timeout);
    try {
      _requireJsonObject(response);
    } on FormatException {
      throw const PeerTransportException(
        'The nearby device sent something that is not valid JSON.',
      );
    }
    return response;
  }

  /// Posts the signed receipt JSON to a [LanPeerHost].
  Future<void> sendReceipt(
    LanTarget target,
    String receiptJson, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    try {
      _requireJsonObject(receiptJson);
    } on FormatException {
      throw const PeerTransportException(
        'Receipt must be a JSON object.',
      );
    }
    final client = _httpClient(timeout);
    try {
      final request = await client.postUrl(
        Uri(scheme: 'http', host: target.host, port: target.port, path: '/receipt'),
      );
      request.headers.contentType = ContentType.json;
      request.write(receiptJson);
      final response = await request.close().timeout(timeout);
      await response.drain<void>();
      if (response.statusCode != HttpStatus.ok) {
        throw PeerTransportException(
          'The nearby device refused the receipt (HTTP ${response.statusCode}).',
        );
      }
    } on PeerTransportException {
      rethrow;
    } catch (error) {
      throw _friendly(target, error);
    } finally {
      client.close(force: true);
    }
  }

  Future<String> _get(
    LanTarget target,
    String path,
    Duration timeout,
  ) async {
    final client = _httpClient(timeout);
    try {
      final request = await client.getUrl(
        Uri(scheme: 'http', host: target.host, port: target.port, path: path),
      );
      final response = await request.close().timeout(timeout);
      final body = await utf8.decodeStream(response).timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        throw PeerTransportException(
          'The nearby device answered HTTP ${response.statusCode}.',
        );
      }
      return body;
    } catch (error) {
      throw _friendly(target, error);
    } finally {
      client.close(force: true);
    }
  }

  HttpClient _httpClient(Duration timeout) => HttpClient()
    ..connectionTimeout = timeout
    ..idleTimeout = timeout;

  void _requireJsonObject(String json) {
    if (jsonDecode(json) is! Map<String, dynamic>) {
      throw const PeerTransportException(
        'Expected a JSON object from the nearby device.',
      );
    }
  }

  PeerTransportException _friendly(LanTarget target, Object error) {
    if (error is PeerTransportException) return error;
    if (error is TimeoutException) {
      return PeerTransportException(
        'The nearby device at $target did not answer in time.',
      );
    }
    if (error is SocketException || error is HttpException) {
      return PeerTransportException(
        'Could not reach $target - check both devices are on the same '
        'Wi-Fi and the other device is still showing its request.',
      );
    }
    if (error is FormatException) {
      return const PeerTransportException(
        'The nearby device sent something that is not valid JSON.',
      );
    }
    return PeerTransportException('Nearby transfer failed: $error');
  }
}
