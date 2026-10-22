import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_nfc_hce/flutter_nfc_hce.dart';
import 'package:nfc_manager/ndef_record.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:nfc_manager/nfc_manager_android.dart';
import 'package:nfc_manager/nfc_manager_ios.dart';

import 'peer_transport.dart';

/// Phase 8: "NFC tap-to-pay" - exchange the two protocol messages by
/// tapping phones, no radio pairing and no network at all.
///
/// Mechanics (Android): one phone EMULATES an NDEF text message via host
/// card emulation (flutter_nfc_hce); the other READS it in a foreground
/// reader session (nfc_manager). Roles swap for the second message:
///
///   receiver emulates PAYMENT_REQUEST  ->  payer taps, reads, pays
///   payer emulates TRANSACTION_RECEIPT ->  receiver taps, reads, records
///
/// ---------------------------------------------------------------------------
/// HONEST STATUS: API-verified, HARDWARE-UNVERIFIED - and ANDROID-ONLY.
/// Written against the installed plugins' real APIs (flutter_nfc_hce
/// 0.1.8 - its Kotlin source confirms it emits a standard NDEF Text
/// record, which [readTextPayload] decodes; nfc_manager 4.2.1) and passes
/// `flutter analyze`, but never executed: this project was built with no
/// Android SDK and no physical device. iOS cannot emulate an NFC tag at
/// all (no HCE), so the emulate side is Android-only by design.
///
/// Sizes: our PAYMENT_REQUEST JSON (~300 bytes) is well within NDEF/HCE
/// limits; the signed TRANSACTION_RECEIPT (~700 bytes) should also fit
/// (the plugin's capability container advertises 65KB), but that path is
/// exactly the kind of thing only hardware can confirm - QR remains the
/// fallback carrier for anything that fails here.
///
/// Trust model: identical to every other carrier - the request carries no
/// secrets, and an arriving receipt is recorded only after signature
/// verification + user confirmation in RecordPaymentScreen.
class NfcCarrier {
  final FlutterNfcHce _hce = FlutterNfcHce();

  /// True while this device is emulating a message for a reader.
  bool get isEmulating => _emulating;
  bool _emulating = false;

  /// Emulates [content] (a protocol JSON message) for a reader to pick
  /// up by tapping this phone. Android only - iOS has no HCE.
  ///
  /// The plugin keeps emulating until [stopEmulating] is called - the
  /// caller owns the timeout (the UI can show it as a countdown).
  /// [persistMessage] stays false on purpose: a payment message must not
  /// be written to the plugin's internal storage file.
  Future<void> emulate(String content) async {
    if (!Platform.isAndroid) {
      throw const PeerTransportException(
        'Emulating NFC messages is Android-only in this prototype '
        '(iOS cannot emulate an NFC tag).',
      );
    }
    final decoded = jsonDecode(content);
    if (decoded is! Map<String, dynamic>) {
      throw const PeerTransportException(
        'Message to emulate must be a JSON object.',
      );
    }
    if (!await _hce.isNfcHceSupported()) {
      throw const PeerTransportException(
        'This device does not support NFC host card emulation.',
      );
    }
    if (!await _hce.isNfcEnabled()) {
      throw const PeerTransportException(
        'NFC is turned off - enable it in system settings and try again.',
      );
    }
    final result = await _hce.startNfcHce(
      content,
      mimeType: 'text/plain',
      persistMessage: false,
    );
    if (result != 'success') {
      throw const PeerTransportException('NFC emulation could not start.');
    }
    _emulating = true;
  }

  Future<void> stopEmulating() async {
    if (!_emulating) return;
    _emulating = false;
    await _hce.stopNfcHce();
  }

  /// Reads the next NDEF text payload from a tapped tag/phone and returns
  /// its text. Works on Android (reader) and iOS (CoreNFC reader).
  ///
  /// Throws [PeerTransportException] if NFC is unavailable, or when the
  /// tapped tag carries no readable text record.
  Future<String> readTextPayload({
    Duration timeout = const Duration(minutes: 1),
  }) async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      throw const PeerTransportException('NFC is not available here.');
    }
    final availability = await NfcManager.instance.checkAvailability();
    if (availability != NfcAvailability.enabled) {
      throw PeerTransportException(
        availability == NfcAvailability.disabled
            ? 'NFC is turned off - enable it in system settings and try again.'
            : 'This device has no NFC hardware.',
      );
    }

    final completer = Completer<String>();
    await NfcManager.instance.startSession(
      pollingOptions: {
        NfcPollingOption.iso14443, // phone-to-phone HCE + most tags
        NfcPollingOption.iso18092,
        NfcPollingOption.iso15693,
      },
      onDiscovered: (tag) async {
        try {
          final message = await _readNdef(tag);
          final text = message?.records
              .map(readTextPayloadFromRecord)
              .whereType<String>()
              .join();
          if (text == null || text.isEmpty) {
            if (!completer.isCompleted) {
              completer.completeError(
                const PeerTransportException(
                  'The tapped device sent no readable message.',
                ),
              );
            }
          } else if (!completer.isCompleted) {
            completer.complete(text);
          }
        } catch (error) {
          if (!completer.isCompleted) {
            completer.completeError(
              PeerTransportException('Could not read the tapped message: $error'),
            );
          }
        } finally {
          await NfcManager.instance.stopSession();
        }
      },
    );

    return completer.future.timeout(
      timeout,
      onTimeout: () {
        // Fire-and-forget: the session stop races the timeout, best effort.
        unawaited(NfcManager.instance.stopSession());
        throw PeerTransportException(
          'No NFC message was tapped within ${timeout.inSeconds} seconds.',
        );
      },
    );
  }

  Future<NdefMessage?> _readNdef(NfcTag tag) async {
    final android = NdefAndroid.from(tag);
    if (android != null) return android.getNdefMessage();
    final ios = NdefIos.from(tag);
    if (ios != null) return ios.readNdef();
    return null;
  }
}

/// Decodes an NDEF Well-Known Text record ("T" record - what both the
/// HCE plugin emits and standard NFC tag writers produce) into its text.
///
/// Layout per the NDEF spec: payload[0] = language-code length (low 6
/// bits), then the language code bytes, then the UTF-8 text. Returns null
/// for anything that is not a text record - URI/MIME records are not
/// part of this protocol and are refused rather than guessed at.
String? readTextPayloadFromRecord(NdefRecord record) {
  if (record.typeNameFormat != TypeNameFormat.wellKnown) return null;
  if (utf8.decode(record.type, allowMalformed: true) != 'T') return null;
  final Uint8List payload = record.payload;
  if (payload.isEmpty) return null;
  final languageLength = payload[0] & 0x3F;
  final textStart = 1 + languageLength;
  if (textStart > payload.length) return null;
  if ((payload[0] & 0x40) != 0) return null; // UTF-16: we only speak UTF-8
  return utf8.decode(payload.sublist(textStart), allowMalformed: true);
}
