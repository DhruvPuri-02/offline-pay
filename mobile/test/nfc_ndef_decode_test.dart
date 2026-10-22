import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_manager/ndef_record.dart';
import 'package:offlinepay/services/peer/nfc_peer.dart';

/// Phase 8: the only part of the NFC carrier that can run without
/// hardware - decoding the standard NDEF Text record that both the HCE
/// plugin's Kotlin source emits (verified: createTextRecord, UTF-8, "en")
/// and ordinary tag writers produce. Everything else in nfc_peer.dart is
/// analyze-verified only, as documented in its header.
NdefRecord textRecord(String text, {String language = 'en'}) {
  final languageBytes = ascii.encode(language);
  final textBytes = utf8.encode(text);
  final payload = Uint8List(1 + languageBytes.length + textBytes.length);
  payload[0] = languageBytes.length & 0x3F;
  payload.setRange(1, 1 + languageBytes.length, languageBytes);
  payload.setRange(1 + languageBytes.length, payload.length, textBytes);
  return NdefRecord(
    typeNameFormat: TypeNameFormat.wellKnown,
    type: Uint8List.fromList(ascii.encode('T')),
    identifier: Uint8List(0),
    payload: payload,
  );
}

void main() {
  group('NDEF text record decoding', () {
    test('decodes a standard text record to its text', () {
      final record = textRecord('{"type":"PAYMENT_REQUEST"}');
      expect(readTextPayloadFromRecord(record), '{"type":"PAYMENT_REQUEST"}');
    });

    test('handles empty text and longer language codes', () {
      expect(readTextPayloadFromRecord(textRecord('')), '');
      expect(readTextPayloadFromRecord(textRecord('héllo', language: 'fr')), 'héllo');
    });

    test('refuses non-text records instead of guessing', () {
      // A URI record (well-known "U") - not part of this protocol.
      final uriRecord = NdefRecord(
        typeNameFormat: TypeNameFormat.wellKnown,
        type: Uint8List.fromList(ascii.encode('U')),
        identifier: Uint8List(0),
        payload: Uint8List.fromList([0x00]),
      );
      expect(readTextPayloadFromRecord(uriRecord), isNull);

      // A MIME record.
      final mimeRecord = NdefRecord(
        typeNameFormat: TypeNameFormat.media,
        type: Uint8List.fromList(ascii.encode('application/json')),
        identifier: Uint8List(0),
        payload: Uint8List.fromList(utf8.encode('{}')),
      );
      expect(readTextPayloadFromRecord(mimeRecord), isNull);
    });

    test('refuses a payload whose language length overruns it', () {
      final broken = NdefRecord(
        typeNameFormat: TypeNameFormat.wellKnown,
        type: Uint8List.fromList(ascii.encode('T')),
        identifier: Uint8List(0),
        payload: Uint8List.fromList([0x3F, 0x65]), // claims 63-byte language
      );
      expect(readTextPayloadFromRecord(broken), isNull);
    });

    test('refuses UTF-16 flagged records (we only speak UTF-8)', () {
      final utf16 = textRecord('hi');
      utf16.payload[0] |= 0x40;
      expect(readTextPayloadFromRecord(utf16), isNull);
    });
  });
}
