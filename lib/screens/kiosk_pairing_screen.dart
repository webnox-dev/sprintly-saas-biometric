import 'dart:async';
import 'dart:convert';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../api/backend_api.dart';
import 'kiosk_screen.dart';

/// Screen displayed when the Biometric Kiosk is first launched or unpaired.
/// Uses the device camera to scan the 1-Click Pairing QR Code from the Admin Dashboard.
class KioskPairingScreen extends StatefulWidget {
  const KioskPairingScreen({super.key});

  @override
  State<KioskPairingScreen> createState() => _KioskPairingScreenState();
}

class _KioskPairingScreenState extends State<KioskPairingScreen>
    with SingleTickerProviderStateMixin {
  CameraController? _cameraController;
  List<CameraDescription> _cameras = [];
  bool _isCameraReady = false;
  bool _useFrontCamera = true;
  bool _isProcessing = false;
  String? _pairedOrgName;
  Timer? _scanTimer;

  late final BarcodeScanner _barcodeScanner;
  late AnimationController _animController;

  @override
  void initState() {
    super.initState();
    _barcodeScanner = BarcodeScanner(formats: [BarcodeFormat.qrCode]);
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final status = await Permission.camera.request();
      if (status != PermissionStatus.granted) {
        _showError('Camera permission is required to scan QR code');
        return;
      }

      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        _showError('No cameras found on this device');
        return;
      }

      final camera = _cameras.firstWhere(
        (c) =>
            c.lensDirection ==
            (_useFrontCamera
                ? CameraLensDirection.front
                : CameraLensDirection.back),
        orElse: () => _cameras.first,
      );

      _cameraController = CameraController(
        camera,
        ResolutionPreset.medium,
        enableAudio: false,
      );

      await _cameraController!.initialize();
      if (!mounted) return;

      setState(() => _isCameraReady = true);
      _startScanningLoop();
    } catch (e) {
      _showError('Failed to initialize camera: $e');
    }
  }

  void _startScanningLoop() {
    _scanTimer?.cancel();
    _scanTimer = Timer.periodic(const Duration(milliseconds: 600), (
      timer,
    ) async {
      if (_isProcessing ||
          _cameraController == null ||
          !_cameraController!.value.isInitialized ||
          _cameraController!.value.isTakingPicture) {
        return;
      }

      try {
        final xFile = await _cameraController!.takePicture();
        final inputImage = InputImage.fromFilePath(xFile.path);
        final barcodes = await _barcodeScanner.processImage(inputImage);

        for (final barcode in barcodes) {
          final rawValue = barcode.rawValue;
          if (rawValue != null && rawValue.trim().isNotEmpty) {
            timer.cancel();
            await _processPairingData(rawValue.trim());
            break;
          }
        }
      } catch (_) {
        // Ignore single frame scan exceptions
      }
    });
  }

  Future<void> _toggleCamera() async {
    setState(() {
      _useFrontCamera = !_useFrontCamera;
      _isCameraReady = false;
    });
    _scanTimer?.cancel();
    await _cameraController?.dispose();
    _cameraController = null;
    await _initCamera();
  }

  @override
  void dispose() {
    _scanTimer?.cancel();
    _barcodeScanner.close();
    _cameraController?.dispose();
    _animController.dispose();
    super.dispose();
  }

  Future<void> _processPairingData(String rawData) async {
    if (_isProcessing) return;
    setState(() => _isProcessing = true);

    try {
      String orgId = '';
      String orgName = 'Sprintly Organization';
      String? apiUrl;

      // Try parsing JSON pairing format
      try {
        final parsed = jsonDecode(rawData) as Map<String, dynamic>;
        if (parsed['type'] == 'sprintly_kiosk_pairing' ||
            parsed.containsKey('org_id') ||
            parsed.containsKey('organization_id')) {
          orgId =
              (parsed['org_id'] ?? parsed['organization_id'] ?? '').toString();
          orgName =
              (parsed['org_name'] ??
                      parsed['organization_name'] ??
                      'Sprintly Organization')
                  .toString();
          apiUrl = parsed['api_url']?.toString();
        }
      } catch (_) {
        // Fallback: If rawData is just a UUID string
        if (RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(rawData.trim())) {
          orgId = rawData.trim();
        }
      }

      if (orgId.isEmpty) {
        _showError(
          'Invalid Pairing QR Code. Please scan the QR from your Admin Dashboard.',
        );
        setState(() => _isProcessing = false);
        _startScanningLoop();
        return;
      }

      if (apiUrl != null && apiUrl.isNotEmpty) {
        BackendApi.setBaseUrl(apiUrl);
      }
      await BackendApi().setOrganizationId(orgId);

      // Fetch official Organization Name from backend API if available
      try {
        final fetchedName = await BackendApi().fetchOrganizationName(orgId);
        if (fetchedName != null && fetchedName.isNotEmpty) {
          orgName = fetchedName;
        }
      } catch (_) {}

      // Save to SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('kiosk_organization_id', orgId);
      await prefs.setString('kiosk_organization_name', orgName);
      if (apiUrl != null && apiUrl.isNotEmpty) {
        await prefs.setString('kiosk_api_url', apiUrl);
      }

      setState(() {
        _pairedOrgName = orgName;
      });

      // Show success feedback and navigate to Kiosk
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF10B981),
            content: Row(
              children: [
                const Icon(Icons.check_circle_rounded, color: Colors.white),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Device paired with $orgName!',
                    style: GoogleFonts.poppins(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            duration: const Duration(seconds: 2),
          ),
        );

        await Future.delayed(const Duration(milliseconds: 1200));

        if (mounted) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const KioskScreen()),
          );
        }
      }
    } catch (e) {
      _showError('Failed to process pairing code: $e');
      setState(() => _isProcessing = false);
      _startScanningLoop();
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: const Color(0xFFEF4444),
        content: Text(message, style: GoogleFonts.poppins(color: Colors.white)),
      ),
    );
  }

  void _showManualEntryDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            backgroundColor: const Color(0xFF1E293B),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            title: Text(
              'Enter Organization ID',
              style: GoogleFonts.poppins(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Find your Organization ID in Admin Dashboard -> Settings -> Biometric Kiosk.',
                  style: GoogleFonts.poppins(
                    color: Colors.white70,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: controller,
                  style: GoogleFonts.poppins(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'e.g. 38797954-d920-41f5-b38e-8136fdd150ce',
                    hintStyle: GoogleFonts.poppins(
                      color: Colors.white38,
                      fontSize: 13,
                    ),
                    filled: true,
                    fillColor: const Color(0xFF0F172A),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Color(0xFF334155)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(
                        color: Color(0xFF3B82F6),
                        width: 2,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(
                  'Cancel',
                  style: GoogleFonts.poppins(color: Colors.white60),
                ),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF3B82F6),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onPressed: () {
                  final text = controller.text.trim();
                  Navigator.pop(context);
                  if (text.isNotEmpty) {
                    _processPairingData(text);
                  }
                },
                child: Text(
                  'Pair Device',
                  style: GoogleFonts.poppins(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isTablet = size.width >= 600;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      body: SafeArea(
        child: Column(
          children: [
            // Top App Bar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF3B82F6).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: const Color(0xFF3B82F6).withValues(alpha: 0.3),
                      ),
                    ),
                    child: const Icon(
                      Icons.qr_code_scanner_rounded,
                      color: Color(0xFF3B82F6),
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Device Setup & Pairing',
                          style: GoogleFonts.poppins(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          'Link this biometric terminal to your organization',
                          style: GoogleFonts.poppins(
                            color: Colors.white60,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Flip Camera button
                  IconButton(
                    icon: const Icon(
                      Icons.flip_camera_android_rounded,
                      color: Colors.white70,
                    ),
                    onPressed: _toggleCamera,
                    tooltip: 'Flip Camera',
                  ),
                ],
              ),
            ),

            const Divider(color: Color(0xFF1E293B), height: 1),

            // Scanner Area
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        // Viewfinder Box
                        Container(
                          width: isTablet ? 360 : 280,
                          height: isTablet ? 360 : 280,
                          decoration: BoxDecoration(
                            color: Colors.black,
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(
                              color: const Color(0xFF3B82F6),
                              width: 2,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(
                                  0xFF3B82F6,
                                ).withValues(alpha: 0.2),
                                blurRadius: 30,
                                spreadRadius: 5,
                              ),
                            ],
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              if (_isCameraReady &&
                                  _cameraController != null &&
                                  _cameraController!.value.isInitialized)
                                SizedBox.expand(
                                  child: FittedBox(
                                    fit: BoxFit.cover,
                                    child: SizedBox(
                                      width:
                                          _cameraController!
                                              .value
                                              .previewSize
                                              ?.height ??
                                          280,
                                      height:
                                          _cameraController!
                                              .value
                                              .previewSize
                                              ?.width ??
                                          280,
                                      child: CameraPreview(_cameraController!),
                                    ),
                                  ),
                                )
                              else
                                const Center(
                                  child: CircularProgressIndicator(
                                    color: Color(0xFF3B82F6),
                                  ),
                                ),

                              // Scanning Animation Line
                              AnimatedBuilder(
                                animation: _animController,
                                builder: (context, child) {
                                  return Positioned(
                                    top:
                                        (isTablet ? 340 : 260) *
                                        _animController.value,
                                    left: 20,
                                    right: 20,
                                    child: Container(
                                      height: 3,
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF3B82F6),
                                        borderRadius: BorderRadius.circular(2),
                                        boxShadow: [
                                          BoxShadow(
                                            color: const Color(
                                              0xFF3B82F6,
                                            ).withValues(alpha: 0.8),
                                            blurRadius: 10,
                                            spreadRadius: 2,
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),

                              // Processing Indicator
                              if (_isProcessing)
                                Container(
                                  color: Colors.black.withValues(alpha: 0.7),
                                  child: Center(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const CircularProgressIndicator(
                                          color: Color(0xFF3B82F6),
                                        ),
                                        const SizedBox(height: 16),
                                        Text(
                                          _pairedOrgName != null
                                              ? 'Connecting to $_pairedOrgName...'
                                              : 'Pairing Device...',
                                          style: GoogleFonts.poppins(
                                            color: Colors.white,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 32),

                        // Instructions
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 14,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(
                              0xFF1E293B,
                            ).withValues(alpha: 0.7),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: const Color(0xFF334155)),
                          ),
                          child: Column(
                            children: [
                              Text(
                                'Point camera at the Admin Pairing QR Code',
                                style: GoogleFonts.poppins(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 15,
                                ),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Go to Admin Dashboard -> Settings -> Biometric Kiosk Terminal to view your organization QR code.',
                                style: GoogleFonts.poppins(
                                  color: Colors.white60,
                                  fontSize: 13,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 24),

                        // Manual Entry Fallback Button
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white70,
                            side: const BorderSide(color: Color(0xFF334155)),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 14,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          icon: const Icon(Icons.edit_note_rounded, size: 20),
                          label: Text(
                            'Enter Organization ID Manually',
                            style: GoogleFonts.poppins(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          onPressed: _showManualEntryDialog,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
