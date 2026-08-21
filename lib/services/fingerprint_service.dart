import 'dart:convert';
import 'dart:typed_data';
import 'mfs500_fingerprint_service.dart';

/// Main fingerprint service that wraps MFS500 direct SDK integration
class FingerprintService {
  final MFS500FingerprintService _mfs500Service = MFS500FingerprintService();

  String get deviceInfo => _deviceInfo;
  String get lastError => _lastError;

  String _deviceInfo = '';
  String _lastError = '';

  // Pass through callbacks from MFS500
  Function(bool hasPermission)? get onDeviceAttached =>
      _mfs500Service.onDeviceAttached;
  set onDeviceAttached(Function(bool)? callback) =>
      _mfs500Service.onDeviceAttached = callback;

  Function()? get onDeviceDetached => _mfs500Service.onDeviceDetached;
  set onDeviceDetached(Function()? callback) =>
      _mfs500Service.onDeviceDetached = callback;

  /// Initialize MFS500 device
  Future<bool> initialize() async {
    try {
      print('FingerprintService: Initializing MFS500...');
      final result = await _mfs500Service.initialize();

      if (result != null && result['success'] == true) {
        _deviceInfo =
            'Make: ${result['make']}, Model: ${result['model']}, '
            'Serial: ${result['serialNo']}';
        _lastError = '';
        print('FingerprintService: MFS500 initialized successfully');
        return true;
      } else {
        _lastError = result?['error'] ?? 'Initialization failed';
        print('FingerprintService: Initialization failed: $_lastError');
        return false;
      }
    } catch (e) {
      _lastError = e.toString();
      print('FingerprintService: Exception during initialization: $e');
      return false;
    }
  }

  /// Capture fingerprint with full details
  Future<FingerprintCaptureResult> captureWithDetails() async {
    try {
      print('FingerprintService: Starting capture...');
      final fingerprintData = await _mfs500Service.captureFingerprint();

      print(
        'FingerprintService: Capture successful - Quality: ${fingerprintData.quality}, '
        'NFIQ: ${fingerprintData.nfiq}',
      );

      return FingerprintCaptureResult(
        success: true,
        pidData: base64Encode(fingerprintData.isoTemplate),
        deviceSerialNo: 'MFS500',
      );
    } catch (e) {
      _lastError = e.toString();
      print('FingerprintService: Capture error: $e');
      return FingerprintCaptureResult(
        success: false,
        errorMessage: e.toString(),
        errorCode: 'CAPTURE_ERROR',
      );
    }
  }

  /// Cancel an ongoing capture
  Future<void> cancelCapture() async {
    await _mfs500Service.cancelCapture();
  }

  /// Capture fingerprint (legacy method for compatibility)
  Future<FingerprintCaptureResult> captureFingerprint() async {
    return await captureWithDetails();
  }

  /// Check if device is initialized
  bool get isInitialized => _deviceInfo.isNotEmpty;

  /// Get device status string
  String get deviceStatus => isInitialized ? 'Connected' : 'Not Connected';

  /// Match two templates and return score
  Future<int> match(List<int> template1, List<int> template2) async {
    try {
      final result = await _mfs500Service.matchFingerprints(
        Uint8List.fromList(template1),
        Uint8List.fromList(template2),
      );
      return result?.score ?? 0;
    } catch (e) {
      print('FingerprintService: Match error: $e');
      return 0;
    }
  }

  /// Get device status
  Future<DeviceStatusResult> getDeviceStatus() async {
    return DeviceStatusResult(
      isConnected: _deviceInfo.isNotEmpty,
      rawInfo: _deviceInfo,
    );
  }

  /// Refresh connection
  Future<bool> refreshConnection() async {
    print('FingerprintService: Refreshing connection...');
    return await initialize();
  }

  /// Dispose resources
  void dispose() {
    _mfs500Service.dispose();
  }
}

/// Result class for fingerprint capture operations
class FingerprintCaptureResult {
  final bool success;
  final String? pidData;
  final String? hmac;
  final String? sessionKey;
  final String? ci;
  final String? deviceSerialNo;
  final String? errorCode;
  final String? errorMessage;
  final String? rawResponse;

  FingerprintCaptureResult({
    required this.success,
    this.pidData,
    this.hmac,
    this.sessionKey,
    this.ci,
    this.deviceSerialNo,
    this.errorCode,
    this.errorMessage,
    this.rawResponse,
  });

  String? get fingerprintTemplate => pidData;

  @override
  String toString() {
    if (success) {
      return 'FingerprintCaptureResult(success: true, deviceSerial: $deviceSerialNo)';
    } else {
      return 'FingerprintCaptureResult(success: false, error: $errorCode - $errorMessage)';
    }
  }
}

/// Result class for device status queries
class DeviceStatusResult {
  final bool isConnected;
  final String? serialNumber;
  final String? firmwareVersion;
  final String? rdServiceVersion;
  final String? rawInfo;
  final String? errorMessage;

  DeviceStatusResult({
    required this.isConnected,
    this.serialNumber,
    this.firmwareVersion,
    this.rdServiceVersion,
    this.rawInfo,
    this.errorMessage,
  });

  @override
  String toString() {
    if (isConnected) {
      return 'DeviceStatusResult(connected: true, serial: $serialNumber)';
    } else {
      return 'DeviceStatusResult(connected: false, error: $errorMessage)';
    }
  }
}
