import 'dart:typed_data';
import 'package:flutter/services.dart';

class MFS500FingerprintService {
  static const MethodChannel _channel = MethodChannel(
    'com.example.biometric/mfs500',
  );

  // Callbacks
  Function(bool hasPermission)? onDeviceAttached;
  Function()? onDeviceDetached;

  MFS500FingerprintService() {
    _channel.setMethodCallHandler(_handleDeviceEvents);
  }

  Future<void> _handleDeviceEvents(MethodCall call) async {
    switch (call.method) {
      case 'onDeviceAttached':
        final hasPermission = call.arguments['hasPermission'] as bool? ?? false;
        onDeviceAttached?.call(hasPermission);
        break;
      case 'onDeviceDetached':
        onDeviceDetached?.call();
        break;
    }
  }

  /// Initialize the MFS500 device
  Future<Map<String, dynamic>?> initialize() async {
    try {
      final result = await _channel.invokeMethod('initialize');
      return Map<String, dynamic>.from(result as Map);
    } on PlatformException catch (e) {
      print('MFS500 initialization error: ${e.message}');
      return {
        'success': false,
        'error': e.message ?? 'Unknown error',
        'code': e.code,
      };
    }
  }

  /// Cancel an ongoing capture
  Future<void> cancelCapture() async {
    try {
      await _channel.invokeMethod('cancelCapture');
      print('MFS500: Capture cancelled');
    } catch (e) {
      print('MFS500: Cancel capture error: $e');
    }
  }

  /// Capture a fingerprint
  Future<FingerprintData> captureFingerprint() async {
    try {
      final result = await _channel.invokeMethod('capture');
      final data = Map<String, dynamic>.from(result as Map);

      if (data['success'] == true) {
        return FingerprintData(
          quality: data['quality'] as int,
          nfiq: data['nfiq'] as int,
          isoTemplate: Uint8List.fromList(List<int>.from(data['isoTemplate'])),
          fingerImage: Uint8List.fromList(List<int>.from(data['fingerImage'])),
        );
      }
      throw Exception(data['error'] ?? 'Unknown capture error');
    } on PlatformException catch (e) {
      print('Capture error: ${e.code} - ${e.message}');
      throw Exception('${e.code}: ${e.message}');
    }
  }

  /// Match two fingerprint templates
  Future<MatchResult?> matchFingerprints(
    Uint8List template1,
    Uint8List template2,
  ) async {
    try {
      final result = await _channel.invokeMethod('match', {
        'template1': template1,
        'template2': template2,
      });

      final data = Map<String, dynamic>.from(result as Map);
      return MatchResult(
        matched: data['matched'] as bool? ?? false,
        score: (data['score'] as int?) ?? 0,
        threshold: (data['threshold'] as int?) ?? 0,
      );
    } on PlatformException catch (e) {
      print('Match error: ${e.message}');
      return null;
    }
  }

  /// Dispose resources
  Future<void> dispose() async {
    try {
      await _channel.invokeMethod('dispose');
    } catch (e) {
      print('Dispose error: $e');
    }
  }
}

/// Fingerprint capture data model
class FingerprintData {
  final int quality;
  final int nfiq;
  final Uint8List isoTemplate;
  final Uint8List fingerImage;

  FingerprintData({
    required this.quality,
    required this.nfiq,
    required this.isoTemplate,
    required this.fingerImage,
  });

  @override
  String toString() {
    return 'FingerprintData(quality: $quality, nfiq: $nfiq, '
        'templateSize: ${isoTemplate.length}, imageSize: ${fingerImage.length})';
  }
}

/// Fingerprint match result model
class MatchResult {
  final bool matched;
  final int score;
  final int threshold;

  MatchResult({
    required this.matched,
    required this.score,
    required this.threshold,
  });

  @override
  String toString() {
    return 'MatchResult(matched: $matched, score: $score, threshold: $threshold)';
  }
}
