import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Shared camera scanner with a paste-JSON fallback.
///
/// Used by every screen that reads a QR code. The paste field is not a
/// gimmick: it keeps the whole payment flow demo-able when
///   * running on Windows/Linux desktop (no camera plugin support), or
///   * running in an emulator without a camera, or
///   * you simply want to move the QR text between devices over chat.
///
/// On a phone the camera is the primary path; the paste field is the
/// reliable escape hatch underneath it.
class QrScannerView extends StatefulWidget {
  const QrScannerView({
    super.key,
    required this.onValueScanned,
    this.helpText = 'Point the camera at the QR code',
  });

  /// Called exactly once per scanned QR (duplicate detections within
  /// [dedupeWindow] are ignored).
  final ValueChanged<String> onValueScanned;

  final String helpText;

  /// How long to suppress an identical re-detection. The camera reports the
  /// same code many times per second; without this the caller would fire
  /// repeatedly while the user is still aiming.
  static const Duration dedupeWindow = Duration(milliseconds: 1500);

  @override
  State<QrScannerView> createState() => _QrScannerViewState();
}

class _QrScannerViewState extends State<QrScannerView> {
  late final MobileScannerController _controller;
  final TextEditingController _pasteController = TextEditingController();

  String? _lastValue;
  DateTime? _lastAt;
  final bool _cameraStarted = true;

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController(
      detectionSpeed: DetectionSpeed.noDuplicates,
      formats: const [BarcodeFormat.qrCode],
    );
  }

  @override
  void dispose() {
    _pasteController.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _accept(String raw) {
    final now = DateTime.now();
    if (_lastValue == raw &&
        _lastAt != null &&
        now.difference(_lastAt!) < QrScannerView.dedupeWindow) {
      return;
    }
    _lastValue = raw;
    _lastAt = now;
    widget.onValueScanned(raw);
  }

  void _usePasted() {
    final text = _pasteController.text.trim();
    if (text.isEmpty) {
      _showMessage('Paste the QR content first.');
      return;
    }
    _accept(text);
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // ------------------------------------------------------------
        // Camera preview
        // ------------------------------------------------------------
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: _cameraStarted
                ? MobileScanner(
                    controller: _controller,
                    onDetect: (capture) {
                      for (final barcode in capture.barcodes) {
                        final value = barcode.rawValue;
                        if (value != null && value.isNotEmpty) {
                          _accept(value);
                          return; // handle one code per frame
                        }
                      }
                    },
                    errorBuilder: (context, error, child) {
                      return _CameraErrorView(error: error);
                    },
                  )
                : const SizedBox.shrink(),
          ),
        ),
        const SizedBox(height: 12),
        Text(widget.helpText, style: const TextStyle(color: Colors.grey)),
        const SizedBox(height: 12),

        // ------------------------------------------------------------
        // Paste fallback (desktop / emulator / no-camera)
        // ------------------------------------------------------------
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _pasteController,
                maxLines: 2,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: '...or paste the QR JSON here',
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: _usePasted,
              child: const Text('Use'),
            ),
          ],
        ),
      ],
    );
  }
}

/// Camera failures (no camera, permission denied) must not dead-end the
/// flow - the paste field below still works, so explain and continue.
class _CameraErrorView extends StatelessWidget {
  const _CameraErrorView({required this.error});

  final MobileScannerException error;

  @override
  Widget build(BuildContext context) {
    final isPermission =
        error.errorCode == MobileScannerErrorCode.permissionDenied;

    return Container(
      color: Colors.black87,
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            isPermission ? Icons.lock_outline : Icons.no_photography,
            color: Colors.white70,
            size: 48,
          ),
          const SizedBox(height: 12),
          Text(
            isPermission
                ? 'Camera permission not granted.\nYou can still paste the QR content below.'
                : 'Camera unavailable (${error.errorCode.name}).\nYou can still paste the QR content below.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70),
          ),
        ],
      ),
    );
  }
}
