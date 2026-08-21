import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:google_fonts/google_fonts.dart';
import 'dart:ui';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart'; // Camera support
import 'package:permission_handler/permission_handler.dart'; // Permissions

import '../services/fingerprint_service.dart';
import '../services/backend_attendance_service.dart';
import '../services/face_detection_service.dart'; // Face Detection
import '../services/face_embedding_service.dart'; // Face Embedding
import '../services/sound_service.dart'; // Sound Service
import '../api/backend_api.dart';
import 'admin/admin_dashboard.dart';
import '../widgets/admin_access_dialog.dart';

enum KioskState { idle, scanning, verifying, confirming, success, error }

enum KioskMode { fingerprint, face, pin } // Tab modes

class KioskScreen extends StatefulWidget {
  const KioskScreen({super.key});

  @override
  State<KioskScreen> createState() => _KioskScreenState();
}

class _KioskScreenState extends State<KioskScreen> with WidgetsBindingObserver {
  late FingerprintService _fingerprintService;
  late BackendAttendanceService _attendanceService;
  late BackendApi _backendApi;
  late FaceDetectionService _faceDetectionService;
  late FaceEmbeddingService _faceEmbeddingService;
  late SoundService _soundService;
  late FlutterTts _flutterTts;

  KioskState _state = KioskState.idle;
  KioskMode _mode = KioskMode.fingerprint; // Default mode

  // Camera & Face properties
  CameraController? _cameraController;
  bool _isCameraInitialized = false;

  String _employeeCode = '';
  String _employeeName = '';
  String _punchType = '';
  String _time = '';
  String _organizationName = '';
  bool _isInitialized = false;
  bool _isInitializing = false;
  String _errorMessage = '';
  bool _isPreparingFingerprint = false;
  bool _isPreparingFace = false;

