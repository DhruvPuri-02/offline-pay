import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:offlinepay/services/peer/lan_peer.dart';
import 'package:offlinepay/services/peer/peer_transport.dart';
import 'package:offlinepay/services/receipt_inbox.dart';

/// Phase 8: the LAN carrier is the one nearby channel this environment
/// can PROVE - these tests run a real host on a real socket and a real
/// client against it (loopback), exactly the code path two phones on one
/// Wi-Fi would take. BLE/NFC adapters cannot be executed here (no
/// Android hardware) and are covered by analyze only.
void main() {
  late LanPeerHost host;
  late String servedRequest;

  setUp(() {
    host = LanPeerHost();
    servedRequest = jsonEncode({
      'type': 'PAYMENT_REQUEST',
      'version': 1,
      'payload': {'amount': 250.0, 'description': 'LAN test'},
    });
  });

  tearDown(() async {
    await host.stop();
  });

  Future<LanTarget> startHost({void Function(String)? onReceipt}) async {
    await host.start(requestJson: servedRequest, onReceipt: onReceipt);
    return LanTarget('127.0.0.1', host.port!);
  }

  group('LAN request serving (receiver -> payer)', () {
    test('client fetches the exact request the host is serving', () async {
      final target = await startHost();
      final fetched = await LanPeerClient().fetchRequest(target);
      expect(fetched, servedRequest);
    });

    test('host can update the served request between payments', () async {
      await startHost();
      const replacement =
          '{"type":"PAYMENT_REQUEST","version":1,"payload":{"amount":99.0}}';
      await host.start(requestJson: replacement);
      // Restart rebinds (possibly to a new ephemeral port) - always read
      // the current one rather than assuming either outcome.
      final newTarget = LanTarget('127.0.0.1', host.port!);
      expect(await LanPeerClient().fetchRequest(newTarget), replacement);
    });

    test('host refuses to serve a non-object payload', () async {
      expect(
        () => host.start(requestJson: '"just a string"'),
        throwsA(isA<PeerTransportException>()),
      );
    });

    test('fetching from a dead port fails with a friendly error', () async {
      // Bind then immediately close to get a port that is certainly free.
      final probe = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = probe.port;
      await probe.close(force: true);

      expect(
        () => LanPeerClient().fetchRequest(LanTarget('127.0.0.1', deadPort)),
        throwsA(
          isA<PeerTransportException>().having(
            (e) => e.reason,
            'reason mentions reaching the device',
            contains('Could not reach'),
          ),
        ),
      );
    });

    test('a hostile server returning non-JSON is rejected on fetch', () async {
      final evil = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      evil.listen((request) {
        request.response.write('<html>not json</html>');
        request.response.close();
      });
      addTearDown(() => evil.close(force: true));

      expect(
        () => LanPeerClient().fetchRequest(LanTarget('127.0.0.1', evil.port)),
        throwsA(isA<PeerTransportException>()),
      );
    });
  });

  group('LAN receipt return (payer -> receiver)', () {
    test('receipt round-trips to the host callback byte-for-byte', () async {
      String? received;
      final target = await startHost(onReceipt: (json) => received = json);

      const receipt =
          '{"type":"TRANSACTION_RECEIPT","version":1,"payload":{"amount":250.0,"signature":"abc+/="}}';
      await LanPeerClient().sendReceipt(target, receipt);

      expect(received, receipt);
    });

    test('host answers 400 to a garbage receipt and never calls back',
        () async {
      var callbackFired = false;
      final target =
          await startHost(onReceipt: (_) => callbackFired = true);

      final client = HttpClient();
      final request = await client.postUrl(Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: target.port,
        path: '/receipt',
      ));
      request.write('this is not json at all {');
      final response = await request.close();
      await response.drain<void>();
      client.close(force: true);

      expect(response.statusCode, HttpStatus.badRequest);
      expect(callbackFired, isFalse);
    });

    test('client refuses to send a non-object receipt', () async {
      final target = await startHost();
      expect(
        () => LanPeerClient().sendReceipt(target, '[1,2,3]'),
        throwsA(isA<PeerTransportException>()),
      );
    });

    test('unknown paths answer 404 (no accidental endpoints)', () async {
      final target = await startHost();
      final client = HttpClient();
      final request = await client.getUrl(Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: target.port,
        path: '/admin',
      ));
      final response = await request.close();
      await response.drain<void>();
      client.close(force: true);
      expect(response.statusCode, HttpStatus.notFound);
    });

    test('after stop() the host is unreachable', () async {
      final target = await startHost();
      await host.stop();
      expect(host.isServing, isFalse);
      expect(
        () => LanPeerClient().fetchRequest(target),
        throwsA(isA<PeerTransportException>()),
      );
    });
  });

  group('address label', () {
    test('label carries the bound port when an interface exists', () async {
      await startHost();
      final label = await host.addressLabel();
      if (label != null) {
        expect(label, endsWith(':${host.port}'));
        expect(LanTarget.parse(label).port, host.port);
      }
    });

    test('no label while not serving', () async {
      expect(await host.addressLabel(), isNull);
    });
  });

  group('LanTarget.parse', () {
    test('parses host:port on the last colon', () {
      final target = LanTarget.parse('192.168.1.5:48231');
      expect(target.host, '192.168.1.5');
      expect(target.port, 48231);
      expect(target.toString(), '192.168.1.5:48231');
    });

    test('rejects addresses without a port, with clear reasons', () {
      for (final bad in ['192.168.1.5', ':80', '192.168.1.5:', 'abc']) {
        expect(
          () => LanTarget.parse(bad),
          throwsA(isA<PeerTransportException>()),
          reason: 'should reject: $bad',
        );
      }
    });

    test('rejects out-of-range and non-numeric ports', () {
      for (final bad in ['1.2.3.4:0', '1.2.3.4:70000', '1.2.3.4:ssh']) {
        expect(
          () => LanTarget.parse(bad),
          throwsA(isA<PeerTransportException>()),
          reason: 'should reject: $bad',
        );
      }
    });
  });

  group('ReceiptInbox', () {
    test('queues receipts in order and takes them once', () {
      final inbox = ReceiptInbox.forTest();
      inbox.add('r1');
      inbox.add('r2');
      expect(inbox.length, 2);
      expect(inbox.take(), 'r1');
      expect(inbox.take(), 'r2');
      expect(inbox.take(), isNull);
      expect(inbox.length, 0);
    });

    test('events fire live; claim() removes an already-seen receipt', () async {
      final inbox = ReceiptInbox.forTest();
      final seen = <String>[];
      final sub = inbox.events.listen(seen.add);

      inbox.add('live');
      await Future<void>.delayed(Duration.zero);
      expect(seen, ['live']);

      // A screen that handled it via the stream claims it so take() will
      // not hand it out a second time.
      inbox.claim('live');
      expect(inbox.take(), isNull);
      await sub.cancel();
    });
  });
}
