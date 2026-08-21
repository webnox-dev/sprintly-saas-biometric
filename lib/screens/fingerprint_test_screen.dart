import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'dart:ui';
import '../services/fingerprint_service.dart';


/// Test screen for Mantra MFS110/MFS500 Fingerprint Scanner
/// This screen provides UI to test device connection and fingerprint capture
class FingerprintTestScreen extends StatefulWidget {
  const FingerprintTestScreen({super.key});

  @override
  State<FingerprintTestScreen> createState() => _FingerprintTestScreenState();
}

class _FingerprintTestScreenState extends State<FingerprintTestScreen>
    with SingleTickerProviderStateMixin {
  late FingerprintService _fingerprintService;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  // State management
  bool _isInitializing = true;
  bool _isCapturing = false;
  bool _isDeviceConnected = false;
  String _statusMessage = 'Initializing...';
  String _deviceInfo = '';
  String _lastCaptureResult = '';
  FingerprintCaptureResult? _captureResult;

  // Colors
  final Color _primaryBlue = const Color(0xFF3B82F6);
  final Color _successGreen = const Color(0xFF10B981);
  final Color _errorRed = const Color(0xFFEF4444);
  final Color _warningOrange = const Color(0xFFF59E0B);

  @override
  void initState() {
    super.initState();
    _fingerprintService = FingerprintService();

    // Setup pulse animation for scanning indicator
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );
    _pulseAnimation = Tween<double>(begin: 0.95, end: 1.05).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _pulseController.repeat(reverse: true);

    _initializeDevice();
  }

  Future<void> _initializeDevice() async {
    setState(() {
      _isInitializing = true;
      _statusMessage = 'Connecting to fingerprint scanner...';
    });

    final success = await _fingerprintService.initialize();

    setState(() {
      _isInitializing = false;
      _isDeviceConnected = success;
      if (success) {
        _statusMessage = 'Device connected successfully';
        _deviceInfo = _fingerprintService.deviceInfo;
      } else {
        _statusMessage = _fingerprintService.lastError;
        _deviceInfo = '';
      }
    });
  }

  Future<void> _refreshConnection() async {
    setState(() {
      _statusMessage = 'Reconnecting...';
    });

    final success = await _fingerprintService.refreshConnection();

    setState(() {
      _isDeviceConnected = success;
      if (success) {
        _statusMessage = 'Device reconnected successfully';
        _deviceInfo = _fingerprintService.deviceInfo;
      } else {
        _statusMessage = _fingerprintService.lastError;
      }
    });
  }

  Future<void> _captureFingerprint() async {
    if (!_isDeviceConnected) {
      _showSnackBar(
        'Device not connected. Please reconnect first.',
        isError: true,
      );
      return;
    }

    setState(() {
      _isCapturing = true;
      _statusMessage = 'Place your finger on the scanner...';
      _lastCaptureResult = '';
      _captureResult = null;
    });

    final result = await _fingerprintService.captureWithDetails();

    setState(() {
      _isCapturing = false;
      _captureResult = result;

      if (result.success) {
        _statusMessage = 'Fingerprint captured successfully!';
        _lastCaptureResult =
            'Device: ${result.deviceSerialNo ?? "Direct SDK"}\n'
            'PID Data Length: ${result.pidData?.length ?? 0} chars';
      } else {
        _statusMessage =
            'Capture failed: ${result.errorMessage ?? "Unknown Error"}';
        _lastCaptureResult = 'Error Code: ${result.errorCode ?? "N/A"}';
      }
    });

    if (result.success) {
      _showSnackBar('Fingerprint captured successfully!', isError: false);
    } else {
      _showSnackBar(result.errorMessage ?? 'Capture failed', isError: true);
    }
  }

  Future<void> _getDeviceStatus() async {
    final status = await _fingerprintService.getDeviceStatus();

    setState(() {
      _isDeviceConnected = status.isConnected;
      if (status.isConnected) {
        _statusMessage = 'Device Status: Connected';
        _deviceInfo =
            'Serial: ${status.serialNumber ?? "Unknown"}\n'
            'Firmware: ${status.firmwareVersion ?? "Unknown"}\n'
            'RD Service: ${status.rdServiceVersion ?? "Unknown"}';
      } else {
        _statusMessage = 'Device Status: Disconnected';
        _deviceInfo = status.errorMessage ?? '';
      }
    });
  }

  void _showSnackBar(String message, {required bool isError}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: GoogleFonts.poppins(color: Colors.white)),
        backgroundColor: isError ? _errorRed : _successGreen,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _fingerprintService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F12),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'Fingerprint Scanner Test',
          style: GoogleFonts.poppins(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: Colors.white70),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white70),
            onPressed: _isInitializing || _isCapturing
                ? null
                : _refreshConnection,
            tooltip: 'Refresh Connection',
          ),
        ],
      ),
      body: Stack(
        children: [
          // Background decorations
          _buildBackgroundDecorations(),

          // Main content
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Device Status Card
                  _buildDeviceStatusCard(),

                  const SizedBox(height: 24),

                  // Fingerprint Capture Area
                  _buildCaptureArea(),

                  const SizedBox(height: 24),

                  // Action Buttons
                  _buildActionButtons(),

                  const SizedBox(height: 24),

                  // Result Display
                  if (_lastCaptureResult.isNotEmpty) _buildResultCard(),

                  const SizedBox(height: 24),

                  // Instructions
                  _buildInstructionsCard(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBackgroundDecorations() {
    return Stack(
      children: [
        Positioned(
          top: -100,
          right: -100,
          child: Container(
            width: 350,
            height: 350,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [_primaryBlue.withOpacity(0.15), Colors.transparent],
              ),
            ),
          ),
        ),
        Positioned(
          bottom: -150,
          left: -150,
          child: Container(
            width: 400,
            height: 400,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [Colors.purple.withOpacity(0.1), Colors.transparent],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDeviceStatusCard() {
    Color statusColor = _isInitializing
        ? _warningOrange
        : _isDeviceConnected
        ? _successGreen
        : _errorRed;

    IconData statusIcon = _isInitializing
        ? Icons.hourglass_empty
        : _isDeviceConnected
        ? Icons.check_circle_outline
        : Icons.error_outline;

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.05),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: statusColor.withOpacity(0.3), width: 1.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: statusColor.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(statusIcon, color: statusColor, size: 28),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Device Status',
                          style: GoogleFonts.poppins(
                            color: Colors.white54,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _isInitializing
                              ? 'Initializing...'
                              : _isDeviceConnected
                              ? 'Connected'
                              : 'Disconnected',
                          style: GoogleFonts.poppins(
                            color: statusColor,
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_isInitializing)
                    const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          Colors.white54,
                        ),
                      ),
                    ),
                ],
              ),
              if (_statusMessage.isNotEmpty) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.black26,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline, color: Colors.white38, size: 18),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _statusMessage,
                          style: GoogleFonts.poppins(
                            color: Colors.white70,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCaptureArea() {
    return Center(
      child: AnimatedBuilder(
        animation: _pulseAnimation,
        builder: (context, child) {
          return Transform.scale(
            scale: _isCapturing ? _pulseAnimation.value : 1.0,
            child: GestureDetector(
              onTap: _isCapturing ? null : _captureFingerprint,
              child: Container(
                width: 200,
                height: 200,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: _isCapturing
                        ? [_warningOrange, _warningOrange.withOpacity(0.7)]
                        : _captureResult?.success == true
                        ? [_successGreen, _successGreen.withOpacity(0.7)]
                        : [_primaryBlue, _primaryBlue.withOpacity(0.7)],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color:
                          (_isCapturing
                                  ? _warningOrange
                                  : _captureResult?.success == true
                                  ? _successGreen
                                  : _primaryBlue)
                              .withOpacity(0.4),
                      blurRadius: 30,
                      spreadRadius: 5,
                    ),
                  ],
                ),
                child: Container(
                  margin: const EdgeInsets.all(4),
                  decoration: const BoxDecoration(
                    color: Color(0xFF0F0F12),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: _isCapturing
                        ? Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const SizedBox(
                                width: 50,
                                height: 50,
                                child: CircularProgressIndicator(
                                  strokeWidth: 3,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    Colors.white,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'Scanning...',
                                style: GoogleFonts.poppins(
                                  color: Colors.white70,
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          )
                        : Icon(
                            _captureResult?.success == true
                                ? Icons.check_rounded
                                : Icons.fingerprint_rounded,
                            size: 80,
                            color: Colors.white,
                          ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildActionButtons() {
    return Column(
      children: [
        // Main capture button
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _isCapturing || !_isDeviceConnected
                ? null
                : _captureFingerprint,
            icon: const Icon(Icons.fingerprint),
            label: Text(
              _isCapturing ? 'Capturing...' : 'Capture Fingerprint',
              style: GoogleFonts.poppins(
                fontWeight: FontWeight.w600,
                fontSize: 16,
              ),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: _primaryBlue,
              foregroundColor: Colors.white,
              disabledBackgroundColor: Colors.grey.shade800,
              padding: const EdgeInsets.symmetric(vertical: 18),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),

        // Secondary buttons
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _isCapturing ? null : _getDeviceStatus,
                icon: const Icon(Icons.info_outline, size: 20),
                label: Text(
                  'Device Info',
                  style: GoogleFonts.poppins(fontWeight: FontWeight.w500),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white70,
                  side: BorderSide(color: Colors.white.withOpacity(0.2)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _isCapturing ? null : _refreshConnection,
                icon: const Icon(Icons.refresh, size: 20),
                label: Text(
                  'Reconnect',
                  style: GoogleFonts.poppins(fontWeight: FontWeight.w500),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white70,
                  side: BorderSide(color: Colors.white.withOpacity(0.2)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildResultCard() {
    final isSuccess = _captureResult?.success == true;

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: (isSuccess ? _successGreen : _errorRed).withOpacity(0.1),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: (isSuccess ? _successGreen : _errorRed).withOpacity(0.3),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    isSuccess ? Icons.check_circle : Icons.error,
                    color: isSuccess ? _successGreen : _errorRed,
                    size: 24,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    isSuccess ? 'Capture Successful' : 'Capture Failed',
                    style: GoogleFonts.poppins(
                      color: isSuccess ? _successGreen : _errorRed,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _lastCaptureResult,
                  style: GoogleFonts.robotoMono(
                    color: Colors.white70,
                    fontSize: 12,
                  ),
                ),
              ),
              if (_captureResult?.rawResponse != null) ...[
                const SizedBox(height: 12),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text(
                    'Raw Response (XML)',
                    style: GoogleFonts.poppins(
                      color: Colors.white54,
                      fontSize: 14,
                    ),
                  ),
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.black38,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Text(
                          _captureResult!.rawResponse!,
                          style: GoogleFonts.robotoMono(
                            color: Colors.white60,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInstructionsCard() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.03),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withOpacity(0.1)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.help_outline, color: _primaryBlue, size: 24),
                  const SizedBox(width: 12),
                  Text(
                    'Instructions',
                    style: GoogleFonts.poppins(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _buildInstructionItem(
                '1',
                'For MFS110: Ensure Mantra RD Service app is installed. For MFS500: No RD Service needed (Direct SDK).',
              ),
              _buildInstructionItem(
                '2',
                'Connect the MFS110/MFS500 fingerprint scanner via USB OTG',
              ),
              _buildInstructionItem('3', 'Wait for "Device Connected" status'),
              _buildInstructionItem(
                '4',
                'Tap "Capture Fingerprint" and place your finger firmly on the sensor',
              ),
              _buildInstructionItem(
                '5',
                'Keep your finger still until capture completes',
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInstructionItem(String number, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: _primaryBlue.withOpacity(0.2),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Center(
              child: Text(
                number,
                style: GoogleFonts.poppins(
                  color: _primaryBlue,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: GoogleFonts.poppins(
                color: Colors.white60,
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