  // Pending punch data for confirmation
  String _pendingEmployeeId = '';
  double _pendingConfidence = 0.0;
  String _enteredPin = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeServices();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Re-initialize camera if needed
      if (_mode == KioskMode.face) {
        _initializeCamera();
      }
      // Re-check fingerprint connection
      // This is crucial if user went to settings to enable OTG
      _fingerprintService.refreshConnection().then((_) {
        if (mounted) setState(() {});
      });
    } else if (state == AppLifecycleState.inactive) {
      if (_mode == KioskMode.face) {
        _stopCamera();
      }
    }
  }

  Future<void> _initializeServices() async {
    _fingerprintService = FingerprintService();
    _faceDetectionService = FaceDetectionService();
    _faceEmbeddingService = FaceEmbeddingService();
    _soundService = SoundService();
    _backendApi = BackendApi();

    // Load paired Organization Name
    try {
      final prefs = await SharedPreferences.getInstance();
      _organizationName = prefs.getString('kiosk_organization_name') ?? '';
      final orgId = prefs.getString('kiosk_organization_id');
      if (orgId != null && orgId.isNotEmpty) {
        _backendApi.fetchOrganizationName(orgId).then((name) {
          if (name != null && name.isNotEmpty && mounted) {
            setState(() {
              _organizationName = name;
            });
            prefs.setString('kiosk_organization_name', name);
          }
        });
      }
    } catch (_) {}

    _attendanceService = BackendAttendanceService(
      _backendApi,
      _faceEmbeddingService,
      _fingerprintService,
    );

    // Initialize Text-to-Speech (Jovial Mode)
    // Initialize Text-to-Speech (Jovial Mode)
    _flutterTts = FlutterTts();

    // Explicitly configure audio session for playback
    await _flutterTts.setSharedInstance(true);
    await _flutterTts
        .setIosAudioCategory(IosTextToSpeechAudioCategory.playback, [
          IosTextToSpeechAudioCategoryOptions.defaultToSpeaker,
          IosTextToSpeechAudioCategoryOptions.allowBluetooth,
          IosTextToSpeechAudioCategoryOptions.allowBluetoothA2DP,
        ]);

    await _flutterTts.setLanguage('en-US');
    await _initVoices(); // Find and cache Male/Female voices

    await _flutterTts.setSpeechRate(0.35);
    await _flutterTts.setPitch(
      1.0,
    ); // Reset to normal first to ensure audibility
    await _flutterTts.setVolume(1.0);

    // Debug Listeners
    _flutterTts.setStartHandler(() {
      print('🔊 TTS Started playing');
    });
    _flutterTts.setCompletionHandler(() {
      print('✅ TTS Completed playing');
    });
    _flutterTts.setErrorHandler((msg) {
      print('❌ TTS Error: $msg');
    });

    // Device Connection Listeners
    _fingerprintService.onDeviceDetached = () async {
      print('⚠️ Device detached!');
      _stopAutoScanLoop();
      if (mounted) {
        setState(() {
          _state = KioskState.error;
          _errorMessage = 'Device Disconnected. Please reconnect.';
        });
        await _speakRoast("Device disconnected. Please reconnect.");
      }
    };

    _fingerprintService.onDeviceAttached = (bool hasPermission) async {
      print('🔌 Device attached (Permission: $hasPermission)');

      // If we are already initializing, ignore this event to prevent loop
      if (_isInitializing) {
        print('Initialization already in progress, skipping...');
        return;
      }

      // If we are already successfully initialized and device status is good, ignore
      if (_isInitialized && _fingerprintService.isInitialized) {
        print('Already initialized, skipping re-init...');
        return;
      }

      if (mounted) {
        setState(() {
          _isInitializing = true;
          _errorMessage = 'Device Connecting...';
        });
      }

      // Re-initialize (now with Activity context support)
      await _fingerprintService.initialize();

      if (mounted) {
        setState(() {
          _isInitializing = false;
        });

        // Check status again after init attempt
        final isReady = _fingerprintService.isInitialized;
        if (isReady) {
          await _speakHappy("Device connected.");
          setState(() {
            _state = KioskState.idle;
            _errorMessage = '';
          });
          // Auto-restart loop if in fingerprint mode
          if (_mode == KioskMode.fingerprint) {
            _startAutoScanLoop();
          }
        } else {
          // Still not ready? Maybe permission was denied or dialog is still pending
          // Only show error if we aren't already showing it, to allow dismissal
          if (_state != KioskState.error) {
            setState(() {
              _state = KioskState.error;
              _errorMessage =
                  'Device attached. Please allow permission if asked.';
            });
          }
        }
      }
    };

    try {
      // Parallel initialization where possible
      await Future.wait([
        _initVoices(),
        _faceEmbeddingService.init(),
        // Increased timeout: release APKs (ProGuard + cold SDK start) need more time
        _fingerprintService.initialize().timeout(
          const Duration(seconds: 15),
          onTimeout: () {
            print('⚠️ Fingerprint Init Timed Out - Proceeding anyway');
            return false;
          },
        ),
      ]);

      _initializeCamera(); // Fire and forget

      // Preload employee cache (Non-critical)
      try {
        await _attendanceService.refreshEmployeeCache();
      } catch (e) {
        print('⚠️ Cache refresh warning: $e');
      }
    } catch (e) {
      print('❌ Initialization Warning: $e');
      // Non-fatal, we still want to show UI
    } finally {
      if (mounted) {
        setState(() {
          _isInitialized = true;
          // Clean error state if things look okay essentially
          if (_fingerprintService.isInitialized) {
            _state = KioskState.idle;
          } else {
            // If fingerprint failed, we are technically in error state for that feature
            // but UI should show.
            // _state = KioskState.error; // Optional: show error immediately
          }
        });

        // Start scanning only if we are ready
        if (_mode == KioskMode.fingerprint &&
            _fingerprintService.isInitialized) {
          Future.delayed(const Duration(milliseconds: 500), () {
            if (mounted) _startAutoScanLoop();
          });
        } else if (_mode == KioskMode.fingerprint &&
            !_fingerprintService.isInitialized) {
          // Init timed out (common in release APK on cold start).
          // Retry in background so the kiosk becomes active when the device is ready.
          print('🔄 Starting background fingerprint init retry...');
          _retryFingerprintInitInBackground();
        }
      }
    }
  }

  /// Retry fingerprint init in the background until it succeeds.
  /// This handles the case where the release APK needs more time to init the SDK.
  Future<void> _retryFingerprintInitInBackground() async {
    const retryInterval = Duration(seconds: 5);
    int attempts = 0;
    const maxAttempts = 20; // Give up after ~100 seconds total

    while (mounted &&
        !_fingerprintService.isInitialized &&
        attempts < maxAttempts) {
      attempts++;
      print('🔄 Background init retry attempt $attempts/$maxAttempts...');
      await Future.delayed(retryInterval);

      if (!mounted) return;

      final success = await _fingerprintService.initialize();
      print('🔄 Background init result: ${success ? "SUCCESS" : "FAILED"}');

      if (success && mounted) {
        setState(() {
          _state = KioskState.idle;
          _errorMessage = '';
        });
        // Start scan loop now that the device is ready
        if (_mode == KioskMode.fingerprint && !_isScanningLoopActive) {
          print('✅ Device ready after background retry. Starting scan loop.');
          _startAutoScanLoop();
        }
        return;
      }
    }

    if (mounted && !_fingerprintService.isInitialized) {
      print(
        '❌ Background init gave up after $maxAttempts attempts. '
        'Waiting for device-attached callback.',
      );
    }
  }

  // Voice Cache
  Map<String, String>? _maleVoice;
  Map<String, String>? _femaleVoice;

  Future<void> _initVoices() async {
    try {
      final voices = await _flutterTts.getVoices;
      final List<dynamic> voiceList = voices as List<dynamic>;

      // Heuristic Search for Male/Female voices
      // Iterate through available voices
      for (var v in voiceList) {
        final Map<String, String> voice = Map<String, String>.from(v as Map);
        final name = voice['name']?.toLowerCase() ?? '';
        final locale = voice['locale']?.toLowerCase() ?? '';

        // Prioritize English
        if (locale.contains('en')) {
          // Female Detection
          if (name.contains('female') ||
              name.contains('samantha') ||
              name.contains('karen') ||
              name.contains('moira') ||
              name.contains('tessa')) {
            _femaleVoice ??= voice; // Keep first match
          }

          // Male Detection
          if ((name.contains('male') && !name.contains('female')) ||
              name.contains('daniel') ||
              name.contains('rishi') ||
              name.contains('fred') ||
              name.contains('alex') ||
              name.contains('aaron')) {
            _maleVoice ??= voice; // Keep first match
          }
        }
      }

      print(
        '🎤 Voice Init Complete: Female: ${_femaleVoice?['name']}, Male: ${_maleVoice?['name']}',
      );
    } catch (e) {
      print('Error Initialize Voices: $e');
    }
  }

  // --- Face Recognition Logic ---

  Future<void> _initializeCamera() async {
    if (_cameraController != null) return;

    final status = await Permission.camera.request();
    if (status != PermissionStatus.granted) {
      setState(() => _errorMessage = 'Camera permission denied');
      return;
    }

    try {
      final cameras = await availableCameras();
      // Use front camera if available
      final frontCamera = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      _cameraController = CameraController(
        frontCamera,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.nv21, // Android friendly
      );

      await _cameraController!.initialize();
      if (!mounted) return;

      setState(() => _isCameraInitialized = true);

      // Start processing stream - REMOVED for manual verification
      // _startFaceScan();
    } catch (e) {
      print('Camera init error: $e');
    }
  }

  Future<void> _stopCamera() async {
    final controller = _cameraController;
    _cameraController = null;
    await controller?.dispose();
    if (mounted) setState(() => _isCameraInitialized = false);
  }

  /// Called when user clicks the Verify button (Snapshot based - from Pudhin)
  Future<void> _verifyFace() async {
    if (_state == KioskState.verifying) return;

    // Voice prompt
    await _flutterTts.setLanguage(
      'en-US',
    ); // Ensure English for analysis prompts? Or Tamil? Pudhin used en-US/mixed.
    // Pudhin verifiedFace didn't speak instantly, just verifying state.

    setState(() => _state = KioskState.verifying);

    try {
      // Take photo
      final image = await _cameraController!.takePicture();
      // We don't need readAsBytes yet unless matchFaceOnly needs it.
      // matchFaceOnly takes bytes.
      final bytes = await image.readAsBytes();

      // CRITICAL: Validate face exists before processing
      final inputImage = InputImage.fromFilePath(image.path);
      // Use service wrapper
      final faces = await _faceDetectionService.processImage(inputImage);

      if (faces.isEmpty) {
        setState(() {
          _state = KioskState.error;
          _errorMessage = 'No face detected';
        });
        _speakRoast(
          'No face detected. Please position your face in the frame.',
        );
        await Future.delayed(const Duration(seconds: 2));
        if (mounted) setState(() => _state = KioskState.idle);
        return;
      }

      // Validate face quality
      final face = faces.first;
      final qualityIssue = _checkFaceQuality(face);
      if (qualityIssue != null) {
        setState(() {
          _state = KioskState.error;
          _errorMessage = qualityIssue;
        });
        _speakHappy(qualityIssue);
        await Future.delayed(const Duration(seconds: 2));
        if (mounted) setState(() => _state = KioskState.idle);
        return;
      }

      // Extract face bounding box for cropping
      final bbox = face.boundingBox;
      final faceRect = {
        'x': bbox.left.round(),
        'y': bbox.top.round(),
        'width': bbox.width.round(),
        'height': bbox.height.round(),
      };

      // Match face
      final matchResult = await _attendanceService.matchFaceOnly(
        bytes,
        faceRect: faceRect,
      );

      if (matchResult != null) {
        // Face matched
        setState(() {
          _state = KioskState.confirming;
          _employeeCode = matchResult.employeeId;
          _employeeName = matchResult.employeeName;
          _pendingEmployeeId = matchResult.employeeId;
          _pendingConfidence = matchResult.confidence;
        });

        _speakHappy('Thank you');
      } else {
        setState(() {
          _state = KioskState.error;
          _errorMessage = 'Face not recognized';
        });

        _speakError('Not recognized');
        await Future.delayed(const Duration(seconds: 2));
        if (mounted) setState(() => _state = KioskState.idle);
      }
    } catch (e) {
      setState(() {
        _state = KioskState.error;
        _errorMessage = 'Error: $e';
      });
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) setState(() => _state = KioskState.idle);
    }
  }

  /// Check face quality (Pudhin Logic)
  String? _checkFaceQuality(Face face) {
    // Check if head is rotated too much (lenient thresholds from Pudhin)
    final headY = face.headEulerAngleY ?? 0; // Left/right rotation
    final headZ = face.headEulerAngleZ ?? 0; // Head tilt

    // Allow up to 45 degrees left/right
    if (headY.abs() > 45) {
      return 'Please look at the camera';
    }
    // Allow up to 30 degrees head tilt
    if (headZ.abs() > 30) {
      return 'Please straighten your head';
    }

    // Check if eyes are open (liveness check)
    // Lower threshold (0.3) to accommodate glasses wearers
    final leftEye = face.leftEyeOpenProbability ?? 1.0;
    final rightEye = face.rightEyeOpenProbability ?? 1.0;
    if (leftEye < 0.3 && rightEye < 0.3) {
      // Only reject if BOTH eyes appear closed
      return 'Please open your eyes';
    }

    return null; // Quality is good
  }

  /// Called when user clicks "Verify" in Fingerprint mode
  Future<void> _onFingerprintVerifyPressed() async {
    // 1. Voice Message: "Please place your hand"
    await _flutterTts.setLanguage('en-US');
    _speakHappy('Please place your finger'); // Non-blocking

    // 2. Ensure Loop is running
    if (!_isScanningLoopActive) {
      _startAutoScanLoop();
    } else {
      _speakHappy('Scanning is active. Place your finger.');
    }
  }

  bool _isScanningLoopActive = false;

  /// Start continuous scan loop without blocking UI
  Future<void> _startAutoScanLoop() async {
    // Prevent multiple loops
    if (_isScanningLoopActive) return;

    _isScanningLoopActive = true;
    // Brief yield to let any pending native cancel fully release the device
    await Future.delayed(const Duration(milliseconds: 200));
    if (!mounted || !_isScanningLoopActive) return;
    // Clear the preparing state now that the loop is actually starting
    if (mounted && _isPreparingFingerprint) {
      setState(() => _isPreparingFingerprint = false);
    }
    print('🔄 Starting continuous fingerprint scan loop...');

    while (_isScanningLoopActive && mounted && _mode == KioskMode.fingerprint) {
      // Don't scan if we are in a success/error overlay state (let it finish showing)
      if (_state == KioskState.success ||
          _state == KioskState.error ||
          _state == KioskState.confirming) {
        await Future.delayed(const Duration(milliseconds: 500));
        continue;
      }

      // If idle, start scanning visual state (optional, or keep idle to be cleaner)
      // setState(() => _state = KioskState.scanning);
      // Actually, for always-on, usually we show "Place Finger" constant message.

      try {
        // 1. Capture Fingerprint (Blocking call with timeout from native SDK)
        final captureResult = await _fingerprintService.captureFingerprint();

        if (!captureResult.success) {
          // Capture failed (timeout, error, etc.)
          // Add a small delay to prevent tight loop if error is instant
          print('⚠️ Capture failed: ${captureResult.errorMessage}');
          await Future.delayed(const Duration(seconds: 1));
          continue;
        }

        if (captureResult.fingerprintTemplate != null) {
          // 2. We got a finger! Now process it.
          setState(
            () => _state = KioskState.scanning,
          ); // Show loading spinner now

          final result = await _attendanceService.punchAttendance(
            captureResult.fingerprintTemplate!,
          );

          if (result.success) {
            // Success!
            setState(() {
              _state = KioskState.success;
              _employeeCode = result.employeeCode ?? '';
              _employeeName = result.employeeName ?? '';
              _punchType = 'Punch ${result.punchType}';
              _time = _formatTime(result.timestamp ?? DateTime.now());
            });

            await _speakGreeting(result.punchType ?? 'IN', _employeeName);

            // Wait for success screen
            await Future.delayed(const Duration(seconds: 3));
            if (mounted) setState(() => _state = KioskState.idle);
          } else {
            // Check if it's just a cooldown (User is recognized but punched recently)
            final isCooldown =
                result.error?.contains('Already punched') ?? false;

            if (isCooldown) {
              // Treat as soft success / info
              final empName = result.employeeName ?? 'Champion';

              setState(() {
                _state = KioskState
                    .success; // Or create a .info state if needed, but success UI is fine
                _errorMessage = '';
                _employeeName = empName;
                _punchType = 'Relax';
                _time = 'Already In';
              });

              await _speakGreeting("You are already checked in", empName);
              await Future.delayed(const Duration(seconds: 3));
              if (mounted) setState(() => _state = KioskState.idle);
            } else {
              // Real Failure
              const simpleError = 'Not recognized, try again';

              setState(() {
                _state = KioskState.error;
                _errorMessage = simpleError;
              });
              await _soundService.playErrorBeep(); // Beep sound
              await _speakError(simpleError);
              await Future.delayed(const Duration(seconds: 2));
              if (mounted) setState(() => _state = KioskState.idle);
            }
          }
        } else {
          // Timeout or no finger. Just loop again.
          // Add small delay to prevent tight loop if SDK returns instantly
          await Future.delayed(const Duration(milliseconds: 500));
        }
      } catch (e) {
        print('Scan loop error: $e');
        // Wait before retrying
        await Future.delayed(const Duration(seconds: 1));
      }
    }

    _isScanningLoopActive = false;
    print('⏹️ Stopped continuous fingerprint scan loop');
  }

  /// Stop the loop (e.g. when switching tabs or navigating away)
  /// This is designed to return INSTANTLY — no awaits, no blocking.
  /// The scan loop will naturally exit on its own.
  void _stopAutoScanLoop() {
    if (!_isScanningLoopActive) return; // Already stopped
    _isScanningLoopActive = false;
    // Fire-and-forget: signal the native SDK to interrupt capture.
    // Don't await — the scan loop will handle the error and exit.
    _fingerprintService.cancelCapture();
  }

  /// User confirmed their identity - record the punch
  Future<void> _confirmPunch() async {
    setState(() => _state = KioskState.scanning); // Loading state

    try {
      final result = await _attendanceService.punchByEmployeeId(
        _pendingEmployeeId,
        _pendingConfidence,
      );

      if (result.success) {
        setState(() {
          _state = KioskState.success;
          _punchType = 'Punch ${result.punchType}';
          _time = _formatTime(result.timestamp!);
        });

        await _speakGreeting(result.punchType!, _employeeName);
      } else {
        setState(() {
          _state = KioskState.error;
          _errorMessage = result.error ?? 'Punch failed';
        });
        await _speakError(_errorMessage);
      }

      await Future.delayed(const Duration(seconds: 3));
      if (mounted) setState(() => _state = KioskState.idle);
    } catch (e) {
      setState(() {
        _state = KioskState.error;
        _errorMessage = 'Error: $e';
      });
      await _speakError(_errorMessage);
      await Future.delayed(const Duration(seconds: 3));
      if (mounted) setState(() => _state = KioskState.idle);
    }
  }

  void _cancelPunch() {
    _speakRoast('Cancelled. Please try again.');
    setState(() {
      _state = KioskState.idle;
      _pendingEmployeeId = '';
      _pendingConfidence = 0.0;
    });
  }

  String _formatTime(DateTime dt) {
    final hour = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
    final amPm = dt.hour >= 12 ? 'PM' : 'AM';
    return '${hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')} $amPm';
  }

  Future<void> _speakHappy(String text) async {
    await _flutterTts.setLanguage('en-US');
    if (_femaleVoice != null) {
      await _flutterTts.setVoice(_femaleVoice!);
      await _flutterTts.setPitch(
        1.0,
      ); // Reset pitch as the voice itself is female
    } else {
      await _flutterTts.setPitch(1.2); // Fallback pitch
    }
    await _flutterTts.setSpeechRate(0.4); // Normal speed
    await _flutterTts.speak(text);
  }

  Future<void> _speakRoast(String text) async {
    await _flutterTts.setLanguage('en-US');
    if (_maleVoice != null) {
      await _flutterTts.setVoice(_maleVoice!);
      await _flutterTts.setPitch(0.8); // Slightly lower for effect
    } else {
      await _flutterTts.setPitch(0.6); // Fallback pitch
    }
    await _flutterTts.setSpeechRate(0.35); // Slower/dramatic
    await _flutterTts.speak(text);
  }

  Future<void> _speakGreeting(String punchType, String employeeName) async {
    // Simple professional greeting
    const greeting = 'Thank you';
    await _speakHappy(greeting);
  }

  Future<void> _speakError(String message) async {
    // Simple error message
    const speechText = 'Not recognized, try again';
    await _speakRoast(speechText);
  }

  Future<void> _showSecurityCheck() async {
    // Show pattern/password dialog
    final authorized = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (context) => const AdminAccessDialog(),
    );

    if (authorized == true && mounted) {
      // STOP both camera and fingerprint scanning before leaving
      _stopAutoScanLoop();
      await _stopCamera();

      await Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const AdminDashboard()));

      if (mounted) {
        // PCRITICAL: Refresh cache to pick up any new enrollments made in Admin Dashboard
        print(
          'Refreshing employee cache after returning from Admin Dashboard...',
        );
        try {
          await _attendanceService.refreshEmployeeCache();
        } catch (e) {
          print('⚠️ Error refreshing cache: $e');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('⚠️ Sync Failed: $e'),
                backgroundColor: Colors.orange,
                duration: const Duration(seconds: 3),
              ),
            );
          }
        }

        // RESTART both if needed
        if (_mode == KioskMode.face) {
          _initializeCamera();
        } else if (_mode == KioskMode.fingerprint) {
          _startAutoScanLoop();
        }
      }
    }
  }

  @override
  void dispose() {
    print('Disposing KioskScreen, stopping loops...');
    _stopAutoScanLoop();
    // Cleanup listeners
    _fingerprintService.onDeviceAttached = null;
    _fingerprintService.onDeviceDetached = null;

    WidgetsBinding.instance.removeObserver(this);
    _cameraController?.dispose();
    _faceDetectionService.dispose();
    _faceEmbeddingService.dispose();
    _soundService.dispose();
    _fingerprintService.dispose();
    _attendanceService.dispose();
    _flutterTts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(color: Colors.white24),
              const SizedBox(height: 24),
              Text(
                'INITIALIZING KIOSK',
                style: GoogleFonts.poppins(
                  color: Colors.white24,
                  letterSpacing: 4,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0F0F12),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Background Gradient decoration
          Positioned(
            top: -100,
            right: -100,
            child: Container(
              width: 400,
              height: 400,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [Colors.blue.withOpacity(0.15), Colors.transparent],
                ),
              ),
            ),
          ),
          Positioned(
            bottom: -150,
            left: -150,
            child: Container(
              width: 500,
              height: 500,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [Colors.indigo.withOpacity(0.1), Colors.transparent],
                ),
              ),
            ),
          ),

          // Main Content (Header + Body)
          // Main Content
          SafeArea(
            child: Column(
              children: [
                const SizedBox(height: 16),

                // Header (Centered Tabs + Fixed Gap for Admin)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      // Organization chip or spacing
                      if (_organizationName.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.business_rounded, color: Color(0xFF60A5FA), size: 16),
                              const SizedBox(width: 6),
                              Text(
                                _organizationName,
                                style: GoogleFonts.poppins(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        )
                      else
                        const SizedBox(width: 44),
                      Expanded(child: Center(child: _buildTabSelector())),
                      const SizedBox(
                        width: 12,
                      ), // FIXED GAP between nav and settings
                      _buildAdminButton(),
                    ],
                  ),
                ),

                // Expanded Body (Camera / Fingerprint / Success)
                Expanded(
                  child: Container(
                    margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                    child: _state == KioskState.success
                        ? _buildSuccessView() // Unified Success UI
                        : (_mode == KioskMode.face
                              ? _buildFaceView()
                              : (_mode == KioskMode.pin
                                    ? _buildPinView()
                                    : _buildFingerprintView())),
                  ),
                ),

                // Footer: Verify Button (Fixed at bottom)
                // Hide verify button on success since we show status
                if (_state != KioskState.success &&
                    _mode != KioskMode.pin &&
                    ((_mode == KioskMode.fingerprint &&
                            _state == KioskState.idle) ||
                        (_mode == KioskMode.face &&
                            _state != KioskState.verifying)))
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 24,
                    ),
                    child: _buildVerifyButton(),
                  )
                else
                  const SizedBox(
                    height: 112,
                  ), // Placeholder size to prevent layout jump
              ],
            ),
          ),

          // Overlays
          if (_state == KioskState.verifying) _buildVerifyingOverlay(),
          if (_state == KioskState.confirming) _buildConfirmingOverlay(),
          // if (_state == KioskState.success) _buildSuccessOverlay(), // Removed as per user request to show inline
          if (_state == KioskState.error) _buildErrorOverlay(),
        ],
      ),
    );
  }

  // Unified Success View for Face & Fingerprint
  Widget _buildSuccessView() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 180,
              height: 180,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.green.withOpacity(0.1),
                border: Border.all(
                  color: Colors.greenAccent.withOpacity(0.5),
                  width: 2,
                ),
              ),
            ),
            Container(
              width: 140,
              height: 140,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.green, // Green Icon Background
                boxShadow: [
                  BoxShadow(
                    color: Colors.greenAccent,
                    blurRadius: 30,
                    spreadRadius: 5,
                  ),
                ],
              ),
              child: const Center(
                child: Icon(Icons.check_rounded, size: 80, color: Colors.white),
              ),
            ),
          ],
        ),
        const SizedBox(height: 32),
        Text(
          'Verified',
          style: GoogleFonts.poppins(
            color: Colors.greenAccent,
            fontSize: 32,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 16),
        // Employee Details
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white10,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white24),
          ),
          child: Column(
            children: [
              Text(
                _employeeName,
                style: GoogleFonts.poppins(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _employeeCode,
                style: GoogleFonts.poppins(color: Colors.white70, fontSize: 16),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        // Punch Status
        Text(
          _punchType, // "Punch IN" or "Punch OUT"
          style: GoogleFonts.poppins(
            color: Colors.white,
            fontSize: 28,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _time,
          style: GoogleFonts.poppins(color: Colors.white54, fontSize: 18),
        ),
      ],
    );
  }

  // --- PIN Mode Implementation ---

  Widget _buildPinView() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          'Enter Employee PIN', // Or ID
          style: GoogleFonts.poppins(
            color: Colors.white,
            fontSize: 24,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (_organizationName.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            _organizationName,
            style: GoogleFonts.poppins(
              color: const Color(0xFF60A5FA),
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
        const SizedBox(height: 24),
        // PIN Display
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          decoration: BoxDecoration(
            color: Colors.white10,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white24),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(4, (index) {
              return Container(
                margin: const EdgeInsets.symmetric(horizontal: 8),
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: index < _enteredPin.length
                      ? Colors.blueAccent
                      : Colors.white24,
                ),
              );
            }),
          ),
        ),
        const SizedBox(height: 32),
        // Keypad
        SizedBox(
          width: 280,
          child: GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            mainAxisSpacing: 16,
            crossAxisSpacing: 16,
            childAspectRatio: 1.2,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              for (var i = 1; i <= 9; i++) _buildPinKey(i.toString()),
              _buildPinKey(
                '',
                icon: Icons.backspace_outlined,
                onTap: _onPinBackspace,
              ), // Clear/Back
              _buildPinKey('0'),
              _buildPinKey(
                '',
                icon: Icons.check,
                isAction: true,
                onTap: _verifyPin,
              ), // Enter
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPinKey(
    String value, {
    IconData? icon,
    bool isAction = false,
    VoidCallback? onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap ?? () => _onPinDigit(value),
        borderRadius: BorderRadius.circular(100),
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isAction ? Colors.green.shade600 : Colors.white12,
          ),
          child: Center(
            child: icon != null
                ? Icon(icon, color: Colors.white, size: 24)
                : Text(
                    value,
                    style: GoogleFonts.poppins(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  void _onPinDigit(String digit) {
    if (_enteredPin.length < 4) {
      setState(() {
        _enteredPin += digit;
      });
    }
  }

  void _onPinBackspace() {
    if (_enteredPin.isNotEmpty) {
      setState(() {
        _enteredPin = _enteredPin.substring(0, _enteredPin.length - 1);
      });
    }
  }

  Future<void> _verifyPin() async {
    if (_enteredPin.length != 4) {
      await _speakError("Please enter 4 digits.");
      return;
    }

    setState(() => _state = KioskState.scanning); // Show loading

    try {
      final result = await _attendanceService.verifyPin(_enteredPin);

      if (mounted) {
        if (result.success) {
          setState(() {
            _state = KioskState.success;
            _employeeCode = result.employeeCode ?? '';
            _employeeName = result.employeeName ?? '';
            _punchType = result.punchType ?? '??';
            _time =
                "${DateTime.now().hour}:${DateTime.now().minute.toString().padLeft(2, '0')}";
          });

          await _soundService.playSuccess();
          await _flutterTts.speak(
            "Welcome ${result.employeeName}. You have punched ${result.punchType}.",
          );

          await Future.delayed(const Duration(seconds: 4));
          if (mounted) {
            setState(() {
              _state = KioskState.idle;
              _enteredPin = '';
            });
          }
        } else {
          setState(() {
            _state = KioskState.error;
            _errorMessage = result.error ?? 'Invalid PIN';
            _enteredPin = '';
          });
          await _speakError(result.error ?? "Invalid PIN");
          await Future.delayed(const Duration(seconds: 2));
          if (mounted) setState(() => _state = KioskState.idle);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _state = KioskState.error;
          _errorMessage = 'Error: $e';
        });
        await Future.delayed(const Duration(seconds: 2));
        if (mounted) setState(() => _state = KioskState.idle);
      }
    }
  }

  // New Dynamic Verify Button
  Widget _buildVerifyButton() {
    return Container(
      width: double.infinity,
      height: 64,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.green.shade500, Colors.green.shade800],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(32),
        boxShadow: [
          BoxShadow(
            color: Colors.green.withOpacity(0.4),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _mode == KioskMode.face
              ? _verifyFace
              : _onFingerprintVerifyPressed,
          borderRadius: BorderRadius.circular(32),
          child: Center(
            child: Text(
              _mode == KioskMode.face ? 'Verify Face' : 'Scanning...',
              style: GoogleFonts.poppins(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: Colors.white,
                letterSpacing: 1.0,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAdminButton() {
    return GestureDetector(
      onLongPress: () => _showSecurityCheck(),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.08),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withOpacity(0.1)),
        ),
        child: const Icon(
          Icons.settings_outlined,
          color: Colors.white54,
          size: 22,
        ),
      ),
    );
  }

  Widget _buildTabSelector() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.08),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withOpacity(0.12)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildTabButton(
                icon: Icons.fingerprint_rounded,
                label: 'Fingerprint',
                isActive: _mode == KioskMode.fingerprint,
                onTap: () {
                  if (_mode != KioskMode.fingerprint) {
                    _stopAutoScanLoop(); // Instant, non-blocking
                    _stopCamera(); // Fire and forget
                    setState(() {
                      _mode = KioskMode.fingerprint;
                      _state = KioskState.idle;
                      _isPreparingFingerprint = true;
                    });
                    // Defer scan loop start to next frame so the UI renders first
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted && _mode == KioskMode.fingerprint) {
                        _startAutoScanLoop();
                      }
                    });
                  }
                },
              ),
              _buildTabButton(
                icon: Icons.face_rounded,
                label: 'Face ID',
                isActive: _mode == KioskMode.face,
                onTap: () async {
                  if (_mode != KioskMode.face) {
                    _stopAutoScanLoop(); // Instant, non-blocking
                    // Update UI immediately so the tab switch feels instant
                    setState(() {
                      _mode = KioskMode.face;
                      _state = KioskState.scanning;
                      _isPreparingFace = true;
                    });
                    // Stop existing camera and re-init (these are async but lightweight)
                    await _stopCamera();
                    if (mounted && _mode == KioskMode.face) {
                      await _initializeCamera();
                      if (mounted) {
                        setState(() => _isPreparingFace = false);
                      }
                    }
                  }
                },
              ),
              _buildTabButton(
                icon: Icons.dialpad_rounded,
                label: 'PIN',
                isActive: _mode == KioskMode.pin,
                onTap: () {
                  if (_mode != KioskMode.pin) {
                    _stopAutoScanLoop(); // Instant, non-blocking
                    _stopCamera(); // Fire and forget
                    setState(() {
                      _mode = KioskMode.pin;
                      _state = KioskState.idle;
                      _enteredPin = '';
                    });
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTabButton({
    required IconData icon,
    required String label,
    required bool isActive,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          color: isActive ? Colors.blue.withOpacity(0.9) : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          boxShadow: isActive
              ? [
                  BoxShadow(
                    color: Colors.blue.withOpacity(0.3),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ]
              : [],
        ),
        child: Row(
          children: [
            Icon(
              icon,
              color: isActive ? Colors.white : Colors.white54,
              size: 18,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: GoogleFonts.poppins(
                color: isActive ? Colors.white : Colors.white54,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                fontSize: 12,
                letterSpacing: 0,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFaceView() {
    // Show loader while preparing (stopping fingerprint scan + starting camera)
    if (_isPreparingFace) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 60,
            height: 60,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              valueColor: AlwaysStoppedAnimation<Color>(Colors.blue.shade400),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Preparing Camera...',
            style: GoogleFonts.poppins(
              color: Colors.white70,
              fontSize: 18,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      );
    }

    if (_state != KioskState.scanning &&
        _state != KioskState.idle &&
        _state != KioskState.verifying) {
      // If confirming, allow overlays to handle visibility.
    }

    if (!_isCameraInitialized || _cameraController == null) {
      return Column(
        children: [
          Container(
            width: 320,
            height: 480,
            decoration: BoxDecoration(
              color: Colors.black26,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.white10),
            ),
            child: const Center(
              child: CircularProgressIndicator(color: Colors.blueAccent),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Starting Camera...',
            style: GoogleFonts.poppins(color: Colors.white54, fontSize: 16),
          ),
        ],
      );
    }

    // Camera View (Filling the Expanded area)
    return ClipRRect(
      borderRadius: BorderRadius.circular(32),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Camera feed scaling to fit without excessive zoom
          FittedBox(
            fit: BoxFit.contain,
            child: SizedBox(
              width: _cameraController!.value.previewSize!.height,
              height: _cameraController!.value.previewSize!.width,
              child: CameraPreview(_cameraController!),
            ),
          ),

          // Face Guide Overlay (Pudhin Style)
          _buildFaceGuideOverlay(),

          // Verify Button MOVED OUT to footer
          if (_state == KioskState.verifying)
            Container(
              color: Colors.black54,
              child: const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),
            ),
        ],
      ),
    );
  }

  /// Face position guide overlay with oval shape (Ported from Pudhin)
  /// Face position guide overlay with oval shape (Responsive)
  Widget _buildFaceGuideOverlay() {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Use the smaller dimension to keep it contained
        final shortSide = constraints.maxWidth < constraints.maxHeight
            ? constraints.maxWidth
            : constraints.maxHeight;

        // Calculate responsive oval size
        final ovalWidth = shortSide * 0.60;
        final ovalHeight = shortSide * 0.75; // Taller than wide

        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Instruction text at top
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(25),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.15),
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_organizationName.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          _organizationName,
                          style: GoogleFonts.poppins(
                            color: const Color(0xFF60A5FA),
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    const Text(
                      'Position your face in the oval',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              // Oval face guide
              Container(
                width: ovalWidth,
                height: ovalHeight,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(ovalWidth / 2),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.8),
                    width: 3,
                  ),
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // Corner markers for guidance
                    Positioned(
                      top: ovalHeight * 0.15,
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: Colors.greenAccent,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: ovalHeight * 0.15,
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: Colors.greenAccent,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    Positioned(
                      left: ovalWidth * 0.1,
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: Colors.greenAccent,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    Positioned(
                      right: ovalWidth * 0.1,
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: Colors.greenAccent,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildFingerprintView() {
    // Show loader while preparing scanner after tab switch
    if (_isPreparingFingerprint) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 60,
            height: 60,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              valueColor: AlwaysStoppedAnimation<Color>(Colors.blue.shade400),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Preparing Scanner...',
            style: GoogleFonts.poppins(
              color: Colors.white70,
              fontSize: 18,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      );
    }

    if (_state == KioskState.scanning) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
                width: 180,
                height: 180,
                child: CircularProgressIndicator(
                  strokeWidth: 4,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    Colors.blue.shade400,
                  ),
                ),
              ),
              Container(
                width: 140,
                height: 140,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.blue.withOpacity(0.1),
                ),
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.8, end: 1.2),
                  duration: const Duration(milliseconds: 800),
                  curve: Curves.easeInOut,
                  builder: (context, value, child) {
                    return Transform.scale(
                      scale: value,
                      child: Icon(
                        Icons.fingerprint_rounded,
                        size: 80,
                        color: Colors.blue.shade400.withOpacity(0.8),
                      ),
                    );
                  },
                  onEnd: () {},
                ),
              ),
            ],
          ),
          const SizedBox(height: 48),
          Text(
            'Analyzing Fingerprint',
            style: GoogleFonts.poppins(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Keep your finger firmly on the sensor',
            style: GoogleFonts.poppins(color: Colors.white54, fontSize: 16),
          ),
        ],
      );
    }

    // Idle State
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (!_fingerprintService.isInitialized ||
            _fingerprintService.deviceStatus != 'Connected')
          Padding(
            padding: const EdgeInsets.only(top: 16.0),
            child: InkWell(
              onTap: () async {
                await _fingerprintService.refreshConnection();
                setState(() {});
              },
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.red.withOpacity(0.5)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      color: Colors.redAccent,
                      size: 16,
                    ),
                    SizedBox(width: 8),
                    Text(
                      'Device Not Ready - Tap to Refresh',
                      style: GoogleFonts.poppins(
                        color: Colors.white,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        const SizedBox(height: 32),
        // Visual Indicator only (Auto-scanning)
        GestureDetector(
          onTap: () {
            // Optional: If for some reason loop stopped, restart it
            if (!_isScanningLoopActive) _startAutoScanLoop();
          },
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Colors.blue.shade400, Colors.blue.shade800],
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.blue.withOpacity(0.3),
                    blurRadius: 40,
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
                child: const Center(
                  child: Icon(
                    Icons.fingerprint_rounded,
                    size: 110,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
        ),
        const Spacer(),
        Container(
          width: 500,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Welcome',
                style: GoogleFonts.poppins(
                  color: Colors.white,
                  fontSize: 44,
                  fontWeight: FontWeight.bold,
                  height: 1.2,
                ),
                textAlign: TextAlign.center,
              ),
              if (_organizationName.isNotEmpty) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF3B82F6).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: const Color(0xFF3B82F6).withValues(alpha: 0.35),
                      width: 1.5,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.business_rounded,
                        color: Color(0xFF60A5FA),
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          _organizationName,
                          style: GoogleFonts.poppins(
                            color: const Color(0xFF93C5FD),
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.5,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        // Active Scanning Indicator
        if (_fingerprintService.isInitialized)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.green.withOpacity(0.1),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.green.withOpacity(0.3)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: Colors.greenAccent,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'Scanning Active',
                  style: GoogleFonts.poppins(
                    color: Colors.greenAccent,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        const Spacer(),
        // Verify Button Moved to Footer
      ],
    );
  }

  Widget _buildVerifyingOverlay() {
    return Center(
      child: Container(
        padding: const EdgeInsets.all(40),
        decoration: BoxDecoration(
          color: Colors.black87,
          borderRadius: BorderRadius.circular(20),
        ),
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Colors.white),
            SizedBox(height: 20),
            Text(
              'Verifying...',
              style: TextStyle(color: Colors.white, fontSize: 24),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConfirmingOverlay() {
    return Center(
      child: Container(
        padding: const EdgeInsets.all(32),
        margin: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.blue.shade800,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(color: Colors.black54, blurRadius: 20, spreadRadius: 5),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.help_outline, color: Colors.white, size: 60),
            const SizedBox(height: 16),
            const Text(
              'Is this you?',
              style: TextStyle(color: Colors.white70, fontSize: 18),
            ),
            const SizedBox(height: 12),
            // Employee ID badge
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.2),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                _employeeCode,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 12),
            // Employee Name - Large and prominent
            Text(
              _employeeName,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 32,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            // Confidence
            // Confidence removed
            // Text(
            //   'Match: ${_pendingConfidence.toStringAsFixed(1)}%',
            //   style: const TextStyle(color: Colors.white54, fontSize: 14),
            // ),
            const SizedBox(height: 24),
            // Action buttons
            Row(
              children: [
                // Cancel button
                Expanded(
                  child: SizedBox(
                    height: 50,
                    child: ElevatedButton(
                      onPressed: _cancelPunch,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red.shade600,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(25),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.close, size: 20),
                          SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              'Cancel',
                              style: TextStyle(fontSize: 16),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                // Confirm button
                Expanded(
                  child: SizedBox(
                    height: 50,
                    child: ElevatedButton(
                      onPressed: _confirmPunch,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green.shade600,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(25),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.check, size: 20),
                          SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              'Confirm',
                              style: TextStyle(fontSize: 16),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorOverlay() {
    return GestureDetector(
      onTap: () {
        if (mounted) setState(() => _state = KioskState.idle);
      },
      child: Container(
        color: Colors.black.withOpacity(0.85),
        child: Center(
          child: GestureDetector(
            onTap: () {}, // Prevent dismissal when tapping inside the dialog
            child: ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                child: Container(
                  width: 420,
                  padding: const EdgeInsets.all(40),
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(
                      color: Colors.redAccent.withOpacity(0.3),
                      width: 1.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.red.withOpacity(0.1),
                        blurRadius: 30,
                        spreadRadius: 5,
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Close Button at top right
                      Align(
                        alignment: Alignment.centerRight,
                        child: InkWell(
                          onTap: () {
                            if (mounted) {
                              setState(() => _state = KioskState.idle);
                            }
                          },
                          child: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.white10,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.close,
                              color: Colors.white70,
                              size: 20,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8), // Adjusted spacing
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: Colors.red.withOpacity(0.2),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.error_outline_rounded,
                          color: Colors.redAccent,
                          size: 60,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        'Access Denied',
                        style: GoogleFonts.poppins(
                          color: Colors.redAccent,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 2,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _errorMessage,
                        style: GoogleFonts.poppins(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w600,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 24),
                      // Dismiss Button
                      SizedBox(
                        width: double.infinity,
                        height: 48,
                        child: ElevatedButton(
                          onPressed: () {
                            if (mounted) {
                              setState(() => _state = KioskState.idle);
                            }
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.white10,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: Text(
                            'Dismiss',
                            style: GoogleFonts.poppins(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
